// One route profile, Throne for Android's RouteProfileActivity: the header (name,
// default outbound, and the remote source of a remote profile), the DNS card,
// the raw read-only note, and the ordered rule list — drag to reorder, swipe or
// menu to delete with undo, tap to edit, tick to enable.
//
// Edits stay in memory until Save: the kernel writes the whole rule array at
// once (`routeSaveRules` replaces the profile's rows), so every mutation here
// works on the local copy and one Save commits it. A profile opened read-only
// (`isRaw`) still lists its rules, and offers no control that would fail.

import '../components/form.dart';
import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

class RouteProfileEditorPage extends ConsumerStatefulWidget {
  const RouteProfileEditorPage({super.key, required this.id, this.remote = false});

  /// 0 creates a new profile; anything else loads that profile.
  final int id;

  /// A new profile starts as a remote one (the toolbar's "Remote profile").
  final bool remote;

  @override
  ConsumerState<RouteProfileEditorPage> createState() => _RouteProfileEditorPageState();
}

class _RouteProfileEditorPageState extends ConsumerState<RouteProfileEditorPage> {
  final _name = TextEditingController();
  final _url = TextEditingController();

  List<Json> _rules = const [];
  /// The rules diverged from the last committed set. Bulk add asks the host to
  /// extend its *stored* rules and replaces the local list with the answer, so
  /// it must not silently swallow in-memory edits.
  bool _rulesDirty = false;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _formError;

  bool _isRemote = false;
  bool _autoUpdate = false;
  bool _isRaw = false;
  String _defaultOutbound = 'proxy';

  /// The last committed rule list, for the delete's undo.
  List<Json>? _undoRules;

  int get _id => widget.id;

  bool get _editable => !_isRaw;

