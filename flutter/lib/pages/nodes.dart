import 'dart:async';

import 'package:flutter/services.dart';
import '../widgets.dart';
import 'protocol_form.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The node page that shares the Profiles screen with the profile grid.
///
/// The list is the selected profile's own nodes (Bettbox's node library, scoped
/// to one profile): a node still belongs to the group whose config carries it,
/// so switching profile cards switches this list. Importing a link here adds a
/// node to that profile instead of creating a new one — the same rows the
/// Proxies screen tests and the config build renders.
class NodesView extends ConsumerStatefulWidget {
  const NodesView({super.key, this.topInset});

  /// The gap above the list when the page sits under the profile/node switch.
  /// Null uses the page body's own inset, for a full-page layout.
  final double? topInset;

  @override
  ConsumerState<NodesView> createState() => NodesViewState();
}

class NodesViewState extends ConsumerState<NodesView> {
  /// The group the current rows belong to. Null until the first load, so a
  /// cold start does not race the first selection with a second request.
  int? _requestedId;
  List<Json> _nodes = const [];
  bool _loading = true;
  String? _error;
  int _generation = 0;

  String get _groupName =>
      ref.read(selectedProfileProvider)?['name']?.toString() ?? '';

  /// Reload after an import or a mutation made by the page above.
  Future<void> reload() => _load();

  Future<void> _load() async {
    final box = ref.read(boxControllerProvider);
    final groupId = _requestedId ?? box.selectedProfileId;
    final generation = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final data = await box.nodeList(groupId);
      if (!mounted || generation != _generation) return;
      setState(() {
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
    // The first build asks for the list; switching the profile card on the other
    // page asks again for that profile. Scheduled after the frame: the load
    // calls setState. [_requestedId] tracks the selection we asked for, never the
    // group the host answered with, so a fallback answer cannot reload forever.
    final selected = ref.watch(selectedProfileIdProvider);
    if (_requestedId != selected) {
      _requestedId = selected;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }
    final padding = EdgeInsets.fromLTRB(
      16,
      widget.topInset ?? context.contentTopPadding,
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
          'Paste a node link, or create one, to fill this profile.',
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
/// editor does not own (share link, delete).
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
