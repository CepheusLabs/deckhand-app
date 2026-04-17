import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ProgressScreen extends ConsumerStatefulWidget {
  const ProgressScreen({super.key});

  @override
  ConsumerState<ProgressScreen> createState() => _ProgressScreenState();
}

class _ProgressScreenState extends ConsumerState<ProgressScreen> {
  final _log = <String>[];
  bool _done = false;
  bool _failed = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startExecution();
  }

  Future<void> _startExecution() async {
    final controller = ref.read(wizardControllerProvider);
    final sub = controller.events.listen(_onEvent);
    try {
      await controller.startExecution();
      setState(() => _done = true);
    } catch (e) {
      setState(() {
        _failed = true;
        _error = '$e';
      });
    } finally {
      await sub.cancel();
    }
  }

  void _onEvent(WizardEvent e) {
    setState(() {
      switch (e) {
        case StepStarted(:final stepId):
          _log.add('▶ starting $stepId');
        case StepCompleted(:final stepId):
          _log.add('✓ $stepId');
        case StepFailed(:final stepId, :final error):
          _log.add('✗ $stepId — $error');
        case StepLog(:final line):
          _log.add(line);
        case StepWarning(:final stepId, :final message):
          _log.add('! $stepId — $message');
        case _:
          break;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: _failed
          ? 'Something went wrong'
          : (_done ? 'All done' : 'Installing…'),
      helperText: _error,
      body: Container(
        height: 400,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: ListView.builder(
          itemCount: _log.length,
          itemBuilder: (_, i) => Text(_log[i],
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ),
      ),
      primaryAction: WizardAction(
        label: _done ? 'Finish' : (_failed ? 'Close' : 'Running…'),
        onPressed: _done ? () => context.go('/done') : (_failed ? () => context.go('/') : null),
      ),
    );
  }
}
