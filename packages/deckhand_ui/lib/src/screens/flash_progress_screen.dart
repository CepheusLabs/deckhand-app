import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FlashProgressScreen extends ConsumerStatefulWidget {
  const FlashProgressScreen({super.key});

  @override
  ConsumerState<FlashProgressScreen> createState() => _FlashProgressScreenState();
}

class _FlashProgressScreenState extends ConsumerState<FlashProgressScreen> {
  double _fraction = 0;
  final _log = <String>['Preparing to write…'];
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // TODO: wire real flash pipeline via FlashService.writeImage. For now
    // this screen exists with the right layout; the execution machinery
    // lives in the WizardController step runner.
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: _done ? 'Flash complete' : 'Writing image',
      helperText:
          'Do not unplug the eMMC or close Deckhand until this finishes. '
          'Verification runs automatically afterwards.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: _done ? 1 : _fraction),
          const SizedBox(height: 16),
          Container(
            height: 280,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (_, i) => Text(
                _log[i],
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: _done ? 'Continue' : 'Running…',
        onPressed: _done ? () => context.go('/first-boot') : null,
      ),
    );
  }
}
