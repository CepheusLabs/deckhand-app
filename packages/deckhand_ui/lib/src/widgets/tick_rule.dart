import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Decorative tick-mark rule. Draws an oscilloscope/ruler-style band
/// of vertical ticks under section headings — the system's signature
/// "workshop instrument" gesture.
///
/// Anatomy (mirrors the CSS in the design source):
///  * Major ticks every 80 logical pixels, 6px tall.
///  * Minor ticks every 16 logical pixels, 3px tall.
///  * Right edge fades to transparent over the last 30% so the rule
///    breathes into the surrounding layout instead of slamming into a
///    boundary.
///
/// Uses [DeckhandTokens.rule] as the tick color so light/dark
/// instances pick up the right contrast automatically.
class TickRule extends StatelessWidget {
  const TickRule({
    super.key,
    this.height = 12,
    this.majorEvery = 80,
    this.minorEvery = 16,
    this.majorTickHeight = 6,
    this.minorTickHeight = 3,
  });

  final double height;
  final double majorEvery;
  final double minorEvery;
  final double majorTickHeight;
  final double minorTickHeight;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SizedBox(
      width: double.infinity,
      height: height,
      child: CustomPaint(
        painter: _TickRulePainter(
          color: tokens.rule,
          majorEvery: majorEvery,
          minorEvery: minorEvery,
          majorTickHeight: majorTickHeight,
          minorTickHeight: minorTickHeight,
        ),
      ),
    );
  }
}

class _TickRulePainter extends CustomPainter {
  _TickRulePainter({
    required this.color,
    required this.majorEvery,
    required this.minorEvery,
    required this.majorTickHeight,
    required this.minorTickHeight,
  });

  final Color color;
  final double majorEvery;
  final double minorEvery;
  final double majorTickHeight;
  final double minorTickHeight;

  @override
  void paint(Canvas canvas, Size size) {
    // Right-edge fade: mask the last 30% with a horizontal gradient
    // (opaque → transparent). Save a layer so the tick paint blends
    // through the mask correctly.
    final bounds = Offset.zero & size;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.saveLayer(bounds, Paint());

    final tickPaint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    // Minor ticks fill the band first; major ticks are drawn on top so
    // they overwrite a co-located minor at the same x.
    for (double x = 0; x <= size.width; x += minorEvery) {
      canvas.drawLine(
        Offset(x + 0.5, 0),
        Offset(x + 0.5, minorTickHeight),
        tickPaint,
      );
    }
    for (double x = 0; x <= size.width; x += majorEvery) {
      canvas.drawLine(
        Offset(x + 0.5, 0),
        Offset(x + 0.5, majorTickHeight),
        tickPaint,
      );
    }

    // Composite the fade — a destinationIn pass keeps existing pixels
    // weighted by the gradient's alpha.
    final fadePaint = Paint()
      ..blendMode = BlendMode.dstIn
      ..shader = const LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          Color(0xFF000000),
          Color(0xFF000000),
          Color(0x00000000),
        ],
        stops: [0, 0.7, 1],
      ).createShader(rect);
    canvas.drawRect(rect, fadePaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _TickRulePainter old) =>
      old.color != color ||
      old.majorEvery != majorEvery ||
      old.minorEvery != minorEvery ||
      old.majorTickHeight != majorTickHeight ||
      old.minorTickHeight != minorTickHeight;
}
