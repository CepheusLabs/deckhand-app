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
class WizardLogView extends StatelessWidget {
  const WizardLogView({super.key, required this.lines});

  final List<String> lines;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: lines.length,
      itemBuilder: (context, i) => _LogLine(
        raw: lines[i],
        tokens: tokens,
        // Approximate "now-ish" timestamp ordinal — the controller
        // doesn't currently emit timestamps with each line, so we
        // synthesize a stable index-based marker for visual rhythm.
        ordinal: i,
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
      _LogKind.dim => tokens.text4,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
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
                height: 1.7,
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
                height: 1.7,
                letterSpacing: 0.04 * DeckhandTokens.tXs,
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
                height: 1.7,
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
    return _Parsed(_LogKind.dim, '...', raw);
  }
}

enum _LogKind { ok, fail, warn, exec, info, dim }

class _Parsed {
  _Parsed(this.kind, this.tag, this.msg);
  final _LogKind kind;
  final String tag;
  final String msg;
}
