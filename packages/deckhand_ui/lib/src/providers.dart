import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'widgets/resume_gate.dart' show shouldOfferResume;

/// Runtime theme mode — drives [MaterialApp.themeMode] in
/// [WizardShell]. The initial value is hydrated from the persisted
/// [DeckhandSettings.themeModeName] so a relaunch picks up the
/// user's last choice. Mutations go through [ThemeModeController]
/// which writes the string form back to settings.json before the
/// process is allowed to drift.
///
/// Defaults to [ThemeMode.system] when nothing is persisted yet
/// (fresh install) so first launch follows the OS preference until
/// the user makes an explicit choice.
final themeModeProvider = NotifierProvider<ThemeModeController, ThemeMode>(
  ThemeModeController.new,
);

class ThemeModeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() {
    final settings = ref.read(deckhandSettingsProvider);
    return _decode(settings.themeModeName);
  }

  /// Update the runtime mode and persist it. Save errors are
  /// swallowed (logged at the OS level by [DeckhandSettings.save]'s
  /// caller) — a flaky disk shouldn't block a theme toggle.
  Future<void> set(ThemeMode mode) async {
    state = mode;
    final settings = ref.read(deckhandSettingsProvider);
    settings.themeModeName = _encode(mode);
    try {
      await settings.save();
    } catch (_) {
      // Persistence is best-effort; theme will reset on restart if
      // the disk write failed, which is a tolerable degradation.
    }
  }

  static ThemeMode _decode(String name) => switch (name) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String _encode(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'light',
    ThemeMode.dark => 'dark',
    ThemeMode.system => 'system',
  };
}

/// Single boot-time preflight run. Exposed as a [FutureProvider] so
/// both the [PreflightStrip] (which renders its result) and the
/// welcome screen (which gates the "Start" button on it) consume the
/// same in-flight future — a click on Start while the future is
/// pending should be impossible, not "race the result." Invalidate
/// to force a re-run.
///
/// Surfaces the cached previous result instantly when one exists so
/// the welcome screen doesn't sit on a spinner for 3-5s on every
/// launch. After the live run completes, the cache is overwritten so
/// the next launch reflects whatever the user's environment looks
/// like now (e.g. they revoked the GitHub PAT, plugged in a USB-eMMC
/// adapter, etc.). `ref.keepAlive()` so the in-flight live probe
/// isn't disposed when the welcome screen unmounts mid-launch.
final preflightReportProvider = FutureProvider<DoctorReport>((ref) async {
  ref.keepAlive();
  // Settings is optional — tests don't override it, and a missing
  // provider would otherwise throw via [_throwUnimplemented]. Caching
  // is best-effort; the live probe always runs as the source of
  // truth.
  DeckhandSettings? settings;
  try {
    settings = ref.read(deckhandSettingsProvider);
  } catch (_) {
    settings = null;
  }
  final cached = settings?.lastPreflight;
  // If a cached result exists, fire the live probe in the background
  // and return the cache immediately. The provider exposes only the
  // cached result for THIS read; once the background probe completes,
  // we invalidate the provider so watchers re-pull and see the fresh
  // result. Net effect for the user: instant paint on launch + a
  // silent refresh shortly after.
  if (cached != null) {
    final cachedReport = _decodeCachedReport(cached);
    final s = settings; // capture non-null for the closure
    Future<void>(() async {
      try {
        final fresh = await ref.read(doctorServiceProvider).run();
        if (s != null) {
          s.lastPreflight = _encodeReport(fresh);
          await s.save();
        }
        ref.invalidateSelf();
      } catch (_) {
        // A failed refresh leaves the cache in place — no point
        // overwriting "good last time" with a transient network blip.
      }
    });
    return cachedReport;
  }
  // First-ever launch (or test): no cache, so we have to wait.
  // Persist when possible so the next launch is instant.
  final report = await ref.read(doctorServiceProvider).run();
  if (settings != null) {
    settings.lastPreflight = _encodeReport(report);
    unawaited(settings.save());
  }
  return report;
});

Map<String, dynamic> _encodeReport(DoctorReport r) => {
  'passed': r.passed,
  'report': r.report,
  'at': DateTime.now().toIso8601String(),
  'results': [
    for (final res in r.results)
      {
        'name': res.name,
        'status': switch (res.status) {
          DoctorStatus.pass => 'PASS',
          DoctorStatus.warn => 'WARN',
          DoctorStatus.fail => 'FAIL',
          DoctorStatus.unknown => 'UNKNOWN',
        },
        'detail': res.detail,
      },
  ],
};

