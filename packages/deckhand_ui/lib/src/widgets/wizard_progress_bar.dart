import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Animated progress bar with measurement ticks below — the design
/// language's signature `.progress-bar + .ticks` pair.
///
/// When [fraction] is null, the bar shows an indeterminate sweep.
/// When non-null in [0..1], the fill animates to that width and a
/// diagonal-stripe overlay slides across to signal "still active."
class WizardProgressBar extends StatefulWidget {
  const WizardProgressBar({
    super.key,
    required this.fraction,
    this.showTicks = true,
    this.tickCount = 20,
  });

  final double? fraction;
  final bool showTicks;
  final int tickCount;

  @override
  State<WizardProgressBar> createState() => _WizardProgressBarState();
}

class _WizardProgressBarState extends State<WizardProgressBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _stripes;

  @override
  void initState() {
    super.initState();
    _stripes = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _stripes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 8,
          decoration: BoxDecoration(
            color: tokens.ink2,
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(99),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: Stack(
              children: [
                // Fill — gradient from accentDim → accent.
                //
                // Determinate (fraction != null): width animates to
                // the requested fraction. SizedBox.expand wraps the
                // DecoratedBox so the gradient actually paints — a
                // bare DecoratedBox has no intrinsic size and would
                // collapse to 0×0 under FractionallySizedBox's loose
                // constraints, leaving only the stripe overlay
                // visible.
                //
                // Indeterminate (fraction == null): a 30%-wide bar
                // slides L→R across the track, Material-style. The
                // earlier "widthFactor: fraction ?? 1.0" path made
                // the indeterminate state look like a 100%-complete
                // bar (especially after the SizedBox.expand fix made
                // the gradient actually fill its slot), which is the
                // wrong signal — users read it as "done" instead of
                // "loading." The slide reads as in-progress without
                // committing to a percentage.
                if (widget.fraction != null)
                  AnimatedFractionallySizedBox(
                    duration: const Duration(milliseconds: 300),
                    widthFactor: widget.fraction!,
                    heightFactor: 1.0,
                    alignment: Alignment.centerLeft,
                    child: SizedBox.expand(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [tokens.accentDim, tokens.accent],
                          ),
                        ),
                      ),
                    ),
                  )
                else
                  AnimatedBuilder(
                    animation: _stripes,
                    builder: (context, child) {
                      // Map controller value [0..1] to alignment x
                      // [-1.857..1.857] — the range where a 30%-wide
                      // child sits exactly off-screen left at the
                      // start and exactly off-screen right at the
                      // end. Derivation:
                      //   leftEdge = (1 - 0.3) * (x + 1) / 2 = 0.35*(x+1)
                      //   leftEdge = -0.3 (off left) → x = -1.857
                      //   leftEdge =  1.0 (off right) → x =  1.857
                      // Total span = 3.714 child-aligned units.
                      final t = _stripes.value;
                      final alignX = -1.857 + 3.714 * t;
                      return Align(
                        alignment: Alignment(alignX, 0),
                        child: child,
                      );
                    },
                    child: FractionallySizedBox(
                      widthFactor: 0.3,
                      heightFactor: 1.0,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [tokens.accentDim, tokens.accent],
                          ),
                        ),
                      ),
                    ),
                  ),
                // Stripes — a CustomPaint that scrolls 28px per cycle
                // for the "still working" feel, layered over the
                // determinate fill. Skipped on the indeterminate
                // path because the sliding bar already conveys
                // "active" and stripes layered on top of a moving
                // chunk read as visual noise.
                if (widget.fraction != null)
                  AnimatedBuilder(
                    animation: _stripes,
                    builder: (context, _) {
                      return CustomPaint(
                        painter: _StripesPainter(
                          offset: _stripes.value * 28,
                          color: const Color(0x10FFFFFF),
                        ),
                        size: Size.infinite,
                      );
                    },
                  ),
              ],
            ),
          ),
        ),
        if (widget.showTicks) ...[
          const SizedBox(height: 4),
          _Ticks(count: widget.tickCount, tokens: tokens),
        ],
      ],
    );
  }
}

class _StripesPainter extends CustomPainter {
  _StripesPainter({required this.offset, required this.color});
  final double offset;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    const period = 14.0;
    const stripeWidth = 2.0;
    final span = size.width + size.height + period;
    for (double x = -span + (offset % period); x < span; x += period) {
      final path = Path()
        ..moveTo(x, 0)
        ..lineTo(x + stripeWidth, 0)
        ..lineTo(x + stripeWidth + size.height, size.height)
        ..lineTo(x + size.height, size.height)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StripesPainter old) =>
      old.offset != offset || old.color != color;
}

class _Ticks extends StatelessWidget {
  const _Ticks({required this.count, required this.tokens});
  final int count;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 14,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final colWidth = constraints.maxWidth / count;
          return Row(
            children: [
              for (var i = 0; i < count; i++)
                SizedBox(
                  width: colWidth,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        child: Container(
                          width: 1,
                          height: i % 5 == 0 ? 6 : 4,
                          color: i % 5 == 0
                              ? tokens.text3
                              : tokens.rule,
                        ),
                      ),
                      if (i % 5 == 0)
                        Positioned(
                          left: 2,
                          top: 6,
                          child: Text(
                            '${i * 5}%',
                            style: TextStyle(
                              fontFamily: DeckhandTokens.fontMono,
                              fontSize: 9,
                              color: tokens.text4,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
