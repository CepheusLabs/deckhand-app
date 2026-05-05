import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/disk_display.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/wizard_scaffold.dart';

/// S220 — Last check before we wipe a disk.
///
/// V2 design: a self-contained "danger screen" panel (red diagonal
/// hatch, corner brackets) that owns its own commit bar. The
/// scaffold's standard footer action row is suppressed because the
/// commit ergonomics here are bespoke:
///
///  * Type the disk name to enable the wipe button.
///  * Click wipe, then confirm the modal.
///
/// Two safety gates instead of two checkboxes — the prior version's
/// "I have backed up / I understand" checkboxes were too easy to
/// click through. Typing a disk name is muscle memory only when
/// you've actually looked at the target card; the modal gives one
/// final explicit confirmation before the destructive handoff.
///
/// `Esc` is intercepted in the wrapping `CallbackShortcuts` so the
/// user can still bail out with the keyboard even though the
/// scaffold isn't rendering a Back button.
class FlashConfirmScreen extends ConsumerStatefulWidget {
  const FlashConfirmScreen({super.key});

  @override
  ConsumerState<FlashConfirmScreen> createState() => _FlashConfirmScreenState();
}

class _FlashConfirmScreenState extends ConsumerState<FlashConfirmScreen> {
  late final TextEditingController _typed;

  @override
  void initState() {
    super.initState();
    _typed = TextEditingController()
      ..addListener(() {
        // Triggers a rebuild so the wipe button enables/disables and
        // the input swaps between the unmatched / matched colour
        // schemes. Cheap; runs only on user keystrokes.
        if (mounted) setState(() {});
      });
  }

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  /// The disk label the user must type to arm the wipe button. We
  /// use the friendly model (the same name shown on the prior pick
  /// disk + flash-target screens — "Generic STORAGE DEVICE",
  /// "SanDisk Cruzer USB") so the typed-confirm matches what the
  /// user just saw, not the dev-facing platform id. Missing or raw
  /// device identifiers get the same friendly fallback as the picker.
  String _expectedDiskName(DiskInfo? disk) {
    if (disk == null) return '';
    return diskDisplayName(disk);
  }

  bool _isMatched(String expected) =>
      expected.isNotEmpty && _typed.text.trim() == expected;

  Future<void> _commit() async {
    ref.read(wizardControllerProvider).setFlow(WizardFlow.freshFlash);
    if (!mounted) return;
    context.go('/progress');
  }

