import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Tappable bordered card used for choose-path / pick-printer style
/// selections. When [selected], the border becomes the accent and
/// a small filled check badge appears in the top-right corner.
///
/// The card is the design's `.scard` primitive — a rounded panel
/// with hover + focus states wired through Material's [InkWell]
/// machinery (so the visual state matches the system focus ring).
class SelectionCard extends StatelessWidget {
  const SelectionCard({
    super.key,
    required this.selected,
    required this.onTap,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final bool selected;
  final VoidCallback? onTap;
  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final radius = BorderRadius.circular(DeckhandTokens.r3);
    return MouseRegion(
      cursor: onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              color: selected ? tokens.ink2 : tokens.ink1,
              border: Border.all(
                color: selected ? tokens.accent : tokens.line,
                width: selected ? 1.5 : 1,
              ),
              borderRadius: radius,
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: tokens.accentSoft,
                        blurRadius: 0,
                        spreadRadius: 3,
                      ),
                    ]
                  : null,
            ),
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                onTap: onTap,
                borderRadius: radius,
                hoverColor: tokens.ink2,
                child: Padding(padding: padding, child: child),
              ),
            ),
          ),
          if (selected)
            Positioned(
              top: 12,
              right: 12,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: tokens.accent,
                  shape: BoxShape.circle,
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.check,
                  size: 9,
                  color: tokens.accentFg,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
