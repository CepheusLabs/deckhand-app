import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class KiauhScreen extends ConsumerStatefulWidget {
  const KiauhScreen({super.key});

  @override
  ConsumerState<KiauhScreen> createState() => _KiauhScreenState();
}

class _KiauhScreenState extends ConsumerState<KiauhScreen> {
  bool? _install;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(wizardControllerProvider).profile;
    final kiauh = profile?.stack.kiauh ?? const <String, dynamic>{};
    final explainer = ((kiauh['wizard'] as Map?)?['explainer'] as String?) ??
        'KIAUH is the Klipper Installation And Update Helper — an interactive '
            'SSH menu for maintaining your stack after Deckhand finishes.';
    final examples =
        ((kiauh['wizard'] as Map?)?['examples'] as List?)?.cast<String>() ?? const [];
    _install ??= kiauh['default_install'] as bool? ?? true;

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Install KIAUH?',
      helperText: explainer,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (examples.isNotEmpty) ...[
            const Text('What KIAUH does for you:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            for (final ex in examples) Text('• $ex'),
            const SizedBox(height: 12),
          ],
          RadioListTile<bool>(
            value: true,
            groupValue: _install,
            onChanged: (v) => setState(() => _install = v),
            title: const Text('Install KIAUH (recommended)'),
          ),
          RadioListTile<bool>(
            value: false,
            groupValue: _install,
            onChanged: (v) => setState(() => _install = v),
            title: const Text('Skip — I\'ll install it later if I want'),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () async {
          await ref
              .read(wizardControllerProvider)
              .setDecision('kiauh', _install!);
          if (context.mounted) context.go('/screen-choice');
        },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/webui')),
      ],
    );
  }
}
