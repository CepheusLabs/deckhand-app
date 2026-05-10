import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// Small monospace badge used across the wizard to indicate state
/// (service running, screen installed, profile status, etc.).
///
/// Visual spec — matches the design language `.pill`:
///  * 18px tall, 9px radius (full-pill).
///  * Monospace, 10px, uppercase, semibold, tracking 0.06em.
///  * Tinted background (8% of color) + tinted border (40% of color).
///  * Optional 5×5 leading dot at the full color (suppress with
///    [noDot] for inline pills where the dot would crowd the text).
///
/// Factories:
///   * [StatusPill.new] - explicit color, dotted variant.
///   * [StatusPill.bordered] - retained for back-compat; the new
///     pill is always bordered, so this is now an alias.
///   * [StatusPill.fromKlippyState] - ready/printing/etc mapped to
///     semantic theme colors; adds a Semantics label.
///   * [StatusPill.fromProfileStatus] - stable/beta/alpha/etc mapped
///     to semantic theme colors.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.noDot = false,
    this.semanticsLabel,
  }) : bordered = true;

  /// Back-compat alias. The new pill is always bordered, so the
  /// [bordered] flag is now informational rather than visual.
  const StatusPill.bordered({
    super.key,
    required this.label,
    required this.color,
    this.noDot = false,
    this.semanticsLabel,
  }) : bordered = true;

  /// Maps a Klipper/Klippy state string (ready, printing, startup,
  /// error, etc.) to a semantic theme color. Used on the connect
  /// screen to tint each discovered printer card's state chip.
  factory StatusPill.fromKlippyState(
    BuildContext context,
    String state,
  ) {
    final tokens = DeckhandTokens.of(context);
    final normalized = state.toLowerCase();
    final color = switch (normalized) {
      'ready' || 'printing' => tokens.ok,
      'startup' || 'shutdown' => tokens.warn,
      'error' || 'disconnected' => tokens.bad,
      _ => tokens.text3,
    };
    return StatusPill(
      label: normalized,
      color: color,
      semanticsLabel: 'Klipper state $normalized',
    );
  }

  /// Maps a profile `status` field (stable/beta/alpha/experimental/
  /// deprecated) to a semantic theme color. Used on pick_printer and
  /// screen_choice to tint the status badge on each card.
  factory StatusPill.fromProfileStatus(
    BuildContext context,
    String status,
  ) {
    final tokens = DeckhandTokens.of(context);
    final color = switch (status) {
      'stable' => tokens.ok,
      'beta' => tokens.info,
      'alpha' => tokens.accent,
      'experimental' || 'deprecated' => tokens.bad,
      _ => tokens.text3,
    };
    return StatusPill(label: status, color: color);
  }

  final String label;
  final Color color;
  // Retained on the public surface so older callers compile.
  // Always-true under the new visual; the field is kept so the
  // back-compat constructor keeps a stable shape.
  final bool bordered;
  final bool noDot;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    // Bg and border tints — uniform recipe regardless of which color
    // was passed in. Source spec uses `color-mix(in oklch, color N%,
    // transparent)`; alpha-blending on top of the panel ink gives an
    // equivalent visual without needing OKLCH at runtime.
    final bgAlpha = color.withValues(alpha: 0.10);
    final borderAlpha = color.withValues(alpha: 0.40);
    final pill = Container(
      height: 18,
      padding: EdgeInsets.symmetric(horizontal: noDot ? 7 : 6),
      decoration: BoxDecoration(
        color: bgAlpha,
        border: Border.all(color: borderAlpha),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!noDot) ...[
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: color,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
    if (semanticsLabel != null) {
      return Semantics(label: semanticsLabel, child: pill);
    }
    return pill;
  }
}
