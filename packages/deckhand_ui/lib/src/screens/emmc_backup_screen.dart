import 'dart:async';
import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/disk_display.dart';
import '../widgets/danger_card.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/wizard_progress_bar.dart';
import '../widgets/wizard_scaffold.dart';

const _backupRootMarker = '.deckhand-emmc-backups-root';
const _backupCanceledMessage = 'Backup canceled.';
final _technicalDiskMessageRe = RegExp(
  r'^(?:\\\\\.\\)?physicaldrive[0-9]+$',
  caseSensitive: false,
);

/// S148-emmc-backup — full-image dd backup of the printer's eMMC via
/// a USB-eMMC adapter on the host. Reached from the Snapshot screen's
/// "Back up the eMMC now" button. On success, sets the wizard
/// decision `snapshot.emmc_backup_path` and bounces back to /snapshot
/// with the eMMC-acknowledged checkbox auto-ticked.
class EmmcBackupScreen extends ConsumerStatefulWidget {
  const EmmcBackupScreen({super.key, this.returnRoute});

  /// Optional override for non-wizard entry points such as Manage.
  /// When omitted, the screen returns to the install route implied by
  /// the active wizard flow.
  final String? returnRoute;

  @override
  ConsumerState<EmmcBackupScreen> createState() => _EmmcBackupScreenState();
}

class _EmmcBackupScreenState extends ConsumerState<EmmcBackupScreen> {
  String? _selected;
  // True when the user already chose a disk upstream (flash-target),
  // so we skip the duplicate picker by default. They can expand it
  // via "Choose a different disk" if they actually want to swap.
  bool _hasInheritedPick = false;
  bool _showPicker = false;
  // User-chosen override for the backup destination dir. When set,
  // takes precedence over emmcBackupsDirProvider's default.
  String? _customDestDir;
  StreamSubscription<FlashProgress>? _readSub;
  FlashProgress? _progress;
  String? _error;
  bool _done = false;
  bool _canceling = false;
  bool _cancelRequested = false;
  String? _outputPath;
  DiskInfo? _backupDisk;
  int? _finalBytes;
  String? _finalSha256;
  DateTime? _throughputStartedAt;
  int _throughputStartedBytes = 0;
  double? _bytesPerSecond;

  @override
  void initState() {
    super.initState();
    // Inherit the disk pick from /flash-target if the user already
    // chose one upstream — otherwise the backup screen would force a
    // second pick of the same disk, which reads as a UI bug. The
    // user can still change it via the picker (Refresh resets), but
    // by default we trust the upstream decision. Disks themselves
    // come from the shared `disksProvider` so we don't re-fetch the
    // list when the parent screen already loaded it.
    final priorPick = ref
        .read(wizardControllerProvider)
        .state
        .decisions['flash.disk'];
    if (priorPick is String && priorPick.isNotEmpty) {
      _selected = priorPick;
      _hasInheritedPick = true;
      _showPicker = false;
    } else {
      _showPicker = true;
    }
  }

  @override
  void dispose() {
    _readSub?.cancel();
    super.dispose();
  }

  void _refreshDisks() {
    ref.invalidate(disksProvider);
    setState(() => _selected = null);
  }

