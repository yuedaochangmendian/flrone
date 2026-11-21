import 'dart:async';

import 'package:flutter/services.dart';
import '../widgets.dart';
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
  const NodesView({super.key});

  @override
  ConsumerState<NodesView> createState() => NodesViewState();
}

class NodesViewState extends ConsumerState<NodesView> {
  List<Json> _nodes = const [];

  /// The container's display name, used by the row actions (share link, select).
  String _groupName = '';
  bool _loading = true;
  String? _error;
  bool _started = false;
  int _generation = 0;

  /// Reload after an import or a mutation, or when the page is opened again.
  Future<void> reload() => _load();

  Future<void> _load() async {
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
      if (!mounted || generation != _generation) return;
      setState(() {
        _groupName = data['groupName']?.toString() ?? '';
        _nodes = [
          for (final node in (data['nodes'] as List? ?? const [])) json(node),
        ];
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_started) {
      // First build asks for the list once; the page stays built afterwards.
      _started = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final padding = EdgeInsets.fromLTRB(
      16,
      context.contentTopPadding,
      16,
      16 + context.bottomInset,
    );
    if (_loading && _nodes.isEmpty) {
      return const Center(child: ActivityIndicator());
    }
    if (_error case final error?) {
      return ErrorState(error, retry: _load);
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
    required this.groupName,
    required this.onChanged,
  });

  final Json node;
  final String groupName;
  final Future<void> Function() onChanged;

  int get _id => (node['id'] as num?)?.toInt() ?? 0;

  Future<void> _edit(BuildContext context) async {
    await openForm(context, ProtocolFormPage(id: _id));
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
      if (done) showAppBanner(context, context.tr('Selected'));
      await onChanged();
    } catch (error) {
      box.report(error);
    }
  }

  Future<void> _copyLink(BuildContext context, WidgetRef ref) async {
    final box = ref.read(boxControllerProvider);
    try {
      final link = await box.profileNodeLink(groupName, node['name'].toString(), false);
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
      await box.profileNodeDelete(_id);
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