DoctorReport _decodeCachedReport(Map<String, dynamic> raw) {
  final results = <DoctorResult>[];
  final list = raw['results'];
  if (list is List) {
    for (final entry in list) {
      if (entry is Map) {
        final m = entry.cast<String, dynamic>();
        results.add(
          DoctorResult(
            name: m['name'] as String? ?? '',
            status: doctorStatusFromString(m['status'] as String? ?? 'unknown'),
            detail: m['detail'] as String? ?? '',
          ),
        );
      }
    }
  }
  return DoctorReport(
    passed: raw['passed'] as bool? ?? false,
    results: results,
    report: raw['report'] as String? ?? '',
  );
}

/// Root providers for the Deckhand UI. Each service is intentionally
/// created via `throwUnimplementedProvider` so the app must override
/// them at bootstrap - there are no "magic defaults."
T _throwUnimplemented<T>(String name) =>
    throw UnimplementedError('Provider $name not overridden at app startup');

final profileServiceProvider = Provider<ProfileService>(
  (_) => _throwUnimplemented('profileServiceProvider'),
);
final sshServiceProvider = Provider<SshService>(
  (_) => _throwUnimplemented('sshServiceProvider'),
);
final flashServiceProvider = Provider<FlashService>(
  (_) => _throwUnimplemented('flashServiceProvider'),
);
final discoveryServiceProvider = Provider<DiscoveryService>(
  (_) => _throwUnimplemented('discoveryServiceProvider'),
);
final moonrakerServiceProvider = Provider<MoonrakerService>(
  (_) => _throwUnimplemented('moonrakerServiceProvider'),
);
final upstreamServiceProvider = Provider<UpstreamService>(
  (_) => _throwUnimplemented('upstreamServiceProvider'),
);
final securityServiceProvider = Provider<SecurityService>(
  (_) => _throwUnimplemented('securityServiceProvider'),
);

/// Sidecar self-diagnostic. Wired by the app to a real
/// [DoctorService] that talks to the sidecar's `doctor.run` JSON-RPC
/// method; the S10 welcome screen + Settings → Run preflight button
/// both call this. See [docs/DOCTOR.md].
final doctorServiceProvider = Provider<DoctorService>(
  (_) => _throwUnimplemented('doctorServiceProvider'),
);

/// Persisted user settings (local-profiles-dir, show-stubs, etc.).
/// The Settings screen calls back into this to persist changes, then
/// the user restarts the app to pick up the new profile source.
final deckhandSettingsProvider = Provider<DeckhandSettings>(
  (_) => _throwUnimplemented('deckhandSettingsProvider'),
);

/// Optional: raw-device writes. Null when elevation is unavailable (e.g.
/// early dev builds before the helper binary ships alongside the app).
final elevatedHelperServiceProvider = Provider<ElevatedHelperService?>(
  (_) => null,
);

/// Optional: stock-config snapshot capture/restore. Null disables
/// the S145 archive step (the install still runs but no host-side
/// tar.gz lands). Production wiring constructs a real
/// [ArchiveService]; tests typically leave this null.
final archiveServiceProvider = Provider<ArchiveService?>((_) => null);

/// Where on the host the snapshot archives land. Production wiring
/// sets this to `<data_dir>/state/snapshots/`; null disables the
/// archive step alongside [archiveServiceProvider].
final snapshotsDirProvider = Provider<String?>((_) => null);

/// Cached host-disk enumeration. Populated lazily by whichever screen
/// asks first (flash-target on freshFlash, emmc-backup on either
/// flow). Once cached, both screens share the same future — no
/// duplicate `listDisks()` call when the user navigates between
/// flash-target → choose-os → flash-confirm → emmc-backup.
///
/// `ref.keepAlive()` so the cache survives navigation between
/// screens that don't watch it (choose-os, flash-confirm). Without
/// it the FutureProvider auto-disposed every time the user moved
/// off flash-target, and the slow PowerShell-driven `listDisks()`
/// call re-ran whenever they came back. Use
/// `ref.invalidate(disksProvider)` for the explicit "Refresh" action.
final disksProvider = FutureProvider<List<DiskInfo>>((ref) async {
  ref.keepAlive();
  return ref.read(flashServiceProvider).listDisks();
});

