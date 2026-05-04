import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Decorative horizontal-line grid that paints behind the wizard's
/// main content area. Same recipe as the design source's `.main`
/// background — a single-pixel rule every 40 logical pixels in the
/// muted `gridLine` color, with the surface `ink-0` underneath.
///
/// Cosmetic only. Sits in a Stack below the routed screen so the
/// content reads against the workshop-graph-paper backdrop.
class WorkshopGrid extends StatelessWidget {
  const WorkshopGrid({super.key, this.spacing = 40});

  /// Pixels between rules. The design source uses 40.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return ColoredBox(
      color: tokens.ink0,
      child: CustomPaint(
        painter: _GridPainter(color: tokens.gridLine, spacing: spacing),
        size: Size.infinite,
      ),
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
    for (double y = 0.5; y <= size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.color != color || old.spacing != spacing;
}
