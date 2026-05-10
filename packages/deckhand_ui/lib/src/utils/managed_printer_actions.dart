import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers.dart';
import 'user_facing_errors.dart';

Future<void> openManagedPrinterForManagement({
  required BuildContext context,
  required WidgetRef ref,
  required ManagedPrinter printer,
}) async {
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
            sshPort: printer.port,
            sshUser: printer.user,
          ),
        );
    if (!context.mounted) return;
    context.go('/manage');
  } on ResumeFailedException catch (e) {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        icon: const Icon(Icons.error_outline),
        title: const Text("Couldn't open this printer"),
        content: Text(
          'Deckhand found "${printer.displayName}", but the profile '
          '"${printer.profileId}" could not be loaded:\n\n'
          '${userFacingError(e.cause)}',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }
}

Future<void> forgetManagedPrinterWithWarning({
  required BuildContext context,
  required WidgetRef ref,
  required ManagedPrinter printer,
  required VoidCallback onForgot,
}) async {
  final registry = ref.read(managedPrinterRegistryProvider);
  registry.forgetManagedPrinter(printer.id);
  onForgot();
  try {
    await registry.save();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          "Deckhand couldn't save that change. The printer is removed "
          'for this session, but may return after restart: '
          '${userFacingError(error)}',
        ),
      ),
    );
  }
}
