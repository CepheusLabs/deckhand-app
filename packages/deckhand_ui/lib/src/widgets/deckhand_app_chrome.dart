import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import 'deckhand_footbar.dart';
import 'deckhand_logo.dart';
import 'settings_link_button.dart';
import 'theme_toggle_button.dart';

/// App-level chrome wrapper — frames every routed screen with a
/// slim top bar (brand + global affordances) and the bottom footbar
/// (run metadata). Inserted via a [ShellRoute] in
/// [buildDeckhandRouter] so [GoRouterState.of] resolves below it.
///
/// The wizard's primary navigation lives in the top stepper
/// ([DeckhandStepper] inside [WizardScaffold]) — the chrome itself
/// carries no step list. A wide left rail expressing the same
/// hierarchy as the stepper read as the "real" nav and confused
/// the user, and slimming it to brand-only left an empty 220px
/// gutter that looked broken. A short top bar fits both jobs:
/// brand on the left, global affordances (Settings + theme) on
/// the right, then the screen content fills the rest.
///
/// Wires:
///  * Wizard state → printer label (top bar subtitle), host (footbar).
///  * Sidecar version → top bar + footbar.
class DeckhandAppChrome extends ConsumerWidget {
  const DeckhandAppChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DeckhandTokens.of(context);
    final wizard = ref.watch(wizardStateProvider).valueOrNull;
    final version = ref.watch(deckhandVersionProvider);

    final printerLabel = _printerLabel(wizard);
    final hostLabel = wizard?.sshHost;

    // The chrome paints raw widgets (Container, Column, Text) without
    // a Scaffold above them. Without an enclosing Material, Flutter's
    // text painter falls back to the yellow-underline debug treatment
    // — the canonical "you forgot Material" smell. Wrapping the whole
    // chrome in a [Material] gives every descendant a proper
    // DefaultTextStyle and ink-well surface.
    return Material(
      type: MaterialType.canvas,
      color: tokens.ink0,
      child: Column(
        children: [
          _TopBar(version: version, printerLabel: printerLabel),
          // Routed content paints its own opaque background + grid
          // via WizardScaffold. Keeping the chrome's outer surface
          // plain means page transitions don't bleed through — each
          // routing fade-in is visually self-contained.
          Expanded(child: child),
          DeckhandFootbar(
            items: [
              DeckhandFootbarItem(label: 'sidecar', value: version),
              if (wizard != null && wizard.profileId.isNotEmpty)
                DeckhandFootbarItem(label: 'profile', value: wizard.profileId),
            ],
            trailing: [
              if (hostLabel != null)
                DeckhandFootbarItem(label: 'host', value: hostLabel),
            ],
          ),
        ],
      ),
    );
  }

  String? _printerLabel(WizardState? state) {
    if (state == null) return null;
    if (state.profileId.isEmpty) return null;
    return state.profileId;
  }
}

/// Slim top bar (~44px). Brand on the left, global affordances
/// on the right. Replaces the old left rail. Stays put across
/// every routed screen so a user always has Settings and the
/// theme toggle one click away.
class _TopBar extends StatelessWidget {
  const _TopBar({required this.version, required this.printerLabel});

  final String version;
  final String? printerLabel;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border(bottom: BorderSide(color: tokens.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          const DeckhandLogo(size: 18),
          const SizedBox(width: 10),
          Text(
            'Deckhand',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              color: tokens.text,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'v$version',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text4,
              letterSpacing: 0,
            ),
          ),
          if (printerLabel != null) ...[
            const SizedBox(width: 14),
            Container(width: 1, height: 16, color: tokens.lineSoft),
            const SizedBox(width: 14),
            // ConstrainedBox (rather than Flexible) so the label
            // takes only its intrinsic width — Flexible's default
            // flex=1 split the leftover space 50/50 with the Spacer
            // below it, pinning Settings/Theme to the middle of the
            // bar instead of the right edge whenever a label was set.
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                printerLabel!,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tXs,
                  color: tokens.text3,
                  letterSpacing: 0,
                ),
              ),
            ),
          ],
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.precision_manufacturing_outlined, size: 14),
            label: const Text('Printers'),
            onPressed: () => context.go('/printers'),
          ),
          const SizedBox(width: 4),
          if (printerLabel != null) ...[
            TextButton.icon(
              icon: const Icon(Icons.tune, size: 14),
              label: const Text('Manage'),
              onPressed: () => context.go('/manage'),
            ),
            const SizedBox(width: 4),
          ],
          const SettingsLinkButton(),
          const SizedBox(width: 4),
          const ThemeToggleButton(),
        ],
      ),
    );
  }
}
