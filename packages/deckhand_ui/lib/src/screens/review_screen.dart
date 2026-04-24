import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
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
    final plan = _buildMutationPlan(
      profile: profile,
      flow: state.flow,
      decisions: state.decisions,
    );
    final theme = Theme.of(context);

    // Human labels for internal enum values. These never leak the
    // enum name (e.g. `stockKeep`) to the user, who would not know
    // what it means.
    final flowLabel = switch (state.flow) {
      WizardFlow.stockKeep => t.review.flow_stock_keep,
      WizardFlow.freshFlash => t.review.flow_fresh_flash,
      WizardFlow.none => t.review.flow_unknown,
    };
    final printerLabel =
        controller.profile?.displayName ?? state.profileId;

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: t.review.title,
      helperText: t.review.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t.review.flow_line(flow: flowLabel)),
                  Text(t.review.printer_line(printer: printerLabel)),
                  if (state.sshHost != null)
                    Text(t.review.host_line(host: state.sshHost!)),
                  const SizedBox(height: 8),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(
                    t.review.your_decisions,
                    style: theme.textTheme.titleSmall,
                  ),
                  for (final e in _humanDecisions(
                    controller.profile,
                    state.decisions,
                  ))
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(e),
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
                      Text(
                        t.review.plan_heading,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.onTertiaryContainer,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    t.review.plan_explainer(flow: flowLabel),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onTertiaryContainer,
                    ),
                  ),
                  const SizedBox(height: 10),
                  for (final s in plan.sections)
                    _PlanSectionWidget(section: s),
                  if (plan.sections.isEmpty)
                    Text(
                      t.review.plan_empty,
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
            title: Text(t.review.confirm),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.review.action_start,
        onPressed: _confirmed ? () => context.go('/progress') : null,
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/hardening'),
        ),
      ],
    );
  }

  /// Convert raw `decisions` map entries into human-readable lines.
  /// Internal decision keys like `service.makerbase_udp` get mapped
  /// against the profile's display_name fields where possible, so
  /// the user sees "Makerbase UDP service: disable" instead of
  /// "service.makerbase_udp: disable".
  List<String> _humanDecisions(
    PrinterProfile? profile,
    Map<String, Object> decisions,
  ) {
    final out = <String>[];
    for (final e in decisions.entries) {
      final key = e.key;
      final val = e.value;
      String? label;
      if (key.startsWith('service.') && profile != null) {
        final id = key.substring('service.'.length);
        final matches = profile.stockOs.services.where((s) => s.id == id);
        label = matches.isNotEmpty ? matches.first.displayName : id;
      } else if (key.startsWith('file.') && profile != null) {
        final id = key.substring('file.'.length);
        final matches = profile.stockOs.files.where((f) => f.id == id);
        label = matches.isNotEmpty ? matches.first.displayName : id;
      } else if (key.startsWith('hardening.')) {
        label = key.substring('hardening.'.length).replaceAll('_', ' ');
      } else if (key == 'webui') {
        label = 'Web interface';
      } else if (key == 'firmware') {
        label = 'Firmware';
      } else if (key == 'kiauh') {
        label = 'KIAUH helper';
      } else if (key == 'screen') {
        label = 'Touchscreen daemon';
      }
      // Never surface `hardening.new_password` content to the UI.
      if (key == 'hardening.new_password') {
        continue;
      }
      label ??= key; // last-resort fallback - still better than raw id+colon
      out.add('$label: $val');
    }
    return out;
  }
}

/// One row inside a plan section. [subtle] dims the row - used for
/// conditional-gate headers so they visually separate from the
/// concrete paths that follow.
class _PlanItem {
  const _PlanItem({required this.label, this.subtle = false});
  final String label;
  final bool subtle;
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
  final List<_PlanItem> items;
}

class _MutationPlan {
  const _MutationPlan(this.sections);
  final List<_PlanSection> sections;
}

Map<String, dynamic>? _lookupStackCfg(PrinterProfile profile, String name) {
  final stack = profile.stack;
  switch (name) {
    case 'moonraker':
      return stack.moonraker;
    case 'kiauh':
      return stack.kiauh;
    case 'crowsnest':
      return stack.crowsnest;
    default:
      final choices =
          ((stack.webui?['choices'] as List?) ?? const []).cast<Map>();
      for (final c in choices) {
        if ((c['id'] as String?) == name) return c.cast<String, dynamic>();
      }
      return null;
  }
}

