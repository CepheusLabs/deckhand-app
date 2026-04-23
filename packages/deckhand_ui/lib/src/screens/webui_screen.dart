import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class WebuiScreen extends ConsumerStatefulWidget {
  const WebuiScreen({super.key});

  @override
  ConsumerState<WebuiScreen> createState() => _WebuiScreenState();
}

class _WebuiScreenState extends ConsumerState<WebuiScreen> {
  final _selected = <String>{};
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final webui = profile?.stack.webui ?? const {};
    final choices = ((webui['choices'] as List?) ?? const []).cast<Map>();
    final defaultChoices = ((webui['default_choices'] as List?) ?? const [])
        .cast<String>();
    final probe = controller.printerState;

    // Seed once on first build. Prefer "whatever is already installed
    // on this specific printer" over the profile's declared defaults -
    // that way users returning to a partly-configured machine don't
    // accidentally un-select the UI they're already running.
    if (!_seeded) {
      final installed = [
        for (final raw in choices)
          if (probe.stackInstalls[raw['id']]?.installed == true)
            raw['id'] as String,
      ];
      _selected.addAll(installed.isNotEmpty ? installed : defaultChoices);
      _seeded = true;
    }

    final theme = Theme.of(context);
    final hasSelection = _selected.isNotEmpty;

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: t.webui.title,
      helperText: t.webui.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: hasSelection
                  ? theme.colorScheme.surfaceContainerHighest
                  : theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(
                  hasSelection
                      ? Icons.info_outline
                      : Icons.error_outline,
                  size: 18,
                  color: hasSelection
                      ? theme.colorScheme.onSurfaceVariant
                      : theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    hasSelection
                        ? t.webui.requirement_ok
                        : t.webui.requirement_missing,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: hasSelection
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          for (final raw in choices)
            _WebuiChoiceTile(
              raw: raw,
              selected: _selected.contains(raw['id']),
              install: probe.stackInstalls[raw['id']],
              descriptionBuilder: _userFacingBlurb,
              onToggle: (v) => setState(() {
                final id = raw['id'] as String;
                if (v) {
                  _selected.add(id);
                } else {
                  _selected.remove(id);
                }
              }),
            ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
        onPressed: hasSelection
            ? () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('webui', _selected.toList());
                if (context.mounted) context.go('/kiauh');
              }
            : null,
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/firmware'),
        ),
      ],
    );
  }

  /// Prefer a profile-supplied `description`. If absent, fall back to a
  /// terse "<display_name> - port <n>" line so at least the reader knows
  /// which service we're installing. Per-id prose belongs in the
  /// profile YAML, not in this widget.
  String _userFacingBlurb(Map raw) {
    final desc = raw['description'] as String?;
    if (desc != null && desc.trim().isNotEmpty) return desc.trim();
    final port = raw['default_port'];
    final name = raw['display_name'] as String? ?? raw['id'] as String;
    return port == null ? name : '$name on port $port';
  }
}

/// One web-UI choice tile with a live "already installed" chip driven
/// by the state probe. Keeps the existing checkbox UX but adds the
/// signal users need to avoid reinstalling a working UI on top of
/// itself.
class _WebuiChoiceTile extends StatelessWidget {
  const _WebuiChoiceTile({
    required this.raw,
    required this.selected,
    required this.install,
    required this.descriptionBuilder,
    required this.onToggle,
  });
  final Map raw;
  final bool selected;
  final InstallState? install;
  final String Function(Map) descriptionBuilder;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final id = raw['id'] as String? ?? '';
    final alreadyInstalled = install?.installed ?? false;
    final isActive = install?.active ?? false;
    Widget? chip;
    if (alreadyInstalled && isActive) {
      chip = _StatusChip(
        label: 'installed + running',
        color: theme.colorScheme.primary,
      );
    } else if (alreadyInstalled) {
      chip = _StatusChip(
        label: 'installed',
        color: theme.colorScheme.secondary,
      );
    }
    return CheckboxListTile(
      value: selected,
      onChanged: (v) => onToggle(v ?? false),
      title: Row(
        children: [
          Expanded(child: Text(raw['display_name'] as String? ?? id)),
          if (chip != null) ...[
            const SizedBox(width: 8),
            chip,
          ],
        ],
      ),
      subtitle: Text(descriptionBuilder(raw)),
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
