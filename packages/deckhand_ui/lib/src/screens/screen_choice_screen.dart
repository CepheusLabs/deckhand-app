import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';
import 'package:deckhand_core/deckhand_core.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../utils/json_safety.dart';
import '../widgets/profile_text.dart';

class ScreenChoiceScreen extends ConsumerStatefulWidget {
  const ScreenChoiceScreen({super.key});

  @override
  ConsumerState<ScreenChoiceScreen> createState() => _ScreenChoiceScreenState();
}

class _ScreenChoiceScreenState extends ConsumerState<ScreenChoiceScreen> {
  String? _choice;

  bool _isSelectable(ScreenConfig s) {
    final status = s.status;
    return status != 'alpha' && status != 'experimental';
  }

  String? _defaultChoice(List<ScreenConfig> screens, PrinterState probe) {
    for (final s in screens) {
      if (probe.screenInstalls[s.id]?.active == true && _isSelectable(s)) {
        return s.id;
      }
    }
    for (final s in screens) {
      if (s.recommended == true && _isSelectable(s)) return s.id;
    }
    for (final s in screens) {
      if (_isSelectable(s)) return s.id;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final screens = controller.profile?.screens ?? const [];
    final probe = controller.printerState;

    if (_choice != null) {
      final selected = screens.where((s) => s.id == _choice).firstOrNull;
      if (selected == null || !_isSelectable(selected)) _choice = null;
    }
    if (_choice == null && screens.isNotEmpty) {
      _choice = _defaultChoice(screens, probe);
    }

    return ClWizardPageScaffold(
      title: 'Choose the screen daemon.',
      helperText:
          'What runs on the printer\'s attached touchscreen. Options '
          'marked alpha are in development and not selectable; pick a '
          'stable choice for daily use.',
      body: ClEqualHeightGrid(
        maxColumns: 3,
        minColumnWidth: 320,
        children: [
          for (final s in screens)
            _ScreenCard(
              name: s.displayName ?? s.id,
              status: s.status ?? 'stub',
              notes: flattenProfileText(jsonString(s.raw['notes'])),
              selectable: _isSelectable(s),
              selected: _choice == s.id,
              installState: _installSummary(probe, s.id),
              onTap: _isSelectable(s)
                  ? () => setState(() => _choice = s.id)
                  : null,
            ),
        ],
      ),
      primaryAction: ClWizardAction(
        label: t.common.action_continue,
        disabledReason: _choice == null
            ? 'Select a screen option first.'
            : null,
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
        ClWizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/kiauh'),
          isBack: true,
        ),
      ],
    );
  }

  /// "running" if the daemon is installed AND active on this printer,
  /// "installed" if installed but not active, null otherwise.
  String? _installSummary(dynamic probe, String id) {
    final state = probe.screenInstalls[id];
    if (state == null) return null;
    if (state.active == true) return 'running';
    if (state.installed == true) return 'installed';
    return null;
  }
}

/// Maps a profile `status` field (stable/beta/alpha/experimental/
/// deprecated) to a forge chip kind. Mirrors the old
/// `StatusPill.fromProfileStatus` color mapping.
ClChipKind _profileStatusKind(String status) => switch (status) {
  'stable' => ClChipKind.good,
  'beta' => ClChipKind.info,
  'alpha' => ClChipKind.accent,
  'experimental' || 'deprecated' => ClChipKind.bad,
  _ => ClChipKind.neutral,
};

class _ScreenCard extends StatelessWidget {
  const _ScreenCard({
    required this.name,
    required this.status,
    required this.notes,
    required this.selectable,
    required this.selected,
    required this.onTap,
    this.installState,
  });

  final String name;
  final String status;
  final String notes;
  final bool selectable;
  final bool selected;
  final VoidCallback? onTap;
  final String? installState;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Opacity(
      opacity: selectable ? 1.0 : 0.45,
      child: ClSelectionCard(
        selected: selected,
        onTap: onTap,
        padding: const EdgeInsets.fromLTRB(18, 16, 40, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    name,
                    // Allow up to 2 lines before ellipsis. Profile-
                    // authored display names are sometimes long (e.g.
                    // "Stock voronFDM screen (recommended)") and a
                    // 3-column 1-line layout truncates them. 2 lines
                    // accommodates typical names; absurdly long ones
                    // still ellipsize at the second-line edge.
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: context.clTitleMedium.copyWith(
                      fontWeight: FontWeight.w500,
                      color: brand.ink,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ClStatusChip(label: status, kind: _profileStatusKind(status)),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                notes,
                style: context.clBodySmall.copyWith(
                  color: brand.ink2,
                  height: 1.5,
                ),
              ),
            ],
            if (installState != null) ...[
              const SizedBox(height: 10),
              ClStatusChip(
                label: installState!.toUpperCase(),
                kind: installState == 'running'
                    ? ClChipKind.good
                    : ClChipKind.info,
                compact: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
