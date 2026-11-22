import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';
import '../widgets.dart';
import 'proxy_card.dart';

// The selected configuration's nodes as a lazy sliver list.
//
// The group IS the configuration the Proxies screen mirrors, so there is no
// group header, fold control or unfold preference here: those belonged to the
// tabbed page, and a header repeating the configuration's name was the
// "not one-to-one" the screen kept showing.
const _inset = 10.0;
const _groupInset = 16.0;
const _lastRowGrowth = 2.0;

class ProxyListGroup {
  const ProxyListGroup(this.group, this.nodes);
  final Json group;
  final List<Json> nodes;
  String get name => group['tag'].toString();
}

class ProxyListView extends ConsumerStatefulWidget {
  const ProxyListView({
    super.key,
    required this.profileKey,
    required this.groups,
    required this.cardBuilder,
    required this.onTest,
  });

  final String profileKey;
  final List<ProxyListGroup> groups;
  final Widget Function(BuildContext, Json, Json) cardBuilder;
  final Future<void> Function(String) onTest;

  @override
  ConsumerState<ProxyListView> createState() => _ProxyListViewState();
}

class _ProxyListViewState extends ConsumerState<ProxyListView> {
  late final _controller = sheetScrollController(context);
  int _columns = 1, _groupColumns = 1;
  double _gap = 8;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    _gap = context.isMobileView ? 8 : constraints.maxWidth >= 1024 ? 16 : 12;
    final width = max(constraints.maxWidth - _groupInset * 2, 0.0);
    _groupColumns = context.isMobileView ? 1 : ((width + _gap) / (360 + _gap)).floor().clamp(1, 3);
    final groupWidth = (width - _gap * (_groupColumns - 1)) / _groupColumns;
    final preferences = ref.watch(preferencesProvider);
    _columns = proxyColumns(max(groupWidth - _inset * 2, 0), preferences);
    Widget buildGroup(ProxyListGroup group) => _GroupSliver(
      key: ValueKey(group.name),
      group: group,
      columns: _columns,
      gap: _gap,
      extent: ProxyCardMetrics.of(context, preferences).rowExtent,
      cardBuilder: widget.cardBuilder,
    );
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: CustomScrollView(
        key: PageStorageKey('proxy-list:${widget.profileKey}'),
        controller: _controller,
        slivers: [
          PinnedHeaderSliver(child: SizedBox(height: context.contentTopPadding)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: _groupInset),
            sliver: _groupColumns == 1
                ? SliverMainAxisGroup(slivers: widget.groups.map(buildGroup).toList())
                : SliverCrossAxisGroup(slivers: [
                    for (var column = 0; column < _groupColumns; column++) ...[
                      if (column > 0)
                        SliverConstrainedCrossAxis(
                          maxExtent: _gap,
                          sliver: const SliverToBoxAdapter(),
                        ),
                      SliverCrossAxisExpanded(
                        flex: 1,
                        sliver: SliverMainAxisGroup(slivers: [
                          for (var index = column;
                              index < widget.groups.length;
                              index += _groupColumns)
                            buildGroup(widget.groups[index]),
                        ]),
                      ),
                    ],
                  ]),
          ),
          // The delay-test button floats over the page's corner; leave a full
          // button plus a gap so the last row can scroll clear of it.
          SliverToBoxAdapter(child: SizedBox(height: 72 + context.bottomInset)),
        ],
      ),
    );
  });
}

/// One group's node rows: `columns` cards per row, fixed extents, no header.
class _GroupSliver extends StatelessWidget {
  const _GroupSliver({
    super.key,
    required this.group,
    required this.columns,
    required this.gap,
    required this.extent,
    required this.cardBuilder,
  });

  final ProxyListGroup group;
  final int columns;
  final double gap, extent;
  final Widget Function(BuildContext, Json, Json) cardBuilder;

  int get _rowCount => (group.nodes.length + columns - 1) ~/ columns;

  Widget _buildRow(BuildContext context, int row) => SurfaceScope(
    level: context.raisedSurfaceLevel,
    child: Padding(
      padding: const EdgeInsets.only(left: _inset, right: _inset, bottom: 8),
      child: Row(children: [
        for (var column = 0; column < columns; column++) ...[
          if (column > 0) const SizedBox(width: 8),
          Expanded(
            child: row * columns + column < group.nodes.length
                ? SizedBox(
                    height: extent - 8,
                    child: cardBuilder(
                      context,
                      group.group,
                      group.nodes[row * columns + column],
                    ),
                  )
                : const SizedBox(),
          ),
        ],
      ]),
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (group.nodes.isEmpty) {
      return SliverPadding(
        padding: EdgeInsets.only(bottom: gap),
        sliver: const SliverToBoxAdapter(),
      );
    }
    // Rows are the whole block now (no header above them), so the block is
    // rounded on all corners instead of only its bottom.
    final decoration = ShapeDecoration(
      color: context.raisedSurfaceLevel.colorOf(context.colorScheme),
      shape: AppShape.all(AppCorner.xl.ap(context)),
    );
    return SliverPadding(
      padding: EdgeInsets.only(bottom: gap),
      sliver: DecoratedSliver(
        decoration: decoration,
        sliver: SliverMainAxisGroup(slivers: [
          SliverFixedExtentList(
            itemExtent: extent,
            delegate: SliverChildBuilderDelegate(
              (context, index) => _buildRow(context, index),
              childCount: _rowCount,
              addAutomaticKeepAlives: false,
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: _lastRowGrowth)),
        ]),
      ),
    );
  }
}
