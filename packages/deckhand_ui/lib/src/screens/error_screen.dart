import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class ErrorScreen extends StatelessWidget {
  const ErrorScreen({super.key, required this.title, required this.message, this.onRetry});
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: title,
      helperText: message,
      body: Icon(Icons.error_outline, size: 64, color: Theme.of(context).colorScheme.error),
      primaryAction: WizardAction(label: 'Start over', onPressed: () => context.go('/')),
      secondaryActions: [
        if (onRetry != null) WizardAction(label: 'Retry', onPressed: onRetry),
      ],
    );
  }
}
