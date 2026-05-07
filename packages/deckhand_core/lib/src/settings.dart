import 'dart:convert';
import 'dart:io';

/// User preferences persisted to `settings.json` in Deckhand's data dir.
/// Schema is intentionally loose (JSON-backed) - we'll tighten as
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

  /// Recently-used SSH connection targets, surfaced on the Connect
  /// screen's Saved tab so the user doesn't have to retype an IP for
  /// every relaunch. Stored as a list (NOT a set) because order
  /// matters — `recordSavedHost` MRU-bumps the entry, and the UI
  /// renders them in that order.
  List<SavedHost> get savedHosts {
    final raw = _values['saved_hosts'];
    if (raw is! List) return const [];
    final out = <SavedHost>[];
    for (final entry in raw) {
      if (entry is Map) {
        try {
          out.add(SavedHost.fromJson(entry.cast<String, dynamic>()));
        } catch (_) {
          // Skip malformed entries silently — a single bad row
          // shouldn't blank the whole list. The next save() pass
          // rewrites the file with only the valid rows.
        }
      }
    }
    return out;
  }

  set savedHosts(List<SavedHost> hosts) {
    _values['saved_hosts'] = [for (final h in hosts) h.toJson()];
  }

  /// Insert-or-update [h] at the head of [savedHosts] (MRU). Entries
  /// are deduped by `(host, user)` so reconnecting to the same
  /// printer with the same login bumps the row rather than
  /// duplicating it. Capped at 10 to keep the Saved tab scannable;
  /// older rows roll off.
  void recordSavedHost(SavedHost h) {
    final list = savedHosts.toList();
    list.removeWhere(
      (e) =>
          e.host.toLowerCase() == h.host.toLowerCase() &&
          e.user.toLowerCase() == h.user.toLowerCase(),
    );
    list.insert(0, h);
    while (list.length > 10) {
      list.removeLast();
    }
    savedHosts = list;
  }

  void forgetSavedHost({required String host, required String user}) {
    final list = savedHosts.toList()
      ..removeWhere(
        (e) =>
            e.host.toLowerCase() == host.toLowerCase() &&
            e.user.toLowerCase() == user.toLowerCase(),
      );
    savedHosts = list;
  }

  bool get showStubProfiles => _values['show_stub_profiles'] == true;
  set showStubProfiles(bool v) => _values['show_stub_profiles'] = v;

  bool get useEdgeProfileChannel => _values['use_edge_profile_channel'] == true;
  set useEdgeProfileChannel(bool v) => _values['use_edge_profile_channel'] = v;

  /// Absolute path to a locally-checked-out copy of `deckhand-profiles`.
  /// When set, the profile service reads profiles from this directory
  /// instead of fetching them from GitHub. Useful for profile authoring.
  /// Null / empty string means "fetch from GitHub".
  String? get localProfilesDir {
    final v = _values['local_profiles_dir'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  set localProfilesDir(String? v) {
    if (v == null || v.trim().isEmpty) {
      _values.remove('local_profiles_dir');
    } else {
      _values['local_profiles_dir'] = v.trim();
    }
  }

  /// How many days old a `.deckhand-pre-*` backup has to be before the
  /// Verify screen's "Prune" action removes it. Default 30.
  int get pruneOlderThanDays {
    final v = _values['prune_older_than_days'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 30;
  }

  set pruneOlderThanDays(int v) =>
      _values['prune_older_than_days'] = v < 1 ? 1 : v;

  /// When true, prune leaves the newest snapshot per target alone even
  /// if it's old enough to remove, so a catastrophic mistake always
  /// has at least one rollback path.
  bool get pruneKeepNewestPerTarget {
    final v = _values['prune_keep_newest_per_target'];
    return v is bool ? v : true; // default: safe (keep one)
  }

  set pruneKeepNewestPerTarget(bool v) =>
      _values['prune_keep_newest_per_target'] = v;

  /// Dry-run mode. When enabled, every destructive side effect is
  /// logged but not executed: disk writes, remote `sudo` commands,
  /// file mutations, firmware fetches. The wizard still walks the
  /// user through the full flow so authors can test a profile against
  /// a real printer without risk.
  ///
  /// Exposed as a setting (not just an env var) so QA can leave it on
  /// by default on a bring-up laptop.
  bool get dryRun {
    final v = _values['dry_run'];
    return v is bool ? v : false;
  }

  set dryRun(bool v) => _values['dry_run'] = v;

  /// Developer mode. When enabled, the UI prefers raw/internal
  /// diagnostics over user-facing summaries: step ids, exact log
  /// strings, paths, and other details useful while debugging a
  /// profile or Deckhand itself. Default false.
  bool get developerMode {
    final v = _values['developer_mode'];
    return v is bool ? v : false;
  }

  set developerMode(bool v) => _values['developer_mode'] = v;

  /// When true, every flash run reads the disk back after writing and
  /// compares the SHA256 against the source image. Adds 30-90 seconds
  /// per gigabyte of image size to the flash phase but catches
  /// silently-bad writes (cheap USB adapters, marginal eMMCs). Default
  /// true — opting out is a performance/risk trade-off the user makes
  /// explicitly in Settings.
  bool get verifyAfterWrite {
    final v = _values['verify_after_write'];
    return v is bool ? v : true;
  }

  set verifyAfterWrite(bool v) => _values['verify_after_write'] = v;

  /// Days to retain downloaded OS images and profile checkouts in the
  /// cache directory before the wizard's idle-cleanup pass evicts
  /// them. 0 disables cleanup (keep forever). Default 30, which keeps
  /// a typical reinstall fast without letting the cache grow
  /// unboundedly.
  int get cacheRetentionDays {
    final v = _values['cache_retention_days'];
    if (v is int) return v;
    if (v is num) return v.toInt();
    return 30;
  }

  set cacheRetentionDays(int v) =>
      _values['cache_retention_days'] = v < 0 ? 0 : v;

  /// Persisted UI theme mode. Stored as a string so the settings
  /// file stays Flutter-free (`deckhand_core` is pure Dart so the
  /// HITL driver can compile against it without pulling in
  /// `package:flutter`). Valid values are `'system' | 'light' |
  /// 'dark'`; anything else (including null/missing) is treated as
  /// `'system'` by the consumer.
  String get themeModeName {
    final v = _values['theme_mode'];
    if (v is String && (v == 'system' || v == 'light' || v == 'dark')) {
      return v;
    }
    return 'system';
  }

  set themeModeName(String v) {
    if (v == 'system' || v == 'light' || v == 'dark') {
      _values['theme_mode'] = v;
    }
  }

  /// Preferred UI locale as a BCP-47 code (e.g. `en`, `es`). Null
  /// means "follow the OS locale, falling back to English". The
  /// settings screen exposes a picker; main.dart applies the choice
  /// before runApp via Slang's `LocaleSettings.setLocale`.
  String? get preferredLocale {
    final v = _values['preferred_locale'];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    return null;
  }

  set preferredLocale(String? v) {
    if (v == null || v.trim().isEmpty) {
      _values.remove('preferred_locale');
    } else {
      _values['preferred_locale'] = v.trim();
    }
  }

  /// Last window geometry — width, height, x, y. Persisted on every
  /// move/resize so the next launch lands on the same monitor and
  /// size the user left it on. Returns null when no previous launch
  /// has saved one.
  WindowGeometry? get windowGeometry {
    final raw = _values['window_geometry'];
    if (raw is! Map) return null;
    final width = (raw['width'] as num?)?.toDouble();
    final height = (raw['height'] as num?)?.toDouble();
    final x = (raw['x'] as num?)?.toDouble();
    final y = (raw['y'] as num?)?.toDouble();
    if (width == null || height == null) return null;
    return WindowGeometry(width: width, height: height, x: x, y: y);
  }

  set windowGeometry(WindowGeometry? g) {
    if (g == null) {
      _values.remove('window_geometry');
      return;
    }
    _values['window_geometry'] = <String, dynamic>{
      'width': g.width,
      'height': g.height,
      if (g.x != null) 'x': g.x,
      if (g.y != null) 'y': g.y,
    };
  }

  /// Last successful preflight (`doctor.run`) report, persisted so a
  /// fresh launch can paint the cached pass/fail state instantly while
  /// a fresh probe runs in the background. The shape mirrors what the
  /// sidecar returns: `{passed, results: [{name, status, detail}], report,
  /// at}`. `at` is the wall-clock time the cache was written, used to
  /// gate "is this fresh enough to skip the live probe?" decisions in
  /// the future. Untyped Map so deckhand_core stays flutter-free.
  Map<String, dynamic>? get lastPreflight {
    final raw = _values['last_preflight'];
    if (raw is Map) return raw.cast<String, dynamic>();
    return null;
  }

  set lastPreflight(Map<String, dynamic>? v) {
    if (v == null) {
      _values.remove('last_preflight');
    } else {
      _values['last_preflight'] = v;
    }
  }

  Future<void> save() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(_values),
    );
  }
}

