import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ScreenChoiceScreen extends ConsumerStatefulWidget {
  const ScreenChoiceScreen({super.key});

  @override
  ConsumerState<ScreenChoiceScreen> createState() => _ScreenChoiceScreenState();
}

class _ScreenChoiceScreenState extends ConsumerState<ScreenChoiceScreen> {
  String? _choice;

  @override
  Widget build(BuildContext context) {
    final screens = ref.watch(wizardControllerProvider).profile?.screens ?? const [];
    _choice ??= screens.firstWhere((s) => s.recommended, orElse: () => screens.first).id;

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Pick a screen daemon',
      helperText:
          'The screen daemon drives your printer\'s touchscreen. Some options '
          'may require restoring closed-source binaries from a backup — those '
          'cards will say so.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final s in screens)
            Card(
              elevation: _choice == s.id ? 4 : 1,
              color: _choice == s.id
                  ? Theme.of(context).colorScheme.primaryContainer
                  : null,
              child: RadioListTile<String>(
                value: s.id,
                groupValue: _choice,
                onChanged: (v) => setState(() => _choice = v),
                title: Text(s.displayName ?? s.id),
                subtitle: Text(_subtitle(s)),
              ),
            ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: _choice == null
            ? null
            : () async {
                await ref.read(wizardControllerProvider).setDecision('screen', _choice!);
                if (context.mounted) context.go('/services');
              },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/kiauh')),
      ],
    );
  }

  String _subtitle(dynamic s) {
    final parts = <String>[];
    if (s.status != null) parts.add('status: ${s.status}');
    final kind = s.raw['source_kind'] as String?;
    if (kind != null) parts.add('source: $kind');
    return parts.join(' · ');
  }
}