  Future<void> _startBackup() async {
    await _readSub?.cancel();
    _readSub = null;
    _resetThroughput();

    final id = _selected;
    final helper = ref.read(elevatedHelperServiceProvider);
    final defaultDir = ref.read(emmcBackupsDirProvider);
    final dir = _customDestDir ?? defaultDir;
    if (id == null || dir == null) {
      setState(
        () => _error =
            'Cannot start: ${id == null ? "no disk selected" : "no destination dir"}',
      );
      return;
    }
    final usableDisk =
        (ref.read(disksProvider).valueOrNull ?? const <DiskInfo>[]).any(
          (disk) => disk.id == id && disk.removable,
        );
    if (!usableDisk) {
      setState(
        () => _error =
            'Cannot start: selected disk is no longer available as a removable disk',
      );
      return;
    }
    final controller = ref.read(wizardControllerProvider);
    final profileId = controller.state.profileId;
    final outputPath = emmcBackupImagePath(
      rootDir: dir,
      profileId: profileId,
      createdAt: DateTime.now().toUtc(),
    );
    try {
      Directory(p.dirname(outputPath)).createSync(recursive: true);
    } catch (_) {
      // Best effort only. The real helper and direct sidecar fallback
      // still validate/open the output path and surface a concrete
      // error if the directory is not writable.
    }

    // Look up the disk size from the cached enumeration so we can
    // (a) pass it as a --total-bytes hint to the elevated helper —
    // Windows raw devices report 0 from both Stat and Seek so without
    // this every progress event has bytes_total=0, and (b) seed the
    // first "preparing" card with the real denominator so the user
    // sees "0 B of 7.28 GiB" instead of "0 B of 0 B" while UAC pops.
    final disks = ref.read(disksProvider).value ?? const <DiskInfo>[];
    DiskInfo? backupDisk;
    var totalHint = 0;
    for (final d in disks) {
      if (d.id == id) {
        backupDisk = d;
        totalHint = d.sizeBytes;
        break;
      }
    }

    // Immediate "preparing" state so the user gets visual confirmation
    // the click was received. Without this, a few hundred ms of
    // spawning PowerShell + waiting for UAC reads as a dead button.
    setState(() {
      _progress = FlashProgress(
        bytesDone: 0,
        bytesTotal: totalHint,
        phase: FlashPhase.preparing,
        message: 'requesting elevation…',
      );
      _error = null;
      _done = false;
      _canceling = false;
      _cancelRequested = false;
      _outputPath = outputPath;
      _backupDisk = backupDisk;
      _finalBytes = null;
      _finalSha256 = null;
    });

    // Reading raw block devices needs admin on Windows (and root on
    // *nix). Prefer the elevated helper when it's wired so the read
    // actually succeeds; fall back to the in-process flash service
    // for environments where elevation already applies (Linux root
    // session, macOS pre-flight) or no helper is available (tests).
    Stream<FlashProgress> stream;
    try {
      if (helper != null) {
        final security = ref.read(securityServiceProvider);
        final token = await security.issueConfirmationToken(
          operation: 'disks.read_image',
          target: id,
        );
        if (!security.consumeToken(
          token.value,
          'disks.read_image',
          target: id,
        )) {
          throw StateError(
            'confirmation token was rejected before helper launch',
          );
        }
        stream = helper.readImage(
          diskId: id,
          outputPath: outputPath,
          confirmationToken: token.value,
          totalBytes: totalHint,
          outputRoot: dir,
        );
      } else {
        final flash = ref.read(flashServiceProvider);
        stream = flash.readImage(diskId: id, outputPath: outputPath);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not start backup: $e';
          _progress = const FlashProgress(
            bytesDone: 0,
            bytesTotal: 0,
            phase: FlashPhase.failed,
          );
        });
      }
      return;
    }

    _readSub = stream.listen(
      (event) {
        if (!mounted) return;
        setState(() {
          // Preserve bytesTotal across event updates. The helper's
          // intermediate `event: preparing` carries `bytes_total: 0`
          // (it's just a "device opened, about to read" sentinel),
          // and a naive replacement would wipe the seeded totalHint
          // from the disk picker. With the total gone the progress
          // card falls into its indeterminate path (fraction=null)
          // and the bar fills to 100% for one frame before the first
          // real `event: progress` arrives and snaps it back to ~0%.
          // Take the larger of (incoming, current) so a non-zero
          // value always wins over a placeholder zero.
          final priorTotal = _progress?.bytesTotal ?? 0;
          final mergedTotal = event.bytesTotal > 0
              ? event.bytesTotal
              : priorTotal;
          final merged = FlashProgress(
            bytesDone: event.bytesDone,
            bytesTotal: mergedTotal,
            phase: event.phase,
            message: event.message,
          );
          _recordProgressSample(merged);
          _progress = merged;
          if (event.phase == FlashPhase.done) {
            _done = true;
            _finalBytes = merged.bytesDone > 0 ? merged.bytesDone : mergedTotal;
            _finalSha256 = event.message;
          }
          if (event.phase == FlashPhase.failed && event.message != null) {
            _error = event.message;
          }
        });
      },
      onError: (Object e, StackTrace s) {
        if (!mounted) return;
        if (_cancelRequested) return;
        setState(() {
          _error = '$e';
          _progress = const FlashProgress(
            bytesDone: 0,
            bytesTotal: 0,
            phase: FlashPhase.failed,
          );
          _done = false;
        });
      },
      onDone: () {
        if (!mounted) return;
        if (_cancelRequested) return;
        // If the stream closed without ever yielding a `done` phase
        // and we haven't already recorded an error, surface that as
        // an error so the user doesn't sit looking at a forever-
        // "preparing" card. Common cause: UAC denied — PowerShell
        // exits cleanly with no helper output.
        if (!_done && _error == null) {
          setState(() {
            _error =
                'Backup ended with no completion event. Most likely the '
                'elevation prompt was denied or the helper exited early.';
            _progress = const FlashProgress(
              bytesDone: 0,
              bytesTotal: 0,
              phase: FlashPhase.failed,
            );
          });
        }
      },
    );
  }

  void _cancelBackup() {
    if (_readSub == null || _canceling) return;
    final sub = _readSub;
    _readSub = null;
    final last = _progress;
    final partialPath = _outputPath;

    setState(() {
      _canceling = true;
      _cancelRequested = true;
      _error = _backupCanceledMessage;
      _progress = FlashProgress(
        bytesDone: last?.bytesDone ?? 0,
        bytesTotal: last?.bytesTotal ?? 0,
        phase: FlashPhase.failed,
        message: 'canceled',
      );
      _done = false;
    });

    unawaited(
      Future<void>(() async {
        try {
          await sub?.cancel();
        } catch (_) {}
        if (partialPath != null) {
          await Future<void>.delayed(const Duration(milliseconds: 750));
          try {
            final f = File(partialPath);
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }),
    );
  }

  Future<void> _confirmAndReturn() async {
    final controller = ref.read(wizardControllerProvider);
    final outputPath = _outputPath;
    final disk = _backupDisk;
    final sha256 = _finalSha256;
    if (outputPath != null) {
      if (disk != null && _isSha256Hex(sha256)) {
        try {
          await ref.read(emmcBackupManifestWriterProvider)(
            EmmcBackupManifest.create(
              profileId: controller.state.profileId,
              imagePath: outputPath,
              imageBytes: _finalBytes ?? _progress?.bytesDone ?? 0,
              imageSha256: sha256!,
              disk: disk,
              deckhandVersion: ref.read(deckhandVersionProvider),
            ),
          );
          ref.invalidate(emmcBackupManifestsProvider);
        } catch (e) {
          if (!mounted) return;
          setState(() {
            _error =
                'Backup completed, but Deckhand could not write the '
                'verification manifest: $e';
            _done = false;
          });
          return;
        }
      } else {
        setState(() {
          _error =
              'Backup completed, but Deckhand did not receive a final '
              'SHA-256 from the helper. Retry so the image can be '
              'verified later.';
          _done = false;
        });
        return;
      }
      await controller.setDecision('snapshot.emmc_backup_path', outputPath);
    }
    await controller.setDecision('snapshot.emmc_acknowledged', true);
    if (mounted) context.go(_returnRoute());
  }

  /// Where to bounce back to after the backup finishes (or is
  /// cancelled). The flow tells us where the user came from:
  /// fresh-flash → /flash-confirm (the destructive S220 confirmation),
  /// stock-keep → /snapshot (the S145 banner that offered the backup).
  String _returnRoute() {
    final explicit = widget.returnRoute;
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final flow = ref.read(wizardControllerProvider).state.flow;
    return flow == WizardFlow.freshFlash ? '/flash-confirm' : '/snapshot';
  }

  /// Pop a native folder picker. Windows uses the .NET FolderBrowserDialog
  /// via PowerShell — no Flutter package dep, works on a stock Windows
  /// install. Returns the absolute path the user picked, or null on
  /// cancel/failure. macOS / Linux fall back to `osascript` / `zenity`
  /// when those tools are present; otherwise null (the user keeps the
  /// default path).
  Future<String?> _pickDirectory() async {
    try {
      if (Platform.isWindows) {
        // FolderBrowserDialog from System.Windows.Forms. The output is
        // the chosen path on stdout; cancel returns an empty string.
        const script =
            r'Add-Type -AssemblyName System.Windows.Forms;'
            r'$f = New-Object System.Windows.Forms.FolderBrowserDialog;'
            r'$f.Description = "Choose where to save the eMMC backup image";'
            r'if ($f.ShowDialog() -eq "OK") { Write-Output $f.SelectedPath }';
        final res = await Process.run('powershell.exe', [
          '-NoProfile',
          '-STA',
          '-Command',
          script,
        ]);
        final out = (res.stdout as String).trim();
        return out.isEmpty ? null : out;
      }
      if (Platform.isMacOS) {
        const script =
            'POSIX path of (choose folder with prompt "Choose where to save '
            'the eMMC backup image")';
        final res = await Process.run('osascript', ['-e', script]);
        final out = (res.stdout as String).trim();
        return out.isEmpty ? null : out;
      }
      // Linux: try zenity, then kdialog. Both are common but neither
      // is guaranteed; failure returns null and the user keeps the
      // default backup dir.
      for (final cmd in const [
        [
          'zenity',
          ['--file-selection', '--directory'],
        ],
        [
          'kdialog',
          ['--getexistingdirectory'],
        ],
      ]) {
        try {
          final res = await Process.run(
            cmd[0] as String,
            (cmd[1] as List).cast<String>(),
          );
          final out = (res.stdout as String).trim();
          if (out.isNotEmpty) return out;
        } catch (_) {
          // Try the next picker.
        }
      }
    } catch (_) {
      // Any failure leaves the default dir in place.
    }
    return null;
  }

  Future<String> _preparePickedBackupDir(String picked) async {
    final clean = p.normalize(picked);
    final root = p.basename(clean).toLowerCase() == 'emmc-backups'
        ? clean
        : p.join(clean, 'emmc-backups');
    await Directory(root).create(recursive: true);
    await File(
      p.join(root, _backupRootMarker),
    ).writeAsString('deckhand-emmc-backups/1\n', flush: true);
    return root;
  }

  void _resetThroughput() {
    _throughputStartedAt = null;
    _throughputStartedBytes = 0;
    _bytesPerSecond = null;
  }

  void _recordProgressSample(FlashProgress event) {
    if (event.phase != FlashPhase.writing ||
        event.bytesDone <= 0 ||
        event.bytesTotal <= 0) {
      return;
    }
    final now = DateTime.now();
    if (_throughputStartedAt == null ||
        event.bytesDone < _throughputStartedBytes) {
      _throughputStartedAt = now;
      _throughputStartedBytes = event.bytesDone;
      _bytesPerSecond = null;
      return;
    }
    final elapsedMs = now.difference(_throughputStartedAt!).inMilliseconds;
    final copied = event.bytesDone - _throughputStartedBytes;
    if (elapsedMs < 500 || copied <= 0) return;
    final average = copied / (elapsedMs / 1000.0);
    final prior = _bytesPerSecond;
    _bytesPerSecond = prior == null
        ? average
        : (prior * 0.65) + (average * 0.35);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final defaultDir = ref.watch(emmcBackupsDirProvider);
    final dir = _customDestDir ?? defaultDir;
    final copying = _progress != null && !_done && _error == null;
    final disksAsync = ref.watch(disksProvider);
    final disksFuture = ref.watch(disksProvider.future);
    final manifests =
        ref.watch(emmcBackupManifestsProvider).valueOrNull ??
        const <EmmcBackupManifest>[];
    final candidates =
        ref.watch(emmcBackupImageCandidatesProvider).valueOrNull ??
        const <EmmcBackupImageCandidate>[];
    final profileId = ref.watch(wizardControllerProvider).state.profileId;
    final selectedDisk = _selected == null
        ? null
        : _findDisk(disksAsync.valueOrNull ?? const <DiskInfo>[], _selected!);
    final existingManifest = selectedDisk == null
        ? null
        : findMatchingEmmcBackup(
            manifests: manifests,
            profileId: profileId,
            disk: selectedDisk,
          );
    final existingCandidate = selectedDisk == null
        ? null
        : findMatchingEmmcBackupImageCandidate(
            candidates: candidates,
            profileId: profileId,
            disk: selectedDisk,
          );
    final selectedDiskIsUsable =
        _selected != null &&
        !disksAsync.isLoading &&
        !disksAsync.hasError &&
        (disksAsync.valueOrNull ?? const <DiskInfo>[]).any(
          (disk) => disk.id == _selected && disk.removable,
        );
    final canStart = selectedDiskIsUsable && !copying && dir != null;

    // Failure flow gets its own focused layout — the destination row
    // and disk picker disappear, and the body is just the rich
    // danger card with diagnostics + recovery actions. Mirrors the
    // S230-fail (write-failed) treatment from the design language so
    // backup failures and write failures share one mental model.
    if (_error != null) {
      final pct = _failurePercent();
      final canceled = _error == _backupCanceledMessage;
      return WizardScaffold(
        screenId: 'S148-fail',
        title: canceled
            ? _backupCanceledMessage
            : (pct == null ? 'Backup failed.' : 'Backup failed at $pct%.'),
        helperText: canceled
            ? 'Deckhand stopped the copy. The eMMC itself is untouched.'
            : 'The eMMC itself is untouched — backups only read. '
                  'Reconnect the adapter and retry, or pick a different disk '
                  'if the issue keeps repeating.',
        body: _BackupFailedCard(
          tokens: tokens,
          progress: _progress,
          error: _error!,
          onBackToPicker: () {
            setState(() {
              _progress = null;
              _error = null;
              _done = false;
              _canceling = false;
              _cancelRequested = false;
              _outputPath = null;
              _backupDisk = null;
              _finalBytes = null;
              _finalSha256 = null;
              _showPicker = true;
              _selected = null;
            });
          },
          onRetry: () {
            setState(() {
              _progress = null;
              _error = null;
              _done = false;
              _canceling = false;
              _cancelRequested = false;
            });
            _startBackup();
          },
          onCopyError: () {
            Clipboard.setData(ClipboardData(text: _error!));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(
              const SnackBar(
                content: Text('Error details copied to clipboard'),
                duration: Duration(seconds: 2),
              ),
            );
          },
        ),
        // No primary/secondary actions on this state — the card owns
        // every recovery affordance so the action bar wouldn't add
        // anything except visual noise. The wizard scaffold's
        // bottom-bar disappears entirely when both lists are empty.
        secondaryActions: const [],
      );
    }

    return WizardScaffold(
      screenId: 'S148-emmc-backup',
      title: 'Back up the eMMC now.',
      helperText:
          'Connect the printer\'s eMMC to your computer via a USB '
          'adapter and pick it below. Deckhand will copy the entire '
          'disk to an image file you can `dd` back if anything goes '
          'wrong with the install.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DestinationRow(
            tokens: tokens,
            dir: dir,
            isCustom: _customDestDir != null,
            disabled: copying,
            onPick: () async {
              final picked = await _pickDirectory();
              if (picked != null && picked.isNotEmpty && mounted) {
                final prepared = await _preparePickedBackupDir(picked);
                if (mounted) setState(() => _customDestDir = prepared);
              }
            },
            onReset: _customDestDir == null
                ? null
                : () => setState(() => _customDestDir = null),
          ),
          if (!copying &&
              (existingManifest != null || existingCandidate != null)) ...[
            const SizedBox(height: 12),
            _ExistingBackupCard(
              tokens: tokens,
              manifest: existingManifest,
              candidate: existingCandidate,
            ),
          ],
          const SizedBox(height: 16),
          // If the user already chose the disk upstream (flash-target),
          // show a single "About to back up <disk>" card instead of
          // forcing them through the same picker again. The picker is
          // still one click away via "Choose a different disk".
          if (_hasInheritedPick && !_showPicker) ...[
            _InheritedPickCard(
              tokens: tokens,
              diskId: _selected ?? '',
              disksFuture: disksFuture,
              onChange: copying
                  ? null
                  : () => setState(() => _showPicker = true),
            ),
          ] else
            _DisksTable(
              disksFuture: disksFuture,
              selected: _selected,
              disabled: copying,
              onRefresh: _refreshDisks,
              onSelect: (id) => setState(() => _selected = id),
            ),
          // Render the progress card whenever a progress event has
          // landed (failure path is handled above with its own
          // dedicated layout, so this branch is just in-flight or
          // complete).
          if (_progress != null) ...[
            const SizedBox(height: 18),
            _ProgressCard(
              tokens: tokens,
              progress: _progress!,
              done: _done,
              error: null,
              outputPath: _outputPath,
              diskLabel: _backupDisk == null
                  ? null
                  : diskDisplayName(_backupDisk!),
              bytesPerSecond: _bytesPerSecond,
            ),
          ],
        ],
      ),
      primaryAction: _done
          ? WizardAction(label: 'Continue', onPressed: _confirmAndReturn)
          : WizardAction(
              label: copying ? 'Backing up…' : 'Back up this disk',
              onPressed: canStart ? _startBackup : null,
            ),
      secondaryActions: [
        WizardAction(
          label: _canceling ? 'Canceling…' : 'Cancel',
          isBack: true,
          onPressed: copying
              ? _cancelBackup
              : () {
                  context.go(_returnRoute());
                },
        ),
      ],
    );
  }

  /// Compute the failure-time percentage from the last progress event,
  /// for the screen title's "Backup failed at X%." label. Returns
  /// null when we don't have enough info to compute it (no progress
  /// recorded, or zero total).
  String? _failurePercent() {
    final p = _progress;
    if (p == null) return null;
    if (p.bytesTotal <= 0) return null;
    final pct = (p.bytesDone / p.bytesTotal) * 100;
    if (pct.isNaN || pct < 0) return null;
    return pct.toStringAsFixed(0);
  }

  bool _isSha256Hex(String? value) {
    if (value == null || value.length != 64) return false;
    return RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
  }

  DiskInfo? _findDisk(List<DiskInfo> disks, String id) {
    for (final disk in disks) {
      if (disk.id == id) return disk;
    }
    return null;
  }
}

