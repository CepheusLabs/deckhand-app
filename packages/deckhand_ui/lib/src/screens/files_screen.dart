import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

/// Stock-OS leftover files the profile declares can be cleaned up.
/// The probe tells us which ones actually exist on *this* printer; we
/// partition the list into "still present" (actionable) and "already
/// gone" (dimmed under a separate header). Keeps the user from picking
/// actions for things that aren't there and removes the visual noise
/// of a twenty-item checklist when twelve items are already clean.
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
    // Subscribe to probe updates so the list rebuilds once the state
    // probe lands fresh data.
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final files = controller.profile?.stockOs.files ?? const [];
    if (!_seeded) {
      for (final f in files) {
        if (f.defaultAction == 'delete') _deleteSelected.add(f.id);
      }
      _seeded = true;
    }
    final probe = controller.printerState;
    final probeReady = probe.probedAt != null;

    final present = <StockFile>[];
    final absent = <StockFile>[];
    for (final f in files) {
      final exists = probe.files[f.id];
      if (probeReady && exists == false) {
        absent.add(f);
      } else {
        present.add(f);
      }
    }

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Leftover files',
      helperText:
          'Deckhand can delete any of these. We probed your printer and '
          'split the list into files we actually found ("still present") '
          'and files the profile mentions but that aren\'t here anymore '
          '("already clean"). Defaults follow the profile\'s recommendation; '
          'toggle what you care about.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!probeReady)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: _ProbeLoadingBanner(
                message: 'Probing this printer to see which files are '
                    'actually present...',
              ),
            ),
          Row(
            children: [
              TextButton(
                onPressed: present.isEmpty
                    ? null
                    : () => setState(() {
                          _deleteSelected
                            ..clear()
                            ..addAll(present.map((f) => f.id));
                        }),
                child: const Text('Select all present'),
              ),
              TextButton(
                onPressed: _deleteSelected.isEmpty
                    ? null
                    : () => setState(() => _deleteSelected.clear()),
                child: const Text('Deselect all'),
              ),
            ],
          ),
          for (final f in present)
            _FileRow(
              file: f,
              selected: _deleteSelected.contains(f.id),
              dimmed: false,
              onToggle: (v) => setState(() {
                if (v) {
                  _deleteSelected.add(f.id);
                } else {
                  _deleteSelected.remove(f.id);
                }
              }),
            ),
          if (absent.isNotEmpty) ...[
            const SizedBox(height: 16),
            _SectionHeader(
              label: 'Already clean (${absent.length})',
              subtitle:
                  'These paths aren\'t on your printer. No action needed; '
                  'the wizard will skip them.',
            ),
            for (final f in absent)
              _FileRow(
                file: f,
                selected: false,
                dimmed: true,
                onToggle: (_) {},
              ),
          ],
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

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.selected,
    required this.dimmed,
    required this.onToggle,
  });
  final StockFile file;
  final bool selected;
  final bool dimmed;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final helper =
        (file.raw['wizard'] as Map?)?['helper_text'] as String? ?? '';
    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: CheckboxListTile(
        value: selected,
        onChanged: dimmed ? null : (v) => onToggle(v ?? false),
        title: Text(file.displayName),
        subtitle: Text(
          [
            helper,
            'paths: ${file.paths.join(", ")}',
          ].where((s) => s.isNotEmpty).join('\n'),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.subtitle});
  final String label;
  final String subtitle;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _ProbeLoadingBanner extends StatelessWidget {
  const _ProbeLoadingBanner({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(message, style: theme.textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}
