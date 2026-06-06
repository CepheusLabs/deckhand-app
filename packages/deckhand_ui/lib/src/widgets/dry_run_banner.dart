import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';

import '../providers.dart';

/// Persistent banner at the top of every wizard screen when the user
/// has dry-run mode enabled. The goal is to make it impossible to
/// forget the setting is on — especially during long flows where a
/// developer might switch tabs and come back expecting a real install.
///
/// Rebuilt on forge's [ClBanner] (warn kind) — keeps the explicit
/// flask icon so screen readers and the existing visual contract stay
/// intact, and wraps the whole thing in a labeled live region so
/// assistive tech announces the state when dry-run is toggled.
class DryRunBanner extends ConsumerWidget {
  const DryRunBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(deckhandSettingsProvider);
    if (!settings.dryRun) return const SizedBox.shrink();

    return Semantics(
      liveRegion: true,
      container: true,
      label:
          'Dry-run mode enabled. No destructive operations will be executed.',
      child: const ExcludeSemantics(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: ClBanner(
            kind: ClBannerKind.warn,
            icon: Icons.science_outlined,
            title:
                'Dry-run mode — no disk writes or remote mutations will happen.',
          ),
        ),
      ),
    );
  }
}
