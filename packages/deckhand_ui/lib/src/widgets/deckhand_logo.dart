import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Deckhand brand mark — caliper / tick-mark.
///
/// A horizontal measurement bar with vertical ticks above and below.
/// The personality is "workshop instrument" — same family as a ruler,
/// oscilloscope, or vernier scale. Drawn in the active accent color
/// unless overridden.
///
/// Sized via [size]; defaults to 22px which matches the chrome header.
/// Use 14px in dense rows, 40-64px in hero layouts.
class DeckhandLogo extends StatelessWidget {
  const DeckhandLogo({super.key, this.size = 22, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final paintColor = color ?? tokens.accent;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _TickLogoPainter(color: paintColor),
      ),
    );
  }
}

class _TickLogoPainter extends CustomPainter {
  _TickLogoPainter({required this.color});
  final Color color;

  // Source viewBox is 32×32 — coordinates below are in viewBox units
  // and scaled at paint time. Keeping them in source-space matches
  // the design SVG line-for-line.
  static const double _vbSize = 32;
  static const _ticksTop = <_TickLine>[
    _TickLine(x: 6,  y1: 9,  y2: 14),
    _TickLine(x: 11, y1: 11, y2: 14),
    _TickLine(x: 16, y1: 7,  y2: 14),
    _TickLine(x: 21, y1: 11, y2: 14),
    _TickLine(x: 26, y1: 9,  y2: 14),
  ];
  static const _ticksBottom = <_TickLine>[
    _TickLine(x: 6,  y1: 18, y2: 23),
    _TickLine(x: 11, y1: 18, y2: 21),
    _TickLine(x: 16, y1: 18, y2: 25),
    _TickLine(x: 21, y1: 18, y2: 21),
    _TickLine(x: 26, y1: 18, y2: 23),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / _vbSize;
    canvas.scale(scale, scale);

    // Horizontal scale bar — drawn at 40% opacity so the ticks pop.
    final barPaint = Paint()
      ..color = color.withValues(alpha: 0.4)
      ..style = PaintingStyle.fill;
    canvas.drawRect(const Rect.fromLTWH(3, 14, 26, 4), barPaint);

    // Tick lines — square caps, full opacity, 2px stroke (in viewBox
    // units). Square caps preserve the slab/instrument feel; rounded
    // caps would soften the mark too much.
    final tickPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.square;

    for (final t in _ticksTop) {
      canvas.drawLine(Offset(t.x, t.y1), Offset(t.x, t.y2), tickPaint);
    }
    for (final t in _ticksBottom) {
      canvas.drawLine(Offset(t.x, t.y1), Offset(t.x, t.y2), tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _TickLogoPainter old) => old.color != color;
}

class _TickLine {
  const _TickLine({required this.x, required this.y1, required this.y2});
  final double x;
  final double y1;
  final double y2;
}
