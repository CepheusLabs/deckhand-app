import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../theming/deckhand_tokens.dart';

/// Compact icon button that jumps the router to `/settings`. Lives in
/// the sidenav foot next to the [ThemeToggleButton] so app-wide
/// affordances stay grouped — no need to scroll back to the welcome
/// screen to reach Settings mid-wizard.
class SettingsLinkButton extends StatelessWidget {
  const SettingsLinkButton({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Tooltip(
      message: 'Settings',
      child: InkWell(
        // push (not go) so the prior wizard route stays on the stack
        // and the Settings screen's Back button can pop back to it.
        // context.go would replace the current location, leaving Back
        // with nowhere to return except '/'.
        onTap: () => context.push('/settings'),
        borderRadius: BorderRadius.circular(DeckhandTokens.r1),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(
            Icons.tune,
            size: 14,
            color: tokens.text3,
          ),
        ),
      ),
    );
  }
}
