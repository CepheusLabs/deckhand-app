import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../screens/debug_bundle_screen.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/user_facing_errors.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/save_debug_bundle.dart';
import '../widgets/status_pill.dart';
import '../widgets/wizard_scaffold.dart';

/// What we learned from probing a discovered host. Lives per-host in
/// [_ConnectScreenState] so the card rebuilds as each async probe
/// completes.
class _ProbeResult {
  const _ProbeResult({this.info, this.match});
  final KlippyInfo? info;
  final PrinterMatch? match;
}

class ConnectScreen extends ConsumerStatefulWidget {
  const ConnectScreen({super.key});

  @override
  ConsumerState<ConnectScreen> createState() => _ConnectScreenState();
}

enum _ConnectTab { discover, manual, saved }

class _ConnectScreenState extends ConsumerState<ConnectScreen> {
  final _hostController = TextEditingController();
  String? _error;
  bool _connecting = false;
  // Host the user is currently connecting to. Drives the
  // "focused-on-one-card" state during the SSH handshake — every
  // other card and the manual-input box hide so the user sees only
  // the printer they picked.
  String? _connectingHost;

  bool _scanning = false;
  List<DiscoveredPrinter> _discovered = const [];
  final Map<String, _ProbeResult> _probed = {};

  // Active tab in the design's 3-up tab strip across the top of the
  // body (Auto-discover / Manual host / Saved). Default to Saved
  // when there are entries — repeat users mostly want to reconnect
  // to a known printer, not re-scan; first-launch falls through to
  // Auto-discover because the saved list is empty.
  _ConnectTab _tab = _ConnectTab.discover;