_MutationPlan _buildMutationPlan({
  required PrinterProfile? profile,
  required WizardFlow flow,
  required Map<String, Object> decisions,
}) {
  if (profile == null) return const _MutationPlan([]);
  final flowSpec = flow == WizardFlow.freshFlash
      ? profile.flows.freshFlash
      : profile.flows.stockKeep;
  if (flowSpec == null) return const _MutationPlan([]);

  final writes = <_PlanItem>[];
  final snapshots = <_PlanItem>[];
  final deletes = <_PlanItem>[];
  final clones = <_PlanItem>[];
  final scripts = <_PlanItem>[];
  final diskWrites = <_PlanItem>[];

  /// Resolve `{{path.like.this}}` references in a profile string
  /// against the same decisions + profile the wizard controller would
  /// use at runtime. Best-effort: missing keys render the brace
  /// expression unchanged so the user sees what's unresolved.
  String resolve(String template) {
    return template.replaceAllMapped(RegExp(r'\{\{([^}]+)\}\}'), (m) {
      final key = m.group(1)!.trim();
      if (key.startsWith('decisions.')) {
        final v = decisions[key.substring('decisions.'.length)];
        return v?.toString() ?? '{{$key}}';
      }
      if (key.startsWith('profile.')) {
        final path = key.substring('profile.'.length).split('.');
        Object? cur = profile.raw;
        for (final p in path) {
          if (cur is Map) {
            cur = cur[p];
          } else {
            cur = null;
            break;
          }
        }
        return cur?.toString() ?? '{{$key}}';
      }
      if (key == 'firmware.install_path') {
        final fwId = decisions['firmware']?.toString();
        final fw = profile.firmware.choices
            .firstWhere(
              (c) => c.id == fwId,
              orElse: () => profile.firmware.choices.isEmpty
                  ? const FirmwareChoice(
                      id: '', displayName: '', repo: '', ref: '')
                  : profile.firmware.choices.first,
            );
        return fw.installPath ?? '{{$key}}';
      }
      if (key == 'stack.webui.selected') {
        final list = decisions['webui'];
        if (list is List) return list.join(', ');
        return list?.toString() ?? '{{$key}}';
      }
      return '{{$key}}';
    });
  }

  /// Whether this step is inside a conditional wrapper - gets a
  /// "(maybe)" tag in the preview so users know the step only fires
  /// when the condition evaluates true.
  void walk(List<dynamic> steps, {bool conditional = false}) {
    final tag = conditional ? ' (maybe, conditional)' : '';
    for (final raw in steps) {
      if (raw is! Map) continue;
      final step = raw.cast<String, dynamic>();
      switch (step['kind']) {
        case 'write_file':
          final target = step['target'] as String?;
          if (target != null) {
            writes.add(_PlanItem(label: resolve(target) + tag));
          }
        case 'install_marker':
          final dir =
              step['target_dir'] as String? ?? '~/printer_data/config';
          final filename = step['filename'] as String? ?? 'deckhand.json';
          writes.add(_PlanItem(label: resolve('$dir/$filename') + tag));
        case 'snapshot_paths':
          final ids =
              ((step['paths'] as List?) ?? const []).cast<String>();
          for (final id in ids) {
            final p = profile.stockOs.paths.firstWhere(
              (x) => x.id == id,
              orElse: () => StockPath(id: id, path: id, action: ''),
            );
            snapshots.add(_PlanItem(label: p.path + tag));
          }
        case 'apply_files':
          // Only list files the user CHOSE to delete (decisions say
          // `delete`, or the profile default is `delete` and the
          // user hasn't overridden). Everything else stays.
          for (final f in profile.stockOs.files) {
            final decided =
                decisions['file.${f.id}'] as String? ?? f.defaultAction;
            if (decided != 'delete') continue;
            for (final p in f.paths) {
              deletes.add(_PlanItem(label: '${f.id}: $p$tag'));
            }
          }
        case 'install_firmware':
          final fwId = decisions['firmware']?.toString() ?? '(unchosen)';
          final fw = profile.firmware.choices.firstWhere(
            (c) => c.id == fwId,
            orElse: () => profile.firmware.choices.isEmpty
                ? const FirmwareChoice(
                    id: '', displayName: '', repo: '', ref: '')
                : profile.firmware.choices.first,
          );
          clones.add(_PlanItem(
            label: 'firmware: ${fw.displayName} '
                '(${fw.repo}@${fw.ref}) -> ${fw.installPath ?? "?"}$tag',
          ));
        case 'install_stack':
          final comps =
              ((step['components'] as List?) ?? const []).cast<String>();
          for (final c in comps) {
            final resolved = resolve(c);
            final cfg = _lookupStackCfg(profile, resolved);
            if (cfg == null) {
              clones.add(_PlanItem(label: 'stack: $resolved$tag'));
            } else {
              final path = cfg['install_path'] as String? ?? '?';
              final repo = cfg['repo'] as String? ?? '?';
              clones.add(_PlanItem(
                label: 'stack: $resolved ($repo) -> $path$tag',
              ));
            }
          }
        case 'link_extras':
          final srcs =
              ((step['sources'] as List?) ?? const []).cast<String>();
          for (final s in srcs) {
            clones.add(_PlanItem(label: 'klippy extras <- $s$tag'));
          }
        case 'script':
          final path = step['path'] as String?;
          if (path != null) scripts.add(_PlanItem(label: path + tag));
        case 'flash_disk':
          final disk = decisions['flash.disk']?.toString() ?? '(unchosen)';
          diskWrites.add(_PlanItem(label: 'raw image write to $disk$tag'));
        case 'conditional':
          final when = step['when'] as String?;
          final then = (step['then'] as List?) ?? const [];
          // Label the gate itself so users see there's branching.
          scripts.add(
            _PlanItem(
              label: '[gate: when $when] then...',
              subtle: true,
            ),
          );
          walk(then, conditional: true);
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
              Expanded(
                child: Text(
                  '${section.title} (${section.items.length})',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          for (final item in section.items)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 2),
              child: Text(
                item.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: item.subtle
                      ? theme.colorScheme.onTertiaryContainer
                          .withValues(alpha: 0.65)
                      : theme.colorScheme.onTertiaryContainer,
                  fontStyle:
                      item.subtle ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

