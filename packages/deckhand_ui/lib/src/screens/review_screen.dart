import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/json_safety.dart';
import '../widgets/wizard_scaffold.dart';

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

    // Human labels for internal enum values. These never leak the
    // enum name (e.g. `stockKeep`) to the user, who would not know
    // what it means.
    final flowLabel = switch (state.flow) {
      WizardFlow.stockKeep => t.review.flow_stock_keep,
      WizardFlow.freshFlash => t.review.flow_fresh_flash,
      WizardFlow.none => t.review.flow_unknown,
    };
    final printerLabel = controller.profile?.displayName ?? state.profileId;

    final decisions = _humanDecisions(controller.profile, state.decisions);

    return WizardScaffold(
      screenId: 'S800-review',
      title: t.review.title,
      helperText: t.review.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _HeaderStrip(
            flowLabel: flowLabel,
            printerLabel: printerLabel,
            host: state.sshHost,
          ),
          const SizedBox(height: 12),
          if (decisions.isNotEmpty) ...[
            _ReviewSection(
              title: t.review.your_decisions,
              icon: Icons.tune,
              defaultOpen: true,
              items: [for (final line in decisions) _decisionToItem(line)],
            ),
            const SizedBox(height: 10),
          ],
          if (plan.sections.isEmpty)
            _EmptyPlanCard(message: t.review.plan_empty)
          else ...[
            for (var i = 0; i < plan.sections.length; i++) ...[
              _ReviewSection(
                title: plan.sections[i].title,
                icon: plan.sections[i].icon,
                // Open the first two sections by default — that's what
                // the design source did for firmware + services.
                defaultOpen: i < 2,
                items: [
                  for (final p in plan.sections[i].items)
                    _Item(label: p.label, subtle: p.subtle),
                ],
              ),
              if (i < plan.sections.length - 1) const SizedBox(height: 10),
            ],
          ],
          const SizedBox(height: 16),
          _ConfirmTile(
            checked: _confirmed,
            label: t.review.confirm,
            onChanged: (v) => setState(() => _confirmed = v),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.review.action_start,
        onPressed: _confirmed ? () => context.go('/progress') : null,
        destructive: true,
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/hardening'),
          isBack: true,
        ),
      ],
    );
  }

  /// Split a "Label: value" decision line into the 2-column shape the
  /// review section expects (left bold label, right mono dim value).
  /// Falls back to a single-column item if there's no colon.
  _Item _decisionToItem(String line) {
    final idx = line.indexOf(':');
    if (idx < 0) return _Item(label: line);
    final label = line.substring(0, idx).trim();
    final value = line.substring(idx + 1).trim();
    return _Item(label: label, value: value);
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
      final choices = jsonStringKeyMapList(stack.webui?['choices']);
      for (final c in choices) {
        if (jsonString(c['id']) == name) return c;
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
        final fw = profile.firmware.choices.firstWhere(
          (c) => c.id == fwId,
          orElse: () => profile.firmware.choices.isEmpty
              ? const FirmwareChoice(id: '', displayName: '', repo: '', ref: '')
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
      final step = jsonStringKeyMap(raw);
      if (step == null) continue;
      switch (step['kind']) {
        case 'write_file':
          final target = jsonString(step['target']);
          if (target != null) {
            writes.add(_PlanItem(label: resolve(target) + tag));
          }
        case 'install_marker':
          final dir = jsonString(step['target_dir']) ?? '~/printer_data/config';
          final filename = jsonString(step['filename']) ?? 'deckhand.json';
          writes.add(_PlanItem(label: resolve('$dir/$filename') + tag));
        case 'snapshot_paths':
          final ids = jsonStringList(step['paths']);
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
                jsonString(decisions['file.${f.id}']) ?? f.defaultAction;
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
                    id: '',
                    displayName: '',
                    repo: '',
                    ref: '',
                  )
                : profile.firmware.choices.first,
          );
          clones.add(
            _PlanItem(
              label:
                  'firmware: ${fw.displayName} '
                  '(${fw.repo}@${fw.ref}) -> ${fw.installPath ?? "?"}$tag',
            ),
          );
        case 'install_stack':
          final comps = jsonStringList(step['components']);
          for (final c in comps) {
            final resolved = resolve(c);
            final cfg = _lookupStackCfg(profile, resolved);
            if (cfg == null) {
              clones.add(_PlanItem(label: 'stack: $resolved$tag'));
            } else {
              final path = jsonString(cfg['install_path']) ?? '?';
              final repo = jsonString(cfg['repo']) ?? '?';
              clones.add(
                _PlanItem(label: 'stack: $resolved ($repo) -> $path$tag'),
              );
            }
          }
        case 'link_extras':
          final srcs = jsonStringList(step['sources']);
          for (final s in srcs) {
            clones.add(_PlanItem(label: 'klippy extras <- $s$tag'));
          }
        case 'script':
          final path = jsonString(step['path']);
          if (path != null) scripts.add(_PlanItem(label: path + tag));
        case 'flash_disk':
          final disk = decisions['flash.disk']?.toString() ?? '(unchosen)';
          diskWrites.add(_PlanItem(label: 'raw image write to $disk$tag'));
        case 'conditional':
          final when = jsonString(step['when']);
          final then = jsonStringKeyMapList(step['then']);
          // Label the gate itself so users see there's branching.
          scripts.add(
            _PlanItem(label: '[gate: when $when] then...', subtle: true),
          );
          walk(then, conditional: true);
      }
    }
  }

  walk(flowSpec.steps);

  final sections = <_PlanSection>[];
  if (writes.isNotEmpty) {
    sections.add(
      _PlanSection(
        title: 'Files to write',
        icon: Icons.edit_note,
        items: writes,
      ),
    );
  }
  if (snapshots.isNotEmpty) {
    sections.add(
      _PlanSection(
        title: 'Paths snapshotted (renamed-with-suffix)',
        icon: Icons.history,
        items: snapshots,
      ),
    );
  }
  if (deletes.isNotEmpty) {
    sections.add(
      _PlanSection(
        title: 'Candidate files to delete',
        icon: Icons.delete_outline,
        items: deletes,
      ),
    );
  }
  if (clones.isNotEmpty) {
    sections.add(
      _PlanSection(
        title: 'Components to install',
        icon: Icons.download,
        items: clones,
      ),
    );
  }
  if (scripts.isNotEmpty) {
    sections.add(
      _PlanSection(
        title: 'Scripts to run (via SSH, with askpass sudo)',
        icon: Icons.terminal,
        items: scripts,
      ),
    );
  }
  if (diskWrites.isNotEmpty) {
    sections.add(
      _PlanSection(
        title: 'Raw disk writes (DESTRUCTIVE)',
        icon: Icons.warning_amber,
        items: diskWrites,
      ),
    );
  }
  return _MutationPlan(sections);
}

