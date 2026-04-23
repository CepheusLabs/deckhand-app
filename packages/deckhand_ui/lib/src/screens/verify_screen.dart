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

  Future<void> _pruneOld() async {
    final n = await ref
        .read(wizardControllerProvider)
        .pruneBackups(olderThan: const Duration(days: 30));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Pruned $n backup(s) older than 30 days.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final detections = profile?.stockOs.detections ?? const [];
    final allBackups = controller.printerState.deckhandBackups;
    // Partition backups: those tagged with the CURRENT profile_id
    // (or unknown / legacy / untagged) show as actionable. Backups
    // that belong to a DIFFERENT profile show dimmed under a
    // secondary header so the user sees them but doesn't assume they
    // apply here. This matters on reused / cloned images.
    final currentProfileId = profile?.id;
    final relevantBackups = <DeckhandBackup>[];
    final foreignBackups = <DeckhandBackup>[];
    for (final b in allBackups) {
      if (b.profileId == null || b.profileId == currentProfileId) {
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
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        icon: const Icon(Icons.cleaning_services, size: 16),
                        label: const Text('Prune backups > 30 days old'),
                        onPressed: _pruneOld,
                      ),
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
    final metaBits = <String>[
      if (backup.profileId != null) 'profile ${backup.profileId}',
      if (backup.stepId != null) 'step ${backup.stepId}',
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