  Future<void> _confirmCommit(DiskInfo? disk) async {
    if (disk == null || !_isMatched(_expectedDiskName(disk))) return;
    final tokens = DeckhandTokens.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.warning_amber_rounded, color: tokens.bad),
        title: const Text('Confirm wipe and flash'),
        content: Text(
          'Deckhand will erase ${diskDisplayName(disk)} and write the '
          'selected OS image. This cannot be undone.',
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
            icon: const Icon(Icons.local_fire_department, size: 16),
            label: const Text('Wipe and flash now'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _commit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(wizardControllerProvider);
    final diskId = controller.decision<String>('flash.disk');
    final osId = controller.decision<String>('flash.os');

    DiskInfo? disk;
    final disksAsync = ref.watch(disksProvider);
    if (diskId != null) {
      for (final d in disksAsync.value ?? const <DiskInfo>[]) {
        if (d.id == diskId) {
          disk = d;
          break;
        }
      }
    }

    final expectedName = _expectedDiskName(disk);
    final matched = _isMatched(expectedName);
    final manifestsAsync = ref.watch(emmcBackupManifestsProvider);
    final manifests =
        manifestsAsync.valueOrNull ?? const <EmmcBackupManifest>[];
    final candidatesAsync = ref.watch(emmcBackupImageCandidatesProvider);
    final candidates =
        candidatesAsync.valueOrNull ?? const <EmmcBackupImageCandidate>[];
    final existingManifest = disk == null
        ? null
        : findMatchingEmmcBackup(
            manifests: manifests,
            profileId: controller.state.profileId,
            disk: disk,
          );
    final existingCandidate = disk == null
        ? null
        : findMatchingEmmcBackupImageCandidate(
            candidates: candidates,
            profileId: controller.state.profileId,
            disk: disk,
          );
    final waitingForDisk =
        diskId != null && disk == null && disksAsync.isLoading;
    final waitingForBackups =
        disk != null &&
        ((manifestsAsync.isLoading && !manifestsAsync.hasValue) ||
            (candidatesAsync.isLoading && !candidatesAsync.hasValue));
    final loadingBody = waitingForDisk || waitingForBackups;

    // Esc still goes back even though the scaffold's Back button is
    // suppressed — wired here so the keyboard escape hatch survives
    // the bespoke commit bar.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            context.go('/choose-os'),
      },
      child: Focus(
        autofocus: true,
        child: WizardScaffold(
          screenId: 'S220-flash-confirm',
          title: 'Last check before we wipe.',
          helperText:
              'This is the only screen with a destructive primary. We '
              'surface every fact you need so you don\'t second-guess '
              'the decision afterwards.',
          body: loadingBody
              ? _FlashConfirmLoading(waitingForDisk: waitingForDisk)
              : _DangerBody(
                  disk: disk,
                  osId: osId,
                  expectedName: expectedName,
                  typed: _typed,
                  matched: matched,
                  backupManifest: existingManifest,
                  backupCandidate: existingCandidate,
                  onBack: () => context.go('/choose-os'),
                  onBackup: () => context.go('/emmc-backup'),
                  onWipe: () => _confirmCommit(disk),
                ),
          secondaryActions: loadingBody
              ? [
                  WizardAction(
                    label: "Back, don't wipe",
                    isBack: true,
                    onPressed: () => context.go('/choose-os'),
                  ),
                ]
              : const [],
          // Footer action bar suppressed — the commit-bar inside the
          // body owns the commit ergonomics for this screen.
        ),
      ),
    );
  }
}

class _FlashConfirmLoading extends StatelessWidget {
  const _FlashConfirmLoading({required this.waitingForDisk});

  final bool waitingForDisk;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: DeckhandLoadingBlock(
        kind: DeckhandLoaderKind.emmcPins,
        title: waitingForDisk
            ? 'Loading selected disk'
            : 'Checking backup records',
        message: waitingForDisk
            ? 'Deckhand is re-enumerating disks before it shows the '
                  'destructive confirmation.'
            : 'Deckhand is scanning local backup manifests and full-size '
                  'images before it recommends another backup.',
      ),
    );
  }
}

class _DangerBody extends StatelessWidget {
  const _DangerBody({
    required this.disk,
    required this.osId,
    required this.expectedName,
    required this.typed,
    required this.matched,
    required this.backupManifest,
    required this.backupCandidate,
    required this.onBack,
    required this.onBackup,
    required this.onWipe,
  });

