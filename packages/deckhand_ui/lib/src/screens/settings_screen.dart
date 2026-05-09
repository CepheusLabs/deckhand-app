import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/user_facing_errors.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/profile_text.dart';
import '../widgets/wizard_scaffold.dart';

/// Stable identifier for the active settings tab. Used as the index
/// state (no string keys threaded through the build); ordering here
/// drives both the rail order and the switch in [_buildTabBody].
enum _SettingsTab { general, connections, profiles, appearance, advanced }

/// Full Settings page. Each tab binds a real persistence target —
/// nothing here is a placeholder. Tabs (left rail):
///
///  * General — `Verify after write` toggle + cache-retention.
///  * Connections — SSH host-key fingerprints Deckhand silently
///    trusts; per-row "Forget" forces re-prompt next connect.
///  * Profiles — local override directory vs. fetching from GitHub.
///    Persists to [DeckhandSettings.localProfilesDir].
///  * Appearance — system / light / dark theme picker + UI locale.
///  * Advanced — developer mode, GitHub access token (lifts the
///    GitHub rate-limit ceiling) + approved outbound network
///    egress hosts.
///
/// The tabbed layout mirrors the design language: a 200px left
/// rail of icon+label rows, with the active tab's content rendered
/// in the right-side panel. Persistence is unchanged — only the
/// presentation has been regrouped.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  _SettingsTab _currentTab = _SettingsTab.general;

  late final TextEditingController _localDirController;
  String? _localDirError;

  late final TextEditingController _githubTokenController;
  bool _githubTokenObscured = true;
  bool _githubTokenLoaded = false;
  String? _githubTokenStatus;

  bool _verifyAfterWrite = true;
  bool _developerMode = false;
  late final TextEditingController _cacheRetentionController;
  String? _cacheRetentionError;
  bool _preflightRunning = false;
  DoctorReport? _preflightReport;
  String? _preflightError;

  Future<List<String>>? _approvedHostsFuture;
  Future<Map<String, String>>? _fingerprintsFuture;

  @override
  void initState() {
    super.initState();
    final settings = ref.read(deckhandSettingsProvider);
    _localDirController = TextEditingController(
      text: settings.localProfilesDir ?? '',
    );
    _githubTokenController = TextEditingController();
    _verifyAfterWrite = settings.verifyAfterWrite;
    _developerMode = settings.developerMode;
    _preflightReport = _decodePreflightReport(settings.lastPreflight);
    _cacheRetentionController = TextEditingController(
      text: settings.cacheRetentionDays.toString(),
    );
    _refreshHostLists();
    _hydrateGithubToken();
  }

  @override
  void dispose() {
    _localDirController.dispose();
    _githubTokenController.dispose();
    _cacheRetentionController.dispose();
    super.dispose();
  }

  Future<void> _hydrateGithubToken() async {
    try {
      final security = ref.read(securityServiceProvider);
      final existing = await security.getGitHubToken();
      if (!mounted) return;
      setState(() {
        _githubTokenLoaded = true;
        if (existing != null) {
          _githubTokenController.text = existing;
          _githubTokenStatus = 'Saved · using authenticated GitHub bucket';
        } else {
          _githubTokenStatus =
              'No token saved · using anonymous 60/hour bucket';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _githubTokenLoaded = true;
        _githubTokenStatus = 'Secure storage error: ${userFacingError(e)}';
      });
    }
  }

  void _refreshHostLists() {
    final security = ref.read(securityServiceProvider);
    setState(() {
      _approvedHostsFuture = security.listApprovedHosts();
      _fingerprintsFuture = security.listPinnedFingerprints();
    });
  }

  Future<void> _saveLocalDir() async {
    final raw = _localDirController.text.trim();
    if (raw.isNotEmpty) {
      final ok =
          await Directory(raw).exists() &&
          await File('$raw/registry.yaml').exists();
      if (!ok) {
        setState(() {
          _localDirError = t.settings.profiles_local_dir_invalid;
        });
        return;
      }
    }
    final settings = ref.read(deckhandSettingsProvider);
    final previous = settings.localProfilesDir;
    settings.localProfilesDir = raw.isEmpty ? null : raw;
    try {
      await settings.save();
      setState(() => _localDirError = null);
      _toast('Saved. Restart Deckhand for the profile source to take effect.');
    } catch (e) {
      settings.localProfilesDir = previous;
      setState(() => _localDirError = userFacingError(e));
    }
  }

  Future<void> _saveGithubToken() async {
    final raw = _githubTokenController.text.trim();
    try {
      final security = ref.read(securityServiceProvider);
      await security.setGitHubToken(raw.isEmpty ? null : raw);
      setState(() {
        _githubTokenStatus = raw.isEmpty
            ? 'Cleared · using anonymous 60/hour bucket'
            : 'Saved · using authenticated GitHub bucket';
      });
      _toast(
        raw.isEmpty
            ? 'GitHub token cleared.'
            : 'GitHub token saved to secure storage.',
      );
    } catch (e) {
      setState(
        () =>
            _githubTokenStatus = 'Secure storage error: ${userFacingError(e)}',
      );
    }
  }

  Future<void> _setDeveloperMode(bool value) async {
    final previous = _developerMode;
    setState(() => _developerMode = value);
    final settings = ref.read(deckhandSettingsProvider);
    settings.developerMode = value;
    try {
      await settings.save();
    } catch (e) {
      settings.developerMode = previous;
      if (mounted) {
        setState(() => _developerMode = previous);
      }
      _toast('Could not save developer mode: ${userFacingError(e)}');
    }
  }

  Future<void> _saveFlashSettings() async {
    final settings = ref.read(deckhandSettingsProvider);
    final raw = _cacheRetentionController.text.trim();
    final parsed = int.tryParse(raw);
    if (parsed == null || parsed < 0) {
      setState(() => _cacheRetentionError = 'Enter 0 or a positive integer.');
      return;
    }
    final previousVerifyAfterWrite = settings.verifyAfterWrite;
    final previousCacheRetentionDays = settings.cacheRetentionDays;
    settings.verifyAfterWrite = _verifyAfterWrite;
    settings.cacheRetentionDays = parsed;
    try {
      await settings.save();
      setState(() => _cacheRetentionError = null);
      _toast('Flash settings saved.');
    } catch (e) {
      settings.verifyAfterWrite = previousVerifyAfterWrite;
      settings.cacheRetentionDays = previousCacheRetentionDays;
      setState(() => _cacheRetentionError = userFacingError(e));
    }
  }

  Future<void> _runPreflightNow() async {
    if (_preflightRunning) return;
    setState(() {
      _preflightRunning = true;
      _preflightError = null;
    });
    try {
      final report = await ref.read(doctorServiceProvider).run();
      final settings = ref.read(deckhandSettingsProvider);
      settings.lastPreflight = _encodePreflightReport(report);
      await settings.save();
      ref.invalidate(preflightReportProvider);
      if (!mounted) return;
      setState(() {
        _preflightReport = report;
        _preflightRunning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _preflightRunning = false;
        _preflightError = userFacingError(e);
      });
    }
  }

  void _showPreflightReport() {
    final report = _preflightReport;
    if (report == null) return;
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Preflight report'),
        content: SizedBox(
          width: 720,
          child: SingleChildScrollView(
            child: SelectableText(
              report.report,
              style: const TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tSm,
                height: 1.4,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _forgetFingerprint(String host) async {
    try {
      await ref.read(securityServiceProvider).forgetHostFingerprint(host);
      _refreshHostLists();
      _toast('Forgot fingerprint for $host. Next connect will re-prompt.');
    } catch (e) {
      _toast('Could not forget $host: ${userFacingError(e)}');
    }
  }

  Future<void> _revokeHost(String host) async {
    try {
      await ref.read(securityServiceProvider).revokeHost(host);
      _refreshHostLists();
      _toast('Revoked network approval for $host.');
    } catch (e) {
      _toast('Could not revoke $host: ${userFacingError(e)}');
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final settings = ref.watch(deckhandSettingsProvider);

    return WizardScaffold(
      screenId: 'CFG-settings',
      title: t.settings.title,
      helperText:
          'Persistent across sessions; written to settings.json. '
          'Changes apply immediately unless the row says otherwise.',
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _TabRail(
            current: _currentTab,
            onSelect: (tab) => setState(() => _currentTab = tab),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(22),
              decoration: BoxDecoration(
                color: tokens.ink1,
                border: Border.all(color: tokens.line),
                borderRadius: BorderRadius.circular(DeckhandTokens.r3),
              ),
              child: _buildTabBody(context, tokens, settings),
            ),
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: t.common.action_back,
        // Pop returns to whichever screen pushed Settings (the
        // SettingsLinkButton uses context.push). On a deep-link or
        // direct '/settings' load the stack is empty, so fall back
        // to the welcome screen so Back is never a no-op.
        onPressed: () => context.canPop() ? context.pop() : context.go('/'),
        isBack: true,
      ),
    );
  }

  Widget _buildTabBody(
    BuildContext context,
    DeckhandTokens tokens,
    DeckhandSettings settings,
  ) {
    return switch (_currentTab) {
      _SettingsTab.general => _generalBody(context, tokens),
      _SettingsTab.connections => _connectionsBody(context, tokens),
      _SettingsTab.profiles => _profilesBody(context, tokens, settings),
      _SettingsTab.appearance => _appearanceBody(context, tokens, settings),
      _SettingsTab.advanced => _advancedBody(context, tokens),
    };
  }

  // ---------------------------------------------------------------------
  // General — verify-after-write toggle + cache retention.
  // ---------------------------------------------------------------------
  Widget _generalBody(BuildContext context, DeckhandTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _preflightPanel(tokens),
        const _SettingsDivider(),
        _osImageCachePanel(tokens),
        const _SettingsDivider(),
        _RowSwitch(
          title: 'Verify after flash',
          subtitle:
              'Read the disk back after every flash and compare SHA256 '
              'against the source image. Adds 30-90 seconds per GiB but '
              'catches silently-bad writes from cheap USB adapters.',
          value: _verifyAfterWrite,
          onChanged: (v) => setState(() => _verifyAfterWrite = v),
        ),
        const _SettingsDivider(),
        const _FieldLabel('CACHE RETENTION (DAYS)'),
        const SizedBox(height: 6),
        Text(
          'OS images and profile checkouts evict after this many days '
          'of disuse. 0 disables eviction (keep forever).',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          width: 200,
          child: TextField(
            controller: _cacheRetentionController,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              errorText: _cacheRetentionError,
              isDense: true,
            ),
            keyboardType: TextInputType.number,
            onChanged: (_) => setState(() => _cacheRetentionError = null),
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Save general settings'),
            onPressed: _saveFlashSettings,
          ),
        ),
      ],
    );
  }

  Widget _osImageCachePanel(DeckhandTokens tokens) {
    final cacheRoot = ref.watch(osImagesDirProvider);
    final cache = ref.watch(osImageCacheProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const _FieldLabel('OS IMAGE CACHE'),
            const SizedBox(width: 12),
            Expanded(
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                runSpacing: 4,
                children: [
                  if (cacheRoot?.trim().isNotEmpty == true)
                    TextButton.icon(
                      onPressed: _clearOsImageCache,
                      icon: const Icon(
                        Icons.cleaning_services_outlined,
                        size: 14,
                      ),
                      label: const Text('Clear cache'),
                    ),
                  TextButton.icon(
                    onPressed: () => ref.invalidate(osImageCacheProvider),
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Downloaded and verified OS images are reused across installs. '
          'Delete a cached image if you want Deckhand to fetch and verify '
          'a fresh copy.',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 8),
        _MutedPath(
          text: cacheRoot?.trim().isNotEmpty == true
              ? cacheRoot!.trim()
              : 'OS image cache is not configured for this build.',
        ),
        const SizedBox(height: 12),
        cache.when(
          loading: () => const SizedBox(
            height: 18,
            width: 18,
            child: DeckhandSpinner(size: 18, strokeWidth: 2),
          ),
          error: (error, _) => Text(
            'Could not read OS image cache: ${userFacingError(error)}',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tSm,
              color: tokens.bad,
            ),
          ),
          data: (entries) {
            if (cacheRoot == null || cacheRoot.trim().isEmpty) {
              return Text(
                'Cache details are unavailable until the app wires a cache root.',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text3,
                ),
              );
            }
            if (entries.isEmpty) {
              return Text(
                'No OS images are cached yet.',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text3,
                ),
              );
            }
            final totalBytes = entries.fold<int>(
              0,
              (sum, entry) => sum + entry.bytes,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${entries.length} image${entries.length == 1 ? '' : 's'} '
                  'using ${_humanBytes(totalBytes)}',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 10),
                for (final entry in entries)
                  _OsImageCacheRow(
                    entry: entry,
                    onDelete: () => _deleteOsImageCacheEntry(entry),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Future<void> _clearOsImageCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.cleaning_services_outlined),
        title: const Text('Clear OS image cache?'),
        content: const Text(
          'Deckhand will remove all cached OS images, manifests, and '
          'partial downloads from the managed cache folder. Future installs '
          'will download and verify the image again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Clear cache'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      final deleted = await ref.read(osImageCacheClearProvider).call();
      _toast(
        deleted == 0
            ? 'OS image cache was already empty.'
            : 'Cleared $deleted OS image cache file${deleted == 1 ? '' : 's'}.',
      );
    } catch (e) {
      _toast('Could not clear OS image cache: ${userFacingError(e)}');
    }
  }

  Future<void> _deleteOsImageCacheEntry(OsImageCacheEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const Text('Delete cached OS image?'),
        content: Text(
          'Deckhand will remove "${entry.fileName}" from the local cache. '
          'Future installs can download it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref
          .read(osImageCacheDeleteProvider)
          .call(imagePath: entry.imagePath);
      _toast('Deleted ${entry.fileName}.');
    } catch (e) {
      _toast('Could not delete ${entry.fileName}: ${userFacingError(e)}');
    }
  }

  Widget _preflightPanel(DeckhandTokens tokens) {
    final report = _preflightReport;
    DoctorResult? firstIssue;
    if (report != null) {
      for (final result in report.results) {
        if (result.status == DoctorStatus.fail) {
          firstIssue = result;
          break;
        }
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _FieldLabel('PREFLIGHT'),
        const SizedBox(height: 6),
        Text(
          'Re-check sidecar runtime, helper availability, disk access, '
          'mDNS, and GitHub reachability after changing your machine or '
          'Deckhand build.',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 12),
        if (_preflightError != null) ...[
          Text(
            'Preflight failed to run: $_preflightError',
            style: TextStyle(color: tokens.bad),
          ),
          const SizedBox(height: 10),
        ] else if (report != null) ...[
          Text(
            _preflightSummary(report),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              fontWeight: FontWeight.w700,
              color: report.passed ? tokens.ok : tokens.bad,
            ),
          ),
          if (firstIssue != null) ...[
            const SizedBox(height: 4),
            Text(
              '${firstIssue.name}: ${firstIssue.detail}',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.text3,
              ),
            ),
          ],
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            FilledButton.icon(
              icon: _preflightRunning
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: DeckhandSpinner(size: 14, strokeWidth: 2),
                    )
                  : const Icon(Icons.health_and_safety_outlined, size: 16),
              label: Text(
                _preflightRunning ? 'Running preflight...' : 'Run preflight',
              ),
              onPressed: _preflightRunning ? null : _runPreflightNow,
            ),
            if (report != null)
              OutlinedButton.icon(
                icon: const Icon(Icons.article_outlined, size: 16),
                label: const Text('View report'),
                onPressed: _showPreflightReport,
              ),
          ],
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Connections — pinned SSH host fingerprints.
  // ---------------------------------------------------------------------
  Widget _connectionsBody(BuildContext context, DeckhandTokens tokens) {
    return FutureBuilder<Map<String, String>>(
      future: _fingerprintsFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              height: 14,
              width: 14,
              child: DeckhandSpinner(size: 14, strokeWidth: 2),
            ),
          );
        }
        if (snap.hasError) {
          return _SecurityStoreError(message: userFacingError(snap.error));
        }
        final pins = snap.data ?? const <String, String>{};
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _FieldLabel('SAVED CONNECTIONS'),
            const SizedBox(height: 6),
            Text(
              'SSH host keys Deckhand silently trusts on the next '
              'connect. Forget any printer to force re-prompt.',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.text3,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            if (pins.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No printers pinned yet. The first SSH connect to a '
                  'new host will prompt to trust its fingerprint.',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text3,
                  ),
                ),
              )
            else
              for (final host in pins.keys.toList()..sort())
                _ConnectionRow(
                  host: host,
                  fingerprint: _shortFingerprint(pins[host]!),
                  onForget: () => _forgetFingerprint(host),
                ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------
  // Profiles — local override directory vs. GitHub fetch.
  // ---------------------------------------------------------------------
  Widget _profilesBody(
    BuildContext context,
    DeckhandTokens tokens,
    DeckhandSettings settings,
  ) {
    final activeDir = settings.localProfilesDir;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(
              activeDir != null ? Icons.folder_open : Icons.cloud,
              size: 18,
              color: tokens.accent,
            ),
            const SizedBox(width: 8),
            Text(
              activeDir != null
                  ? t.settings.profiles_local_dir_active
                  : t.settings.profiles_local_dir_github,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tMd,
                fontWeight: FontWeight.w500,
                color: tokens.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          flattenProfileText(t.settings.profiles_local_dir_hint),
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 14),
        const _FieldLabel('LOCAL OVERRIDE DIRECTORY'),
        const SizedBox(height: 6),
        TextField(
          controller: _localDirController,
          decoration: InputDecoration(
            hintText: t.settings.profiles_local_dir_label,
            border: const OutlineInputBorder(),
            errorText: _localDirError,
            isDense: true,
            suffixIcon: _localDirController.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: t.settings.profiles_local_dir_clear,
                    onPressed: () {
                      _localDirController.clear();
                      setState(() => _localDirError = null);
                    },
                  ),
          ),
          onChanged: (_) => setState(() => _localDirError = null),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            icon: const Icon(Icons.save, size: 16),
            label: const Text('Save profile source'),
            onPressed: _saveLocalDir,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Appearance — theme picker + UI locale.
  // ---------------------------------------------------------------------
  Widget _appearanceBody(
    BuildContext context,
    DeckhandTokens tokens,
    DeckhandSettings settings,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _FieldLabel('THEME'),
        const SizedBox(height: 6),
        RadioGroup<ThemeMode>(
          groupValue: ref.watch(themeModeProvider),
          onChanged: (m) {
            if (m == null) return;
            ref.read(themeModeProvider.notifier).set(m);
          },
          child: const Column(
            children: [
              _ThemeRadio(
                mode: ThemeMode.system,
                label: 'System',
                detail: 'Follow the OS preference (default).',
              ),
              _ThemeRadio(
                mode: ThemeMode.light,
                label: 'Light',
                detail: 'Force light mode regardless of OS theme.',
              ),
              _ThemeRadio(
                mode: ThemeMode.dark,
                label: 'Dark',
                detail: 'Force dark mode regardless of OS theme.',
              ),
            ],
          ),
        ),
        const _SettingsDivider(),
        const _FieldLabel('LANGUAGE'),
        const SizedBox(height: 6),
        _LocalePickerTile(settings: settings, onChanged: () => setState(() {})),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Advanced — GitHub token + approved network hosts.
  // ---------------------------------------------------------------------
  Widget _advancedBody(BuildContext context, DeckhandTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _RowSwitch(
          title: 'Developer mode',
          subtitle:
              'Show raw step ids, exact session log strings, paths, '
              'URLs, and diagnostic details instead of simplified run '
              'status text.',
          value: _developerMode,
          onChanged: (v) => unawaited(_setDeveloperMode(v)),
        ),
        const _SettingsDivider(),
        const _FieldLabel('GITHUB API TOKEN'),
        const SizedBox(height: 6),
        Text(
          'Optional. A Personal Access Token lifts the rate limit '
          'from 60/hour (anonymous) to 5000/hour (authenticated). '
          'Stored in the OS keychain — never written to disk in '
          'plaintext. A fine-grained token with public-repo read is '
          'enough.',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _githubTokenController,
          obscureText: _githubTokenObscured,
          enabled: _githubTokenLoaded,
          style: const TextStyle(fontFamily: DeckhandTokens.fontMono),
          decoration: InputDecoration(
            hintText: 'ghp_… (optional)',
            border: const OutlineInputBorder(),
            isDense: true,
            suffixIcon: IconButton(
              icon: Icon(
                _githubTokenObscured ? Icons.visibility : Icons.visibility_off,
                size: 18,
              ),
              tooltip: _githubTokenObscured ? 'Show' : 'Hide',
              onPressed: () =>
                  setState(() => _githubTokenObscured = !_githubTokenObscured),
            ),
          ),
        ),
        if (_githubTokenStatus != null) ...[
          const SizedBox(height: 6),
          Text(
            _githubTokenStatus!,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tXs,
              color: tokens.text4,
            ),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.save, size: 16),
              label: const Text('Save token'),
              onPressed: _githubTokenLoaded ? _saveGithubToken : null,
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('Clear'),
              onPressed: _githubTokenLoaded
                  ? () {
                      _githubTokenController.clear();
                      _saveGithubToken();
                    }
                  : null,
            ),
          ],
        ),
        const _SettingsDivider(),
        const _FieldLabel('APPROVED NETWORK HOSTS'),
        const SizedBox(height: 6),
        Text(
          'Outbound destinations Deckhand may contact. Revoke a host '
          'to force a re-prompt on the next install.',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tSm,
            color: tokens.text3,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 12),
        FutureBuilder<List<String>>(
          future: _approvedHostsFuture,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: SizedBox(
                  height: 14,
                  width: 14,
                  child: DeckhandSpinner(size: 14, strokeWidth: 2),
                ),
              );
            }
            if (snap.hasError) {
              return _SecurityStoreError(message: userFacingError(snap.error));
            }
            final hosts = snap.data ?? const <String>[];
            if (hosts.isEmpty) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No hosts approved yet. The first install run will '
                  'prompt for github.com and any image hosts the '
                  'profile declares.',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text3,
                  ),
                ),
              );
            }
            return Container(
              decoration: BoxDecoration(
                border: Border.all(color: tokens.lineSoft),
                borderRadius: BorderRadius.circular(DeckhandTokens.r2),
              ),
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                children: [
                  for (final h in hosts)
                    _ApprovedHostRow(host: h, onRevoke: () => _revokeHost(h)),
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  /// Truncate the long algo + colon-hex bytes of a fingerprint into
  /// something that fits a settings row. Full value still available
  /// in a Tooltip for users who want to verify it.
  String _shortFingerprint(String fp) {
    if (fp.length <= 28) return fp;
    return '${fp.substring(0, 14)}…${fp.substring(fp.length - 8)}';
  }
}

/// Left-rail tab list. Pure presentation — `current`/`onSelect`
/// are wired to the parent state.
class _TabRail extends StatelessWidget {
  const _TabRail({required this.current, required this.onSelect});

  final _SettingsTab current;
  final void Function(_SettingsTab) onSelect;

  static const _items = <(_SettingsTab, String, IconData)>[
    (_SettingsTab.general, 'General', Icons.settings_outlined),
    (_SettingsTab.connections, 'Connections', Icons.lan_outlined),
    (_SettingsTab.profiles, 'Profiles', Icons.folder_outlined),
    (_SettingsTab.appearance, 'Appearance', Icons.palette_outlined),
    (_SettingsTab.advanced, 'Advanced', Icons.terminal),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      width: 200,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (tab, label, icon) in _items)
            _TabRailItem(
              icon: icon,
              label: label,
              selected: current == tab,
              onTap: () => onSelect(tab),
            ),
        ],
      ),
    );
  }
}

