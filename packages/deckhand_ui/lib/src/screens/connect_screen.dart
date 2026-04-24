import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

/// What we learned from probing a discovered host. Lives per-host in
/// [_ConnectScreenState] so the card rebuilds as each async probe
/// completes.
class _ProbeResult {
  const _ProbeResult({
    this.info,
    this.match,
  });
  final KlippyInfo? info;
  final PrinterMatch? match;
}

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _hostController = TextEditingController();
  String? _error;
  bool _connecting = false;

  bool _scanning = false;
  List<DiscoveredPrinter> _discovered = const [];
  final Map<String, _ProbeResult> _probed = {};

  @override
  void initState() {
    super.initState();
    _scan();
  }

  @override
  void dispose() {
    _hostController.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _discovered = const [];
    });
    final discovery = ref.read(discoveryServiceProvider);

    final cidrs = await _localCidrs();

    final futures = <Future<List<DiscoveredPrinter>>>[
      discovery.scanMdns(timeout: const Duration(seconds: 4)).catchError(
        (_) => <DiscoveredPrinter>[],
      ),
      for (final c in cidrs)
        discovery
            .scanCidr(
              cidr: c,
              port: 7125,
              timeout: const Duration(seconds: 1),
            )
            .catchError((_) => <DiscoveredPrinter>[]),
    ];

    final merged = <String, DiscoveredPrinter>{};
    _probed.clear();
    var outstanding = futures.length;
    for (final f in futures) {
      f.then((found) {
        final newlySeen = <DiscoveredPrinter>[];
        for (final p in found) {
          if (merged.putIfAbsent(p.host, () => p) == p) newlySeen.add(p);
        }
        if (!mounted) return;
        setState(() {
          _discovered = merged.values.toList();
        });
        for (final p in newlySeen) {
          _probe(p);
        }
      }).whenComplete(() {
        outstanding--;
        if (outstanding == 0 && mounted) {
          setState(() => _scanning = false);
        }
      });
    }
  }

  /// Run all identification probes for one discovered host in
  /// parallel, with an explicit deadline per call and a single retry
  /// on transient failure. Populates `_probed[host]` twice: first
  /// with whatever info came back fast, then with the full match
  /// verdict once all three signals land.
  Future<void> _probe(DiscoveredPrinter p) async {
    final moonraker = ref.read(moonrakerServiceProvider);
    final profile = ref.read(wizardControllerProvider).profile;
    final hints =
        profile?.identification ?? const ProfileIdentification();

    final probeTimeout = Duration(seconds: hints.probeTimeoutSeconds);
    Future<T?> withRetry<T>(Future<T> Function() op) async {
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          return await op().timeout(probeTimeout);
        } catch (_) {
          if (attempt == 1) return null;
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      return null;
    }

    final infoFuture = withRetry(() =>
        moonraker.info(host: p.host, port: p.port));
    final objectsFuture = hints.moonrakerObjects.isEmpty
        ? Future<List<String>>.value(const [])
        : withRetry(() =>
                moonraker.listObjects(host: p.host, port: p.port))
            .then((v) => v ?? const <String>[]);
    final markerFuture = hints.markerFile == null
        ? Future<String?>.value(null)
        : withRetry(() => moonraker.fetchConfigFile(
              host: p.host,
              port: p.port,
              filename: hints.markerFile!,
            ));

    // Surface info as soon as it lands so the card stops saying "just
    // an IP" while the slower probes run.
    final info = await infoFuture;
    if (!mounted) return;
    setState(() {
      _probed[p.host] = _ProbeResult(info: info);
    });

    final objects = await objectsFuture;
    final marker = await markerFuture;
    if (!mounted) return;

    final match = PrinterMatch.score(
      hints: hints,
      markerFileContent: marker,
      hostname: info?.hostname,
      registeredObjects: objects,
      profileId: profile?.id ?? '',
    );
    setState(() {
      _probed[p.host] = _ProbeResult(info: info, match: match);
    });
  }

  Future<List<String>> _localCidrs() async {
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final cidrs = <String>{};
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          cidrs.add('${parts[0]}.${parts[1]}.${parts[2]}.0/24');
        }
      }
      return cidrs.toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _connect(String host, {bool acceptHostKey = false}) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await ref.read(wizardControllerProvider).connectSsh(
            host: host,
            acceptHostKey: acceptHostKey,
          );
      if (mounted) context.go('/verify');
    } on HostKeyUnpinnedException catch (e) {
      // First-time connect to this host. Show the fingerprint and ask
      // the user to confirm before we pin it and retry.
      if (!mounted) return;
      final accept = await _showHostKeyDialog(
        host: e.host,
        fingerprint: e.fingerprint,
        title: t.connect.host_key_title_new,
        body: t.connect.host_key_body_new,
        confirmLabel: t.connect.host_key_confirm_new,
      );
      if (accept == true && mounted) {
        await _connect(host, acceptHostKey: true);
        return;
      }
      if (mounted) setState(() => _error = e.userTitle);
    } on HostKeyMismatchException catch (e) {
      // Fingerprint changed since we last pinned - could be reinstall,
      // could be MITM. Do NOT auto-retry. User has to clear it
      // manually from Settings.
      if (!mounted) return;
      await _showHostKeyDialog(
        host: e.host,
        fingerprint: e.fingerprint,
        title: t.connect.host_key_title_mismatch,
        body: t.connect.host_key_body_mismatch,
        confirmLabel: null,
      );
      if (mounted) setState(() => _error = e.userTitle);
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<bool?> _showHostKeyDialog({
    required String host,
    required String fingerprint,
    required String title,
    required String body,
    required String? confirmLabel,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            const SizedBox(height: 12),
            SelectableText(
              '$host\n$fingerprint',
              style: const TextStyle(fontFamily: 'monospace'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.action_cancel),
          ),
          if (confirmLabel != null)
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(confirmLabel),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manualHost = _hostController.text.trim();
    final profile = ref.watch(wizardControllerProvider).profile;
    final hasHints = profile?.identification != null &&
        (profile!.identification.moonrakerObjects.isNotEmpty ||
            profile.identification.markerFile != null ||
            profile.identification.hostnamePatterns.isNotEmpty);

    // Sort by confidence bucket so confirmed matches surface first.
    final sorted = [..._discovered];
    if (hasHints) {
      sorted.sort((a, b) {
        final ca =
            _probed[a.host]?.match?.confidence.index ?? _unknownIndex;
        final cb =
            _probed[b.host]?.match?.confidence.index ?? _unknownIndex;
        return ca.compareTo(cb);
      });
    }

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: t.connect.title,
      helperText: t.connect.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                t.connect.section_discovered,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(width: 12),
              if (_scanning)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              const Spacer(),
              TextButton.icon(
                icon: const Icon(Icons.refresh),
                label: Text(t.connect.action_rescan),
                onPressed: _scanning || _connecting ? null : _scan,
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!_scanning && _discovered.isEmpty)
            Text(
              t.connect.empty_state,
              style: theme.textTheme.bodySmall,
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in sorted)
                  _DiscoveredCard(
                    printer: p,
                    probe: _probed[p.host],
                    profileName: profile?.displayName,
                    showMatchBadge: hasHints,
                    onTap: _connecting ? null : () => _connect(p.host),
                  ),
              ],
            ),

          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 16),

          Text(t.connect.section_manual, style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _hostController,
            decoration: InputDecoration(
              labelText: t.connect.field_host,
              hintText: t.connect.hint_host,
              border: const OutlineInputBorder(),
            ),
            enabled: !_connecting,
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) {
              final h = v.trim();
              if (h.isNotEmpty) _connect(h);
            },
          ),
          const SizedBox(height: 12),
          if (_connecting) const LinearProgressIndicator(),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(
              _error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
      primaryAction: WizardAction(
        label: _connecting
            ? t.connect.action_connecting
            : t.connect.action_connect,
        onPressed: _connecting || manualHost.isEmpty
            ? null
            : () => _connect(manualHost),
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/pick-printer'),
        ),
      ],
    );
  }

  /// Sort index assigned to cards with no probe result yet: slots them
  /// between "probable" and "miss" so we don't ping-pong cards around
  /// as probes finish.
  static final _unknownIndex = PrinterMatchConfidence.unknown.index;
}

