import 'dart:io';

import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../widgets/deckhand_loading.dart';
import '../widgets/host_approval_gate.dart';
import '../widgets/id_tag.dart';
import '../widgets/status_pill.dart';
import '../widgets/wizard_scaffold.dart';

class PickPrinterScreen extends ConsumerStatefulWidget {
  const PickPrinterScreen({super.key});

  @override
  ConsumerState<PickPrinterScreen> createState() => _PickPrinterScreenState();
}

class _PickPrinterScreenState extends ConsumerState<PickPrinterScreen> {
  Future<ProfileRegistry>? _registryFuture;
  String? _selectedId;
  String _query = '';

  Future<ProfileRegistry> _fetchRegistry(BuildContext context) {
    // The fetch goes through HostApprovalGate so the network allow-
    // list prompt fires before the actual HTTP / git call. The gate
    // either approves + retries, or rethrows HostNotApprovedException
    // for the FutureBuilder to render via _ErrorBox.
    return HostApprovalGate.runGuarded<ProfileRegistry>(
      ref,
      context,
      action: () => ref.read(profileServiceProvider).fetchRegistry(),
    );
  }

  @override
  Widget build(BuildContext context) {
    _registryFuture ??= _fetchRegistry(context);
    return FutureBuilder<ProfileRegistry>(
      future: _registryFuture,
      builder: (context, snap) {
        Widget body;
        ProfileRegistryEntry? selectedEntry;
        if (snap.connectionState != ConnectionState.done) {
          body = const DeckhandLoadingBlock(
            title: 'Loading printer profiles',
            message:
                'Deckhand is loading the approved profile registry before '
                'showing printer choices.',
          );
        } else if (snap.hasError) {
          body = _ErrorBox(
            message: 'Failed to load printer registry: ${snap.error}',
            onRetry: () => setState(() {
              _registryFuture = _fetchRegistry(context);
            }),
          );
        } else {
          final all = snap.data!.entries
              .where((e) => e.status != 'stub')
              .toList(growable: false);
          final filtered = _filter(all, _query);
          selectedEntry = _selectedId == null
              ? null
              : all.firstWhere(
                  (e) => e.id == _selectedId,
                  orElse: () => all.first,
                );
          body = _Body(
            registrySize: all.length,
            visible: filtered,
            query: _query,
            selectedId: _selectedId,
            onQuery: (q) => setState(() => _query = q),
            onSelect: (id) => setState(() => _selectedId = id),
          );
        }
        final primaryLabel = selectedEntry == null
            ? t.common.action_continue
            : 'Continue with ${selectedEntry.displayName}';
        return WizardScaffold(
          screenId: 'S15-pick-printer',
          title: 'Which printer are you setting up?',
          helperText:
              'Pick a profile from the registry. Everything downstream — '
              'credentials, host allow-list, services to remove — is driven '
              'by what you choose.',
          body: body,
          primaryAction: WizardAction(
            label: primaryLabel,
            onPressed: _selectedId == null
                ? null
                : () async {
                    final controller = ref.read(wizardControllerProvider);
                    await HostApprovalGate.runGuarded<void>(
                      ref,
                      context,
                      // `force: true` wipes the on-disk profile cache
                      // before re-cloning. Cheap (a sub-second shallow
                      // clone) and removes the "I just pushed a fix to
                      // deckhand-profiles, why isn't it showing up?"
                      // confusion.
                      action: () =>
                          controller.loadProfile(_selectedId!, force: true),
                    );
                    if (context.mounted) context.go('/choose-path');
                  },
          ),
          secondaryActions: [
            WizardAction(
              label: t.common.action_back,
              onPressed: () => context.go('/'),
              isBack: true,
            ),
          ],
        );
      },
    );
  }

