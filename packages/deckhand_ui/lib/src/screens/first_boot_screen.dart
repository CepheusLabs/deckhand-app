import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/wizard_scaffold.dart';

class FirstBootScreen extends ConsumerStatefulWidget {
  const FirstBootScreen({super.key});

  @override
  ConsumerState<FirstBootScreen> createState() => _FirstBootScreenState();
}

class _FirstBootScreenState extends ConsumerState<FirstBootScreen> {
  bool _waiting = false;
  bool _ready = false;
  String _status = 'waiting…';
  DateTime? _pollStart;
  Timer? _ticker;

  static const _pollTimeout = Duration(minutes: 10);

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _startPolling() async {
    final host = ref.read(wizardControllerProvider).state.sshHost;
    if (host == null) return;
    setState(() {
      _waiting = true;
      _pollStart = DateTime.now();
      _status = 'Polling $host:22 for SSH…';
    });
    _ticker = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() {}),
    );
    final ok = await ref
        .read(discoveryServiceProvider)
        .waitForSsh(host: host, timeout: _pollTimeout);
    _ticker?.cancel();
    if (!mounted) return;
    setState(() {
      _waiting = false;
      _ready = ok;
      _status = ok ? 'SSH is up.' : 'Timed out waiting for SSH.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final host = ref.watch(wizardControllerProvider).state.sshHost ?? '<host>';
    return WizardScaffold(
      screenId: 'S240-first-boot',
      title: 'Boot the printer.',
      helperText:
          'Once Deckhand sees an SSH listener on the printer it\'ll '
          'continue automatically. Worst case it gives up after ten '
          'minutes — power-on issues stop the wizard cleanly rather '
          'than hanging forever.',
      body: LayoutBuilder(
        builder: (context, constraints) {
          final twoCol = constraints.maxWidth >= 720;
          final steps = _StepsPanel();
          final indicator = _WaitingPanel(
            host: host,
            waiting: _waiting,
            ready: _ready,
            status: _status,
            elapsed: _pollStart == null
                ? Duration.zero
                : DateTime.now().difference(_pollStart!),
            timeout: _pollTimeout,
          );
          if (twoCol) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: steps),
                  const SizedBox(width: 12),
                  Expanded(child: indicator),
                ],
              ),
            );
          }
          return Column(
            children: [steps, const SizedBox(height: 12), indicator],
          );
        },
      ),
      primaryAction: WizardAction(
        label: _ready ? 'Continue' : (_waiting ? 'Waiting…' : 'Start polling'),
        onPressed: _ready
            ? () => context.go('/first-boot-setup')
            : (_waiting ? null : _startPolling),
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          onPressed: () => context.go('/flash-confirm'),
          isBack: true,
        ),
      ],
    );
  }
}

class _StepsPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    const steps = [
      'Unplug the USB adapter from your computer.',
      'Put the eMMC module back in the printer.',
      'Power the printer on.',
      'Click "Start polling" — Deckhand will wait for SSH for up to 10 minutes.',
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'STEPS',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text4,
              letterSpacing: 0.1 * 10,
            ),
          ),
          const SizedBox(height: 14),
          for (var i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: tokens.ink2,
                      border: Border.all(color: tokens.line),
                      borderRadius: BorderRadius.circular(DeckhandTokens.r2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: 11,
                        color: tokens.text2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        steps[i],
                        style: TextStyle(
                          fontFamily: DeckhandTokens.fontSans,
                          fontSize: DeckhandTokens.tMd,
                          color: tokens.text2,
                          height: 1.5,
                        ),
                      ),
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

class _WaitingPanel extends StatelessWidget {
  const _WaitingPanel({
    required this.host,
    required this.waiting,
    required this.ready,
    required this.status,
    required this.elapsed,
    required this.timeout,
  });

  final String host;
  final bool waiting;
  final bool ready;
  final String status;
  final Duration elapsed;
  final Duration timeout;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final remaining = timeout - elapsed;
    final remainingStr = remaining.isNegative
        ? '0s'
        : _shortDuration(remaining);
    final elapsedStr = _shortDuration(elapsed);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 80×80 framing ring around the spinner. Solid green when SSH
          // is up; otherwise a dashed accent border (the design's
          // "waiting" treatment from S240). Flutter's Border.all only
          // does solid edges, so the dashed pass goes through a
          // CustomPaint that walks the perimeter in equal arc segments.
          SizedBox(
            width: 80,
            height: 80,
            child: CustomPaint(
              painter: _RingPainter(
                color: ready ? tokens.ok : tokens.accent,
                strokeWidth: 2,
                dashed: !ready,
              ),
              child: Center(
                child: ready
                    ? Icon(
                        Icons.check_circle_outline,
                        size: 36,
                        color: tokens.ok,
                      )
                    : const DeckhandSpinner(size: 40, strokeWidth: 2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            ready
                ? 'SSH is up.'
                : (waiting ? 'Waiting for SSH…' : 'Ready to poll'),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            waiting
                ? '$host:22 · $elapsedStr elapsed · $remainingStr remaining'
                : status,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tXs,
              color: tokens.text4,
            ),
          ),
        ],
      ),
    );
  }

  String _shortDuration(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    if (m == 0) return '${s}s';
    return '${m}m ${s.toString().padLeft(2, '0')}s';
  }
}

/// Paints a circular ring as either a solid stroke (matches the
/// CSS `border` rendering) or 24 evenly-spaced dashes around the
/// perimeter. The dashed mode is the design's "waiting" treatment
/// from S240 — the dashes nudge the eye to read the ring as
/// in-progress rather than a static frame.
class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.color,
    required this.strokeWidth,
    required this.dashed,
  });

  final Color color;
  final double strokeWidth;
  final bool dashed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;
    final inset = strokeWidth / 2;
    final rect = Rect.fromLTWH(
      inset,
      inset,
      size.width - strokeWidth,
      size.height - strokeWidth,
    );
    if (!dashed) {
      canvas.drawArc(rect, 0, 2 * math.pi, false, paint);
      return;
    }
    // 24 segments → 12 visible dashes with 12 gaps; tracks the CSS
    // `border-style: dashed` cadence for an 80px circle. Switch to
    // 32 if we ever shrink this widget; readability falls off when
    // segments drop under ~6 logical pixels each.
    const segments = 24;
    final segmentArc = (2 * math.pi) / segments;
    for (var i = 0; i < segments; i += 2) {
      final start = i * segmentArc;
      canvas.drawArc(rect, start, segmentArc, false, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.dashed != dashed;
}
