import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Subtle horizontal-grid background — the design source's
/// "workshop instrument" backdrop. Renders a 1px line every 40px
/// using [DeckhandTokens.gridLine], which is faint enough to read as
/// texture rather than ruled paper.
///
/// Wraps a [child] so the grid sits behind it. The chrome puts this
/// behind the routed wizard content; sidenav + footbar get plain
/// surfaces so the grid doesn't compete with the navigation.
class GridBackground extends StatelessWidget {
  const GridBackground({super.key, required this.child, this.spacing = 40});

  final Widget child;
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _GridPainter(color: tokens.gridLine, spacing: spacing),
          ),
        ),
        child,
      ],
    );
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter({required this.color, required this.spacing});
  final Color color;
  final double spacing;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (double y = 0; y < size.height; y += spacing) {
      // y + 0.5 keeps the line crisp on integer-pixel devices —
      // hairline strokes drawn on integer y get anti-aliased into a
      // 2px-wide blur otherwise.
      canvas.drawLine(Offset(0, y + 0.5), Offset(size.width, y + 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.color != color || old.spacing != spacing;
}
