import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class PickPrinterScreen extends ConsumerStatefulWidget {
  const PickPrinterScreen({super.key});

  @override
  ConsumerState<PickPrinterScreen> createState() => _PickPrinterScreenState();
}

class _PickPrinterScreenState extends ConsumerState<PickPrinterScreen> {
  late Future<ProfileRegistry> _registryFuture;
  String? _selectedId;

  @override
  void initState() {
    super.initState();
    _registryFuture = ref.read(profileServiceProvider).fetchRegistry();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ProfileRegistry>(
      future: _registryFuture,
      builder: (context, snap) {
        Widget body;
        if (snap.connectionState != ConnectionState.done) {
          body = const Center(child: CircularProgressIndicator());
        } else if (snap.hasError) {
          body = _ErrorBox(
            message: 'Failed to load printer registry: ${snap.error}',
            onRetry: () => setState(() {
              _registryFuture = ref
                  .read(profileServiceProvider)
                  .fetchRegistry();
            }),
          );
        } else {
          final entries = snap.data!.entries
              .where((e) => e.status != 'stub')
              .toList();
          body = Wrap(
            spacing: 12,
            runSpacing: 12,
            children: entries
                .map(
                  (e) => _PrinterCard(
                    entry: e,
                    selected: _selectedId == e.id,
                    onTap: () => setState(() => _selectedId = e.id),
                  ),
                )
                .toList(),
          );
        }
        return WizardScaffold(
          stepper: const DeckhandStepper(),
          title: 'Which printer are you setting up?',
          helperText:
              'Deckhand supports these printers. Pick yours — we use that '
              'choice to load the right profile before anything else.',
          body: body,
          primaryAction: WizardAction(
            label: 'Continue',
            onPressed: _selectedId == null
                ? null
                : () async {
                    final controller = ref.read(wizardControllerProvider);
                    await controller.loadProfile(_selectedId!);
                    if (context.mounted) context.go('/connect');
                  },
          ),
          secondaryActions: [
            WizardAction(label: 'Back', onPressed: () => context.go('/')),
          ],
        );
      },
    );
  }
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    required this.entry,
    required this.selected,
    required this.onTap,
  });
  final ProfileRegistryEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SizedBox(
      width: 280,
      child: Card(
        elevation: selected ? 4 : 1,
        color: selected ? t.colorScheme.primaryContainer : null,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.manufacturer,
                  style: t.textTheme.labelLarge?.copyWith(
                    color: t.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(entry.displayName, style: t.textTheme.titleLarge),
                const SizedBox(height: 8),
                _StatusChip(status: entry.status),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});
  final String status;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    final color = switch (status) {
      'stable' => t.colorScheme.tertiary,
      'beta' => t.colorScheme.secondary,
      'alpha' => t.colorScheme.primary,
      'deprecated' => t.colorScheme.error,
      _ => t.colorScheme.outline,
    };
    return Chip(
      label: Text(status),
      labelStyle: t.textTheme.labelSmall?.copyWith(color: color),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
        const SizedBox(height: 12),
        OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
      ],
    );
  }
}
