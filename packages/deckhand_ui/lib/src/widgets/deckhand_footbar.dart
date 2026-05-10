import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Bottom chrome strip — 24px tall, holds machine-shaped status
/// columns ("SIDECAR 0.4.1", "PROFILE phrozen-arco@v0.4.1", etc).
///
/// Renders [items] left-to-right, separated by middot bullets. Items
/// pushed via [trailing] are right-aligned so version/host slots can
/// live opposite the build slots.
///
/// Pure presentation. Mono throughout — this strip is data, not body
/// copy.
class DeckhandFootbar extends StatelessWidget {
  const DeckhandFootbar({
    super.key,
    this.items = const [],
    this.trailing = const [],
  });

  final List<DeckhandFootbarItem> items;
  final List<DeckhandFootbarItem> trailing;

  static const double height = 24;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border(top: BorderSide(color: tokens.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: DefaultTextStyle.merge(
        style: TextStyle(
          fontFamily: DeckhandTokens.fontMono,
          fontSize: 10,
          color: tokens.text3,
          letterSpacing: 0,
        ),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              _FootbarCell(item: items[i], tokens: tokens),
              if (i < items.length - 1) _Sep(tokens: tokens),
            ],
            const Spacer(),
            for (var i = 0; i < trailing.length; i++) ...[
              if (i > 0) const SizedBox(width: 16),
              _FootbarCell(item: trailing[i], tokens: tokens),
            ],
          ],
        ),
      ),
    );
  }
}

class DeckhandFootbarItem {
  const DeckhandFootbarItem({required this.label, required this.value});
  final String label;
  final String value;
}

class _FootbarCell extends StatelessWidget {
  const _FootbarCell({required this.item, required this.tokens});
  final DeckhandFootbarItem item;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          item.label.toUpperCase(),
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 10,
            color: tokens.text3,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          item.value,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 10,
            color: tokens.text4,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep({required this.tokens});
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text('·', style: TextStyle(
        color: tokens.text4,
        fontFamily: DeckhandTokens.fontMono,
        fontSize: 10,
      )),
    );
  }
}
