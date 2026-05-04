import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Inline screen-ID / hash / path tag — a signature element of the
/// Deckhand visual language. Renders content like `[S40-choose-path]`
/// or `[sha256:8b2c…b1]` as a small monospace chip with a leading dot.
///
/// Used inline in body copy, in headers, and in the wizard to anchor
/// references to documented IDs (the same IDs that appear in
/// docs/WIZARD-FLOW.md and the profile schema).
class IdTag extends StatelessWidget {
  const IdTag(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Leading dot at half-opacity of the text color — same
          // pattern as the CSS `::before` pseudo-element.
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: tokens.text3.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text3,
              letterSpacing: 0.04 * 10,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
