import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../utils/managed_printer_actions.dart';

class PrintersScreen extends ConsumerStatefulWidget {
  const PrintersScreen({super.key});

  @override
  ConsumerState<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends ConsumerState<PrintersScreen> {
  String? _busyId;
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _manage(ManagedPrinter printer) async {
    if (_busyId != null) return;
    setState(() => _busyId = printer.id);
    try {
      await openManagedPrinterForManagement(
        context: context,
        ref: ref,
        printer: printer,
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _forget(ManagedPrinter printer) async {
    if (_busyId == printer.id) return;
    await forgetManagedPrinterWithWarning(
      context: context,
      ref: ref,
      printer: printer,
      onForgot: () => setState(() {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final printers = ref
        .watch(managedPrinterRegistryProvider)
        .listManagedPrinters();
    final searchQuery = _searchController.text.trim();
    final visiblePrinters = searchQuery.isEmpty
        ? printers
        : printers.where((p) => _matchesPrinterSearch(p, searchQuery)).toList();
    return ClWizardPageScaffold(
      title: 'Printers',
      helperText:
          'Saved printers Deckhand can reopen for manage, backup, restore, and maintenance work.',
      preHeader: const ClPageHeader(
        icon: Icons.precision_manufacturing_outlined,
        title: 'Printers',
      ),
      body: _PrintersPanel(
        allCount: printers.length,
        searchController: _searchController,
        searchQuery: searchQuery,
        onSearchChanged: (_) => setState(() {}),
        printers: printers,
        visiblePrinters: visiblePrinters,
        busyId: _busyId,
        onManage: _manage,
        onForget: _forget,
      ),
      primaryAction: ClWizardAction(
        label: 'Add a printer',
        onPressed: () => context.go('/pick-printer'),
      ),
      secondaryActions: [
        ClWizardAction(
          label: 'Back',
          isBack: true,
          onPressed: () => context.go('/'),
        ),
      ],
    );
  }
}

class _PrintersPanel extends StatelessWidget {
  const _PrintersPanel({
    required this.allCount,
    required this.searchController,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.printers,
    required this.visiblePrinters,
    required this.busyId,
    required this.onManage,
    required this.onForget,
  });

  final int allCount;
  final TextEditingController searchController;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final List<ManagedPrinter> printers;
  final List<ManagedPrinter> visiblePrinters;
  final String? busyId;
  final Future<void> Function(ManagedPrinter printer) onManage;
  final Future<void> Function(ManagedPrinter printer) onForget;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        color: brand.bgAlt,
        border: Border.all(color: brand.borderStrong),
        borderRadius: BorderRadius.circular(context.radii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const ClTechLabel('KNOWN PRINTERS'),
              const Spacer(),
              ClIdTag(
                searchQuery.isEmpty
                    ? '$allCount saved'
                    : '${visiblePrinters.length} of $allCount shown',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (printers.isNotEmpty) ...[
            TextField(
              controller: searchController,
              onChanged: onSearchChanged,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search printers',
              ),
            ),
            const SizedBox(height: 16),
          ],
          if (printers.isEmpty)
            const _EmptyPrinters()
          else if (visiblePrinters.isEmpty)
            _NoMatchingPrinters(query: searchQuery)
          else
            Column(
              children: [
                for (final printer in visiblePrinters)
                  _PrinterRegistryRow(
                    printer: printer,
                    busy: busyId == printer.id,
                    onManage: () => onManage(printer),
                    onForget: () => onForget(printer),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _NoMatchingPrinters extends StatelessWidget {
  const _NoMatchingPrinters({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: brand.surface,
        border: Border.all(color: brand.borderStrong),
        borderRadius: BorderRadius.circular(context.radii.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.search_off, size: 18, color: brand.ink3),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'No saved printers match "$query".',
              style: context.clBodySmall.copyWith(color: brand.ink3),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyPrinters extends StatelessWidget {
  const _EmptyPrinters();

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: brand.surface,
        border: Border.all(color: brand.borderStrong),
        borderRadius: BorderRadius.circular(context.radii.sm),
      ),
      child: Row(
        children: [
          Icon(
            Icons.precision_manufacturing_outlined,
            size: 18,
            color: brand.ink3,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No printers saved yet.',
                  style: context.clBodyMedium.copyWith(
                    fontWeight: FontWeight.w600,
                    color: brand.ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect to a printer once and it will appear here.',
                  style: context.clBodySmall.copyWith(color: brand.ink3),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PrinterRegistryRow extends StatelessWidget {
  const _PrinterRegistryRow({
    required this.printer,
    required this.busy,
    required this.onManage,
    required this.onForget,
  });

  final ManagedPrinter printer;
  final bool busy;
  final VoidCallback onManage;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: brand.surface,
        border: Border.all(color: brand.borderStrong),
        borderRadius: BorderRadius.circular(context.radii.sm),
      ),
      child: Row(
        children: [
          Icon(
            Icons.precision_manufacturing_outlined,
            size: 18,
            color: brand.primary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  printer.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: context.clBodyMedium.copyWith(
                    fontWeight: FontWeight.w600,
                    color: brand.ink,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ClIdTag(_connectionLabel(printer)),
                    ClIdTag(printer.profileId),
                    if (printer.lastSeen != null)
                      ClIdTag('seen ${_shortDate(printer.lastSeen!)}'),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Tooltip(
            message: 'Forget printer',
            child: IconButton(
              onPressed: busy ? null : onForget,
              icon: const Icon(Icons.close, size: 16),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 4),
          OutlinedButton.icon(
            onPressed: busy ? null : onManage,
            icon: busy
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: ClSpinner(size: 12, strokeWidth: 1.5),
                  )
                : const Icon(Icons.tune, size: 14),
            label: Text(busy ? 'Opening...' : 'Manage'),
          ),
        ],
      ),
    );
  }
}

String _connectionLabel(ManagedPrinter printer) {
  final port = printer.port == 22 ? '' : ':${printer.port}';
  return '${printer.user}@${printer.host}$port';
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  return '$month-$day $hour:$minute';
}

bool _matchesPrinterSearch(ManagedPrinter printer, String query) {
  final needle = query.toLowerCase();
  return printer.displayName.toLowerCase().contains(needle) ||
      printer.host.toLowerCase().contains(needle) ||
      printer.profileId.toLowerCase().contains(needle) ||
      printer.user.toLowerCase().contains(needle);
}
