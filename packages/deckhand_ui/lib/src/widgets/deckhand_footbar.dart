import 'package:flutter/material.dart';
import 'package:forge/forge.dart';

/// Bottom chrome strip — 24px tall, holds machine-shaped status
/// columns ("SIDECAR 0.4.1", "PROFILE phrozen-arco@v0.4.1", etc).
///
/// Renders [items] left-to-right, separated by middot bullets. Items
/// pushed via [trailing] are right-aligned so version/host slots can
/// live opposite the build slots.
///
/// Pure presentation. Mono throughout — this strip is data, not body
/// copy. Rebuilt on forge tokens: the surface/border come from
/// [context.brandColors] and the text uses forge's technical mono
/// styles ([context.labelTechnical] / [context.dataTiny]).
class DeckhandFootbar extends StatelessWidget {
  const DeckhandFootbar({
    super.key,
    this.items = const [],
    this.trailing = const [],
  });

  final List<DeckhandFootbarItem> items;
  final List<DeckhandFootbarItem> trailing;

  static const double height = 24;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: brand.bgAlt,
        border: Border(top: BorderSide(color: brand.borderStrong)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            _FootbarCell(item: items[i]),
            if (i < items.length - 1) const _Sep(),
          ],
          const Spacer(),
          for (var i = 0; i < trailing.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            _FootbarCell(item: trailing[i]),
          ],
        ],
      ),
    );
  }
}

class DeckhandFootbarItem {
  const DeckhandFootbarItem({required this.label, required this.value});
  final String label;
  final String value;
}

class _FootbarCell extends StatelessWidget {
  const _FootbarCell({required this.item});
  final DeckhandFootbarItem item;

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    // labelTechnical/dataTiny carry the brand mono family + tabular
    // figures; shrink to the 10px footbar scale and drop the technical
    // label's letter-spacing so the strip stays dense.
    final labelStyle = context.labelTechnical.copyWith(
      fontSize: 10,
      letterSpacing: 0,
      color: brand.ink3,
      height: 1,
    );
    final valueStyle = context.dataTiny.copyWith(
      fontSize: 10,
      color: brand.ink4,
      height: 1,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(item.label.toUpperCase(), style: labelStyle),
        const SizedBox(width: 6),
        Text(item.value, style: valueStyle),
      ],
    );
  }
}

class _Sep extends StatelessWidget {
  const _Sep();

  @override
  Widget build(BuildContext context) {
    final brand = context.brandColors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Text(
        '·',
        style: context.dataTiny.copyWith(
          fontSize: 10,
          color: brand.ink4,
          height: 1,
        ),
      ),
    );
  }
}
