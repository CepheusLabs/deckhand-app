import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

/// One-question-per-screen walker through every stock_os.services entry
/// that declares a `wizard:` block. Uses an internal index to advance
/// through them before handing control off to the files screen.
class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  int _index = 0;
  String? _action;

  List<StockService> get _serviceQueue {
    final all = ref.read(wizardControllerProvider).profile?.stockOs.services ?? const [];
    return all.where((s) {
      final w = s.raw['wizard'];
      return w != null && w != 'none';
    }).toList();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _seedDefault());
  }

  void _seedDefault() {
    final queue = _serviceQueue;
    if (queue.isEmpty) {
      context.go('/files');
      return;
    }
    final svc = queue[_index];
    setState(() {
      _action = ref.read(wizardControllerProvider).resolveServiceDefault(svc);
    });
  }

  @override
  Widget build(BuildContext context) {
    final queue = _serviceQueue;
    if (queue.isEmpty) {
      return const SizedBox.shrink();
    }
    final svc = queue[_index];
    final wiz = (svc.raw['wizard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final options = ((wiz['options'] as List?) ?? const []).cast<Map>();

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: svc.displayName,
      helperText: wiz['helper_text'] as String?,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${_index + 1} of ${queue.length}',
              style: Theme.of(context).textTheme.labelMedium),
          const SizedBox(height: 12),
          if (wiz['question'] != null)
            Text(wiz['question'] as String,
                style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          for (final opt in options)
            RadioListTile<String>(
              value: opt['id'] as String,
              groupValue: _action,
              onChanged: (v) => setState(() => _action = v),
              title: Text(opt['label'] as String? ?? opt['id'] as String),
            ),
        ],
      ),
      primaryAction: WizardAction(
        label: _index + 1 < queue.length ? 'Next service' : 'Continue',
        onPressed: _action == null
            ? null
            : () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('service.${svc.id}', _action!);
                if (_index + 1 < queue.length) {
                  setState(() {
                    _index++;
                    _action = null;
                  });
                  _seedDefault();
                } else {
                  if (context.mounted) context.go('/files');
                }
              },
      ),
      secondaryActions: [
        WizardAction(
          label: _index == 0 ? 'Back' : 'Previous',
          onPressed: () {
            if (_index == 0) {
              context.go('/screen-choice');
            } else {
              setState(() {
                _index--;
                _action = null;
              });
              _seedDefault();
            }
          },
        ),
      ],
    );
  }
}
