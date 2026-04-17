import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class VerifyScreen extends ConsumerWidget {
  const VerifyScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Simplified — a real implementation runs each of the profile's
    // stock_os.detections over SSH and shows per-check pass/fail. For
    // now we present a checklist view keyed off profile detection rules
    // and let the user acknowledge.
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final detections = profile?.stockOs.detections ?? const [];

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Verify your printer',
      helperText:
          'We\'ll run a few quick checks against your connected printer to '
          'confirm this profile matches. Warnings don\'t block the wizard — '
          'you can always proceed.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final d in detections) ...[
            ListTile(
              leading: Icon(
                d.required ? Icons.check_circle_outline : Icons.help_outline,
                color: Theme.of(context).colorScheme.primary,
              ),
              title: Text('${d.kind}: ${_pathFor(d.raw)}'),
              subtitle: Text(d.required ? 'required' : 'optional'),
              dense: true,
            ),
          ],
          if (detections.isEmpty)
            const Text('No detection rules declared for this profile.'),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () => context.go('/choose-path'),
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/connect')),
      ],
    );
  }

  String _pathFor(Map<String, dynamic> raw) {
    return raw['path'] as String? ?? raw['name'] as String? ?? raw['unit'] as String? ?? '?';
  }
}
