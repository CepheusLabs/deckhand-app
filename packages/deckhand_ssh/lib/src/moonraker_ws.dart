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
    final res = await _dio.get<Map<String, dynamic>>(
      'http://$host:$port/printer/info',
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
    final res = await _dio.get<Map<String, dynamic>>(
      'http://$host:$port/printer/objects/query',
      queryParameters: {'print_stats': ''},
    );
    final status = (res.data?['result'] as Map?)?['status'] as Map?;
    final stats = status?['print_stats'] as Map?;
    final state = stats?['state'] as String?;
    return state == 'printing' || state == 'paused';
  }

  @override
  Future<List<String>> listObjects({
    required String host,
    int port = 7125,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      'http://$host:$port/printer/objects/list',
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
      final res = await _dio.get<String>(
        'http://$host:$port/server/files/config/$filename',
        options: Options(responseType: ResponseType.plain),
      );
      return res.data;
    } on DioException catch (e) {
      // 404 when the file doesn't exist; anything else is either
      // Moonraker not responding or a permission issue - both are
      // treated the same (no identification signal).
      if (e.response?.statusCode == 404) return null;
      return null;
    } catch (_) {
      return null;
    }
  }
}

/// Backwards-compat alias - same service, HTTP-backed today.
typedef MoonrakerWsService = MoonrakerHttpService;
