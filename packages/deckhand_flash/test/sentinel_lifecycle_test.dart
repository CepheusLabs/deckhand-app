import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const imageSha256 =
      '0123456789abcdef0123456789abcdef'
      '0123456789abcdef0123456789abcdef';

  group('flash sentinel lifecycle', () {
    late Directory tmp;
    late FlashSentinelWriter writer;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('deckhand-sentinel-');
      writer = FlashSentinelWriter(directory: tmp.path);
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on Object {
        /* best-effort */
      }
    });

    test('write produces a JSON file with the expected schema', () async {
      await writer.write(
        diskId: 'PhysicalDrive3',
        imagePath: '/tmp/img.iso',
        imageSha256: 'abc',
      );
      final f = File(writer.sentinelPath('PhysicalDrive3'));
      expect(await f.exists(), isTrue);
      final body = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      expect(body['schema'], 'deckhand.flash_sentinel/1');
      expect(body['disk_id'], 'PhysicalDrive3');
      expect(body['image_path'], '/tmp/img.iso');
      expect(body['image_sha256'], 'abc');
      expect(body['started_at'], isNotEmpty);
    });

    test('disk_ids with shell-special characters round-trip safely', () async {
      const oddId = r'/dev/disk0/partition$1';
      await writer.write(diskId: oddId, imagePath: '/x');
      final path = writer.sentinelPath(oddId);
      // Filename never contains the unsafe chars verbatim.
      expect(p.basename(path), isNot(contains('/')));
      expect(p.basename(path), isNot(contains(r'$')));
      expect(await File(path).exists(), isTrue);
    });

    test('clear removes the sentinel; missing file is not an error', () async {
      await writer.write(diskId: 'd1', imagePath: '/x');
      await writer.clear('d1');
      expect(await File(writer.sentinelPath('d1')).exists(), isFalse);
      // Idempotent.
      await writer.clear('d1');
      await writer.clear('never-existed');
    });

    test('helper launch dispatch: sentinel written before launch, '
        'cleared only on event:done', () async {
      // Subclass that doesn't spawn a real process — the test wants
      // the lifecycle, not the OS-level elevation prompt.
      final svc = _FakeLaunchHelperService(
        helperPath: '/fake',
        sentinelWriter: writer,
        events: [
          const FlashProgress(
            bytesDone: 100,
            bytesTotal: 100,
            phase: FlashPhase.done,
            message: 'sha-stub',
          ),
        ],
      );
      // Sentinel must NOT exist before writeImage starts.
      expect(await File(writer.sentinelPath('disk0')).exists(), isFalse);

      // Stream the events; sentinel is written before the first
      // event arrives and cleared after the last one.
      final got = await svc
          .writeImage(
            imagePath: '/img.iso',
            diskId: 'disk0',
            confirmationToken: 'tok-${"x" * 16}',
            expectedSha256: imageSha256,
          )
          .toList();
      expect(got, hasLength(1));
      expect(got.single.phase, FlashPhase.done);

      // Cleared because event:done fired.
      expect(await File(writer.sentinelPath('disk0')).exists(), isFalse);
    });

    test(
      'sentinel survives when the helper exits without event:done',
      () async {
        final svc = _FakeLaunchHelperService(
          helperPath: '/fake',
          sentinelWriter: writer,
          events: [
            const FlashProgress(
              bytesDone: 50,
              bytesTotal: 100,
              phase: FlashPhase.writing,
              message: null,
            ),
            // Stream ends without a `done` phase — simulates the
            // helper crashing mid-write.
          ],
        );
        await svc
            .writeImage(
              imagePath: '/img.iso',
              diskId: 'disk-crash',
              confirmationToken: 'tok-${"x" * 16}',
              expectedSha256: imageSha256,
            )
            .toList();
        // Sentinel persists.
        expect(await File(writer.sentinelPath('disk-crash')).exists(), isTrue);
      },
    );

    test(
      'next disks.list-style read surfaces the surviving sentinel',
      () async {
        // Write a sentinel directly (simulating a prior failed flash),
        // then load via the test seam.
        await writer.write(
          diskId: 'PhysicalDrive3',
          imagePath: '/tmp/x.iso',
          imageSha256: 'sha',
        );
        final body =
            jsonDecode(
                  await File(
                    writer.sentinelPath('PhysicalDrive3'),
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        // The Go side's LoadSentinels is the production reader; here we
        // assert the wire format is what the Go side expects (schema +
        // disk_id key + ISO-8601 timestamp).
        expect(body['schema'], 'deckhand.flash_sentinel/1');
        expect(body['disk_id'], 'PhysicalDrive3');
        expect(
          DateTime.tryParse(body['started_at'] as String),
          isNotNull,
          reason: 'sidecar parses started_at as RFC3339',
        );
      },
    );
  });
}

/// [ProcessElevatedHelperService] subclass that streams a canned
/// list of events instead of spawning a real process. Tests use
/// this to exercise the sentinel lifecycle without requiring UAC /
/// pkexec / osascript.
class _FakeLaunchHelperService extends ProcessElevatedHelperService {
  _FakeLaunchHelperService({
    required super.helperPath,
    required super.sentinelWriter,
    required this.events,
  });

  final List<FlashProgress> events;

  @override
  Stream<FlashProgress> launchHelper(List<String> args) async* {
    for (final e in events) {
      yield e;
    }
  }
}
