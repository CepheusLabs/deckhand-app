import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class VerifyScreen extends ConsumerStatefulWidget {
  const VerifyScreen({super.key});

  @override
  ConsumerState<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends ConsumerState<VerifyScreen> {
  final _restoring = <String>{};
  final _deleting = <String>{};
  String? _restoreError;

  Future<void> _restore(DeckhandBackup b) async {
    setState(() {
      _restoring.add(b.backupPath);
      _restoreError = null;
    });
    try {
      await ref.read(wizardControllerProvider).restoreBackup(b);
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoreError = '$e');
    } finally {
      if (mounted) setState(() => _restoring.remove(b.backupPath));
    }
  }

  Future<void> _delete(DeckhandBackup b) async {
    final confirm = await _confirmDelete(b);
    if (confirm != true || !mounted) return;
    setState(() {
      _deleting.add(b.backupPath);
      _restoreError = null;
    });
    try {
      await ref.read(wizardControllerProvider).deleteBackup(b);
    } catch (e) {
      if (!mounted) return;
      setState(() => _restoreError = '$e');
    } finally {
      if (mounted) setState(() => _deleting.remove(b.backupPath));
    }
  }

  Future<bool?> _confirmDelete(DeckhandBackup b) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(t.verify.delete_confirm_title),
          content: Text(t.verify.delete_confirm_body(path: b.backupPath)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t.common.action_cancel),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t.verify.delete_confirm_action),
            ),
          ],
        ),
      );

  Future<void> _preview(DeckhandBackup b) async {
    final controller = ref.read(wizardControllerProvider);
    final content = await controller.readBackupContent(b);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.verify.preview_title(path: b.originalPath)),
        content: SizedBox(
          width: 720,
          height: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              content ?? t.verify.preview_unreadable,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.verify.preview_close),
          ),
        ],
      ),
    );
  }

  /// Prune interval in days. Hydrated from [DeckhandSettings] on
  /// first build; changes persist on Prune-click so the next session
  /// reuses the user's preference.
  int _pruneDays = 30;
  /// When true, the single newest backup per original-path survives
  /// the prune regardless of age. Safety net for "I pruned every
  /// backup and now have no snapshot to roll back to."
  bool _keepLatestPerTarget = true;
  bool _prunePrefsHydrated = false;

  void _hydratePrunePrefs() {
    if (_prunePrefsHydrated) return;
    final settings = ref.read(deckhandSettingsProvider);
    _pruneDays = settings.pruneOlderThanDays;
    _keepLatestPerTarget = settings.pruneKeepNewestPerTarget;
    _prunePrefsHydrated = true;
  }

  Future<void> _pruneOld() async {
    final settings = ref.read(deckhandSettingsProvider);
    // Persist the current choice so the next session defaults to it.
    settings.pruneOlderThanDays = _pruneDays;
    settings.pruneKeepNewestPerTarget = _keepLatestPerTarget;
    await settings.save();

    final n = await ref.read(wizardControllerProvider).pruneBackups(
          olderThan: Duration(days: _pruneDays),
          keepLatestPerTarget: _keepLatestPerTarget,
        );
    if (!mounted) return;
    final keepSuffix = _keepLatestPerTarget
        ? ' (kept the newest snapshot for each target)'
        : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(
        'Pruned $n backup(s) older than $_pruneDays days$keepSuffix.',
      )),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(wizardStateProvider);
    _hydratePrunePrefs();
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final detections = profile?.stockOs.detections ?? const [];
    final allBackups = controller.printerState.deckhandBackups;
    // Three buckets:
    //   relevant  - sidecar metadata confirms this profile_id
    //   legacy    - no sidecar metadata (older Deckhand build); could
    //               belong to anything, surface as a separate group
    //               so the user can see + decide
    //   foreign   - sidecar says it's from a DIFFERENT profile
    final currentProfileId = profile?.id;
    final relevantBackups = <DeckhandBackup>[];
    final legacyBackups = <DeckhandBackup>[];
    final foreignBackups = <DeckhandBackup>[];
    for (final b in allBackups) {
      if (b.profileId == null) {
        legacyBackups.add(b);
      } else if (b.profileId == currentProfileId) {
        relevantBackups.add(b);
      } else {
        foreignBackups.add(b);
      }
    }
    final backups = relevantBackups;

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: t.verify.title,
      helperText: t.verify.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (backups.isNotEmpty) ...[
            Card(
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.restore,
                            color: theme.colorScheme.onSecondaryContainer),
                        const SizedBox(width: 8),
                        Text(
                          t.verify.backups_heading,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      t.verify.backups_explainer,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final b in backups)
                      _BackupTile(
                        backup: b,
                        restoring: _restoring.contains(b.backupPath),
                        deleting: _deleting.contains(b.backupPath),
                        onRestore: () => _restore(b),
                        onPreview: () => _preview(b),
                        onDelete: () => _delete(b),
                      ),
                    if (_restoreError != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _restoreError!,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 12),
                    _PruneControls(
                      days: _pruneDays,
                      keepLatestPerTarget: _keepLatestPerTarget,
                      onDaysChanged: (v) =>
                          setState(() => _pruneDays = v),
                      onKeepLatestChanged: (v) =>
                          setState(() => _keepLatestPerTarget = v),
                      onPrune: _pruneOld,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (legacyBackups.isNotEmpty) ...[
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.verify.legacy_backups_heading(count: legacyBackups.length),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.verify.legacy_backups_explainer,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final b in legacyBackups)
                      _BackupTile(
                        backup: b,
                        restoring: _restoring.contains(b.backupPath),
                        deleting: _deleting.contains(b.backupPath),
                        onRestore: () => _restore(b),
                        onPreview: () => _preview(b),
                        onDelete: () => _delete(b),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (foreignBackups.isNotEmpty) ...[
            Card(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.verify.foreign_backups_heading(count: foreignBackups.length),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      t.verify.foreign_backups_explainer,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final b in foreignBackups)
                      _BackupTile(
                        backup: b,
                        restoring: false,
                        deleting: _deleting.contains(b.backupPath),
                        onRestore: null,
                        onPreview: () => _preview(b),
                        onDelete: () => _delete(b),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (detections.isEmpty)
            Text(t.verify.no_detections)
          else
            for (final d in detections)
              Card(
                child: ListTile(
                  leading: Icon(
                    d.required
                        ? Icons.check_circle_outline
                        : Icons.info_outline,
                    color: d.required
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                  title: Text(_title(d.kind, d.raw, profile?.manufacturer)),
                  subtitle: Text(_explain(d.kind, d.raw, d.required)),
                  isThreeLine: true,
                ),
              ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.verify.action_continue,
        onPressed: () => context.go('/choose-path'),
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/connect')),
      ],
    );
  }

  /// Human-facing title for a detection. Prefers the profile author's
  /// custom `label` field if present, otherwise falls back to a generic
  /// sentence keyed by detection `kind`.
  String _title(String kind, Map<String, dynamic> raw, String? vendor) {
    final custom = raw['label'] as String?;
    if (custom != null && custom.trim().isNotEmpty) return custom.trim();

    switch (kind) {
      case 'file_exists':
        return t.verify.check_title_file_exists;
      case 'file_contains':
        final pattern = raw['pattern'] as String? ?? '';
        return pattern.isEmpty
            ? t.verify.check_title_file_contains
            : t.verify.check_title_file_mentions(pattern: pattern);
      case 'process_running':
        final name = raw['name'] as String? ?? '';
        return name.isEmpty
            ? t.verify.check_title_service_running(
                vendor: vendor ?? t.verify.check_title_vendor_fallback,
              )
            : t.verify.check_title_named_process_running(name: name);
      case 'process_pattern':
        return t.verify.check_title_process_running;
      default:
        return t.verify.check_title_custom;
    }
  }

  /// Secondary line - profile-authored note when present, otherwise a
  /// plain-English description of the check kind. The concrete file
  /// path / pattern is kept out of the user-visible subtitle; it's
  /// available via a tooltip on the card for users who need it.
  String _explain(String kind, Map<String, dynamic> raw, bool required) {
    final note = flattenProfileText(raw['note'] as String?);
    final label = required ? t.verify.check_required : t.verify.check_optional;
    final kindLabel = switch (kind) {
      'file_exists' => t.verify.check_kind_file_exists,
      'file_contains' => t.verify.check_kind_file_contains,
      'process_running' => t.verify.check_kind_process_running,
      _ => t.verify.check_kind_custom,
    };
    final lines = <String>[
      '$label - $kindLabel',
      if (note.isNotEmpty) note,
    ];
    return lines.join('\n');
  }
}

class _PruneControls extends StatelessWidget {
  const _PruneControls({
    required this.days,
    required this.keepLatestPerTarget,
    required this.onDaysChanged,
    required this.onKeepLatestChanged,
    required this.onPrune,
  });
  final int days;
  final bool keepLatestPerTarget;
  final ValueChanged<int> onDaysChanged;
  final ValueChanged<bool> onKeepLatestChanged;
  final VoidCallback onPrune;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t.verify.prune_older_than, style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: days,
              items: [
                for (final n in const [7, 14, 30, 60, 90, 180])
                  DropdownMenuItem(
                    value: n,
                    child: Text(t.verify.prune_days(n: n)),
                  ),
              ],
              onChanged: (v) {
                if (v != null) onDaysChanged(v);
              },
            ),
          ],
        ),
        Tooltip(
          message: t.verify.prune_keep_latest_tooltip,
          waitDuration: const Duration(milliseconds: 300),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Checkbox(
                value: keepLatestPerTarget,
                onChanged: (v) => onKeepLatestChanged(v ?? true),
              ),
              Flexible(
                child: Text(
                  t.verify.prune_keep_latest_label,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                Icons.help_outline,
                size: 14,
                color: theme.colorScheme.outline,
              ),
            ],
          ),
        ),
        FilledButton.tonalIcon(
          icon: const Icon(Icons.cleaning_services, size: 16),
          label: Text(t.verify.prune_now),
          onPressed: onPrune,
        ),
      ],
    );
  }
}

