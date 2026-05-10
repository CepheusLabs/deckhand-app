import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/selection_card.dart';
import '../widgets/status_pill.dart';
import '../widgets/wizard_scaffold.dart';

class ChoosePathScreen extends ConsumerStatefulWidget {
  const ChoosePathScreen({super.key});

  @override
  ConsumerState<ChoosePathScreen> createState() => _ChoosePathScreenState();
}

class _ChoosePathScreenState extends ConsumerState<ChoosePathScreen> {
  WizardFlow _choice = WizardFlow.stockKeep;

  @override
  void initState() {
    super.initState();
    final saved = ref.read(wizardControllerProvider).state.flow;
    if (saved != WizardFlow.none) {
      _choice = saved;
    }
  }

  @override
  Widget build(BuildContext context) {
    return WizardScaffold(
      screenId: 'S40-choose-path',
      title: 'How should we install the new firmware?',
      helperText:
          'Two safe paths. Both end with your printer running Kalico or '
          'Klipper, Moonraker, and your chosen web UI. Pick the one that '
          'matches the blast radius you want.',
      body: LayoutBuilder(
        builder: (context, constraints) {
          final twoColumn = constraints.maxWidth >= 720;
          final keep = _PathCard(
            tag: 'FLOW A',
            badge: const StatusPill(
              label: 'recommended',
              color: Color(0xFF2EA771),
              noDot: true,
            ),
            title: 'Keep my current OS',
            body:
                'Reuse the OS already on your printer; install OSS firmware '
                'in place. Reversible via snapshot.',
            details: const [
              _PathDetail(label: 'flow', value: 'stock-keep'),
              _PathDetail(label: 'reversible', value: 'yes (snapshot)'),
              _PathDetail(label: 'duration', value: '~22 min typical'),
            ],
            selected: _choice == WizardFlow.stockKeep,
            onTap: () => setState(() => _choice = WizardFlow.stockKeep),
          );
          final fresh = _PathCard(
            tag: 'FLOW B',
            badge: const StatusPill(
              label: 'destructive',
              color: Color(0xFFCC4A38),
              noDot: true,
            ),
            title: 'Flash a fresh OS',
            body:
                'Wipe the eMMC and install a clean Armbian image. Slowest '
                'path, cleanest result.',
            details: const [
              _PathDetail(label: 'flow', value: 'fresh-flash'),
              _PathDetail(label: 'reversible', value: 'no'),
              _PathDetail(
                label: 'duration',
                value: '~14 min flash + ~22 min install',
              ),
            ],
            warningKind: _PathWarn.bad,
            warning:
                'Requires an eMMC-to-USB adapter and erases the entire disk.',
            selected: _choice == WizardFlow.freshFlash,
            onTap: () => setState(() => _choice = WizardFlow.freshFlash),
          );
          if (twoColumn) {
            return IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: keep),
                  const SizedBox(width: 12),
                  Expanded(child: fresh),
                ],
              ),
            );
          }
          return Column(children: [keep, const SizedBox(height: 12), fresh]);
        },
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
        onPressed: () {
          ref.read(wizardControllerProvider).setFlow(_choice);
          if (_choice == WizardFlow.stockKeep) {
            // Stock-keep needs an SSH session against the printer's
            // current OS. Connect handles credentials + reachability;
            // Verify reads back the inventory probe before we ask the
            // user to make configuration choices.
            context.go('/connect');
          } else {
            // Fresh-flash bypasses Connect/Verify entirely — the eMMC
            // is being wiped, so there's no current OS to SSH into.
            // The wizard reconnects to the freshly-booted OS at S240
            // (first-boot wait) instead.
            context.go('/flash-target');
          }
        },
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/pick-printer'),
          isBack: true,
        ),
      ],
    );
  }
}

enum _PathWarn { warn, bad }

class _PathDetail {
  const _PathDetail({required this.label, required this.value});
  final String label;
  final String value;
}

class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.tag,
    required this.badge,
    required this.title,
    required this.body,
    required this.details,
    required this.selected,
    required this.onTap,
    this.warningKind,
    this.warning,
  });
  final String tag;
  final Widget badge;
  final String title;
  final String body;
  final List<_PathDetail> details;
  final bool selected;
  final VoidCallback onTap;
  final _PathWarn? warningKind;
  final String? warning;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SelectionCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                tag,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: 10,
                  color: tokens.text4,
                  letterSpacing: 0,
                ),
              ),
              const Spacer(),
              badge,
            ],
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tXl,
              fontWeight: FontWeight.w500,
              color: tokens.text,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            body,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
              height: 1.55,
            ),
          ),
          if (warning != null) ...[
            const SizedBox(height: 12),
            _WarnLine(kind: warningKind ?? _PathWarn.warn, message: warning!),
          ],
          const Spacer(),
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: tokens.line)),
            ),
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final d in details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 100,
                          child: Text(
                            d.label,
                            style: TextStyle(
                              fontFamily: DeckhandTokens.fontMono,
                              fontSize: 10,
                              color: tokens.text4,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            d.value,
                            style: TextStyle(
                              fontFamily: DeckhandTokens.fontMono,
                              fontSize: 10,
                              color: tokens.text3,
                              letterSpacing: 0,
                            ),
                          ),
                        ),
                      ],
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

class _WarnLine extends StatelessWidget {
  const _WarnLine({required this.kind, required this.message});
  final _PathWarn kind;
  final String message;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final color = kind == _PathWarn.bad ? tokens.bad : tokens.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
