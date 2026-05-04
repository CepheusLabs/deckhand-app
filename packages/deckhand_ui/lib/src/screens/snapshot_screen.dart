import 'dart:async';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/wizard_scaffold.dart';

/// S145-snapshot — capture the user's hand-edited config before Flow A
/// rewrites it. See docs/WIZARD-FLOW.md (S145-snapshot) for the spec.
///
/// Layout mirrors the design source: a left panel listing every
/// snapshot path with a checkbox + mono path + note + size estimate,
/// and a right panel carrying the restore-strategy radio + an
/// "Estimated archive" callout.
class SnapshotScreen extends ConsumerStatefulWidget {
  const SnapshotScreen({super.key});

  @override
  ConsumerState<SnapshotScreen> createState() => _SnapshotScreenState();
}

class _SnapshotScreenState extends ConsumerState<SnapshotScreen> {
  final _selected = <String>{};
  bool _seeded = false;
  bool _didRefresh = false;
  bool _emmcBackupAcknowledged = false;
  String _restoreStrategy = 'side_by_side';

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(wizardControllerProvider);
    final paths = controller.profile?.stockOs.snapshotPaths ?? const [];
    if (!_seeded) {
      for (final p in paths) {
        if (p.defaultSelected) _selected.add(p.id);
      }
      _seeded = true;
    }

    // The probe is pre-warmed by ChoosePath when the user picks
    // stockKeep. Watching here either reuses the cached future (fast
    // path) or kicks it off if the user navigated here directly.
    final probeAsync = ref.watch(snapshotProbeProvider);
    final probing = probeAsync.isLoading;
    final probe = probeAsync.valueOrNull;
    final sizes = probe?.sizes ?? const <String, int>{};
    final probedAt = probe?.probedAt;
    final probeError = probeAsync.hasError ? probeAsync.error : null;

    // Race recovery: if the probe completed with `null` because SSH
    // wasn't ready at the moment ChoosePath kicked it off, but is
    // ready now (we got here, SSH is connected, profile + paths +
    // flow are all valid), retrigger it once. Without this the user
    // sees "not available" forever despite everything actually being
    // fine. Guarded by `_didRefresh` so we don't loop.
    if (!_didRefresh &&
        !probing &&
        probe == null &&
        probeError == null &&
        controller.sshSession != null &&
        controller.state.flow == WizardFlow.stockKeep &&
        paths.isNotEmpty) {
      _didRefresh = true;
      // Fire after the build completes so we don't mutate provider
      // state during a build call.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) ref.invalidate(snapshotProbeProvider);
      });
    }

    final selectedSize = _selected.fold<int>(0, (sum, id) {
      final p = paths.firstWhere(
        (e) => e.id == id,
        orElse: () => const StockSnapshotPath(
          id: '',
          displayName: '',
          path: '',
          defaultSelected: false,
        ),
      );
      return sum + (sizes[p.path] ?? 0);
    });

    return WizardScaffold(
      screenId: 'S145-snapshot',
      title: 'Save your current configuration.',
      helperText:
          'We\'ll archive these directories before the install rewrites '
          'them. The archive is restored side-by-side after install so '
          'you can pull any tweaks you want to keep.',
      body: Column(
        children: [
          // Probe error renders as a banner above the layout so the
          // paths and strategy panels stay visible — losing du -sk
          // shouldn't hide the user's data.
          if (probeError != null) ...[
            _ProbeErrorCard(error: probeError),
            const SizedBox(height: 12),
          ],
          _FullEmmcBackupBanner(
            acknowledged: _emmcBackupAcknowledged,
            onChanged: (v) =>
                setState(() => _emmcBackupAcknowledged = v),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoCol = constraints.maxWidth >= 880;
              final left = paths.isEmpty
                  ? const _EmptyPathsCard()
                  : _PathsPanel(
                      paths: paths,
                      selected: _selected,
                      sizes: sizes,
                      probing: probing,
                      onToggle: (id, v) => setState(() {
                        if (v) {
                          _selected.add(id);
                        } else {
                          _selected.remove(id);
                        }
                      }),
                    );
              final right = _StrategyPanel(
                strategy: _restoreStrategy,
                estimatedBytes: selectedSize,
                probedAt: probedAt,
                probing: probing,
                onChange: (v) => setState(
                    () => _restoreStrategy = v ?? 'side_by_side'),
              );
              if (twoCol) {
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: left),
                      const SizedBox(width: 12),
                      Expanded(child: right),
                    ],
                  ),
                );
              }
              return Column(
                children: [
                  left,
                  const SizedBox(height: 12),
                  right,
                ],
              );
            },
          ),
        ],
      ),
      primaryAction: WizardAction(
        label: 'Snapshot and continue',
        // Continue is gated on the eMMC-backup acknowledgement so
        // the user can't accidentally barrel through the only place
        // we ask them about their rollback path. Allowing advance
        // even before the probe lands — a slow network shouldn't
        // gate the user. Decisions still record.
        onPressed: !_emmcBackupAcknowledged
            ? null
            : () {
                final c = ref.read(wizardControllerProvider);
                unawaited(
                    c.setDecision('snapshot.paths', _selected.toList()));
                unawaited(c.setDecision(
                    'snapshot.restore_strategy', _restoreStrategy));
                unawaited(c.setDecision('snapshot.emmc_acknowledged', true));
                context.go('/hardening');
              },
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          isBack: true,
          onPressed: () => context.go('/files'),
        ),
      ],
    );
  }
}

