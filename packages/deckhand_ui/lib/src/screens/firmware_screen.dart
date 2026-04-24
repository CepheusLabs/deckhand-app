import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../widgets/wizard_scaffold.dart';
import '../widgets/deckhand_stepper.dart';

class FirmwareScreen extends ConsumerStatefulWidget {
  const FirmwareScreen({super.key});

  @override
  ConsumerState<FirmwareScreen> createState() => _FirmwareScreenState();
}

class _FirmwareScreenState extends ConsumerState<FirmwareScreen> {
  String? _choice;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Seed the default once the profile is available. Previously this
    // ran as `_choice ??= ...` inside build() which mutates state
    // during the build phase - the Flutter linter rightly flags this.
    // didChangeDependencies runs after the widget is mounted and any
    // time inherited state changes, so it picks up the profile as
    // soon as Riverpod has it.
    if (_choice != null) return;
    final profile = ref.read(wizardControllerProvider).profile;
    final choices = profile?.firmware.choices ?? const [];
    _choice = profile?.firmware.defaultChoice ??
        (choices.isNotEmpty ? choices.first.id : null);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(wizardControllerProvider).profile;
    final choices = profile?.firmware.choices ?? const [];

    return WizardScaffold(
      stepper: const DeckhandStepper(),
      title: t.firmware.title,
      helperText: t.firmware.helper,
      body: RadioGroup<String>(
        groupValue: _choice,
        onChanged: (v) => setState(() => _choice = v),
        child: Column(
          children: [
            for (final c in choices)
              Card(
                elevation: _choice == c.id ? 4 : 1,
                color: _choice == c.id
                    ? Theme.of(context).colorScheme.primaryContainer
                    : null,
                child: RadioListTile<String>(
                  value: c.id,
                  title: Row(
                    children: [
                      Text(c.displayName),
                      if (c.recommended) ...[
                        const SizedBox(width: 8),
                        const Chip(
                          label: Text('Recommended'),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      ],
                    ],
                  ),
                  subtitle: Text(
                    // Only the profile-authored description lands in
                    // the user-visible card. The git repo + ref are
                    // developer details that basic users cannot act
                    // on - they move to a Tooltip on the card so
                    // power users can still inspect them without
                    // leaking into the main copy.
                    _flatten(c.description),
                    maxLines: 4,
                  ),
                  secondary: Tooltip(
                    message: '${c.repo}\n${c.ref}',
                    child: const Icon(Icons.info_outline, size: 18),
                  ),
                ),
              ),
          ],
        ),
      ),
      primaryAction: WizardAction(
        label: 'Continue',
        onPressed: _choice == null
            ? null
            : () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('firmware', _choice!);
                if (context.mounted) context.go('/webui');
              },
      ),
      secondaryActions: [
        WizardAction(
          label: 'Back',
          onPressed: () => context.go('/choose-path'),
        ),
      ],
    );
  }

  // Profile descriptions are often authored as YAML literal blocks
  // (`|`) with hard line breaks at ~80 chars for source readability.
  // Those baked-in newlines render verbatim on wider screens. Collapse
  // single newlines into spaces while preserving paragraph breaks.
  String _flatten(String? text) {
    if (text == null || text.isEmpty) return '';
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'\n{2,}'), '\u0000')
        .replaceAll('\n', ' ')
        .replaceAll('\u0000', '\n\n')
        .trim();
  }
}
