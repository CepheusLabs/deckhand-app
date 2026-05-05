import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Diff-style log view — the right pane on the install progress
/// screen. Renders raw log lines as `[time] [tag] [message]` rows,
/// color-coding the tag based on prefix conventions used by the
/// wizard controller (`[ok]`, `[fail]`, `[warn]`, `> starting …`).
///
/// The log line is the design's signature data treatment — a mono
/// gutter with a tag column that turns the screen into something
/// resembling a developer console rather than a generic install
/// progress bar.
class WizardLogView extends StatefulWidget {
  const WizardLogView({super.key, required this.lines});

  final List<String> lines;

  @override
  State<WizardLogView> createState() => _WizardLogViewState();
}

class _WizardLogViewState extends State<WizardLogView> {
  final _controller = ScrollController();

  @override
  void didUpdateWidget(covariant WizardLogView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lines.length != oldWidget.lines.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_controller.hasClients) return;
        _controller.animateTo(
          _controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    if (widget.lines.isEmpty) {
      return Center(
        child: Text(
          'Waiting for the first log line...',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
          ),
        ),
      );
    }
    return SelectionArea(
      child: ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: widget.lines.length,
        itemBuilder: (context, i) => _LogLine(
          raw: widget.lines[i],
          tokens: tokens,
          // Approximate "now-ish" timestamp ordinal — the controller
          // doesn't currently emit timestamps with each line, so we
          // synthesize a stable index-based marker for visual rhythm.
          ordinal: i,
        ),
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({
    required this.raw,
    required this.tokens,
    required this.ordinal,
  });
  final String raw;
  final DeckhandTokens tokens;
  final int ordinal;

  @override
  Widget build(BuildContext context) {
    final parsed = _parse(raw);
    final tagColor = switch (parsed.kind) {
      _LogKind.ok => tokens.ok,
      _LogKind.fail => tokens.bad,
      _LogKind.warn => tokens.warn,
      _LogKind.exec => tokens.accent,
      _LogKind.info => tokens.info,
      _LogKind.input => tokens.text3,
      _LogKind.dim => tokens.text4,
    };
    final rowBg = switch (parsed.kind) {
      _LogKind.fail => tokens.bad.withValues(alpha: 0.06),
      _LogKind.warn => tokens.warn.withValues(alpha: 0.06),
      _ => Colors.transparent,
    };
    final rowBorder = switch (parsed.kind) {
      _LogKind.fail => tokens.bad,
      _LogKind.warn => tokens.warn,
      _ => Colors.transparent,
    };
    return Container(
      decoration: BoxDecoration(
        color: rowBg,
        border: Border(left: BorderSide(color: rowBorder, width: 2)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              _ordinalLabel(ordinal),
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tXs,
                color: tokens.text4,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 56,
            child: Text(
              parsed.tag,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tXs,
                color: tagColor,
                height: 1.6,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              parsed.msg,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tXs,
                color: tokens.text2,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Synthesize a `mm:ss.frac`-shaped marker from the line index.
  String _ordinalLabel(int n) {
    final m = (n ~/ 60).toString().padLeft(2, '0');
    final s = (n % 60).toString().padLeft(2, '0');
    return '$m:$s.${(n * 17 % 1000).toString().padLeft(3, '0')}';
  }

  _Parsed _parse(String raw) {
    if (raw.startsWith('[ok] ')) {
      return _Parsed(_LogKind.ok, 'OK', raw.substring(5));
    }
    if (raw.startsWith('[fail] ')) {
      return _Parsed(_LogKind.fail, 'FAIL', raw.substring(7));
    }
    if (raw.startsWith('[warn] ')) {
      return _Parsed(_LogKind.warn, 'WARN', raw.substring(7));
    }
    if (raw.startsWith('> starting ')) {
      return _Parsed(_LogKind.exec, 'STEP', raw.substring(2));
    }
    if (raw.startsWith('> ')) {
      return _Parsed(_LogKind.info, 'EXEC', raw.substring(2));
    }
    if (raw.startsWith('[input] ')) {
      return _Parsed(_LogKind.input, 'INPUT', raw.substring(8));
    }
    if (raw.startsWith('[os] ')) {
      return _Parsed(_LogKind.info, 'OS', raw.substring(5));
    }
    return _Parsed(_LogKind.dim, '...', raw);
  }
}

enum _LogKind { ok, fail, warn, exec, info, input, dim }

class _Parsed {
  _Parsed(this.kind, this.tag, this.msg);
  final _LogKind kind;
  final String tag;
  final String msg;
}
