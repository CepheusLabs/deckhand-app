import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/id_tag.dart';
import '../widgets/wizard_scaffold.dart';

class PrintersScreen extends ConsumerStatefulWidget {
  const PrintersScreen({super.key});

  @override
  ConsumerState<PrintersScreen> createState() => _PrintersScreenState();
}

class _PrintersScreenState extends ConsumerState<PrintersScreen> {
  String? _busyId;

  Future<void> _manage(ManagedPrinter printer) async {
    if (_busyId != null) return;
    setState(() => _busyId = printer.id);
    try {
      await ref
          .read(wizardControllerProvider)
          .restore(
            WizardState(
              profileId: printer.profileId,
              decisions: const {},
              currentStep: 'manage',
              flow: WizardFlow.none,
              sshHost: printer.host,
            ),
          );
      if (!mounted) return;
      context.go('/manage');
    } on ResumeFailedException catch (e) {
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.error_outline),
          title: const Text("Couldn't open this printer"),
          content: Text(
            'Deckhand found "${printer.displayName}", but the profile '
            '"${printer.profileId}" could not be loaded:\n\n${e.cause}',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _forget(ManagedPrinter printer) async {
    if (_busyId == printer.id) return;
    final settings = ref.read(deckhandSettingsProvider);
    settings.forgetManagedPrinter(printer.id);
    setState(() {});
    try {
      await settings.save();
    } catch (_) {
      // Keep the in-memory registry updated even if the settings file
      // is temporarily unavailable. A later settings write can persist it.
    }
  }

  @override
  Widget build(BuildContext context) {
    final printers = ref.watch(deckhandSettingsProvider).managedPrinters;
    return WizardScaffold(
      screenId: 'MGR-printers',
      title: 'Printers.',
      helperText: 'Known printers Deckhand has connected to on this computer.',
      body: _PrintersPanel(
        printers: printers,
        busyId: _busyId,
        onManage: _manage,
        onForget: _forget,
      ),
      primaryAction: WizardAction(
        label: 'Add a printer',
        onPressed: () => context.go('/pick-printer'),
      ),
      secondaryActions: [
        WizardAction(
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
    required this.printers,
    required this.busyId,
    required this.onManage,
    required this.onForget,
  });

  final List<ManagedPrinter> printers;
  final String? busyId;
  final Future<void> Function(ManagedPrinter printer) onManage;
  final Future<void> Function(ManagedPrinter printer) onForget;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
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
              _Eyebrow('KNOWN PRINTERS', color: tokens.text3),
              const Spacer(),
              IdTag('${printers.length} saved'),
            ],
          ),
          const SizedBox(height: 16),
          if (printers.isEmpty)
            _EmptyPrinters(tokens: tokens)
          else
            Column(
              children: [
                for (final printer in printers)
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

class _EmptyPrinters extends StatelessWidget {
  const _EmptyPrinters({required this.tokens});

  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          Icon(
            Icons.precision_manufacturing_outlined,
            size: 18,
            color: tokens.text3,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'No printers saved yet.',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Connect to a printer once and it will appear here.',
                  style: TextStyle(
                    fontSize: DeckhandTokens.tSm,
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
    final tokens = DeckhandTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.ink2,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          Icon(
            Icons.precision_manufacturing_outlined,
            size: 18,
            color: tokens.accent,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  printer.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                    height: 1.25,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    IdTag(_connectionLabel(printer)),
                    IdTag(printer.profileId),
                    if (printer.lastSeen != null)
                      IdTag('seen ${_shortDate(printer.lastSeen!)}'),
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
                    child: DeckhandSpinner(size: 12, strokeWidth: 1.5),
                  )
                : const Icon(Icons.tune, size: 14),
            label: Text(busy ? 'Opening...' : 'Manage'),
          ),
        ],
      ),
    );
  }
}

class _Eyebrow extends StatelessWidget {
  const _Eyebrow(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontFamily: DeckhandTokens.fontMono,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        color: color,
        letterSpacing: 0,
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