class _ExistingBackupCard extends StatelessWidget {
  const _ExistingBackupCard({
    required this.tokens,
    required this.manifest,
    required this.candidate,
  });

  final DeckhandTokens tokens;
  final EmmcBackupManifest? manifest;
  final EmmcBackupImageCandidate? candidate;

  @override
  Widget build(BuildContext context) {
    final path = manifest?.imagePath ?? candidate?.imagePath ?? '';
    final indexed = manifest != null;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.ok.withValues(alpha: 0.06),
        border: Border.all(color: tokens.ok.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_outline, size: 17, color: tokens.ok),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  indexed
                      ? 'Indexed backup already exists'
                      : 'Complete backup already exists',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    fontWeight: FontWeight.w600,
                    color: tokens.ok,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  indexed
                      ? 'Deckhand found a manifest for this disk. You can still make another backup if you want a newer rollback point.'
                      : 'Deckhand found a full-size image for this disk. Verify it on the previous screen to index it as an exact rollback image.',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tXs,
                    color: tokens.text2,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  path,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DisksTable extends StatelessWidget {
  const _DisksTable({
    required this.disksFuture,
    required this.selected,
    required this.disabled,
    required this.onSelect,
    required this.onRefresh,
  });

  final Future<List<DiskInfo>>? disksFuture;
  final String? selected;
  final bool disabled;
  final void Function(String id) onSelect;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
            decoration: BoxDecoration(
              color: tokens.ink2,
              border: Border(bottom: BorderSide(color: tokens.line)),
            ),
            child: Row(
              children: [
                Text(
                  'REMOVABLE DISKS',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text3,
                    letterSpacing: 0.1 * 10,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: disabled ? null : onRefresh,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text('Refresh'),
                ),
              ],
            ),
          ),
          FutureBuilder<List<DiskInfo>>(
            future: disksFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: DeckhandSpinner(size: 24, strokeWidth: 2),
                  ),
                );
              }
              if (snap.hasError) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'Error listing disks: ${snap.error}',
                    style: TextStyle(color: tokens.bad),
                  ),
                );
              }
              final disks = (snap.data ?? const <DiskInfo>[])
                  .where((d) => d.removable)
                  .toList();
              if (disks.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    'No removable disks reported. Plug in your USB-eMMC '
                    'adapter and tap Refresh.',
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontSans,
                      fontSize: DeckhandTokens.tSm,
                      color: tokens.text3,
                    ),
                  ),
                );
              }
              return Column(
                children: [
                  for (var i = 0; i < disks.length; i++)
                    _DiskRow(
                      disk: disks[i],
                      isLast: i == disks.length - 1,
                      selected: selected == disks[i].id,
                      onTap: disabled ? null : () => onSelect(disks[i].id),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DiskRow extends StatelessWidget {
  const _DiskRow({
    required this.disk,
    required this.isLast,
    required this.selected,
    required this.onTap,
  });
  final DiskInfo disk;
  final bool isLast;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final mountpoints = disk.partitions
        .map((p) => p.mountpoint)
        .whereType<String>()
        .where((m) => m.isNotEmpty)
        .join(', ');
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? tokens.ink2 : Colors.transparent,
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: tokens.lineSoft)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              child: Center(
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: selected ? tokens.accent : tokens.rule,
                      width: selected ? 5 : 1.5,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 4,
              child: Text(
                diskDisplayName(disk),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                disk.bus.isEmpty ? '—' : disk.bus,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text2,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                _formatSize(disk.sizeBytes),
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text2,
                ),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                mountpoints.isEmpty ? '—' : mountpoints,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.text2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    final gib = bytes / (1 << 30);
    if (gib >= 1) return '${gib.toStringAsFixed(2)} GiB';
    final mib = bytes / (1 << 20);
    return '${mib.toStringAsFixed(0)} MiB';
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.tokens,
    required this.progress,
    required this.done,
    required this.error,
    required this.outputPath,
    required this.diskLabel,
    required this.bytesPerSecond,
  });
  final DeckhandTokens tokens;
  final FlashProgress progress;
  final bool done;
  final String? error;
  final String? outputPath;
  final String? diskLabel;
  final double? bytesPerSecond;

  @override
  Widget build(BuildContext context) {
    final fraction = progress.bytesTotal == 0
        ? null
        : (progress.bytesDone / progress.bytesTotal).clamp(0.0, 1.0);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                // "Copying disk" reads as the user's intent (we're
                // making a copy of the eMMC onto your computer).
                // "Reading disk" was the I/O verb — accurate but
                // jargon-y; users don't think about reads, they
                // think about backups.
                error != null
                    ? 'BACKUP FAILED'
                    : (done ? 'BACKUP COMPLETE' : 'COPYING DISK'),
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: 10,
                  color: error != null
                      ? tokens.bad
                      : (done ? tokens.ok : tokens.text3),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1 * 10,
                ),
              ),
              const Spacer(),
              if (fraction != null)
                Text(
                  '${(fraction * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text3,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
          WizardProgressBar(fraction: done ? 1.0 : fraction),
          const SizedBox(height: 10),
          Text(
            error ??
                (done ? 'Image written to $outputPath' : _progressDetail()),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: DeckhandTokens.tXs,
              color: error != null ? tokens.bad : tokens.text3,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  String _progressDetail() {
    final copied =
        '${_humanBytes(progress.bytesDone)} of '
        '${_humanBytes(progress.bytesTotal)}';
    final parts = <String>[copied];
    final bps = bytesPerSecond;
    if (bps != null &&
        bps > 0 &&
        progress.bytesTotal > 0 &&
        progress.bytesDone > 0) {
      final remainingBytes = progress.bytesTotal - progress.bytesDone;
      final remaining = remainingBytes <= 0
          ? Duration.zero
          : Duration(seconds: (remainingBytes / bps).ceil());
      parts
        ..add('${_humanBytes(bps.round())}/s')
        ..add('ETA ${_formatDuration(remaining)}');
    }
    final label = diskLabel?.trim();
    if (label != null && label.isNotEmpty) parts.add(label);
    final helperMessage = _userFacingHelperMessage(progress.message);
    if (helperMessage != null && helperMessage != label) {
      parts.add(helperMessage);
    }
    return parts.join(' · ');
  }

  String? _userFacingHelperMessage(String? message) {
    final value = message?.trim();
    if (value == null || value.isEmpty) return null;
    final compact = value.replaceAll(RegExp(r'[\s_-]+'), '');
    if (_technicalDiskMessageRe.hasMatch(compact)) return null;
    return value;
  }

  String _formatDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    if (totalSeconds <= 0) return 'now';
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) return '${hours}h ${minutes}m';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    const units = ['KiB', 'MiB', 'GiB', 'TiB'];
    double v = bytes / 1024.0;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024.0;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
  }
}

