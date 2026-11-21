import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:prism_ui/prism_ui.dart';

import '../app/l10n.dart';
import '../box.dart';
import '../providers/box_providers.dart';
import '../ui/icons/icons.dart';
import '../ui/scaffold/scaffold.dart';

class AccessPage extends ConsumerStatefulWidget {
  const AccessPage({super.key});

  @override
  ConsumerState<AccessPage> createState() => _AccessPageState();
}

class _AccessPageState extends ConsumerState<AccessPage> {
  List<Json>? _apps;
  String? _error;
  String _query = '';
  var _loading = true;
  var _saving = false;
  var _enabled = false;
  var _mode = 2;
  var _selected = <String>{};
  var _saved = <String>{};

  @override
  void initState() {
    super.initState();
    final settings = ref.read(boxControllerProvider).settings;
    _enabled = settings['perAppEnabled'] == true;
    _mode = (settings['perAppMode'] as num?)?.toInt() == 1 ? 1 : 2;
    _savedEnabled = _enabled;
    _savedMode = _mode;
    _selected = (settings['perAppList'] as List? ?? const [])
        .whereType<String>()
        .toSet();
    _saved = {..._selected};
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _dirty =>
      _enabled != _savedEnabled ||
      _mode != _savedMode ||
      !_sameSet(_selected, _saved);

  bool _savedEnabled = false;
  var _savedMode = 2;

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  Future<void> _load({bool refresh = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final apps = rows(
        await ref.read(boxControllerProvider).appsList({
          'refresh': refresh,
          'system': false,
          'nonInternet': true,
        }),
      );
      if (!mounted) return;
      setState(() {
        _apps = apps;
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
    final apps = (_apps ?? const <Json>[]).where((app) {
      if (_query.isEmpty) return true;
      final query = _query.toLowerCase();
      return '${app['name']} ${app['package']}'.toLowerCase().contains(query);
    }).toList();
    final scheme = context.colorScheme;
    return Scaffold(
      title: 'Access control',
      isLoading: _loading || _saving,
      searchState: AppBarSearchState(
        onSearch: (query) => setState(() => _query = query),
      ),
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: context.tr('Save'),
        isLoading: _saving,
        onPressed: _dirty && !_saving ? _save : null,
      ),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: 'Refresh',
          onPressed: _loading ? null : () => _load(refresh: true),
        ),
      ],
      menuItems: [
        PopupMenuItem(
          label: 'Proxy selected apps',
          checked: _mode == 2,
          onPressed: () => setState(() => _mode = 2),
        ),
        PopupMenuItem(
          label: 'Bypass selected apps',
          checked: _mode == 1,
          onPressed: () => setState(() => _mode = 1),
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
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            decoration: ShapeDecoration(
              color: SurfaceLevel.card.colorOf(scheme),
              shape: AppShape.all(AppCorner.xl),
            ),
            child: Row(
              spacing: 12,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      Text(
                        'Per-app routing',
                        style: AppTextStyle.subheadline.of(
                          context,
                          emphasized: true,
                        ),
                      ),
                      Text(
                        _mode == 2
                            ? 'Only selected apps use the VPN'
                            : 'Selected apps bypass the VPN',
                        style: AppTextStyle.caption1
                            .of(context)
                            .copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                Text(
                  '${_selected.length}',
                  style: AppTextStyle.title3
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.primary),
                ),
                SizedBox(
                  width: 52,
                  height: 32,
                  child: Switch(
                    value: _enabled,
                    onChanged: (value) => setState(() => _enabled = value),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: AppTextStyle.caption1
                    .of(context)
                    .copyWith(color: scheme.error),
              ),
            ),
          const SizedBox(height: 12),
          for (final app in apps)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: _AppRow(
                app: app,
                selected: _selected.contains(app['package']),
                enabled: _enabled,
                onTap: () => setState(() {
                  final package = app['package'].toString();
                  if (!_selected.remove(package)) _selected.add(package);
                }),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(boxControllerProvider).setSettings({
        'perAppEnabled': _enabled,
        'perAppMode': _mode,
        'perAppList': _selected.toList()..sort(),
      });
      if (mounted && saved) {
        setState(() {
          _savedEnabled = _enabled;
          _savedMode = _mode;
          _saved = {..._selected};
        });
        BannerHost.maybeOf(context)?.show('Access control saved');
      }
    } catch (error) {
      ref.read(boxControllerProvider).report(error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _AppRow extends StatelessWidget {
  const _AppRow({
    required this.app,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final Json app;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = context.colorScheme;
    final name = app['name']?.toString() ?? app['package']?.toString() ?? '';
    final package = app['package']?.toString() ?? '';
    return PressSurface(
      fill: selected
          ? Color.alphaBlend(
              scheme.primary.withValues(alpha: 0.1),
              SurfaceLevel.card.colorOf(scheme),
            )
          : SurfaceLevel.card.colorOf(scheme),
      shape: AppShape.all(AppCorner.md),
      onPressed: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          spacing: 10,
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: ShapeDecoration(
                color: SurfaceLevel.inset.colorOf(scheme),
                shape: AppShape.all(AppCorner.sm),
              ),
              child: Center(
                child: Text(
                  name.isEmpty ? '?' : name.substring(0, 1).toUpperCase(),
                  style: AppTextStyle.footnote
                      .of(context, emphasized: true)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 1,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.footnote
                        .of(context)
                        .copyWith(color: scheme.onSurface),
                  ),
                  Text(
                    package,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyle.caption2
                        .of(context)
                        .copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            if (selected)
              GlyphIcon(AppGlyphs.checkCircle, size: 20, color: scheme.primary),
          ],
        ),
      ),
    );
  }
}
