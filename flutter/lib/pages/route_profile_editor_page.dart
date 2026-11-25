// The one global rule table, Throne for Android's route list: an ordered list of
// rules that applies everywhere. There are no route profiles any more — Go owns
// `global_route_rules.json` and this page is its editor.
//
// Edits stay in memory until Save: the kernel replaces the whole rule array at
// once (`routeSaveGlobalRules`), so every mutation here works on the local copy
// and one Save commits it. Deleting a rule keeps the previous list for the
// banner's undo; reordering is drag-to-reorder or the row's up/down menu.

import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The single global rule list. `settings.dart` and `configuration.dart` open
/// [RoutingPage], which is this page; the name here says what it edits.
class GlobalRulesPage extends ConsumerStatefulWidget {
  const GlobalRulesPage({super.key});

  @override
  ConsumerState<GlobalRulesPage> createState() => _GlobalRulesPageState();
}

class _GlobalRulesPageState extends ConsumerState<GlobalRulesPage> {
  List<Json> _rules = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _formError;

  /// The last committed rule list, for a delete's undo.
  List<Json>? _undoRules;

  /// A manual "Update resources" run is in flight.
  bool _updatingResources = false;

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
    final box = ref.read(boxControllerProvider);
    try {
      final answer = json(await box.routeGlobalRules());
      final rules = rows(answer['rules']);
      if (!mounted) return;
      setState(() {
        _rules = [for (final rule in rules) ruleFromWire(rule)];
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

  // --- save ---------------------------------------------------------------------

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _formError = null;
    });
    final box = ref.read(boxControllerProvider);
    try {
      // One whole-table replace: no profile id, no merge, no partial write.
      await box.routeSaveGlobalRules([for (final rule in _rules) ruleToWire(rule)]);
      if (!mounted) return;
      showAppBanner(context, context.tr('Saved'));
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _formError = BoxController.describe(error);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
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
    setState(() => _rules = [..._rules, result!.rule!]);
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
    });
  }

  void _removeRule(int index) {
    if (index < 0 || index >= _rules.length) return;
    final removed = _rules[index];
    final previous = [..._rules];
    setState(() {
      _undoRules = previous;
      _rules = [..._rules]..removeAt(index);
    });
    // The banner's tap is the undo: a deleted rule that cannot be brought back
    // would be a lost edit.
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
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final rules = [..._rules];
      final moved = rules.removeAt(oldIndex);
      rules.insert(newIndex.clamp(0, rules.length), moved);
      _rules = rules;
    });
  }

  /// Reads `prefix:value -> outbound` lines into rules locally. The kernel's
  /// profile-scoped batch-add action is gone with the profiles; a bulk add now
  /// appends to the one in-memory list and rides the ordinary whole-table save.
  Future<void> _batchAdd() async {
    final text = await showAppDialog<String>(context, child: const _BatchAddDialog());
    if (text == null || text.trim().isEmpty || !mounted) return;
    final added = _parseBatch(text);
    if (added.isEmpty) {
      if (mounted) {
        showAppBanner(context, context.tr('No rules were added'), level: BannerLevel.warning);
      }
      return;
    }
    setState(() => _rules = [..._rules, ...added]);
    if (mounted) showAppBanner(context, '${context.tr('Rules added')}: ${added.length}');
  }

  /// The short-name aliases the dialog's prefixes stand for; `ruleFromWire`
  /// canonicalises them into the `_json` columns on the way in.
  static const _batchFields = <String, String>{
    'suffix': 'domain_suffix', 'domain': 'domain', 'keyword': 'domain_keyword',
    'regex': 'domain_regex', 'ip': 'ip_cidr', 'ip-cidr': 'ip_cidr',
    'port': 'port', 'process': 'process_name', 'app': 'package_name',
    'rule-set': 'rule_set', 'inbound': 'inbound',
  };

  List<Json> _parseBatch(String text) {
    final out = <Json>[];
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final arrow = line.indexOf('->');
      if (arrow <= 0) continue;
      final match = line.substring(0, arrow).trim();
      final target = line.substring(arrow + 2).trim();
      final colon = match.indexOf(':');
      if (colon <= 0) continue;
      final field = _batchFields[match.substring(0, colon).trim().toLowerCase()];
      final value = match.substring(colon + 1).trim();
      if (field == null || value.isEmpty) continue;
      final id = switch (target.toLowerCase()) {
        'proxy' => -1,
        'direct' => -2,
        'block' => -3,
        'warp-bypass' => -5,
        _ => int.tryParse(target) ?? -2,
      };
      out.add(ruleFromWire(<String, dynamic>{
        'name': '$field:$value',
        'type': 'custom',
        'action': 'route',
        'outbound_id': id,
        field: <String>[value],
      }));
    }
    return out;
  }

  // The manual resource update: the core's remote rule-sets. A stopped tunnel
  // skips the work and the banner says why — the item stays enabled.
  Future<void> _updateResources() async {
    if (_updatingResources) return;
    setState(() => _updatingResources = true);
    try {
      final report = await ref.read(boxControllerProvider).updateResources();
      if (!mounted) return;
      final lines = <String>[
        '${context.tr('Rule sets')}: ${report.ruleSetsUpdated}',
        if (report.ruleSetsSkipped)
          context.tr('The core is not running; rule sets can only be updated while the tunnel is up.'),
        if (report.ruleSetsFailure != null)
          '${context.tr('Rule sets')}: ${report.ruleSetsFailure}',
        if (report.ruleSetsError.isNotEmpty)
          '${context.tr('Rule sets')}: ${report.ruleSetsError}',
      ];
      showAppBanner(
        context,
        lines.join('\n'),
        level: report.clean && !report.ruleSetsSkipped
            ? BannerLevel.info
            : BannerLevel.warning,
      );
    } finally {
      if (mounted) setState(() => _updatingResources = false);
    }
  }

  Future<void> _openSettings() =>
      openPage<void>(context, const RouteEngineSettingsPage());

  // --- build --------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: context.tr('Routing'),
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: context.tr('Save'),
        onPressed: _loading || _saving ? null : _save,
      ),
      iconActions: [
        IconButtonData(
          glyph: AppGlyphs.add,
          tooltip: context.tr('Add rule'),
          onPressed: _loading ? null : _addRule,
        ),
        IconButtonData(
          glyph: AppGlyphs.refresh,
          tooltip: context.tr('Refresh'),
          onPressed: _loading ? null : _load,
        ),
      ],
      menuItems: [
        PopupMenuItem(
          glyph: AppGlyphs.resources,
          label: context.tr('Update resources'),
          onPressed: _updatingResources ? null : _updateResources,
        ),
        PopupMenuItem(
          glyph: AppGlyphs.sliders,
          label: context.tr('Routing settings'),
          onPressed: _openSettings,
        ),
      ],
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: ActivityIndicator.page());
    if (_error != null) return ErrorState(_error!, retry: _load);
    return ListView(
      padding: boxPagePadding(context),
      children: [
        if (_saving)
          const Padding(
            padding: EdgeInsets.only(bottom: 12),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        if (_formError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_formError!,
                style: context.listCaptionStyle.copyWith(color: context.colorScheme.error)),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Row(children: [
            Expanded(
              child: Text('${context.tr('Rules')} (${_rules.length})',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyle.subheadline.of(context, emphasized: true)),
            ),
            TextButton(onPressed: _saving ? null : _batchAdd, child: Text(context.tr('Bulk add'))),
          ]),
        ),
        if (_rules.isEmpty)
          NullStatus(
            label: context.tr('No rules yet'),
            description: context.tr('Rules run top to bottom; the first match wins.'),
            illustration: NullStatusIllustration.rules,
            action: TonalButton(
              size: TonalButtonSize.bar,
              glyph: AppGlyphs.add,
              label: context.tr('Add rule'),
              onPressed: _addRule,
            ),
          )
        else
          generateGroup([
            for (var index = 0; index < _rules.length; index++) _ruleRow(context, index),
          ]),
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

  /// One rule row: the enable tick, the two-line summary, the drag handle, and
  /// the destructive actions behind a menu.
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
            onChanged: (value) => _toggleDisabled(index, value == true),
          ),
          title: Opacity(
            opacity: enabled ? 1 : .5,
            child: Text(ruleName(rule, index), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          subtitle: Opacity(
            opacity: enabled ? 1 : .5,
            child: DefaultTextStyle.merge(
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              child: ruleRowSubtitle(context, rule),
            ),
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
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
            SortHandle(index: index),
          ]),
          onPressed: () => _editRule(index),
        ),
      ),
    );
  }
}

/// The bulk-add sheet: `prefix:value -> outbound` lines, one rule each.
class _BatchAddDialog extends StatefulWidget {
  const _BatchAddDialog();

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