  @override
  void initState() {
    super.initState();
    _scan();
    // Default-tab seeding runs once after first frame so we have
    // access to ref.read. A user with saved hosts gets dropped onto
    // Saved by default; otherwise Auto-discover (the existing
    // first-launch behaviour) is preserved.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final saved = ref.read(deckhandSettingsProvider).savedHosts;
      if (saved.isNotEmpty) {
        setState(() => _tab = _ConnectTab.saved);
      }
    });
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
      discovery
          .scanMdns(timeout: const Duration(seconds: 4))
          .catchError((_) => <DiscoveredPrinter>[]),
      for (final c in cidrs)
        discovery
            .scanCidr(cidr: c, port: 7125, timeout: const Duration(seconds: 1))
            .catchError((_) => <DiscoveredPrinter>[]),
    ];

    final merged = <String, DiscoveredPrinter>{};
    _probed.clear();
    var outstanding = futures.length;
    for (final f in futures) {
      f
          .then((found) {
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
          })
          .whenComplete(() {
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
    final hints = profile?.identification ?? const ProfileIdentification();

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

    final infoFuture = withRetry(
      () => moonraker.info(host: p.host, port: p.port),
    );
    final objectsFuture = hints.moonrakerObjects.isEmpty
        ? Future<List<String>>.value(const [])
        : withRetry(
            () => moonraker.listObjects(host: p.host, port: p.port),
          ).then((v) => v ?? const <String>[]);
    final markerFuture = hints.markerFile == null
        ? Future<String?>.value(null)
        : withRetry(
            () => moonraker.fetchConfigFile(
              host: p.host,
              port: p.port,
              filename: hints.markerFile!,
            ),
          );

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

  Future<void> _connect(
    String host, {
    int? port,
    String? preferredUser,
    bool acceptHostKey = false,
    String? acceptedHostFingerprint,
  }) async {
    setState(() {
      _connecting = true;
      _connectingHost = host;
      _error = null;
    });
    try {
      final controller = ref.read(wizardControllerProvider);
      final savedCredential = preferredUser == null
          ? null
          : _defaultCredentialForUser(controller.profile, preferredUser);
      if (savedCredential == null) {
        await controller.connectSsh(
          host: host,
          port: port,
          acceptHostKey: acceptHostKey,
          acceptedHostFingerprint: acceptedHostFingerprint,
        );
      } else {
        await controller.connectSshWithPassword(
          host: host,
          port: port,
          user: savedCredential.user,
          password: savedCredential.password!,
          acceptHostKey: acceptHostKey,
          acceptedHostFingerprint: acceptedHostFingerprint,
        );
      }
      // Persist to the Saved tab so a relaunch surfaces this host
      // one click away. session.user is what actually authenticated
      // (default-credential fallback may have used a non-stock user)
      // so that's what we store, not anything the UI assumed.
      try {
        final session = controller.sshSession;
        if (session != null) {
          final settings = ref.read(deckhandSettingsProvider);
          final registry = ref.read(managedPrinterRegistryProvider);
          final profile = controller.profile;
          final user = session.user.trim().isNotEmpty
              ? session.user.trim()
              : (preferredUser ?? '').trim();
          final seenAt = DateTime.now();
          settings.recordSavedHost(
            SavedHost(
              host: host,
              port: session.port,
              user: user,
              lastUsed: seenAt,
            ),
          );
          if (profile != null) {
            registry.recordManagedPrinter(
              ManagedPrinter.fromConnection(
                profileId: profile.id,
                displayName: profile.displayName,
                host: host,
                port: session.port,
                user: user,
                lastSeen: seenAt,
              ),
            );
          }
          await _persistConnectedPrinterState(
            settings: settings,
            registry: registry,
          );
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _error =
              'Connected, but Deckhand could not save this printer. '
              '${userFacingError(e)}';
        });
        return;
      }
      if (mounted) {
        final state = controller.state;
        final firstBootHandoff =
            state.flow == WizardFlow.freshFlash &&
            state.currentStep == 'first-boot';
        if (firstBootHandoff) {
          await controller.setDecision(firstBootReadyForSshWaitDecision, true);
          if (!mounted) return;
        }
        final nextRoute = firstBootHandoff ? '/first-boot-setup' : '/verify';
        context.go(nextRoute);
      }
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
        await _connect(
          host,
          port: port,
          preferredUser: preferredUser,
          acceptHostKey: true,
          acceptedHostFingerprint: e.fingerprint,
        );
        return;
      }
      if (mounted) setState(() => _error = e.userTitle);
    } on HostKeyMismatchException catch (e) {
      // Fingerprint changed since we last pinned - could be reinstall,
      // could be MITM. Surface a rich danger card with EXPECTED vs
      // RECEIVED so the user can compare hashes, save a debug bundle
      // for later forensics, or explicitly clear the pin and retry.
      if (!mounted) return;
      final security = ref.read(securityServiceProvider);
      String? expected;
      try {
        expected = await security.pinnedHostFingerprint(e.host);
      } catch (_) {
        // Pinned-store read failure is non-fatal — render the dialog
        // with EXPECTED as "(not available)" rather than crashing.
        expected = null;
      }
      if (!mounted) return;
      final retry = await _showMitmDialog(
        host: e.host,
        expectedFingerprint: expected,
        receivedFingerprint: e.fingerprint,
      );
      if (retry == true && mounted) {
        try {
          await security.forgetHostFingerprint(e.host);
        } catch (clearError) {
          if (mounted) {
            setState(
              () => _error =
                  'Could not clear stored fingerprint: '
                  '${userFacingError(clearError)}',
            );
          }
          return;
        }
        if (mounted) {
          await _connect(host, port: port, preferredUser: preferredUser);
        }
        return;
      }
      if (mounted) setState(() => _error = e.userTitle);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = userFacingError(e));
    } finally {
      if (mounted) {
        setState(() {
          _connecting = false;
          _connectingHost = null;
        });
      }
    }
  }

  Future<void> _persistConnectedPrinterState({
    required DeckhandSettings settings,
    required ManagedPrinterRegistry registry,
  }) async {
    if (registry is SettingsManagedPrinterRegistry &&
        identical(registry.settings, settings)) {
      await settings.save();
      return;
    }
    await Future.wait([settings.save(), registry.save()]);
  }

  Future<void> _forgetSavedHost(SavedHost h) async {
    final settings = ref.read(deckhandSettingsProvider);
    final previous = settings.savedHosts;
    settings.forgetSavedHost(host: h.host, user: h.user);
    try {
      await settings.save();
      if (!mounted) return;
      setState(() => _error = null);
    } catch (e) {
      settings.savedHosts = previous;
      if (!mounted) return;
      setState(
        () => _error = 'Could not forget saved host: ${userFacingError(e)}',
      );
    }
  }

  SshDefaultCredential? _defaultCredentialForUser(
    PrinterProfile? profile,
    String user,
  ) {
    if (profile == null) return null;
    for (final credential in profile.ssh.defaultCredentials) {
      if (credential.user == user && credential.password != null) {
        return credential;
      }
    }
    return null;
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
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(body),
              const SizedBox(height: 16),
              _HostKeyField(label: 'Host', value: host, mono: true),
              const SizedBox(height: 8),
              _FingerprintField(fingerprint: fingerprint),
            ],
          ),
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

  /// Rich danger-card for the MITM case (S20 host-key mismatch from
  /// the design language). Shows EXPECTED vs RECEIVED side-by-side so
  /// the user can compare hashes character-by-character — a generic
  /// "fingerprint changed" dialog hides the most useful piece of
  /// information for this decision.
  ///
  /// Returns `true` when the user clicks "Clear stored fingerprint &
  /// retry" (destructive); `false` / `null` on cancel. The caller
  /// owns the actual `forgetHostFingerprint` + reconnect — the
  /// dialog just collects the verdict.
  Future<bool?> _showMitmDialog({
    required String host,
    required String? expectedFingerprint,
    required String receivedFingerprint,
  }) {
    final tokens = DeckhandTokens.of(context);
    return showDialog<bool>(
      context: context,
      // Modal — closing by tapping outside would let a user dismiss
      // the warning by accident. The user must click Back, Save
      // bundle, or Clear & retry.
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        contentPadding: EdgeInsets.zero,
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: _MitmDangerCard(
            tokens: tokens,
            host: host,
            expectedFingerprint: expectedFingerprint,
            receivedFingerprint: receivedFingerprint,
            onBack: () => Navigator.of(ctx).pop(false),
            onSaveDebugBundle: () => _openMitmDebugBundleReview(
              host: host,
              expectedFingerprint: expectedFingerprint,
              receivedFingerprint: receivedFingerprint,
            ),
            onClearAndRetry: () => Navigator.of(ctx).pop(true),
          ),
        ),
      ),
    );
  }

  Future<void> _openMitmDebugBundleReview({
    required String host,
    required String? expectedFingerprint,
    required String receivedFingerprint,
  }) {
    final sessionLog = _mitmDebugLog(
      host: host,
      expectedFingerprint: expectedFingerprint,
      receivedFingerprint: receivedFingerprint,
    );
    final rootNavigator = Navigator.of(context, rootNavigator: true);
    return rootNavigator.push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (reviewContext) => DebugBundleScreen(
          sessionLog: sessionLog,
          onCancel: () => Navigator.of(reviewContext).pop(),
          onSave: (redactedLog) {
            unawaited(() async {
              final result = await saveDebugBundle(
                context: reviewContext,
                ref: ref,
                redactedLog: redactedLog,
                host: _hostInfoSnapshot(),
                extraTextFiles: {'host_key_mismatch.txt': sessionLog},
              );
              if (result != null && reviewContext.mounted) {
                Navigator.of(reviewContext).pop();
              }
            }());
          },
        ),
      ),
    );
  }

  String _mitmDebugLog({
    required String host,
    required String? expectedFingerprint,
    required String receivedFingerprint,
  }) => [
    'Host key mismatch',
    'Host: $host',
    'Expected fingerprint: ${expectedFingerprint ?? '(not available)'}',
    'Received fingerprint: $receivedFingerprint',
  ].join('\n');

  HostInfoSnapshot _hostInfoSnapshot() => HostInfoSnapshot(
    os: '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    arch: ffi.Abi.current().toString(),
    deckhandVersion: ref.read(deckhandVersionProvider),
    dartVersion: Platform.version.split(' ').first,
  );

  @override
  Widget build(BuildContext context) {
    final manualHost = _hostController.text.trim();
    final profile = ref.watch(wizardControllerProvider).profile;
    final hasHints =
        profile?.identification != null &&
        (profile!.identification.moonrakerObjects.isNotEmpty ||
            profile.identification.markerFile != null ||
            profile.identification.hostnamePatterns.isNotEmpty);

    // Sort by confidence bucket so confirmed matches surface first.
    final sorted = [..._discovered];
    if (hasHints) {
      sorted.sort((a, b) {
        final ca = _probed[a.host]?.match?.confidence.index ?? _unknownIndex;
        final cb = _probed[b.host]?.match?.confidence.index ?? _unknownIndex;
        return ca.compareTo(cb);
      });
    }

    // While a connect is in flight, the body collapses down to a
    // single "Connecting to <host>" card so the user's attention
    // stays on the printer they picked instead of the noise of all
    // the other discovered hosts. Discovery, rescan, manual entry,
    // and the section dividers are hidden until the connect
    // resolves (success → /verify, or error → re-render with the
    // grid restored).
    final focused = _connecting && _connectingHost != null;
    final focusedPrinter = focused
        ? _discovered.firstWhere(
            (p) => p.host == _connectingHost,
            // Manual-IP path has no DiscoveredPrinter; synthesize a
            // minimal stand-in so the card still renders.
            orElse: () => DiscoveredPrinter(
              host: _connectingHost!,
              port: 7125,
              hostname: '',
              service: 'manual',
            ),
          )
        : null;
    final showManualFooterAction = focused || _tab == _ConnectTab.manual;

    return WizardScaffold(
      screenId: 'S20-connect',
      title: t.connect.title,
      helperText: t.connect.helper,
      body: focused
          ? _ConnectingFocus(
              printer: focusedPrinter!,
              probe: _probed[focusedPrinter.host],
              profileName: profile?.displayName,
              showMatchBadge: hasHints,
            )
          : _TabbedBody(
              activeTab: _tab,
              onTabChanged: (t) => setState(() => _tab = t),
              savedHostCount: ref
                  .watch(deckhandSettingsProvider)
                  .savedHosts
                  .length,
              scanning: _scanning,
              onRescan: _scanning ? null : _scan,
              discoverChild: _DiscoverTabBody(
                scanning: _scanning,
                discovered: sorted,
                probed: _probed,
                profileName: profile?.displayName,
                hasHints: hasHints,
                error: _error,
                onConnect: _connect,
              ),
              manualChild: _ManualTabBody(
                controller: _hostController,
                error: _error,
                onChanged: () => setState(() {}),
                onSubmit: (h) {
                  if (h.isNotEmpty) _connect(h);
                },
              ),
              savedChild: _SavedTabBody(
                hosts: ref.watch(deckhandSettingsProvider).savedHosts,
                error: _error,
                onConnect: (h) =>
                    _connect(h.host, port: h.port, preferredUser: h.user),
                onForget: (h) => unawaited(_forgetSavedHost(h)),
              ),
            ),
      primaryAction: showManualFooterAction
          ? WizardAction(
              label: _connecting
                  ? t.connect.action_connecting
                  : t.connect.action_connect,
              onPressed: _connecting || manualHost.isEmpty
                  ? null
                  : () => _connect(manualHost),
            )
          : null,
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/choose-path'),
          isBack: true,
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

    final title = (enriched != null && enriched.hostname.trim().isNotEmpty)
        ? enriched.hostname
        : (printer.hostname.isNotEmpty && printer.hostname != printer.host
              ? printer.hostname
              : printer.host);

    final String detail;
    if (enriched != null) {
      final version = enriched.softwareVersion.trim();
      detail = version.isEmpty
          // Previously rendered `"Moonraker"` as a user-facing label.
          // That's a developer term, so default to a plain status
          // instead; the full version shows up once the enrichment
          // probe lands.
          ? '${printer.host}:${printer.port} * ${t.connect.card_printer_found}'
          : '${printer.host} * $version';
    } else {
      detail =
          '${printer.host}:${printer.port} * ${t.connect.card_printer_found}';
    }

    final stateChip = enriched == null
        ? null
        : StatusPill.fromKlippyState(context, enriched.klippyState);

    final matchBadge = showMatchBadge
        ? _MatchBadge(match: probe?.match, profileName: profileName)
        : null;

    // Tint the card for confirmed matches so the user's eye finds
    // them without reading every row. Probable matches stay neutral
    // so the user doesn't over-trust a hostname-only signal.
    final Color? cardColor =
        probe?.match?.confidence == PrinterMatchConfidence.confirmed
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
                      ?stateChip,
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

    final (
      IconData icon,
      String label,
      Color color,
      String? tooltip,
    ) = switch (m?.confidence) {
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

// _StateChip removed; callers use StatusPill.fromKlippyState.

/// Focus body shown while an SSH handshake is in flight. Hides the
/// rest of the discovery grid so the user's attention stays on the
/// printer they picked. Renders the picked card centered with a
/// caption + linear progress underneath.
class _ConnectingFocus extends StatelessWidget {
  const _ConnectingFocus({
    required this.printer,
    required this.profileName,
    required this.showMatchBadge,
    this.probe,
  });

  final DiscoveredPrinter printer;
  final _ProbeResult? probe;
  final String? profileName;
  final bool showMatchBadge;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final host = printer.hostname.isNotEmpty && printer.hostname != printer.host
        ? '${printer.hostname} (${printer.host})'
        : printer.host;
    // Centered, vertically padded focus state — the connecting view
    // is intentionally minimal so the user's eyes lock on the card
    // they picked. Tap on the card is null because clicking it
    // again mid-connect would re-enter `_connect` and reset the
    // spinner.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Halo: a 96px ring with the spinner inside, framing the
              // card below. Larger than the inline LinearProgress and
              // visually anchors the screen.
              Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: tokens.accent, width: 2),
                ),
                alignment: Alignment.center,
                child: const DeckhandSpinner(size: 48, strokeWidth: 2),
              ),
              const SizedBox(height: 22),
              Text(
                'Connecting',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tXl,
                  fontWeight: FontWeight.w500,
                  color: tokens.text,
                  letterSpacing: -0.01 * DeckhandTokens.tXl,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'SSH handshake with $host. We\'ll move on to '
                'verification as soon as the printer responds.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text3,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 22),
              _DiscoveredCard(
                printer: printer,
                probe: probe,
                profileName: profileName,
                showMatchBadge: showMatchBadge,
                onTap: null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Labeled "field" row used inside the host-key dialog. Renders the
/// label as a small mono uppercase tag above a bordered value box,
/// matching the design language's labeled-data treatment. Selectable
/// so users can copy the value into another verification tool.
class _HostKeyField extends StatelessWidget {
  const _HostKeyField({
    required this.label,
    required this.value,
    this.mono = true,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 10,
            color: tokens.text4,
            letterSpacing: 0.12 * 10,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: tokens.ink2,
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          ),
          child: SelectableText(
            value,
            style: TextStyle(
              fontFamily: mono
                  ? DeckhandTokens.fontMono
                  : DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}

/// Specialized fingerprint field — splits the raw `algo TYPE:digest`
/// string into its three parts and renders the algorithm and digest
/// type as distinct chips, then breaks the colon-delimited hex bytes
/// (or base64 digest) onto its own readable line. Falls back to a
/// flat mono render when the format is something we don't recognize.
class _FingerprintField extends StatelessWidget {
  const _FingerprintField({required this.fingerprint});

  final String fingerprint;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final parsed = _parse(fingerprint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'FINGERPRINT',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 10,
            color: tokens.text4,
            letterSpacing: 0.12 * 10,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: tokens.ink2,
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          ),
          child: parsed == null
              ? SelectableText(
                  fingerprint,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tMd,
                    color: tokens.text,
                    height: 1.4,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _Chip(label: parsed.algorithm, tokens: tokens),
                        const SizedBox(width: 6),
                        _Chip(label: parsed.digestType, tokens: tokens),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      parsed.digest,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tMd,
                        color: tokens.text,
                        height: 1.5,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// Parses `ssh-ed25519 MD5:e0:36:…` or `ssh-rsa SHA256:abc…` shapes.
  /// Returns null when the input doesn't match — callers should fall
  /// back to a flat render rather than displaying garbage.
  static _ParsedFingerprint? _parse(String raw) {
    final spaceIdx = raw.indexOf(' ');
    if (spaceIdx <= 0 || spaceIdx >= raw.length - 1) return null;
    final algorithm = raw.substring(0, spaceIdx).trim();
    final remainder = raw.substring(spaceIdx + 1).trim();
    final colonIdx = remainder.indexOf(':');
    if (colonIdx <= 0 || colonIdx >= remainder.length - 1) return null;
    final digestType = remainder.substring(0, colonIdx);
    final digest = remainder.substring(colonIdx + 1);
    return _ParsedFingerprint(
      algorithm: algorithm,
      digestType: digestType,
      digest: digest,
    );
  }
}

class _ParsedFingerprint {
  const _ParsedFingerprint({
    required this.algorithm,
    required this.digestType,
    required this.digest,
  });
  final String algorithm;
  final String digestType;
  final String digest;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.tokens});
  final String label;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: tokens.ink3,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r1),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontFamily: DeckhandTokens.fontMono,
          fontSize: 10,
          color: tokens.text2,
          letterSpacing: 0.06 * 10,
        ),
      ),
    );
  }
}