class _DiscoveredCard extends StatelessWidget {
  const _DiscoveredCard({
    required this.printer,
    required this.onTap,
    required this.profileName,
    required this.showMatchBadge,
    this.probe,
  });
  final DiscoveredPrinter printer;
  final _ProbeResult? probe;
  final String? profileName;
  final bool showMatchBadge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enriched = probe?.info;

    final title =
        (enriched != null && enriched.hostname.trim().isNotEmpty)
        ? enriched.hostname
        : (printer.hostname.isNotEmpty && printer.hostname != printer.host
              ? printer.hostname
              : printer.host);

    final String detail;
    if (enriched != null) {
      final version = enriched.softwareVersion.trim();
      detail = version.isEmpty
          ? '${printer.host}:${printer.port} * Moonraker'
          : '${printer.host} * $version';
    } else {
      detail = '${printer.host}:${printer.port} * ${printer.service}';
    }

    final stateChip = enriched == null
        ? null
        : _StateChip(state: enriched.klippyState);

    final matchBadge = showMatchBadge
        ? _MatchBadge(match: probe?.match, profileName: profileName)
        : null;

    // Tint the card for confirmed matches so the user's eye finds
    // them without reading every row. Probable matches stay neutral
    // so the user doesn't over-trust a hostname-only signal.
    final Color? cardColor = probe?.match?.confidence ==
            PrinterMatchConfidence.confirmed
        ? theme.colorScheme.primaryContainer.withValues(alpha: 0.5)
        : null;

