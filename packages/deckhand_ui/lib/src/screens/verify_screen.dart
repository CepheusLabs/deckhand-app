import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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
          title: const Text('Delete this backup?'),
          content: Text(
            'Removes ${b.backupPath} plus its metadata sidecar. '
            'Once deleted, there is no way to undo the original '
            'write_file that created this backup.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton.tonal(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Delete'),
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
        title: Text('Preview: ${b.originalPath}'),
        content: SizedBox(
          width: 720,
          height: 480,
          child: SingleChildScrollView(
            child: SelectableText(
              content ?? '(could not read backup contents)',
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
            child: const Text('Close'),
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
      title: 'Does this look like your printer?',
      helperText:
          'A few quick sanity checks so we can confirm the profile you '
          'picked matches what\'s actually on this machine. Required '
          'checks need to match for the flow to work. Optional ones are '
          'hints that we\'re talking to the right kind of printer.',
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
                          'Previous Deckhand backups found',
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'A prior Deckhand run overwrote these files and saved '
                      'the originals with a timestamped suffix. Restore any '
                      'that shouldn\'t have been touched before continuing.',
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
                      'Legacy backups without profile metadata '
                      '(${legacyBackups.length})',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'These were written by an older Deckhand build that '
                      'did not record which profile created them. Preview '
                      'before restoring - content could belong to any '
                      'profile previously run against this printer.',
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
                      'Backups from other profiles (${foreignBackups.length})',
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'These backups were created by a different profile. '
                      'They are listed for transparency but the Restore '
                      'action is disabled because the content is unlikely '
                      'to apply to the current profile\'s setup.',
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
            const Text('No detection rules declared for this profile.')
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
        label: 'Looks right, continue',
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
        return 'A vendor file we expect to see is present';
      case 'file_contains':
        final pattern = raw['pattern'] as String? ?? '';
        return pattern.isEmpty
            ? 'A file contains an expected marker'
            : 'A file mentions "$pattern"';
      case 'process_running':
        final name = raw['name'] as String? ?? '';
        return name.isEmpty
            ? '${vendor ?? "Vendor"} service is running'
            : '"$name" is running';
      case 'process_pattern':
        return 'A vendor process is running';
      default:
        return 'Custom check';
    }
  }

  /// Secondary line - the "how we check it" detail plus any note from
  /// the profile, kept out of the title so non-technical users aren\'t
  /// confronted with a filesystem path first.
  String _explain(String kind, Map<String, dynamic> raw, bool required) {
    final note = flattenProfileText(raw['note'] as String?);
    final label = required ? 'Needs to be present' : 'Optional hint';
    final detail = switch (kind) {
      'file_exists' => 'Checks: ${raw['path']}',
      'file_contains' =>
        'Checks: ${raw['path']} contains "${raw['pattern']}"',
      'process_running' => 'Checks: process "${raw['name']}"',
      _ => raw.toString(),
    };
    return [
      '$label - $detail',
      if (note.isNotEmpty) note,
    ].join('\n');
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
            Text('Prune backups older than', style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            DropdownButton<int>(
              value: days,
              items: const [
                DropdownMenuItem(value: 7, child: Text('7 days')),
                DropdownMenuItem(value: 14, child: Text('14 days')),
                DropdownMenuItem(value: 30, child: Text('30 days')),
                DropdownMenuItem(value: 60, child: Text('60 days')),
                DropdownMenuItem(value: 90, child: Text('90 days')),
                DropdownMenuItem(value: 180, child: Text('180 days')),
              ],
              onChanged: (v) {
                if (v != null) onDaysChanged(v);
              },
            ),
          ],
        ),
        Tooltip(
          message:
              'For every file Deckhand has backed up, the newest snapshot '
              'survives the prune - even if it is older than the interval '
              'above. Keeps you from a "pruned every backup, now have no '
              'rollback" scenario. Uncheck for a true sweep.',
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
                  'Keep the newest snapshot per target',
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
          label: const Text('Prune now'),
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
    final metaBits = <String>[
      if (backup.profileId != null && backup.profileId!.isNotEmpty)
        'profile ${backup.profileId}',
      if (backup.stepId != null && backup.stepId!.isNotEmpty)
        'step ${backup.stepId}',
      if (backup.createdAt != null)
        'at ${backup.createdAt!.toLocal().toString().substring(0, 19)}',
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  backup.originalPath,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  'backup: ${backup.backupPath}',
                  style: theme.textTheme.labelSmall?.copyWith(
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
          const SizedBox(width: 8),
          TextButton.icon(
            icon: const Icon(Icons.visibility, size: 16),
            label: const Text('Preview'),
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
              deleting ? 'Deleting...' : 'Delete',
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
              label: Text(restoring ? 'Restoring...' : 'Restore'),
            ),
          ],
        ],
      ),
    );
  }
}