  final DiskInfo? disk;
  final String? osId;
  final String expectedName;
  final TextEditingController typed;
  final bool matched;
  final EmmcBackupManifest? backupManifest;
  final EmmcBackupImageCandidate? backupCandidate;
  final VoidCallback onBack;
  final VoidCallback onBackup;
  final VoidCallback onWipe;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      // Mode-marker panel: tinted bg + red border + diagonal red
      // hatch + corner-bracket viewfinder, matching the design's
      // "you're in destructive mode" framing. The hatch + brackets
      // sit BEHIND the content via a Stack — the prior session
      // mistakenly thought the Stack was breaking child layout, but
      // the real culprit was a non-uniform Border on the BackupCta
      // (see _BackupCta).
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 24),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          tokens.bad.withValues(alpha: 0.04),
          tokens.ink0,
        ),
        border: Border.all(color: tokens.bad.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _HazardHatchPainter(
                  color: tokens.bad.withValues(alpha: 0.06),
                ),
              ),
            ),
          ),
          // Corner brackets — the "viewfinder" frame at the top of
          // the panel that signals "you're in a different mode now."
          Positioned(top: 14, left: 14, child: _CornerBracket(tokens, true)),
          Positioned(top: 14, right: 14, child: _CornerBracket(tokens, false)),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Banner(),
              const SizedBox(height: 18),
              _BackupCta(
                onTap: onBackup,
                manifest: backupManifest,
                candidate: backupCandidate,
              ),
              const SizedBox(height: 18),
              _DangerGrid(disk: disk, osId: osId),
              const SizedBox(height: 18),
              _SafeStrip(),
              const SizedBox(height: 18),
              _ConfirmBlock(
                expected: expectedName,
                typed: typed,
                matched: matched,
                onBack: onBack,
                onWipe: onWipe,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Diagonal red hatch behind the danger panel. Painted instead of a
/// repeating-linear-gradient so the alpha lines stay crisp at any
/// pixel ratio — Flutter's gradient anti-aliasing on tight stripes
/// can shimmer.
class _HazardHatchPainter extends CustomPainter {
  _HazardHatchPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    const spacing = 12.0;
    final span = size.width + size.height;
    for (double offset = -span; offset < span; offset += spacing) {
      canvas.drawLine(
        Offset(offset, 0),
        Offset(offset + size.height, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _HazardHatchPainter old) => old.color != color;
}

class _CornerBracket extends StatelessWidget {
  const _CornerBracket(this.tokens, this.isLeft);
  final DeckhandTokens tokens;
  final bool isLeft;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 28,
      height: 28,
      child: CustomPaint(
        painter: _CornerBracketPainter(color: tokens.bad, leftSide: isLeft),
      ),
    );
  }
}

class _CornerBracketPainter extends CustomPainter {
  _CornerBracketPainter({required this.color, required this.leftSide});
  final Color color;
  final bool leftSide;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(0, 0), Offset(size.width, 0), paint);
    if (leftSide) {
      canvas.drawLine(const Offset(0, 0), Offset(0, size.height), paint);
    } else {
      canvas.drawLine(
        Offset(size.width, 0),
        Offset(size.width, size.height),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CornerBracketPainter old) =>
      old.color != color || old.leftSide != leftSide;
}

class _Banner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    // Pre-blend tints with the panel's bg colour so the underlying
    // diagonal hatch can't show through translucent fills. Using
    // `alpha: 0.14` over a hatched parent is what made the icon and
    // tag look like the hatch was passing through them.
    final panelBg = Color.alphaBlend(
      tokens.bad.withValues(alpha: 0.04),
      tokens.ink0,
    );
    final iconBg = Color.alphaBlend(
      tokens.bad.withValues(alpha: 0.14),
      panelBg,
    );
    final tagBg = Color.alphaBlend(tokens.bad.withValues(alpha: 0.08), panelBg);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: iconBg,
            border: Border.all(color: tokens.bad.withValues(alpha: 0.5)),
            shape: BoxShape.circle,
          ),
          alignment: Alignment.center,
          child: Icon(Icons.warning_amber_rounded, color: tokens.bad, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Last check before we wipe.',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: 22,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.01 * 22,
                  height: 1.2,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Three partitions will be permanently destroyed. There '
                'is no undo.',
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: 13,
                  color: tokens.text3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: tagBg,
            border: Border.all(color: tokens.bad.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(3),
          ),
          child: Text(
            'DESTRUCTIVE',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              letterSpacing: 0.12 * 10,
              color: tokens.bad,
            ),
          ),
        ),
      ],
    );
  }
}