/// Persistent window size + position. `x`/`y` are nullable so a
/// first-time saver that knows size but not position (which the
/// platform may not expose) can still record something useful.
class WindowGeometry {
  const WindowGeometry({
    required this.width,
    required this.height,
    this.x,
    this.y,
  });

  final double width;
  final double height;
  final double? x;
  final double? y;

  @override
  String toString() =>
      'WindowGeometry(${width}x$height @ ${x ?? "?"},${y ?? "?"})';
}

/// One row of the Connect screen's "Saved" tab. Captures the (host,
/// port, user) tuple the user successfully connected to plus the
/// timestamp of that connect, so the UI can render "last used 3d
/// ago" against each entry.
///
/// Persisted via [DeckhandSettings.savedHosts]. NOT a credentials
/// store — passwords and SSH keys live in the OS secure store via
/// [SecurityService], not here.
class SavedHost {
  const SavedHost({
    required this.host,
    required this.port,
    required this.user,
    this.lastUsed,
  });

  final String host;
  final int port;
  final String user;
  final DateTime? lastUsed;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'host': host,
    'port': port,
    'user': user,
    if (lastUsed != null) 'last_used': lastUsed!.toIso8601String(),
  };

  factory SavedHost.fromJson(Map<String, dynamic> j) {
    final lastUsedRaw = j['last_used'];
    DateTime? lastUsed;
    if (lastUsedRaw is String) {
      try {
        lastUsed = DateTime.parse(lastUsedRaw);
      } catch (_) {
        lastUsed = null;
      }
    }
    final port = (j['port'] is num) ? (j['port'] as num).toInt() : 22;
    return SavedHost(
      host: (j['host'] as String?) ?? '',
      port: port,
      user: (j['user'] as String?) ?? '',
      lastUsed: lastUsed,
    );
  }

  @override
  String toString() => '$user@$host:$port';
}