/// 3-tab body shell for the Connect screen — Auto-discover · Manual
/// host · Saved (N). Mirrors the tabs across the top of the design's
/// S20 layout. The tab strip itself is just buttons styled with an
/// accent underline on the active one; no Material TabController so
/// the parent state owns `_tab` and switching doesn't interrupt
/// in-flight scans.
class _TabbedBody extends StatelessWidget {
  const _TabbedBody({
    required this.activeTab,
    required this.onTabChanged,
    required this.savedHostCount,
    required this.scanning,
    required this.onRescan,
    required this.discoverChild,
    required this.manualChild,
    required this.savedChild,
  });

  final _ConnectTab activeTab;
  final ValueChanged<_ConnectTab> onTabChanged;
  final int savedHostCount;
  final bool scanning;
  final VoidCallback? onRescan;
  final Widget discoverChild;
  final Widget manualChild;
  final Widget savedChild;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tokens.line)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final tabs = <Widget>[
                _TabButton(
                  label: 'Auto-discover',
                  icon: Icons.wifi,
                  active: activeTab == _ConnectTab.discover,
                  onTap: () => onTabChanged(_ConnectTab.discover),
                ),
                _TabButton(
                  label: 'Manual host',
                  icon: Icons.dns_outlined,
                  active: activeTab == _ConnectTab.manual,
                  onTap: () => onTabChanged(_ConnectTab.manual),
                ),
                _TabButton(
                  label: savedHostCount > 0
                      ? 'Saved ($savedHostCount)'
                      : 'Saved',
                  icon: Icons.book_outlined,
                  active: activeTab == _ConnectTab.saved,
                  onTap: () => onTabChanged(_ConnectTab.saved),
                ),
              ];
              final refresh = activeTab == _ConnectTab.discover
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (scanning)
                            const Padding(
                              padding: EdgeInsets.only(right: 8),
                              child: DeckhandSpinner(strokeWidth: 1.5),
                            ),
                          TextButton.icon(
                            icon: const Icon(Icons.refresh, size: 14),
                            label: const Text('Refresh'),
                            onPressed: onRescan,
                          ),
                        ],
                      ),
                    )
                  : null;
              if (constraints.maxWidth < 620) {
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: [...tabs, if (refresh != null) refresh]),
                );
              }
              return Row(
                children: [
                  ...tabs,
                  const Spacer(),
                  if (refresh != null) refresh,
                ],
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        switch (activeTab) {
          _ConnectTab.discover => discoverChild,
          _ConnectTab.manual => manualChild,
          _ConnectTab.saved => savedChild,
        },
      ],
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? tokens.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? tokens.text : tokens.text3),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: active ? tokens.text : tokens.text3,
                fontWeight: active ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Existing discover-list body, factored out so the tab switch can
