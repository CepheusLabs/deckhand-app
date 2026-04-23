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
    final profile = ref.watch(wizardControllerProvider).profile;
    final webui = profile?.stack.webui ?? const {};
    final choices = ((webui['choices'] as List?) ?? const []).cast<Map>();
    final defaultChoices = ((webui['default_choices'] as List?) ?? const [])
        .cast<String>();

    // Seed once on first build so the user's own toggles aren't clobbered
    // by the defaults after they clear a checkbox.
    if (!_seeded) {
      _selected.addAll(defaultChoices);
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
            CheckboxListTile(
              value: _selected.contains(raw['id']),
              onChanged: (v) => setState(() {
                final id = raw['id'] as String;
                if (v == true) {
                  _selected.add(id);
                } else {
                  _selected.remove(id);
                }
              }),
              title: Text(
                raw['display_name'] as String? ?? raw['id'] as String,
              ),
              subtitle: Text(_userFacingBlurb(raw)),
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
