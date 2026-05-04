import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// 1-pixel-tall horizontal dashed line. Flutter has no native
/// dashed-border support so this is a CustomPainter; the design uses
/// it for the footer separator inside selection cards (matches
/// `border-top: 1px dashed var(--line)` in the source).
class DashedDivider extends StatelessWidget {
  const DashedDivider({
    super.key,
    this.color,
    this.dashWidth = 4,
    this.gapWidth = 4,
    this.thickness = 1,
  });

  final Color? color;
  final double dashWidth;
  final double gapWidth;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SizedBox(
      width: double.infinity,
      height: thickness,
      child: CustomPaint(
        painter: _DashedLinePainter(
          color: color ?? tokens.line,
          dashWidth: dashWidth,
          gapWidth: gapWidth,
          thickness: thickness,
        ),
      ),
    );
  }
}

class _DashedLinePainter extends CustomPainter {
  _DashedLinePainter({
    required this.color,
    required this.dashWidth,
    required this.gapWidth,
    required this.thickness,
  });
  final Color color;
  final double dashWidth;
  final double gapWidth;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke;
    final y = size.height / 2;
    for (double x = 0; x < size.width; x += dashWidth + gapWidth) {
      canvas.drawLine(
        Offset(x, y),
        Offset((x + dashWidth).clamp(0, size.width), y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _DashedLinePainter old) =>
      old.color != color ||
      old.dashWidth != dashWidth ||
      old.gapWidth != gapWidth ||
      old.thickness != thickness;
}

/// Box with a 1px dashed border on all sides. Used for the "Neither"
/// affordance on the web-UI screen (matches the source's `border: 1px
/// dashed var(--line)` rule).
class DashedBorderBox extends StatelessWidget {
  const DashedBorderBox({
    super.key,
    required this.child,
    this.color,
    this.borderRadius = 6,
    this.padding = EdgeInsets.zero,
    this.dashWidth = 4,
    this.gapWidth = 4,
    this.thickness = 1,
  });

  final Widget child;
  final Color? color;
  final double borderRadius;
  final EdgeInsetsGeometry padding;
  final double dashWidth;
  final double gapWidth;
  final double thickness;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return CustomPaint(
      painter: _DashedRectPainter(
        color: color ?? tokens.rule,
        radius: borderRadius,
        dashWidth: dashWidth,
        gapWidth: gapWidth,
        thickness: thickness,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({
    required this.color,
    required this.radius,
    required this.dashWidth,
    required this.gapWidth,
    required this.thickness,
  });
  final Color color;
  final double radius;
  final double dashWidth;
  final double gapWidth;
  final double thickness;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = thickness
      ..style = PaintingStyle.stroke;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    final metrics = path.computeMetrics();
    for (final metric in metrics) {
      var distance = 0.0;
      while (distance < metric.length) {
        final next = (distance + dashWidth).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gapWidth;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.dashWidth != dashWidth ||
      old.gapWidth != gapWidth ||
      old.thickness != thickness;
}
