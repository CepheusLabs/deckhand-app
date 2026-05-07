import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';

import 'deckhand_loading.dart';

/// Live "what just got fetched" panel for S900-progress. Subscribes
/// to [SecurityService.egressEvents] and renders one row per request,
/// updating in place as completion events arrive. See
/// [docs/ARCHITECTURE.md] (egress visualization) for the design.
class NetworkPanel extends StatelessWidget {
  const NetworkPanel({super.key, required this.events});

  final List<EgressEvent> events;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (events.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                'No host-side outbound HTTP yet.',
                style: theme.textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'This panel only shows traffic from your computer (e.g. '
                'profile fetch, OS image download, GitHub release '
                'metadata). Commands Deckhand runs on the printer over '
                'SSH — including `git clone` of Kalico/Klipper — happen '
                'from the printer\'s network, not yours, so they never '
                'land here.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    final sorted = List<EgressEvent>.of(events)
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return ListView.separated(
      itemCount: sorted.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => _EgressTile(event: sorted[i]),
    );
  }
}

class _EgressTile extends StatelessWidget {
  const _EgressTile({required this.event});

  final EgressEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inflight = !event.isComplete;
    final color = event.error != null
        ? theme.colorScheme.error
        : (inflight ? theme.colorScheme.primary : theme.colorScheme.onSurface);
    return ExpansionTile(
      leading: inflight
          ? const SizedBox(
              width: 16,
              height: 16,
              child: DeckhandSpinner(size: 16, strokeWidth: 2),
            )
          : Icon(
              event.error != null
                  ? Icons.cancel_outlined
                  : Icons.check_circle_outline,
              size: 18,
              color: color,
            ),
      title: Text(
        event.host,
        style: theme.textTheme.bodyMedium?.copyWith(color: color),
      ),
      subtitle: Text(
        '${event.method}  •  ${event.operationLabel}'
        '${event.bytes != null ? "  •  ${_humanBytes(event.bytes!)}" : ""}'
        '${event.status != null ? "  •  HTTP ${event.status}" : ""}'
        '${event.error != null ? "  •  ${event.error}" : ""}',
        style: theme.textTheme.bodySmall,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(56, 0, 16, 12),
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(
            event.url,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Started ${event.startedAt.toIso8601String()}'
            '${event.completedAt != null ? "\nCompleted ${event.completedAt!.toIso8601String()}" : ""}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB'];
  double v = bytes / 1024.0;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024.0;
    i++;
  }
  return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
}
