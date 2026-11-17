part of 'list.dart';

bool _isEnd(ItemPosition? position) =>
    position == ItemPosition.end || position == ItemPosition.startAndEnd;

BorderRadius listItemRadiusOf(ItemPosition? position) {
  final isStart =
      position == ItemPosition.start || position == ItemPosition.startAndEnd;
  return AppRadius.vertical(
    top: isStart ? AppCorner.xl : AppCorner.none,
    bottom: _isEnd(position) ? AppCorner.xl : AppCorner.none,
  );
}

class DecorationListItem extends StatelessWidget {
  final Widget title;
  final Widget? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final bool? isSelected;
  final double? horizontalTitleGap;
  final EdgeInsetsGeometry? contentPadding;
  final VoidCallback? onPressed;

  /// Suppresses the card's own ink wash; a transparent value paints no band at all, for a
  /// row whose leading icon carries the press feedback.
  final Color? pressTint;

  /// Focus/disabled states for the card's press surface (a toolbox icon listens).
  final WidgetStatesController? statesController;
  final double? minVerticalPadding;
  final bool invalid;

  const DecorationListItem({
    super.key,
    this.contentPadding,
    required this.title,
    this.leading,
    this.trailing,
    this.subtitle,
    this.isSelected,
    this.onPressed,
    this.pressTint,
    this.statesController,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.invalid = false,
  });

  @override
  Widget build(BuildContext context) {
    final proxy = ProxyDecoratorProvider.of(context);
    final proxyDecorator = proxy?.isProxyDecorator ?? false;
    final sortable = SortableItem.maybeOf(context);
    final sorting = sortable?.sorting ?? false;
    final position = ItemPositionProvider.of(context)?.position;
    final isEnd = _isEnd(position);
    final row = _ListRowSeparator(
      separated: !proxyDecorator && !isEnd,
      emphasized: invalid,
      endIndent: 14,
      child: Card(
        shape: AppShape.of(listItemRadiusOf(position)),
        isError: invalid,
        isSelected: isSelected,
        padding: EdgeInsets.zero,
        pressTint: pressTint,
        statesController: statesController,
        inert: sorting,
        onPressed: proxyDecorator ? null : onPressed,
        child: LayoutBuilder(
          builder: (_, constraints) {
            final tile = ListRow(
              leading: leading == null
                  ? null
                  : IgnorePointer(ignoring: sorting, child: leading),
              padding:
                  contentPadding ??
                  const EdgeInsets.only(right: 16, left: 16),
              title: _ListRowSeparatorStart(child: title),
              subtitle: subtitle,
              minVerticalPadding:
                  minVerticalPadding ?? listRowVerticalPadding,
              horizontalTitleGap: horizontalTitleGap,
              trailing: sortable == null
                  ? trailing
                  : SortableTrailing(item: sortable, child: trailing),
            );
            if (constraints.maxHeight >= double.infinity) {
              return tile;
            }
            return SizedBox(height: constraints.maxHeight, child: tile);
          },
        ),
      ),
    );
    if (!proxyDecorator) {
      return row;
    }
    // A change of the card's shape eases in over the button's own animation
    // duration, which would trail the lift; the clip follows it frame by frame.
    return ClipRSuperellipse(
      borderRadius: AppRadius.all(AppCorner.xl * proxy!.lift),
      child: row,
    );
  }
}

class SelectedDecorationListItem extends StatelessWidget {
  final bool isSelected;
  final bool isEditing;
  final Widget title;
  final Widget? subtitle;
  final VoidCallback onSelected;
  final VoidCallback onPressed;
  final double? horizontalTitleGap;
  final Widget? leading;
  final bool invalid;
  final double? minVerticalPadding;

  const SelectedDecorationListItem({
    super.key,
    required this.isSelected,
    required this.onSelected,
    this.horizontalTitleGap,
    this.isEditing = false,
    this.invalid = false,
    required this.title,
    required this.onPressed,
    this.minVerticalPadding,
    this.subtitle,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    return DecorationListItem(
      title: title,
      minVerticalPadding: minVerticalPadding,
      contentPadding: const EdgeInsets.only(left: 16, right: 0),
      isSelected: isSelected,
      invalid: invalid,
      leading: leading,
      horizontalTitleGap: horizontalTitleGap,
      onPressed: () {
        if (isEditing) {
          onSelected();
          return;
        }
        onPressed();
      },
      subtitle: subtitle,
      trailing: Checkbox(
        value: isSelected,
        isCircle: true,
        onChanged: (_) {
          onSelected();
        },
      ),
    );
  }
}
