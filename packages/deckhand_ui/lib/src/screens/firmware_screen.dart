import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FirmwareScreen extends ConsumerStatefulWidget {
  const FirmwareScreen({super.key});

  @override
  ConsumerState<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends ConsumerState<FirmwareScreen> {
  String? _choice;

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(wizardControllerProvider).profile;
    final choices = profile?.firmware.choices ?? const [];
    _choice ??= profile?.firmware.defaultChoice ??
        (choices.isNotEmpty ? choices.first.id : null);

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Pick your firmware',
      helperText:
          'Kalico is a community-maintained Klipper fork with weekly '
          'rebases and some helpful extras (gcode_shell_command, danger_'
          'options). Mainline Klipper is upstream/master — more conservative.',
      body: Column(
        children: [
          for (final c in choices)
            Card(
              elevation: _choice == c.id ? 4 : 1,
              color: _choice == c.id
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: RadioListTile<String>(
                value: c.id,
                groupValue: _choice,
                onChanged: (v) => setState(() => _choice = v),
                title: Row(
                  children: [
                    Text(c.displayName),
                    if (c.recommended) ...[
                      const SizedBox(width: 8),
                      const Chip(
                        label: Text('Recommended'),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ],
                ),
                subtitle: Text(
                  '${c.description ?? ''}\n${c.repo} @ ${c.ref}',
                  maxLines: 3,
                ),
              ),
            ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: _choice == null
            ? null
            : () async {
                await ref.read(wizardControllerProvider).setDecision('firmware', _choice!);
                if (context.mounted) context.go('/webui');
              },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/choose-path')),
      ],
    );
  }
}
