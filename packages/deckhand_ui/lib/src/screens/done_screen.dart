import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class DoneScreen extends ConsumerWidget {
  const DoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(wizardControllerProvider).state;
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Setup complete',
      helperText:
          'Your printer is running community firmware with the configuration '
          'you picked. Deckhand\'s job ends here — day-to-day updates happen '
          'via Moonraker\'s own update_manager or KIAUH.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            leading: const Icon(Icons.check_circle_outline, color: Colors.green, size: 32),
            title: Text(state.profileId),
            subtitle: state.sshHost != null
                ? Text('Connected to ${state.sshHost}')
                : null,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Next steps', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  _TipRow(icon: Icons.public, text: 'Open the web UI at http://${state.sshHost ?? "<printer>"}:8808 (Fluidd) or :81 (Mainsail)'),
                  _TipRow(icon: Icons.update, text: 'Updates to Klipper/Moonraker/Fluidd/Mainsail run from the web UI\'s Update Manager'),
                  _TipRow(icon: Icons.terminal, text: 'For stack tweaks later: ssh in and run ./kiauh/kiauh.sh'),
                ],
              ),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Set up another printer',
        onPressed: () => context.go('/'),
      ),
    );
  }
}

class _TipRow extends StatelessWidget {
  const _TipRow({required this.icon, required this.text});
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
      );
}
