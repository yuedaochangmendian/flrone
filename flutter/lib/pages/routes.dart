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
import '../ui/scaffold/scaffold.dart';

class RoutesPage extends ConsumerStatefulWidget {
  const RoutesPage({super.key});

  @override
  ConsumerState<RoutesPage> createState() => _RoutesPageState();
}

class _RoutesPageState extends ConsumerState<RoutesPage> {
  List<Json> _profiles = const [];
  var _currentId = 0;
  var _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = json(await ref.read(boxControllerProvider).routeList());
      if (!mounted) return;
      setState(() {
        _profiles = rows(data['profiles']);
        _currentId = (data['currentId'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: 'Routing',
      isLoading: _loading,
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: 'New route',
          onPressed: () => _edit(),
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
          if (_error != null)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: ShapeDecoration(
                color: context.colorScheme.errorContainer,
                shape: AppShape.all(AppCorner.md),
              ),
              child: Text(
                _error!,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: context.colorScheme.onErrorContainer),
              ),
            ),
          if (_profiles.isEmpty && !_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 40),
              child: Column(
                spacing: 12,
                children: [
                  GlyphIcon(
                    AppGlyphs.rules,
                    size: 40,
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                  Text(
                    'No route profiles',
                    style: AppTextStyle.body
                        .of(context)
                        .copyWith(color: context.colorScheme.onSurfaceVariant),
                  ),
                  TonalButton(
                    label: 'New route',
                    glyph: AppGlyphs.add,
                    onPressed: () => _edit(),
                  ),
                ],
              ),
            )
          else
            for (final profile in _profiles)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _RouteCard(
                  profile: profile,
                  current: (profile['id'] as num?)?.toInt() == _currentId,
                  onSelect: () => _select(profile),
                  onEdit: () => _edit(profile),
                  onRules: () => _rules(profile),
                  onDelete: () => _delete(profile),
                ),
              ),
        ],
      ),
    );
  }

  Future<void> _select(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    if (id == 0 || id == _currentId || profile['isRaw'] == true) return;
    final box = ref.read(boxControllerProvider);
    try {
      await box.routeSetCurrentHost(id);
      await box.serviceReload();
      await _load();
    } catch (error) {
      box.report(error);
    }
  }

  Future<void> _edit([Json? profile]) async {
    final saved = await showFormSheet<bool>(
      context: context,
      builder: (_) => _RouteForm(initial: profile),
    );
    if (saved == true) await _load();
  }

  Future<void> _delete(Json profile) async {
    final name = profile['name']?.toString() ?? '';
    final confirmed = await showFloatingDialog<bool>(
      context: context,
      child: AlertDialog(
        title: 'Delete route',
        destructive: true,
        child: Text(name),
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
    if (confirmed != true) return;
    final box = ref.read(boxControllerProvider);
    try {
      await box.routeDeleteProfile(profile['id']);
      await _load();
    } catch (error) {
      box.report(error);
    }
  }

  Future<void> _rules(Json profile) async {
    final id = (profile['id'] as num?)?.toInt() ?? 0;
    if (id == 0) return;
    final saved = await openPage<bool>(
      context,
      RouteRulesPage(id: id, name: profile['name']?.toString() ?? ''),
    );
    if (saved == true) await _load();
  }
}

class _RouteCard extends StatelessWidget {
  const _RouteCard({
    required this.profile,
    required this.current,
    required this.onSelect,
    required this.onEdit,
    required this.onRules,
    required this.onDelete,
  });

  final Json profile;
  final bool current;
  final VoidCallback onSelect;
  final VoidCallback onEdit;
  final VoidCallback onRules;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final remote = profile['isRemote'] == true;
    return GestureDetector(
      onLongPress: onDelete,
      child: PressSurface(
        fill: current
            ? Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.1),
                SurfaceLevel.card.colorOf(scheme),
              )
            : SurfaceLevel.card.colorOf(scheme),
        shape: AppShape.all(AppCorner.lg),
        onPressed: onSelect,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(
            spacing: 10,
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: ShapeDecoration(
                  color: SurfaceLevel.inset.colorOf(scheme),
                  shape: AppShape.all(AppCorner.md),
                ),
                child: Center(
                  child: GlyphIcon(
                    remote ? AppGlyphs.cloudSync : AppGlyphs.rules,
                    size: 20,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text(
                      profile['name']?.toString() ?? '',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyle.subheadline.of(
                        context,
                        emphasized: true,
                      ),
                    ),
                    Text(
                      [
                        profile['defaultOutbound']?.toString() ?? 'proxy',
                        if (remote) 'remote',
                        if (current) 'current',
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
              if (current)
                GlyphIcon(
                  AppGlyphs.checkCircle,
                  size: 18,
                  color: scheme.primary,
                ),
              DashboardIconButton(
                glyph: AppGlyphs.rules,
                tooltip: 'Rules',
                onPressed: onRules,
              ),
              DashboardIconButton(
                glyph: AppGlyphs.edit,
                tooltip: context.tr('Edit'),
                onPressed: onEdit,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class RouteRulesPage extends ConsumerStatefulWidget {
  const RouteRulesPage({super.key, required this.id, required this.name});

  final int id;
  final String name;

  @override
  ConsumerState<RouteRulesPage> createState() => _RouteRulesPageState();
}

class _RouteRulesPageState extends ConsumerState<RouteRulesPage> {
  final _controller = TextEditingController();
  var _loading = true;
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final data = json(
        await ref.read(boxControllerProvider).routeRules(widget.id),
      );
      if (!mounted) return;
      _controller.text = const JsonEncoder.withIndent('  ')
          .convert(rows(data['rules']));
      setState(() => _loading = false);
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = BoxController.describe(error);
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    return Scaffold(
      title: widget.name.isEmpty ? 'Rules' : widget.name,
      isLoading: _loading || _saving,
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: context.tr('Save'),
        onPressed: _saving ? null : _save,
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
          Text(
            'Raw route rules. Each entry is an object; unknown fields are preserved.',
            style: AppTextStyle.caption1
                .of(context)
                .copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 10),
          Container(
            decoration: ShapeDecoration(
              color: SurfaceLevel.card.colorOf(scheme),
              shape: AppShape.all(AppCorner.lg),
            ),
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _controller,
              minLines: 12,
              maxLines: 24,
              autocorrect: false,
              enableSuggestions: false,
              style: AppTextStyle.caption1
                  .of(context)
                  .copyWith(fontFamily: 'monospace', color: scheme.onSurface),
              decoration: const InputDecoration(
                hintText: '[\n  {"name": "Example", "action": "route"}\n]',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    dynamic parsed;
    try {
      parsed = jsonDecode(_controller.text);
    } catch (_) {
      setState(() => _error = 'Rules must be a JSON array');
      return;
    }
    if (parsed is! List) {
      setState(() => _error = 'Rules must be a JSON array');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(boxControllerProvider).routeSaveRules(widget.id, parsed);
      if (mounted) Navigator.pop(context, true);
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

class _RouteForm extends ConsumerStatefulWidget {
  const _RouteForm({this.initial});

  final Json? initial;

  @override
  ConsumerState<_RouteForm> createState() => _RouteFormState();
}

class _RouteFormState extends ConsumerState<_RouteForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?['name']?.toString() ?? '',
  );
  late final TextEditingController _outbound = TextEditingController(
    text: widget.initial?['defaultOutbound']?.toString() ?? 'proxy',
  );
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _outbound.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Surface(
      color: SurfaceLevel.page.colorOf(context.colorScheme),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              Text(
                widget.initial == null ? 'New route' : 'Edit route',
                style: AppTextStyle.title3.of(context, emphasized: true),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: AppTextStyle.caption1
                      .of(context)
                      .copyWith(color: context.colorScheme.error),
                ),
              TextField(
                controller: _name,
                decoration: const InputDecoration(hintText: 'Name'),
              ),
              TextField(
                controller: _outbound,
                decoration: const InputDecoration(
                  hintText: 'Default outbound (proxy / direct / block)',
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
    if (name.isEmpty) {
      setState(() => _error = 'Enter a name');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(boxControllerProvider)
          .routeSaveProfile(
            id: widget.initial?['id'],
            name: name,
            defaultOutbound: _outbound.text.trim().isEmpty
                ? 'proxy'
                : _outbound.text.trim(),
          );
      if (mounted) Navigator.pop(context, true);
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
