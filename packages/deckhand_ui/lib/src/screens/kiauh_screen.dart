import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/json_safety.dart';
import '../widgets/selection_card.dart';
import '../widgets/wizard_scaffold.dart';

class KiauhScreen extends ConsumerStatefulWidget {
  const KiauhScreen({super.key});

  @override
  ConsumerState<KiauhScreen> createState() => _KiauhScreenState();
}

class _KiauhScreenState extends ConsumerState<KiauhScreen> {
  bool? _install;

  @override
  Widget build(BuildContext context) {
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final kiauh = profile?.stack.kiauh ?? const <String, dynamic>{};
    final wizard = jsonStringKeyMap(kiauh['wizard']) ?? const {};
    final explainer =
        jsonString(wizard['explainer'])?.trim() ??
        'The Klipper Installation And Update Helper is an interactive '
            'SSH menu for maintaining your stack after Deckhand finishes — '
            'install another instance, swap branches, repair a service.';
    final examples = jsonStringList(wizard['examples']);
    final probe = controller.printerState;
    final alreadyInstalled = probe.stackInstalls['kiauh']?.installed ?? false;
    final defaultInstall = kiauh['default_install'] is bool
        ? kiauh['default_install'] as bool
        : true;
    final repo = jsonString(kiauh['repo'])?.trim();
    _install ??= alreadyInstalled ? false : defaultInstall;

    return WizardScaffold(
      screenId: 'S107-kiauh',
      title: 'Install KIAUH for ongoing maintenance?',
      helperText: explainer,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (alreadyInstalled)
            _AlreadyInstalledNotice(
              path: probe.stackInstalls['kiauh']?.path ?? '~/kiauh',
            ),
          if (alreadyInstalled) const SizedBox(height: 14),
          LayoutBuilder(
            builder: (context, constraints) {
              final twoCol = constraints.maxWidth >= 720;
              final installCard = _KiauhCard(
                icon: Icons.terminal,
                title: alreadyInstalled
                    ? 'Re-install (clean clone)'
                    : 'Install KIAUH',
                recommended: !alreadyInstalled,
                body:
                    'Adds ~/kiauh/ on the printer. Run ./kiauh.sh '
                    'over SSH for an interactive menu.',
                selected: _install == true,
                onTap: () => setState(() => _install = true),
              );
              final skipCard = _KiauhCard(
                icon: Icons.close,
                title: alreadyInstalled ? 'Skip (keep existing)' : 'Skip',
                body: alreadyInstalled
                    ? 'Leave the existing checkout alone. Re-run from '
                          'Settings later if you need a clean copy.'
                    : repo == null || repo.isEmpty
                    ? 'You can install it later over SSH.'
                    : 'You can install it later from $repo.',
                selected: _install == false,
                onTap: () => setState(() => _install = false),
              );
              if (twoCol) {
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: installCard),
                      const SizedBox(width: 12),
                      Expanded(child: skipCard),
                    ],
                  ),
                );
              }
              return Column(
                children: [installCard, const SizedBox(height: 12), skipCard],
              );
            },
          ),
          if (examples.isNotEmpty) ...[
            const SizedBox(height: 16),
            _WhatItDoes(examples: examples),
          ],
        ],
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
        disabledReason: _install == null
            ? 'Choose whether to install KIAUH first.'
            : null,
        onPressed: _install == null
            ? null
            : () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('kiauh', _install!);
                if (context.mounted) context.go('/screen-choice');
              },
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/webui'),
          isBack: true,
        ),
      ],
    );
  }
}

class _AlreadyInstalledNotice extends StatelessWidget {
  const _AlreadyInstalledNotice({required this.path});
  final String path;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: tokens.info.withValues(alpha: 0.10),
        border: Border.all(color: tokens.info.withValues(alpha: 0.35)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle_outline, size: 16, color: tokens.info),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: DeckhandTokens.tSm,
                  color: tokens.info,
                ),
                children: [
                  const TextSpan(text: 'KIAUH already installed at '),
                  TextSpan(
                    text: path,
                    style: const TextStyle(fontFamily: DeckhandTokens.fontMono),
                  ),
                  const TextSpan(text: '. Default is to skip.'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KiauhCard extends StatelessWidget {
  const _KiauhCard({
    required this.icon,
    required this.title,
    required this.body,
    required this.selected,
    required this.onTap,
    this.recommended = false,
  });
  final IconData icon;
  final String title;
  final String body;
  final bool selected;
  final bool recommended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SelectionCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(20, 18, 40, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: tokens.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tLg,
                    fontWeight: FontWeight.w500,
                    color: tokens.text,
                  ),
                ),
              ),
              if (recommended) _RecommendedPill(),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tSm,
              color: tokens.text2,
              height: 1.55,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecommendedPill extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: tokens.ok.withValues(alpha: 0.10),
        border: Border.all(color: tokens.ok.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        'Recommended',
        style: TextStyle(
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tXs,
          color: tokens.ok,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _WhatItDoes extends StatelessWidget {
  const _WhatItDoes({required this.examples});
  final List<String> examples;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        title: Text(
          'What KIAUH does for you',
          style: TextStyle(
            fontFamily: DeckhandTokens.fontSans,
            fontSize: DeckhandTokens.tMd,
            fontWeight: FontWeight.w500,
            color: tokens.text,
          ),
        ),
        children: [
          for (final ex in examples)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: tokens.text4,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      ex,
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontSans,
                        fontSize: DeckhandTokens.tSm,
                        color: tokens.text2,
                        height: 1.6,
                      ),
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
