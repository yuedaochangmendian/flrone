import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../app/navigation.dart';
import '../box.dart';
import '../components/dashboard_common.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/list_item.dart';
import '../ui/scaffold/scaffold.dart';

class ProfilesPage extends ConsumerWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final profiles = box.profiles;
    return Scaffold(
      title: context.tr('Profiles'),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.sync,
          tooltip: context.tr('Sync'),
          onPressed: profiles.any((profile) => profile['remote'] == true)
              ? () => _syncAll(context, ref, profiles)
              : null,
        ),
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: context.tr('Add profile'),
          onPressed: () => _openForm(context, ref),
        ),
      ],
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          if (profiles.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                spacing: 12,
                children: [
                  GlyphIcon(
                    AppGlyphs.profiles,
                    size: 44,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                  Text(
                    context.tr('No profile'),
                    style: AppTextStyle.body
                        .of(context)
                        .copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                  TonalButton(
                    label: context.tr('Add profile'),
                    glyph: AppGlyphs.add,
                    onPressed: () => _openForm(context, ref),
                  ),
                ],
              ),
            )
          else
            for (final profile in profiles)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _ProfileCard(
                  profile: profile,
                  selected:
                      (profile['id'] as num?)?.toInt() == box.selectedProfileId,
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _syncAll(
    BuildContext context,
    WidgetRef ref,
    List<Json> profiles,
  ) async {
    final box = ref.read(boxControllerProvider);
    for (final profile in profiles) {
      if (profile['remote'] == true) {
        await box.profileUpdate(profile['id']);
      }
    }
  }

  Future<void> _openForm(BuildContext context, WidgetRef ref, {Json? initial}) {
    return showFormSheet<void>(
      context: context,
      builder: (_) => _ProfileForm(initial: initial),
    );
  }
}

class _ProfileCard extends ConsumerWidget {
  const _ProfileCard({required this.profile, required this.selected});

  final Json profile;
  final bool selected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = context.colorScheme;
    final remote = profile['remote'] == true;
    return GestureDetector(
      onLongPress: () => _menu(context, ref),
      child: PressSurface(
        fill: selected
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.1),
                SurfaceLevel.card.colorOf(scheme),
              )
            : SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.xl),
        onPressed: () =>
            ref.read(boxControllerProvider).profileSelect(profile['id']),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 10, 14),
          child: Row(
            spacing: 12,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: ShapeDecoration(
                  color: SurfaceLevel.inset.colorOf(scheme),
                  shape: AppShape.all(AppCorner.md),
                ),
                child: Center(
                  child: GlyphIcon(
                    remote ? AppGlyphs.cloudSync : AppGlyphs.profiles,
                    size: 22,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 3,
                  children: [
                    Text(
                      profile['name']?.toString() ??
                          profile['label']?.toString() ??
                          '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.subheadline.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                    Text(
                      [
                        profile['type']?.toString() ?? 'local',
                        if (profile['nodeCount'] case final count?)
                          '$count nodes',
                        if (profile['lastUpdate'] case final update?)
                          _ago(update),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.caption1
                          .of(context)
                          .copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              if (remote)
                DashboardIconButton(
                  glyph: AppGlyphs.sync,
                  tooltip: context.tr('Update'),
                  onPressed: () => ref
                      .read(boxControllerProvider)
                      .profileUpdate(profile['id']),
                ),
              if (selected)
                GlyphIcon(
                  AppGlyphs.checkCircle,
                  size: 20,
                  color: scheme.primary,
                ),
              DashboardIconButton(
                glyph: AppGlyphs.more,
                tooltip: context.tr('Edit'),
                onPressed: () => _menu(context, ref),
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
                  profile['name']?.toString() ??
                      profile['label']?.toString() ??
                      '',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.title3.of(context, emphasized: true),
                ),
                TonalButton(
                  label: context.tr('Select'),
                  onPressed: () async {
                    await ref
                        .read(boxControllerProvider)
                        .profileSelect(profile['id']);
                    if (context.mounted) Navigator.pop(context);
                  },
                ),
                TonalButton(
                  label: context.tr('Edit'),
                  onPressed: () {
                    Navigator.pop(context);
                    showFormSheet<void>(
                      context: context,
                      builder: (_) => _ProfileForm(initial: profile),
                    );
                  },
                ),
                TonalButton(
                  label: 'Nodes',
                  onPressed: () {
                    Navigator.pop(context);
                    _showNodes(context);
                  },
                ),
                if (profile['remote'] == true)
                  TonalButton(
                    label: context.tr('Update'),
                    onPressed: () {
                      ref
                          .read(boxControllerProvider)
                          .profileUpdate(profile['id']);
                      Navigator.pop(context);
                    },
                  ),
                TonalButton(
                  label: context.tr('Delete'),
                  onPressed: () async {
                    Navigator.pop(context);
                    final confirmed = await showFloatingDialog<bool>(
                      context: context,
                      child: AlertDialog(
                        title: context.tr('Delete'),
                        destructive: true,
                        child: Text(
                          profile['name']?.toString() ??
                              profile['label']?.toString() ??
                              '',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: Text(context.tr('Cancel')),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: Text(context.tr('Delete')),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) {
                      await ref
                          .read(boxControllerProvider)
                          .profileDelete(profile['id']);
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showNodes(BuildContext context) {
    return showSheet<void>(
      context: context,
      builder: (_) => const _NodesSheet(),
    );
  }
}

class _NodesSheet extends ConsumerWidget {
  const _NodesSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final box = ref.watch(boxStateProvider);
    final groups = box.groups;
    final scheme = context.colorScheme;
    return Surface(
      color: SurfaceLevel.page.colorOf(scheme),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Nodes',
                style: AppTextStyle.title3.of(context, emphasized: true),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final group in groups) ...[
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 4),
                        child: Text(
                          group['tag']?.toString() ?? '',
                          style: AppTextStyle.caption1
                              .of(context)
                              .copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                      for (final node in rows(group['items']))
                        ListItem(
                          title: Text(node['tag']?.toString() ?? ''),
                          subtitle: Text(
                            node['id'] == null ? '—' : '#${node['id']}',
                            maxLines: 1,
                          ),
                          trailing: const GlyphIcon(AppGlyphs.chevronForward),
                          onTap: node['id'] == null
                              ? null
                              : () => openPage<void>(
                                  context,
                                  NodeJsonPage(
                                    id: (node['id'] as num).toInt(),
                                    name: node['tag']?.toString() ?? '',
                                  ),
                                ),
                        ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class NodeJsonPage extends ConsumerStatefulWidget {
  const NodeJsonPage({super.key, required this.id, required this.name});

  final int id;
  final String name;

  @override
  ConsumerState<NodeJsonPage> createState() => _NodeJsonPageState();
}

class _NodeJsonPageState extends ConsumerState<NodeJsonPage> {
  final _name = TextEditingController();
  final _json = TextEditingController();
  var _loading = true;
  var _saving = false;
  String? _error;
  String _originalName = '';
  String _originalJson = '';

  bool get _dirty =>
      _name.text.trim() != _originalName || _json.text != _originalJson;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _name.dispose();
    _json.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = json(
        await ref.read(boxControllerProvider).profileNodeConfig(widget.id),
      );
      if (!mounted) return;
      _name.text = data['name']?.toString() ?? widget.name;
      _json.text = data['json']?.toString() ?? '';
      _originalName = _name.text.trim();
      _originalJson = _json.text;
      setState(() => _loading = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = BoxController.describe(error);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Scaffold(
      title: widget.name,
      isLoading: _loading || _saving,
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: context.tr('Save'),
        onPressed: _dirty && !_saving ? _save : null,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          context.contentTopPadding,
          16,
          24 + context.bottomInset,
        ),
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                _error!,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: scheme.error),
              ),
            ),
          TextField(
            controller: _name,
            decoration: const InputDecoration(hintText: 'Name'),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: ShapeDecoration(
              color: SurfaceLevel.card.colorOf(scheme),
              shape: AppShape.all(AppCorner.lg),
            ),
            child: TextField(
              controller: _json,
              minLines: 16,
              maxLines: 32,
              autocorrect: false,
              enableSuggestions: false,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(fontFamily: 'monospace', color: scheme.onSurface),
              decoration: const InputDecoration(
                hintText: '{\n  "type": "vless",\n  ...\n}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    try {
      jsonDecode(_json.text);
    } catch (_) {
      setState(() => _error = 'Node JSON is not valid');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(boxControllerProvider)
          .profileNodeUpdate(widget.id, _name.text.trim(), _json.text);
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = BoxController.describe(error);
        });
      }
    }
  }
}

class _ProfileForm extends ConsumerStatefulWidget {
  const _ProfileForm({this.initial});

  final Json? initial;

  @override
  ConsumerState<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<_ProfileForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?['name']?.toString() ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.initial?['url']?.toString() ?? '',
  );
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Surface(
      color: SurfaceLevel.page.colorOf(scheme),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(
                widget.initial == null
                    ? context.tr('Add profile')
                    : context.tr('Edit'),
                style: AppTextStyle.title3.of(context, emphasized: true),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: scheme.error),
                ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(hintText: 'Name'),
              ),
              TextField(
                controller: _url,
                decoration: const InputDecoration(
                  hintText: 'https://example.com/config.json',
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TonalButton(
                    label: context.tr('Cancel'),
                    onPressed: _saving ? null : () => Navigator.pop(context),
                  ),
                  TonalButton(
                    label: context.tr('Save'),
                    onPressed: _saving ? null : _save,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty || (url.isNotEmpty && !url.startsWith('http'))) {
      setState(() => _error = 'Enter a name and a valid URL');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(boxControllerProvider).profileSave({
        ...?widget.initial,
        'name': name,
        'url': url,
        'autoUpdate': widget.initial?['autoUpdate'] ?? false,
        'interval': widget.initial?['interval'] ?? 60,
      });
      if (mounted) Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = BoxController.describe(error);
        });
      }
    }
  }
}

String _ago(Object update) {
  final value = update is num
      ? (update > 100000000000 ? update ~/ 1000 : update)
      : 0;
  final time = DateTime.fromMillisecondsSinceEpoch((value * 1000).toInt());
  final diff = DateTime.now().difference(time);
  if (diff.inDays > 0) return '${diff.inDays}d ago';
  if (diff.inHours > 0) return '${diff.inHours}h ago';
  return '${diff.inMinutes}m ago';
}