class _TabRailItem extends StatelessWidget {
  const _TabRailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? tokens.ink2 : Colors.transparent,
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
        ),
        child: Row(
          children: [
            Icon(icon, size: 16, color: selected ? tokens.text : tokens.text3),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                color: selected ? tokens.text : tokens.text3,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mono uppercase field label used throughout the Settings tabs.
/// Matches the design language's signature 10px tracking-out style.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Text(
      text,
      style: TextStyle(
        fontFamily: DeckhandTokens.fontMono,
        fontSize: 10,
        letterSpacing: 0.1 * 10,
        color: tokens.text4,
      ),
    );
  }
}

class _SettingsDivider extends StatelessWidget {
  const _SettingsDivider();
  @override
  Widget build(BuildContext context) {
    return const SizedBox(height: 24);
  }
}

class _MutedPath extends StatelessWidget {
  const _MutedPath({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.lineSoft),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontFamily: DeckhandTokens.fontMono,
          fontSize: DeckhandTokens.tXs,
          color: tokens.text3,
          height: 1.35,
        ),
      ),
    );
  }
}

class _OsImageCacheRow extends StatelessWidget {
  const _OsImageCacheRow({required this.entry, required this.onDelete});

  final OsImageCacheEntry entry;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final status = _cacheStatus(entry);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.image_outlined, size: 16, color: status.color(tokens)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      entry.fileName,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontSans,
                        fontSize: DeckhandTokens.tMd,
                        fontWeight: FontWeight.w600,
                        color: tokens.text,
                      ),
                    ),
                    _CacheStatusChip(status: status),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  [
                    _humanBytes(entry.bytes),
                    _cacheSource(entry),
                    'last used ${_shortDateTime(entry.lastTouchedAt)}',
                  ].join(' · '),
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text3,
                    height: 1.35,
                  ),
                ),
                if (entry.actualSha256 != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    'sha256 ${_shortSha(entry.actualSha256!)}',
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontMono,
                      fontSize: DeckhandTokens.tXs,
                      color: tokens.text4,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  entry.imagePath,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tXs,
                    color: tokens.text4,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: tokens.bad,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline, size: 14),
            label: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}