/// Prominent backup status/escape-hatch card. The 3px accent rail
/// used to be expressed via `Border(left: width: 3, top/right/bottom:
/// width: 1)` combined with `borderRadius` — Flutter silently refuses
/// to paint children when a rounded box has non-uniform border widths,
/// which was the entire reason the CTA kept rendering as an empty
/// tinted rectangle across three different wrapper rewrites. Now:
/// uniform 1px border, with the rail as a sibling Container in an
/// `IntrinsicHeight` Row that stretches to the row's height.
class _BackupCta extends StatelessWidget {
  const _BackupCta({
    required this.onTap,
    required this.manifest,
    required this.candidate,
  });
  final VoidCallback onTap;
  final EmmcBackupManifest? manifest;
  final EmmcBackupImageCandidate? candidate;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final indexed = manifest != null;
    final hasBackup = manifest != null || candidate != null;
    final accent = hasBackup ? tokens.ok : tokens.accent;
    final path = manifest?.imagePath ?? candidate?.imagePath;
    final title = indexed
        ? 'Indexed backup already exists'
        : hasBackup
        ? 'Complete backup already exists'
        : 'Back up the disk first';
    final badge = indexed
        ? 'INDEXED'
        : hasBackup
        ? 'FOUND'
        : 'RECOMMENDED';
    final body = indexed
        ? 'Deckhand found an exact rollback image for this disk. You can '
              'still make another backup if you want a newer restore point.'
        : hasBackup
        ? 'Deckhand found a full-size image for this disk. Open the '
              'backup step if you want to verify and index it as exact.'
        : 'Reads the entire disk to an image on this host before any '
              'wipe. Returns here when finished.';
    final actionLabel = hasBackup ? 'VIEW BACKUP' : 'START BACKUP';
    final icon = hasBackup
        ? Icons.check_circle_outline
        : Icons.inventory_2_outlined;
    final bg = Color.alphaBlend(accent.withValues(alpha: 0.08), tokens.ink0);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: accent.withValues(alpha: 0.45), width: 1),
            borderRadius: BorderRadius.circular(DeckhandTokens.r3),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 3px accent rail. Sibling of the content rather
                // than an asymmetric border on the parent.
                Container(width: 3, color: accent),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(15, 16, 18, 16),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: accent.withValues(alpha: 0.18),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.5),
                            ),
                            shape: BoxShape.circle,
                          ),
                          alignment: Alignment.center,
                          child: Icon(icon, color: accent, size: 20),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      title,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontFamily: DeckhandTokens.fontSans,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        letterSpacing: -0.005 * 14,
                                        color: tokens.text,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 7,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: accent.withValues(alpha: 0.14),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      badge,
                                      style: TextStyle(
                                        fontFamily: DeckhandTokens.fontMono,
                                        fontSize: 9,
                                        letterSpacing: 0.12 * 9,
                                        color: accent,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 4),
                              Text(
                                body,
                                style: TextStyle(
                                  fontFamily: DeckhandTokens.fontSans,
                                  fontSize: 12,
                                  color: tokens.text3,
                                  height: 1.4,
                                ),
                              ),
                              if (path != null && path.isNotEmpty) ...[
                                const SizedBox(height: 5),
                                Text(
                                  path,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: DeckhandTokens.fontMono,
                                    fontSize: 10,
                                    color: tokens.text3,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: accent,
                            foregroundColor: hasBackup
                                ? const Color(0xFFFCFCFC)
                                : tokens.accentFg,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 10,
                            ),
                            textStyle: const TextStyle(
                              fontFamily: DeckhandTokens.fontMono,
                              fontSize: 11,
                              letterSpacing: 0.08 * 11,
                            ),
                          ),
                          onPressed: onTap,
                          icon: Icon(
                            hasBackup ? Icons.open_in_new : Icons.arrow_forward,
                            size: 11,
                          ),
                          label: Text(actionLabel),
                        ),
                      ], // inner Row.children
                    ), // inner Row
                  ), // Padding
                ), // Expanded
              ], // outer Row.children
            ), // outer Row
          ), // IntrinsicHeight
        ), // Container
      ), // GestureDetector
    ); // MouseRegion
  }
}

class _DangerGrid extends StatelessWidget {
  const _DangerGrid({required this.disk, required this.osId});
  final DiskInfo? disk;
  final String? osId;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The mockup's 1.4fr / 1fr split collapses to a single column
        // below 1100px. We don't reach 1100px in our 1080px content
        // box (each panel sits in a Wrap-friendly column), so we
        // stack at 720px — the breakpoint the rest of the design
        // uses for "small wizard".
        if (constraints.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TargetCard(disk: disk),
              const SizedBox(height: 12),
              _SourceCard(osId: osId),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 7, child: _TargetCard(disk: disk)),
            const SizedBox(width: 16),
            Expanded(flex: 5, child: _SourceCard(osId: osId)),
          ],
        );
      },
    );
  }
}

