import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:deckhand_core/deckhand_web_core.dart';
import 'package:dio/dio.dart';
import 'package:web/web.dart' as web;

class DeckhandLocalAgentClient implements LocalAgentClient {
  DeckhandLocalAgentClient({
    required this.baseUrl,
    required this.token,
    Dio? dio,
  }) : _dio = dio ?? Dio();

  final String baseUrl;
  final String token;
  final Dio _dio;

  Future<bool> ping() async {
    try {
      final response = await _dio.get<Map<String, dynamic>>(
        _url('/ping'),
        options: Options(headers: _headers),
      );
      return response.statusCode == 200 && response.data?['ok'] == true;
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<Map<String, Object?>> callStreaming(
    String method,
    Map<String, Object?> params,
  ) async* {
    final response = await _dio.post<Map<String, dynamic>>(
      _url('/operations'),
      data: {'method': method, 'params': params},
      options: Options(headers: _headers),
    );
    final id = response.data?['id']?.toString();
    if (id == null || id.isEmpty) {
      throw const DeckhandTransportException(
        'local agent did not return an operation id',
      );
    }
    yield* _operationEvents(id);
  }

  Stream<Map<String, Object?>> _operationEvents(String id) {
    late final web.EventSource source;
    late final StreamController<Map<String, Object?>> controller;
    controller = StreamController<Map<String, Object?>>(
      onCancel: () => source.close(),
    );
    source = web.EventSource(
      _url('/operations/$id/events', eventSource: true),
    );

    void addEvent(web.Event event) {
      if (controller.isClosed) return;
      final message = event as web.MessageEvent;
      final data = _decodeEventData(message.data);
      controller.add(data);
      final phase = data['phase']?.toString();
      final operationEvent = data['operation_event']?.toString();
      if (phase == 'done' ||
          phase == 'failed' ||
          operationEvent == 'done' ||
          operationEvent == 'failed' ||
          operationEvent == 'cancelled') {
        source.close();
        unawaited(controller.close());
      }
    }

    for (final name in const ['progress', 'done', 'failed', 'cancelled']) {
      source.addEventListener(name, addEvent.toJS);
    }
    source.onError.listen((_) {
      if (controller.isClosed) return;
      source.close();
      controller.addError(
        const DeckhandTransportException('local agent event stream failed'),
      );
      unawaited(controller.close());
    });
    return controller.stream;
  }

  Map<String, Object?> _decodeEventData(JSAny? raw) {
    if (raw != null) {
      final text = (raw as JSString).toDart;
      if (text.trim().isEmpty) return const <String, Object?>{};
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return decoded.cast<String, Object?>();
      }
    }
    return const <String, Object?>{};
  }

  Map<String, String> get _headers {
    return {
      if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
    };
  }

  String _url(String path, {bool eventSource = false}) {
    final root = baseUrl.endsWith('/')
        ? baseUrl.substring(0, baseUrl.length - 1)
        : baseUrl;
    final normalizedPath = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$root$normalizedPath');
    if (!eventSource || token.trim().isEmpty) {
      return uri.toString();
    }
    return uri
        .replace(
          queryParameters: {...uri.queryParameters, 'token': token.trim()},
        )
        .toString();
  }
}
