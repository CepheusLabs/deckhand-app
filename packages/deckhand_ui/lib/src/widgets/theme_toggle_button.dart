import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';

/// Compact icon button that cycles the runtime [ThemeMode] through
/// system → light → dark → system. Lives in the sidenav foot so it's
/// reachable from any wizard screen without diving into Settings.
///
/// Why three states (and not just light/dark): once a user toggles
/// off `system`, "follow the OS preference" needs to stay reachable.
/// A two-way light↔dark toggle traps the user. The cycle keeps
/// system as a permanent option.
///
/// The icon reflects the *current* state — auto/sun/moon — and the
/// tooltip names the current state and what clicking does next.
/// Toggling routes through [ThemeModeController.set] which persists
/// the choice to `settings.json`.
class ThemeToggleButton extends ConsumerWidget {
  const ThemeToggleButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DeckhandTokens.of(context);
    final mode = ref.watch(themeModeProvider);
    final next = _next(mode);
    final iconData = switch (mode) {
      ThemeMode.system => Icons.brightness_auto_outlined,
      ThemeMode.light => Icons.light_mode_outlined,
      ThemeMode.dark => Icons.dark_mode_outlined,
    };
    final tooltipMessage = switch (mode) {
      ThemeMode.system => 'Theme: system · click for light',
      ThemeMode.light => 'Theme: light · click for dark',
      ThemeMode.dark => 'Theme: dark · click for system',
    };
    return Tooltip(
      message: tooltipMessage,
      child: InkWell(
        onTap: () {
          ref.read(themeModeProvider.notifier).set(next);
        },
        borderRadius: BorderRadius.circular(DeckhandTokens.r1),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            iconData,
            size: 14,
            color: tokens.text3,
          ),
        ),
      ),
    );
  }

  ThemeMode _next(ThemeMode current) => switch (current) {
        ThemeMode.system => ThemeMode.light,
        ThemeMode.light => ThemeMode.dark,
        ThemeMode.dark => ThemeMode.system,
      };
}
