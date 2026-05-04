import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Live "what just got fetched" panel for S900-progress. Subscribes
/// to [SecurityService.egressEvents] and renders one row per request,
/// updating in place as completion events arrive. See
/// [docs/ARCHITECTURE.md] (egress visualization) for the design.
class NetworkPanel extends ConsumerStatefulWidget {
  const NetworkPanel({super.key});

  @override
  ConsumerState<NetworkPanel> createState() => _NetworkPanelState();
}

class _NetworkPanelState extends ConsumerState<NetworkPanel> {
  /// Event-by-id store. Completion events overwrite the start event
  /// so the row updates in place rather than appearing twice.
  final _events = <String, EgressEvent>{};

  @override
  void initState() {
    super.initState();
    final security = ref.read(securityServiceProvider);
    security.egressEvents.listen((e) {
      if (!mounted) return;
      setState(() => _events[e.requestId] = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_events.isEmpty) {
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
    final events = _events.values.toList()
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return ListView.separated(
      itemCount: events.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => _EgressTile(event: events[i]),
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
        : (inflight
            ? theme.colorScheme.primary
            : theme.colorScheme.onSurface);
    return ExpansionTile(
      leading: inflight
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
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
