import 'package:flutter/widgets.dart';

/// Lays out [children] in a [columns]-wide grid where every cell in a
/// given row stretches to the row's tallest child. Falls back to a
/// single-column stack when [columns] <= 1.
///
/// Why not just use [Wrap]: in a Wrap, each card sizes to its own
/// content. Cards with thinner blurbs end up shorter than their
/// peers, which reads as broken in a card-pick layout. [GridView]
/// would solve this with a fixed aspect ratio, but our cards are
/// content-driven — pinning a ratio either truncates the long ones
/// or wastes space under the short ones.
///
/// The implementation slices [children] into rows of up to [columns]
/// items, wraps each row in [IntrinsicHeight] + [Row] with
/// `crossAxisAlignment: stretch`, and gives each cell an [Expanded]
/// flex of 1. The last row's children also expand: a row with one
/// card spans the full width (the natural reading of a "combined"
/// affordance like Both), and a row with two-of-three is two
/// half-width cells.
class EqualHeightGrid extends StatelessWidget {
  const EqualHeightGrid({
    super.key,
    required this.children,
    required this.columns,
    this.spacing = 12,
    this.runSpacing = 12,
  });

  final List<Widget> children;
  final int columns;
  final double spacing;
  final double runSpacing;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final cols = columns < 1 ? 1 : columns;
    if (cols == 1) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: runSpacing),
            children[i],
          ],
        ],
      );
    }
    final rows = <List<Widget>>[];
    for (var i = 0; i < children.length; i += cols) {
      final end = (i + cols) < children.length ? (i + cols) : children.length;
      rows.add(children.sublist(i, end));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) SizedBox(height: runSpacing),
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var c = 0; c < rows[r].length; c++) ...[
                  if (c > 0) SizedBox(width: spacing),
                  Expanded(child: rows[r][c]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}
