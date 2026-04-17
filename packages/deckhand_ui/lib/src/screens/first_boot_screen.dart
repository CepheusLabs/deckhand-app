import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FirstBootScreen extends ConsumerStatefulWidget {
  const FirstBootScreen({super.key});

  @override
  ConsumerState<FirstBootScreen> createState() => _FirstBootScreenState();
}

class _FirstBootScreenState extends ConsumerState<FirstBootScreen> {
  bool _waiting = false;
  bool _ready = false;
  String _status = 'waiting…';

  Future<void> _startPolling() async {
    final host = ref.read(wizardControllerProvider).state.sshHost;
    if (host == null) return;
    setState(() {
      _waiting = true;
      _status = 'Polling $host:22 for SSH-ready state…';
    });
    final ok = await ref.read(discoveryServiceProvider).waitForSsh(host: host);
    setState(() {
      _waiting = false;
      _ready = ok;
      _status = ok ? 'SSH is up!' : 'Timed out waiting for SSH.';
    });
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Put the eMMC back in the printer',
      helperText:
          '1. Unplug the USB adapter.\n'
          '2. Put the eMMC module back in the printer.\n'
          '3. Power on.\n'
          '4. Click "Start polling" below; Deckhand will wait for SSH to '
          'come up on the printer\'s IP.',
      body: Column(
        children: [
          Text(_status),
          const SizedBox(height: 16),
          if (_waiting) const LinearProgressIndicator(),
        ],
      ),
      primaryAction: WizardAction(
        label: _ready ? 'Continue' : (_waiting ? 'Waiting…' : 'Start polling'),
        onPressed: _ready
            ? () => context.go('/first-boot-setup')
            : (_waiting ? null : _startPolling),
      ),
    );
  }
}
