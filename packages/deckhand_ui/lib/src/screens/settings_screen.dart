import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Settings',
      helperText:
          'Most settings live here. Anything not visible yet is on the '
          'roadmap.',
      body: const Column(
        children: [
          ListTile(title: Text('General'), subtitle: Text('Default flash verification, cache retention')),
          ListTile(title: Text('Connections'), subtitle: Text('Saved printer endpoints + fingerprints')),
          ListTile(title: Text('Profiles'), subtitle: Text('Cached profile versions; edge-channel toggle')),
          ListTile(title: Text('Network allow-list'), subtitle: Text('Approved upstreams')),
          ListTile(title: Text('Appearance'), subtitle: Text('Theme, density')),
        ],
      ),
      primaryAction: WizardAction(label: 'Back', onPressed: () => (context as Element).tryGoHome()),
    );
  }
}

extension on Element {
  void tryGoHome() {
    try {
      GoRouter.of(this).go('/');
    } catch (_) {
      // ignore
    }
  }
}