class _CacheStatusChip extends StatelessWidget {
  const _CacheStatusChip({required this.status});

  final _CacheStatus status;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final color = status.color(tokens);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Text(
        status.label,
        style: TextStyle(
          fontFamily: DeckhandTokens.fontMono,
          fontSize: 10,
          color: color,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}

/// Title + subtitle on the left, switch on the right. The mockup's
/// canonical "toggleable preference" row.
class _RowSwitch extends StatelessWidget {
  const _RowSwitch({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tMd,
                  fontWeight: FontWeight.w500,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text3,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}

/// Bordered row in the Connections tab — a printer host + its
/// fingerprint hash + a Forget button. Mirrors the mockup's
/// "saved connections" card style.
class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({
    required this.host,
    required this.fingerprint,
    required this.onForget,
  });

  final String host;
  final String fingerprint;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: tokens.line),
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
        ),
        child: Row(
          children: [
            Icon(Icons.print_outlined, size: 16, color: tokens.text3),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host,
                    style: const TextStyle(
                      fontFamily: DeckhandTokens.fontMono,
                      fontSize: DeckhandTokens.tMd,
                    ),
                  ),
                  Text(
                    fingerprint,
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontMono,
                      fontSize: DeckhandTokens.tXs,
                      color: tokens.text4,
                    ),
                  ),
                ],
              ),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: tokens.bad,
                minimumSize: const Size(0, 28),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: onForget,
              child: const Text('Forget'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecurityStoreError extends StatelessWidget {
  const _SecurityStoreError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tokens.bad.withValues(alpha: 0.08),
        border: Border.all(color: tokens.bad.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: tokens.bad),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Secure storage error: $message',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.bad,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact row in the Advanced tab's approved-host list — a host,
/// a green check, and a small Revoke button.
class _ApprovedHostRow extends StatelessWidget {
  const _ApprovedHostRow({required this.host, required this.onRevoke});
  final String host;
  final VoidCallback onRevoke;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.check, size: 14, color: tokens.ok),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              host,
              style: const TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tSm,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 24),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: const TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: 11,
              ),
            ),
            onPressed: onRevoke,
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
  }
}

