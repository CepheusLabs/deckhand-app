import 'package:flutter/material.dart';

import 'profile_text.dart';

/// Standard layout for a wizard screen. Title + body + footer action row.
class WizardScaffold extends StatelessWidget {
  const WizardScaffold({
    super.key,
    required this.title,
    required this.body,
    this.helperText,
    this.primaryAction,
    this.secondaryActions = const [],
    this.stepper,
  });

  final String title;
  final Widget body;
  final String? helperText;
  final WizardAction? primaryAction;
  final List<WizardAction> secondaryActions;
  final Widget? stepper;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Column(
        children: [
          if (stepper != null) stepper!,
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
              // Center the content block so wide displays don't leave a
              // sea of empty space on the right. The 960px cap keeps
              // line lengths readable regardless of window size.
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: Text(
                          title,
                          style: theme.textTheme.headlineMedium,
                        ),
                      ),
                      if (helperText != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          flattenProfileText(helperText),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      body,
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (primaryAction != null || secondaryActions.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border(
                  top: BorderSide(color: theme.colorScheme.outlineVariant),
                ),
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Row(
                    children: [
                      for (final a in secondaryActions) ...[
                        TextButton(
                          onPressed: a.onPressed,
                          child: Text(a.label),
                        ),
                        const SizedBox(width: 8),
                      ],
                      const Spacer(),
                      if (primaryAction != null)
                        FilledButton(
                          onPressed: primaryAction!.onPressed,
                          style: primaryAction!.destructive
                              ? FilledButton.styleFrom(
                                  backgroundColor: theme.colorScheme.error,
                                  foregroundColor: theme.colorScheme.onError,
                                )
                              : null,
                          child: Text(primaryAction!.label),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class WizardAction {
  const WizardAction({
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool destructive;
}