/// Where on the host full-eMMC `dd` images land when the user clicks
/// "Back up the eMMC now" from S145. Production wiring sets this to
/// `<data_dir>/state/emmc-backups/`. When null, the backup screen
/// shows an "unconfigured" notice instead of silently writing to a
/// surprise path.
final emmcBackupsDirProvider = Provider<String?>((_) => null);

/// Where on the host debug bundles ([BundleBuilder] output) land.
/// Production wiring sets this to `<data_dir>/debug-bundles/`. When
/// null the "Save bundle" path on [DebugBundleScreen] surfaces an
/// "unconfigured" snackbar rather than silently dropping the zip.
final debugBundlesDirProvider = Provider<String?>((_) => null);

/// Build-time deckhand version (CalVer + commit count, e.g.
/// `26.4.25-1731`). Threaded into the wizard controller and the
/// on-printer run-state file so debug bundles and HITL artifacts
/// can be correlated to a release. Default `'dev'` for non-release
/// builds; `app/lib/build_info.dart` overrides it at the binding
/// site via `--dart-define=DECKHAND_VERSION=...`.
final deckhandVersionProvider = Provider<String>((_) => 'dev');

/// On-disk session store. The app overrides this with a real path under
/// the user's data dir. Leaving it null disables resume (tests, dev
/// flows where you always want a fresh wizard).
final wizardStateStoreProvider = Provider<WizardStateStore?>((_) => null);

