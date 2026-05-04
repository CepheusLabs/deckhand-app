import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Mandatory review screen before "Save debug bundle" writes a zip.
/// See [docs/DEBUG-BUNDLES.md] for the full pipeline. The screen
/// shows the redacted contents of the session log + wizard state,
/// the redaction-stats summary, and Cancel/Save buttons.
///
/// This is a simplified v1 — the bundler that actually assembles +
/// zips the artifacts (and therefore the on-disk write path) is
/// flagged pending in [docs/DEBUG-BUNDLES.md]. The review surface
/// itself is in place so the contract for "every bundle goes through
/// review" is enforced from day one.
class DebugBundleScreen extends ConsumerStatefulWidget {
  const DebugBundleScreen({
    super.key,
    required this.sessionLog,
    required this.onSave,
    required this.onCancel,
  });

  /// Raw session-log text. The screen redacts before display.
  final String sessionLog;

  /// Called when the user clicks Save. Receives the redacted log so
  /// the bundler doesn't have to re-redact. The actual zip-write
  /// implementation owns "where on disk does this land" — review
  /// stays focused on "what is the user about to share?"
  final void Function(RedactedDocument log) onSave;

  /// Called when the user clicks Cancel. Most callers pop the
  /// containing dialog/route here.
  final VoidCallback onCancel;

  @override
  ConsumerState<DebugBundleScreen> createState() => _DebugBundleScreenState();
}

class _DebugBundleScreenState extends ConsumerState<DebugBundleScreen> {
  late RedactedDocument _redacted;

  @override
  void initState() {
    super.initState();
    _redacted = _buildRedactor().redact(widget.sessionLog);
  }

  Redactor _buildRedactor() {
    // Pull whatever live values the wizard knows. Missing keys are
    // fine — Redactor skips null/empty entries. Tests inject their
    // own controller via `wizardControllerProvider`; production
    // wires this from the live session.
    final controller = ref.read(wizardControllerProvider);
    return Redactor(sessionValues: controller.redactionSessionValues());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stats = _redacted.stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Review debug bundle'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: widget.onCancel,
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Deckhand will write a zip containing your session log, '
              'wizard decisions, the active profile, and a doctor '
              'report. This preview shows the redacted log content. '
              'Skim it, click Save when you\'re ready.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            _StatsCard(stats: stats),
            const SizedBox(height: 16),
            Text('Redacted log preview',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _redacted.text,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('Cancel'),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () => widget.onSave(_redacted),
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save bundle'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.stats});
  final RedactionStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (stats.isClean) {
      return Card(
        color: theme.colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Icon(Icons.check_circle_outline,
                  color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Nothing matched the redaction patterns. The bundle '
                  'looks clean — but skim the log below anyway.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final entries = <(String, int)>[
      if (stats.sessionHits > 0) ('session values', stats.sessionHits),
      if (stats.ipCount > 0) ('IPs', stats.ipCount),
      if (stats.macCount > 0) ('MACs', stats.macCount),
      if (stats.emailCount > 0) ('emails', stats.emailCount),
      if (stats.fprCount > 0) ('SSH fingerprints', stats.fprCount),
      if (stats.secretCount > 0) ('probable secrets', stats.secretCount),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Redactions applied',
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final (label, count) in entries)
                  Chip(
                    label: Text('$count $label'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
