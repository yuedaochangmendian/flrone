import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/scaffold/scaffold.dart';

class ProxiesPage extends ConsumerStatefulWidget {
  const ProxiesPage({super.key});

  @override
  ConsumerState<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends ConsumerState<ProxiesPage> {
  String? _groupTag;
  String _query = '';
  BoxController? _box;

  @override
  void initState() {
    super.initState();
    final box = ref.read(boxControllerProvider);
    _box = box;
    box.setGroupsVisible(this, true);
  }

  @override
  void dispose() {
    _box?.setGroupsVisible(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watch(boxStateProvider);
    final groups = box.groups;
    if (groups.isEmpty) {
      return Scaffold(
        title: context.tr('Proxies'),
        body: Center(
          child: Text(
            context.tr('No proxy groups'),
            style: AppTextStyle.body
                .of(context)
                .copyWith(color: context.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }
    final current = groups.cast<Json?>().firstWhere(
      (group) => group?['tag'] == _groupTag,
      orElse: () => groups.first,
    )!;
    final nodes = rows(current['items'])
        .where(
          (node) =>
              _query.isEmpty ||
              node['tag'].toString().toLowerCase().contains(
                _query.toLowerCase(),
              ),
        )
        .toList();
    final selectedId = (current['selectedId'] as num?)?.toInt();
    return Scaffold(
      title: context.tr('Proxies'),
      searchState: AppBarSearchState(
        onSearch: (query) => setState(() => _query = query),
      ),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.speed,
          tooltip: context.tr('Test all'),
          onPressed: () => box.groupTest(current['tag']),
        ),
      ],
      body: ListView(
        padding: EdgeInsets.only(
          top: context.contentTopPadding,
          bottom: 24 + context.bottomInset,
        ),
        children: [
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: groups.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final group = groups[index];
                final selected = group['tag'] == current['tag'];
                return _GroupChip(
                  label: group['tag']?.toString() ?? '',
                  selected: selected,
                  count: (group['nodeCount'] as num?)?.toInt(),
                  onTap: () =>
                      setState(() => _groupTag = group['tag'] as String?),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '${current['tag']} · ${current['selected'] ?? '—'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(color: context.colorScheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 12),
          if (nodes.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: Text(
                  context.tr('No nodes'),
                  style: AppTextStyle.body
                      .of(context)
                      .copyWith(color: context.colorScheme.onSurfaceVariant),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final columns = constraints.maxWidth >= 720 ? 3 : 2;
                  return GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      mainAxisExtent: 68,
                    ),
                    itemCount: nodes.length,
                    itemBuilder: (context, index) {
                      final node = nodes[index];
                      return _NodeCard(
                        group: current,
                        node: node,
                        selected:
                            (node['id'] as num?)?.toInt() == selectedId ||
                            node['tag'] == current['selected'],
                      );
                    },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _GroupChip extends StatelessWidget {
  const _GroupChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return PressSurface(
      fill: selected ? scheme.primary : SurfaceLevel.card.colorOf(scheme),
      shape: AppShape.full,
      onPressed: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            Text(
              label,
              maxLines: 1,
              style: AppTextStyle.footnote
                  .of(context, emphasized: true)
                  .copyWith(
                    color: selected ? scheme.onPrimary : scheme.onSurface,
                  ),
            ),
            if (count case final count?)
              Text(
                '$count',
                style: AppTextStyle.caption2
                    .of(context)
                    .copyWith(
                      color: selected
                          ? scheme.onPrimary.withValues(alpha: 0.8)
                          : scheme.onSurfaceVariant,
                    ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NodeCard extends ConsumerWidget {
  const _NodeCard({
    required this.group,
    required this.node,
    required this.selected,
  });

  final Json group;
  final Json node;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.colorScheme;
    final delay = (node['delay'] as num?)?.toInt();
    return GestureDetector(
      onLongPress: () => _menu(context, ref),
      child: PressSurface(
        fill: selected
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.1),
                SurfaceLevel.card.colorOf(scheme),
              )
            : SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.md),
        onPressed: group['selectable'] == false
            ? null
            : () => ref
                  .read(boxControllerProvider)
                  .groupSelect(
                    group['tag'],
                    node['tag'],
                    nodeId: (node['id'] as num?)?.toInt(),
                  ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 4,
            children: [
              Row(
                spacing: 6,
                children: [
                  Expanded(
                    child: Text(
                      node['tag']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.footnote
                          .of(context, emphasized: selected)
                          .copyWith(color: scheme.onSurface),
                    ),
                  ),
                  if (selected)
                    GlyphIcon(AppGlyphs.check, size: 15, color: scheme.primary),
                ],
              ),
              Text(
                delay == null
                    ? '—'
                    : delay < 0
                    ? context.tr('Timeout')
                    : '$delay ms',
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(
                      color: delay != null && delay < 0
                          ? scheme.error
                          : scheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _menu(BuildContext context, WidgetRef ref) {
    return showSheet<void>(
      context: context,
      builder: (context) => Surface(
        color: SurfaceLevel.page.colorOf(context.colorScheme),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 8,
              children: [
                Text(
                  node['tag']?.toString() ?? '',
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
                TonalButton(
                  label: context.tr('Select'),
                  onPressed: () async {
                    await ref
                        .read(boxControllerProvider)
                        .groupSelect(
                          group['tag'],
                          node['tag'],
                          nodeId: (node['id'] as num?)?.toInt(),
                        );
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
                TonalButton(
                  label: context.tr('Test'),
                  onPressed: () {
                    ref.read(boxControllerProvider).groupTest(group['tag']);
                    Navigator.pop(context);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