  List<ProfileRegistryEntry> _filter(
    List<ProfileRegistryEntry> input,
    String query,
  ) {
    if (query.isEmpty) return input;
    final q = query.toLowerCase();
    return input
        .where(
          (e) =>
              e.displayName.toLowerCase().contains(q) ||
              e.manufacturer.toLowerCase().contains(q) ||
              e.model.toLowerCase().contains(q),
        )
        .toList(growable: false);
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.registrySize,
    required this.visible,
    required this.query,
    required this.selectedId,
    required this.onQuery,
    required this.onSelect,
  });

  final int registrySize;
  final List<ProfileRegistryEntry> visible;
  final String query;
  final String? selectedId;
  final void Function(String) onQuery;
  final void Function(String) onSelect;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 320,
              child: TextField(
                onChanged: onQuery,
                decoration: InputDecoration(
                  prefixIcon: Icon(Icons.search, size: 16, color: tokens.text4),
                  hintText: 'Search $registrySize profiles…',
                ),
              ),
            ),
            const Spacer(),
            Text(
              'REGISTRY',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: DeckhandTokens.tXs,
                color: tokens.text4,
                letterSpacing: 0.04 * DeckhandTokens.tXs,
              ),
            ),
            const SizedBox(width: 6),
            IdTag('$registrySize entries'),
          ],
        ),
        const SizedBox(height: 16),
        if (visible.isEmpty)
          _EmptyState(query: query)
        else
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 12.0;
              final cardWidth = _cardWidth(constraints.maxWidth, spacing);
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final e in visible)
                    SizedBox(
                      width: cardWidth,
                      child: _SpecCard(
                        entry: e,
                        selected: selectedId == e.id,
                        onTap: () => onSelect(e.id),
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 20),
        Row(
          children: [
            Icon(Icons.menu_book_outlined, size: 14, color: tokens.text3),
            const SizedBox(width: 8),
            Text(
              'My printer isn\'t here — ',
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: tokens.text3,
              ),
            ),
            // The contribute link opens the deckhand-profiles repo's
            // CONTRIBUTING guide in the user's default browser.
            // Wrapped in MouseRegion + InkWell so the cursor flips to
            // a pointer (clickable affordance) and the click actually
            // does something — the previous version was a plain Text
            // that read as a button but was inert.
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: _openContributeLink,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'contribute a profile',
                      style: TextStyle(
                        fontFamily: DeckhandTokens.fontSans,
                        fontSize: DeckhandTokens.tSm,
                        color: tokens.accent,
                        decoration: TextDecoration.underline,
                        decorationColor: tokens.accent,
                      ),
                    ),
                    const SizedBox(width: 4),
                    // Trailing arrow rendered as an Icon rather than
                    // U+2192 glyph — the unicode arrow is banned from
                    // the printer picker (regression guard from a
                    // prior copy bug).
                    Icon(Icons.arrow_forward, size: 12, color: tokens.accent),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Resolve the card width for a given content width. Aim for 3
  /// columns at desktop width, 2 columns mid-range, 1 column when
  /// the chrome shrinks below 480px.
  double _cardWidth(double contentWidth, double spacing) {
    if (contentWidth >= 880) {
      return (contentWidth - 2 * spacing) / 3;
    }
    if (contentWidth >= 480) {
      return (contentWidth - spacing) / 2;
    }
    return contentWidth;
  }

  /// Open the deckhand-profiles repo's contributing guide in the
  /// user's default browser. Uses platform-native shell-out so we
  /// don't pull `url_launcher` for a single link.
  Future<void> _openContributeLink() async {
    const url =
        'https://github.com/CepheusLabs/deckhand-profiles/blob/main/CONTRIBUTING.md';
    try {
      if (Platform.isWindows) {
        await Process.run('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [url]);
      } else {
        await Process.run('xdg-open', [url]);
      }
    } catch (_) {
      // Best effort — failing to open the browser shouldn't crash
      // the wizard. The URL is also visible in the rendered text so
      // the user can copy it manually if launching the browser
      // fails (rare on a desktop env).
    }
  }
}

/// Spec-rich printer card. Header (name + mfr + status pill) over a
/// 2x2 mono grid of hardware highlights (SBC / KIN / MCU / EXTRAS)
/// over a footer line (version + last-updated). Selected state
/// adds a 3px accent left rail, accent-tinted background, and a
/// circular check badge in the top-right corner.
class _SpecCard extends StatefulWidget {
  const _SpecCard({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final ProfileRegistryEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_SpecCard> createState() => _SpecCardState();
}

class _SpecCardState extends State<_SpecCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final entry = widget.entry;
    final selected = widget.selected;

    final borderColor = selected
        ? tokens.accent
        : _hovering
        ? tokens.rule
        : tokens.line;
    final backgroundColor = selected
        ? Color.alphaBlend(tokens.accent.withValues(alpha: 0.04), tokens.ink1)
        : tokens.ink1;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          // Subtle hover lift. Matches the design's "feels physically
          // pickable" intent without overdoing it. `translationValues`
          // writes a proper affine translation; the previous
          // `translateByDouble(..., 0)` form passed w=0, which the
          // matrix treats as a direction vector at infinity and made
          // the card vanish on hover.
          transform: _hovering && !selected
              ? Matrix4.translationValues(0, -1, 0)
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: backgroundColor,
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(DeckhandTokens.r3),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: tokens.accent.withValues(alpha: 0.18),
                      blurRadius: 20,
                      offset: const Offset(0, 6),
                    ),
                  ]
                : _hovering
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.18),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Stack(
            children: [
              if (selected)
                // 3px left rail anchors the selected state and gives
                // the card a measurable "you picked this" silhouette
                // even when scrolled in a dense list.
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  child: Container(
                    width: 3,
                    decoration: BoxDecoration(
                      color: tokens.accent,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(DeckhandTokens.r3),
                        bottomLeft: Radius.circular(DeckhandTokens.r3),
                      ),
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Header(entry: entry),
                    const SizedBox(height: 12),
                    _SpecGrid(entry: entry),
                    const SizedBox(height: 12),
                    _Footer(entry: entry, tokens: tokens),
                  ],
                ),
              ),
              if (selected)
                Positioned(
                  top: 10,
                  right: 10,
                  child: _SelBadge(tokens: tokens),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.entry});
  final ProfileRegistryEntry entry;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                entry.displayName,
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontSans,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.01 * 16,
                  height: 1.2,
                  color: tokens.text,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                entry.manufacturer.toUpperCase(),
                style: TextStyle(
                  fontFamily: DeckhandTokens.fontMono,
                  fontSize: 10,
                  letterSpacing: 0.06 * 10,
                  color: tokens.text4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        StatusPill.fromProfileStatus(context, entry.status),
      ],
    );
  }
}