/// swap it in/out cleanly without touching the original layout. The
/// section-header row above the cards is gone — the tab strip
/// already labels what we're looking at.
class _DiscoverTabBody extends StatelessWidget {
  const _DiscoverTabBody({
    required this.scanning,
    required this.discovered,
    required this.probed,
    required this.profileName,
    required this.hasHints,
    required this.error,
    required this.onConnect,
  });

  final bool scanning;
  final List<DiscoveredPrinter> discovered;
  final Map<String, _ProbeResult> probed;
  final String? profileName;
  final bool hasHints;
  final String? error;
  final void Function(String host) onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (!scanning && discovered.isEmpty)
          Text(t.connect.empty_state, style: theme.textTheme.bodySmall)
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final p in discovered)
                _DiscoveredCard(
                  printer: p,
                  probe: probed[p.host],
                  profileName: profileName,
                  showMatchBadge: hasHints,
                  onTap: () => onConnect(p.host),
                ),
            ],
          ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

/// Manual host-entry tab. Single TextField; primary action at the
/// bottom of the wizard scaffold drives the connect.
class _ManualTabBody extends StatelessWidget {
  const _ManualTabBody({
    required this.controller,
    required this.error,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final String? error;
  final VoidCallback onChanged;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: t.connect.field_host,
            hintText: t.connect.hint_host,
            border: const OutlineInputBorder(),
          ),
          onChanged: (_) => onChanged(),
          onSubmitted: (v) => onSubmit(v.trim()),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

/// Saved-hosts tab. List of recently-used (host, port, user) tuples
/// the user can one-click reconnect to. Each row offers Forget so a
/// stale entry can be removed without leaving the screen.
class _SavedTabBody extends StatelessWidget {
  const _SavedTabBody({
    required this.hosts,
    required this.error,
    required this.onConnect,
    required this.onForget,
  });

  final List<SavedHost> hosts;
  final String? error;
  final ValueChanged<SavedHost> onConnect;
  final ValueChanged<SavedHost> onForget;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final theme = Theme.of(context);
    if (hosts.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'No saved hosts yet. Auto-discover or enter a host manually; '
          'Deckhand will remember the printers you successfully connect to.',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
            height: 1.5,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          decoration: BoxDecoration(
            color: tokens.ink1,
            border: Border.all(color: tokens.line),
            borderRadius: BorderRadius.circular(DeckhandTokens.r3),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (var i = 0; i < hosts.length; i++)
                _SavedRow(
                  host: hosts[i],
                  isLast: i == hosts.length - 1,
                  onConnect: () => onConnect(hosts[i]),
                  onForget: () => onForget(hosts[i]),
                ),
            ],
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
  }
}

class _SavedRow extends StatelessWidget {
  const _SavedRow({
    required this.host,
    required this.isLast,
    required this.onConnect,
    required this.onForget,
  });

  final SavedHost host;
  final bool isLast;
  final VoidCallback onConnect;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return InkWell(
      onTap: onConnect,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: tokens.lineSoft)),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_outline, size: 16, color: tokens.text3),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${host.user}@${host.host}'
                    '${host.port == 22 ? "" : ":${host.port}"}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontMono,
                      fontSize: DeckhandTokens.tMd,
                      color: tokens.text,
                    ),
                  ),
                  if (host.lastUsed != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'last used ${_relativeShort(host.lastUsed!)}',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: 11,
                        color: tokens.text4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Forget this host',
              icon: const Icon(Icons.close, size: 16),
              onPressed: onForget,
            ),
          ],
        ),
      ),
    );
  }

  String _relativeShort(DateTime when) {
    final delta = DateTime.now().difference(when);
    if (delta.isNegative || delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 30) return '${delta.inDays}d ago';
    if (delta.inDays < 365) return '${delta.inDays ~/ 30}mo ago';
    return '${delta.inDays ~/ 365}y ago';
  }
}

