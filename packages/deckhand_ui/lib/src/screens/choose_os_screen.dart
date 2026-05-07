import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/equal_height_grid.dart';
import '../widgets/selection_card.dart';
import '../widgets/wizard_scaffold.dart';

class ChooseOsScreen extends ConsumerStatefulWidget {
  const ChooseOsScreen({super.key});

  @override
  ConsumerState<ChooseOsScreen> createState() => _ChooseOsScreenState();
}

class _ChooseOsScreenState extends ConsumerState<ChooseOsScreen> {
  String? _choice;
  bool _seeded = false;

  void _seedChoice(List<OsImageOption> options) {
    if (_seeded) return;
    final controller = ref.read(wizardControllerProvider);
    final saved = controller.decision<String>('flash.os');
    if (saved != null && saved.isNotEmpty) {
      _choice = saved;
      _seeded = true;
      return;
    }
    OsImageOption? pick;
    for (final OsImageOption o in options) {
      if (o.recommended) {
        pick = o;
        break;
      }
    }
    pick ??= options.isEmpty ? null : options.first;
    _choice = pick?.id;
    _seeded = true;
  }

  @override
  Widget build(BuildContext context) {
    final options =
        ref.watch(wizardControllerProvider).profile?.os.freshInstallOptions ??
        const <OsImageOption>[];
    _seedChoice(options);

    return WizardScaffold(
      screenId: 'S210-choose-os',
      title: 'Pick the OS image.',
      helperText:
          'Either pull a fresh Armbian build, or supply your own .img.xz '
          'for air-gapped installs. Deckhand downloads, verifies, and '
          'writes it to the disk you picked.',
      body: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final cols = w >= 1080 ? 3 : (w >= 720 ? 2 : 1);
          return EqualHeightGrid(
            columns: cols,
            children: [
              for (final opt in options)
                _OsCard(
                  name: opt.displayName,
                  notes: opt.notes?.trim() ?? '',
                  recommended: opt.recommended,
                  size: _humanSize(opt.sizeBytesApprox),
                  shortSha: _shortSha(opt.sha256),
                  fullSha: opt.sha256 ?? '',
                  selected: _choice == opt.id,
                  onTap: () => setState(() => _choice = opt.id),
                ),
            ],
          );
        },
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
        onPressed: _choice == null
            ? null
            : () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision('flash.os', _choice!);
                if (context.mounted) context.go('/flash-confirm');
              },
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/flash-target'),
          isBack: true,
        ),
      ],
    );
  }

  String _humanSize(int? bytes) {
    if (bytes == null) return '—';
    final gib = bytes / (1 << 30);
    if (gib >= 1) return '${gib.toStringAsFixed(1)} GiB';
    final mib = bytes / (1 << 20);
    return '${mib.toStringAsFixed(0)} MiB';
  }

  String _shortSha(String? sha) {
    if (sha == null || sha.isEmpty) return '—';
    if (sha.length <= 12) return sha;
    return '${sha.substring(0, 6)}…${sha.substring(sha.length - 4)}';
  }
}

class _OsCard extends StatelessWidget {
  const _OsCard({
    required this.name,
    required this.notes,
    required this.recommended,
    required this.size,
    required this.shortSha,
    required this.fullSha,
    required this.selected,
    required this.onTap,
  });

  final String name;
  final String notes;
  final bool recommended;
  final String size;
  final String shortSha;
  final String fullSha;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SelectionCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(18, 16, 40, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.download_outlined,
                  size: 18,
                  color: tokens.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                // Allow titles like "Armbian Trixie (Debian 13, CLI)
                // for MKS Pi" to wrap to two lines instead of getting
                // ellipsized — they don't fit on one line in any of
                // the responsive column widths and the truncation
                // hides the version that distinguishes the options.
                child: Text(
                  name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tLg,
                    fontWeight: FontWeight.w500,
                    color: tokens.text,
                    height: 1.25,
                  ),
                ),
              ),
              if (recommended) ...[
                const SizedBox(width: 8),
                _Pill(label: 'rec.', color: tokens.ok),
              ],
            ],
          ),
          if (notes.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              notes,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.text2,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: tokens.line)),
            ),
            padding: const EdgeInsets.only(top: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _MetaRow(label: 'size', value: size),
                // The sha256 is 64 hex chars — never going to fit on
                // one row, so we show a short ellipsized version with
                // a tooltip + click-to-copy that reveals the full
                // value. The previous implementation just showed
                // "56218f…a509" with no way to see the rest.
                _ShaRow(short: shortSha, full: fullSha, tokens: tokens),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ShaRow extends StatelessWidget {
  const _ShaRow({
    required this.short,
    required this.full,
    required this.tokens,
  });
  final String short;
  final String full;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    // Dead-simple. Two earlier iterations of this widget tried to be
    // clever with LayoutBuilder + Tooltip.richMessage / WidgetSpan to
    // adapt to card width and to force single-line tooltip layout —
    // both broke choose-os rendering at runtime in ways that
    // analyzer didn't catch (white screen on navigation in). This
    // version is the lowest-risk fallback: short form inline, an
    // explicit "copy" button next to it for the full value. No
    // tooltip, no LayoutBuilder, nothing nested.
    final hasFull = full.isNotEmpty;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 60,
            child: Text(
              'sha256',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 11,
                color: tokens.text4,
              ),
            ),
          ),
          Expanded(
            child: Text(
              short,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 11,
                color: tokens.text3,
              ),
            ),
          ),
          if (hasFull)
            IconButton(
              tooltip: 'copy full sha256',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              iconSize: 12,
              splashRadius: 14,
              onPressed: () {
                Clipboard.setData(ClipboardData(text: full));
                final messenger = ScaffoldMessenger.maybeOf(context);
                messenger?.showSnackBar(
                  const SnackBar(
                    content: Text('sha256 copied to clipboard'),
                    duration: Duration(seconds: 2),
                  ),
                );
              },
              icon: Icon(Icons.content_copy, color: tokens.text4),
            ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 11,
                color: tokens.text4,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 11,
                color: tokens.text3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: DeckhandTokens.fontSans,
          fontSize: DeckhandTokens.tXs,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