  @override
  void initState() {
    super.initState();
    _isRemote = widget.remote;
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final box = ref.read(boxControllerProvider);
    try {
      if (_id > 0) {
        final detail = json(await box.routeGetProfile(_id));
        final rules = rows(json(await box.routeRules(_id))['rules']);
        if (!mounted) return;
        setState(() {
          _name.text = detail['name']?.toString() ?? '';
          _url.text = (detail['remoteUrl'] ?? detail['remote_url'] ?? '').toString();
          _isRemote = detail['isRemote'] == true || detail['is_remote'] == true;
          _autoUpdate = detail['autoUpdate'] == true || detail['auto_update'] == true;
          _isRaw = detail['isRaw'] == true || detail['is_raw'] == true;
          _defaultOutbound = detail['defaultOutbound']?.toString() ?? 'direct';
          _rules = [for (final rule in rules) ruleFromWire(rule)];
          _rulesDirty = false;
          _loading = false;
        });
      } else {
        // RouteItem.cpp:61-67 seeds a new profile with the DNS hijack rule.
        final seed = widget.remote
            ? const <Json>[]
            : [
                ruleFromWire(const {'name': 'dns-hijack', 'protocol': 'dns', 'action': 'hijack-dns'}),
              ];
        if (!mounted) return;
        setState(() {
          _rules = seed;
          _rulesDirty = false;
          _loading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  // --- save ---------------------------------------------------------------------

  Future<void> _save() async {
    final name = _name.text.trim();
    final url = _url.text.trim();
    if (name.isEmpty) {
      setState(() => _formError = context.tr('A profile needs a name'));
      return;
    }
    if (_isRemote && url.isEmpty) {
      setState(() => _formError = context.tr('A remote profile needs a URL'));
      return;
    }
    if (_isRemote && !isSafeRemoteRouteUrl(url)) {
      setState(() => _formError = context.tr('Only a public http(s) URL is accepted'));
      return;
    }
    setState(() {
      _saving = true;
      _formError = null;
    });
    final box = ref.read(boxControllerProvider);
    try {
      final saved = await box.routeSaveProfile(
        id: _id,
        name: name,
        defaultOutbound: _defaultOutbound,
        isRemote: _isRemote,
        remoteUrl: url,
        autoUpdate: _autoUpdate,
      );
      final savedId = _savedId(saved) > 0 ? _savedId(saved) : _id;
      if (savedId > 0) {
        final rules = [for (final rule in _rules) ruleToWire(rule)];
        await box.routeSaveRules(savedId, rules);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = BoxController.describe(error);
      });
    }
  }

  // --- rule mutations -----------------------------------------------------------

  Future<void> _addRule() async {
    final result = await openPage<RouteRuleEditorResult>(
      context,
      RouteRuleEditorPage(
        initial: ruleFromWire(const {'action': 'route', 'outbound_id': -1, 'type': 'custom'}),
        isNew: true,
      ),
    );
    if (result?.rule == null || !mounted) return;
    setState(() {
      _rules = [..._rules, result!.rule!];
      _rulesDirty = true;
    });
  }

  Future<void> _editRule(int index) async {
    final result = await openPage<RouteRuleEditorResult>(
      context,
      RouteRuleEditorPage(initial: _rules[index]),
    );
    if (result == null || !mounted) return;
    if (result.deleted) {
      _removeRule(index);
      return;
    }
    if (result.rule == null) return;
    setState(() {
      final rules = [..._rules];
      rules[index] = result.rule!;
      _rules = rules;
      _rulesDirty = true;
    });
  }

  void _removeRule(int index) {
    if (index < 0 || index >= _rules.length) return;
    final removed = _rules[index];
    final previous = [..._rules];
    setState(() {
      _undoRules = previous;
      _rules = [..._rules]..removeAt(index);
      _rulesDirty = true;
    });
    // The banner's tap is the undo: Prism's banner takes one action, and a
    // deleted rule that cannot be brought back would be a lost edit.
    BannerHost.maybeOf(context)?.show(
      '${context.tr('Rule deleted')}: ${ruleName(removed, index)}',
      onTap: () {
        if (!mounted) return;
        setState(() => _rules = _undoRules ?? previous);
      },
    );
  }

  void _toggleDisabled(int index, bool value) {
    setState(() {
      final rules = [..._rules];
      rules[index] = {...rules[index], 'disabled': !value};
      _rules = rules;
      _rulesDirty = true;
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final rules = [..._rules];
      final moved = rules.removeAt(oldIndex);
      rules.insert(newIndex.clamp(0, rules.length), moved);
      _rules = rules;
      _rulesDirty = true;
    });
  }

  Future<void> _batchAdd() async {
    final text = await showAppDialog<String>(context, child: _BatchAddDialog());
    if (text == null || text.trim().isEmpty || !mounted) return;
    if (_id <= 0) {
      // The kernel batch-adds into a saved profile; a new one saves first.
      setState(() => _formError = context.tr('Save the profile before adding rules in bulk'));
      return;
    }
    // The host extends its *stored* rules and the answer replaces the local
    // list wholesale; unsaved in-memory edits would vanish silently. Ask first.
    if (_rulesDirty) {
      final proceed = await confirm(
        context,
        'Bulk add replaces your unsaved rule edits',
        action: 'Continue',
      );
      if (!proceed || !mounted) return;
    }
    try {
      final answer = json(await ref.read(boxControllerProvider).routeBatchAddRules(_id, text));
      final rules = rows(answer['rules']);
      if (!mounted) return;
      setState(() {
        _rules = [for (final rule in rules) ruleFromWire(rule)];
        _rulesDirty = false;
      });
      showAppBanner(context, '${context.tr('Rules added')}: ${answer['added'] ?? rules.length}');
    } catch (error) {
      if (mounted) ref.read(boxControllerProvider).report(error);
    }
  }

  Future<void> _resetRules() async {
    if (_id <= 0) {
      setState(() => _formError = context.tr('Save the profile before resetting its rules'));
      return;
    }
    final ok = await confirm(
      context,
      'Reset the rules?',
      message: context.tr('Every rule is replaced with the Default chain, the one DNS hijack rule.'),
      action: 'Reset',
    );
    if (!ok || !mounted) return;
    try {
      final answer = json(await ref.read(boxControllerProvider).routeResetRules(_id));
      final rules = rows(answer['rules']);
      if (!mounted) return;
      setState(() => _rules = [for (final rule in rules) ruleFromWire(rule)]);
    } catch (error) {
      if (mounted) ref.read(boxControllerProvider).report(error);
    }
  }

  Future<void> _fetchNow() async {
    if (_id <= 0) {
      setState(() => _formError = context.tr('Save the profile before fetching it'));
      return;
    }
    setState(() => _saving = true);
    try {
      final count = await updateRemoteProfile(ref.read(boxControllerProvider), _id);
      if (!mounted) return;
      setState(() => _saving = false);
      showAppBanner(context, '${context.tr('Rules updated')}: $count');
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = BoxController.describe(error);
      });
    }
  }

  // --- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: _id > 0 ? context.tr('Route profile') : context.tr('New route profile'),
      // No `isLoading`: the scaffold answers it with a LoadingBar laid out at
      // the bar's foot and drawn past it (bottom: -3, clip none), which on a
      // phone reads as a blue pill hanging off the bar's end. This page paints
      // its own progress inline in the body instead, and its save state
      // already disables every control it blocks.
      confirmationAction: _editable
          ? IconButtonData(
              glyph: AppGlyphs.check,
              tooltip: context.tr('Save'),
              onPressed: _loading || _saving ? null : _save,
            )
          : null,
      iconActions: [
        if (_editable) ...[
          IconButtonData(
            glyph: AppGlyphs.add,
            tooltip: context.tr('Add rule'),
            onPressed: _loading ? null : _addRule,
          ),
          IconButtonData(
            glyph: AppGlyphs.reset,
            tooltip: context.tr('Reset rules'),
            onPressed: _loading ? null : _resetRules,
          ),
        ],
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: context.tr('Refresh'),
          onPressed: _loading ? null : _load,
        ),
      ],
      body: Stack(
        fit: StackFit.expand,
        children: [
          _body(context),
          // The bar floats over the body at nine tenths of the page colour and
          // fades out, so a scrolled row stayed faintly legible through it —
          // the URL line, most visibly. An opaque strip of the same colour
          // under the bar, easing out over its last 30%, keeps the bar clean
          // without a shared-scaffold change; content still passes under its
          // foot as on every other page.
          PositionedDirectional(
            top: 0,
            start: 0,
            end: 0,
            height: context.appBarInset,
            child: IgnorePointer(child: _barBackdrop(context)),
          ),
        ],
      ),
    );
  }

  Widget _barBackdrop(BuildContext context) {
    final page = SurfaceLevel.page.colorOf(context.colorScheme);
    return DecoratedBox(
      key: const ValueKey('route-editor-bar-backdrop'),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: const [.7, 1],
          colors: [page, page.withValues(alpha: 0)],
        ),
      ),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: ActivityIndicator.page());
    if (_error != null) return ErrorState(_error!, retry: _load);
    return ListView(
      // The body opens on a titled section, whose header brings its own 24 gap
      // above it; sectionsTopPadding takes that off the page's own clearance so
      // the first header lands where contentTopPadding puts any other page's
      // first row (the same contract as settings and route_fragment).
      padding: boxPagePadding(context).copyWith(top: context.sectionsTopPadding),
      children: [
        if (_saving)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (_formError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_formError!, style: context.listCaptionStyle.copyWith(color: context.colorScheme.error)),
          ),
        generateSection(title: context.tr('Profile'), items: [
          if (!_editable)
            _valueDisplay(context, title: context.tr('Name'), value: _name.text)
          else
            _valueRow(
              context,
              'route-profile-name',
              title: context.tr('Name'),
              value: _name.text,
              hintText: '',
              onChanged: (value) => setState(() => _name.text = value),
            ),
          if (!_editable)
            ListItem(
              title: Text(context.tr('Default outbound')),
              trailing: Text(context.tr(_outboundName(_defaultOutboundId)), style: context.listValueStyle),
            )
          else
            ListItem<int>.options(
              title: Text(context.tr('Default outbound')),
              options: const [-1, -2, -3, -5],
              value: _defaultOutboundId,
              textBuilder: (value) => context.tr(_outboundName(value)),
              onChanged: (value) => setState(() => _defaultOutbound = _outboundName(value)),
            ),
        ]),
        if (_isRemote || widget.remote)
          generateSection(title: context.tr('Remote'), items: [
            if (!_editable)
              _valueDisplay(
                context,
                title: context.tr('URL'),
                value: _url.text,
              )
            else
              _valueRow(
                context,
                'route-profile-url',
                title: context.tr('URL'),
                value: _url.text,
                hintText: 'https://example.com/route.json',
                onChanged: (value) => setState(() => _url.text = value),
              ),
            ListItem.toggle(
              title: Text(context.tr('Auto update')),
              value: _autoUpdate,
              onChanged: _editable ? (value) => setState(() => _autoUpdate = value) : null,
            ),
            if (_id > 0)
              ListItem(
                leading: GlyphIcon(AppGlyphs.cloudDownload),
                title: Text(context.tr('Fetch now')),
                subtitle: Text(context.tr('Download the rule list and replace these rules.')),
                onTap: _editable && !_saving ? _fetchNow : null,
              ),
          ]),
        if (_isRaw)
          generateSection(items: [
            ListItem(
              leading: const GlyphIcon(AppGlyphs.info),
              title: Text(context.tr('This profile is read-only')),
              subtitle: Text(context.tr('The desktop built it from a raw route; this build lists it verbatim.')),
            ),
          ]),
        // Rules: the header carries the count, the footer the bulk actions.
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
          child: Row(children: [
            Expanded(
              child: Text('${context.tr('Rules')} (${_rules.length})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline.of(context, emphasized: true)),
            ),
            if (_editable)
              TextButton(onPressed: _saving ? null : _batchAdd, child: Text(context.tr('Bulk add'))),
          ]),
        ),
        if (_rules.isEmpty)
          NullStatus(
            label: context.tr('No rules yet'),
            description: context.tr('Rules run top to bottom; the first match wins.'),
            illustration: NullStatusIllustration.rules,
            action: _editable
                ? TonalButton(
                    size: TonalButtonSize.bar,
                    glyph: AppGlyphs.add,
                    label: context.tr('Add rule'),
                    onPressed: _addRule,
                  )
                : null,
          )
        else
          generateGroup([
            for (var index = 0; index < _rules.length; index++) _ruleRow(context, index),
          ]),
        if (_editable)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Card(
              radius: AppCorner.lg,
              onPressed: _saving ? null : _addRule,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(children: [
                const GlyphIcon(AppGlyphs.add),
                const SizedBox(width: 12),
                Text(context.tr('Add rule')),
              ]),
            ),
          ),
      ],
    );
  }

  int get _defaultOutboundId => switch (_defaultOutbound) {
        'proxy' => -1,
        'block' => -3,
        'warp-bypass' => -5,
        _ => -2,
      };

  String _outboundName(int id) => switch (id) {
        -1 => 'Proxy',
        -3 => 'Block',
        -5 => 'WARP bypass',
        _ => 'Direct',
      };

  /// One rule row: the enable tick, the two-line summary, the drag handle, and
  /// the destructive actions behind a swipe-like menu.
  Widget _ruleRow(BuildContext context, int index) {
    final rule = _rules[index];
    final enabled = rule['disabled'] != true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ItemPositionProvider(
        position: ItemPosition.get(index, _rules.length),
        child: DecorationListItem(
          leading: Checkbox(
            value: enabled,
            onChanged: _editable ? (value) => _toggleDisabled(index, value == true) : null,
          ),
          title: Opacity(
            opacity: enabled ? 1 : .5,
            child: Text(ruleName(rule, index), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          // ruleRowSubtitle is a Text.rich the row must not let grow without
          // bound: a rule with many conditions would otherwise size the row to
          // whatever the conditions run to.
          subtitle: Opacity(
            opacity: enabled ? 1 : .5,
            child: DefaultTextStyle.merge(
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              child: ruleRowSubtitle(context, rule),
            ),
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (_editable)
              PopupAnchor(
                targetBuilder: (open) => IconButton(
                  tooltip: context.tr('Move'),
                  icon: const GlyphIcon(AppGlyphs.arrowUp),
                  onPressed: open,
                ),
                popupBuilder: (_) => PopupMenu(items: [
                  PopupMenuItem(
                    glyph: AppGlyphs.arrowUp,
                    label: context.tr('Move up'),
                    onPressed: index > 0 ? () => _reorder(index, index - 1) : null,
                  ),
                  PopupMenuItem(
                    glyph: AppGlyphs.arrowDown,
                    label: context.tr('Move down'),
                    onPressed: index < _rules.length - 1 ? () => _reorder(index + 1, index) : null,
                  ),
                  PopupMenuItem(
                    glyph: AppGlyphs.delete,
                    label: context.tr('Delete'),
                    danger: true,
                    onPressed: () => _removeRule(index),
                  ),
                ]),
              ),
            if (_editable) SortHandle(index: index),
          ]),
          onPressed: _editable ? () => _editRule(index) : null,
        ),
      ),
    );
  }

  int _savedId(dynamic saved) {
    if (saved is num) return saved.toInt();
    if (saved is Map) return (saved['id'] as num?)?.toInt() ?? 0;
    return 0;
  }

  /// A one-line value row that edits through the same dialog [ListItem.input]
  /// opens, with the value held to half the row: `ListItem.input` hands its
  /// value to `ListRow`'s trailing slot as an unconstrained `Text`, so a long
  /// remote URL takes the width it wants and the title is squeezed to one
  /// character a line.
  Widget _valueRow(
    BuildContext context,
    String key, {
    required String title,
    required String value,
    required String hintText,
    required ValueChanged<String> onChanged,
  }) {
    return ListItem(
      key: ValueKey(key),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .45),
        child: TooltipText(
          text: Text(
            value.isEmpty ? context.tr('Not set') : value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: context.listValueStyle,
          ),
        ),
      ),
      onTap: () async {
        final edited = await showAppDialog<String>(
          context,
          child: InputDialog(title: title, value: value, hintText: hintText),
        );
        if (edited != null) onChanged(edited);
      },
    );
  }

  /// The read-only form of [_valueRow]: the same one-line, half-width value,
  /// with the label it belongs to.
  Widget _valueDisplay(
    BuildContext context, {
    required String title,
    required String value,
  }) {
    return ListItem(
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .45),
        child: TooltipText(
          text: Text(
            value.isEmpty ? context.tr('Not set') : value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: context.listValueStyle,
          ),
        ),
      ),
    );
  }
}

/// The bulk-add sheet: `prefix:value -> outbound` lines, one rule each.
class _BatchAddDialog extends StatefulWidget {
  @override
  State<_BatchAddDialog> createState() => _BatchAddDialogState();
}

class _BatchAddDialogState extends State<_BatchAddDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        hasFields: true,
        title: context.tr('Bulk add'),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              context.tr('One rule per line: suffix:example.com -> proxy, ip:10.0.0.0/8 -> direct.'),
              style: AppTextStyle.caption1.of(context),
            ),
          ),
          TextField(
            key: const Key('route-batch-add-field'),
            controller: _controller,
            minLines: 5,
            maxLines: 10,
            autocorrect: false,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
            decoration: const InputDecoration(hintText: 'suffix:example.com -> proxy'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(context.tr('Add'))),
        ],
      );
}
