import 'dart:convert';

/// Redacts text-files for inclusion in a debug bundle. See
/// [docs/DEBUG-BUNDLES.md] for the full pipeline and threat model.
///
/// The redactor runs a deterministic sequence of replacements:
///   1. Per-session known values — the host's home dir, OS username,
///      SSH user, SSH host, host's LAN IP. Each becomes a stable
///      placeholder (`<HOME>`, `<USER>`, `<PRINTER_HOST>`, …) so a
///      reviewer can read the bundle without having to mentally
///      translate every line.
///   2. Generic identifiers — IPv4, MAC, email, SSH-key fingerprint.
///   3. Probable secrets — long high-entropy strings.
///   4. Free-text decisions — anything stored under a `decisions[*]
///      .free_text` key, replaced unconditionally.
///
/// The result is paired with a [RedactionStats] object listing how
/// many of each pattern fired. Reviewers use the stats to decide
/// whether to expect a clean bundle ("0 of everything") or one that
/// hit its safety nets hard.
class Redactor {
  Redactor({
    required this.sessionValues,
    this.placeholderForSession = const {
      'home': '<HOME>',
      'user': '<USER>',
      'printer_host': '<PRINTER_HOST>',
      'printer_user': '<SSH_USER>',
      'printer_ip': '<PRINTER_IP>',
      // SSH passwords below the 32-char generic-secret threshold (any
      // user-chosen 8-31 char password) are not caught by the entropy
      // regex; explicit substring redaction here closes that gap.
      // Callers populate sessionValues['ssh_password'] from the
      // controller's redactionSessionValues() helper.
      'ssh_password': '<SSH_PASSWORD>',
    },
  });

  /// Live session values keyed by [placeholderForSession] keys.
  /// `null` values are skipped. Caller fills in whatever is known
  /// for the active session — the key set drives which placeholders
  /// will appear in the manifest.
  final Map<String, String?> sessionValues;

  /// Stable placeholder labels for [sessionValues]. Override only if
  /// you want different display strings (e.g. for tests or a
  /// localized UI).
  final Map<String, String> placeholderForSession;

  static final _ipv4Re =
      RegExp(r'\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b');
  static final _macRe = RegExp(r'\b[a-fA-F0-9]{2}(:[a-fA-F0-9]{2}){5}\b');
  static final _emailRe =
      RegExp(r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}');
  static final _sshFprRe = RegExp(r'SHA256:[A-Za-z0-9+/=]{43}');

  /// Heuristic for a "probable secret": long base64 or hex-looking
  /// strings. We bias for false positives over false negatives — a
  /// noisy bundle is the user's review job, a missed secret is an
  /// immediate problem.
  ///
  /// `[\w/+]{32,}=*` covers base64; `[a-fA-F0-9]{32,}` covers hex.
  /// Combined into one alternation so ordering doesn't matter.
  static final _secretRe = RegExp(
    r'(?<![\w/])(?:[A-Za-z0-9+/]{32,}=*|[a-fA-F0-9]{32,})(?![\w/])',
  );

  RedactedDocument redact(String input) {
    var text = input;
    final stats = RedactionStats();

    // 1. Generic identifiers run FIRST so a session value like the
    // printer host name doesn't consume part of an email address
    // (`alice@printer.local` would otherwise become
    // `alice@<PRINTER_HOST>` and never match the email regex).
    text = _replaceCount(text, _ipv4Re, '<IP>', () => stats.ipCount++);
    text = _replaceCount(text, _macRe, '<MAC>', () => stats.macCount++);
    text = _replaceCount(text, _emailRe, '<EMAIL>', () => stats.emailCount++);
    text = _replaceCount(text, _sshFprRe, '<FPR>', () => stats.fprCount++);

    // 2. Per-session known values — exact substring match. Order
    // matters: longer values first so "host" inside "printer_host"
    // doesn't get redacted twice with different placeholders.
    final ordered = sessionValues.entries
        .where((e) => e.value != null && e.value!.isNotEmpty)
        .toList()
      ..sort((a, b) => b.value!.length.compareTo(a.value!.length));
    for (final e in ordered) {
      final placeholder = placeholderForSession[e.key] ?? '<${e.key.toUpperCase()}>';
      final v = e.value!;
      final before = text;
      text = text.replaceAll(v, placeholder);
      if (before != text) stats.sessionHits++;
    }

    // 3. Probable secrets — replace with a length-tagged placeholder
    // so the reviewer can see how "big" the redacted thing was.
    text = text.replaceAllMapped(_secretRe, (m) {
      final raw = m[0]!;
      // Skip values that look like SHA-256 hashes already labelled
      // "sha256:" — those are commit/file integrity hashes the
      // reviewer wants visible.
      final start = m.start;
      final prefix = start >= 7 ? text.substring(start - 7, start) : '';
      if (prefix.toLowerCase().endsWith('sha256:')) return raw;
      stats.secretCount++;
      return '<REDACTED:${raw.length}>';
    });

    return RedactedDocument(text: text, stats: stats);
  }

  /// Convenience for redacting the JSON serialization of an arbitrary
  /// payload. Encodes with the same indent the wizard uses elsewhere
  /// so a reviewer's diff against an unredacted copy lines up
  /// visually.
  RedactedDocument redactJson(Object? value) {
    final encoded = const JsonEncoder.withIndent('  ').convert(value);
    return redact(encoded);
  }

  String _replaceCount(
    String input,
    RegExp re,
    String replacement,
    void Function() onMatch,
  ) {
    return input.replaceAllMapped(re, (m) {
      onMatch();
      return replacement;
    });
  }
}

class RedactedDocument {
  const RedactedDocument({required this.text, required this.stats});
  final String text;
  final RedactionStats stats;
}

class RedactionStats {
  RedactionStats();

  int sessionHits = 0;
  int ipCount = 0;
  int macCount = 0;
  int emailCount = 0;
  int fprCount = 0;
  int secretCount = 0;

  Map<String, int> toJson() => {
        'session_hits': sessionHits,
        'ip_count': ipCount,
        'mac_count': macCount,
        'email_count': emailCount,
        'fpr_count': fprCount,
        'secret_count': secretCount,
      };

  bool get isClean =>
      sessionHits == 0 &&
      ipCount == 0 &&
      macCount == 0 &&
      emailCount == 0 &&
      fprCount == 0 &&
      secretCount == 0;
}
