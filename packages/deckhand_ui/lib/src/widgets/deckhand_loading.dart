import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';
import 'deckhand_panel.dart';

enum DeckhandLoaderKind { oscilloscope, tickPulse, emmcPins }

class DeckhandSpinner extends StatefulWidget {
  const DeckhandSpinner({
    super.key,
    this.size = 14,
    this.strokeWidth = 1.5,
    this.color,
  });

  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  State<DeckhandSpinner> createState() => _DeckhandSpinnerState();
}

class _DeckhandSpinnerState extends State<DeckhandSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<DeckhandTokens>();
    final color = widget.color ?? tokens?.accent ?? theme.colorScheme.primary;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _DeckhandSpinnerPainter(
            progress: _controller.value,
            color: color,
            trackColor: color.withValues(alpha: 0.18),
            strokeWidth: widget.strokeWidth,
          ),
        ),
      ),
    );
  }
}

class _DeckhandSpinnerPainter extends CustomPainter {
  _DeckhandSpinnerPainter({
    required this.progress,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
  });

  final double progress;
  final Color color;
  final Color trackColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    final track = Paint()
      ..color = trackColor
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    final arc = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    canvas.drawCircle(center, radius, track);
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(
      rect,
      progress * math.pi * 2 - math.pi / 2,
      math.pi * 1.35,
      false,
      arc,
    );
  }

  @override
  bool shouldRepaint(covariant _DeckhandSpinnerPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.trackColor != trackColor ||
      old.strokeWidth != strokeWidth;
}

class DeckhandLoadingBlock extends StatelessWidget {
  const DeckhandLoadingBlock({
    super.key,
    required this.title,
    required this.message,
    this.kind = DeckhandLoaderKind.oscilloscope,
  });

  final String title;
  final String message;
  final DeckhandLoaderKind kind;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return DeckhandPanel(
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _LoaderGraphic(kind: kind),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    height: 1.4,
                    color: tokens.text3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LoaderGraphic extends StatelessWidget {
  const _LoaderGraphic({required this.kind});

  final DeckhandLoaderKind kind;

  @override
  Widget build(BuildContext context) {
    return switch (kind) {
      DeckhandLoaderKind.oscilloscope => const DeckhandOscilloscopeLoader(),
      DeckhandLoaderKind.tickPulse => const DeckhandTickPulseLoader(),
      DeckhandLoaderKind.emmcPins => const DeckhandEmmcPinLoader(),
    };
  }
}

class DeckhandOscilloscopeLoader extends StatefulWidget {
  const DeckhandOscilloscopeLoader({super.key, this.size = 64});

  final double size;

  @override
  State<DeckhandOscilloscopeLoader> createState() =>
      _DeckhandOscilloscopeLoaderState();
}

class _DeckhandOscilloscopeLoaderState extends State<DeckhandOscilloscopeLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SizedBox.square(
      dimension: widget.size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: tokens.ink1,
          border: Border.all(color: tokens.line),
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => CustomPaint(
              painter: _OscilloscopePainter(
                progress: _controller.value,
                tokens: tokens,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OscilloscopePainter extends CustomPainter {
  _OscilloscopePainter({required this.progress, required this.tokens});

  final double progress;
  final DeckhandTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = tokens.lineSoft
      ..strokeWidth = 0.5;
    for (final f in const [0.25, 0.5, 0.75]) {
      final x = size.width * f;
      final y = size.height * f;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    final wave = Paint()
      ..color = tokens.accent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = _wavePath(size);
    final dx = progress * size.width;
    canvas.save();
    canvas.translate(dx - size.width, 0);
    canvas.drawPath(path, wave);
    canvas.translate(size.width, 0);
    canvas.drawPath(path, wave);
    canvas.restore();

    final cursor = Paint()
      ..color = tokens.accentBright.withValues(alpha: 0.75)
      ..strokeWidth = 1;
    final cursorX = progress * size.width;
    canvas.drawLine(Offset(cursorX, 0), Offset(cursorX, size.height), cursor);
  }

  Path _wavePath(Size size) {
    final mid = size.height / 2;
    final amp = size.height * 0.22;
    return Path()
      ..moveTo(0, mid)
      ..quadraticBezierTo(size.width * 0.125, mid - amp, size.width * 0.25, mid)
      ..quadraticBezierTo(size.width * 0.375, mid + amp, size.width * 0.5, mid)
      ..quadraticBezierTo(size.width * 0.625, mid - amp, size.width * 0.75, mid)
      ..quadraticBezierTo(size.width * 0.875, mid + amp, size.width, mid);
  }

  @override
  bool shouldRepaint(covariant _OscilloscopePainter old) =>
      old.progress != progress || old.tokens != tokens;
}

class DeckhandTickPulseLoader extends StatefulWidget {
  const DeckhandTickPulseLoader({super.key});

  @override
  State<DeckhandTickPulseLoader> createState() =>
      _DeckhandTickPulseLoaderState();
}

class _DeckhandTickPulseLoaderState extends State<DeckhandTickPulseLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SizedBox(
      width: 52,
      height: 32,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (var i = 0; i < 8; i++) ...[
              _PulseTick(
                phase: (_controller.value + i * 0.08) % 1.0,
                color: tokens.accent,
              ),
              if (i < 7) const SizedBox(width: 3),
            ],
          ],
        ),
      ),
    );
  }
}

