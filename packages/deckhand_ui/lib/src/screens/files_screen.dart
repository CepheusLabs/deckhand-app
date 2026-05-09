import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/json_safety.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/wizard_scaffold.dart';

/// Stock-OS leftover files the profile declares can be cleaned up.
/// The probe tells us which ones actually exist on *this* printer; we
/// partition the list into "still present" (actionable) and "already
/// gone" (dimmed under a separate header). Keeps the user from picking
/// actions for things that aren't there.
class FilesScreen extends ConsumerStatefulWidget {
  const FilesScreen({super.key});

  @override
  ConsumerState<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends ConsumerState<FilesScreen> {
  final _deleteSelected = <String>{};
  bool _seeded = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final files = controller.profile?.stockOs.files ?? const [];
    if (!_seeded) {
      for (final f in files) {
        if (f.defaultAction == 'delete') _deleteSelected.add(f.id);
      }
      _seeded = true;
    }
    final probe = controller.printerState;
    final probeReady = probe.probedAt != null;

    final present = <StockFile>[];
    final absent = <StockFile>[];
    for (final f in files) {
      final exists = probe.files[f.id];
      if (probeReady && exists == false) {
        absent.add(f);
      } else {
        present.add(f);
      }
    }

    return WizardScaffold(
      screenId: 'S140-files-cleanup',
      title: 'Files to clean up.',
      helperText:
          'Vendor leftovers detected on the OS. Tick anything you want '
          'removed; defaults follow the profile\'s recommendation. Files '
          'the profile mentions but that the probe didn\'t find on the '
          'printer collapse into a dimmed "already gone" group below.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!probeReady)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: _ProbeLoadingBanner(),
            ),
          _Toolbar(
            selectAllEnabled: present.isNotEmpty,
            clearEnabled: _deleteSelected.isNotEmpty,
            onSelectAll: () => setState(() {
              _deleteSelected
                ..clear()
                ..addAll(present.map((f) => f.id));
            }),
            onClear: () => setState(() => _deleteSelected.clear()),
          ),
          const SizedBox(height: 8),
          if (present.isEmpty && probeReady)
            const _EmptyNotice(
              message: 'No vendor leftovers detected on this printer.',
            )
          else
            _FilesPanel(
              files: present,
              dimmed: false,
              isSelected: _deleteSelected.contains,
              onToggle: (id) => setState(() {
                if (_deleteSelected.contains(id)) {
                  _deleteSelected.remove(id);
                } else {
                  _deleteSelected.add(id);
                }
              }),
            ),
          if (absent.isNotEmpty) ...[
            const SizedBox(height: 18),
            _SectionHeader(
              label: 'Already clean (${absent.length})',
              subtitle:
                  'These paths aren\'t on your printer. No action needed; '
                  'the wizard will skip them.',
            ),
            const SizedBox(height: 8),
            _FilesPanel(
              files: absent,
              dimmed: true,
              isSelected: (_) => false,
              onToggle: (_) {},
            ),
          ],
          const SizedBox(height: 14),
          // Count only the queued items that the probe says are
          // actually on the printer. Profiles seed their default-
          // delete files into `_deleteSelected` before the probe
          // returns, so absent files were inflating the queue
          // count ("8 of 0" when everything turned out already
          // clean).
          if (present.isNotEmpty)
            _SummaryStrip(
              queuedCount: _deleteSelected
                  .where((id) => present.any((f) => f.id == id))
                  .length,
              totalPresent: present.length,
            ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
        onPressed: () async {
          for (final f in files) {
            await ref
                .read(wizardControllerProvider)
                .setDecision(
                  'file.${f.id}',
                  _deleteSelected.contains(f.id) ? 'delete' : 'keep',
                );
          }
          if (!context.mounted) return;
          final hasSnapshotStep = controller.state.flow == WizardFlow.stockKeep;
          context.go(hasSnapshotStep ? '/snapshot' : '/hardening');
        },
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/services'),
          isBack: true,
        ),
      ],
    );
  }
}

class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.selectAllEnabled,
    required this.clearEnabled,
    required this.onSelectAll,
    required this.onClear,
  });
  final bool selectAllEnabled;
  final bool clearEnabled;
  final VoidCallback onSelectAll;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        OutlinedButton(
          onPressed: selectAllEnabled ? onSelectAll : null,
          child: const Text('Select all present'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          onPressed: clearEnabled ? onClear : null,
          child: const Text('Clear'),
        ),
      ],
    );
  }
}

class _FilesPanel extends StatelessWidget {
  const _FilesPanel({
    required this.files,
    required this.dimmed,
    required this.isSelected,
    required this.onToggle,
  });

  final List<StockFile> files;
  final bool dimmed;
  final bool Function(String id) isSelected;
  final void Function(String id) onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Opacity(
      opacity: dimmed ? 0.55 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          color: tokens.ink1,
          border: Border.all(color: tokens.line),
          borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < files.length; i++)
              _FileRow(
                file: files[i],
                selected: isSelected(files[i].id),
                isDefault: files[i].defaultAction == 'delete',
                isLast: i == files.length - 1,
                disabled: dimmed,
                onToggle: () => onToggle(files[i].id),
              ),
          ],
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.file,
    required this.selected,
    required this.isDefault,
    required this.isLast,
    required this.disabled,
    required this.onToggle,
  });

  final StockFile file;
  final bool selected;
  final bool isDefault;
  final bool isLast;
  final bool disabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final helper =
        jsonString(jsonStringKeyMap(file.raw['wizard'])?['helper_text']) ?? '';
    final paths = file.paths.join(', ');
    return InkWell(
      onTap: disabled ? null : onToggle,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: tokens.lineSoft)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: Checkbox(
                value: selected,
                onChanged: disabled ? null : (_) => onToggle(),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    file.displayName,
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontSans,
                      fontSize: DeckhandTokens.tMd,
                      fontWeight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                  if (paths.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      paths,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tXs,
                        color: tokens.text3,
                      ),
                    ),
                  ],
                  if (helper.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      helper,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontSans,
                        fontSize: DeckhandTokens.tXs,
                        color: tokens.text4,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (isDefault) ...[
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
                decoration: BoxDecoration(
                  color: tokens.ink3,
                  border: Border.all(color: tokens.line),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  'DEFAULT',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 9,
                    color: tokens.text2,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.06 * 9,
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

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.subtitle});
  final String label;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tMd,
            fontWeight: FontWeight.w600,
            color: tokens.text2,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
          ),
        ),
      ],
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({required this.queuedCount, required this.totalPresent});
  final int queuedCount;
  final int totalPresent;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: queuedCount > 0 ? tokens.ok : tokens.text4,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$queuedCount of $totalPresent files queued for removal',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tXs,
              color: tokens.text3,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyNotice extends StatelessWidget {
  const _EmptyNotice({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 18, color: tokens.ok),
          const SizedBox(width: 10),
          Text(
            message,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tSm,
              color: tokens.text2,
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
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.info.withValues(alpha: 0.10),
        border: Border.all(color: tokens.info.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          DeckhandSpinner(size: 14, strokeWidth: 2, color: tokens.info),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Probing this printer to see which files are actually present…',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.info,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
