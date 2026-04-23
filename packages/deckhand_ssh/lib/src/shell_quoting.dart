/// POSIX shell single-quote escape.
///
/// Wraps [s] in single quotes, escaping any embedded single quote via
/// the standard `'\''` dance. Safe for passing arbitrary user input
/// (passwords, paths, flags) as a single argument without giving the
/// shell a chance to re-interpret it.
///
/// Lives in its own file so tests can pin the semantics down without
/// depending on the full dartssh_service surface.
String shellSingleQuote(String s) {
  final escaped = s.replaceAll("'", r"'\''");
  return "'$escaped'";
}
