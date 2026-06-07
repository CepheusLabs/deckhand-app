import 'package:cl_updater/cl_updater.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Trusted Ed25519 update public key(s) — `current` (and later `next`) — from the
/// contracts registry (printdeck-ecosystem-contracts → update-distribution). The
/// same `current` key MUST be set as `SUPublicEDKey` in macos/Runner/Info.plist.
const List<String> kDeckhandUpdatePublicKeys = <String>[
  'QnZ88k2M321Cf/vV04KfQAL0tSgLwT16SoGRmukAL/o=',
];

/// Deckhand's shared cl_updater [Updater] (consumed like forge). macOS/Windows →
/// Sparkle adapter; Linux-AppImage → in-app self-update.
Future<Updater> createDeckhandUpdater() => bootstrapUpdater(
      product: 'deckhand',
      trustedPublicKeysB64: kDeckhandUpdatePublicKeys,
    );

/// Riverpod handle, overridden with the real instance in the root `ProviderScope`.
/// Mount the optional banner via:
///   Consumer(builder: (_, ref, __) => UpdateBanner(updater: ref.watch(deckhandUpdaterProvider)))
final Provider<Updater> deckhandUpdaterProvider = Provider<Updater>(
  (ref) => throw UnimplementedError(
    'deckhandUpdaterProvider must be overridden in the root ProviderScope',
  ),
);
