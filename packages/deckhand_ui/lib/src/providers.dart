import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  );
  ref.onDispose(controller.dispose);
  return controller;
});

/// Live wizard state stream that screens watch for rebuilds.
final wizardStateProvider = StreamProvider<WizardState>((ref) async* {
  final controller = ref.watch(wizardControllerProvider);
  yield controller.state;
  await for (final _ in controller.events) {
    yield controller.state;
  }
});
