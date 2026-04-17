import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ChoosePathScreen extends ConsumerStatefulWidget {
  const ChoosePathScreen({super.key});

  @override
  ConsumerState<ChoosePathScreen> createState() => _ChoosePathScreenState();
}

class _ChoosePathScreenState extends ConsumerState<ChoosePathScreen> {
  WizardFlow _choice = WizardFlow.stockKeep;

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Which path do you want to take?',
      helperText:
          'Choose whether to reuse the OS already on your printer or wipe '
          'the eMMC and install a fresh Armbian image. Both lead to the same '
          'final state (Kalico or Klipper + your chosen web UI); they differ '
          'in blast radius and in what you have to manage yourself.',
      body: Column(
        children: [
          _PathCard(
            icon: Icons.swap_horiz,
            title: 'Keep my current OS',
            body: 'Transforms your printer in place. Snapshots the stock '
                'Klipper install, then swaps in the firmware you pick. Any '
                'vendor services you don\'t want are disabled or removed per '
                'your selections.',
            selected: _choice == WizardFlow.stockKeep,
            onTap: () => setState(() => _choice = WizardFlow.stockKeep),
          ),
          const SizedBox(height: 12),
          _PathCard(
            icon: Icons.refresh,
            title: 'Flash a new OS',
            body: 'Wipes the eMMC and installs a clean Armbian image. '
                'Strongly preferred if you have an eMMC-to-USB adapter handy '
                'and want a fully known-good base.',
            selected: _choice == WizardFlow.freshFlash,
            onTap: () => setState(() => _choice = WizardFlow.freshFlash),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () {
          ref.read(wizardControllerProvider).setFlow(_choice);
          if (_choice == WizardFlow.stockKeep) {
            context.go('/firmware');
          } else {
            context.go('/flash-target');
          }
        },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/verify')),
      ],
    );
  }
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
      elevation: selected ? 4 : 1,
      color: selected ? t.colorScheme.primaryContainer : null,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32, color: t.colorScheme.primary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: t.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(body, style: t.textTheme.bodyMedium),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