/// 2x2 mono spec grid. Cells share a single hairline border and
/// are separated by 1px rules — the design's "lab readout" look.
class _SpecGrid extends StatelessWidget {
  const _SpecGrid({required this.entry});
  final ProfileRegistryEntry entry;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final cells = <_SpecCell>[
      _SpecCell('SBC', entry.sbc),
      _SpecCell('KINEMATICS', entry.kinematics),
      _SpecCell('MCU', entry.mcu),
      _SpecCell('EXTRAS', entry.extras),
    ];
    return Container(
      decoration: BoxDecoration(
        // The "background" you see between cells is just the soft-line
        // colour leaking through the 1px gaps in the grid below.
        color: tokens.lineSoft,
        border: Border.all(color: tokens.lineSoft),
        borderRadius: BorderRadius.circular(DeckhandTokens.r1),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: cells[0].build(context)),
              const SizedBox(width: 1),
              Expanded(child: cells[1].build(context)),
            ],
          ),
          const SizedBox(height: 1),
          Row(
            children: [
              Expanded(child: cells[2].build(context)),
              const SizedBox(width: 1),
              Expanded(child: cells[3].build(context)),
            ],
          ),
        ],
      ),
    );
  }
}

class _SpecCell {
  const _SpecCell(this.label, this.value);
  final String label;
  final String? value;

  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      color: tokens.ink1,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 9,
              letterSpacing: 0.08 * 9,
              color: tokens.text4,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value == null || value!.isEmpty ? '—' : value!,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 12,
              letterSpacing: 0.02 * 12,
              color: tokens.text2,
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.entry, required this.tokens});
  final ProfileRegistryEntry entry;
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    final left = entry.latestTag ?? 'untagged';
    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: tokens.lineSoft)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              left,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontMono,
                fontSize: 10,
                letterSpacing: 0.04 * 10,
                color: tokens.text4,
              ),
            ),
          ),
          Text(
            entry.id,
            style: TextStyle(
              fontFamily: DeckhandTokens.fontMono,
              fontSize: 10,
              letterSpacing: 0.04 * 10,
              color: tokens.text4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SelBadge extends StatelessWidget {
  const _SelBadge({required this.tokens});
  final DeckhandTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: tokens.accent,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: tokens.accent.withValues(alpha: 0.4),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Icon(Icons.check, size: 12, color: tokens.accentFg),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 48),
      width: double.infinity,
      decoration: BoxDecoration(
        color: tokens.ink1,
        border: Border.all(color: tokens.line),
        borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      ),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 24, color: tokens.text3),
          const SizedBox(height: 12),
          Text(
            'No profiles match "$query"',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tMd,
              color: tokens.text2,
            ),
          ),
        ],
      ),
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
