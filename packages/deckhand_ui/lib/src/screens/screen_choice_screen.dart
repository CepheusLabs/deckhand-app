import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/equal_height_grid.dart';
import '../widgets/profile_text.dart';
import '../widgets/selection_card.dart';
import '../widgets/status_pill.dart';
import '../widgets/wizard_scaffold.dart';

class ScreenChoiceScreen extends ConsumerStatefulWidget {
  const ScreenChoiceScreen({super.key});

  @override
  ConsumerState<ScreenChoiceScreen> createState() => _ScreenChoiceScreenState();
}

class _ScreenChoiceScreenState extends ConsumerState<ScreenChoiceScreen> {
  String? _choice;

  bool _isSelectable(dynamic s) {
    final status = s.status as String?;
    return status != 'alpha' && status != 'experimental';
  }

  String? _defaultChoice(List<dynamic> screens, dynamic probe) {
    for (final s in screens) {
      if (probe.screenInstalls[s.id]?.active == true && _isSelectable(s)) {
        return s.id as String?;
      }
    }
    for (final s in screens) {
      if (s.recommended == true && _isSelectable(s)) return s.id as String?;
    }
    for (final s in screens) {
      if (_isSelectable(s)) return s.id as String?;
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

    return WizardScaffold(
      screenId: 'S110-screen-daemon',
      title: 'Choose the screen daemon.',
      helperText:
          'What runs on the printer\'s attached touchscreen. Options '
          'marked alpha are in development and not selectable; pick a '
          'stable choice for daily use.',
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final cols = w >= 1080 ? 3 : (w >= 720 ? 2 : 1);
          return EqualHeightGrid(
            columns: cols,
            children: [
              for (final s in screens)
                _ScreenCard(
                  name: s.displayName ?? s.id,
                  status: s.status ?? 'stub',
                  notes: flattenProfileText(s.raw['notes'] as String?),
                  selectable: _isSelectable(s),
                  selected: _choice == s.id,
                  installState: _installSummary(probe, s.id),
                  onTap: _isSelectable(s)
                      ? () => setState(() => _choice = s.id)
                      : null,
                ),
            ],
          );
        },
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
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
        WizardAction(
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
    final tokens = DeckhandTokens.of(context);
    return Opacity(
      opacity: selectable ? 1.0 : 0.45,
      child: SelectionCard(
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
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontSans,
                      fontSize: DeckhandTokens.tLg,
                      fontWeight: FontWeight.w500,
                      color: tokens.text,
                      height: 1.3,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                StatusPill.fromProfileStatus(context, status),
              ],
            ),
            if (notes.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                notes,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text2,
                  height: 1.5,
                ),
              ),
            ],
            if (installState != null) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: (installState == 'running' ? tokens.ok : tokens.info)
                      .withValues(alpha: 0.10),
                  border: Border.all(
                    color: (installState == 'running' ? tokens.ok : tokens.info)
                        .withValues(alpha: 0.40),
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  installState!.toUpperCase(),
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.06 * 9,
                    color: installState == 'running' ? tokens.ok : tokens.info,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
