import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../i18n/translations.g.dart';
import '../providers.dart';
import '../theming/deckhand_tokens.dart';
import '../utils/json_safety.dart';
import '../widgets/dashed_divider.dart';
import '../widgets/equal_height_grid.dart';
import '../widgets/selection_card.dart';
import '../widgets/wizard_scaffold.dart';

class WebuiScreen extends ConsumerStatefulWidget {
  const WebuiScreen({super.key});

  @override
  ConsumerState<WebuiScreen> createState() => _WebuiScreenState();
}

class _WebuiScreenState extends ConsumerState<WebuiScreen> {
  final _selected = <String>{};
  bool _neither = false;
  bool _seeded = false;
  bool _userChanged = false;
  String? _autoSeedSignature;

  void _replaceSelection(Iterable<String> ids) {
    _selected
      ..clear()
      ..addAll(ids.where((id) => id.isNotEmpty));
    _neither = false;
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(wizardStateProvider);
    final controller = ref.watch(wizardControllerProvider);
    final profile = controller.profile;
    final webui = profile?.stack.webui ?? const {};
    final choices = _webuiChoices(webui);
    final defaultChoices = jsonStringList(webui['default_choices']);
    final allowNone = webui['allow_none'] == true;
    final probe = controller.printerState;

    final saved = controller.state.decisions['webui'];
    final choiceIds = choices.map((c) => jsonString(c['id'])!).toSet();
    final installed = [
      for (final raw in choices)
        if (probe.stackInstalls[jsonString(raw['id'])]?.installed == true)
          jsonString(raw['id'])!,
    ];
    final autoIds = installed.isNotEmpty ? installed : defaultChoices;
    final autoSeedSignature = '${choiceIds.join('|')}::${autoIds.join('|')}';

    // Seed from persisted wizard decisions before applying profile or
    // probe defaults. If the user has not touched this screen during
    // this mount, keep auto defaults responsive to inventory/probe
    // changes; once they click, preserve their explicit choice.
    if (!_seeded) {
      if (saved is List) {
        _replaceSelection(saved.whereType<String>());
        _neither = _selected.isEmpty && allowNone;
      } else {
        _replaceSelection(autoIds);
      }
      _seeded = true;
      _autoSeedSignature = autoSeedSignature;
    } else if (!_userChanged &&
        saved == null &&
        _autoSeedSignature != autoSeedSignature) {
      _replaceSelection(autoIds);
      _autoSeedSignature = autoSeedSignature;
    }

    final hasSelection = _selected.isNotEmpty;
    final canContinue = hasSelection || (_neither && allowNone);

    return WizardScaffold(
      screenId: 'S105-webui',
      title: t.webui.title,
      helperText: t.webui.helper,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!canContinue)
            _RequirementBanner(message: t.webui.requirement_missing),
          if (canContinue)
            _RequirementBanner(message: t.webui.requirement_ok, ok: true),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              // Synthesize a "Both" affordance when exactly two web
              // UIs are on offer — matches the design source's
              // explicit third card. Selected state means every
              // available choice is in `_selected`. Selecting it
              // selects all; deselecting clears all.
              final showBoth = choices.length == 2;
              final allIds = choiceIds;
              final bothSelected =
                  !_neither &&
                  allIds.isNotEmpty &&
                  _selected.containsAll(allIds);
              final cols = width >= 960
                  ? 3
                  : width >= 640
                  ? 2
                  : 1;
              return EqualHeightGrid(
                columns: cols,
                children: [
                  for (final raw in choices)
                    _WebuiCard(
                      raw: raw,
                      // When "Both" is the active selection we
                      // visually mark the discrete cards as
                      // selected too — they're functionally part
                      // of the same set.
                      selected:
                          !_neither &&
                          _selected.contains(jsonString(raw['id'])),
                      installed: probe.stackInstalls[jsonString(raw['id'])],
                      descriptionBuilder: _userFacingBlurb,
                      onTap: () => setState(() {
                        final id = jsonString(raw['id'])!;
                        _userChanged = true;
                        _neither = false;
                        if (_selected.contains(id)) {
                          _selected.remove(id);
                        } else {
                          _selected.add(id);
                        }
                      }),
                    ),
                  if (showBoth)
                    _BothCard(
                      selected: bothSelected,
                      ports: choices
                          .map((c) => (c['default_port'] ?? '?').toString())
                          .join(', '),
                      onTap: () => setState(() {
                        _userChanged = true;
                        _neither = false;
                        if (bothSelected) {
                          _selected.clear();
                        } else {
                          _selected
                            ..clear()
                            ..addAll(allIds);
                        }
                      }),
                    ),
                ],
              );
            },
          ),
          if (allowNone) ...[
            const SizedBox(height: 16),
            _NeitherTile(
              checked: _neither,
              onChanged: (v) => setState(() {
                _userChanged = true;
                _neither = v;
                if (v) _selected.clear();
              }),
            ),
          ],
        ],
      ),
      primaryAction: WizardAction(
        label: t.common.action_continue,
        disabledReason: _webuiDisabledReason(
          canContinue: canContinue,
          allowNone: allowNone,
        ),
        onPressed: canContinue
            ? () async {
                await ref
                    .read(wizardControllerProvider)
                    .setDecision(
                      'webui',
                      _neither ? const <String>[] : _selected.toList(),
                    );
                if (context.mounted) context.go('/kiauh');
              }
            : null,
      ),
      secondaryActions: [
        WizardAction(
          label: t.common.action_back,
          onPressed: () => context.go('/firmware'),
          isBack: true,
        ),
      ],
    );
  }

  String? _webuiDisabledReason({
    required bool canContinue,
    required bool allowNone,
  }) {
    if (canContinue) return null;
    if (allowNone) return 'Choose a web UI or select Neither.';
    return 'Select at least one web UI first.';
  }

  /// Prefer a profile-supplied `description`. If absent, fall back to a
  /// terse `<display_name> on port <n>` line so at least the reader knows
  /// which service we're installing. Per-id prose belongs in the
  /// profile YAML, not in this widget.
  String _userFacingBlurb(Map raw) {
    final desc = jsonString(raw['description']);
    if (desc != null && desc.trim().isNotEmpty) return desc.trim();
    final port = raw['default_port'];
    final name = jsonString(raw['display_name']) ?? jsonString(raw['id'])!;
    return port == null ? name : '$name on port $port';
  }
}

