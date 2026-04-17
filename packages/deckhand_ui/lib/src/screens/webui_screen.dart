import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class WebuiScreen extends ConsumerStatefulWidget {
  const WebuiScreen({super.key});

  @override
  ConsumerState<WebuiScreen> createState() => _WebuiScreenState();
}

class _WebuiScreenState extends ConsumerState<WebuiScreen> {
  final _selected = <String>{};

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(wizardControllerProvider).profile;
    final webui = profile?.stack.webui ?? const {};
    final choices = ((webui['choices'] as List?) ?? const []).cast<Map>();
    final defaultChoices =
        ((webui['default_choices'] as List?) ?? const []).cast<String>();
    if (_selected.isEmpty) _selected.addAll(defaultChoices);

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Which web interface?',
      helperText:
          'Both Mainsail and Fluidd talk to Moonraker — pick one, the other, '
          'or install both and switch per session. Neither is a power-user '
          'option: Moonraker is still installed; you can add a UI later.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final raw in choices)
            CheckboxListTile(
              value: _selected.contains(raw['id']),
              onChanged: (v) => setState(() {
                final id = raw['id'] as String;
                if (v == true) {
                  _selected.add(id);
                } else {
                  _selected.remove(id);
                }
              }),
              title: Text(raw['display_name'] as String? ?? raw['id'] as String),
              subtitle: Text(
                '${raw['release_repo']} — port ${raw['default_port']}',
              ),
            ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () async {
          await ref
              .read(wizardControllerProvider)
              .setDecision('webui', _selected.toList());
          if (context.mounted) context.go('/kiauh');
        },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/firmware')),
      ],
    );
  }
}
