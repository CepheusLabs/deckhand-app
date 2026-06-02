import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:printdeck_telescope/printdeck_telescope.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _dartDefineOptIn = bool.fromEnvironment(
  'DECKHAND_TELESCOPE_OPT_IN',
  defaultValue: false,
);
const _dartDefineEndpoint = String.fromEnvironment(
  'DECKHAND_TELESCOPE_ENDPOINT',
  defaultValue: '',
);

const _telescopeConfig = TelescopeConfig(
  endpoint: '',
  flushIntervalSeconds: 10,
  maxBatchSize: 50,
  maxQueueSize: 1000,
  autoCapture: false,
  persistQueue: true,
);

final deckhandTelescopeProvider = Provider<TelescopeModule?>((ref) => null);

class DeckhandTelescopeOptions {
  const DeckhandTelescopeOptions({
    required this.enabled,
    required this.endpoint,
  });

  final bool enabled;
  final String endpoint;
}

DeckhandTelescopeOptions resolveDeckhandTelescopeOptions(
  DeckhandSettings settings, {
  bool dartDefineOptIn = _dartDefineOptIn,
  String dartDefineEndpoint = _dartDefineEndpoint,
}) {
  final endpoint = (settings.telescopeEndpoint ?? dartDefineEndpoint).trim();
  final enabled =
      (settings.telescopeOptIn || dartDefineOptIn) && endpoint.isNotEmpty;
  return DeckhandTelescopeOptions(enabled: enabled, endpoint: endpoint);
}

Future<TelescopeModule?> createDeckhandTelescopeModule({
  required DeckhandSettings settings,
  required String deckhandVersion,
  Dio? dio,
  SharedPreferences? prefs,
}) async {
  final options = resolveDeckhandTelescopeOptions(settings);
  if (!options.enabled) return null;

  final resolvedPrefs = prefs ?? await SharedPreferences.getInstance();
  final resolvedDio = dio ?? Dio(BaseOptions(contentType: 'application/json'));
  final client = TelescopeClient(
    config: TelescopeConfig(
      endpoint: options.endpoint,
      flushIntervalSeconds: _telescopeConfig.flushIntervalSeconds,
      maxBatchSize: _telescopeConfig.maxBatchSize,
      maxQueueSize: _telescopeConfig.maxQueueSize,
      autoCapture: _telescopeConfig.autoCapture,
      persistQueue: _telescopeConfig.persistQueue,
      sessionTimeout: _telescopeConfig.sessionTimeout,
    ),
    dio: resolvedDio,
    sessionManager: SessionManager(
      timeout: _telescopeConfig.sessionTimeout,
      prefs: resolvedPrefs,
    ),
    contextCollector: ContextCollector(),
    persistence: Persistence(
      prefs: resolvedPrefs,
      maxQueueSize: _telescopeConfig.maxQueueSize,
    ),
  );
  await client.initialize();

  final packageInfo = await PackageInfo.fromPlatform();
  client.setSuperProperties(<String, dynamic>{
    'app': 'deckhand',
    'deckhand_version': deckhandVersion,
    'app_version': packageInfo.version,
    'app_build': packageInfo.buildNumber,
    'platform': Platform.operatingSystem,
  });

  final module = TelescopeModule(
    adapters: TelescopeAdapters(
      httpClient: _DeckhandTelescopeHttpClient(resolvedDio, options.endpoint),
      authSession: const _AnonymousTelescopeAuthSession(),
      deviceInfo: const _PackageTelescopeDeviceInfo(),
      telemetryPolicy: const _EnabledTelescopeTelemetryPolicy(),
      client: client,
      storage: _SharedPreferencesTelescopeStorage(resolvedPrefs),
    ),
    features: TelescopeFeatureSet.eventsOnly(),
  );
  module.track('deckhand.app.started');
  return module;
}

class _DeckhandTelescopeHttpClient implements TelescopeHttpClient {
  const _DeckhandTelescopeHttpClient(this._dio, this._endpoint);

  final Dio _dio;
  final String _endpoint;

  @override
  Future<void> postEvents(Map<String, Object?> envelope) async {
    await _dio.post<dynamic>('$_endpoint/track', data: envelope);
  }
}

class _AnonymousTelescopeAuthSession implements TelescopeAuthSession {
  const _AnonymousTelescopeAuthSession();

  @override
  String? get actorId => null;

  @override
  Stream<String?> get actorIdChanges => const Stream<String?>.empty();
}

class _PackageTelescopeDeviceInfo implements TelescopeDeviceInfoAdapter {
  const _PackageTelescopeDeviceInfo();

  @override
  Future<Map<String, Object?>> snapshot() async {
    final info = await PackageInfo.fromPlatform();
    return <String, Object?>{
      'app_name': info.appName,
      'app_version': info.version,
      'app_build': info.buildNumber,
      'package_name': info.packageName,
    };
  }
}

class _EnabledTelescopeTelemetryPolicy
    implements TelescopeTelemetryPolicyAdapter {
  const _EnabledTelescopeTelemetryPolicy();

  @override
  bool get isEnabled => true;

  @override
  double get samplingRate => 1.0;

  @override
  Stream<bool> get isEnabledChanges => const Stream<bool>.empty();
}

class _SharedPreferencesTelescopeStorage implements TelescopePersistentStorage {
  const _SharedPreferencesTelescopeStorage(this._prefs);

  final SharedPreferences _prefs;

  @override
  Future<String?> readString(String key) async => _prefs.getString(key);

  @override
  Future<void> writeString(String key, String value) async {
    await _prefs.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _prefs.remove(key);
  }
}