List<Map<String, dynamic>> _webuiChoices(Map<dynamic, dynamic> webui) =>
    jsonStringKeyMapList(
      webui['choices'],
    ).where((choice) => jsonString(choice['id'])?.isNotEmpty == true).toList();

/// Bordered banner above the grid that calls out the picking
/// requirement. Doubles as a green "you're good to continue"
/// reassurance once at least one card is selected (or "Neither" is
/// checked when allow_none is set).
class _RequirementBanner extends StatelessWidget {
  const _RequirementBanner({required this.message, this.ok = false});
  final String message;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final color = ok ? tokens.ok : tokens.warn;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.30)),
        borderRadius: BorderRadius.circular(DeckhandTokens.r2),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.info_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontFamily: DeckhandTokens.fontSans,
                fontSize: DeckhandTokens.tSm,
                color: color,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WebuiCard extends StatelessWidget {
  const _WebuiCard({
    required this.raw,
    required this.selected,
    required this.installed,
    required this.descriptionBuilder,
    required this.onTap,
  });

  final Map<String, dynamic> raw;
  final bool selected;
  final InstallState? installed;
  final String Function(Map<String, dynamic>) descriptionBuilder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final id = jsonString(raw['id']) ?? '';
    final name = jsonString(raw['display_name']) ?? id;
    final port = raw['default_port'];
    final isInstalled = installed?.installed ?? false;
    final isActive = installed?.active ?? false;

    return SelectionCard(
      selected: selected,
      onTap: onTap,
      // Reserve room on the right edge so the SelectionCard's check
      // badge doesn't overlap the title row's pill.
      padding: const EdgeInsets.fromLTRB(16, 16, 40, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, size: 18, color: tokens.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tLg,
                    fontWeight: FontWeight.w500,
                    color: tokens.text,
                  ),
                ),
              ),
              if (isInstalled) ...[
                const SizedBox(width: 8),
                _MiniPill(
                  label: isActive ? 'INSTALLED · RUNNING' : 'INSTALLED',
                  color: isActive ? tokens.ok : tokens.info,
                ),
              ],
            ],
          ),
          const SizedBox(height: 10),
          Text(
            descriptionBuilder(raw),
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tSm,
              height: 1.5,
              color: tokens.text2,
            ),
          ),
          const SizedBox(height: 14),
          // Dashed divider matches the design source's
          // `border-top: 1px dashed var(--line)` on the card footer.
          const DashedDivider(),
          const SizedBox(height: 10),
          _MetaRow(label: 'port', value: port == null ? '—' : port.toString()),
          if (raw['asset_pattern'] != null)
            _MetaRow(label: 'asset', value: raw['asset_pattern'].toString()),
        ],
      ),
    );
  }
}

