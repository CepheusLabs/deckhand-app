import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../utils/json_safety.dart';
import '../widgets/profile_text.dart';

/// One-question-at-a-time service prompts. The design source treats
/// each stock-OS service as its own wizard question — `Question 2 of
/// 4 from the Phrozen vendor stack` — with a 2-column body: radio
/// options on the left, a "WHAT THIS SERVICE DOES" explainer panel on
/// the right, and a progress bar at the bottom of the body.
///
/// The screen advances through services one at a time. Continue
/// records the active question's decision and moves to the next; on
/// the last question Continue navigates onward to /files. Back walks
/// in reverse, falling out to /screen-choice from the first question.
class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  int _index = 0;
  bool _seeded = false;

  @override
  void initState() {
    super.initState();
    // Seed defaults once on the first frame after mount. initState
    // runs exactly once per widget lifetime, which is the right
    // place — earlier versions ran inside build via a postFrame
    // callback and accumulated registrations on every rebuild.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _seedDefaults();
    });
  }

  /// Stock-OS services that actually have a `wizard:` block. Services
  /// declared with `wizard: 'none'` aren't user-facing — they get
  /// filtered out so the queue is exactly the questions to ask.
  List<StockService> _queue() {
    final all =
        ref.read(wizardControllerProvider).profile?.stockOs.services ??
        const [];
    return all
        .where((s) => s.raw['wizard'] != null && s.raw['wizard'] != 'none')
        .toList();
  }

  void _seedDefaults() {
    if (_seeded) return;
    _seeded = true;
    final controller = ref.read(wizardControllerProvider);
    for (final svc in _queue()) {
      final key = 'service.${svc.id}';
      if (controller.decision<String>(key) == null) {
        controller.setDecision(key, controller.resolveServiceDefault(svc));
      }
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final queue = _queue();
    final probe = controller.printerState;

    if (queue.isEmpty) {
      return ClWizardPageScaffold(
        title: 'Stock services',
        helperText:
            'This profile has nothing to ask about. Continue to keep '
            'moving through the wizard.',
        body: const SizedBox.shrink(),
        primaryAction: ClWizardAction(
          label: t.common.action_continue,
          onPressed: () => context.go('/files'),
        ),
        secondaryActions: [
          ClWizardAction(
            label: t.common.action_back,
            onPressed: () => context.go('/screen-choice'),
            isBack: true,
          ),
        ],
      );
    }

    final clampedIdx = _index.clamp(0, queue.length - 1);
    final current = queue[clampedIdx];
    final wiz = jsonStringKeyMap(current.raw['wizard']) ?? const {};
    final options = _serviceOptions(wiz);
    final question = jsonString(wiz['question']);
    final helper = jsonString(wiz['helper_text']);
    final state = probe.services[current.id];
    final decisionKey = 'service.${current.id}';
    final selected = controller.decision<String>(decisionKey);

    return ClWizardPageScaffold(
      title: question == null
          ? 'What should we do with ${current.displayName}?'
          : flattenProfileText(question),
      helperText: helper == null ? null : flattenProfileText(helper),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final twoCol = constraints.maxWidth >= 880;
              final left = _OptionsPanel(
                options: options,
                selected: selected,
                onChoose: (id) {
                  controller.setDecision(decisionKey, id);
                  setState(() {});
                },
              );
              final right = _ExplainerPanel(service: current, state: state);
              if (twoCol) {
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: left),
                      const SizedBox(width: 12),
                      Expanded(child: right),
                    ],
                  ),
                );
              }
              return Column(
                children: [left, const SizedBox(height: 12), right],
              );
            },
          ),
          const SizedBox(height: 16),
          _QuestionProgress(current: clampedIdx + 1, total: queue.length),
        ],
      ),
      primaryAction: ClWizardAction(
        label: t.common.action_continue,
        disabledReason: selected == null
            ? 'Choose what to do with this service first.'
            : null,
        onPressed: selected == null
            ? null
            : () {
                if (clampedIdx + 1 < queue.length) {
                  setState(() => _index = clampedIdx + 1);
                } else {
                  context.go('/files');
                }
              },
      ),
      secondaryActions: [
        ClWizardAction(
          label: t.common.action_back,
          onPressed: () {
            if (clampedIdx > 0) {
              setState(() => _index = clampedIdx - 1);
            } else {
              context.go('/screen-choice');
            }
          },
          isBack: true,
        ),
      ],
    );
  }
}