/// Compact card shown when the user already chose a disk on the
/// flash-target screen. Resolves the disk metadata from the same
/// listDisks() future so we can show "Generic STORAGE DEVICE · USB ·
/// 7.28 GiB" instead of just the opaque device id.
class _InheritedPickCard extends StatelessWidget {
  const _InheritedPickCard({
    required this.tokens,
    required this.diskId,
    required this.disksFuture,
    required this.onChange,
  });
  final DeckhandTokens tokens;
  final String diskId;
  final Future<List<DiskInfo>>? disksFuture;
  final VoidCallback? onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "ABOUT TO BACK UP",
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text4,
              letterSpacing: 0.1 * 10,
            ),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<DiskInfo>>(
            future: disksFuture,
            builder: (context, snap) {
              // While listDisks() is in flight, show a small spinner +
              // muted "resolving disk…" line instead of the raw
              // PhysicalDriveN id. Without this, the card flashed the
              // opaque id for ~100ms before swapping to the friendly
              // model/bus/size label, which read as a UI flicker.
              if (snap.connectionState != ConnectionState.done) {
                return Row(
                  children: [
                    DeckhandSpinner(
                      size: 12,
                      strokeWidth: 1.5,
                      color: tokens.text4,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      'resolving disk…',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tMd,
                        color: tokens.text3,
                      ),
                    ),
                  ],
                );
              }
              final disks = snap.data ?? const <DiskInfo>[];
              DiskInfo? match;
              for (final d in disks) {
                if (d.id == diskId) {
                  match = d;
                  break;
                }
              }
              if (match == null) {
                return Text(
                  'Selected disk is no longer connected',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tMd,
                    color: tokens.warn,
                  ),
                );
              }
              final label = diskDisplaySummary(match);
              return Text(
                label,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tMd,
                  color: tokens.text,
                ),
              );
            },
          ),
          const SizedBox(height: 4),
          Text(
            "Inherited from the disk you picked on the previous screen.",
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tXs,
              color: tokens.text3,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              TextButton.icon(
                onPressed: onChange,
                icon: const Icon(Icons.edit_outlined, size: 14),
                label: const Text("Choose a different disk"),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// "Image will be written to: `<path>`" + a "Change…" button that pops
/// the OS folder picker. Lets the user route the backup to an
/// external drive (USB stick, NAS mount) instead of the default
/// AppData location, since the image can run several GiB.
class _DestinationRow extends StatelessWidget {
  const _DestinationRow({
    required this.tokens,
    required this.dir,
    required this.isCustom,
    required this.disabled,
    required this.onPick,
    required this.onReset,
  });

  final DeckhandTokens tokens;
  final String? dir;
  final bool isCustom;
  final bool disabled;
  final Future<void> Function() onPick;
  final VoidCallback? onReset;

  @override
  Widget build(BuildContext context) {
    final color = dir == null ? tokens.warn : tokens.info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            dir == null ? Icons.warning_amber_rounded : Icons.folder_outlined,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dir == null
                      ? 'Backup destination not configured'
                      : 'Image will be written to:',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tXs,
                    color: tokens.text3,
                  ),
                ),
                if (dir != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    dir!,
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontMono,
                      fontSize: DeckhandTokens.tSm,
                      color: tokens.text,
                    ),
                  ),
                  if (isCustom) ...[
                    const SizedBox(height: 2),
                    Text(
                      'custom destination · click "Use default" to revert',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: 10,
                        color: tokens.text4,
                      ),
                    ),
                  ],
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (isCustom && onReset != null) ...[
            TextButton(
              onPressed: disabled ? null : onReset,
              child: const Text('Use default'),
            ),
            const SizedBox(width: 4),
          ],
          OutlinedButton.icon(
            onPressed: disabled ? null : () => onPick(),
            icon: const Icon(Icons.folder_open, size: 14),
            label: const Text('Change…'),
          ),
        ],
      ),
    );
  }
}

