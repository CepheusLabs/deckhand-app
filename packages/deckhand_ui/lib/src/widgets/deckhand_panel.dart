import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Generic bordered surface used everywhere the design language
/// shows a `.panel` — list containers, info blocks, side rails.
///
/// Optional [head] renders a label strip across the top, separated
/// from the body by a 1px line. The strip uses the design's "panel
/// head" treatment (mono uppercase label on `ink-2`).
class DeckhandPanel extends StatelessWidget {
  const DeckhandPanel({
    super.key,
    required this.child,
    this.head,
    this.padding = const EdgeInsets.all(16),
  }) : fillParent = false;

  /// Convenience constructor for an unpadded panel — useful when the
  /// child supplies its own internal padding (lists, tables, etc.).
  /// Defaults [fillParent] to true since flush panels are typically
  /// hosted inside height-constrained parents (split layouts, list
  /// rails, the progress screen's right pane) and need to fill them.
  const DeckhandPanel.flush({
    super.key,
    required this.child,
    this.head,
    this.fillParent = true,
  }) : padding = EdgeInsets.zero;

  final Widget child;
  final DeckhandPanelHead? head;
  final EdgeInsetsGeometry padding;

  /// When true, the panel expands its body to consume any remaining
  /// vertical space (for `Expanded` children to work). Default false
  /// — most panels wrap snugly around their content.
  final bool fillParent;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: fillParent ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (head != null) _Head(head: head!, tokens: tokens),
          if (fillParent)
            Expanded(child: Padding(padding: padding, child: child))
          else
            Padding(padding: padding, child: child),
        ],
      ),
    );
  }
}

class DeckhandPanelHead {
  const DeckhandPanelHead({required this.label, this.trailing});
  final String label;
  final Widget? trailing;
}

class _Head extends StatelessWidget {
  const _Head({required this.head, required this.tokens});
  final DeckhandPanelHead head;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border(bottom: BorderSide(color: tokens.line)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              head.label.toUpperCase(),
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 10,
                color: tokens.text3,
                letterSpacing: 0,
              ),
            ),
          ),
          if (head.trailing != null) head.trailing!,
        ],
      ),
    );
  }
}