List<Map<String, dynamic>> _serviceOptions(Map<String, dynamic> wizard) =>
    jsonStringKeyMapList(
      wizard['options'],
    ).where((option) => jsonString(option['id'])?.isNotEmpty == true).toList();

/// Left panel: radio rows for the current question's options.
class _OptionsPanel extends StatelessWidget {
  const _OptionsPanel({
    required this.options,
    required this.selected,
    required this.onChoose,
  });

  final List<Map<String, dynamic>> options;
  final String? selected;
  final void Function(String id) onChoose;

  @override
  Widget build(BuildContext context) {
    return ClPanel(
      padding: const EdgeInsets.all(8),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final raw in options)
            _OptionRow(
              id: jsonString(raw['id'])!,
              label: jsonString(raw['label']) ?? jsonString(raw['id'])!,
              description: jsonString(raw['description']),
              isRecommended: raw['recommended'] == true,
              groupValue: selected,
              onTap: () => onChoose(jsonString(raw['id'])!),
            ),
        ],
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    required this.id,
    required this.label,
    required this.description,
    required this.isRecommended,
    required this.groupValue,
    required this.onTap,
  });

  final String id;
  final String label;
  final String? description;
  final bool isRecommended;
  final String? groupValue;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    final selected = groupValue == id;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.radii.sm),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: selected ? brand.selectedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(context.radii.sm),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: ClRadio<String>(
                value: id,
                groupValue: groupValue,
                onChanged: (_) => onTap(),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        label,
                        style: context.clBodyMedium.copyWith(
                          fontWeight: FontWeight.w500,
                          color: brand.ink,
                        ),
                      ),
                      if (isRecommended) ...[
                        const SizedBox(width: 8),
                        const ClStatusChip(
                          label: 'recommended',
                          kind: ClChipKind.good,
                          compact: true,
                        ),
                      ],
                    ],
                  ),
                  if (description != null &&
                      description!.trim().isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      flattenProfileText(description),
                      style: context.clBodySmall.copyWith(
                        color: brand.ink3,
                        height: 1.45,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Right panel: explains what this service is, plus mono unit /
/// binary / config metadata pulled from the profile YAML.
class _ExplainerPanel extends StatelessWidget {
  const _ExplainerPanel({required this.service, required this.state});

  final StockService service;
  final ServiceRuntimeState? state;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    final raw = service.raw;
    final wiz = jsonStringKeyMap(raw['wizard']) ?? const {};
    final blurb =
        jsonString(wiz['explainer']) ?? jsonString(raw['description']) ?? '';
    final unit = jsonString(raw['systemd_unit']);
    final binary = jsonString(raw['binary']);
    final config = jsonString(raw['config_path']);

    return ClPanel(
      padding: const EdgeInsets.all(18),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ClTechLabel('What this service does'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  service.displayName,
                  style: context.clTitleMedium.copyWith(
                    fontWeight: FontWeight.w500,
                    color: brand.ink,
                  ),
                ),
              ),
              if (state != null) _StateChip(state: state!),
            ],
          ),
          if (blurb.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              flattenProfileText(blurb),
              style: context.clBodySmall.copyWith(
                color: brand.ink2,
                height: 1.55,
              ),
            ),
          ],
          if (unit != null || binary != null || config != null) ...[
            const SizedBox(height: 14),
            for (final entry in [
              if (unit != null) ('unit', unit),
              if (binary != null) ('binary', binary),
              if (config != null) ('config', config),
            ])
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    SizedBox(
                      width: 60,
                      child: Text(entry.$1, style: context.dataTiny),
                    ),
                    Expanded(
                      child: Text(
                        entry.$2,
                        style: context.dataTiny.copyWith(color: brand.ink3),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});
  final ServiceRuntimeState state;

  @override
  Widget build(BuildContext context) {
    final (label, kind) = _summarize();
    return ClStatusChip(label: label.toUpperCase(), kind: kind, compact: true);
  }

  (String, ClChipKind) _summarize() {
    if (state.unitActive || state.processRunning) {
      return ('running', ClChipKind.good);
    }
    if (state.unitExists) return ('installed · stopped', ClChipKind.info);
    if (state.launcherScriptExists) {
      return ('launcher present', ClChipKind.info);
    }
    return ('not detected', ClChipKind.neutral);
  }
}

class _QuestionProgress extends StatelessWidget {
  const _QuestionProgress({required this.current, required this.total});
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Row(
      children: [
        Text(
          'Question $current / $total',
          style: context.dataTiny.copyWith(color: brand.ink3),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ClProgressBar(value: total == 0 ? 0 : current / total),
        ),
      ],
    );
  }
}
