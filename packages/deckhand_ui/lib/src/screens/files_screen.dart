import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  final _deleteSelected = <String>{};
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    final files = ref.watch(wizardControllerProvider).profile?.stockOs.files ?? const [];
    if (!_seeded) {
      for (final f in files) {
        if (f.defaultAction == 'delete') _deleteSelected.add(f.id);
      }
      _seeded = true;
    }

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Leftover files',
      helperText:
          'Deckhand can delete any of these. Defaults to the recommendation '
          'in this profile; toggle any you want to keep.',
      body: Column(
        children: [
          Row(
            children: [
              TextButton(
                onPressed: () => setState(() {
                  _deleteSelected
                    ..clear()
                    ..addAll(files.map((f) => f.id));
                }),
                child: const Text('Select all'),
              ),
              TextButton(
                onPressed: () => setState(() => _deleteSelected.clear()),
                child: const Text('Deselect all'),
              ),
            ],
          ),
          for (final f in files)
            CheckboxListTile(
              value: _deleteSelected.contains(f.id),
              onChanged: (v) => setState(() {
                if (v == true) {
                  _deleteSelected.add(f.id);
                } else {
                  _deleteSelected.remove(f.id);
                }
              }),
              title: Text(f.displayName),
              subtitle: Text(
                [
                  (f.raw['wizard'] as Map?)?['helper_text'] as String? ?? '',
                  'paths: ${f.paths.join(", ")}',
                ].where((s) => s.isNotEmpty).join('\n'),
              ),
            ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () async {
          for (final f in files) {
            await ref.read(wizardControllerProvider).setDecision(
                  'file.${f.id}',
                  _deleteSelected.contains(f.id) ? 'delete' : 'keep',
                );
          }
          if (context.mounted) context.go('/hardening');
        },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/services')),
      ],
    );
  }
}
