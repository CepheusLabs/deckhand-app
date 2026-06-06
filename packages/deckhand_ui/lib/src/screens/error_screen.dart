import 'package:flutter/material.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';

class ErrorScreen extends StatelessWidget {
  const ErrorScreen({
    super.key,
    required this.title,
    required this.message,
    this.onRetry,
  });
  final String title;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return ClWizardPageScaffold(
      title: title,
      helperText: message,
      body: Icon(Icons.error_outline, size: 64, color: context.brandColors.bad),
      primaryAction: ClWizardAction(
        label: 'Start over',
        onPressed: () => context.go('/'),
      ),
      secondaryActions: [
        if (onRetry != null) ClWizardAction(label: 'Retry', onPressed: onRetry),
      ],
    );
  }
}