/// Rich danger card for the host-key MITM scenario. Renders the
/// design's E-host-key-mismatch screen as a dialog body: bad-toned
/// header, EXPECTED vs RECEIVED side-by-side hash diff, three
/// distinct actions (Back / Save bundle / Clear & retry).
class _MitmDangerCard extends StatelessWidget {
  const _MitmDangerCard({
    required this.tokens,
    required this.host,
    required this.expectedFingerprint,
    required this.receivedFingerprint,
    required this.onBack,
    required this.onSaveDebugBundle,
    required this.onClearAndRetry,
  });

  final DeckhandTokens tokens;
  final String host;
  final String? expectedFingerprint;
  final String receivedFingerprint;
  final VoidCallback onBack;
  final VoidCallback onSaveDebugBundle;
  final VoidCallback onClearAndRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.bad, width: 1.5),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header pill: warning icon + mono caps tagline.
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 20, color: tokens.bad),
              const SizedBox(width: 10),
              Text(
                'HARD STOP · MITM POSSIBLE',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tXs,
                  color: tokens.bad,
                  letterSpacing: 0.1 * DeckhandTokens.tXs,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Host key mismatch.',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.t2Xl,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.015 * DeckhandTokens.t2Xl,
              color: tokens.text,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'The fingerprint $host presented does not match the one '
            'Deckhand recorded for this host. Either the printer was '
            "reflashed (in which case clearing the pin is fine) — or "
            'something is intercepting your connection.',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tSm,
              color: tokens.text3,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          // EXPECTED vs RECEIVED side-by-side. The side-by-side layout
          // is load-bearing here: stacked rows would force a saccade
          // between the two hashes and dilute the visual diff.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _FingerprintBlock(
                  tokens: tokens,
                  label: 'EXPECTED',
                  value: expectedFingerprint ?? '(not pinned in this profile)',
                  bad: false,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _FingerprintBlock(
                  tokens: tokens,
                  label: 'RECEIVED',
                  value: receivedFingerprint,
                  bad: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // Three actions: Back (cancel), Save bundle (forensics),
          // Clear & retry (destructive, primary). Order mirrors the
          // mockup: cancel-style actions left, destructive on the
          // right with a Spacer separating them.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton.icon(
                icon: const Icon(Icons.arrow_back, size: 14),
                label: const Text('Back'),
                onPressed: onBack,
              ),
              TextButton.icon(
                icon: const Icon(Icons.archive_outlined, size: 14),
                label: const Text('Save debug bundle'),
                onPressed: onSaveDebugBundle,
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.bad,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.delete_forever, size: 14),
                label: const Text('Clear stored fingerprint & retry'),
                onPressed: onClearAndRetry,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FingerprintBlock extends StatelessWidget {
  const _FingerprintBlock({
    required this.tokens,
    required this.label,
    required this.value,
    required this.bad,
  });

  final DeckhandTokens tokens;
  final String label;
  final String value;
  final bool bad;

  @override
  Widget build(BuildContext context) {
    final bg = bad ? tokens.bad.withValues(alpha: 0.08) : tokens.ink2;
    final border = bad ? tokens.bad.withValues(alpha: 0.4) : tokens.line;
    final textColor = bad ? tokens.bad : tokens.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 10,
            color: tokens.text4,
            letterSpacing: 0.1 * 10,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          ),
          child: SelectableText(
            value,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tSm,
              color: textColor,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
