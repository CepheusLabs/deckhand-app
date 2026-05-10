import 'package:flutter/material.dart';

import '../theming/deckhand_tokens.dart';

/// 5-phase compressed wizard stepper. Replaces the older
/// horizontal-overflow strip — a static row of phase chips that
/// always fits any width, with a click-to-expand popover on each
/// chip showing its substeps and their current state.
///
/// Anatomy:
///  * Phase chip — `[tick] Label  N/M` per phase. State is one of
///    done / current / future and drives color.
///  * Popover (on click) — vertical list of substeps; a substep is
///    `done` (✓), `current` (▸), `visited` (·), or `unvisited` (○).
///  * Right-side meta — current `[S15] Pick printer` for context.
///
/// Visited substeps in the current and prior phases are clickable
/// (jump-back navigation). The widget receives a [visitedIds] set
/// from above; if empty, no jump-back is offered.
class DeckhandWizardStepper extends StatefulWidget {
  const DeckhandWizardStepper({
    super.key,
    required this.phases,
    required this.currentStepId,
    required this.stepLabels,
    this.visitedIds = const {},
    this.onJumpTo,
  });

  /// Phase definitions — same order as the wizard flow. The phase
  /// containing [currentStepId] is highlighted.
  final List<WizardPhase> phases;

  /// `S15`, `S100`, etc. The current location in the flow.
  final String currentStepId;

  /// `S15` → `Pick printer`. Used in the popover and the right-side
  /// meta strip.
  final Map<String, String> stepLabels;

  /// Step IDs the user has reached. Visited steps in past or current
  /// phases are clickable to jump back. Default empty = no jump-back.
  final Set<String> visitedIds;

  /// Called with the target step ID when the user clicks a visited
  /// substep in the popover. The host is responsible for routing.
  final void Function(String stepId)? onJumpTo;

  @override
  State<DeckhandWizardStepper> createState() => _DeckhandWizardStepperState();
}

class WizardPhase {
  const WizardPhase({
    required this.id,
    required this.label,
    required this.stepIds,
  });

  final String id;
  final String label;

  /// Source-order list of step IDs in this phase.
  final List<String> stepIds;
}

class _DeckhandWizardStepperState extends State<DeckhandWizardStepper> {
  int? _openIdx;

  int get _currentPhaseIdx {
    final idx = widget.phases.indexWhere(
      (p) => p.stepIds.contains(widget.currentStepId),
    );
    return idx < 0 ? 0 : idx;
  }

  int get _stepInPhase {
    final phase = widget.phases[_currentPhaseIdx];
    final idx = phase.stepIds.indexOf(widget.currentStepId);
    return idx < 0 ? 0 : idx;
  }

  void _toggle(int i) {
    setState(() {
      _openIdx = _openIdx == i ? null : i;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final phaseIdx = _currentPhaseIdx;
    final stepIdx = _stepInPhase;
    final currentLabel =
        widget.stepLabels[widget.currentStepId] ?? widget.currentStepId;
    final phase = widget.phases[phaseIdx];

    return Container(
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 720;
          return Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 0; i < widget.phases.length; i++)
                      _PhaseChip(
                        phase: widget.phases[i],
                        state: i < phaseIdx
                            ? _PhaseState.done
                            : i == phaseIdx
                                ? _PhaseState.current
                                : _PhaseState.future,
                        countNumerator: i < phaseIdx
                            ? widget.phases[i].stepIds.length
                            : i == phaseIdx
                                ? stepIdx + 1
                                : null,
                        compact: compact,
                        open: _openIdx == i,
                        onTap: () => _toggle(i),
                        popoverChild: _Popover(
                          phase: widget.phases[i],
                          currentStepId: widget.currentStepId,
                          stepLabels: widget.stepLabels,
                          visitedIds: widget.visitedIds,
                          phaseIdx: i,
                          activePhaseIdx: phaseIdx,
                          stepInPhase: stepIdx,
                          onJumpTo: (sid) {
                            widget.onJumpTo?.call(sid);
                            setState(() => _openIdx = null);
                          },
                        ),
                      ),
                  ],
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 12),
                // Right meta — human-readable context. The internal
                // S-ID lived here previously but it's devs-only
                // jargon; "Step 2 of 4 in Entry — Pick printer" is
                // what an end user actually wants.
                Text(
                  'Step ${stepIdx + 1} of ${phase.stepIds.length} '
                  '· $currentLabel',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tXs,
                    color: tokens.text3,
                  ),
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}

enum _PhaseState { done, current, future }

class _PhaseChip extends StatelessWidget {
  const _PhaseChip({
    required this.phase,
    required this.state,
    required this.countNumerator,
    required this.compact,
    required this.open,
    required this.onTap,
    required this.popoverChild,
  });

