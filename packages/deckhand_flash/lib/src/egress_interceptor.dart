import 'dart:convert';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:dio/dio.dart';
import 'package:uuid/uuid.dart';

/// Dio interceptor that forwards every outbound HTTP request through
/// [SecurityService.recordEgress] so the S900 Network panel and the
/// debug-bundle capture can subscribe to a single stream of approved
/// outbound traffic.
///
/// The hook fires at four points per request:
///   - `onRequest`  → emit a "started" event (no bytes yet).
///   - `onResponse` → emit a "completed" event with bytes + status.
///   - `onError`    → emit a "completed" event with the error string.
///
/// `operationLabel` is set by callers via Dio request `extra` under
/// the [operationLabelKey] key. Wizard-step adapters wrap their
/// `dio.get(...)` calls with `Options(extra: {operationLabelKey:
/// 'Profile fetch'})`. Calls without a label fall back to
/// `'Background'` so the panel still shows them.
class EgressLogInterceptor extends Interceptor {
  EgressLogInterceptor(this.security, {Uuid? uuid})
    : _uuid = uuid ?? const Uuid();

  final SecurityService security;
  final Uuid _uuid;

  /// Dio request-extras key callers set to label what wizard step
  /// triggered the request. Surfaced as [EgressEvent.operationLabel].
  static const String operationLabelKey = 'deckhand.operation_label';

  /// Internal extras key — stamped on the request by [onRequest] so
  /// [onResponse] / [onError] can pair the start + completion events.
  static const String _requestIdKey = 'deckhand.request_id';
  static const String _startedAtKey = 'deckhand.started_at';

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final id = _uuid.v4();
    final startedAt = DateTime.now().toUtc();
    options.extra[_requestIdKey] = id;
    options.extra[_startedAtKey] = startedAt;
    final host = Uri.tryParse(options.uri.toString())?.host ?? '';
    security.recordEgress(
      EgressEvent(
        requestId: id,
        host: host,
        url: options.uri.toString(),
        method: options.method,
        operationLabel:
            options.extra[operationLabelKey]?.toString() ?? 'Background',
        startedAt: startedAt,
      ),
    );
    handler.next(options);
  }

  @override
  void onResponse(
    Response<dynamic> response,
    ResponseInterceptorHandler handler,
  ) {
    final extras = response.requestOptions.extra;
    final id = _stringExtra(extras, _requestIdKey) ?? '';
    final started =
        _dateTimeExtra(extras, _startedAtKey) ?? DateTime.now().toUtc();
    final host = response.requestOptions.uri.host;
    final bytes = _approxBytes(response);
    security.recordEgress(
      EgressEvent(
        requestId: id,
        host: host,
        url: response.requestOptions.uri.toString(),
        method: response.requestOptions.method,
        operationLabel: extras[operationLabelKey]?.toString() ?? 'Background',
        startedAt: started,
        completedAt: DateTime.now().toUtc(),
        bytes: bytes,
        status: response.statusCode,
      ),
    );
    handler.next(response);
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    final extras = err.requestOptions.extra;
    final id = _stringExtra(extras, _requestIdKey) ?? '';
    final started =
        _dateTimeExtra(extras, _startedAtKey) ?? DateTime.now().toUtc();
    final host = err.requestOptions.uri.host;
    security.recordEgress(
      EgressEvent(
        requestId: id,
        host: host,
        url: err.requestOptions.uri.toString(),
        method: err.requestOptions.method,
        operationLabel: extras[operationLabelKey]?.toString() ?? 'Background',
        startedAt: started,
        completedAt: DateTime.now().toUtc(),
        status: err.response?.statusCode,
        error: err.message ?? err.type.name,
      ),
    );
    handler.next(err);
  }

  int? _approxBytes(Response<dynamic> r) {
    // 1. Trust Content-Length when the server provided it.
    final cl = r.headers.value('content-length');
    if (cl != null) {
      final n = int.tryParse(cl);
      if (n != null) return n;
    }
    // 2. Body is already in a known-size shape — bytes or text.
    final body = r.data;
    if (body is List<int>) return body.length;
    if (body is String) return body.length;
    // 3. Body was parsed by Dio (Map / List / num / bool from a
    //    JSON response, which is the default responseType). The
    //    parser ate the wire bytes, but we can re-encode and
    //    measure. The encoded length differs from the wire length
    //    by whitespace that was discarded during parsing — fine
    //    for "how big was this fetch", which is the panel's only
    //    consumer of the field.
    if (body is Map || body is List || body is num || body is bool) {
      try {
        return utf8.encode(jsonEncode(body)).length;
      } on Object {
        return null;
      }
    }
    return null;
  }

  String? _stringExtra(Map<String, dynamic> extras, String key) {
    final value = extras[key];
    return value is String ? value : null;
  }

  DateTime? _dateTimeExtra(Map<String, dynamic> extras, String key) {
    final value = extras[key];
    return value is DateTime ? value : null;
  }
}

/// Builder convenience: returns a Dio with the egress interceptor
/// pre-attached. Use this where you'd otherwise `Dio()` so every
/// instance produces consistent egress events.
Dio buildEgressLoggingDio(SecurityService security) {
  final dio = Dio();
  dio.interceptors.add(EgressLogInterceptor(security));
  return dio;
}
