import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ChooseOsScreen extends ConsumerStatefulWidget {
  const ChooseOsScreen({super.key});

  @override
  ConsumerState<ChooseOsScreen> createState() => _ChooseOsScreenState();
}

class _ChooseOsScreenState extends ConsumerState<ChooseOsScreen> {
  String? _choice;

  @override
  Widget build(BuildContext context) {
    final options =
        ref.watch(wizardControllerProvider).profile?.os.freshInstallOptions ??
        const [];
    if (_choice == null) {
      _choice = options.where((o) => o.recommended).firstOrNull?.id ??
          options.firstOrNull?.id;
    }

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Which OS image?',
      helperText:
          'Pick the base Linux image to flash onto your printer\'s eMMC. '
          'Deckhand downloads the image, verifies it, and writes it to the '
          'disk you chose.',
      body: RadioGroup<String>(
        groupValue: _choice,
        onChanged: (v) => setState(() => _choice = v),
        child: Column(
          children: [
            for (final opt in options)
              Card(
                color: _choice == opt.id
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: RadioListTile<String>(
                  value: opt.id,
                  title: Row(
                    children: [
                      Text(opt.displayName),
                      if (opt.recommended) ...[
                        const SizedBox(width: 8),
                        const Chip(
                          label: Text('Recommended'),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    [
                      opt.notes?.trim() ?? '',
                      if (opt.sizeBytesApprox != null)
                        '~${(opt.sizeBytesApprox! / (1 << 30)).toStringAsFixed(1)} GB download',
                    ].where((s) => s.isNotEmpty).join('\n'),
                  ),
                ),
              ),
          ],
        ),
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: _choice == null
            ? null
            : () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('flash.os', _choice!);
                if (context.mounted) context.go('/flash-confirm');
              },
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          onPressed: () => context.go('/flash-target'),
        ),
      ],
    );
  }
}

extension on Iterable {
  dynamic get firstOrNull => isEmpty ? null : first;
}
