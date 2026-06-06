import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../utils/disk_display.dart';
import '../utils/user_facing_errors.dart';

class FlashTargetScreen extends ConsumerStatefulWidget {
  const FlashTargetScreen({super.key});

  @override
  ConsumerState<FlashTargetScreen> createState() => _FlashTargetScreenState();
}

class _FlashTargetScreenState extends ConsumerState<FlashTargetScreen> {
  String? _selected;

  void _refresh() {
    setState(() => _selected = null);
    // Invalidate the shared cache; the FutureProvider re-runs on the
    // next watch and any other screen also watching it sees the
    // refreshed list. The local screen's `ref.watch(disksProvider)`
    // below picks up the new value automatically.
    ref.invalidate(disksProvider);
  }

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    final disksAsync = ref.watch(disksProvider);
    final selectedDiskIsUsable =
        _selected != null &&
        !disksAsync.isLoading &&
        !disksAsync.hasError &&
        (disksAsync.valueOrNull ?? const <DiskInfo>[]).any(
          (disk) => disk.id == _selected && disk.removable,
        );
    return ClWizardPageScaffold(
      title: 'Pick the disk to flash.',
      helperText:
          'Connect the printer\'s eMMC to your computer via a USB '
          'adapter, then choose it below. Non-removable system disks are '
          'dimmed and unselectable so the host\'s boot drive can never '
          'be picked by accident.',
      preHeader: const ClPageHeader(
        icon: Icons.sd_storage_outlined,
        title: 'Flash target',
      ),
      body: Builder(
        builder: (context) {
          if (disksAsync.isLoading) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: ClTechnicalLoadingBlock(
                kind: ClTechnicalLoaderKind.emmcPins,
                title: 'Scanning disks',
                message:
                    'Deckhand is enumerating removable drives and blocking '
                    'system disks before selection.',
              ),
            );
          }
          if (disksAsync.hasError) {
            return Text(
              'Error listing disks: ${userFacingError(disksAsync.error)}',
              style: TextStyle(color: brand.bad),
            );
          }
          final disks = disksAsync.value ?? const <DiskInfo>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${disks.length} disk${disks.length == 1 ? '' : 's'} '
                      'enumerated',
                      style: context.dataTiny.copyWith(color: brand.ink3),
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 14),
                    label: const Text('Refresh'),
                    onPressed: _refresh,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _DisksTable(
                disks: disks,
                selected: _selected,
                onSelect: (id) => setState(() => _selected = id),
              ),
            ],
          );
        },
      ),
      primaryAction: ClWizardAction(
        label: 'Use this disk',
        disabledReason: _flashTargetDisabledReason(disksAsync),
        onPressed: !selectedDiskIsUsable
            ? null
            : () async {
                final selected = _selected;
                final disks =
                    ref.read(disksProvider).valueOrNull ?? const <DiskInfo>[];
                final stillUsable =
                    selected != null &&
                    disks.any((disk) => disk.id == selected && disk.removable);
                if (!stillUsable) return;
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('flash.disk', selected);
                if (context.mounted) context.go('/choose-os');
              },
      ),
      secondaryActions: [
        ClWizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/choose-path'),
          isBack: true,
        ),
      ],
    );
  }

  String? _flashTargetDisabledReason(AsyncValue<List<DiskInfo>> disksAsync) {
    if (disksAsync.isLoading) return 'Wait for the disk scan to finish.';
    if (disksAsync.hasError) {
      return 'Resolve the disk scan error before continuing.';
    }
    if (_selected == null) return 'Select a removable eMMC disk first.';
    return 'Select a removable eMMC disk; fixed system disks cannot be flashed.';
  }
}

class _DisksTable extends StatelessWidget {
  const _DisksTable({
    required this.disks,
    required this.selected,
    required this.onSelect,
  });

