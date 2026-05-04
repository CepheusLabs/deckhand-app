import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Horizontal status row — an inline strip of `[dot] label` items
/// rendered against a faint panel background. Used in screen heads
/// to surface the live state of preconditions ("SSH ok · Profile
/// match · OS: Armbian 22.05").
class StatusStrip extends StatelessWidget {
  const StatusStrip({super.key, required this.items});

  final List<StatusStripItem> items;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < items.length; i++) ...[
            if (i > 0) const SizedBox(width: 14),
            _Item(item: items[i], tokens: tokens),
          ],
        ],
      ),
    );
  }
}

enum StatusStripKind { neutral, ok, warn, bad }

class StatusStripItem {
  const StatusStripItem({
    required this.label,
    this.kind = StatusStripKind.neutral,
  });
  final String label;
  final StatusStripKind kind;
}

class _Item extends StatelessWidget {
  const _Item({required this.item, required this.tokens});
  final StatusStripItem item;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    final dotColor = switch (item.kind) {
      StatusStripKind.ok => tokens.ok,
      StatusStripKind.warn => tokens.warn,
      StatusStripKind.bad => tokens.bad,
      StatusStripKind.neutral => tokens.text4,
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: dotColor,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          item.label,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: DeckhandTokens.tXs,
            color: tokens.text3,
          ),
        ),
      ],
    );
  }
}
