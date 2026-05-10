import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theming/deckhand_tokens.dart';
import 'deckhand_stepper.dart';
import 'dry_run_banner.dart';
import 'grid_background.dart';
import 'profile_text.dart';
import 'tick_rule.dart';

/// Standard layout for a wizard screen. Title + body + footer action row.
///
/// Visual structure (top to bottom):
///  * [DryRunBanner] when active.
///  * [DeckhandStepper] — 5-phase chip strip showing the current
///    step. The design language puts wizard navigation HERE, not in
///    a left rail; the stepper renders nothing on non-wizard routes.
///  * Screen head — `Title` + [helperText] + [TickRule].
///  * [body] — host content.
///  * Action bar — primary + secondary actions.
///
/// The [screenId] parameter is retained on the API but no longer
/// renders a visible chip — internal IDs are devs-only jargon. The
/// id is kept available for future hooks (analytics, deeplinks,
/// dev overlay).
class WizardScaffold extends StatelessWidget {
  const WizardScaffold({
    super.key,
    required this.title,
    required this.body,
    this.screenId,
    this.helperText,
    this.primaryAction,
    this.secondaryActions = const [],
    this.maxContentWidth = 1080,
  });

  final String title;
  final Widget body;
  final double maxContentWidth;

  /// Source-spec screen ID like `S15-pick-printer`. Reserved for
  /// future analytics / dev overlay use — does NOT render in the
  /// header today (would read as jargon to end users).
  final String? screenId;

  final String? helperText;
  final WizardAction? primaryAction;
  final List<WizardAction> secondaryActions;

  @override
  Widget build(BuildContext context) {
    // Keyboard shortcuts: Enter activates the primary action,
    // Esc activates the first "Back"-style secondary action.
    // Skipped entirely when neither is enabled so the shortcut
    // map doesn't swallow Enter inside a text field higher up.
    final primary = primaryAction;
    final back = _firstBackAction();
    final shortcuts = <ShortcutActivator, Intent>{
      if (primary?.onPressed != null && !primary!.destructive)
        LogicalKeySet(LogicalKeyboardKey.enter): const _ActivatePrimaryIntent(),
      if (primary?.onPressed != null && !primary!.destructive)
        LogicalKeySet(LogicalKeyboardKey.numpadEnter):
            const _ActivatePrimaryIntent(),
      if (back?.onPressed != null)
        LogicalKeySet(LogicalKeyboardKey.escape): const _ActivateBackIntent(),
    };
    final actions = <Type, Action<Intent>>{
      _ActivatePrimaryIntent: CallbackAction<_ActivatePrimaryIntent>(
        onInvoke: (_) {
          primary?.onPressed?.call();
          return null;
        },
      ),
      _ActivateBackIntent: CallbackAction<_ActivateBackIntent>(
        onInvoke: (_) {
          back?.onPressed?.call();
          return null;
        },
      ),
    };
    return Shortcuts(
      shortcuts: shortcuts,
      child: Actions(
        actions: actions,
        child: Focus(autofocus: true, child: _buildScaffold(context)),
      ),
    );
  }

  WizardAction? _firstBackAction() {
    // The locale-dependent label heuristic that used to live here is
    // gone. Callers must opt their back action in via `isBack: true`;
    // a localized "Zurück" or "戻る" would otherwise silently lose Esc.
    for (final a in secondaryActions) {
      if (a.isBack) return a;
    }
    if (primaryAction?.isBack == true) return primaryAction;
    return null;
  }

