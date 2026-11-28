import 'dart:async';

import 'package:flutter/services.dart';
import '../widgets.dart';
import '../core/proxy_memory.dart';
import 'node_json_page.dart';
import 'protocol_form.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The single-node page that shares the Profiles screen with the profile grid.
///
/// The two pages are the two modes: the grid lists profiles (subscriptions and
/// local configs), this page lists the manually imported single nodes. Single
/// nodes live in their own container group (Throne's Default group), which the
/// grid hides — a hand-imported link never shows up as a profile card.
class NodesView extends ConsumerStatefulWidget {
  const NodesView({super.key, this.fabClearance = false});

  /// Reserves room under the last row for the page's floating add button.
  final bool fabClearance;

  @override
  ConsumerState<NodesView> createState() => NodesViewState();
}

class NodesViewState extends ConsumerState<NodesView> {
  List<Json> _nodes = const [];

  /// The container's display name, used by the row actions (share link, select).
  String _groupName = '';

  /// The container's group id: the key of the per-configuration node memory.
  int _groupId = 0;
  bool _loading = true;
  String? _error;
  bool _started = false;
  int _generation = 0;

  /// The load in flight, if any.
  ///
  /// The page's first build and the mode switch's reload run in the same frame;
  /// one shared request keeps that from becoming two bridge calls where the
  /// second supersedes the first and leaves the switch with no group id.
  Future<int>? _inFlight;

  /// The rows the reorder page edits.
  List<Json> get nodes => _nodes;

  /// The container group whose member order [nodes] follows.
  int get groupId => _groupId;

  /// Reload after an import or a mutation, or when the page is opened again.
  /// Answers the container's group id, so the mode switch can make it the
  /// current configuration.
  Future<int> reload() => _inFlight ??= _load().whenComplete(() => _inFlight = null);

  Future<int> _load() async {
    final box = ref.read(boxControllerProvider);
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await box.nodeList();
      if (!mounted || generation != _generation) return 0;
      final groupId = (data['groupId'] as num?)?.toInt() ?? 0;
      setState(() {
        _groupId = groupId;
        _groupName = data['groupName']?.toString() ?? '';
        _nodes = [
          for (final node in (data['nodes'] as List? ?? const [])) json(node),
        ];
        _loading = false;
      });
      return groupId;
    } catch (error) {
      if (!mounted || generation != _generation) return 0;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
      return 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      // First build asks for the list once; the page stays built afterwards.
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(reload());
      });
    }
    final padding = EdgeInsets.fromLTRB(
      16,
      context.contentTopPadding,
      16,
      16 + context.bottomInset + (widget.fabClearance ? 64 : 0),
    );
    if (_loading && _nodes.isEmpty) {
      return const Center(child: ActivityIndicator());
    }
    if (_error case final error?) {
      return ErrorState(error, retry: () => unawaited(_load()));
    }
    if (_nodes.isEmpty) {
      return NullStatus(
        label: context.tr('No nodes yet'),
        description: context.tr(
          'Paste a node link, or create one, to start the list.',
        ),
        illustration: NullStatusIllustration.profile,
      );
    }
    return ListView.separated(
      padding: padding,
      itemCount: _nodes.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final node = _nodes[index];
        return _NodeRow(
          key: ValueKey(node['id']),
          node: node,
          groupId: _groupId,
          groupName: _groupName,
          onChanged: _load,
        );
      },
    );
  }
}

/// One node row: the editor on tap, and the row menu for the actions the
/// editor does not own (select, share link, delete).
class _NodeRow extends ConsumerWidget {
  const _NodeRow({
    super.key,
    required this.node,
    required this.groupId,
    required this.groupName,
    required this.onChanged,
  });

  final Json node;
  final int groupId;
  final String groupName;
  final Future<void> Function() onChanged;

  int get _id => (node['id'] as num?)?.toInt() ?? 0;

  Future<void> _edit(BuildContext context) async {
    final typeKey = node['typeKey']?.toString() ?? '';
    if (node['isSelector'] == true || typeKey == 'autoselector') {
      await openPage(context, AutoSelectorPage(id: _id));
    } else if (typeKey == 'custom') {
      // The typed form has no custom editor; the JSON page is its only editor.
      await openPage(context, NodeJsonPage(id: _id));
    } else {
      await openForm(context, ProtocolFormPage(id: _id));
    }
    await onChanged();
  }