/// Rich failure card for the backup flow — design-language sibling
/// of the S230-fail write-failed treatment. Diagonal-hashed danger
/// surface with:
///
///  * Header pill ("RECOVERABLE · BACKUP INCOMPLETE")
///  * Two-column stat strip (COPIED BEFORE FAIL / ERROR)
///  * LIKELY CAUSES bullet list (derived from the error keywords)
///  * Action row: Copy error · Back to disk picker · Retry
///
/// Inherits [DangerCard] for the hash backdrop so the visual stays
/// consistent with the flash-confirm danger surface.
class _BackupFailedCard extends StatelessWidget {
  const _BackupFailedCard({
    required this.tokens,
    required this.progress,
    required this.error,
    required this.onBackToPicker,
    required this.onRetry,
    required this.onCopyError,
  });

  final DeckhandTokens tokens;
  final FlashProgress? progress;
  final String error;
  final VoidCallback onBackToPicker;
  final VoidCallback onRetry;
  final VoidCallback onCopyError;

  @override
  Widget build(BuildContext context) {
    final causes = _likelyCauses(error);
    return DangerCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 16, color: tokens.bad),
              const SizedBox(width: 8),
              Text(
                'RECOVERABLE · BACKUP INCOMPLETE',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: DeckhandTokens.tXs,
                  color: tokens.bad,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1 * DeckhandTokens.tXs,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Two-column stat strip. COPIED renders an em-dash when no
          // progress event landed (helper failed before the first
          // read); ERROR is always present.
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _StatBlock(
                  tokens: tokens,
                  label: 'COPIED BEFORE FAIL',
                  value: _copiedLabel(progress),
                  bad: false,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _StatBlock(
                  tokens: tokens,
                  label: 'ERROR',
                  value: _shortError(error),
                  bad: true,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Likely-causes bullets — tied to keywords in the error
          // string so the user gets specific advice when we can
          // recognise the failure mode.
          Container(
            decoration: BoxDecoration(
              color: tokens.ink2,
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(DeckhandTokens.r2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  decoration: BoxDecoration(
                    border: Border(bottom: BorderSide(color: tokens.lineSoft)),
                  ),
                  child: Text(
                    'LIKELY CAUSES',
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontMono,
                      fontSize: 10,
                      color: tokens.text3,
                      letterSpacing: 0.1 * 10,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final c in causes) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(top: 6),
                                child: Container(
                                  width: 4,
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: tokens.text3,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  c,
                                  style: TextStyle(
                                    fontFamily: DeckhandTokens.fontSans,
                                    fontSize: DeckhandTokens.tSm,
                                    color: tokens.text2,
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          // Actions row. Copy-error sits left because it's the
          // diagnostic affordance (least destructive); Back/Retry
          // anchor the right because that's where the user's eye
          // travels after reading the causes panel.
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('Copy error'),
                onPressed: onCopyError,
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.arrow_back, size: 14),
                label: const Text('Back to disk picker'),
                onPressed: onBackToPicker,
              ),
              FilledButton.icon(
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text('Retry from 0%'),
                onPressed: onRetry,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Pretty value for the COPIED-BEFORE-FAIL stat tile.
  static String _copiedLabel(FlashProgress? p) {
    if (p == null || p.bytesDone <= 0) return '—';
    final done = _humanBytes(p.bytesDone);
    if (p.bytesTotal > 0) {
      return '$done of ${_humanBytes(p.bytesTotal)}';
    }
    return done;
  }

  /// Single-line summary of the error for the ERROR stat tile.
  /// Long multi-line errors get clipped to first line + ellipsis.
  static String _shortError(String e) {
    final firstLine = e.split('\n').first.trim();
    if (firstLine.length <= 80) return firstLine;
    return '${firstLine.substring(0, 77)}…';
  }

  /// Map error-message keywords to a 2-3 item likely-causes list.
  /// Catch-all defaults err on the side of the most common failure
  /// modes for the eMMC-over-USB-adapter scenario this screen
  /// targets.
  static List<String> _likelyCauses(String e) {
    final s = e.toLowerCase();
    if (s.contains('never started') ||
        s.contains('uac') ||
        s.contains('antivirus') ||
        s.contains('quarantine')) {
      return const [
        'UAC prompt was suppressed or denied — re-launch Deckhand and approve the elevation request.',
        'Antivirus quarantined the elevated helper — add Deckhand\'s install directory to the AV exclusion list.',
        'Helper binary missing — reinstall Deckhand or verify deckhand-elevated-helper.exe sits next to deckhand.exe.',
      ];
    }
    if (s.contains('access is denied') || s.contains('access denied')) {
      return const [
        'The disk is mounted by Windows — close any File Explorer window pointing at it.',
        'Another process is holding the device — disconnect and reconnect the USB adapter.',
        'The user account doesn\'t have raw-device access — check that UAC granted admin on the prompt.',
      ];
    }
    if (s.contains('no space') || s.contains('disk full')) {
      return const [
        'The destination drive ran out of space — pick a different destination via the "Change…" button.',
        'A previous failed backup left a partial image — delete old .img files in the destination folder.',
      ];
    }
    if (s.contains('backup canceled') ||
        s.contains('operation canceled by user')) {
      return const [
        'Deckhand stopped the copy before it finished.',
        'Any partial image in the destination folder can be deleted.',
      ];
    }
    if (s.contains('the operation was canceled by the user') ||
        s.contains('cancelled by the user')) {
      return const [
        'You clicked "No" on the UAC prompt — click Retry and approve it this time to continue.',
      ];
    }
    if (s.contains('sector') ||
        s.contains('i/o') ||
        s.contains('read device')) {
      return const [
        'USB adapter disconnected mid-copy — reseat the cable and the eMMC module.',
        'eMMC has bad sectors — try a different module if the failure repeats at the same offset.',
        'Adapter overreports the disk size — typically harmless, but a hard error means reseat and retry.',
      ];
    }
    return const [
      'USB adapter disconnected mid-copy — reseat the cable and the eMMC module.',
      'Antivirus or endpoint security blocked the elevated helper — check your security tool\'s quarantine.',
      'Destination drive ran out of space — pick a different destination via the "Change…" button.',
    ];
  }

  static String _humanBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024) return '$bytes B';
    const units = ['KiB', 'MiB', 'GiB', 'TiB'];
    double v = bytes / 1024.0;
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024.0;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 ? 1 : 0)} ${units[i]}';
  }
}

class _StatBlock extends StatelessWidget {
  const _StatBlock({
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