class _ProbeErrorCard extends StatelessWidget {
  const _ProbeErrorCard({required this.error});
  final Object error;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.bad.withValues(alpha: 0.06),
        border: Border.all(color: tokens.bad.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: tokens.bad),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Could not probe sizes',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w600,
                    color: tokens.bad,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '$error',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.bad,
                    height: 1.5,
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

class _EmptyPathsCard extends StatelessWidget {
  const _EmptyPathsCard();

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Row(
        children: [
          Icon(Icons.inbox_outlined, size: 18, color: tokens.text3),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'This profile doesn\'t declare any snapshot paths. '
              'Continue if there\'s nothing custom to preserve, or back '
              'out and use the Manage view\'s Backup tab for a full '
              'eMMC dump.',
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
    );
  }
}

class _PathsPanel extends StatelessWidget {
  const _PathsPanel({
    required this.paths,
    required this.selected,
    required this.sizes,
    required this.probing,
    required this.onToggle,
  });

  final List<StockSnapshotPath> paths;
  final Set<String> selected;
  final Map<String, int> sizes;
  final bool probing;
  final void Function(String id, bool value) onToggle;

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
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            decoration: BoxDecoration(
              color: tokens.ink2,
              border: Border(bottom: BorderSide(color: tokens.line)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Text(
                  'PATHS',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text3,
                    letterSpacing: 0.12 * 10,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '· ${selected.length}/${paths.length} selected',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text4,
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < paths.length; i++)
            _PathRow(
              path: paths[i],
              selected: selected.contains(paths[i].id),
              probing: probing,
              size: sizes[paths[i].path],
              missing: !probing &&
                  sizes[paths[i].path] != null &&
                  sizes[paths[i].path] == 0,
              isLast: i == paths.length - 1,
              onToggle: (v) => onToggle(paths[i].id, v),
            ),
        ],
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.path,
    required this.selected,
    required this.probing,
    required this.size,
    required this.missing,
    required this.isLast,
    required this.onToggle,
  });