class _PulseTick extends StatelessWidget {
  const _PulseTick({required this.phase, required this.color});

  final double phase;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final wave = (math.sin(phase * math.pi * 2) + 1) / 2;
    return Container(
      width: 3,
      height: 8 + wave * 18,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.35 + wave * 0.65),
        borderRadius: BorderRadius.circular(1),
      ),
    );
  }
}

class DeckhandEmmcPinLoader extends StatefulWidget {
  const DeckhandEmmcPinLoader({super.key, this.size = 72});

  final double size;

  @override
  State<DeckhandEmmcPinLoader> createState() => _DeckhandEmmcPinLoaderState();
}

class _DeckhandEmmcPinLoaderState extends State<DeckhandEmmcPinLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SizedBox(
      width: widget.size,
      height: widget.size * 0.625,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _EmmcPinPainter(progress: _controller.value, tokens: tokens),
        ),
      ),
    );
  }
}

class _EmmcPinPainter extends CustomPainter {
  _EmmcPinPainter({required this.progress, required this.tokens});

  final double progress;
  final DeckhandTokens tokens;

  @override
  void paint(Canvas canvas, Size size) {
    final sx = size.width / 80;
    final sy = size.height / 50;
    final chip = Rect.fromLTWH(10 * sx, 10 * sy, 60 * sx, 30 * sy);
    final chipPaint = Paint()..color = tokens.ink2;
    final linePaint = Paint()
      ..color = tokens.line
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, Radius.circular(2 * sx)),
      chipPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(chip, Radius.circular(2 * sx)),
      linePaint,
    );

    final textPainter = TextPainter(
      text: TextSpan(
        text: 'eMMC',
        style: TextStyle(
          fontFamily: DeckhandTokens.fontMono,
          fontSize: 7 * sx,
          color: tokens.text3,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout();
    textPainter.paint(
      canvas,
      Offset((size.width - textPainter.width) / 2, 22 * sy),
    );

    for (var i = 0; i < 8; i++) {
      final phase = (progress + i * 0.095) % 1.0;
      final opacity = 0.2 + ((math.sin(phase * math.pi * 2) + 1) / 2) * 0.8;
      final pin = Rect.fromLTWH((14 + i * 7) * sx, 40 * sy, 4 * sx, 6 * sy);
      canvas.drawRect(
        pin,
        Paint()..color = tokens.accent.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EmmcPinPainter old) =>
      old.progress != progress || old.tokens != tokens;
}