/// 2-column row used inside [_ReviewSection]. `label` is bold, `value`
/// is mono-dim. `subtle` italicizes + dims the entire row (used for
/// conditional-gate markers in the mutation plan).
class _Item {
  const _Item({required this.label, this.value, this.subtle = false});
  final String label;
  final String? value;
  final bool subtle;
}

/// Collapsible section panel. Mirrors the design source's
/// `<details>` blocks: header row with icon + title + mono "N items"
/// count on the right, expanding into a list of `_Item` rows.
class _ReviewSection extends StatelessWidget {
  const _ReviewSection({
    required this.title,
    required this.icon,
    required this.items,
    required this.defaultOpen,
  });

  final String title;
  final IconData icon;
  final List<_Item> items;
  final bool defaultOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(
          dividerColor: Colors.transparent,
          splashColor: Colors.transparent,
        ),
        child: ExpansionTile(
          initiallyExpanded: defaultOpen,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14),
          childrenPadding: EdgeInsets.zero,
          collapsedShape: const RoundedRectangleBorder(),
          shape: const RoundedRectangleBorder(),
          leading: Icon(icon, size: 16, color: tokens.text3),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w500,
                    color: tokens.text,
                  ),
                ),
              ),
              Text(
                '${items.length} item${items.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: 11,
                  color: tokens.text4,
                ),
              ),
            ],
          ),
          children: [
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: tokens.lineSoft)),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < items.length; i++)
                    _ItemRow(item: items[i], isLast: i == items.length - 1),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.isLast});
  final _Item item;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final color = item.subtle ? tokens.text4 : tokens.text;
    final valueColor = item.subtle ? tokens.text4 : tokens.text3;
    return Container(
      padding: const EdgeInsets.fromLTRB(36, 8, 16, 8),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: tokens.lineSoft)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 220,
            child: Text(
              item.label,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                fontWeight: item.subtle ? FontWeight.w400 : FontWeight.w500,
                fontStyle: item.subtle ? FontStyle.italic : FontStyle.normal,
                color: color,
              ),
            ),
          ),
          if (item.value != null)
            Expanded(
              child: Text(
                item.value!,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tXs,
                  color: valueColor,
                  fontStyle: item.subtle ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Top "what we're about to do" strip — flow + printer + host as
/// labeled mono cells.
class _HeaderStrip extends StatelessWidget {
  const _HeaderStrip({
    required this.flowLabel,
    required this.printerLabel,
    required this.host,
  });
  final String flowLabel;
  final String printerLabel;
  final String? host;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Wrap(
        spacing: 24,
        runSpacing: 12,
        children: [
          _HeaderCell(label: 'flow', value: flowLabel),
          _HeaderCell(label: 'printer', value: printerLabel),
          if (host != null) _HeaderCell(label: 'host', value: host!),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 10,
            color: tokens.text4,
            letterSpacing: 0.1 * 10,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: DeckhandTokens.tMd,
            color: tokens.text,
          ),
        ),
      ],
    );
  }
}

class _ConfirmTile extends StatelessWidget {
  const _ConfirmTile({
    required this.checked,
    required this.label,
    required this.onChanged,
  });
  final bool checked;
  final String label;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return InkWell(
      onTap: () => onChanged(!checked),
      borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        decoration: BoxDecoration(
          color: checked ? tokens.accentSoft : tokens.ink1,
          border: Border.all(
            color: checked ? tokens.accent : tokens.line,
            width: checked ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: checked,
                onChanged: (v) => onChanged(v ?? false),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tMd,
                  color: tokens.text,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPlanCard extends StatelessWidget {
  const _EmptyPlanCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Text(
        message,
        style: TextStyle(
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tSm,
          color: tokens.text3,
        ),
      ),
    );
  }
}