    // Compose a screen-reader summary so AT users hear the match
    // verdict without parsing chips visually.
    final semanticsLabel = [
      title,
      detail,
      if (enriched != null) 'state ${enriched.klippyState}',
      if (probe?.match != null)
        _semanticsForMatch(probe!.match!, profileName ?? 'profile'),
    ].join('. ');

    return SizedBox(
      width: 320,
      child: Semantics(
        container: true,
        button: onTap != null,
        label: semanticsLabel,
        child: Card(
          color: cardColor,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.print, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title,
                          style: theme.textTheme.titleMedium,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (stateChip != null) stateChip,
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (matchBadge != null) ...[
                    const SizedBox(height: 8),
                    matchBadge,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _semanticsForMatch(PrinterMatch m, String profileName) {
    final reason = m.reason == null ? '' : ' because ${m.reason}';
    switch (m.confidence) {
      case PrinterMatchConfidence.confirmed:
        return t.connect.semantics_confirmed(
          profile: profileName,
          reason: reason,
        );
      case PrinterMatchConfidence.probable:
        return t.connect.semantics_probable(
          profile: profileName,
          reason: reason,
        );
      case PrinterMatchConfidence.miss:
        return t.connect.semantics_miss(profile: profileName);
      case PrinterMatchConfidence.unknown:
        return t.connect.semantics_unknown;
    }
  }
}

class _MatchBadge extends StatelessWidget {
  const _MatchBadge({required this.match, required this.profileName});
  final PrinterMatch? match;
  final String? profileName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = match;
    final name = profileName ?? 'your printer';

    final (IconData icon, String label, Color color, String? tooltip) =
        switch (m?.confidence) {
      PrinterMatchConfidence.confirmed => (
        Icons.check_circle,
        t.connect.match_confirmed(profile: name),
        theme.colorScheme.primary,
        m?.reason,
      ),
      PrinterMatchConfidence.probable => (
        Icons.help_outline,
        t.connect.match_probable(profile: name),
        theme.colorScheme.secondary,
        m?.reason,
      ),
      PrinterMatchConfidence.miss => (
        Icons.cancel_outlined,
        t.connect.match_miss(profile: name),
        theme.colorScheme.outline,
        null,
      ),
      _ => (
        Icons.hourglass_empty,
        t.connect.match_checking,
        theme.colorScheme.outline,
        null,
      ),
    };

    final row = Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(color: color),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    if (tooltip == null) return row;
    return Tooltip(message: tooltip, child: row);
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.state});
  final String state;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final normalized = state.toLowerCase();
    final color = switch (normalized) {
      'ready' || 'printing' => theme.colorScheme.tertiary,
      'startup' || 'shutdown' => theme.colorScheme.secondary,
      'error' || 'disconnected' => theme.colorScheme.error,
      _ => theme.colorScheme.outline,
    };
    return Semantics(
      label: 'Klipper state $normalized',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          normalized,
          style: theme.textTheme.labelSmall?.copyWith(
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
