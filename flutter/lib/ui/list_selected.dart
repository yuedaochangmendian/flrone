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

class DecorationListItem extends StatefulWidget {
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

  /// Lifts the row on a soft shadow while it is held, the way FlClash raises a pressed card.
  final bool pressShadow;
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
    this.pressShadow = false,
    this.horizontalTitleGap,
    this.minVerticalPadding,
    this.invalid = false,
  });

  @override
  State<DecorationListItem> createState() => _DecorationListItemState();
}

class _DecorationListItemState extends State<DecorationListItem> {
  final _states = WidgetStatesController();

  @override
  void dispose() {
    _states.dispose();
    super.dispose();
  }

  /// FlClash's card lift: two neutral shadows, stronger in the dark where a black shadow
  /// would otherwise disappear into the surface.
  static List<BoxShadow> _pressShadows(BuildContext context) {
    final scheme = context.colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    return [
      BoxShadow(
        color: scheme.shadow.withValues(alpha: dark ? 0.42 : 0.14),
        blurRadius: 16,
        offset: const Offset(0, 6),
        spreadRadius: -2,
      ),
      BoxShadow(
        color: scheme.shadow.withValues(alpha: dark ? 0.26 : 0.07),
        blurRadius: 4,
        offset: const Offset(0, 1),
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final proxy = ProxyDecoratorProvider.of(context);
    final proxyDecorator = proxy?.isProxyDecorator ?? false;
    final sortable = SortableItem.maybeOf(context);
    final sorting = sortable?.sorting ?? false;
    final position = ItemPositionProvider.of(context)?.position;
    final isEnd = _isEnd(position);
    // A row's press feedback is its own lift: the pointer state is observed directly (not
    // through the card's tap recognizer) so a drag that starts a scroll keeps the shadow
    // until the finger lifts. The separator no longer takes part in the press.
    final card = _ListRowSeparator(
      separated: !proxyDecorator && !isEnd,
      emphasized: widget.invalid,
      endIndent: 14,
      child: Card(
        shape: AppShape.of(listItemRadiusOf(position)),
        isError: widget.invalid,
        isSelected: widget.isSelected,
        padding: EdgeInsets.zero,
        pressTint: widget.pressTint,
        inert: sorting,
        onPressed: proxyDecorator ? null : widget.onPressed,
        child: LayoutBuilder(
          builder: (_, constraints) {
            final tile = ListRow(
              leading: widget.leading == null
                  ? null
                  : IgnorePointer(ignoring: sorting, child: widget.leading),
              padding:
                  widget.contentPadding ??
                  const EdgeInsets.only(right: 16, left: 16),
              title: _ListRowSeparatorStart(child: widget.title),
              subtitle: widget.subtitle,
              minVerticalPadding:
                  widget.minVerticalPadding ?? listRowVerticalPadding,
              horizontalTitleGap: widget.horizontalTitleGap,
              trailing: sortable == null
                  ? widget.trailing
                  : SortableTrailing(item: sortable, child: widget.trailing),
            );
            if (constraints.maxHeight >= double.infinity) {
              return tile;
            }
            return SizedBox(height: constraints.maxHeight, child: tile);
          },
        ),
      ),
    );
    final row = Listener(
      onPointerDown: (_) => _states.update(WidgetState.pressed, true),
      onPointerUp: (_) => _states.update(WidgetState.pressed, false),
      onPointerCancel: (_) => _states.update(WidgetState.pressed, false),
      child: widget.pressShadow && !proxyDecorator
          ? ListenableBuilder(
              listenable: _states,
              builder: (context, child) {
                final pressed = _states.value.contains(WidgetState.pressed);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  decoration: ShapeDecoration(
                    color: const Color(0x00000000),
                    shape: AppShape.of(listItemRadiusOf(position)),
                    shadows: pressed ? _pressShadows(context) : const [],
                  ),
                  child: child,
                );
              },
              child: card,
            )
          : card,
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
