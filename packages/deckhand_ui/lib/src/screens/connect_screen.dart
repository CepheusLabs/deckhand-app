import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _hostController = TextEditingController();
  String? _error;
  bool _connecting = false;

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref.read(wizardControllerProvider).connectSsh(host: _hostController.text.trim());
      if (mounted) context.go('/verify');
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Connect to your printer',
      helperText:
          'Enter your printer\'s IP address (or hostname). Deckhand will '
          'authenticate using the default SSH credentials declared by this '
          'printer\'s profile.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _hostController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Host or IP',
              hintText: 'e.g. 192.168.1.50 or mkspi.local',
              border: OutlineInputBorder(),
            ),
            enabled: !_connecting,
            onSubmitted: (_) => _connect(),
          ),
          const SizedBox(height: 12),
          if (_connecting) const LinearProgressIndicator(),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
        ],
      ),
      primaryAction: WizardAction(
        label: _connecting ? 'Connecting…' : 'Connect',
        onPressed: _connecting || _hostController.text.trim().isEmpty ? null : _connect,
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/pick-printer')),
      ],
    );
  }
}