class _BackupTile extends StatelessWidget {
  const _BackupTile({
    required this.backup,
    required this.restoring,
    required this.deleting,
    required this.onRestore,
    required this.onPreview,
    required this.onDelete,
  });
  final DeckhandBackup backup;
  final bool restoring;
  final bool deleting;
  final VoidCallback? onRestore; // null => foreign-profile backup
  final VoidCallback onPreview;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = restoring || deleting;
    // Sidecar-metadata line: who created this backup and when. Only
    // shown when at least one field is known - older backups without
    // a `.meta.json` stay quiet rather than displaying "unknown".
    // Null-or-empty step_id is common (write_file steps inside a
    // conditional carry no id) - omit those entirely so the line
    // doesn't show "step null" or "step ".
    // Only surface the timestamp to the user by default. profile_id
    // and step_id are internal identifiers - useful for debugging but
    // meaningless to basic users, and surfacing them on every tile
    // was flagged by the code review. They stay available via the
    // tile's tooltip so power users can still inspect them.
    final metaBits = <String>[
      if (backup.createdAt != null)
        t.verify.backup_created_at(
          ts: backup.createdAt!.toLocal().toString().substring(0, 19),
        ),
    ];
    final internalMeta = <String>[
      if (backup.profileId != null && backup.profileId!.isNotEmpty)
        'profile ${backup.profileId}',
      if (backup.stepId != null && backup.stepId!.isNotEmpty)
        'step ${backup.stepId}',
    ].join(' * ');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Tooltip(
              message: internalMeta.isEmpty
                  ? '${backup.backupPath}\n${backup.originalPath}'
                  : '${backup.backupPath}\n${backup.originalPath}\n$internalMeta',
              waitDuration: const Duration(milliseconds: 500),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    backup.originalPath,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFamily: 'monospace',
                    ),
                  ),
                  if (metaBits.isNotEmpty)
                    Text(
                      metaBits.join(' * '),
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.visibility, size: 16),
            label: Text(t.verify.backup_action_preview),
            onPressed: busy ? null : onPreview,
          ),
          const SizedBox(width: 4),
          TextButton.icon(
            icon: Icon(
              Icons.delete_outline,
              size: 16,
              color: theme.colorScheme.error,
            ),
            label: Text(
              deleting
                  ? t.verify.backup_action_deleting
                  : t.verify.backup_action_delete,
              style: TextStyle(color: theme.colorScheme.error),
            ),
            onPressed: busy ? null : onDelete,
          ),
          if (onRestore != null) ...[
            const SizedBox(width: 4),
            FilledButton.tonalIcon(
              onPressed: busy ? null : onRestore,
              icon: restoring
                  ? const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restore, size: 16),
              label: Text(
                restoring
                    ? t.verify.backup_action_restoring
                    : t.verify.backup_action_restore,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