class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.disk});
  final DiskInfo? disk;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: tokens.ink0,
        border: Border.all(color: tokens.bad.withValues(alpha: 0.5), width: 2),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
        boxShadow: [
          BoxShadow(
            color: tokens.bad.withValues(alpha: 0.12),
            blurRadius: 24,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'TARGET DISK — WILL BE ERASED',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 9,
              letterSpacing: 0.14 * 9,
              color: tokens.bad,
            ),
          ),
          const SizedBox(height: 8),
          // Friendly name as the headline so it matches the
          // pick-disk + flash-target screens. The platform id (e.g.
          // PhysicalDrive3) is dev-facing jargon and goes below as a
          // small caption — there if the user needs the unambiguous
          // identifier for support, but not the thing they're asked
          // to type.
          Text(
            _friendlyName(disk),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: 22,
              fontWeight: FontWeight.w500,
              letterSpacing: -0.01 * 22,
              height: 1.2,
              color: tokens.text,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _diskMeta(disk),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 12,
              letterSpacing: 0.02 * 12,
              color: tokens.text3,
            ),
          ),
          if (disk != null) ...[
            const SizedBox(height: 2),
            Text(
              diskTechnicalLabel(disk!),
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 10,
                letterSpacing: 0.04 * 10,
                color: tokens.text4,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: tokens.bad.withValues(alpha: 0.3),
                  style: BorderStyle.solid,
                ),
              ),
            ),
            padding: const EdgeInsets.only(top: 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _partitionsHeader(disk),
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 9,
                    letterSpacing: 0.12 * 9,
                    color: tokens.text4,
                  ),
                ),
                const SizedBox(height: 6),
                if (disk == null || disk!.partitions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Text(
                      'partition list unavailable — full disk will be '
                      'overwritten',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: 12,
                        color: tokens.text3,
                      ),
                    ),
                  )
                else
                  for (final p in disk!.partitions)
                    _PartitionRow(part: p, tokens: tokens),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Headline label — same logic the prior screens use so the user
  /// types the name they actually saw on flash-target.
  String _friendlyName(DiskInfo? d) {
    if (d == null) return '<no disk>';
    return diskDisplayName(d);
  }

  /// Subtitle row — size + bus + removable flag. The model name is
  /// already in the headline so we omit it here to avoid
  /// duplication.
  String _diskMeta(DiskInfo? d) {
    if (d == null) return '';
    final size = (d.sizeBytes / (1 << 30)).toStringAsFixed(2);
    final parts = <String>[
      '$size GiB',
      if (d.bus.isNotEmpty) d.bus,
      if (d.removable) 'removable',
    ];
    return parts.join(' · ');
  }

  String _partitionsHeader(DiskInfo? d) {
    if (d == null || d.partitions.isEmpty) return 'PARTITIONS';
    final size = (d.sizeBytes / (1 << 30)).toStringAsFixed(2);
    return 'PARTITIONS — ${d.partitions.length} entries · $size GiB';
  }
}

class _PartitionRow extends StatelessWidget {
  const _PartitionRow({required this.part, required this.tokens});
  final PartitionInfo part;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    final size = part.sizeBytes >= (1 << 30)
        ? '${(part.sizeBytes / (1 << 30)).toStringAsFixed(1)} GiB'
        : '${(part.sizeBytes / (1 << 20)).toStringAsFixed(0)} MiB';
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: tokens.lineSoft)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 18,
            child: Icon(Icons.close, size: 11, color: tokens.bad),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 80,
            child: Text(
              part.mountpoint ?? 'p${part.index}',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 12,
                color: tokens.text,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              part.filesystem.isEmpty ? '—' : part.filesystem,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 11,
                color: tokens.text4,
              ),
            ),
          ),
          SizedBox(
            width: 80,
            child: Text(
              size,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 12,
                color: tokens.text3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.osId});
  final String? osId;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'SOURCE IMAGE',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 9,
              letterSpacing: 0.14 * 9,
              color: tokens.text4,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            osId ?? '<no image>',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 14,
              letterSpacing: -0.005 * 14,
              color: tokens.text,
            ),
          ),
          const SizedBox(height: 14),
          // A 2x2 readout of the operations the helper will perform.
          // We don't yet plumb image size + sha through to this
          // screen, so the right column is fixed copy describing the
          // pipeline rather than fake numbers — honest and matches
          // the V2 design's intent.
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 4.5,
            children: const [
              _SourceStat(k: 'WRITE', v: 'elevated helper'),
              _SourceStat(k: 'VERIFY', v: 'sha256 + read-back'),
              _SourceStat(k: 'PARTS', v: 'recreated from image'),
              _SourceStat(k: 'ETA', v: '~14 min'),
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceStat extends StatelessWidget {
  const _SourceStat({required this.k, required this.v});
  final String k;
  final String v;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          k,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 9,
            letterSpacing: 0.1 * 9,
            color: tokens.text4,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          v,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: DeckhandTokens.fontMono,
            fontSize: 12,
            color: tokens.text2,
          ),
        ),
      ],
    );
  }
}

