import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Bordered red card with diagonal hash-line backdrop. Used for the
/// destructive flash-confirm screen — the only place in the wizard
/// where a primary action wipes hardware state. The hash pattern is
/// the design language's signal that "this is the dangerous one."
class DangerCard extends StatelessWidget {
  const DangerCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      child: Container(
        decoration: BoxDecoration(
          color: tokens.ink1,
          border: Border.all(color: tokens.bad.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(DeckhandTokens.r3),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              tokens.bad.withValues(alpha: 0.04),
              Colors.transparent,
            ],
          ),
        ),
        child: CustomPaint(
          painter: _HashStripesPainter(color: tokens.bad.withValues(alpha: 0.05)),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class _HashStripesPainter extends CustomPainter {
  _HashStripesPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    // 16px period; 14px transparent gap → 2px line. Tilt -45deg by
    // walking along x with a -1 slope and offsetting both endpoints.
    const spacing = 16.0;
    final span = size.width + size.height;
    for (double offset = -span; offset < span; offset += spacing) {
      canvas.drawLine(
        Offset(offset, 0),
        Offset(offset + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HashStripesPainter old) => old.color != color;
}
