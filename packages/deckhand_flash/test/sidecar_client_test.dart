import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_flash/src/sidecar_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for [SidecarClient]'s framing / correlation / error logic.
///
/// We don't spawn a real Go sidecar in CI. The client exposes two
/// `@visibleForTesting` seams - [SidecarClient.registerPendingForTesting]
/// and [SidecarClient.handleLineForTesting] - that let us feed
/// synthetic JSON-RPC lines through the same dispatch code the
/// production stdout stream uses, without touching Process or IOSink.
void main() {
  group('SidecarClient response routing', () {
    test(
      'start failure leaves the client reusable and not half-started',
      () async {
        final client = SidecarClient(
          binaryPath: 'definitely_missing_deckhand_sidecar_for_test',
        );

        await expectLater(client.start(), throwsA(isA<ProcessException>()));
        await expectLater(client.start(), throwsA(isA<ProcessException>()));
        expect(client.pendingRequestCountForTesting, 0);
        await expectLater(
          client.call('ping', const {}),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('callStreaming before start throws a controlled StateError', () {
      final client = SidecarClient(binaryPath: '/does/not/exist');

      expect(
        () => client.callStreaming('disks.write_image', const {}).listen(null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not started'),
          ),
        ),
      );
    });

    test('callStreaming surfaces stdin flush failures and cleans up', () async {
      final client = SidecarClient(binaryPath: '/does/not/exist');
      client.startForTesting(
        writeLine: (_) {},
        flush: () async {
          throw const SidecarError(code: -1, message: 'stdin closed');
        },
      );

      final stream = client.callStreaming('disks.write_image', const {});

      await expectLater(
        stream,
        emitsError(
          isA<SidecarError>().having(
            (e) => e.message,
            'message',
            'stdin closed',
          ),
        ),
      );
      expect(client.pendingRequestCountForTesting, 0);
      expect(client.operationSubscriberCountForTesting, 0);
    });

    test('callStreaming cancel sends jobs.cancel and releases state', () async {
      final writes = <String>[];
      final client = SidecarClient(binaryPath: '/does/not/exist');
      client.startForTesting(writeLine: writes.add, flush: () async {});

      final sub = client.callStreaming('os.download', const {}).listen((_) {});
      await Future<void>.delayed(Duration.zero);
      expect(client.pendingRequestCountForTesting, 1);
      expect(client.operationSubscriberCountForTesting, 1);

      await sub.cancel();

      expect(client.pendingRequestCountForTesting, 0);
      expect(client.operationSubscriberCountForTesting, 0);
      expect(writes, hasLength(2));
      final request = jsonDecode(writes.first) as Map<String, dynamic>;
      final cancel = jsonDecode(writes.last) as Map<String, dynamic>;
      expect(cancel['method'], 'jobs.cancel');
      expect((cancel['params'] as Map<String, dynamic>)['id'], request['id']);
    });

    test(
      'successful response resolves the pending future with result',
      () async {
        final client = SidecarClient(binaryPath: '/does/not/exist');
        final completer = Completer<Map<String, dynamic>>();
        client.registerPendingForTesting('req-1', completer);

        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'req-1',
            'result': {'ok': true, 'value': 42},
          }),
        );

        final result = await completer.future;
        expect(result, {'ok': true, 'value': 42});
      },
    );

    test('scalar `result` is wrapped in {value: ...}', () async {
      final client = SidecarClient(binaryPath: '/does/not/exist');
      final completer = Completer<Map<String, dynamic>>();
      client.registerPendingForTesting('req-scalar', completer);

      client.handleLineForTesting(
        jsonEncode({'jsonrpc': '2.0', 'id': 'req-scalar', 'result': 'pong'}),
      );

      final result = await completer.future;
      expect(result, {'value': 'pong'});
    });

    test(
      'error response rejects with SidecarError carrying code + message',
      () async {
        final client = SidecarClient(binaryPath: '/does/not/exist');
        final completer = Completer<Map<String, dynamic>>();
        client.registerPendingForTesting('req-err', completer);

        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'req-err',
            'error': {
              'code': -34002,
              'message': 'disk not found',
              'data': {'diskId': 'PhysicalDrive9'},
            },
          }),
        );

        await expectLater(
          completer.future,
          throwsA(
            isA<SidecarError>()
                .having((e) => e.code, 'code', -34002)
                .having((e) => e.message, 'message', 'disk not found')
                .having((e) => e.data, 'data', {'diskId': 'PhysicalDrive9'}),
          ),
        );
      },
    );

    test('notification (no id) fires onNotification without completing any '
        'pending request', () async {
      final client = SidecarClient(binaryPath: '/does/not/exist');
      final completer = Completer<Map<String, dynamic>>();
      client.registerPendingForTesting('req-live', completer);

      final received = <SidecarNotification>[];
      final sub = client.notifications.listen(received.add);

      client.handleLineForTesting(
        jsonEncode({
          'jsonrpc': '2.0',
          'method': 'progress',
          'params': {'operation_id': 'op-123', 'bytes_done': 1024},
        }),
      );

      // Give the broadcast stream a microtask tick to deliver.
      await Future<void>.delayed(Duration.zero);

      expect(received, hasLength(1));
      expect(received.single.method, 'progress');
      expect(received.single.operationId, 'op-123');
      expect(received.single.params['bytes_done'], 1024);
      expect(
        completer.isCompleted,
        isFalse,
        reason: 'notifications must not complete the pending request',
      );
      await sub.cancel();
    });

    test(
      'subscribeToOperation receives only notifications for its op id',
      () async {
        final client = SidecarClient(binaryPath: '/does/not/exist');
        final opNotes = <SidecarNotification>[];
        final sub = client.subscribeToOperation('op-A').listen(opNotes.add);

        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'progress',
            'params': {'operation_id': 'op-A', 'step': 1},
          }),
        );
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'progress',
            'params': {'operation_id': 'op-B', 'step': 99},
          }),
        );
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'progress',
            'params': {'operation_id': 'op-A', 'step': 2},
          }),
        );
        await Future<void>.delayed(Duration.zero);

        expect(opNotes.map((n) => n.params['step']), [1, 2]);
        await sub.cancel();
      },
    );

    test(
      'out-of-order responses route to the correct pending caller',
      () async {
        final client = SidecarClient(binaryPath: '/does/not/exist');
        final c1 = Completer<Map<String, dynamic>>();
        final c2 = Completer<Map<String, dynamic>>();
        final c3 = Completer<Map<String, dynamic>>();
        client.registerPendingForTesting('a', c1);
        client.registerPendingForTesting('b', c2);
        client.registerPendingForTesting('c', c3);

        // Deliver c, then a, then b - in no particular order.
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'c',
            'result': {'which': 'c'},
          }),
        );
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'a',
            'result': {'which': 'a'},
          }),
        );
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'b',
            'result': {'which': 'b'},
          }),
        );

        expect((await c1.future)['which'], 'a');
        expect((await c2.future)['which'], 'b');
        expect((await c3.future)['which'], 'c');
      },
    );

    test('response for an unknown id is dropped silently (no throw)', () {
      final client = SidecarClient(binaryPath: '/does/not/exist');
      // No pending registered for `ghost`.
      expect(
        () => client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'ghost',
            'result': <String, dynamic>{},
          }),
        ),
        returnsNormally,
      );
    });

    test('malformed JSON line is ignored (framing tolerance)', () {
      final client = SidecarClient(binaryPath: '/does/not/exist');
      expect(
        () => client.handleLineForTesting('not { valid json'),
        returnsNormally,
      );
    });

    test('empty / whitespace-only line is ignored', () {
      final client = SidecarClient(binaryPath: '/does/not/exist');
      expect(() => client.handleLineForTesting(''), returnsNormally);
      expect(() => client.handleLineForTesting('   '), returnsNormally);
    });

    test(
      'notification without operation_id still dispatches globally',
      () async {
        final client = SidecarClient(binaryPath: '/does/not/exist');
        final received = <SidecarNotification>[];
        final sub = client.notifications.listen(received.add);

        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'heartbeat',
            'params': {'stage': 'booting'},
          }),
        );
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received.single.method, 'heartbeat');
        expect(received.single.operationId, isNull);
        await sub.cancel();
      },
    );

    test(
      'notification with malformed params dispatches an empty payload',
      () async {
        final client = SidecarClient(binaryPath: '/does/not/exist');
        final received = <SidecarNotification>[];
        final sub = client.notifications.listen(received.add);

        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'method': 'progress',
            'params': ['not', 'a', 'map'],
          }),
        );
        await Future<void>.delayed(Duration.zero);

        expect(received, hasLength(1));
        expect(received.single.method, 'progress');
        expect(received.single.params, isEmpty);
        expect(received.single.operationId, isNull);
        await sub.cancel();
      },
    );

    test(
      'numeric id from sidecar still correlates (coerced to string)',
      () async {
        final client = SidecarClient(binaryPath: '/does/not/exist');
        final completer = Completer<Map<String, dynamic>>();
        // The client converts incoming ids to string via obj['id'].toString(),
        // so a pending keyed as '7' must still match an int-id response.
        client.registerPendingForTesting('7', completer);

        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 7,
            'result': {'n': 7},
          }),
        );

        expect(await completer.future, {'n': 7});
      },
    );

    test(
      'malformed error envelope does not crash — synthesized -1 code',
      () async {
        // Regression: (err["code"] as num).toInt() crashed the isolate
        // when a buggy sidecar sent an error that was not a Map, or a
        // Map without a numeric `code`. Both shapes must now come back
        // as a SidecarError with code = -1.
        final client = SidecarClient(binaryPath: '/does/not/exist');

        // Case A: error is a string, not a Map.
        final c1 = Completer<Map<String, dynamic>>();
        client.registerPendingForTesting('r-a', c1);
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'r-a',
            'error': 'something went wrong',
          }),
        );
        final errA = await c1.future.then<Object?>(
          (v) => v,
          onError: (Object e) => e,
        );
        expect(errA, isA<SidecarError>());
        expect((errA! as SidecarError).code, -1);
        expect((errA as SidecarError).message, contains('malformed'));

        // Case B: error is a Map but `code` is a string like "unauthorized".
        final c2 = Completer<Map<String, dynamic>>();
        client.registerPendingForTesting('r-b', c2);
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'r-b',
            'error': {'code': 'unauthorized', 'message': 'nope'},
          }),
        );
        final errB = await c2.future.then<Object?>(
          (v) => v,
          onError: (Object e) => e,
        );
        expect(errB, isA<SidecarError>());
        expect((errB! as SidecarError).code, -1);
        expect((errB as SidecarError).message, 'nope');

        // Case C: error Map with `code` missing entirely.
        final c3 = Completer<Map<String, dynamic>>();
        client.registerPendingForTesting('r-c', c3);
        client.handleLineForTesting(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': 'r-c',
            'error': {'message': 'no code'},
          }),
        );
        final errC = await c3.future.then<Object?>(
          (v) => v,
          onError: (Object e) => e,
        );
        expect(errC, isA<SidecarError>());
        expect((errC! as SidecarError).code, -1);
      },
    );

    test('malformed error message still rejects with SidecarError', () async {
      final client = SidecarClient(binaryPath: '/does/not/exist');
      final completer = Completer<Map<String, dynamic>>();
      client.registerPendingForTesting('req-bad-message', completer);

      client.handleLineForTesting(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 'req-bad-message',
          'error': {
            'code': -2,
            'message': ['not', 'a', 'string'],
          },
        }),
      );

      await expectLater(
        completer.future,
        throwsA(
          isA<SidecarError>()
              .having((e) => e.code, 'code', -2)
              .having((e) => e.message, 'message', ''),
        ),
      );
    });
  });

  group('SidecarError', () {
    test('toString includes code and message', () {
      const e = SidecarError(code: -34010, message: 'verify failed');
      expect(e.toString(), contains('-34010'));
      expect(e.toString(), contains('verify failed'));
    });
  });
}
