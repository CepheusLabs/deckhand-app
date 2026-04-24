/// Canonical shell-quoting helpers for Deckhand.
///
/// Every code path that interpolates a string into a shell command MUST
/// go through one of these helpers. Profile YAML is untrusted input.
/// The prior codebase had three private copies of this function and one
/// of them was wrong for tilde-prefixed paths, which is why this
/// module exists.
library;

/// POSIX shell single-quote escape.
///
/// Wraps [s] in single quotes, escaping any embedded single quote via
/// the standard `'\''` dance. Safe for passing arbitrary user input
/// (passwords, paths, flags) as a single argument without giving the
/// shell a chance to re-interpret it.
String shellSingleQuote(String s) {
  if (s.isEmpty) return "''";
  final escaped = s.replaceAll("'", r"'\''");
  return "'$escaped'";
}

/// Escape a path that may start with `~` for use as a shell argument.
///
/// Plain `shellSingleQuote('~/foo')` would suppress tilde expansion
/// (bash only expands `~` when unquoted or at the very start, never
/// inside single or double quotes). For tilde paths we emit
/// `"$HOME"'<single-quoted rest>'` which expands `$HOME` from the
/// surrounding double-quote context and leaves the rest inside a
/// single-quoted block where no further expansion can occur.
///
/// Absolute paths and all other forms are single-quoted directly.
String shellPathEscape(String path) {
  if (path == '~') return r'"$HOME"';
  if (path.startsWith('~/')) {
    final rest = path.substring(2);
    if (rest.isEmpty) return r'"$HOME"';
    return r'"$HOME"/' + shellSingleQuote(rest);
  }
  return shellSingleQuote(path);
}
