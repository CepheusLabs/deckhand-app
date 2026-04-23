import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import 'wizard_stepper.dart';

/// Context-aware stepper that derives its step list + current index from
/// the active wizard state and GoRouter location. Every [WizardScaffold]
/// gets one of these via `DeckhandStepper()` in its `stepper` slot.
class DeckhandStepper extends ConsumerWidget {
  const DeckhandStepper({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch events so the stepper rebuilds when the controller's
    // currentStepKind changes mid-execution. Without this the
    // phase-aware label on /progress would stay frozen at whatever
    // was active when the route first mounted.
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final flow = controller.state.flow;
    final currentLocation = GoRouterState.of(context).uri.path;
    final steps = _stepsForFlow(flow);
    final currentIndex = steps.indexWhere(
      (s) => s.routes.contains(currentLocation),
    );

    // Phase-aware override: when the active card is the unified
    // /progress screen, ask the controller for its currentStepKind
    // and swap the generic "Install" label for something specific.
    final resolvedSteps = [
      for (var i = 0; i < steps.length; i++)
        if (i == currentIndex && steps[i].routes.contains('/progress'))
          _StepEntry(
            label: _phaseLabel(controller.currentStepKind) ?? steps[i].label,
            routes: steps[i].routes,
          )
        else
          steps[i],
    ];

    return WizardStepper(
      steps: resolvedSteps
          .map((s) => WizardStepperItem(label: s.label))
          .toList(),
      currentIndex: currentIndex < 0 ? 0 : currentIndex,
      onStepTap: (i) => context.go(steps[i].routes.first),
    );
  }

  /// Map a wizard step kind to a short stepper-label. Returns null to
  /// fall back to the default label for this entry.
  String? _phaseLabel(String? kind) => switch (kind) {
        'os_download' => t.progress.phase_os_download,
        'flash_disk' => t.progress.phase_flash_disk,
        'wait_for_ssh' => t.progress.phase_wait_for_ssh,
        'install_firmware' => t.progress.phase_install_firmware,
        'install_stack' => t.progress.phase_install_stack,
        'flash_mcus' => t.progress.phase_flash_mcus,
        'install_marker' => t.progress.phase_install_marker,
        'verify' => t.progress.phase_verify,
        _ => null,
      };

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
          // Single unified progress screen owns write, reboot wait, and
          // post-boot setup steps. Older routes kept as aliases below.
          const _StepEntry(
            label: 'Install',
            routes: ['/progress', '/flash-progress', '/first-boot'],
          ),
          const _StepEntry(label: 'User', routes: ['/first-boot-setup']),
          const _StepEntry(label: 'Firmware', routes: ['/firmware']),
          const _StepEntry(label: 'Web UI', routes: ['/webui']),
          const _StepEntry(label: 'KIAUH', routes: ['/kiauh']),
          const _StepEntry(label: 'Screen', routes: ['/screen-choice']),
          const _StepEntry(label: 'Review', routes: ['/review']),
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
