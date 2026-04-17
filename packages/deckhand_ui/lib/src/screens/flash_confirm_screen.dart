import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FlashConfirmScreen extends ConsumerStatefulWidget {
  const FlashConfirmScreen({super.key});

  @override
  ConsumerState<FlashConfirmScreen> createState() => _FlashConfirmScreenState();
}

class _FlashConfirmScreenState extends ConsumerState<FlashConfirmScreen> {
  bool _backedUp = false;
  bool _understand = false;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(wizardControllerProvider);
    final diskId = controller.decision<String>('flash.disk');
    final osId = controller.decision<String>('flash.os');
    final theme = Theme.of(context);
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Confirm the wipe',
      helperText: 'About to write $osId to $diskId. '
          'This erases EVERYTHING on that disk. No undo.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            color: theme.colorScheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: theme.colorScheme.onErrorContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Writing $osId onto $diskId will permanently erase its '
                      'existing contents. Double-check the disk identifier '
                      'before continuing.',
                      style: TextStyle(
                          color: theme.colorScheme.onErrorContainer),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          CheckboxListTile(
            value: _backedUp,
            onChanged: (v) => setState(() => _backedUp = v ?? false),
            title: const Text('I\'ve backed up anything I need from this disk.'),
          ),
          CheckboxListTile(
            value: _understand,
            onChanged: (v) => setState(() => _understand = v ?? false),
            title: const Text('I understand this cannot be undone.'),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Wipe and flash',
        destructive: true,
        onPressed: _backedUp && _understand
            ? () async {
                final ok = await _finalConfirm(context, diskId ?? '?');
                if (ok == true && context.mounted) context.go('/flash-progress');
              }
            : null,
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/choose-os')),
      ],
    );
  }

  Future<bool?> _finalConfirm(BuildContext context, String diskId) async =>
      showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('Wipe $diskId?'),
          content: const Text('This action is irreversible. Confirm to proceed.'),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Yes, wipe this disk'),
            ),
          ],
        ),
      );
}
