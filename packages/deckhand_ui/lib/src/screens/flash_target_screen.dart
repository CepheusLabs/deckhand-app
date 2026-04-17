import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FlashTargetScreen extends ConsumerStatefulWidget {
  const FlashTargetScreen({super.key});

  @override
  ConsumerState<FlashTargetScreen> createState() => _FlashTargetScreenState();
}

class _FlashTargetScreenState extends ConsumerState<FlashTargetScreen> {
  Future<List<DiskInfo>>? _disksFuture;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _disksFuture = ref.read(flashServiceProvider).listDisks();
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: 'Which disk should we flash?',
      helperText:
          'Connect your printer\'s eMMC via a USB adapter. Deckhand will '
          'enumerate attached drives below; pick the one that matches the '
          'expected eMMC size.',
      body: FutureBuilder<List<DiskInfo>>(
        future: _disksFuture,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Text('Error listing disks: ${snap.error}');
          }
          final disks = snap.data ?? const [];
          return Column(
            children: [
              Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.refresh),
                    label: const Text('Refresh'),
                    onPressed: () => setState(() {
                      _disksFuture = ref.read(flashServiceProvider).listDisks();
                    }),
                  ),
                ],
              ),
              for (final d in disks)
                Card(
                  color: _selected == d.id
                      ? Theme.of(context).colorScheme.primaryContainer
                      : null,
                  child: RadioListTile<String>(
                    value: d.id,
                    groupValue: _selected,
                    onChanged: d.removable ? (v) => setState(() => _selected = v) : null,
                    title: Text(d.model.isEmpty ? d.id : d.model),
                    subtitle: Text(
                      '${_formatBytes(d.sizeBytes)} · ${d.bus}'
                      '${d.removable ? "" : " · (non-removable — dimmed)"}',
                    ),
                  ),
                ),
            ],
          );
        },
      ),
      primaryAction: WizardAction(
        label: 'Use this disk',
        onPressed: _selected == null
            ? null
            : () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('flash.disk', _selected!);
                if (context.mounted) context.go('/choose-os');
              },
      ),
      secondaryActions: [
        WizardAction(label: 'Back', onPressed: () => context.go('/choose-path')),
      ],
    );
  }

  String _formatBytes(int bytes) {
    final gb = bytes / (1 << 30);
    return '${gb.toStringAsFixed(1)} GB';
  }
}