  Widget _buildScaffold(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Scaffold(
      // Each routed page paints its own opaque ink0 surface +
      // GridBackground texture so route transitions don't show two
      // pages at once. (When the grid lived in the chrome instead,
      // the fade-in transition revealed the previous page through
      // the new one's transparent body.)
      backgroundColor: tokens.ink0,
      body: GridBackground(
        child: Column(
          children: [
            const DryRunBanner(),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(32, 24, 32, 48),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxContentWidth),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const DeckhandStepper(),
                        _ScreenHead(title: title, helperText: helperText),
                        body,
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (primaryAction != null || secondaryActions.isNotEmpty)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: tokens.ink1,
                  border: Border(top: BorderSide(color: tokens.line)),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxContentWidth),
                    child: _WizardFooterActionBar(
                      primaryAction: primaryAction,
                      secondaryActions: secondaryActions,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WizardFooterActionBar extends StatelessWidget {
  const _WizardFooterActionBar({
    required this.primaryAction,
    required this.secondaryActions,
  });

  final WizardAction? primaryAction;
  final List<WizardAction> secondaryActions;

  @override
  Widget build(BuildContext context) {
    final leading = <Widget>[
      for (final action in secondaryActions) _secondaryButton(action),
      if (primaryAction?.isBack == true) _backButton(primaryAction!),
    ];
    final primary = primaryAction;
    final trailing = primary != null && !primary.isBack
        ? _primaryButton(context, primary)
        : null;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final button in leading) ...[
                Align(alignment: Alignment.centerLeft, child: button),
                const SizedBox(height: 8),
              ],
              if (trailing != null)
                Align(alignment: Alignment.centerRight, child: trailing),
            ],
          );
        }

        return Row(
          children: [
            for (final button in leading) ...[button, const SizedBox(width: 8)],
            const Spacer(),
            if (trailing != null) trailing,
          ],
        );
      },
    );
  }

  Widget _secondaryButton(WizardAction action) {
    if (action.isBack) return _backButton(action);
    return TextButton(
      onPressed: action.onPressed,
      child: Text(action.label, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _backButton(WizardAction action) {
    return OutlinedButton.icon(
      onPressed: action.onPressed,
      icon: const Icon(Icons.arrow_back, size: 14),
      label: Text(action.label, overflow: TextOverflow.ellipsis),
    );
  }

  Widget _primaryButton(BuildContext context, WizardAction action) {
    final theme = Theme.of(context);
    // Destructive actions advertise themselves to assistive tech so a
    // screen-reader user hears "flash disk, warning: destructive"
    // before activating the button.
    return Semantics(
      button: true,
      enabled: action.onPressed != null,
      label: action.destructive ? '${action.label}, destructive' : action.label,
      child: ExcludeSemantics(
        child: FilledButton.icon(
          onPressed: action.onPressed,
          style: action.destructive
              ? FilledButton.styleFrom(
                  backgroundColor: theme.colorScheme.error,
                  foregroundColor: theme.colorScheme.onError,
                )
              : null,
          icon: action.destructive
              ? const SizedBox.shrink()
              : const Icon(Icons.arrow_forward, size: 14),
          label: Text(action.label, overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}

class _ScreenHead extends StatelessWidget {
  const _ScreenHead({required this.title, required this.helperText});

  final String title;
  final String? helperText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = DeckhandTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w500,
                letterSpacing: -0.015 * DeckhandTokens.t2Xl,
                color: tokens.text,
              ),
            ),
          ),
          if (helperText != null) ...[
            const SizedBox(height: 8),
            // Helper text inherits the same width as the rest of the
            // screen body. The design source clamped this to 64ch
            // for paragraph readability, but in the app that made
            // the helper visibly narrower than the form below it,
            // which read as a layout bug rather than typography.
            Text(
              flattenProfileText(helperText),
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tMd,
                height: 1.5,
                color: tokens.text3,
              ),
            ),
          ],
          const SizedBox(height: 8),
          const TickRule(),
        ],
      ),
    );
  }
}

class WizardAction {
  const WizardAction({
    required this.label,
    required this.onPressed,
    this.destructive = false,
    this.isBack = false,
  });
  final String label;
  final VoidCallback? onPressed;

  /// Destructive actions refuse the Enter-key shortcut; the user must
  /// move focus + press Space or click explicitly. Matches the UI
  /// convention where "Flash disk" stays one deliberate action away
  /// from a stray keystroke.
  final bool destructive;

  /// When true, this action is the screen's "go back" affordance and
  /// Esc will fire it. Prefer this flag over heuristics on [label] —
  /// labels are localized, keyboards aren't.
  final bool isBack;
}

class _ActivatePrimaryIntent extends Intent {
  const _ActivatePrimaryIntent();
}

class _ActivateBackIntent extends Intent {
  const _ActivateBackIntent();
}