  final StockSnapshotPath path;
  final bool selected;
  final bool probing;
  final int? size;
  final bool missing;
  final bool isLast;
  final void Function(bool) onToggle;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Opacity(
      opacity: missing ? 0.55 : 1.0,
      child: InkWell(
        onTap: missing ? null : () => onToggle(!selected),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            border: isLast
                ? null
                : Border(bottom: BorderSide(color: tokens.lineSoft)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: Checkbox(
                  value: selected && !missing,
                  onChanged: missing ? null : (v) => onToggle(v ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      path.displayName,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontSans,
                        fontSize: DeckhandTokens.tMd,
                        fontWeight: FontWeight.w500,
                        color: tokens.text,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      path.path,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontMono,
                        fontSize: DeckhandTokens.tXs,
                        color: tokens.text3,
                      ),
                    ),
                    if (path.helperText != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        path.helperText!,
                        style: TextStyle(
                          fontFamily: DeckhandTokens.fontSans,
                          fontSize: DeckhandTokens.tXs,
                          color: tokens.text4,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 88,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _SizeCell(
                    probing: probing,
                    missing: missing,
                    sizeBytes: size,
                    tokens: tokens,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SizeCell extends StatelessWidget {
  const _SizeCell({
    required this.probing,
    required this.missing,
    required this.sizeBytes,
    required this.tokens,
  });
  final bool probing;
  final bool missing;
  final int? sizeBytes;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    if (probing) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: tokens.text4,
        ),
      );
    }
    if (missing) {
      return Text(
        'not found',
        style: TextStyle(
          fontFamily: DeckhandTokens.fontMono,
          fontSize: DeckhandTokens.tXs,
          color: tokens.text4,
          fontStyle: FontStyle.italic,
        ),
      );
    }
    return Text(
      sizeBytes == null ? '—' : _humanBytes(sizeBytes!),
      style: TextStyle(
        fontFamily: DeckhandTokens.fontMono,
        fontSize: DeckhandTokens.tXs,
        color: tokens.text3,
      ),
    );
  }
}

class _StrategyPanel extends StatelessWidget {
  const _StrategyPanel({
    required this.strategy,
    required this.estimatedBytes,
    required this.probedAt,
    required this.probing,
    required this.onChange,
  });

  final String strategy;
  final int estimatedBytes;
  final DateTime? probedAt;
  final bool probing;
  final void Function(String? value) onChange;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'RESTORE STRATEGY',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              color: tokens.text4,
              letterSpacing: 0.12 * 10,
            ),
          ),
          const SizedBox(height: 12),
          RadioGroup<String>(
            groupValue: strategy,
            onChanged: onChange,
            child: Column(
              children: [
                _StrategyOption(
                  value: 'side_by_side',
                  selected: strategy == 'side_by_side',
                  isDefault: true,
                  title: 'Save as a separate backup',
                  body:
                      'Your old files land in a backup folder next to the '
                      'new install (e.g. ~/printer_data.stock-2026-05-01). '
                      'New install starts clean — copy back any tweaks you '
                      'want by hand. Safest option.',
                ),
                const SizedBox(height: 10),
                _StrategyOption(
                  value: 'auto_merge',
                  selected: strategy == 'auto_merge',
                  isDefault: false,
                  title: 'Merge into the new install',
                  body:
                      'Anything that exists only in your old files gets '
                      'pulled into the new install automatically. Files '
                      'that conflict with the new install fall back to '
                      'the backup folder for you to review manually.',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: tokens.ink2,
              border: Border.all(color: tokens.line),
              borderRadius: BorderRadius.circular(DeckhandTokens.r2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ESTIMATED ARCHIVE',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text4,
                    letterSpacing: 0.12 * 10,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  probing
                      ? '…'
                      : (probedAt == null
                          ? '—'
                          : _humanBytes(estimatedBytes)),
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: DeckhandTokens.tXl,
                    fontWeight: FontWeight.w500,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  probing
                      ? 'du -sk · running'
                      : (probedAt == null
                          ? 'du -sk · not available'
                          : 'du -sk · cached ${_ago(probedAt!)}'),
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontMono,
                    fontSize: 10,
                    color: tokens.text4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _ago(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    if (s < 60) return '${s}s ago';
    final m = s ~/ 60;
    return '${m}m ago';
  }
}

class _StrategyOption extends StatelessWidget {
  const _StrategyOption({
    required this.value,
    required this.selected,
    required this.isDefault,
    required this.title,
    required this.body,
  });

  final String value;
  final bool selected;
  final bool isDefault;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: selected ? tokens.ink2 : Colors.transparent,
        border: Border.all(color: selected ? tokens.accent : tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Radio<String>(
              value: value,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
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
                    if (isDefault) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 7, vertical: 1),
                        decoration: BoxDecoration(
                          color: tokens.ink3,
                          border: Border.all(color: tokens.line),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Text(
                          'DEFAULT',
                          style: TextStyle(
                            fontFamily: DeckhandTokens.fontMono,
                            fontSize: 9,
                            color: tokens.text2,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.06 * 9,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  body,
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
        ],
      ),
    );
  }
}

String _humanBytes(int bytes) {
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

/// Full-eMMC-image backup banner. Asks the user to confirm they
/// either have a full image backup (via a USB-eMMC adapter + dd)
/// or are knowingly proceeding without one — and offers to actually
/// run the backup right now via the dedicated S148 backup screen.
/// Lives on the snapshot screen because that's the natural "what am
/// I preserving before destructive changes?" moment in the flow.
class _FullEmmcBackupBanner extends ConsumerWidget {
  const _FullEmmcBackupBanner({
    required this.acknowledged,
    required this.onChanged,
  });

  final bool acknowledged;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = DeckhandTokens.of(context);
    final color = acknowledged ? tokens.ok : tokens.warn;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        border: Border.all(color: color.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => onChanged(!acknowledged),
            borderRadius: BorderRadius.circular(DeckhandTokens.r2),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: Checkbox(
                      value: acknowledged,
                      onChanged: (v) => onChanged(v ?? false),
                      materialTapTargetSize:
                          MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      activeColor: tokens.ok,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'I have a full eMMC image backup '
                          '(or accept the risk).',
                          style: TextStyle(
                            fontFamily: DeckhandTokens.fontSans,
                            fontSize: DeckhandTokens.tMd,
                            fontWeight: FontWeight.w600,
                            color: color,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'A directory snapshot below preserves your '
                          'config, but it can\'t restore a bricked '
                          'install. The only safe rollback is a `dd` '
                          'image of the eMMC taken via a USB adapter.',
                          style: TextStyle(
                            fontFamily: DeckhandTokens.fontSans,
                            fontSize: DeckhandTokens.tSm,
                            color: tokens.text2,
                            height: 1.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.only(left: 30),
            child: Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => context.go('/emmc-backup'),
                  icon: const Icon(Icons.save_alt, size: 14),
                  label: const Text('Back up the eMMC now'),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Plug in a USB-eMMC adapter, pick the disk, and '
                    'Deckhand will dd the image for you. Returns here '
                    'when finished.',
                    style: TextStyle(
                      fontFamily: DeckhandTokens.fontSans,
                      fontSize: DeckhandTokens.tXs,
                      color: tokens.text3,
                      height: 1.4,
                    ),
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
