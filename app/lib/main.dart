import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_discovery/deckhand_discovery.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:deckhand_profiles/deckhand_profiles.dart';
import 'package:deckhand_ssh/deckhand_ssh.dart';
import 'package:deckhand_ui/deckhand_ui.dart';
import 'package:deckhand_ui/trust_keyring_asset.dart';

import 'build_info.dart' as build_info;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'window_geometry_observer.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  const isReleaseBuild = bool.fromEnvironment(
    'dart.vm.product',
    defaultValue: false,
  );
  String? startupLogsDir;
  SidecarSupervisor? startedSidecar;

  try {
    await windowManager.ensureInitialized();

    // Per-user data directories.
    final appDataDir = await getApplicationSupportDirectory();
    final cacheDirBase = await getApplicationCacheDirectory();
    final paths = DeckhandPaths(
      cacheDir: p.join(cacheDirBase.path, 'Deckhand'),
      stateDir: p.join(appDataDir.path, 'state'),
      logsDir: p.join(appDataDir.path, 'logs'),
      settingsFile: p.join(appDataDir.path, 'settings.json'),
    );
    await Directory(paths.cacheDir).create(recursive: true);
    await Directory(paths.stateDir).create(recursive: true);
    await Directory(paths.logsDir).create(recursive: true);
    startupLogsDir = paths.logsDir;

    // Settings drives the local-profiles-dir override (and other toggles).
    // Loaded once at boot; the Settings screen calls back into it to
    // persist changes.
    final settings = await DeckhandSettings.load(paths.settingsFile);

    // Apply locale before the first build. `LocaleSettings.useDeviceLocale()`
    // picks up the OS-reported locale; an explicit override from Settings
    // wins. Slang's `fallback_strategy: base_locale` means a missing
    // string in es/etc. falls back to en at runtime, so a partial
    // translation is safe.
    if (settings.preferredLocale != null) {
      final code = settings.preferredLocale!;
      final parsed = AppLocaleUtils.parse(code);
      LocaleSettings.setLocale(parsed);
    } else {
      LocaleSettings.useDeviceLocale();
    }

    // Apply persisted window geometry before the first frame so the
    // window doesn't "jump" from a default size to the saved size.
    // Geometry is restored only on desktop (skipped on mobile, which
    // ignores window-manager calls anyway).
    await applyPersistedWindowGeometry(settings);

    // Wizard-state persistence. Snapshots let the user reopen the app
    // after a crash and land on the screen they were on, with every
    // previous decision intact. Secrets are NEVER serialized (see
    // WizardState.toJson); tokens and SSH passwords live only in RAM.
    //
    // Save errors land in <logsDir>/wizard_state_errors.log so a flaky
    // disk surfaces somewhere instead of being swallowed. The same
    // sink also receives window-geometry persistence failures.
    final persistenceLog = File(
      p.join(paths.logsDir, 'persistence_errors.log'),
    );
    void persistenceErrorSink(Object e, StackTrace st) {
      try {
        persistenceLog.writeAsStringSync(
          '${DateTime.now().toIso8601String()} $e\n$st\n',
          mode: FileMode.append,
        );
      } on Object {
        // The error sink itself failing means we can't durably log
        // the original failure either; that's beyond our reach.
      }
    }

    final wizardStore = WizardStateStore(
      path: p.join(paths.stateDir, 'wizard_session.json'),
      errorSink: persistenceErrorSink,
    );

    // Sidecar binary ships alongside the Flutter executable. A failed
    // start is a hard failure — every service override below expects a
    // live sidecar, and silently continuing with a dead one produced
    // cryptic "operation_id timeout" errors halfway through the wizard.
    // Mount a minimal error screen instead of runApp so the user sees
    // *why* Deckhand can't proceed.
    //
    // The supervisor (rather than a raw SidecarClient) is what every
    // adapter sees. It auto-respawns the sidecar on retrySafe-method
    // crashes (one retry), surfaces typed errors for stateful methods,
    // and latches after the destructive flash path's pre-flight, so a
    // mid-call segfault doesn't leave the wizard wedged. See
    // [docs/IPC.md#sidecar-lifecycle-and-crash-recovery].
    final sidecar = SidecarSupervisor(
      spawn: () => SidecarClient(binaryPath: _resolveSidecarPath()),
    );
    startedSidecar = sidecar;
    try {
      await sidecar.start();
    } catch (e, st) {
      // Write a crash record to disk so `deckhand-sidecar doctor` can
      // be pointed at it after the fact.
      await writeStartupFailureLog(
        logsDir: paths.logsDir,
        phase: 'sidecar.start failed',
        error: e,
        stackTrace: st,
        metadata: startupDiagnosticMetadata(isReleaseBuild: isReleaseBuild),
      );
      try {
        await sidecar.shutdown();
      } catch (_) {}
      runApp(
        _FatalErrorApp(
          title: 'Sidecar failed to start',
          body:
              'Deckhand could not launch its helper process. This is either '
              'a missing binary next to the app executable, or a corrupted '
              'install. Try reinstalling Deckhand. Details:\n\n$e',
          sidecarPath: _resolveSidecarPath(),
          logsDir: paths.logsDir,
        ),
      );
      return;
    }

    // Env var still takes precedence over settings (developer override
    // that's more visible than a JSON file). For non-release builds we
    // also auto-detect a sibling `deckhand-builds/` checkout next to
    // the running .exe so contributors can edit `profile.yaml` and see
    // the change on next launch without exporting an env var or
    // touching settings.json. Release builds skip the autodetect (a
    // sibling dir on a user's machine could otherwise silently override
    // their pinned profile registry).
    String? autoDetectedDir;
    final productionTrustEnforced = isProductionTrustEnforcedBuild(
      isReleaseBuild: isReleaseBuild,
      isLocalSmokeRelease: build_info.localSmokeRelease,
    );
    final envLocalDir = !productionTrustEnforced
        ? Platform.environment['DECKHAND_PROFILES_LOCAL']
        : null;
    if (!productionTrustEnforced) {
      autoDetectedDir = await _autoDetectLocalProfilesDir();
    }
    final localProfilesDir = !productionTrustEnforced
        ? (envLocalDir != null && envLocalDir.trim().isNotEmpty
              ? envLocalDir
              : (settings.localProfilesDir ?? autoDetectedDir))
        : null;

    // SecurityService is constructed first so the SSH client can share
    // its fingerprint store. Without this shared instance, DartsshService
    // would fall back to accept-all and MITM attacks would not be caught.
    final security = DefaultSecurityService();

    // SSH + archive services share an underlying connection model.
    // The archive service captures the user's S145 stock-config
    // selection into a host-local tar.gz before the install rewrites
    // the printer's config. See docs/WIZARD-FLOW.md (S145-snapshot).
    final sshService = DartsshService(security: security);
    final archiveService = DartsshArchiveService(ssh: sshService);
    final snapshotsDir = p.join(paths.stateDir, 'snapshots');
    await Directory(snapshotsDir).create(recursive: true);
    // Full-eMMC `dd` images land here when the user clicks "Back up the
    // eMMC now" from S145. Kept distinct from the directory-snapshot
    // path so the two are never confused (and so the user can wipe the
    // big images independently of the small per-install configs).
    final emmcBackupsDir = p.join(paths.stateDir, 'emmc-backups');
    await Directory(emmcBackupsDir).create(recursive: true);
    await File(
      p.join(emmcBackupsDir, '.deckhand-emmc-backups-root'),
    ).writeAsString('deckhand-emmc-backups/1\n', flush: true);

    // Bundled profile-trust keyring. See docs/PROFILE-TRUST.md for the
    // rotation/bootstrap model. While the asset is still the dev
    // placeholder we leave `requireSignedTag` off only in dev builds.
    // Release builds fail closed if packaging forgot to replace the
    // placeholder, because profile content drives printer-side shell
    // execution.
    final trustKeyring = await loadBundledTrustKeyring();
    enforceProfileTrustKeyringForBuild(
      isReleaseBuild: productionTrustEnforced,
      trustKeyring: trustKeyring,
    );
    final requireSignedTag = !trustKeyring.isPlaceholder;
    if (trustKeyring.isPlaceholder) {
      persistenceErrorSink(
        StateError(
          'profile-trust keyring is the dev placeholder; signed-tag '
          'verification is OFF. Production builds must replace '
          'packages/deckhand_core/lib/src/trust/keyring.asc.',
        ),
        StackTrace.current,
      );
    }

    // Flash-sentinel writer — the UI persists a sentinel to
    // <data_dir>/state/flash-sentinels/ before launching the elevated
    // helper, and clears it after observing event:done. Sidecar's
    // disks.list joins these onto enumeration results so the UI can
    // surface "interrupted flash" warnings after a crash or power loss.
    final sentinelWriter = FlashSentinelWriter(
      directory: p.join(paths.stateDir, 'flash-sentinels'),
    );

    runApp(
      ProviderScope(
        overrides: [
          deckhandSettingsProvider.overrideWithValue(settings),
          wizardStateStoreProvider.overrideWithValue(wizardStore),
          profileServiceProvider.overrideWithValue(
            SidecarProfileService(
              sidecar: sidecar,
              paths: paths,
              security: security,
              localProfilesDir: localProfilesDir,
              allowLocalProfilesInProduct: build_info.localSmokeRelease,
              trustKeyring: trustKeyring,
              requireSignedTag: requireSignedTag,
            ),
          ),
          sshServiceProvider.overrideWithValue(sshService),
          printerConfigServiceProvider.overrideWithValue(
            SshPrinterConfigService(ssh: sshService),
          ),
          archiveServiceProvider.overrideWithValue(archiveService),
          snapshotsDirProvider.overrideWithValue(snapshotsDir),
          emmcBackupsDirProvider.overrideWithValue(emmcBackupsDir),
          debugBundlesDirProvider.overrideWithValue(
            p.join(paths.stateDir, 'debug-bundles'),
          ),
          deckhandVersionProvider.overrideWithValue(build_info.deckhandVersion),
          flashServiceProvider.overrideWithValue(
            SidecarFlashService(sidecar, dryRun: settings.dryRun),
          ),
          discoveryServiceProvider.overrideWithValue(BonsoirDiscoveryService()),
          moonrakerServiceProvider.overrideWithValue(MoonrakerHttpService()),
          upstreamServiceProvider.overrideWithValue(
            SidecarUpstreamService(sidecar: sidecar, security: security),
          ),
          securityServiceProvider.overrideWithValue(security),
          doctorServiceProvider.overrideWithValue(
            SidecarDoctorService(sidecar: sidecar),
          ),
          elevatedHelperServiceProvider.overrideWithValue(
            settings.dryRun
                ? const DryRunElevatedHelperService()
                : ProcessElevatedHelperService(
                    helperPath: _resolveElevatedHelperPath(),
                    sentinelWriter: sentinelWriter,
                    readOutputRoot: emmcBackupsDir,
                  ),
          ),
        ],
        child: TranslationProvider(
          child: WindowGeometryObserver(
            settings: settings,
            onError: persistenceErrorSink,
            child: const WizardShell(),
          ),
        ),
      ),
    );
  } catch (e, st) {
    try {
      await startedSidecar?.shutdown();
    } catch (_) {}
    final logsDir = startupLogsDir ?? await resolveStartupLogsDirFallback();
    await writeStartupFailureLog(
      logsDir: logsDir,
      phase: 'app.start failed',
      error: e,
      stackTrace: st,
      metadata: startupDiagnosticMetadata(isReleaseBuild: isReleaseBuild),
    );
    runApp(
      _FatalErrorApp(
        title: 'Deckhand failed to start',
        body:
            'Deckhand hit a startup error before the wizard could open. '
            'No profile or disk operation ran.\n\n$e',
        sidecarPath: _resolveSidecarPath(),
        logsDir: logsDir,
      ),
    );
  }
}

