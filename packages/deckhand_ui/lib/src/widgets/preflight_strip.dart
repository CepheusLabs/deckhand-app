import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import 'deckhand_loading.dart';

/// Tiny status row for S10-welcome that watches the shared
/// [preflightReportProvider] and shows a single-line summary with a
/// "View report" expander on tap.
///
/// The strip itself never decides whether navigation should block —
/// that's the welcome screen's job (it watches the same provider and
/// disables the Start button while the future is pending). Failures
/// are loud (red icon + count) but downstream destructive flows have
/// their own preconditions and gate independently. The strip's job
/// is to surface "the boring failures" (helper missing, dir not
/// writable, pkexec absent) before the user has invested 20 minutes.
class PreflightStrip extends ConsumerWidget {
  const PreflightStrip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(preflightReportProvider);
    return async.when(
      loading: () => _Row(
        icon: const SizedBox(
          width: 14,
          height: 14,
          child: DeckhandSpinner(size: 14, strokeWidth: 2),
        ),
        label: 'Preflight: running…',
        color: theme.colorScheme.onSurfaceVariant,
        tooltipMessage: _runningTooltip,
      ),
      error: (e, _) => _Row(
        icon: Icon(
          Icons.help_outline,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        label: 'Preflight: unavailable ($e)',
        color: theme.colorScheme.onSurfaceVariant,
        tooltipMessage:
            'The doctor service did not respond. Retry to ask '
            'again. Mid-session hiccups are usually transient.',
        onRetry: () => ref.invalidate(preflightReportProvider),
      ),
      data: (report) {
        final tooltipMessage = _summarizeChecks(report);
        if (report.passed && report.warnings.isEmpty) {
          return _Row(
            icon: Icon(
              Icons.check_circle_outline,
              size: 18,
              color: theme.colorScheme.primary,
            ),
            label: 'Preflight: ready',
            color: theme.colorScheme.primary,
            tooltipMessage: tooltipMessage,
            onViewReport: () => _showReport(context, report),
          );
        }
        if (report.passed) {
          // No FAILs, but at least one WARN. Yellow but unblocking.
          final n = report.warnings.length;
          return _Row(
            icon: const Icon(
              Icons.info_outline,
              size: 18,
              color: Colors.orange,
            ),
            label: 'Preflight: ready ($n warning${n == 1 ? '' : 's'})',
            color: Colors.orange,
            tooltipMessage: tooltipMessage,
            onViewReport: () => _showReport(context, report),
          );
        }
        final n = report.failures.length;
        return _Row(
          icon: Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.error,
          ),
          label:
              'Preflight: $n issue${n == 1 ? '' : 's'} — '
              '${report.failures.first.name}',
          color: theme.colorScheme.error,
          tooltipMessage: tooltipMessage,
          onViewReport: () => _showReport(context, report),
          onRetry: () => ref.invalidate(preflightReportProvider),
        );
      },
    );
  }

  static const String _runningTooltip =
      'Running boot checks before the wizard starts:\n'
      '  · sidecar process responding\n'
      '  · helper binaries present and runnable\n'
      '  · file-system permissions on data + cache dirs\n'
      '  · elevation tooling for destructive flows\n'
      'Usually finishes in well under a second.';

  /// Human-readable summary of each check, one per line. Used for
  /// the tooltip once the report is in.
  static String _summarizeChecks(DoctorReport report) {
    if (report.results.isEmpty) {
      return 'No check results were returned.';
    }
    final buf = StringBuffer('Checks (hover an item to see detail):\n');
    for (final r in report.results) {
      final marker = switch (r.status) {
        DoctorStatus.pass => '[PASS]',
        DoctorStatus.warn => '[WARN]',
        DoctorStatus.fail => '[FAIL]',
        DoctorStatus.unknown => '[ ?  ]',
      };
      buf.writeln('  $marker ${r.name}');
    }
    return buf.toString().trimRight();
  }

  void _showReport(BuildContext context, DoctorReport report) {
    showDialog<void>(
      context: context,
      // CRITICAL: use the builder's own context for `Navigator.of`
      // below. The outer `context` belongs to the welcome screen,
      // which lives inside the GoRouter ShellRoute's nested
      // Navigator — popping that one closes the welcome route and
      // blacks the screen instead of dismissing the dialog. The
      // dialog itself is on the root navigator (showDialog default),
      // so resolving Navigator from the dialog's own context picks
      // up the right one.
      builder: (dialogCtx) => Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Preflight report',
                  style: Theme.of(dialogCtx).textTheme.titleMedium,
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      report.report,
                      style: const TextStyle(fontFamily: 'monospace'),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(dialogCtx).pop(),
                    child: const Text('Close'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.color,
    required this.tooltipMessage,
    this.onViewReport,
    this.onRetry,
  });

  final Widget icon;
  final String label;
  final Color color;
  final String tooltipMessage;
  final VoidCallback? onViewReport;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    // Tooltip wraps ONLY the icon+label cluster, not the full strip.
    // Flutter's Tooltip centers itself on its child's bounds, so a
    // wide parent (with an Expanded eating the middle) drops the
    // tooltip far from the cursor. Keeping the wrapped subtree tight
    // anchors the bubble next to the actual hover target.
    final hoverTarget = Tooltip(
      message: tooltipMessage,
      waitDuration: const Duration(milliseconds: 300),
      showDuration: const Duration(seconds: 8),
      preferBelow: false,
      verticalOffset: 14,
      child: Padding(
        // Pad inside the tooltip's hit-rect so the bubble doesn't
        // crowd the icon vertically when it pops.
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          hoverTarget,
          const Spacer(),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          if (onViewReport != null)
            TextButton(
              onPressed: onViewReport,
              child: const Text('View report'),
            ),
        ],
      ),
    );
  }
}
