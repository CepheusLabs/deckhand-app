import 'package:deckhand_core/deckhand_core.dart';
import 'package:dio/dio.dart';

/// [MoonrakerService] using HTTP against Moonraker's REST API. We only
/// need two endpoints (info + print_stats), both available over REST -
/// no WebSocket needed.
class MoonrakerHttpService implements MoonrakerService {
  MoonrakerHttpService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 5),
              receiveTimeout: const Duration(seconds: 5),
            ),
          );

  final Dio _dio;

  @override
  Future<KlippyInfo> info({required String host, int port = 7125}) async {
    final res = await _dio.getUri<Map<String, dynamic>>(
      _moonrakerUri(host, port, const ['printer', 'info']),
    );
    final r =
        (res.data?['result'] as Map?)?.cast<String, dynamic>() ?? const {};
    return KlippyInfo(
      state: r['state'] as String? ?? 'unknown',
      hostname: r['hostname'] as String? ?? host,
      softwareVersion: r['software_version'] as String? ?? '',
      klippyState: r['state'] as String? ?? 'unknown',
    );
  }

  @override
  Future<bool> isPrinting({required String host, int port = 7125}) async {
    final status = await queryObjects(
      host: host,
      port: port,
      objects: const ['print_stats'],
    );
    final stats = status['print_stats'] as Map?;
    final state = stats?['state'] as String?;
    return state == 'printing' || state == 'paused';
  }

  @override
  Future<Map<String, dynamic>> queryObjects({
    required String host,
    int port = 7125,
    required List<String> objects,
  }) async {
    final res = await _dio.getUri<Map<String, dynamic>>(
      _moonrakerUri(
        host,
        port,
        const ['printer', 'objects', 'query'],
        queryParameters: {for (final object in objects) object: ''},
      ),
    );
    final status = (res.data?['result'] as Map?)?['status'] as Map? ?? const {};
    return status.cast<String, dynamic>();
  }

  @override
  Future<void> runGCode({
    required String host,
    int port = 7125,
    required String script,
  }) async {
    await _dio.postUri<Map<String, dynamic>>(
      _moonrakerUri(host, port, const ['printer', 'gcode', 'script']),
      data: {'script': script},
    );
  }

  @override
  Future<List<String>> listObjects({
    required String host,
    int port = 7125,
  }) async {
    final res = await _dio.getUri<Map<String, dynamic>>(
      _moonrakerUri(host, port, const ['printer', 'objects', 'list']),
    );
    final objects =
        (res.data?['result'] as Map?)?['objects'] as List? ?? const [];
    return objects.whereType<String>().toList();
  }

  @override
  Future<String?> fetchConfigFile({
    required String host,
    int port = 7125,
    required String filename,
  }) async {
    try {
      final res = await _dio.getUri<String>(
        _moonrakerUri(host, port, [
          'server',
          'files',
          'config',
          ..._safeConfigPath(filename),
        ]),
        options: Options(responseType: ResponseType.plain),
      );
      return res.data;
    } on DioException {
      // Any HTTP-level failure (404 missing file, 401 permission,
      // connection refused) is the same signal at this layer: we
      // didn't get a marker file, so the caller falls back to
      // softer identification signals. Non-Dio failures (TLS, DNS,
      // OOM) are caught below for the same reason.
      return null;
    } catch (_) {
      return null;
    }
  }

  Uri _moonrakerUri(
    String host,
    int port,
    List<String> pathSegments, {
    Map<String, dynamic>? queryParameters,
  }) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    pathSegments: pathSegments,
    queryParameters: queryParameters,
  );

  List<String> _safeConfigPath(String filename) {
    final normalized = filename.replaceAll('\\', '/');
    final parts = normalized.split('/');
    if (normalized.startsWith('/') ||
        parts.isEmpty ||
        parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(filename, 'filename', 'unsafe config path');
    }
    return parts;
  }
}

/// Backwards-compat alias - same service, HTTP-backed today.
typedef MoonrakerWsService = MoonrakerHttpService;