  final WizardPhase phase;
  final _PhaseState state;
  final int? countNumerator;
  final bool compact;
  final bool open;
  final VoidCallback onTap;
  final Widget popoverChild;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final fg = switch (state) {
      _PhaseState.done => tokens.text2,
      _PhaseState.current => tokens.text,
      _PhaseState.future => tokens.text4,
    };
    final tickColor = switch (state) {
      _PhaseState.done => tokens.ok,
      _PhaseState.current => tokens.accent,
      _PhaseState.future => tokens.text4,
    };
    final tickWidth = state == _PhaseState.future ? 8.0 : 14.0;
    final bg = state == _PhaseState.current
        ? tokens.accentSoft
        : open
            ? tokens.ink2
            : Colors.transparent;
    final showLabel = !compact || state == _PhaseState.current;
    final showCount = !compact && countNumerator != null;
    final countColor = switch (state) {
      _PhaseState.done => tokens.ok,
      _PhaseState.current => tokens.accent,
      _PhaseState.future => tokens.text4,
    };
    final countBorder = switch (state) {
      _PhaseState.done => tokens.ok.withValues(alpha: 0.3),
      _PhaseState.current => tokens.accent.withValues(alpha: 0.35),
      _PhaseState.future => tokens.line,
    };

    return MenuAnchor(
      style: MenuStyle(
        backgroundColor: WidgetStateProperty.all(tokens.ink1),
        elevation: WidgetStateProperty.all(8),
        shape: WidgetStateProperty.all(RoundedRectangleBorder(
          side: BorderSide(color: tokens.line),
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
        )),
        padding: WidgetStateProperty.all(
          const EdgeInsets.symmetric(vertical: 8),
        ),
      ),
      builder: (context, controller, _) {
        return InkWell(
          onTap: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
            onTap();
          },
          borderRadius: BorderRadius.circular(DeckhandTokens.r1),
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 4, 10, 4),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(DeckhandTokens.r1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  width: tickWidth,
                  height: 2,
                  color: tickColor,
                ),
                if (showLabel) ...[
                  const SizedBox(width: 8),
                  Text(
                    phase.label,
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontSans,
                      fontSize: DeckhandTokens.tXs,
                      color: fg,
                    ),
                  ),
                ],
                if (showCount) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: countBorder),
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      '$countNumerator/${phase.stepIds.length}',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: 9,
                        color: countColor,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
      menuChildren: [
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 240, maxWidth: 320),
          child: popoverChild,
        ),
      ],
    );
  }
}

class _Popover extends StatelessWidget {
  const _Popover({
    required this.phase,
    required this.currentStepId,
    required this.stepLabels,
    required this.visitedIds,
    required this.phaseIdx,
    required this.activePhaseIdx,
    required this.stepInPhase,
    required this.onJumpTo,
  });

  final WizardPhase phase;
  final String currentStepId;
  final Map<String, String> stepLabels;
  final Set<String> visitedIds;
  final int phaseIdx;
  final int activePhaseIdx;
  final int stepInPhase;
  final void Function(String stepId) onJumpTo;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
          child: Text(
            '${phase.label.toUpperCase()} · ${phase.stepIds.length} STEP'
            '${phase.stepIds.length == 1 ? '' : 'S'}',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 9,
              color: tokens.text4,
              letterSpacing: 0,
            ),
          ),
        ),
        Container(height: 1, color: tokens.lineSoft),
        for (var j = 0; j < phase.stepIds.length; j++)
          _PopoverItem(
            sid: phase.stepIds[j],
            label: stepLabels[phase.stepIds[j]] ?? phase.stepIds[j],
            state: phaseIdx < activePhaseIdx
                ? _SubState.done
                : phaseIdx > activePhaseIdx
                    ? _SubState.future
                    : j < stepInPhase
                        ? _SubState.done
                        : j == stepInPhase
                            ? _SubState.current
                            : _SubState.future,
            visited: visitedIds.contains(phase.stepIds[j]),
            isCurrent: phase.stepIds[j] == currentStepId,
            onJumpTo: onJumpTo,
          ),
        Container(height: 1, color: tokens.lineSoft),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
          child: Text(
            'Tip — click any visited step to jump',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 9,
              color: tokens.text4,
              letterSpacing: 0,
            ),
          ),
        ),
      ],
    );
  }
}

enum _SubState { done, current, future }

class _PopoverItem extends StatelessWidget {
  const _PopoverItem({
    required this.sid,
    required this.label,
    required this.state,
    required this.visited,
    required this.isCurrent,
    required this.onJumpTo,
  });

  final String sid;
  final String label;
  final _SubState state;
  final bool visited;
  final bool isCurrent;
  final void Function(String stepId) onJumpTo;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final markerStyle = TextStyle(
      fontFamily: DeckhandTokens.fontMono,
      fontSize: 11,
      color: state == _SubState.done
          ? tokens.ok
          : state == _SubState.current
              ? tokens.accent
              : tokens.text4,
    );
    final marker = state == _SubState.done
        ? '✓'
        : state == _SubState.current
            ? '▸'
            : visited
                ? '·'
                : '○';
    final jumpable = visited && !isCurrent;
    final color = isCurrent
        ? tokens.text
        : state == _SubState.done
            ? tokens.text2
            : tokens.text3;

    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              marker,
              style: markerStyle,
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: 12,
                color: color,
              ),
            ),
          ),
          if (jumpable)
            Text(
              '↩',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 11,
                color: tokens.accent,
              ),
            ),
        ],
      ),
    );
    if (isCurrent) {
      row = Container(color: tokens.accentSoft, child: row);
    }
    if (!jumpable) {
      return Opacity(opacity: visited ? 1.0 : 0.55, child: row);
    }
    return InkWell(
      onTap: () => onJumpTo(sid),
      child: row,
    );
  }
}
