import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';

/// Bridges [HostNotApprovedException] from the service layer to a
/// user-visible "Allow this host?" dialog. Wizard screens call
/// [HostApprovalGate.runGuarded] around any code that might trigger
/// an outbound network call; the helper catches the typed exception,
/// shows the prompt, persists the decision via
/// [SecurityService.approveHost], and re-runs the action. Some flows
/// legitimately contact more than one host (GitHub API plus a release
/// asset host), so the gate can prompt for multiple distinct hosts
/// during the same action.
///
/// Refusal ("Cancel") is sticky for the lifetime of the call: the
/// retry doesn't fire, and the original [HostNotApprovedException]
/// propagates so the calling screen can render its own error UX.
class HostApprovalGate {
  HostApprovalGate._();

  /// Ensure every host in [candidates] is already approved, or prompt
  /// once with the missing hosts. Returns false when the user cancels.
  static Future<bool> ensureHostsApproved(
    WidgetRef ref,
    BuildContext context, {
    required Iterable<String> candidates,
  }) async {
    final hosts = {
      for (final candidate in candidates) ?normalizeHostCandidate(candidate),
    }.toList()..sort();
    if (hosts.isEmpty) return true;

    final security = ref.read(securityServiceProvider);
    final current = await security.requestHostApprovals(hosts);
    final pending = [
      for (final host in hosts)
        if (current[host] != true) host,
    ];
    if (pending.isEmpty) return true;
    if (!context.mounted) return false;

    final approved = await _promptApproval(
      context,
      pending,
      profileBatch: true,
    );
    if (!approved) return false;
    for (final host in pending) {
      await security.approveHost(host);
    }
    return true;
  }

  /// Run [action]. If it throws [HostNotApprovedException], prompt the
  /// user via [BuildContext]; on approval, persist + retry. A repeated
  /// denial for the same host is rethrown so the caller can surface a
  /// real failure instead of looping forever.
  static Future<T> runGuarded<T>(
    WidgetRef ref,
    BuildContext context, {
    required Future<T> Function() action,
  }) async {
    final promptedHosts = <String>{};
    while (true) {
      try {
        return await action();
      } on HostNotApprovedException catch (e) {
        if (!context.mounted) rethrow;
        final host = e.host.trim().toLowerCase();
        if (host.isEmpty || !promptedHosts.add(host)) rethrow;
        final approved = await _promptApproval(context, [host]);
        if (!approved) rethrow;
        await ref.read(securityServiceProvider).approveHost(host);
      }
    }
  }

  static Future<bool> _promptApproval(
    BuildContext context,
    List<String> hosts, {
    bool profileBatch = false,
  }) async {
    final hostText = hosts.length == 1 ? '"${hosts.single}"' : 'these hosts';
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.public),
        title: Text(
          profileBatch
              ? 'Allow profile network access?'
              : 'Allow network access?',
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                profileBatch
                    ? 'This printer profile can contact $hostText for images, '
                          'source code, and release assets. You can revoke '
                          'this later from Settings.'
                    : 'Deckhand wants to contact $hostText to fetch profiles '
                          'or firmware. You can revoke this later from '
                          'Settings.',
              ),
              const SizedBox(height: 14),
              _HostApprovalList(hosts: hosts),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Allow'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

class _HostApprovalList extends StatelessWidget {
  const _HostApprovalList({required this.hosts});

  final List<String> hosts;

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(fontFamily: 'IBMPlexMono', fontSize: 12);
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final host in hosts)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Text(host, style: textStyle),
              ),
          ],
        ),
      ),
    );
  }
}
