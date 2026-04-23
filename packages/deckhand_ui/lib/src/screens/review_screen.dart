import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

/// Pre-run preview + final confirm. Lists every decision the user
/// made AND every file path the flow is about to touch (from the
/// profile's step declarations), so users can catch "oh that file
/// shouldn't be rewritten" before anything mutates.
class ReviewScreen extends ConsumerStatefulWidget {
  const ReviewScreen({super.key});

  @override
  ConsumerState<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends ConsumerState<ReviewScreen> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final state = controller.state;
    final profile = controller.profile;
    final plan = _buildMutationPlan(profile, state.flow);
    final theme = Theme.of(context);

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Review your choices',
      helperText:
          'Every decision you made is listed below, plus every file Deckhand '
          'is about to touch on the printer. Deckhand auto-snapshots each '
          'target before overwriting (you can restore from the Verify '
          'screen), but it is cheaper to catch a mistake now.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Flow: ${state.flow.name}'),
                  Text('Printer: ${state.profileId}'),
                  if (state.sshHost != null)
                    Text('SSH host: ${state.sshHost}'),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(
                    'Your decisions',
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final e in state.decisions.entries)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('${e.key}: ${e.value}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Card(
            color: theme.colorScheme.tertiaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.preview,
                          color: theme.colorScheme.onTertiaryContainer),
                      const SizedBox(width: 8),
                      Text('What this will touch',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer,
                          )),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Generated from the profile\'s step list for the '
                    '"${state.flow.name}" flow. Anything written here is '
                    'backed up before it is overwritten.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final s in plan.sections)
                    _PlanSectionWidget(section: s),
                  if (plan.sections.isEmpty)
                    Text(
                      '(no file-mutating steps in this flow)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          CheckboxListTile(
            value: _confirmed,
            onChanged: (v) => setState(() => _confirmed = v ?? false),
            title: const Text('I understand and want to proceed.'),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Start install',
        onPressed: _confirmed ? () => context.go('/progress') : null,
      ),
      secondaryActions: [
        WizardAction(
            label: 'Back', onPressed: () => context.go('/hardening')),
      ],
    );
  }
}

/// A grouped set of paths the flow will touch, by category.
class _PlanSection {
  const _PlanSection({
    required this.title,
    required this.icon,
    required this.items,
  });
  final String title;
  final IconData icon;
  final List<String> items;
}

class _MutationPlan {
  const _MutationPlan(this.sections);
  final List<_PlanSection> sections;
}

_MutationPlan _buildMutationPlan(PrinterProfile? profile, WizardFlow flow) {
  if (profile == null) return const _MutationPlan([]);
  final flowSpec = flow == WizardFlow.freshFlash
      ? profile.flows.freshFlash
      : profile.flows.stockKeep;
  if (flowSpec == null) return const _MutationPlan([]);

  final writes = <String>[];
  final snapshots = <String>[];
  final deletes = <String>[];
  final clones = <String>[];
  final scripts = <String>[];
  final diskWrites = <String>[];

  void walk(List<dynamic> steps) {
    for (final raw in steps) {
      if (raw is! Map) continue;
      final step = raw.cast<String, dynamic>();
      switch (step['kind']) {
        case 'write_file':
          final target = step['target'] as String?;
          if (target != null) writes.add(target);
        case 'install_marker':
          final dir = step['target_dir'] as String?
              ?? '~/printer_data/config';
          final filename = step['filename'] as String? ?? 'deckhand.json';
          writes.add('$dir/$filename');
        case 'snapshot_paths':
          final ids = ((step['paths'] as List?) ?? const []).cast<String>();
          for (final id in ids) {
            final p = profile.stockOs.paths.firstWhere(
              (x) => x.id == id,
              orElse: () => StockPath(id: id, path: id, action: ''),
            );
            snapshots.add(p.path);
          }
        case 'apply_files':
          for (final f in profile.stockOs.files) {
            for (final p in f.paths) deletes.add(p);
          }
        case 'install_firmware':
          final fwId = step['id'] as String? ?? 'firmware';
          clones.add('firmware: $fwId');
        case 'install_stack':
          final comps =
              ((step['components'] as List?) ?? const []).cast<String>();
          for (final c in comps) clones.add('stack: $c');
        case 'link_extras':
          final srcs =
              ((step['sources'] as List?) ?? const []).cast<String>();
          for (final s in srcs) clones.add('klippy extras <- $s');
        case 'script':
          final path = step['path'] as String?;
          if (path != null) scripts.add(path);
        case 'flash_disk':
          diskWrites.add('raw image write to user-chosen disk');
        case 'conditional':
          final then = (step['then'] as List?) ?? const [];
          walk(then);
      }
    }
  }

  walk(flowSpec.steps);

  final sections = <_PlanSection>[];
  if (writes.isNotEmpty) {
    sections.add(_PlanSection(
        title: 'Files to write', icon: Icons.edit_note, items: writes));
  }
  if (snapshots.isNotEmpty) {
    sections.add(_PlanSection(
        title: 'Paths snapshotted (renamed-with-suffix)',
        icon: Icons.history,
        items: snapshots));
  }
  if (deletes.isNotEmpty) {
    sections.add(_PlanSection(
        title: 'Candidate files to delete',
        icon: Icons.delete_outline,
        items: deletes));
  }
  if (clones.isNotEmpty) {
    sections.add(_PlanSection(
        title: 'Components to install',
        icon: Icons.download,
        items: clones));
  }
  if (scripts.isNotEmpty) {
    sections.add(_PlanSection(
        title: 'Scripts to run (via SSH, with askpass sudo)',
        icon: Icons.terminal,
        items: scripts));
  }
  if (diskWrites.isNotEmpty) {
    sections.add(_PlanSection(
        title: 'Raw disk writes (DESTRUCTIVE)',
        icon: Icons.warning_amber,
        items: diskWrites));
  }
  return _MutationPlan(sections);
}

class _PlanSectionWidget extends StatelessWidget {
  const _PlanSectionWidget({required this.section});
  final _PlanSection section;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(section.icon,
                  size: 16, color: theme.colorScheme.onTertiaryContainer),
              const SizedBox(width: 6),
              Text(
                '${section.title} (${section.items.length})',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ],
          ),
          for (final i in section.items)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2),
              child: Text(
                i,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

