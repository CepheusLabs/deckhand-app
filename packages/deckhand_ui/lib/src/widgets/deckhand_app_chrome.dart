import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';
import 'package:printdeck_product_platform/printdeck_product_platform.dart';

import '../providers.dart';
import 'deckhand_footbar.dart';
import 'deckhand_logo.dart';

/// App-level chrome wrapper — frames every routed screen with a
/// slim command bar (brand + nav + global affordances) and the bottom
/// footbar (run metadata). Inserted via a [ShellRoute] in
/// [buildDeckhandRouter] so [GoRouterState.of] resolves below it.
///
/// The wizard's primary navigation lives in the top stepper
/// ([DeckhandStepper] inside the screen scaffolds) — the chrome itself
/// carries only the cross-cutting nav (Printers / Manage). A wide left
/// rail expressing the same hierarchy as the stepper read as the
/// "real" nav and confused the user, and slimming it to brand-only
/// left an empty 220px gutter that looked broken. A short command bar
/// fits both jobs: brand on the left, cross-cutting nav in the middle,
/// global affordances (Settings + theme) on the right.
///
/// Wires:
///  * Wizard state → printer label (command bar subtitle), host (footbar).
///  * Sidecar version → footbar.
class DeckhandAppChrome extends ConsumerWidget {
  const DeckhandAppChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = context.brandColors;
    final wizard = ref.watch(wizardStateProvider).valueOrNull;
    final version = ref.watch(deckhandVersionProvider);

    final printerLabel = _printerLabel(wizard);
    final hostLabel = wizard?.sshHost;

    return ProductShellFrame.slotted(
      backgroundColor: brand.bg,
      wrapBodyInSelectionArea: false,
      topBarBuilder: (context, shell) {
        return _CommandBar(printerLabel: printerLabel);
      },
      body: child,
      bottomBarBuilder: (context, shell) {
        return DeckhandFootbar(
          items: [
            DeckhandFootbarItem(label: 'sidecar', value: version),
            if (wizard != null && wizard.profileId.isNotEmpty)
              DeckhandFootbarItem(label: 'profile', value: wizard.profileId),
          ],
          trailing: [
            if (hostLabel != null)
              DeckhandFootbarItem(label: 'host', value: hostLabel),
          ],
        );
      },
    );
  }

  String? _printerLabel(WizardState? state) {
    if (state == null) return null;
    if (state.profileId.isEmpty) return null;
    return state.profileId;
  }
}

/// The forge [ClCommandBar] wired to Deckhand's brand mark, nav, and
/// global affordances. Stays put across every routed screen so a user
/// always has Settings and the theme toggle one click away.
class _CommandBar extends ConsumerWidget {
  const _CommandBar({required this.printerLabel});

  final String? printerLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brand = context.brandColors;
    // Resolve the active location so the nav pills can light up. The
    // command bar lives below the ShellRoute, so GoRouterState resolves
    // here; degrade gracefully if it ever renders without a router
    // ancestor (e.g. an isolated widget test).
    String location;
    try {
      location = GoRouterState.of(context).uri.path;
    } catch (_) {
      location = '';
    }
    final mode = ref.watch(themeModeProvider);

    return ClCommandBar(
      leading: const DeckhandLogo(size: 18),
      title: 'Deckhand',
      subtitle: printerLabel,
      nav: [
        ClNavPill(
          label: 'Printers',
          icon: Icons.precision_manufacturing_outlined,
          selected: location.startsWith('/printers'),
          onPressed: () => context.go('/printers'),
        ),
        if (printerLabel != null)
          ClNavPill(
            label: 'Manage',
            icon: Icons.tune,
            selected: location.startsWith('/manage'),
            onPressed: () => context.go('/manage'),
          ),
      ],
      actions: [
        Tooltip(
          message: 'Settings',
          child: IconButton(
            // push (not go) so the prior wizard route stays on the stack
            // and the Settings screen's Back button can pop back to it.
            onPressed: () => context.push('/settings'),
            icon: Icon(Icons.settings_outlined, size: 18, color: brand.ink2),
            visualDensity: VisualDensity.compact,
            splashRadius: 18,
          ),
        ),
        ClThemeToggle(
          value: mode,
          onChanged: (m) => ref.read(themeModeProvider.notifier).set(m),
          size: ClThemeToggleSize.sm,
        ),
      ],
    );
  }
}
