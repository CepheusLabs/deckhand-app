import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/disk_display.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/wizard_progress_bar.dart';
import '../widgets/wizard_scaffold.dart';
import 'manage_tuning_panel.dart';

/// Post-install printer management. Reached after a wizard run
/// completes (or directly via `/manage`). The mockup design is a
/// horizontal tab strip + per-tab body — analogous to a "manage
/// device" pane in a desktop app.
///
/// Tabs:
///  * Printer status — live Klippy state from Moonraker, plus
///    quick links (copy Mainsail URL, copy SSH host).
///  * Backup — kicks the user into the existing eMMC backup
///    flow at `/emmc-backup`.
///  * Restore — writes a previously captured full-eMMC backup image
///    back to a selected removable target through the elevated helper.
///  * Flash MCU — same story; MCU detection + reflashing is a
///    distinct service surface that doesn't exist yet.
///  * Re-run wizard — jumps back to S40 with the printer's
///    identity preserved, so a user can repair / reconfigure
///    without losing their profile selection.
///
/// `WizardScaffold` is reused for chrome consistency. The
/// stepper auto-hides on this route (it's not a wizard step).
class ManageScreen extends ConsumerStatefulWidget {
  const ManageScreen({super.key});

  @override
  ConsumerState<ManageScreen> createState() => _ManageScreenState();
}

/// Direct rollback surface for restoring a full eMMC image without
/// requiring the user to enter an in-progress install's Manage view.
///
/// This intentionally reuses the same restore tab body as Manage so
/// the future printer-registry submodule only has to route users into
/// one restore implementation.
class EmmcRestoreScreen extends StatelessWidget {
  const EmmcRestoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      screenId: 'MGR-restore',
      title: 'Restore an eMMC backup.',
      helperText:
          'Writes a Deckhand backup image back to a selected eMMC adapter. '
          'Use this when you need to roll a printer back to a known image.',
      body: const _RestoreTab(),
      primaryAction: WizardAction(
        label: 'Done',
        onPressed: () => context.go('/'),
        isBack: true,
      ),
    );
  }
}

enum _ManageTab { status, tune, backup, restore, mcu, wizard }

class _ManageScreenState extends ConsumerState<ManageScreen> {
  _ManageTab _currentTab = _ManageTab.status;

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(wizardControllerProvider);
    final state = controller.state;
    final profile = controller.profile;

    // Title is "Manage · <printer>" when a profile is loaded; falls
    // back to plain "Manage" so the screen still renders if the user
    // navigates directly without an active session.
    final printerLabel = profile?.displayName ?? state.profileId;
    final title = printerLabel.isEmpty ? 'Manage' : 'Manage · $printerLabel';

    return WizardScaffold(
      screenId: 'MGR-manage',
      title: title,
      helperText:
          'Things Klipper, Moonraker, and KIAUH don\'t already own. '
          'Updates to those tools live in those tools — Deckhand stays '
          'out of their lane.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _ManageTabStrip(
            current: _currentTab,
            onSelect: (t) => setState(() => _currentTab = t),
          ),
          const SizedBox(height: 16),
          _buildTabBody(state, profile),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Done',
        onPressed: () => context.go('/'),
        isBack: true,
      ),
    );
  }

  Widget _buildTabBody(WizardState state, PrinterProfile? profile) {
    return switch (_currentTab) {
      _ManageTab.status => _StatusTab(state: state, profile: profile),
      _ManageTab.tune => const ManageTuningPanel(),
      _ManageTab.backup => const _BackupTab(),
      _ManageTab.restore => const _RestoreTab(),
      _ManageTab.mcu => const _McuTab(),
      _ManageTab.wizard => const _ReRunWizardTab(),
    };
  }
}

/// Horizontal tab strip — one row of icon+label buttons separated
/// by a hairline border, with a 2px accent underline below the
/// active tab. Matches the mockup's `borderBottom` pattern.
class _ManageTabStrip extends StatelessWidget {
  const _ManageTabStrip({required this.current, required this.onSelect});

  final _ManageTab current;
  final void Function(_ManageTab) onSelect;

  static const _items = <(_ManageTab, String, IconData)>[
    (_ManageTab.status, 'Printer status', Icons.visibility_outlined),
    (_ManageTab.tune, 'Tune', Icons.tune),
    (_ManageTab.backup, 'Backup', Icons.inventory_2_outlined),
    (_ManageTab.restore, 'Restore', Icons.restore),
    (_ManageTab.mcu, 'Flash MCU', Icons.memory),
    (_ManageTab.wizard, 'Re-run wizard', Icons.refresh),
  ];

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.line)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (tab, label, icon) in _items)
              _TabStripButton(
                label: label,
                icon: icon,
                selected: current == tab,
                onTap: () => onSelect(tab),
              ),
          ],
        ),
      ),
    );
  }
}