  final List<DiskInfo> disks;
  final String? selected;
  final void Function(String id) onSelect;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Container(
      decoration: BoxDecoration(
        color: brand.bgAlt,
        border: Border.all(color: brand.borderStrong),
        borderRadius: BorderRadius.circular(context.radii.md),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Container(
            decoration: BoxDecoration(
              color: brand.surface,
              border: Border(bottom: BorderSide(color: brand.borderStrong)),
            ),
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
            child: const _RowLayout(
              radio: SizedBox.shrink(),
              disk: _HeaderCell('Disk'),
              bus: _HeaderCell('Bus'),
              size: _HeaderCell('Size'),
              parts: _HeaderCell('Partitions'),
              match: _HeaderCell('Match'),
            ),
          ),
          if (disks.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                'No disks reported. Connect an adapter and Refresh.',
                style: context.clBodySmall.copyWith(color: brand.ink3),
              ),
            )
          else
            for (var i = 0; i < disks.length; i++)
              _DiskRow(
                disk: disks[i],
                isLast: i == disks.length - 1,
                selected: selected == disks[i].id,
                onTap: _diskSelectable(disks[i])
                    ? () => onSelect(disks[i].id)
                    : null,
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
    final brand = context.brandColors;
    final clickable = onTap != null;
    final dim = !_diskSelectable(disk);
    return MouseRegion(
      cursor: clickable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: Opacity(
        opacity: dim ? 0.4 : 1.0,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              color: selected ? brand.surface : Colors.transparent,
              border: isLast
                  ? null
                  : Border(bottom: BorderSide(color: brand.borderSubtle)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: _RowLayout(
              radio: _RadioDot(selected: selected),
              disk: Row(
                children: [
                  Icon(
                    disk.interruptedFlash == null
                        ? Icons.album_outlined
                        : Icons.warning_amber_outlined,
                    size: 16,
                    color: disk.interruptedFlash == null
                        ? brand.ink3
                        : brand.bad,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          diskDisplayName(disk),
                          overflow: TextOverflow.ellipsis,
                          style: context.dataSmall.copyWith(color: brand.ink),
                        ),
                        if (disk.interruptedFlash != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            _interruptedFlashLabel(disk.interruptedFlash!),
                            overflow: TextOverflow.ellipsis,
                            style: context.clLabelSmall.copyWith(
                              color: brand.bad,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              bus: Text(
                disk.bus.isEmpty ? '—' : disk.bus,
                style: context.dataSmall.copyWith(color: brand.ink2),
              ),
              size: Text(
                _formatSize(disk.sizeBytes),
                style: context.dataSmall.copyWith(color: brand.ink2),
              ),
              parts: Text(
                _partitionsLabel(disk),
                overflow: TextOverflow.ellipsis,
                style: context.dataSmall.copyWith(color: brand.ink2),
              ),
              match: _MatchPill(disk: disk),
            ),
          ),
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

  /// Mountpoint summary for the Partitions column. On Windows the
  /// sidecar fills mountpoint with `D:\`, `E:\`, etc.; on Linux/macOS
  /// it's a Unix path like `/` or `/Volumes/Foo`. Render whichever
  /// the host produced — drive letters are what the user is matching
  /// against File Explorer when picking the eMMC adapter, so showing
  /// them removes the "is this the right disk?" guesswork. Falls
  /// back to a partition count when nothing is mounted (raw eMMC,
  /// freshly-wiped USB, etc.).
  String _partitionsLabel(DiskInfo disk) {
    final mounts = disk.partitions
        .map((p) => p.mountpoint)
        .whereType<String>()
        .where((m) => m.isNotEmpty)
        .toList();
    if (mounts.isNotEmpty) return mounts.join(', ');
    final n = disk.partitions.length;
    if (n == 0) return 'no partitions';
    return '$n partition${n == 1 ? '' : 's'}';
  }

  String _interruptedFlashLabel(InterruptedFlashInfo info) {
    return 'Previous Deckhand flash did not finish · '
        '${_formatLocalTimestamp(info.startedAt)}';
  }

  String _formatLocalTimestamp(DateTime utc) {
    final local = utc.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _RowLayout extends StatelessWidget {
  const _RowLayout({
    required this.radio,
    required this.disk,
    required this.bus,
    required this.size,
    required this.parts,
    required this.match,
  });
  final Widget radio;
  final Widget disk;
  final Widget bus;
  final Widget size;
  final Widget parts;
  final Widget match;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(width: 24, child: radio),
        const SizedBox(width: 8),
        Expanded(flex: 4, child: disk),
        Expanded(flex: 2, child: bus),
        Expanded(flex: 2, child: size),
        Expanded(flex: 2, child: parts),
        // Wide enough for the longest forge ClStatusChip label
        // ("INTERRUPTED") at its compact font; the prior 90px was sized
        // for the deleted fontSize-9 mono pill and clipped the wider chip.
        SizedBox(width: 132, child: match),
      ],
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Text(
      label.toUpperCase(),
      style: context.labelTechnical.copyWith(
        color: brand.ink3,
        letterSpacing: 0,
      ),
    );
  }
}

class _RadioDot extends StatelessWidget {
  const _RadioDot({required this.selected});
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Center(
      child: Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? brand.primary : brand.borderStrong,
            width: selected ? 5 : 1.5,
          ),
        ),
      ),
    );
  }
}

class _MatchPill extends StatelessWidget {
  const _MatchPill({required this.disk});
  final DiskInfo disk;

  @override
  Widget build(BuildContext context) {
    final (label, kind) = disk.interruptedFlash != null
        ? ('interrupted', ClChipKind.bad)
        : disk.hasWindowsSystemRole
        ? ('system', ClChipKind.bad)
        : disk.isWindowsWriteBlocked
        ? ('blocked', ClChipKind.bad)
        : !disk.removable
        ? ('system', ClChipKind.bad)
        : ('removable', ClChipKind.good);
    return Align(
      alignment: Alignment.centerLeft,
      child: ClStatusChip(label: label.toUpperCase(), kind: kind, compact: true),
    );
  }
}

bool _diskSelectable(DiskInfo disk) =>
    disk.removable && !disk.hasWindowsSystemRole && !disk.isWindowsWriteBlocked;
