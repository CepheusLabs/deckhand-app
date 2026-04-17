import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(wizardControllerProvider).state;
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Review your choices',
      helperText:
          'Every decision you made is listed below. Deckhand will execute '
          'them in order once you start. You can go back to any step using '
          'the stepper at the top.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Flow: ${state.flow.name}'),
                  Text('Printer: ${state.profileId}'),
                  if (state.sshHost != null)
                    Text('SSH host: ${state.sshHost}'),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  for (final e in state.decisions.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('${e.key}: ${e.value}'),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            value: _confirmed,
            onChanged: (v) => setState(() => _confirmed = v ?? false),
            title: const Text('I understand and want to proceed.'),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Start install',
        onPressed: _confirmed ? () => context.go('/progress') : null,
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/hardening')),
      ],
    );
  }
}
