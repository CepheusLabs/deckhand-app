import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

/// One card per stock-OS service that declares a `wizard:` block. Each
/// card is collapsible so the whole list fits on one page and the user
/// can see at a glance what they've decided without bouncing between
/// pages. The first un-answered service is expanded by default; the
/// rest stay collapsed until the user opens them.
class ServicesScreen extends ConsumerStatefulWidget {
  const ServicesScreen({super.key});

  @override
  ConsumerState<ServicesScreen> createState() => _ServicesScreenState();
}

class _ServicesScreenState extends ConsumerState<ServicesScreen> {
  final _expanded = <String>{};
  bool _seeded = false;

  List<StockService> _queue() {
    final all =
        ref.read(wizardControllerProvider).profile?.stockOs.services ??
        const [];
    return all.where((s) {
      final w = s.raw['wizard'];
      return w != null && w != 'none';
    }).toList();
  }

  void _seedDefaults() {
    if (_seeded) return;
    _seeded = true;
    final controller = ref.read(wizardControllerProvider);
    final queue = _queue();
    for (final svc in queue) {
      final key = 'service.${svc.id}';
      if (controller.decision<String>(key) == null) {
        final seeded = controller.resolveServiceDefault(svc);
        controller.setDecision(key, seeded);
      }
    }
    // Expand the first service so the user sees an example of what the
    // card looks like opened; everything else starts collapsed.
    if (queue.isNotEmpty) _expanded.add(queue.first.id);
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_seeded) setState(_seedDefaults);
    });

    // Subscribe to wizard events so the list rebuilds when the probe
    // lands fresh data (changes which services show up as absent).
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final queue = _queue();
    final probe = controller.printerState;
    final probeReady = probe.probedAt != null;

    // Split into "detected on this printer" and "absent / already
    // clean". Absent cards still render but greyed + collapsed so
    // the user can see we looked and found nothing.
    final present = <StockService>[];
    final absent = <StockService>[];
    for (final svc in queue) {
      final state = probe.services[svc.id];
      if (probeReady && state != null && !state.present) {
        absent.add(svc);
      } else {
        present.add(svc);
      }
    }

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Stock services',
      helperText:
          'Each stock service below is up to you. We probed your printer '
          'after you connected - services already removed or disabled show '
          'up dimmed under "Already clean" so you don\'t waste time picking '
          'an action for something that isn\'t there. Pick what you care '
          'about; defaults handle the rest.',
      body: queue.isEmpty
          ? const Text('Nothing to configure on this profile.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!probeReady)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: _ProbeLoadingBanner(),
                  ),
                for (final svc in present)
                  _ServiceCard(
                    service: svc,
                    state: probe.services[svc.id],
                    currentDecision:
                        controller.decision<String>('service.${svc.id}'),
                    expanded: _expanded.contains(svc.id),
                    dimmed: false,
                    onExpandChange: (v) => setState(() {
                      if (v) {
                        _expanded.add(svc.id);
                      } else {
                        _expanded.remove(svc.id);
                      }
                    }),
                    onChoose: (action) {
                      controller.setDecision('service.${svc.id}', action);
                      setState(() {});
                    },
                  ),
                if (absent.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  _SectionHeader(
                    label: 'Already clean (${absent.length})',
                    subtitle:
                        'These services were declared in the profile but '
                        'we did not find them running on this printer. No '
                        'action needed.',
                  ),
                  for (final svc in absent)
                    _ServiceCard(
                      service: svc,
                      state: probe.services[svc.id],
                      currentDecision:
                          controller.decision<String>('service.${svc.id}'),
                      expanded: false,
                      dimmed: true,
                      onExpandChange: (_) {},
                      onChoose: (_) {},
                    ),
                ],
              ],
            ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: () => context.go('/files'),
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          onPressed: () => context.go('/screen-choice'),
        ),
      ],
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.state,
    required this.currentDecision,
    required this.expanded,
    required this.dimmed,
    required this.onExpandChange,
    required this.onChoose,
  });

  final StockService service;
  final ServiceRuntimeState? state;
  final String? currentDecision;
  final bool expanded;
  final bool dimmed;
  final ValueChanged<bool> onExpandChange;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wiz =
        (service.raw['wizard'] as Map?)?.cast<String, dynamic>() ?? const {};
    final options = ((wiz['options'] as List?) ?? const []).cast<Map>();
    final question = wiz['question'] as String?;
    final helper = wiz['helper_text'] as String?;

    final selectedLabel = _labelFor(options, currentDecision);

    final probeChip = _probeChip(theme);

    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Theme(
        // Remove ExpansionTile's built-in divider lines so it sits
        // cleanly inside a Card without doubling up borders.
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: expanded,
          onExpansionChanged: dimmed ? null : onExpandChange,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  service.displayName,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              if (probeChip != null) ...[
                const SizedBox(width: 8),
                probeChip,
              ],
            ],
          ),
          subtitle: selectedLabel == null || dimmed
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _DecisionChip(label: selectedLabel),
                ),
          children: [
            if (question != null) ...[
              Text(
                flattenProfileText(question),
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
            ],
            if (helper != null) ...[
              Text(
                flattenProfileText(helper),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
            ],
            RadioGroup<String>(
              groupValue: currentDecision,
              onChanged: (v) {
                if (v != null) onChoose(v);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final opt in options)
                    _OptionTile(
                      id: opt['id'] as String,
                      label: opt['label'] as String? ?? opt['id'] as String,
                      description: opt['description'] as String?,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  /// Small status chip summarising what the probe saw for this service.
  /// Hidden when probe data is unavailable (screen hasn't been probed
  /// yet) so we don't falsely imply "all clean" during that window.
  ///
  /// Status tiers (strongest signal first):
  ///   - running   - unit is active OR pattern-matched process found
  ///   - installed + stopped - unit file on disk but systemctl says
  ///                           inactive (user disabled it, or it
  ///                           hasn't been started). Calls out that
  ///                           choosing "disable" here is still a
  ///                           meaningful action even though the
  ///                           service isn't currently running.
  ///   - launcher present - script path from launched_by exists but
  ///                        no systemd unit + no running process
  ///                        (e.g. a cron/init.d launcher).
  ///   - not detected - nothing matched; action is a no-op.
  Widget? _probeChip(ThemeData theme) {
    final s = state;
    if (s == null) return null;
    if (s.unitActive || s.processRunning) {
      return _StatusChip(
        label: 'running',
        color: theme.colorScheme.tertiary,
      );
    }
    if (s.unitExists) {
      return _StatusChip(
        label: 'installed + stopped',
        color: theme.colorScheme.secondary,
      );
    }
    if (s.launcherScriptExists) {
      return _StatusChip(
        label: 'launcher present',
        color: theme.colorScheme.secondary,
      );
    }
    return _StatusChip(
      label: 'not detected',
      color: theme.colorScheme.outline,
    );
  }

  String? _labelFor(List<Map> options, String? id) {
    if (id == null) return null;
    for (final o in options) {
      if (o['id'] == id) return o['label'] as String? ?? id;
    }
    return id;
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.id,
    required this.label,
    this.description,
  });

  final String id;
  final String label;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final desc = description == null ? null : flattenProfileText(description);
    return RadioListTile<String>(
      value: id,
      title: Text(label),
      subtitle: desc == null || desc.isEmpty ? null : Text(desc),
      isThreeLine: desc != null && desc.length > 60,
      contentPadding: EdgeInsets.zero,
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
  const _ProbeLoadingBanner();
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
            child: Text(
              'Probing this printer to see which services are actually '
              'running. You can start picking while we check.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _DecisionChip extends StatelessWidget {
  const _DecisionChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSecondaryContainer,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