enum _CacheStatus {
  verified('VERIFIED'),
  unindexed('UNINDEXED'),
  mismatch('MISMATCH');

  const _CacheStatus(this.label);
  final String label;

  Color color(DeckhandTokens tokens) => switch (this) {
    _CacheStatus.verified => tokens.ok,
    _CacheStatus.unindexed => tokens.warn,
    _CacheStatus.mismatch => tokens.bad,
  };
}

_CacheStatus _cacheStatus(OsImageCacheEntry entry) {
  if (!entry.hasManifest) return _CacheStatus.unindexed;
  return entry.hashMatchesManifest
      ? _CacheStatus.verified
      : _CacheStatus.mismatch;
}

String _cacheSource(OsImageCacheEntry entry) {
  final raw = entry.url;
  if (raw == null || raw.trim().isEmpty) return 'local file';
  final uri = Uri.tryParse(raw);
  final host = uri?.host;
  if (host == null || host.isEmpty) return 'local file';
  return host;
}

String _shortSha(String sha) {
  final value = sha.trim();
  if (value.length <= 16) return value;
  return '${value.substring(0, 12)}...${value.substring(value.length - 8)}';
}

String _shortDateTime(DateTime dateTime) {
  final local = dateTime.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _humanBytes(int bytes) {
  const kib = 1024;
  const mib = kib * 1024;
  const gib = mib * 1024;
  if (bytes < kib) return '$bytes B';
  if (bytes < mib) return '${(bytes / kib).toStringAsFixed(1)} KiB';
  if (bytes < gib) return '${(bytes / mib).toStringAsFixed(1)} MiB';
  return '${(bytes / gib).toStringAsFixed(2)} GiB';
}

Map<String, dynamic> _encodePreflightReport(DoctorReport report) {
  return {
    'passed': report.passed,
    'report': report.report,
    'at': DateTime.now().toIso8601String(),
    'results': [
      for (final result in report.results)
        {
          'name': result.name,
          'status': _doctorStatusString(result.status),
          'detail': result.detail,
        },
    ],
  };
}

DoctorReport? _decodePreflightReport(Map<String, dynamic>? raw) {
  if (raw == null) return null;
  final passed = raw['passed'];
  final report = raw['report'];
  final resultsRaw = raw['results'];
  if (passed is! bool || report is! String || resultsRaw is! List) {
    return null;
  }
  final results = <DoctorResult>[];
  for (final item in resultsRaw) {
    if (item is! Map) continue;
    final entry = item.cast<dynamic, dynamic>();
    final name = entry['name'];
    final status = entry['status'];
    final detail = entry['detail'];
    if (name is! String || status is! String || detail is! String) continue;
    results.add(
      DoctorResult(
        name: name,
        status: doctorStatusFromString(status),
        detail: detail,
      ),
    );
  }
  return DoctorReport(passed: passed, results: results, report: report);
}

String _preflightSummary(DoctorReport report) {
  final failures = report.failures.length;
  if (failures > 0) {
    return 'Preflight found $failures issue${failures == 1 ? '' : 's'}';
  }
  final warnings = report.warnings.length;
  if (warnings > 0) {
    return 'Preflight ready ($warnings warning${warnings == 1 ? '' : 's'})';
  }
  return 'Preflight ready';
}

String _doctorStatusString(DoctorStatus status) {
  return switch (status) {
    DoctorStatus.pass => 'PASS',
    DoctorStatus.warn => 'WARN',
    DoctorStatus.fail => 'FAIL',
    DoctorStatus.unknown => 'UNKNOWN',
  };
}

class _ThemeRadio extends StatelessWidget {
  const _ThemeRadio({
    required this.mode,
    required this.label,
    required this.detail,
  });
  final ThemeMode mode;
  final String label;
  final String detail;

  @override
  Widget build(BuildContext context) {
    // No groupValue/onChanged here — both come from the enclosing
    // RadioGroup<ThemeMode> ancestor in the Appearance section.
    return RadioListTile<ThemeMode>(
      contentPadding: EdgeInsets.zero,
      value: mode,
      title: Text(label),
      subtitle: Text(detail),
    );
  }
}

/// Picker for the UI language. Drives `LocaleSettings` directly so
/// the change is visible immediately without an app restart, and
/// persists the choice to `DeckhandSettings.preferredLocale` so the
/// next launch picks up the same locale before the first frame.
class _LocalePickerTile extends StatelessWidget {
  const _LocalePickerTile({required this.settings, required this.onChanged});
  final DeckhandSettings settings;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final current = LocaleSettings.currentLocale;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Language'),
      subtitle: const Text(
        'Switches the wizard UI language. Falls back to English for '
        'any string not yet translated.',
      ),
      trailing: DropdownButton<AppLocale>(
        value: current,
        onChanged: (locale) async {
          if (locale == null) return;
          LocaleSettings.setLocale(locale);
          settings.preferredLocale = locale.languageCode;
          await settings.save();
          onChanged();
        },
        items: [
          for (final l in AppLocale.values)
            DropdownMenuItem(
              value: l,
              child: Text(l.languageCode.toUpperCase()),
            ),
        ],
      ),
    );
  }
}
