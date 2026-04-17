import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import 'wizard_stepper.dart';

/// Context-aware stepper that derives its step list + current index from
/// the active wizard state and GoRouter location. Every [WizardScaffold]
/// gets one of these via `DeckhandStepper()` in its `stepper` slot.
class DeckhandStepper extends ConsumerWidget {
  const DeckhandStepper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final flow = ref.watch(wizardControllerProvider).state.flow;
    final currentLocation = GoRouterState.of(context).uri.path;
    final steps = _stepsForFlow(flow);
    final currentIndex =
        steps.indexWhere((s) => s.routes.contains(currentLocation));

    return WizardStepper(
      steps: steps.map((s) => WizardStepperItem(label: s.label)).toList(),
      currentIndex: currentIndex < 0 ? 0 : currentIndex,
      onStepTap: (i) => context.go(steps[i].routes.first),
    );
  }

  List<_StepEntry> _stepsForFlow(WizardFlow flow) {
    final base = [
      const _StepEntry(label: 'Welcome', routes: ['/']),
      const _StepEntry(label: 'Pick', routes: ['/pick-printer']),
      const _StepEntry(label: 'Connect', routes: ['/connect']),
      const _StepEntry(label: 'Verify', routes: ['/verify']),
      const _StepEntry(label: 'Path', routes: ['/choose-path']),
    ];
    switch (flow) {
      case WizardFlow.stockKeep:
        return [
          ...base,
          const _StepEntry(label: 'Firmware', routes: ['/firmware']),
          const _StepEntry(label: 'Web UI', routes: ['/webui']),
          const _StepEntry(label: 'KIAUH', routes: ['/kiauh']),
          const _StepEntry(label: 'Screen', routes: ['/screen-choice']),
          const _StepEntry(label: 'Services', routes: ['/services']),
          const _StepEntry(label: 'Files', routes: ['/files']),
          const _StepEntry(label: 'Harden', routes: ['/hardening']),
          const _StepEntry(label: 'Review', routes: ['/review']),
          const _StepEntry(label: 'Install', routes: ['/progress']),
          const _StepEntry(label: 'Done', routes: ['/done']),
        ];
      case WizardFlow.freshFlash:
        return [
          ...base,
          const _StepEntry(label: 'Disk', routes: ['/flash-target']),
          const _StepEntry(label: 'Image', routes: ['/choose-os']),
          const _StepEntry(label: 'Confirm', routes: ['/flash-confirm']),
          const _StepEntry(label: 'Write', routes: ['/flash-progress']),
          const _StepEntry(label: 'Reboot', routes: ['/first-boot']),
          const _StepEntry(label: 'User', routes: ['/first-boot-setup']),
          const _StepEntry(label: 'Firmware', routes: ['/firmware']),
          const _StepEntry(label: 'Web UI', routes: ['/webui']),
          const _StepEntry(label: 'KIAUH', routes: ['/kiauh']),
          const _StepEntry(label: 'Screen', routes: ['/screen-choice']),
          const _StepEntry(label: 'Review', routes: ['/review']),
          const _StepEntry(label: 'Install', routes: ['/progress']),
          const _StepEntry(label: 'Done', routes: ['/done']),
        ];
      case WizardFlow.none:
        return base;
    }
  }
}

class _StepEntry {
  const _StepEntry({required this.label, required this.routes});
  final String label;
  final List<String> routes;
}