class _TabStripButton extends StatelessWidget {
  const _TabStripButton({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          // -1 bottom margin pulls the underline over the strip's
          // own border so the active accent visually replaces the
          // hairline rather than stacking on top of it.
          border: Border(
            bottom: BorderSide(
              color: selected ? tokens.accent : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: selected ? tokens.text : tokens.text3),
            const SizedBox(width: 6),
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

// ---------------------------------------------------------------------
// Status tab — live Klippy state via Moonraker.
// ---------------------------------------------------------------------
class _StatusTab extends ConsumerStatefulWidget {
  const _StatusTab({required this.state, required this.profile});
  final WizardState state;
  final PrinterProfile? profile;

  @override
  ConsumerState<_StatusTab> createState() => _StatusTabState();
}

class _StatusTabState extends ConsumerState<_StatusTab> {
  Future<_StatusSnapshot>? _snapshot;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final host = widget.state.sshHost;
    if (host == null || host.isEmpty) {
      _snapshot = Future.value(const _StatusSnapshot.disconnected());
      return;
    }
    final moonraker = ref.read(moonrakerServiceProvider);
    setState(() {
      _snapshot = _query(moonraker, host);
    });
  }

  Future<_StatusSnapshot> _query(
    MoonrakerService moonraker,
    String host,
  ) async {
    try {
      final info = await moonraker.info(host: host);
      final printing = await moonraker.isPrinting(host: host);
      return _StatusSnapshot.ok(info: info, printing: printing, host: host);
    } catch (e) {
      return _StatusSnapshot.error(host: host, message: e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final controller = ref.watch(wizardControllerProvider);
    final host = widget.state.sshHost;
    final profile = widget.profile;
    final webUiUrl = host == null || host.isEmpty
        ? null
        : _webUiUrl(host: host, profile: profile);
    final sshUser = controller.sshSession?.user ?? _defaultSshUser(profile);
    return _Panel(
      child: FutureBuilder<_StatusSnapshot>(
        future: _snapshot,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: DeckhandSpinner(size: 24, strokeWidth: 2)),
            );
          }
          final s = snap.data!;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const _MonoLabel('STATE'),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh, size: 16),
                    tooltip: 'Refresh',
                    onPressed: _refresh,
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _StateDot(color: _stateColor(tokens, s)),
                  const SizedBox(width: 10),
                  Text(
                    _stateLabel(s),
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontSans,
                      fontSize: DeckhandTokens.t2Xl,
                      fontWeight: FontWeight.w500,
                      color: tokens.text,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (s.error != null) ...[
                Text(
                  s.error!,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.bad,
                  ),
                ),
              ] else if (s.info != null) ...[
                _StatGrid(
                  stats: [
                    _Stat('HOSTNAME', s.info!.hostname),
                    _Stat('KLIPPER', s.info!.softwareVersion),
                    _Stat('KLIPPY', s.info!.klippyState),
                    _Stat('JOB', s.printing ? 'Printing' : 'Idle'),
                  ],
                ),
              ] else if (host == null || host.isEmpty) ...[
                Text(
                  'No printer connected. Run the wizard once to pin a '
                  'host, then come back here for live status.',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text3,
                    height: 1.5,
                  ),
                ),
              ],
              if ((host ?? '').isNotEmpty) ...[
                const SizedBox(height: 18),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      icon: const Icon(Icons.copy, size: 14),
                      label: const Text('Copy Web UI URL'),
                      onPressed: () => _copyToClipboard(
                        context,
                        webUiUrl!,
                        'Web UI URL copied',
                      ),
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.terminal, size: 14),
                      label: const Text('Copy SSH command'),
                      onPressed: () => _copyToClipboard(
                        context,
                        'ssh $sshUser@$host',
                        'SSH command copied',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  Color _stateColor(DeckhandTokens tokens, _StatusSnapshot s) {
    if (s.error != null) return tokens.bad;
    if (s.info == null) return tokens.text4;
    final ks = s.info!.klippyState.toLowerCase();
    if (ks == 'ready') return tokens.ok;
    if (ks == 'error' || ks == 'shutdown') return tokens.bad;
    return tokens.warn;
  }

  String _stateLabel(_StatusSnapshot s) {
    if (s.error != null) return 'Unreachable';
    if (s.info == null) return 'Disconnected';
    final ks = s.info!.klippyState;
    if (ks.isEmpty) return s.info!.state;
    return ks[0].toUpperCase() + ks.substring(1);
  }
}

String _webUiUrl({required String host, required PrinterProfile? profile}) {
  final webui = profile?.stack.webui ?? const <String, dynamic>{};
  final scheme = (webui['scheme'] as String?)?.trim().toLowerCase();
  final port = _webUiPort(profile);
  final normalizedScheme = scheme == 'https' ? 'https' : 'http';
  final portSuffix =
      (normalizedScheme == 'http' && port == 80) ||
          (normalizedScheme == 'https' && port == 443)
      ? ''
      : ':$port';
  return '$normalizedScheme://$host$portSuffix';
}

int _webUiPort(PrinterProfile? profile) {
  final webui = profile?.stack.webui ?? const <String, dynamic>{};
  final raw = webui['port'] ?? webui['url_port'] ?? webui['http_port'];
  if (raw is num && raw >= 1 && raw <= 65535) return raw.toInt();
  if (raw is String) {
    final parsed = int.tryParse(raw.trim());
    if (parsed != null && parsed >= 1 && parsed <= 65535) return parsed;
  }
  return profile?.id == 'phrozen-arco' ? 8808 : 80;
}

String _defaultSshUser(PrinterProfile? profile) {
  final credentials = profile?.ssh.defaultCredentials ?? const [];
  return credentials.isEmpty ? 'root' : credentials.first.user;
}

class _StatusSnapshot {
  const _StatusSnapshot.disconnected()
    : info = null,
      printing = false,
      host = null,
      error = null;
  const _StatusSnapshot.ok({
    required KlippyInfo this.info,
    required this.printing,
    required this.host,
  }) : error = null;
  const _StatusSnapshot.error({required this.host, required String message})
    : info = null,
      printing = false,
      error = message;

  final KlippyInfo? info;
  final bool printing;
  final String? host;
  final String? error;
}

class _StateDot extends StatelessWidget {
  const _StateDot({required this.color});
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.25),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Backup tab — defers to the existing /emmc-backup flow.
// ---------------------------------------------------------------------
class _BackupTab extends StatelessWidget {
  const _BackupTab();

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _MonoLabel('FULL DISK BACKUP'),
          const SizedBox(height: 8),
          Text(
            'Pull a complete byte-for-byte image of the printer\'s eMMC '
            'to local storage. SHA256-verified on completion. Recommended before '
            'any destructive change — flash, reconfigure, or migrate.',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.inventory_2_outlined, size: 16),
              label: const Text('Open backup flow'),
              onPressed: () => context.go('/manage-emmc-backup'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Restore tab — full eMMC image restore via elevated helper.
// ---------------------------------------------------------------------
class _RestoreTab extends ConsumerStatefulWidget {
  const _RestoreTab();

  @override
  ConsumerState<_RestoreTab> createState() => _RestoreTabState();
}

class _RestoreImage {
  const _RestoreImage.manifest(this.manifest) : candidate = null;

  const _RestoreImage.candidate(this.candidate) : manifest = null;

  final EmmcBackupManifest? manifest;
  final EmmcBackupImageCandidate? candidate;

  bool get indexed => manifest != null;

  String get imagePath => manifest?.imagePath ?? candidate!.imagePath;

  int get imageBytes => manifest?.imageBytes ?? candidate!.imageBytes;

  DateTime get createdAt => manifest?.createdAt ?? candidate!.modifiedAt;

  String? get profileId => manifest?.profileId ?? candidate?.inferredProfileId;

  String get manifestSha256 => manifest?.imageSha256 ?? '';

  EmmcBackupDiskIdentity? get diskIdentity => manifest?.disk;
}

class _RestoreTabState extends ConsumerState<_RestoreTab> {
  final _typed = TextEditingController();
  StreamSubscription<FlashProgress>? _restoreSub;
  String? _selectedImagePath;
  String? _selectedDiskId;
  FlashProgress? _progress;
  String? _error;
  bool _checking = false;
  bool _done = false;
  bool _cancelRequested = false;

  @override
  void initState() {
    super.initState();
    _typed.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _restoreSub?.cancel();
    _typed.dispose();
    super.dispose();
  }

  bool get _busy =>
      _checking || (_progress != null && !_done && _error == null);

  @override
  Widget build(BuildContext context) {
    final manifestsAsync = ref.watch(emmcBackupManifestsProvider);
    final candidatesAsync = ref.watch(emmcBackupImageCandidatesProvider);
    final disksAsync = ref.watch(disksProvider);
    final backupDir = ref.watch(emmcBackupsDirProvider);
    final tokens = DeckhandTokens.of(context);

    if ((manifestsAsync.isLoading && !manifestsAsync.hasValue) ||
        (candidatesAsync.isLoading && !candidatesAsync.hasValue)) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: DeckhandLoadingBlock(
          kind: DeckhandLoaderKind.emmcPins,
          title: 'Loading backups',
          message:
              'Deckhand is scanning local eMMC backup manifests before restore.',
        ),
      );
    }
    if (manifestsAsync.hasError) {
      return _RestoreProblem(message: '${manifestsAsync.error}');
    }
    if (candidatesAsync.hasError) {
      return _RestoreProblem(message: '${candidatesAsync.error}');
    }

    final manifests =
        manifestsAsync.valueOrNull ?? const <EmmcBackupManifest>[];
    final candidates =
        candidatesAsync.valueOrNull ?? const <EmmcBackupImageCandidate>[];
    if (disksAsync.isLoading && !disksAsync.hasValue) {
      return const Padding(
        padding: EdgeInsets.only(top: 8),
        child: DeckhandLoadingBlock(
          kind: DeckhandLoaderKind.emmcPins,
          title: 'Scanning disks',
          message: 'Deckhand is enumerating removable drives before restore.',
        ),
      );
    }
    if (disksAsync.hasError) {
      return _RestoreProblem(message: '${disksAsync.error}');
    }

    final disks = disksAsync.valueOrNull ?? const <DiskInfo>[];
    final images = _restoreImagesFrom(
      manifests: manifests,
      candidates: candidates,
    );
    if (images.isEmpty) {
      return _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _MonoLabel('RESTORE EMMC IMAGE'),
            const SizedBox(height: 8),
            Text(
              'No eMMC backup images were found. Deckhand looked for '
              'manifest-indexed backups and standalone .img files in:',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tMd,
                color: tokens.text2,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 10),
            _MutedBox(
              text: backupDir?.trim().isNotEmpty == true
                  ? backupDir!.trim()
                  : 'No backup directory is configured for this build.',
            ),
            const SizedBox(height: 10),
            Text(
              'Put the backup image in that folder, or make a new eMMC '
              'backup from the Backup tab. Restore stays on this '
              'recovery screen so canceling never drops into an '
              'install step.',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.text3,
                height: 1.45,
              ),
            ),
          ],
        ),
      );
    }
    final image = _selectedImage(images);
    final target = image == null ? null : _selectedDisk(disks, image);
    final expected = target == null ? '' : diskDisplayName(target);
    final typedMatches = expected.isNotEmpty && _typed.text.trim() == expected;
    final canRestore =
        !_busy && image != null && target != null && typedMatches;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const _MonoLabel('RESTORE EMMC IMAGE'),
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _busy
                        ? null
                        : () {
                            ref.invalidate(emmcBackupManifestsProvider);
                            ref.invalidate(emmcBackupImageCandidatesProvider);
                            ref.invalidate(disksProvider);
                          },
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Refresh'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Select a Deckhand backup image, pick the eMMC adapter to '
                'overwrite, then restore it through the elevated helper. '
                'Deckhand verifies the backup hash before writing.',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tMd,
                  color: tokens.text2,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 18),
              _SectionHeader(
                label: 'BACKUP IMAGE',
                trailing:
                    '${images.length} image${images.length == 1 ? '' : 's'}',
              ),
              const SizedBox(height: 8),
              for (final restoreImage in images)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _RestoreChoiceTile(
                    selected: identical(restoreImage, image),
                    icon: Icons.image_outlined,
                    title: _restoreImageTitle(restoreImage),
                    subtitle: _restoreImageSubtitle(restoreImage),
                    danger: false,
                    onTap: _busy
                        ? null
                        : () => setState(() {
                            _selectedImagePath = restoreImage.imagePath;
                            _selectedDiskId = null;
                            _typed.clear();
                            _error = null;
                            _done = false;
                            _progress = null;
                          }),
                  ),
                ),
              const SizedBox(height: 10),
              _SectionHeader(
                label: 'TARGET EMMC',
                trailing: '${disks.length} disk${disks.length == 1 ? '' : 's'}',
              ),
              const SizedBox(height: 8),
              if (disks.isEmpty)
                const _MutedBox(
                  text:
                      'No disks are visible. Connect the eMMC adapter and refresh.',
                )
              else
                for (final d in disks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _RestoreChoiceTile(
                      selected: identical(d, target),
                      icon: Icons.album_outlined,
                      title: diskDisplaySummary(d),
                      subtitle: _restoreDiskSubtitle(d, image),
                      danger: true,
                      onTap: _busy || !_restoreDiskSelectable(d, image)
                          ? null
                          : () => setState(() {
                              _selectedDiskId = d.id;
                              _typed.clear();
                              _error = null;
                              _done = false;
                              _progress = null;
                            }),
                    ),
                  ),
              const SizedBox(height: 12),
              _RestoreConfirmBlock(
                expected: expected,
                typed: _typed,
                matched: typedMatches,
                busy: _busy,
                done: _done,
                onRestore: canRestore
                    ? () => _confirmRestore(image, target)
                    : null,
                onCancel: _busy ? _cancelRestore : null,
              ),
            ],
          ),
        ),
        if (_checking || _progress != null || _error != null || _done) ...[
          const SizedBox(height: 12),
          _RestoreProgressPanel(
            checking: _checking,
            progress: _progress,
            error: _error,
            done: _done,
          ),
        ],
      ],
    );
  }

  _RestoreImage? _selectedImage(List<_RestoreImage> images) {
    if (images.isEmpty) return null;
    final selected = _selectedImagePath;
    if (selected != null) {
      for (final image in images) {
        if (image.imagePath == selected) return image;
      }
    }
    return images.first;
  }

  DiskInfo? _selectedDisk(List<DiskInfo> disks, _RestoreImage image) {
    final selected = _selectedDiskId;
    if (selected != null) {
      for (final disk in disks) {
        if (disk.id == selected && _restoreDiskSelectable(disk, image)) {
          return disk;
        }
      }
    }
    final identity = image.diskIdentity;
    if (identity != null) {
      for (final disk in disks) {
        if (disk.removable && identity.matches(disk)) return disk;
      }
    }
    for (final disk in disks) {
      if (_restoreDiskSelectable(disk, image)) return disk;
    }
    return null;
  }

  Future<void> _confirmRestore(_RestoreImage image, DiskInfo disk) async {
    final tokens = DeckhandTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: tokens.bad),
        title: const Text('Restore eMMC backup'),
        content: Text(
          'Deckhand will erase ${diskDisplayName(disk)} and restore:\n\n'
          '${image.imagePath}\n\n'
          '${image.indexed ? 'Deckhand will verify the backup manifest hash before writing.' : 'This image has no Deckhand manifest. Deckhand will hash the file before writing.'}\n\n'
          'This overwrites the selected eMMC. The host computer and other '
          'drives are not touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            style: FilledButton.styleFrom(
              backgroundColor: tokens.bad,
              foregroundColor: const Color(0xFFFCFCFC),
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('Restore image now'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _startRestore(image, disk);
    }
  }

  Future<void> _startRestore(_RestoreImage restoreImage, DiskInfo disk) async {
    await _restoreSub?.cancel();
    if (!mounted) return;
    _cancelRequested = false;
    setState(() {
      _checking = true;
      _progress = const FlashProgress(
        bytesDone: 0,
        bytesTotal: 0,
        phase: FlashPhase.preparing,
        message: 'checking backup image',
      );
      _error = null;
      _done = false;
    });

    try {
      if (!disk.removable) {
        throw StateError('Target disk is not removable.');
      }
      final image = File(restoreImage.imagePath);
      if (!await image.exists()) {
        throw StateError(
          'Backup image no longer exists: ${restoreImage.imagePath}',
        );
      }
      final length = await image.length();
      if (length != restoreImage.imageBytes) {
        throw StateError(
          'Backup image size changed. Expected '
          '${_formatBytes(restoreImage.imageBytes)}, found ${_formatBytes(length)}.',
        );
      }
      if (disk.sizeBytes < restoreImage.imageBytes) {
        throw StateError(
          '${diskDisplayName(disk)} is smaller than the backup image. '
          'Choose an eMMC that is the same size or larger.',
        );
      }

      final flash = ref.read(flashServiceProvider);
      final actualSha = (await flash.sha256(
        restoreImage.imagePath,
      )).trim().toLowerCase();
      if (_cancelRequested) return;
      if (!_isSha256Hex(actualSha)) {
        throw StateError('Backup image hash is not a valid SHA-256.');
      }
      final manifestSha = restoreImage.manifestSha256.trim().toLowerCase();
      if (restoreImage.indexed && actualSha != manifestSha) {
        throw StateError(
          'Backup image hash does not match its manifest. Refusing to restore.',
        );
      }
      final expectedSha = restoreImage.indexed ? manifestSha : actualSha;

      final verdict = await flash.safetyCheck(diskId: disk.id);
      if (_cancelRequested) return;
      if (!verdict.allowed) {
        final reasons = verdict.blockingReasons.isEmpty
            ? 'No blocking reason returned.'
            : verdict.blockingReasons.join('; ');
        throw StateError('Disk safety check blocked restore: $reasons');
      }
      if (verdict.warnings.isNotEmpty && mounted) {
        final proceed = await _confirmSafetyWarnings(verdict.warnings);
        if (proceed != true) {
          if (mounted) {
            setState(() {
              _checking = false;
              _progress = null;
            });
          }
          return;
        }
      }

      final helper = ref.read(elevatedHelperServiceProvider);
      if (helper == null) {
        throw StateError('Elevated helper is not configured.');
      }
      if (_cancelRequested) return;
      final security = ref.read(securityServiceProvider);
      final token = await security.issueConfirmationToken(
        operation: 'write_image',
        target: disk.id,
      );
      if (_cancelRequested) return;
      if (!security.consumeToken(token.value, 'write_image', target: disk.id)) {
        throw StateError('Confirmation token was rejected before restore.');
      }

      if (!mounted) return;
      setState(() => _checking = false);
      _restoreSub = helper
          .writeImage(
            imagePath: restoreImage.imagePath,
            diskId: disk.id,
            confirmationToken: token.value,
            verifyAfterWrite: true,
            expectedSha256: expectedSha,
          )
          .listen(
            (event) {
              if (!mounted) return;
              setState(() {
                _progress = event.bytesTotal > 0
                    ? event
                    : FlashProgress(
                        bytesDone: event.bytesDone,
                        bytesTotal: restoreImage.imageBytes,
                        phase: event.phase,
                        message: event.message,
                      );
                if (event.phase == FlashPhase.done) {
                  _done = true;
                  ref.invalidate(disksProvider);
                }
                if (event.phase == FlashPhase.failed) {
                  _error = event.message ?? 'Restore failed.';
                }
              });
            },
            onError: (Object e, StackTrace st) {
              if (!mounted) return;
              setState(() {
                _checking = false;
                _error = _friendlyRestoreError(e);
              });
            },
            onDone: () {
              if (!mounted) return;
              setState(() => _checking = false);
            },
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = _friendlyRestoreError(e);
        _progress = const FlashProgress(
          bytesDone: 0,
          bytesTotal: 0,
          phase: FlashPhase.failed,
        );
      });
    }
  }

  Future<bool?> _confirmSafetyWarnings(List<String> warnings) {
    final tokens = DeckhandTokens.of(context);
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: tokens.warn),
        title: const Text('Review disk warning'),
        content: Text(
          'Deckhand can continue, but the live disk safety check reported:\n\n'
          '${warnings.join('\n')}\n\n'
          'Continue only if this is the eMMC backup target.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Continue restore'),
          ),
        ],
      ),
    );
  }

  Future<void> _cancelRestore() async {
    _cancelRequested = true;
    await _restoreSub?.cancel();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _progress = null;
      _error = 'Restore canceled.';
    });
  }
}