/// One labeled mono row inside a card footer ("port 80" / "asset
/// fluidd.zip"). Pulled out so the column doesn't accumulate
/// inline `Row(... mono... )` boilerplate per metadata field.
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
            width: 50,
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

/// Synthetic third card on the web-UI screen — selecting it picks
/// every available choice in one tap. Mirrors the design source's
/// `{ id: 'both', name: 'Both', desc: 'Coexist on different ports
/// — pick per session.' }` entry.
class _BothCard extends StatelessWidget {
  const _BothCard({
    required this.selected,
    required this.ports,
    required this.onTap,
  });

  final bool selected;
  final String ports;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    return SelectionCard(
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(16, 16, 40, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.dynamic_feed_outlined, size: 18, color: tokens.accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Both',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tLg,
                    fontWeight: FontWeight.w500,
                    color: tokens.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Install both web UIs on their default ports. Open '
            'either from a browser; switch per session.',
            style: TextStyle(
              fontFamily: DeckhandTokens.fontSans,
              fontSize: DeckhandTokens.tSm,
              height: 1.5,
              color: tokens.text2,
            ),
          ),
          const SizedBox(height: 14),
          const DashedDivider(),
          const SizedBox(height: 10),
          _MetaRow(label: 'ports', value: ports),
        ],
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  const _MiniPill({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.40)),
        borderRadius: BorderRadius.circular(9),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: DeckhandTokens.fontMono,
          fontSize: 9,
          color: color,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.06 * 9,
        ),
      ),
    );
  }
}

/// "Neither — I'll handle web UI myself" affordance. Shown only when
/// the profile's `allow_none` is true. Wrapped in a dashed border so
/// it visually separates from the recommended-card grid above.
class _NeitherTile extends StatelessWidget {
  const _NeitherTile({required this.checked, required this.onChanged});
  final bool checked;
  final void Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final tokens = DeckhandTokens.of(context);
    final body = Row(
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: Checkbox(
            value: checked,
            onChanged: (v) => onChanged(v ?? false),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: RichText(
            text: TextSpan(
              children: [
                TextSpan(
                  text: 'Neither',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    fontWeight: FontWeight.w600,
                    color: tokens.text,
                  ),
                ),
                TextSpan(
                  text: ' — I\'ll handle the web UI myself ',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tMd,
                    color: tokens.text2,
                  ),
                ),
                TextSpan(
                  text: '(advanced)',
                  style: TextStyle(
                    fontFamily: DeckhandTokens.fontSans,
                    fontSize: DeckhandTokens.tSm,
                    color: tokens.text3,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
    // Dashed border matches the design's `.check ... border: 1px
    // dashed var(--line)` rule. Switching to a solid accent border
    // when checked keeps the "selected" affordance loud.
    return InkWell(
      onTap: () => onChanged(!checked),
      borderRadius: BorderRadius.circular(DeckhandTokens.r3),
      child: checked
          ? Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: BoxDecoration(
                color: tokens.ink2,
                border: Border.all(color: tokens.accent, width: 1.5),
                borderRadius: BorderRadius.circular(DeckhandTokens.r3),
              ),
              child: body,
            )
          : DashedBorderBox(
              borderRadius: DeckhandTokens.r3,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: body,
            ),
    );
  }
}