String _resolveSidecarPath() {
  final dir = p.dirname(Platform.resolvedExecutable);
  return Platform.isWindows
      ? p.join(dir, 'deckhand-sidecar.exe')
      : p.join(dir, 'deckhand-sidecar');
}

String _resolveElevatedHelperPath() {
  final dir = p.dirname(Platform.resolvedExecutable);
  return Platform.isWindows
      ? p.join(dir, 'deckhand-elevated-helper.exe')
      : p.join(dir, 'deckhand-elevated-helper');
}

/// Walks up from the running executable looking for the contributor's
/// local `deckhand-builds/` checkout. The repo layout is
/// `<root>/installer/deckhand/...` for the main project and
/// `<root>/installer/deckhand-builds/...` for the profiles repo;
/// when the .exe lives at
/// `installer/deckhand/app/build/windows/x64/runner/Debug/deckhand.exe`
/// we walk back until we find a sibling `deckhand-builds/registry.yaml`.
/// Returns null if no checkout is found — the app falls back to the
/// remote profile fetch in that case. Only used in non-release builds.
Future<String?> _autoDetectLocalProfilesDir() async {
  try {
    final exe = Platform.resolvedExecutable;
    var dir = Directory(p.dirname(exe));
    // Cap the walk so a runaway parent traversal can't take seconds.
    for (var i = 0; i < 12; i++) {
      final sibling = Directory(p.join(dir.parent.path, 'deckhand-builds'));
      final registry = File(p.join(sibling.path, 'registry.yaml'));
      if (await registry.exists()) {
        return sibling.path;
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
  } catch (_) {
    // Best-effort dev convenience; never crash startup over it.
  }
  return null;
}

Future<String> resolveStartupLogsDirFallback() async {
  try {
    final appDataDir = await getApplicationSupportDirectory();
    return p.join(appDataDir.path, 'logs');
  } catch (_) {
    final appData = Platform.environment['APPDATA'];
    if (Platform.isWindows && appData != null && appData.trim().isNotEmpty) {
      return p.join(appData, 'CepheusLabs', 'Deckhand', 'logs');
    }
    return p.join(Directory.systemTemp.path, 'Deckhand', 'logs');
  }
}

Future<void> writeStartupFailureLog({
  required String logsDir,
  required String phase,
  required Object error,
  required StackTrace stackTrace,
  Map<String, String> metadata = const {},
}) async {
  try {
    await Directory(logsDir).create(recursive: true);
    final crashFile = File(p.join(logsDir, 'startup_crash.log'));
    final metadataLines = metadata.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    await crashFile.writeAsString(
      '${DateTime.now().toIso8601String()} $phase\n'
      '${metadataLines.isEmpty ? '' : '$metadataLines\n'}'
      '$error\n$stackTrace\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

Map<String, String> startupDiagnosticMetadata({
  required bool isReleaseBuild,
}) => {
  'deckhand_version': build_info.deckhandVersion,
  'build_mode': build_info.describeBuildMode(isReleaseBuild: isReleaseBuild),
  'executable': Platform.resolvedExecutable,
  'sidecar_path': _resolveSidecarPath(),
  'elevated_helper_path': _resolveElevatedHelperPath(),
  'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
};

bool isProductionTrustEnforcedBuild({
  required bool isReleaseBuild,
  required bool isLocalSmokeRelease,
}) {
  return isReleaseBuild && !isLocalSmokeRelease;
}

void enforceProfileTrustKeyringForBuild({
  required bool isReleaseBuild,
  required TrustKeyring trustKeyring,
}) {
  if (isReleaseBuild && trustKeyring.isPlaceholder) {
    throw StateError(
      'Release build cannot start with the placeholder profile-trust '
      'keyring. Replace app/assets/keyring.asc with the production '
      'trusted signing keys before packaging.',
    );
  }
}

/// Shown instead of the wizard when the sidecar refuses to start.
/// Kept inside `main.dart` so it works without any of the service
/// providers being wired up.
class _FatalErrorApp extends StatelessWidget {
  const _FatalErrorApp({
    required this.title,
    required this.body,
    required this.sidecarPath,
    required this.logsDir,
  });

  final String title;
  final String body;
  final String sidecarPath;
  final String logsDir;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Align(
              alignment: Alignment.topLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Icon(
                          Icons.error_outline,
                          size: 32,
                          color: Colors.red,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            title,
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SelectableText(body),
                    const SizedBox(height: 24),
                    Text(
                      'Sidecar expected at:',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    SelectableText(sidecarPath),
                    const SizedBox(height: 12),
                    Text(
                      'Elevated helper expected at:',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    SelectableText(_resolveElevatedHelperPath()),
                    const SizedBox(height: 12),
                    Text(
                      'Startup log:',
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    SelectableText(p.join(logsDir, 'startup_crash.log')),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _openLogsDir(logsDir),
                          icon: const Icon(Icons.folder_open),
                          label: const Text('Open logs'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: diagnosticText),
                          ),
                          icon: const Icon(Icons.copy),
                          label: const Text('Copy diagnostics'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  String get diagnosticText => [
    title,
    '',
    body,
    '',
    'Deckhand version: ${build_info.deckhandVersion}',
    'Sidecar expected at: $sidecarPath',
    'Elevated helper expected at: ${_resolveElevatedHelperPath()}',
    'Startup log: ${p.join(logsDir, 'startup_crash.log')}',
  ].join('\n');

  Future<void> _openLogsDir(String logsDir) async {
    try {
      await Directory(logsDir).create(recursive: true);
      if (Platform.isWindows) {
        await Process.start('explorer.exe', [logsDir]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [logsDir]);
      } else {
        await Process.start('xdg-open', [logsDir]);
      }
    } catch (_) {}
  }
}
