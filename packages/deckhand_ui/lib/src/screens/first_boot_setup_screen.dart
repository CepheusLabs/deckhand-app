import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FirstBootSetupScreen extends ConsumerStatefulWidget {
  const FirstBootSetupScreen({super.key});

  @override
  ConsumerState<FirstBootSetupScreen> createState() => _FirstBootSetupScreenState();
}

class _FirstBootSetupScreenState extends ConsumerState<FirstBootSetupScreen> {
  final _user = TextEditingController(text: 'mks');
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _hostname = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'First boot setup',
      helperText:
          'Create the user Deckhand and Moonraker will run as. Defaults '
          'match the stock convention so mixing stock + new-OS printers '
          'stays simple.',
      body: Column(
        children: [
          TextField(controller: _user, decoration: const InputDecoration(labelText: 'User')),
          const SizedBox(height: 8),
          TextField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password')),
          const SizedBox(height: 8),
          TextField(controller: _confirm, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password')),
          const SizedBox(height: 8),
          TextField(controller: _hostname, decoration: const InputDecoration(labelText: 'Hostname (optional)')),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () async {
          final controller = ref.read(wizardControllerProvider);
          await controller.setDecision('first_boot.user', _user.text);
          await controller.setDecision('first_boot.password', _password.text);
          await controller.setDecision('first_boot.hostname', _hostname.text);
          if (context.mounted) context.go('/firmware');
        },
      ),
    );
  }

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    _confirm.dispose();
    _hostname.dispose();
    super.dispose();
  }
}