class _RestoreProblem extends StatelessWidget {
  const _RestoreProblem({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return _Panel(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: tokens.bad),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.bad,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.trailing});
  final String label;
  final String trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Row(
      children: [
        _MonoLabel(label),
        const Spacer(),
        Text(
          trailing,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: DeckhandTokens.tXs,
            color: tokens.text4,
          ),
        ),
      ],
    );
  }
}

class _RestoreChoiceTile extends StatelessWidget {
  const _RestoreChoiceTile({
    required this.selected,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.danger,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String title;
  final String subtitle;
  final bool danger;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final enabled = onTap != null;
    final accent = danger && selected ? tokens.bad : tokens.accent;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Opacity(
        opacity: enabled ? 1 : 0.46,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            decoration: BoxDecoration(
              color: selected
                  ? Color.alphaBlend(
                      accent.withValues(alpha: 0.08),
                      tokens.ink0,
                    )
                  : tokens.ink2,
              border: Border.all(
                color: selected ? accent.withValues(alpha: 0.55) : tokens.line,
              ),
              borderRadius: BorderRadius.circular(DeckhandTokens.r2),
            ),
            child: Row(
              children: [
                Icon(icon, size: 16, color: selected ? accent : tokens.text3),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: DeckhandTokens.fontSans,
                          fontSize: DeckhandTokens.tSm,
                          fontWeight: FontWeight.w500,
                          color: tokens.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: DeckhandTokens.fontMono,
                          fontSize: DeckhandTokens.tXs,
                          color: tokens.text3,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                  color: selected ? accent : tokens.text4,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MutedBox extends StatelessWidget {
  const _MutedBox({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tSm,
          color: tokens.text3,
          height: 1.45,
        ),
      ),
    );
  }
}

class _RestoreConfirmBlock extends StatelessWidget {
  const _RestoreConfirmBlock({
    required this.expected,
    required this.typed,
    required this.matched,
    required this.busy,
    required this.done,
    required this.onRestore,
    required this.onCancel,
  });

  final String expected;
  final TextEditingController typed;
  final bool matched;
  final bool busy;
  final bool done;
  final VoidCallback? onRestore;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final border = matched ? tokens.ok : tokens.line;
    final enabled = expected.isNotEmpty && !busy && !done;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: border.withValues(alpha: 0.65)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _MonoLabel('TYPE THE TARGET DISK NAME TO ENABLE RESTORE'),
          const SizedBox(height: 8),
          TextField(
            controller: typed,
            enabled: enabled,
            decoration: InputDecoration(
              hintText: expected.isEmpty ? 'select a target disk' : expected,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            expected.isEmpty
                ? 'EXPECTED: —'
                : matched
                ? 'MATCH · RESTORE ARMED'
                : 'EXPECTED: $expected',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tXs,
              color: matched ? tokens.ok : tokens.text4,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (onCancel != null)
                OutlinedButton.icon(
                  onPressed: onCancel,
                  icon: const Icon(Icons.close, size: 14),
                  label: const Text('Cancel restore'),
                ),
              const Spacer(),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: tokens.bad,
                  foregroundColor: const Color(0xFFFCFCFC),
                ),
                onPressed: onRestore,
                icon: const Icon(Icons.restore, size: 16),
                label: Text(done ? 'Restore complete' : 'Restore backup'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RestoreProgressPanel extends StatelessWidget {
  const _RestoreProgressPanel({
    required this.checking,
    required this.progress,
    required this.error,
    required this.done,
  });

  final bool checking;
  final FlashProgress? progress;
  final String? error;
  final bool done;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final p = progress;
    final failed = error != null;
    final title = failed
        ? 'RESTORE STOPPED'
        : done
        ? 'RESTORE COMPLETE'
        : checking
        ? 'CHECKING BACKUP'
        : _phaseLabel(p?.phase);
    final fraction = p == null || p.bytesTotal <= 0
        ? null
        : p.fraction.clamp(0.0, 1.0).toDouble();
    final accent = failed
        ? tokens.bad
        : done
        ? tokens.ok
        : tokens.accent;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                failed
                    ? Icons.error_outline
                    : done
                    ? Icons.check_circle_outline
                    : Icons.restore,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 8),
              _MonoLabel(title),
              const Spacer(),
              if (p != null && p.bytesTotal > 0)
                Text(
                  '${(p.fraction * 100).clamp(0, 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tXs,
                    color: tokens.text3,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          WizardProgressBar(
            fraction: failed || done ? 1.0 : fraction,
            animateStripes: !failed && !done,
          ),
          const SizedBox(height: 8),
          Text(
            failed
                ? error!
                : p == null
                ? 'Preparing restore.'
                : '${_formatBytes(p.bytesDone)} of '
                      '${_formatBytes(p.bytesTotal)}'
                      '${p.message == null ? '' : ' · ${p.message}'}',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tXs,
              color: failed ? tokens.bad : tokens.text3,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

List<_RestoreImage> _restoreImagesFrom({
  required List<EmmcBackupManifest> manifests,
  required List<EmmcBackupImageCandidate> candidates,
}) {
  final manifestPaths = {
    for (final manifest in manifests) manifest.imagePath.toLowerCase(),
  };
  final images = <_RestoreImage>[
    for (final manifest in manifests) _RestoreImage.manifest(manifest),
    for (final candidate in candidates)
      if (!manifestPaths.contains(candidate.imagePath.toLowerCase()))
        _RestoreImage.candidate(candidate),
  ];
  images.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  return images;
}

String _restoreImageTitle(_RestoreImage image) {
  final local = image.createdAt.toLocal();
  final stamp =
      '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
  final source = image.indexed ? 'indexed backup' : 'unindexed image';
  return '$stamp · ${_formatBytes(image.imageBytes)} · $source';
}

String _restoreImageSubtitle(_RestoreImage image) {
  final profile = image.profileId == null || image.profileId!.isEmpty
      ? 'unknown profile'
      : image.profileId!;
  if (image.indexed) {
    final sha = image.manifestSha256.length >= 12
        ? image.manifestSha256.substring(0, 12)
        : image.manifestSha256;
    return '$profile · sha256 $sha… · ${image.imagePath}';
  }
  return '$profile · unindexed image · ${image.imagePath}';
}

String _restoreDiskSubtitle(DiskInfo disk, _RestoreImage? image) {
  final parts = disk.partitions.isEmpty
      ? 'no partitions'
      : '${disk.partitions.length} partition'
            '${disk.partitions.length == 1 ? '' : 's'}';
  final match = !disk.removable
      ? 'not removable'
      : image != null && disk.sizeBytes < image.imageBytes
      ? 'target too small'
      : image?.diskIdentity?.matches(disk) == true
      ? 'matches backup'
      : image != null && disk.sizeBytes > image.imageBytes
      ? 'larger target'
      : 'manual target';
  return '$parts · ${diskTechnicalLabel(disk)} · $match';
}

bool _restoreDiskSelectable(DiskInfo disk, _RestoreImage? image) {
  if (!disk.removable) return false;
  if (image == null) return true;
  return disk.sizeBytes >= image.imageBytes;
}

final _sha256Re = RegExp(r'^[0-9a-f]{64}$');

bool _isSha256Hex(String value) => _sha256Re.hasMatch(value);

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 B';
  final gib = bytes / (1 << 30);
  if (gib >= 1) return '${gib.toStringAsFixed(2)} GiB';
  final mib = bytes / (1 << 20);
  if (mib >= 1) return '${mib.toStringAsFixed(1)} MiB';
  final kib = bytes / 1024;
  if (kib >= 1) return '${kib.toStringAsFixed(1)} KiB';
  return '$bytes B';
}

String _phaseLabel(FlashPhase? phase) => switch (phase) {
  FlashPhase.preparing => 'PREPARING RESTORE',
  FlashPhase.writing => 'WRITING IMAGE',
  FlashPhase.verifying => 'VERIFYING IMAGE',
  FlashPhase.done => 'RESTORE COMPLETE',
  FlashPhase.failed => 'RESTORE STOPPED',
  null => 'RESTORING IMAGE',
};

String _friendlyRestoreError(Object error) {
  final raw = error.toString();
  const prefix = 'Exception: ';
  final trimmed = raw.startsWith(prefix) ? raw.substring(prefix.length) : raw;
  return trimmed
      .replaceFirst('StateError: ', '')
      .replaceFirst('ElevatedHelperException: ', '');
}

// ---------------------------------------------------------------------
// Flash MCU tab — same honest stance.
// ---------------------------------------------------------------------
class _McuTab extends StatelessWidget {
  const _McuTab();
  @override
  Widget build(BuildContext context) {
    return const _ComingSoonPanel(
      label: 'FLASH MCU',
      body:
          'Per-MCU reflashing (toolhead, Z, accelerometer boards) needs '
          'a service abstraction Deckhand doesn\'t ship yet — DFU / CAN '
          'enumeration plus klipper-build orchestration. The wizard '
          'flashes the main board today; per-MCU flashing will arrive '
          'when the service exists. Tracking this rather than mocking '
          'fake rows.',
    );
  }
}

// ---------------------------------------------------------------------
// Re-run wizard tab — re-enters at choose-path with state preserved.
// ---------------------------------------------------------------------
class _ReRunWizardTab extends StatelessWidget {
  const _ReRunWizardTab();
  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _MonoLabel('RE-RUN WIZARD'),
          const SizedBox(height: 8),
          Text(
            'Jump back to choose-path with this printer\'s identity '
            'preserved. Use to repair, reconfigure, or migrate — the '
            'profile and host pin stay intact, you just re-pick the '
            'flow (stock-keep vs. fresh-flash).',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Re-run wizard'),
              onPressed: () => context.go('/choose-path'),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------

class _Panel extends StatelessWidget {
  const _Panel({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: child,
    );
  }
}

class _ComingSoonPanel extends StatelessWidget {
  const _ComingSoonPanel({required this.label, required this.body});
  final String label;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              _MonoLabel(label),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: tokens.ink2,
                  border: Border.all(color: tokens.line),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  'NOT YET WIRED',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 9,
                    color: tokens.text3,
                    letterSpacing: 0.1 * 9,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _MonoLabel extends StatelessWidget {
  const _MonoLabel(this.text);
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

class _Stat {
  const _Stat(this.k, this.v);
  final String k;
  final String v;
}

/// 2x2 grid of mono key/value pairs — the mockup's `done-stat-grid`
/// pattern. Used in the Status tab to lay out hostname, klippy
/// state, etc.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.stats});
  final List<_Stat> stats;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return GridView.count(
      crossAxisCount: 2,
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 4,
      children: [
        for (final s in stats)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: tokens.ink2,
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(DeckhandTokens.r2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _MonoLabel(s.k),
                const SizedBox(height: 4),
                Text(
                  s.v.isEmpty ? '—' : s.v,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tMd,
                    color: tokens.text,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

Future<void> _copyToClipboard(
  BuildContext context,
  String value,
  String message,
) async {
  await Clipboard.setData(ClipboardData(text: value));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
