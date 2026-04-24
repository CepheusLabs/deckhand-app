/// Re-export of the canonical shell-quoting helpers from deckhand_core.
///
/// Kept as a thin shim so existing `package:deckhand_ssh/src/shell_quoting.dart`
/// imports continue to resolve. New code should import from
/// `package:deckhand_core/deckhand_core.dart` directly.
export 'package:deckhand_core/deckhand_core.dart' show shellSingleQuote, shellPathEscape;
