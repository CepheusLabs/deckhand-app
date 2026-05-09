import 'dart:convert';
import 'dart:typed_data';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EgressLogInterceptor', () {
    late _CapturingSecurity sec;
    late _FakeAdapter adapter;
    late Dio dio;

    setUp(() {
      sec = _CapturingSecurity();
      adapter = _FakeAdapter();
      dio = Dio()
        ..interceptors.add(EgressLogInterceptor(sec))
        ..httpClientAdapter = adapter;
    });

    test('emits start + completion events for a successful GET', () async {
      adapter.respondWithBody('OK');
      await dio.get<String>('https://example.com/foo');
      expect(sec.events, hasLength(2));
      expect(sec.events.first.host, 'example.com');
      expect(sec.events.first.url, 'https://example.com/foo');
      expect(sec.events.first.method, 'GET');
      expect(sec.events.first.completedAt, isNull);
      expect(sec.events.last.status, 200);
      expect(sec.events.last.bytes, 2);
      expect(sec.events.last.completedAt, isNotNull);
      // Both events share the same requestId so the UI can collapse
      // them into one row.
      expect(sec.events.first.requestId, sec.events.last.requestId);
      expect(sec.events.first.requestId, isNotEmpty);
    });

    test('passes through operation label from request extras', () async {
      adapter.respondWithBody('OK');
      await dio.get<String>(
        'https://example.com/profiles.yaml',
        options: Options(
          extra: const {
            EgressLogInterceptor.operationLabelKey: 'Profile fetch',
          },
        ),
      );
      expect(sec.events.last.operationLabel, 'Profile fetch');
    });

    test('records error events with the failure message', () async {
      adapter.failWith('connection refused');
      try {
        await dio.get<String>('https://example.com/x');
      } on DioException {
        /* expected */
      }
      expect(sec.events, hasLength(2));
      expect(sec.events.last.error, contains('connection refused'));
      expect(sec.events.last.completedAt, isNotNull);
    });

    test('falls back to "Background" label when none provided', () async {
      adapter.respondWithBody('OK');
      await dio.get<String>('https://example.com/anon');
      expect(sec.events.last.operationLabel, 'Background');
    });

    test(
      'approx-bytes still populated when Dio parsed the body to a Map',
      () async {
        // Dio's default responseType is JSON: it eats the bytes and
        // returns a Map. The previous _approxBytes returned null in
        // this case; the fix re-encodes the parsed object so the
        // S900 Network panel's "size" column has something to show.
        adapter.respondWithJson({'name': 'klipper', 'version': 'v0.12.0'});
        final res = await dio.get<dynamic>('https://example.com/registry.json');
        expect(res.data, isA<Map>());
        expect(
          sec.events.last.bytes,
          greaterThan(0),
          reason: 'parsed JSON body should still report a byte count',
        );
      },
    );

    test('tolerates malformed request extras on completion', () async {
      adapter.respondWithBody('OK');
      adapter.corruptEgressExtras = true;

      await dio.get<String>('https://example.com/corrupt-extras');

      expect(sec.events, hasLength(2));
      expect(sec.events.last.requestId, isEmpty);
      expect(sec.events.last.completedAt, isNotNull);
    });

    test('tolerates malformed request extras on error', () async {
      adapter.failWith('connection refused');
      adapter.corruptEgressExtras = true;

      try {
        await dio.get<String>('https://example.com/corrupt-error');
      } on DioException {
        /* expected */
      }

      expect(sec.events, hasLength(2));
      expect(sec.events.last.requestId, isEmpty);
      expect(sec.events.last.error, contains('connection refused'));
    });
  });
}

class _FakeAdapter implements HttpClientAdapter {
  String? _body;
  String? _failure;
  Map<String, List<String>>? _headersOverride;
  bool corruptEgressExtras = false;

  void respondWithBody(String body) {
    _body = body;
    _failure = null;
    _headersOverride = null;
  }

  void respondWithJson(Map<String, dynamic> body) {
    _body = jsonEncode(body);
    _failure = null;
    // The interceptor's content-length fast path would mask the
    // "parsed body" branch we want to exercise. Drop the header so
    // the test forces the JSON-encode fallback.
    _headersOverride = const {
      'content-type': ['application/json; charset=utf-8'],
    };
  }

  void failWith(String reason) {
    _failure = reason;
    _body = null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<dynamic>? cancelFuture,
  ) async {
    if (corruptEgressExtras) {
      options.extra['deckhand.request_id'] = 42;
      options.extra['deckhand.started_at'] = 'bad date';
    }
    if (_failure != null) {
      throw DioException(
        requestOptions: options,
        type: DioExceptionType.connectionError,
        message: _failure,
      );
    }
    final body = _body ?? '';
    final bytes = Uint8List.fromList(body.codeUnits);
    final headers =
        _headersOverride ??
        {
          'content-length': ['${bytes.length}'],
        };
    return ResponseBody.fromBytes(bytes, 200, headers: headers);
  }

  @override
  void close({bool force = false}) {}
}

class _CapturingSecurity implements SecurityService {
  final events = <EgressEvent>[];

  @override
  void recordEgress(EgressEvent event) => events.add(event);

  @override
  Stream<EgressEvent> get egressEvents => const Stream.empty();

  @override
  noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} not used');
}
