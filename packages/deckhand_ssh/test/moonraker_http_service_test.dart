import 'dart:convert';
import 'dart:typed_data';

import 'package:deckhand_ssh/deckhand_ssh.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'info falls back when Moonraker returns malformed result data',
    () async {
      final svc = MoonrakerHttpService(
        dio: Dio()
          ..httpClientAdapter = _MoonrakerAdapter(
            infoPayload: const {'result': 'not a map'},
          ),
      );

      final info = await svc.info(host: 'printer.local');

      expect(info.state, 'unknown');
      expect(info.hostname, 'printer.local');
      expect(info.softwareVersion, isEmpty);
      expect(info.klippyState, 'unknown');
    },
  );

  test('queryObjects returns empty status for malformed payloads', () async {
    final svc = MoonrakerHttpService(
      dio: Dio()
        ..httpClientAdapter = _MoonrakerAdapter(
          queryPayload: const {
            'result': {'status': 'not a map'},
          },
        ),
    );

    final status = await svc.queryObjects(
      host: 'printer.local',
      objects: const ['print_stats'],
    );

    expect(status, isEmpty);
  });

  test('isPrinting treats malformed print_stats as not printing', () async {
    final svc = MoonrakerHttpService(
      dio: Dio()
        ..httpClientAdapter = _MoonrakerAdapter(
          queryPayload: const {
            'result': {
              'status': {'print_stats': 'not a map'},
            },
          },
        ),
    );

    expect(await svc.isPrinting(host: 'printer.local'), isFalse);
  });

  test('listObjects ignores malformed object lists', () async {
    final svc = MoonrakerHttpService(
      dio: Dio()
        ..httpClientAdapter = _MoonrakerAdapter(
          listPayload: const {
            'result': {
              'objects': ['print_stats', 42, 'extruder'],
            },
          },
        ),
    );

    expect(await svc.listObjects(host: 'printer.local'), [
      'print_stats',
      'extruder',
    ]);
  });
}

class _MoonrakerAdapter implements HttpClientAdapter {
  const _MoonrakerAdapter({
    this.infoPayload = const <String, dynamic>{'result': <String, dynamic>{}},
    this.queryPayload = const <String, dynamic>{'result': <String, dynamic>{}},
    this.listPayload = const <String, dynamic>{'result': <String, dynamic>{}},
  });

  final Map<String, dynamic> infoPayload;
  final Map<String, dynamic> queryPayload;
  final Map<String, dynamic> listPayload;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final payload = switch (options.uri.path) {
      '/printer/info' => infoPayload,
      '/printer/objects/query' => queryPayload,
      '/printer/objects/list' => listPayload,
      _ => const <String, dynamic>{'result': <String, dynamic>{}},
    };
    return ResponseBody.fromString(
      jsonEncode(payload),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