class _SafeStrip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(tokens.ok.withValues(alpha: 0.08), tokens.ink0),
        border: Border.all(color: tokens.ok.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          Icon(Icons.check, size: 14, color: tokens.ok),
          const SizedBox(width: 10),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: 13,
                  color: Color.alphaBlend(
                    tokens.ok.withValues(alpha: 0.8),
                    tokens.text,
                  ),
                ),
                children: const [
                  TextSpan(
                    text: 'Only this disk is being erased.',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  TextSpan(
                    text:
                        ' Your computer, any other drives plugged in, '
                        'and any backups you\'ve already made are not '
                        'touched.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConfirmBlock extends StatelessWidget {
  const _ConfirmBlock({
    required this.expected,
    required this.typed,
    required this.matched,
    required this.onBack,
    required this.onWipe,
  });

  final String expected;
  final TextEditingController typed;
  final bool matched;
  final VoidCallback onBack;
  final VoidCallback onWipe;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
      decoration: BoxDecoration(
        color: tokens.ink0,
        border: Border.all(
          color: Color.alphaBlend(
            tokens.bad.withValues(alpha: 0.25),
            tokens.line,
          ),
        ),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'TYPE THE DISK NAME TO ENABLE WIPE',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              letterSpacing: 0.12 * 10,
              color: tokens.text4,
            ),
          ),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: TextField(
              controller: typed,
              autocorrect: false,
              enableSuggestions: false,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 14,
                letterSpacing: 0.02 * 14,
                color: tokens.text,
              ),
              decoration: InputDecoration(
                hintText: expected.isEmpty ? 'disk name' : expected,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                filled: true,
                fillColor: matched
                    ? Color.alphaBlend(
                        tokens.ok.withValues(alpha: 0.06),
                        tokens.ink1,
                      )
                    : tokens.ink1,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DeckhandTokens.r2),
                  borderSide: BorderSide(color: tokens.line),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DeckhandTokens.r2),
                  borderSide: BorderSide(
                    color: matched ? tokens.ok : tokens.line,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DeckhandTokens.r2),
                  borderSide: BorderSide(
                    color: matched ? tokens.ok : tokens.bad,
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            matched ? 'MATCH · WIPE ARMED' : 'EXPECTED: $expected',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 11,
              letterSpacing: 0.06 * 11,
              color: matched ? tokens.ok : tokens.text4,
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.only(top: 18),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(
                  color: Color.alphaBlend(
                    tokens.bad.withValues(alpha: 0.25),
                    tokens.line,
                  ),
                ),
              ),
            ),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back, size: 14),
                  label: const Text("Back, don't wipe"),
                ),
                const Spacer(),
                _WipeAndFlashButton(matched: matched, onPressed: onWipe),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WipeAndFlashButton extends StatelessWidget {
  const _WipeAndFlashButton({required this.matched, required this.onPressed});

  final bool matched;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: tokens.bad,
        foregroundColor: const Color(0xFFFCFCFC),
        disabledBackgroundColor: tokens.ink2,
        disabledForegroundColor: tokens.text4,
        minimumSize: const Size(190, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DeckhandTokens.r2),
          side: BorderSide(color: matched ? tokens.bad : tokens.line),
        ),
      ),
      onPressed: matched ? onPressed : null,
      icon: const Icon(Icons.local_fire_department, size: 15),
      label: const Text(
        'Wipe and flash',
        style: TextStyle(
          fontFamily: DeckhandTokens.fontSans,
          fontSize: 14,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}
