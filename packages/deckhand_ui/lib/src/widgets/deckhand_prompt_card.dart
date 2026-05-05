import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

enum PromptSeverity { recommended, neutral, destructive }

typedef PromptOption = ({String id, String label, PromptSeverity severity});

/// Custom prompt-dialog card. Material's AlertDialog action row wraps
/// three long confirmation labels into a vertical stack too early, so
/// this card keeps the action hierarchy explicit on wider windows.
class DeckhandPromptCard extends StatelessWidget {
  const DeckhandPromptCard({
    super.key,
    required this.title,
    required this.message,
    required this.buttons,
  });

  final String title;
  final String message;
  final List<PromptOption> buttons;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final ordered = [
      ...buttons.where((b) => b.severity == PromptSeverity.destructive),
      ...buttons.where((b) => b.severity == PromptSeverity.neutral),
      ...buttons.where((b) => b.severity == PromptSeverity.recommended),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 600),
      child: Material(
        color: tokens.ink1,
        elevation: 8,
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        child: Container(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(DeckhandTokens.r3),
          ),
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tXl,
                  fontWeight: FontWeight.w600,
                  color: tokens.text,
                  letterSpacing: 0,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                message,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tMd,
                  color: tokens.text2,
                  height: 1.55,
                ),
              ),
              const SizedBox(height: 24),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowSpacing: 8,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  for (final button in ordered)
                    _PromptButton(
                      label: button.label,
                      severity: button.severity,
                      tokens: tokens,
                      onPressed: () => Navigator.of(
                        context,
                        rootNavigator: true,
                      ).pop(button.id),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PromptButton extends StatelessWidget {
  const _PromptButton({
    required this.label,
    required this.severity,
    required this.tokens,
    required this.onPressed,
  });

  final String label;
  final PromptSeverity severity;
  final DeckhandTokens tokens;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    const padding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
    switch (severity) {
      case PromptSeverity.recommended:
        return FilledButton(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            backgroundColor: tokens.accent,
            foregroundColor: tokens.accentFg,
            padding: padding,
          ),
          child: Text(label),
        );
      case PromptSeverity.destructive:
        return OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: tokens.bad,
            side: BorderSide(color: tokens.bad.withValues(alpha: 0.55)),
            padding: padding,
          ),
          child: Text(label),
        );
      case PromptSeverity.neutral:
        return OutlinedButton(
          onPressed: onPressed,
          style: OutlinedButton.styleFrom(
            foregroundColor: tokens.text,
            side: BorderSide(color: tokens.line),
            padding: padding,
          ),
          child: Text(label),
        );
    }
  }
}