  Future<void> _select(BuildContext context, WidgetRef ref) async {
    final box = ref.read(boxControllerProvider);
    try {
      final done = await box.groupSelect(
        groupName,
        node['name'].toString(),
        nodeId: _id,
      );
      if (!context.mounted) return;
      if (done) {
        // The container's node memory feeds the proxies page's configuration
        // restore; without this write a node picked here was reverted by the
        // proxies page's older entry (and read as "the selection did not
        // persist" after a restart).
        await rememberProxySelection(
          box,
          groupId: groupId,
          groupTag: groupName,
          nodeId: _id,
          nodeTag: node['name'].toString(),
        );
        if (context.mounted) showAppBanner(context, context.tr('Selected'));
      }
      await onChanged();
    } catch (error) {
      box.report(error);
    }
  }

  Future<void> _copyLink(BuildContext context, WidgetRef ref) async {
    final box = ref.read(boxControllerProvider);
    try {
      final link = await box.nodeLink(groupName, node['name'].toString(), false);
      await Clipboard.setData(ClipboardData(text: link.toString()));
      if (context.mounted) showAppBanner(context, context.tr('Copied'));
    } catch (error) {
      box.report(error);
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final box = ref.read(boxControllerProvider);
    if (!await confirm(context, context.tr('Delete node?'),
        message: node['name'].toString())) {
      return;
    }
    try {
      await box.nodeDelete(_id);
      await onChanged();
    } catch (error) {
      box.report(error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final delay = (node['delay'] as num?)?.toInt() ?? 0;
    final type = node['type']?.toString() ?? '';
    final group = groupName;
    final detail = [
      if (type.isNotEmpty) type.toUpperCase(),
      if (delay > 0) '$delay ms',
    ].join(' · ');
    return Card(
      radius: AppCorner.xl,
      onPressed: () => _edit(context),
      child: ListItem(
        title: Text(
          node['name'].toString(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.headline.of(context),
        ),
        subtitle: Text(
          detail,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTextStyle.footnote.of(context).toLighter,
        ),
        trailing: PopupAnchor(
          targetBuilder: (open) => IconButton(
            tooltip: context.tr('More'),
            icon: const GlyphIcon(AppGlyphs.more),
            onPressed: open,
          ),
          popupBuilder: (_) => PopupMenu(
            items: [
              PopupMenuItem(
                glyph: AppGlyphs.checkCircle,
                label: context.tr('Select'),
                onPressed: group.isEmpty ? null : () => _select(context, ref),
              ),
              PopupMenuItem(
                glyph: AppGlyphs.edit,
                label: context.tr('Edit'),
                onPressed: () => _edit(context),
              ),
              PopupMenuItem(
                glyph: AppGlyphs.link,
                label: context.tr('Copy link'),
                onPressed: group.isEmpty ? null : () => _copyLink(context, ref),
              ),
              PopupMenuItem(
                glyph: AppGlyphs.delete,
                label: context.tr('Delete'),
                danger: true,
                onPressed: () => _delete(context, ref),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Reorders the node page's rows — the single-node container's member order in
/// the profiles document. Saving goes through BoxApi.nodeReorder; the caller
/// reloads the list when this page pops with `true`.
class NodeOrderPage extends ConsumerStatefulWidget {
  const NodeOrderPage({super.key, required this.groupId, required this.nodes});

  final int groupId;
  final List<Json> nodes;

  @override
  ConsumerState<NodeOrderPage> createState() => _NodeOrderPageState();
}

class _NodeOrderPageState extends ConsumerState<NodeOrderPage> {
  late final List<Json> _nodes = List.of(widget.nodes);
  bool _saving = false;

  Widget _item(int index) => ReorderableDelayedDragStartListener(
    key: ValueKey(_nodes[index]['id']),
    index: index,
    child: ItemPositionProvider(
      position: ItemPosition.get(index, _nodes.length),
      child: DecorationListItem(
        contentPadding: const EdgeInsets.only(left: 16),
        title: Text(_nodes[index]['name'].toString()),
        trailing: SortHandle(index: index),
      ),
    ),
  );

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final box = ref.read(boxControllerProvider);
    final saved = await box.nodeReorder(
      widget.groupId,
      [for (final node in _nodes) node['id']],
    );
    if (!mounted) return;
    if (saved) {
      context.safeNestedPop(true);
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    title: context.tr('Reorder'),
    confirmationAction: IconButtonData(
      glyph: AppGlyphs.check,
      tooltip: context.tr('Save'),
      isLoading: _saving,
      onPressed: _saving ? null : _save,
    ),
    body: AbsorbPointer(
      absorbing: _saving,
      child: ReorderableListView.builder(
        buildDefaultDragHandles: false,
        padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 32 + context.bottomInset),
        itemCount: _nodes.length,
        proxyDecorator: (child, index, animation) => commonProxyDecorator(_item(index), index, animation),
        onReorderItem: (old, next) => setState(() => _nodes.insert(next, _nodes.removeAt(old))),
        itemBuilder: (_, index) => _item(index),
      ),
    ),
  );
}
