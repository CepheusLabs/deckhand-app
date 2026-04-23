import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:deckhand_discovery/deckhand_discovery.dart';
import 'package:deckhand_flash/deckhand_flash.dart';
import 'package:deckhand_profiles/deckhand_profiles.dart';
import 'package:deckhand_ssh/deckhand_ssh.dart';
import 'package:deckhand_ui/deckhand_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

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

  // Settings drives the local-profiles-dir override (and other toggles).
  // Loaded once at boot; the Settings screen calls back into it to
  // persist changes.
  final settings = await DeckhandSettings.load(paths.settingsFile);

  // Sidecar binary ships alongside the Flutter executable.
  final sidecar = SidecarClient(binaryPath: _resolveSidecarPath());
  try {
    await sidecar.start();
  } catch (e, st) {
    debugPrint('Sidecar failed to start: $e\n$st');
  }

  // Env var still takes precedence over settings (developer override
  // that's more visible than a JSON file).
  final envLocalDir = Platform.environment['DECKHAND_PROFILES_LOCAL'];
  final localProfilesDir = envLocalDir != null && envLocalDir.trim().isNotEmpty
      ? envLocalDir
      : settings.localProfilesDir;

  runApp(
    ProviderScope(
      overrides: [
        deckhandSettingsProvider.overrideWithValue(settings),
        profileServiceProvider.overrideWithValue(
          SidecarProfileService(
            sidecar: sidecar,
            paths: paths,
            localProfilesDir: localProfilesDir,
          ),
        ),
        sshServiceProvider.overrideWithValue(DartsshService()),
        flashServiceProvider.overrideWithValue(SidecarFlashService(sidecar)),
        discoveryServiceProvider.overrideWithValue(BonsoirDiscoveryService()),
        moonrakerServiceProvider.overrideWithValue(MoonrakerHttpService()),
        upstreamServiceProvider.overrideWithValue(
          SidecarUpstreamService(sidecar: sidecar),
        ),
        securityServiceProvider.overrideWithValue(DefaultSecurityService()),
        elevatedHelperServiceProvider.overrideWithValue(
          ProcessElevatedHelperService(helperPath: _resolveElevatedHelperPath()),
        ),
      ],
      child: const WizardShell(),
    ),
  );
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
