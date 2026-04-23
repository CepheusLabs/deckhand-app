import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ScreenChoiceScreen extends ConsumerStatefulWidget {
  const ScreenChoiceScreen({super.key});

  @override
  ConsumerState<ScreenChoiceScreen> createState() => _ScreenChoiceScreenState();
}

class _ScreenChoiceScreenState extends ConsumerState<ScreenChoiceScreen> {
  String? _choice;

  bool _isSelectable(dynamic s) {
    // Alpha / experimental screens are shown but not selectable by
    // default - they're incomplete and the user shouldn't accidentally
    // pick one. Advanced users can flip the status in the profile to
    // unlock.
    final status = s.status as String?;
    return status != 'alpha' && status != 'experimental';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final screens = controller.profile?.screens ?? const [];
    final probe = controller.printerState;
    // Pre-select a screen that's already installed + active, so users
    // returning to a partly-configured machine don't silently re-pick
    // the profile-recommended one over what they're running.
    _choice ??= screens
        .firstWhere(
          (s) => probe.screenInstalls[s.id]?.active == true &&
              _isSelectable(s),
          orElse: () => screens.firstWhere(
            (s) => s.recommended && _isSelectable(s),
            orElse: () => screens.firstWhere(
              _isSelectable,
              orElse: () => screens.first,
            ),
          ),
        )
        .id;

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Pick a screen daemon',
      helperText:
          'The screen daemon drives your printer\'s touchscreen. Options '
          'marked alpha are in development and disabled here; pick one of '
          'the stable choices for daily use.',
      body: RadioGroup<String>(
        groupValue: _choice,
        onChanged: (v) => setState(() => _choice = v),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final s in screens)
              Opacity(
                opacity: _isSelectable(s) ? 1.0 : 0.45,
                child: Card(
                  elevation: _choice == s.id ? 4 : 1,
                  color: _choice == s.id
                      ? theme.colorScheme.primaryContainer
                      : null,
                  child: RadioListTile<String>(
                    value: s.id,
                    title: Row(
                      children: [
                        Expanded(child: Text(s.displayName ?? s.id)),
                        if (s.status != null) ...[
                          const SizedBox(width: 8),
                          _StatusBadge(status: s.status as String),
                        ],
                        if (probe.screenInstalls[s.id]?.active == true) ...[
                          const SizedBox(width: 6),
                          _InstallBadge(
                            label: 'running',
                            color: theme.colorScheme.primary,
                          ),
                        ] else if (
                            probe.screenInstalls[s.id]?.installed == true) ...[
                          const SizedBox(width: 6),
                          _InstallBadge(
                            label: 'installed',
                            color: theme.colorScheme.secondary,
                          ),
                        ],
                      ],
                    ),
                    subtitle: _subtitle(context, s),
                    isThreeLine: _hasNotes(s),
                    enabled: _isSelectable(s),
                  ),
                ),
              ),
          ],
        ),
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: _choice == null
            ? null
            : () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('screen', _choice!);
                if (context.mounted) context.go('/services');
              },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/kiauh')),
      ],
    );
  }

  bool _hasNotes(dynamic s) {
    final notes = s.raw['notes'] as String?;
    return notes != null && notes.trim().isNotEmpty;
  }

  Widget _subtitle(BuildContext context, dynamic s) {
    final notes = flattenProfileText(s.raw['notes'] as String?);
    if (notes.isEmpty) {
      final kind = s.raw['source_kind'] as String?;
      return Text(kind == null ? '' : 'source: $kind');
    }
    return Text(notes);
  }
}

class _InstallBadge extends StatelessWidget {
  const _InstallBadge({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withValues(alpha: 0.4),
          width: 0.5,
        ),
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

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = switch (status) {
      'stable' => theme.colorScheme.tertiary,
      'beta' => theme.colorScheme.secondary,
      'alpha' => theme.colorScheme.primary,
      'experimental' => theme.colorScheme.error,
      'deprecated' => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        status,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
