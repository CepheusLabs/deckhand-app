import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import 'deckhand_wizard_stepper.dart';
import 'wizard_nav_map.dart';

/// Wizard-state-aware adapter around [DeckhandWizardStepper]. Reads
/// the active wizard state + current route, maps them to a screen-ID
/// (`S15`, `S40`, …) plus a phase, and delegates rendering to the
/// underlying compressed-phase stepper.
///
/// Used as `const DeckhandStepper()` in every [WizardScaffold].
class DeckhandStepper extends ConsumerWidget {
  const DeckhandStepper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch wizard state so the chip + popover redraw when the
    // controller advances or the user picks a flow. Tests that pump
    // a bare WizardScaffold (e.g. wizard_scaffold_shortcuts_test)
    // don't wire the wizard controller — degrade to an empty
    // placeholder rather than throwing UnimplementedProvider so
    // the scaffold remains testable in isolation.
    final WizardController controller;
    try {
      ref.watch(wizardStateProvider);
      controller = ref.watch(wizardControllerProvider);
    } on UnimplementedError {
      return const SizedBox.shrink();
    }
    final flow = controller.state.flow;
    // Orthogonal pages (Settings, Error) reuse [WizardScaffold] for
    // chrome but aren't part of the wizard flow. Showing a stepper
    // there would mislabel them as "Entry · Welcome". Same defense
    // for tests where there's no GoRouter ancestor.
    final GoRouterState routerState;
    try {
      routerState = GoRouterState.of(context);
    } catch (_) {
      return const SizedBox.shrink();
    }
    final location = routerState.uri.path;
    if (!WizardNavMap.isWizardRoute(location)) {
      return const SizedBox.shrink();
    }
    final currentSid = WizardNavMap.routeToSid(
      location: location,
      flow: flow,
      stepKind: controller.currentStepKind,
    );

    final order = WizardNavMap.orderForFlow(flow);
    final currentIdx = order.indexOf(currentSid);
    // Visited = everything up to and including the current step in
    // the canonical order. Jump-back via popover stays scoped to
    // steps the user has already passed through.
    final visited = currentIdx < 0
        ? <String>{}
        : order.take(currentIdx + 1).toSet();

    // The 24px bottom margin is part of the stepper's contract (the
    // design language puts a fixed gap between stepper and screen
    // head). Folding it in here means the host scaffold doesn't have
    // to distinguish wizard-route screens from orthogonal ones.
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: DeckhandWizardStepper(
        phases: WizardNavMap.phasesForFlow(flow),
        currentStepId: currentSid,
        stepLabels: WizardNavMap.stepLabels,
        visitedIds: visited,
        onJumpTo: (sid) {
          final route = WizardNavMap.sidToRoute(sid);
          if (route != null) context.go(route);
        },
      ),
    );
  }
}
