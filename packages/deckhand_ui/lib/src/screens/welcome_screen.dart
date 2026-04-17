import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class WelcomeScreen extends ConsumerWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Welcome to Deckhand',
      helperText:
          'Flash, set up, and maintain Klipper-based printers. This wizard '
          'walks you through replacing vendor firmware with Kalico or Klipper '
          'end-to-end, either in place on your existing OS or on a fresh '
          'install.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HelpCard(
            icon: Icons.menu_book_outlined,
            title: 'First time here?',
            body:
                'The wizard will ask which printer you have, try to reach it '
                'over SSH using known default credentials, then let you pick '
                'what you want to replace and what you want to keep.',
          ),
          const SizedBox(height: 12),
          _HelpCard(
            icon: Icons.shield_outlined,
            title: 'Safety',
            body:
                'Nothing destructive happens without explicit confirmation. '
                'Deckhand can back up your entire eMMC to an image before any '
                'firmware swap, so you always have a route back to stock.',
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Start',
        onPressed: () => context.go('/pick-printer'),
      ),
      secondaryActions: [
        WizardAction(
          label: 'Settings',
          onPressed: () => context.go('/settings'),
        ),
      ],
    );
  }
}

class _HelpCard extends StatelessWidget {
  const _HelpCard({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Card(
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
    );
  }
}
