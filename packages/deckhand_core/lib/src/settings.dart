import 'dart:convert';
import 'dart:io';

/// User preferences persisted to `settings.json` in Deckhand's data dir.
/// Schema is intentionally loose (JSON-backed) — we'll tighten as
/// real settings land.
class DeckhandSettings {
  DeckhandSettings({required this.path, Map<String, dynamic>? initial})
      : _values = Map.of(initial ?? const {});

  final String path;
  final Map<String, dynamic> _values;

  static Future<DeckhandSettings> load(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      return DeckhandSettings(path: path);
    }
    try {
      final text = await file.readAsString();
      final json = jsonDecode(text);
      return DeckhandSettings(
        path: path,
        initial: (json as Map).cast<String, dynamic>(),
      );
    } catch (_) {
      return DeckhandSettings(path: path);
    }
  }

  T? get<T>(String key, [T? fallback]) {
    final v = _values[key];
    if (v is T) return v;
    return fallback;
  }

  void set<T>(String key, T value) {
    _values[key] = value;
  }

  Set<String> get allowedHosts {
    final raw = _values['allowed_hosts'];
    if (raw is List) return raw.cast<String>().toSet();
    return <String>{};
  }

  set allowedHosts(Set<String> hosts) {
    _values['allowed_hosts'] = hosts.toList();
  }

  bool get showStubProfiles => _values['show_stub_profiles'] == true;
  set showStubProfiles(bool v) => _values['show_stub_profiles'] = v;

  bool get useEdgeProfileChannel => _values['use_edge_profile_channel'] == true;
  set useEdgeProfileChannel(bool v) => _values['use_edge_profile_channel'] = v;

  Future<void> save() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(_values));
  }
}
