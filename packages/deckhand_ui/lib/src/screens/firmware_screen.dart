import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:forge/forge.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';

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
    final controller = ref.read(wizardControllerProvider);
    final saved = controller.decision<String>('firmware');
    if (saved != null && saved.isNotEmpty) {
      _choice = saved;
      return;
    }
    final profile = controller.profile;
    final choices = profile?.firmware.choices ?? const [];
    _choice =
        profile?.firmware.defaultChoice ??
        (choices.isNotEmpty ? choices.first.id : null);
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(wizardControllerProvider).profile;
    final choices = profile?.firmware.choices ?? const [];

    return ClWizardPageScaffold(
      title: t.firmware.title,
      helperText: t.firmware.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < choices.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            _FirmwareCard(
              displayName: choices[i].displayName,
              description: _flatten(choices[i].description),
              repo: choices[i].repo,
              ref: choices[i].ref,
              recommended: choices[i].recommended,
              selected: _choice == choices[i].id,
              onTap: () => setState(() => _choice = choices[i].id),
            ),
          ],
        ],
      ),
      primaryAction: ClWizardAction(
        label: t.common.action_continue,
        disabledReason: _choice == null
            ? 'Select a firmware option first.'
            : null,
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
        ClWizardAction(
          label: t.common.action_back,
          // Back-target depends on flow because Configure entry differs:
          // stock-keep arrives from /verify; fresh-flash arrives from
          // /first-boot-setup (S250 provisions the freshly-booted OS).
          onPressed: () {
            final flow = ref.read(wizardControllerProvider).state.flow;
            context.go(
              flow == WizardFlow.freshFlash ? '/first-boot-setup' : '/verify',
            );
          },
          isBack: true,
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
    const paragraphBreak = '<deckhand-paragraph-break>';
    return text
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'\n{2,}'), paragraphBreak)
        .replaceAll('\n', ' ')
        .replaceAll(paragraphBreak, '\n\n')
        .trim();
  }
}

/// Selection card for one firmware choice. Mirrors the design
/// language's `.scard` treatment used elsewhere (Pick printer,
/// Choose path) so the selection state actually reads as selected
/// — accent border, soft glow, check badge — instead of a faint
/// gray fill that the user can barely tell apart from unselected.
class _FirmwareCard extends StatelessWidget {
  const _FirmwareCard({
    required this.displayName,
    required this.description,
    required this.repo,
    required this.ref,
    required this.recommended,
    required this.selected,
    required this.onTap,
  });

  final String displayName;
  final String description;
  final String repo;
  final String ref;
  final bool recommended;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return ClSelectionCard(
      selected: selected,
      onTap: onTap,
      // Reserve room on the right so the auto-rendered selected check
      // badge doesn't overlap the trailing info icon.
      padding: const EdgeInsets.fromLTRB(18, 16, 40, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Custom radio dot — Material's RadioListTile draws a
          // radio that fights the ClSelectionCard's corner check. A
          // hand-painted dot in the accent color is enough to read
          // as "this is the selected radio" without the conflict.
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? brand.primary : brand.borderStrong,
                  width: selected ? 5 : 1.5,
                ),
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Title takes all remaining width, with the
                    // optional "Recommended" badge sitting next to
                    // it. The info icon at the end is right-anchored
                    // because Expanded eats every leftover pixel —
                    // the previous layout used Flexible+Spacer which
                    // both carried flex:1 and split the remainder
                    // evenly, parking the icon mid-row.
                    Expanded(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              displayName,
                              overflow: TextOverflow.ellipsis,
                              style: context.clTitleLarge.copyWith(
                                fontWeight: FontWeight.w500,
                                color: brand.ink,
                              ),
                            ),
                          ),
                          if (recommended) ...[
                            const SizedBox(width: 10),
                            // Plain Text rather than ClStatusChip so the
                            // tests that look up
                            // `find.text('Recommended')` keep working
                            // — chips uppercase their label and the
                            // capitalization carries semantic meaning
                            // here (the profile-authored flag
                            // "recommended").
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: brand.good.withValues(alpha: 0.10),
                                border: Border.all(
                                  color: brand.good.withValues(alpha: 0.40),
                                ),
                                borderRadius: BorderRadius.circular(
                                  context.radii.lgPlus,
                                ),
                              ),
                              child: Text(
                                'Recommended',
                                style: context.clLabelSmall.copyWith(
                                  color: brand.good,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    // Repo + ref are devs-only metadata. Surfaced
                    // through a hover tooltip on this info icon
                    // rather than rendered into the body — keeps the
                    // user copy clean. (See firmware_screen_test:
                    // "git repo + ref are NOT rendered in the card
                    // subtitle".)
                    //
                    // preferBelow: false anchors the bubble *above*
                    // the icon. The default is below, which lands
                    // the tooltip directly on top of the description
                    // copy underneath since the icon lives in the
                    // title row.
                    Tooltip(
                      message: '$repo\n$ref',
                      preferBelow: false,
                      verticalOffset: 12,
                      child: Icon(
                        Icons.info_outline,
                        size: 14,
                        color: brand.ink4,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  description,
                  style: context.clBodyMedium.copyWith(
                    color: brand.ink2,
                    height: 1.5,
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
