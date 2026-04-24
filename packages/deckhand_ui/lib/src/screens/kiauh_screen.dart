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
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final kiauh = profile?.stack.kiauh ?? const <String, dynamic>{};
    final explainer =
        ((kiauh['wizard'] as Map?)?['explainer'] as String?) ??
        'KIAUH is the Klipper Installation And Update Helper - an interactive '
            'SSH menu for maintaining your stack after Deckhand finishes.';
    final examples =
        ((kiauh['wizard'] as Map?)?['examples'] as List?)?.cast<String>() ??
        const [];
    final probe = controller.printerState;
    final alreadyInstalled =
        probe.stackInstalls['kiauh']?.installed ?? false;
    // On an already-installed system default to "skip" - no point
    // re-cloning. Still let the user pick Install (useful if they
    // want a clean re-clone) but mark it as not-needed.
    if (_install == null) {
      _install = alreadyInstalled
          ? false
          : (kiauh['default_install'] as bool? ?? true);
    }

    final theme = Theme.of(context);

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Install KIAUH?',
      helperText: explainer,
      body: RadioGroup<bool>(
        groupValue: _install,
        onChanged: (v) => setState(() => _install = v),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (alreadyInstalled) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12, vertical: 8),
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.check_circle,
                      size: 18,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'KIAUH is already installed at '
                        '${probe.stackInstalls['kiauh']?.path ?? "~/kiauh"}. '
                        'Default is to skip; pick Install only if you '
                        'want a clean re-clone.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            if (examples.isNotEmpty) ...[
              const Text(
                'What KIAUH does for you:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              for (final ex in examples) Text('- $ex'),
              const SizedBox(height: 12),
            ],
            RadioListTile<bool>(
              value: true,
              title: Text(alreadyInstalled
                  ? 'Re-install (clean clone)'
                  : 'Install KIAUH (recommended)'),
            ),
            RadioListTile<bool>(
              value: false,
              title: Text(alreadyInstalled
                  ? 'Skip (keep existing)'
                  : "Skip - I'll install it later if I want"),
            ),
          ],
        ),
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