final wizardControllerProvider = Provider<WizardController>((ref) {
  final controller = WizardController(
    profiles: ref.watch(profileServiceProvider),
    ssh: ref.watch(sshServiceProvider),
    flash: ref.watch(flashServiceProvider),
    discovery: ref.watch(discoveryServiceProvider),
    moonraker: ref.watch(moonrakerServiceProvider),
    upstream: ref.watch(upstreamServiceProvider),
    security: ref.watch(securityServiceProvider),
    elevatedHelper: ref.watch(elevatedHelperServiceProvider),
    archive: ref.watch(archiveServiceProvider),
    snapshotsDir: ref.watch(snapshotsDirProvider),
    deckhandVersion: ref.watch(deckhandVersionProvider),
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Result of probing the printer's snapshot paths for size + presence.
/// `sizes` maps `<absolute path on printer> → bytes`. A path that
/// returned 0 might be empty OR missing — the snapshot screen
/// surfaces "not found" for the latter via the same map.
class SnapshotProbe {
  const SnapshotProbe({required this.sizes, required this.probedAt});
  final Map<String, int> sizes;
  final DateTime probedAt;
}

/// Pre-warmed `du -sk` probe for the snapshot paths. Triggered as
/// soon as a screen accesses the provider — typically the Verify
/// screen kicks it off via [Ref.read] right after SSH connects, so
/// by the time the user reaches Snapshot 5+ screens later the result
/// is already cached.
///
/// Returns null when the probe isn't applicable (no profile loaded,
/// flow isn't stockKeep, no snapshot paths declared, no SSH session).
/// On those paths the snapshot screen renders fine without any size
/// estimate.
///
/// Hard-capped at 15s so a flaky SSH session can't leave the screen
/// spinning forever; on timeout the future completes with a [SnapshotProbe]
/// carrying the empty sizes map and the probe error becomes a banner
/// on the screen.
final snapshotProbeProvider = FutureProvider<SnapshotProbe?>((ref) async {
  // Watch wizard state so the probe re-runs if the user reconnects
  // SSH (which produces a different sshHost / session).
  ref.watch(wizardStateProvider);
  // Pre-warm pattern: ChoosePath fires this provider via [Ref.read] and
  // then immediately navigates away. Without [keepAlive], that read has
  // no listener by the time the probe completes — Riverpod disposes the
  // provider and throws the result away. When SnapshotScreen 5+ screens
  // later watches it, the future restarts from zero and the user sees
  // "pending" instead of the cached estimate the pre-warm was supposed
  // to deliver. Keeping the result alive lets the provider live across
  // route transitions until the wizard state actually changes.
  ref.keepAlive();
  final controller = ref.read(wizardControllerProvider);
  final profile = controller.profile;
  if (profile == null) return null;
  if (controller.state.flow != WizardFlow.stockKeep) return null;
  final paths = profile.stockOs.snapshotPaths;
  if (paths.isEmpty) return null;
  final session = controller.sshSession;
  if (session == null) return null;

  final ssh = ref.read(sshServiceProvider);
  final sizes = await ssh
      .duPaths(session, paths.map((p) => p.path).toList())
      .timeout(const Duration(seconds: 15));
  return SnapshotProbe(sizes: sizes, probedAt: DateTime.now());
});

/// Snapshot the welcome screen reads to render the "RESUME" panel
/// from the design language (right-hand card on S10). Loaded once
/// per launch from the [wizardStateStoreProvider]; null when no
/// store is wired (tests), no snapshot on disk, or the snapshot is
/// indistinguishable from a fresh-launch state (welcome step + no
/// profile id — see [shouldOfferResume]).
///
/// `savedAt` is the on-disk file's `mtime`, used to render the
/// "2 hr ago" relative-time IdTag in the design. Falls back to the
/// current time when stat fails (in-memory store, mocked tests) so
/// the panel still renders rather than disappearing.
///
/// Invalidate after a Resume action so the panel disappears (the
/// snapshot is now consumed; rendering a stale "in-progress" card
/// when the user has already restored is misleading).
class SavedWizardSnapshot {
  const SavedWizardSnapshot({required this.state, required this.savedAt});
  final WizardState state;
  final DateTime savedAt;
}

final savedWizardSnapshotProvider = FutureProvider<SavedWizardSnapshot?>((
  ref,
) async {
  ref.keepAlive();
  final store = ref.read(wizardStateStoreProvider);
  if (store == null) return null;
  final state = await store.load();
  if (!shouldOfferResume(state)) return null;
  // Prefer the on-disk mtime so "X ago" reflects when the user
  // actually paused. Skip the stat entirely for in-memory stores
  // (path '<memory>') and any path that doesn't resolve — File.stat
  // on those is well-defined to throw, but the throw still costs
  // a frame in widget tests and we have a perfectly good fallback.
  //
  // Defensive: `(await f.stat()).modified` can return
  // `DateTime.fromMillisecondsSinceEpoch(0)` even when `exists()`
  // returns true — observed in the Windows desktop runner for the
  // wizard_session.json path. The standalone dart-cli stat call
  // on the same file returns the real mtime, but the Flutter
  // process gets the not-found sentinel, leaking through to the
  // UI as "Dec 31 1969" on the welcome resume panel. Treat any
  // stat result at-or-below epoch 0 as "no info" and fall through
  // to the now-fallback so the panel always renders a sensible
  // timestamp.
  DateTime savedAt = DateTime.now();
  if (store.path != '<memory>') {
    try {
      final f = File(store.path);
      if (await f.exists()) {
        final stat = await f.stat();
        if (stat.modified.millisecondsSinceEpoch > 0) {
          savedAt = stat.modified;
        }
      }
    } catch (_) {
      // Stat failure is non-load-bearing — the panel still renders
      // with the now-fallback timestamp.
    }
  }
  return SavedWizardSnapshot(state: state!, savedAt: savedAt);
});

/// Predicate for "is this state worth persisting." A state with no
/// profile id and no decisions is just the initial chrome — saving
/// it would WIPE whatever resume snapshot is on disk before the
/// user has committed to anything new. Concretely: the chrome
/// (titlebar/sidenav) watches `wizardStateProvider` on every screen,
/// so the very first yield happens at app boot with `controller.state
/// == WizardState.initial()`. Without this guard, every launch
/// overwrites the saved snapshot with empty state and the welcome
/// resume panel disappears.
///
/// "Meaningful progress" = profileId set OR decisions present. The
/// router-listener-driven currentStep updates alone don't count —
/// just navigating doesn't mean the user wants their old session
/// thrown away.
bool isPersistableWizardState(WizardState s) {
  return s.profileId.isNotEmpty || s.decisions.isNotEmpty;
}

/// Live wizard state stream. Also *persists* on every change when a
/// [wizardStateStoreProvider] is configured, so a crash mid-wizard
/// leaves a resumable snapshot on disk.
final wizardStateProvider = StreamProvider<WizardState>((ref) async* {
  final controller = ref.watch(wizardControllerProvider);
  final store = ref.watch(wizardStateStoreProvider);
  yield controller.state;
  if (store != null && isPersistableWizardState(controller.state)) {
    // Fire-and-forget; save errors are logged and ignored so a disk
    // issue never blocks the wizard from advancing.
    unawaited(store.save(controller.state));
  }
  await for (final _ in controller.events) {
    yield controller.state;
    if (store != null && isPersistableWizardState(controller.state)) {
      unawaited(store.save(controller.state));
    }
  }
});
