// The one global rule table, Throne for Android's route list: an ordered list of
// rules that applies everywhere. There are no route profiles any more — Go owns
// `global_route_rules.json` and this page is its editor.
//
// Every mutation commits at once, the way FlClash's added-rules screen behaves:
// the kernel applies one incremental patch (`saveGlobalRulesPatch`) guarded by
// the revision of the snapshot the list was loaded from, a save in flight queues
// one follow-up instead of dropping the newer edit, and a failed write keeps the
// edited list on screen with the reason. A stale refusal reloads the snapshot
// and surfaces an error — it never silently merges or renumbers. Deleting a rule
// keeps its own previous list for the banner's undo; cards reorder by drag.

import 'dart:async';

import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// A rule's stable id from the kernel, or null for a rule added locally. The
/// id is the only safe identity for patch compute: positions move on reorder.
int? ruleId(Json rule) {
  final value = rule['id'];
  final id = switch (value) {
    num() => value.toInt(),
    String() => int.tryParse(value),
    _ => null,
  };
  // Go starts ids at 1; a 0 (or negative) is an unset sentinel, not identity.
  return id != null && id > 0 ? id : null;
}

/// The single global rule list. `settings.dart` and `configuration.dart` open
/// [RoutingPage], which is this page; the name here says what it edits.
class GlobalRulesPage extends ConsumerStatefulWidget {
  const GlobalRulesPage({super.key});

  @override
  ConsumerState<GlobalRulesPage> createState() => _GlobalRulesPageState();
}

class _GlobalRulesPageState extends ConsumerState<GlobalRulesPage> {
  List<Json> _rules = const [];

  /// The snapshot this draft was built from. Its version is the baseVersion of
  /// every patch, and its id set is what added/updated/deleted are computed
  /// against. Null until the first successful load.
  RouteRulesSnapshot? _base;

  /// The snapshot's rules in the editor's flat shape, canonicalised through
  /// ruleFromWire/ruleToWire exactly like the draft. Comparing this with the
  /// draft's wire form avoids sending no-op updates for shorthand keys Go adds
  /// (`enabled`, `domain`, ...) that the editor does not represent.
  List<Json> _baseRules = const [];

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _formError;

  /// Bumped on every load so a slow response cannot overwrite newer edits.
  int _loadGeneration = 0;

  /// An edit landed while a save was in flight; it is committed after that save
  /// instead of being dropped.
  bool _saveQueued = false;

  /// A manual "Update resources" run is in flight.
  bool _updatingResources = false;

  /// The bottom search field's text, and the rules selected through the row circles.
  final _searchController = TextEditingController();
  String _query = '';
  final Set<Json> _selected = {};

  /// No edit may start while the list is still loading. A save does not block
  /// editing: the next change queues behind it.
  bool get _busy => _loading;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// The rules the search leaves visible, with their index in the full list.
  List<(int, Json)> get _visibleRules {
    final words = _query
        .toLowerCase()
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.isEmpty) {
      return [for (var index = 0; index < _rules.length; index++) (index, _rules[index])];
    }
    return [
      for (var index = 0; index < _rules.length; index++)
        if (words.every((word) => _haystack(_rules[index], index).contains(word)))
          (index, _rules[index]),
    ];
  }

  String _haystack(Json rule, int index) => '${ruleTypeLabel(rule)} '
      '${ruleName(rule, index)} ${ruleActionText(rule)} '
      '${ruleTargetLabel(rule)} ${ruleConditions(context, rule)}'
          .toLowerCase();

  void _toggleSelected(Json rule) {
    if (_busy) return;
    setState(() {
      if (!_selected.remove(rule)) _selected.add(rule);
    });
  }

  void _selectAll() {
    setState(() {
      final visible = [for (final (_, rule) in _visibleRules) rule];
      if (visible.every(_selected.contains)) {
        _selected.removeAll(visible);
      } else {
        _selected.addAll(visible);
      }
    });
  }

  /// Deletes every circled rule in one step, with the same undo banner the
  /// single-row delete shows.
  Future<void> _deleteSelected() async {
    if (_selected.isEmpty || _busy) return;
    if (!await confirm(context, 'Delete the selected rules?', action: 'Delete')) return;
    if (!mounted) return;
    final removed = Set<Json>.of(_selected);
    final previous = [..._rules];
    _changed(() {
      _rules = [for (final rule in _rules) if (!removed.contains(rule)) rule];
      _selected.clear();
    });
    BannerHost.maybeOf(context)?.show(
      '${context.tr('Rules deleted')}: ${removed.length}',
      onTap: () {
        if (!mounted) return;
        _changed(() => _rules = [...previous]);
      },
    );
  }

  Future<void> _load() async {
    if (!mounted) return;
    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
    });
    final box = ref.read(boxControllerProvider);
    try {
      final snapshot = await box.routeGlobalRulesSnapshot();
      final rules = [for (final rule in snapshot.rules) ruleFromWire(rule)];
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _rules = rules;
        _base = snapshot;
        _baseRules = rules;
        // The old rows are gone: a selection built from them could only delete nothing.
        _selected.clear();
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  // --- commits ------------------------------------------------------------------

  /// Applies [mutate] and commits the table. Every mutation builds one patch
  /// from the draft against the loaded snapshot; the list on screen is what
  /// the kernel receives (as adds/updates/deletes plus an explicit order).
  void _changed(VoidCallback mutate) {
    setState(mutate);
    unawaited(_commit());
  }

  /// Builds the patch whose application turns [_base] into the current draft.
  /// A rule's `id` is its identity: absent on a newly added rule, present on
  /// every rule that came from the snapshot. Only rows whose wire shape changed
  /// are sent as updates; the explicit order covers every row, with a 0
  /// placeholder for each addition (Go resolves those to the ids it assigns).
  RouteRulesPatch _patchFromDraft() {
    final base = _base;
    if (base == null) {
      // No snapshot yet: nothing can be committed against a base version.
      return const RouteRulesPatch(baseVersion: 0);
    }
    final before = {for (final rule in _baseRules) ruleId(rule): ruleToWire(rule)};
    final afterIds = <int>{};
    final added = <Json>[];
    final updated = <Json>[];
    final order = <int>[];

    for (final rule in _rules) {
      final id = ruleId(rule);
      final wire = ruleToWire(rule);
      if (id == null) {
        added.add(wire);
        order.add(0); // Go assigns an id and resolves placeholders left to right.
      } else {
        afterIds.add(id);
        if (before[id] != null && !_sameWire(before[id]!, wire)) {
          updated.add(wire);
        }
        order.add(id);
      }
    }
    final beforeIds = before.keys.whereType<int>().toSet();
    final deleted = [for (final id in beforeIds) if (!afterIds.contains(id)) id];
    return RouteRulesPatch(
      baseVersion: base.version,
      added: added,
      updated: updated,
      deleted: deleted,
      order: order,
    );
  }

  static bool _sameWire(Json a, Json b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (entry.value is List && other is List) {
        if (entry.value.length != other.length) return false;
        for (var i = 0; i < entry.value.length; i++) {
          if (entry.value[i] != other[i]) return false;
        }
      } else if (entry.value != other) {
        return false;
      }
    }
    return true;
  }

  Future<void> _commit() async {
    if (_saving) {
      // The newer list wins when this save finishes; dropping it would lose a
      // drag that landed during a write.
      _saveQueued = true;
      return;
    }
    final patch = _patchFromDraft();
    setState(() {
      _saving = true;
      _formError = null;
    });
    final box = ref.read(boxControllerProvider);
    try {
      final result = await box.routeSaveGlobalRulesPatch(patch);
      // Attach the ids Go assigned to new rules so the next patch sees them as
      // updates, not as a second set of additions.
      final newIds = List<int>.from(result.ids);
      var next = 0;
      if (!mounted) return;
      setState(() {
        for (var i = 0; i < _rules.length; i++) {
          if (ruleId(_rules[i]) == null && next < newIds.length) {
            _rules[i] = {..._rules[i], 'id': newIds[next++]};
          }
        }
        _base = RouteRulesSnapshot(
          [for (final rule in _rules) ruleToWire(rule)],
          result.version,
          result.etag,
        );
        _baseRules = List<Json>.from(_rules);
      });
      // A save that raced with a load must not resurrect the older generation's
      // rules underneath the user.
      ++_loadGeneration;
    } on RouteRulesStale catch (stale) {
      if (!mounted) return;
      // The store moved since this draft was loaded. Reload the authoritative
      // snapshot but keep the user's draft on screen and say why the write was
      // refused — no silent merge, no id renumber.
      _saveQueued = false;
      setState(() {
        _saving = false;
        _formError = '${context.tr('Rules changed elsewhere; external changes were merged — review your edit')} '
            '(version ${stale.currentVersion}).';
      });
      unawaited(_refreshAfterStale());
      showAppBanner(context, context.tr('Save failed: rules changed elsewhere'), level: BannerLevel.error);
      return;
    } catch (error) {
      if (!mounted) return;
      // The queued edit is still on screen; the next change retries the patch.
      // Keeping the flag would make that retry write twice.
      _saveQueued = false;
      setState(() {
        _saving = false;
        _formError = BoxController.describe(error);
      });
      showAppBanner(context, context.tr('Save failed'), level: BannerLevel.error);
      return;
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (_saveQueued) {
      _saveQueued = false;
      await _commit();
    }
  }

  /// Reloads the base snapshot after a stale refusal and merges the changes the
  /// other writer made into the draft, so the next patch cannot delete rows the
  /// user never saw. External additions are appended, external deletions are
  /// dropped from the draft, and for a row both sides changed the user's draft
  /// wins (they were editing it). The draft is otherwise left in place.
  Future<void> _refreshAfterStale() async {
    try {
      final snapshot = await ref.read(boxControllerProvider).routeGlobalRulesSnapshot();
      if (!mounted) return;
      final incoming = [for (final rule in snapshot.rules) ruleFromWire(rule)];
      final draftIds = _rules.map(ruleId).whereType<int>().toSet();
      final incomingIds = incoming.map(ruleId).whereType<int>().toSet();
      setState(() {
        _rules = [
          // Keep local additions (no id yet) and every row the store still has;
          // a row deleted elsewhere disappears from the draft.
          for (final rule in _rules)
            if (ruleId(rule) == null || incomingIds.contains(ruleId(rule))) rule,
          // Surface external additions the draft never saw.
          for (final rule in incoming)
            if (!draftIds.contains(ruleId(rule))) rule,
        ];
        _base = snapshot;
        _baseRules = incoming;
      });
    } catch (_) {
      // The error is already on screen; a failed refresh must not hide it.
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
    _changed(() => _rules = [..._rules, result!.rule!]);
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
    _changed(() {
      final rules = [..._rules];
      rules[index] = result.rule!;
      _rules = rules;
    });
  }

  void _removeRule(int index) {
    if (index < 0 || index >= _rules.length) return;
    final removed = _rules[index];
    final previous = [..._rules];
    _changed(() => _rules = [..._rules]..removeAt(index));
    // Each banner captures its own snapshot: two quick deletions must not make
    // the older banner restore the newer deletion's list (and lose a rule).
    BannerHost.maybeOf(context)?.show(
      '${context.tr('Rule deleted')}: ${ruleName(removed, index)}',
      onTap: () {
        if (!mounted) return;
        _changed(() => _rules = [...previous]);
      },
    );
  }

  void _reorder(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    _changed(() {
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
    _changed(() => _rules = [..._rules, ...added]);
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
      iconActions: [
        if (_selected.isNotEmpty) ...[
          IconButtonData(
            glyph: AppGlyphs.delete,
            tooltip: context.tr('Delete'),
            onPressed: _busy ? null : _deleteSelected,
          ),
          IconButtonData(
            glyph: AppGlyphs.selectAll,
            tooltip: context.tr('Select all'),
            onPressed: _busy ? null : _selectAll,
          ),
        ] else ...[
          IconButtonData(
            glyph: AppGlyphs.rulePresets,
            tooltip: context.tr('Bulk add'),
            onPressed: _busy ? null : _batchAdd,
          ),
          IconButtonData(
            glyph: AppGlyphs.addCircle,
            tooltip: context.tr('Add rule'),
            onPressed: _busy ? null : _addRule,
          ),
        ],
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
        PopupMenuItem(
          glyph: AppGlyphs.refresh,
          label: context.tr('Refresh'),
          onPressed: _loading ? null : _load,
        ),
      ],
      body: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    if (_loading) return const Center(child: ActivityIndicator.page());
    if (_error != null) return ErrorState(_error!, retry: _load);
    final visible = _visibleRules;
    final searching = _query.trim().isNotEmpty;
    return Column(children: [
      if (_saving) const LinearProgressIndicator(minHeight: 3),
      if (_formError != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(_formError!,
              style: context.listCaptionStyle.copyWith(color: context.colorScheme.error)),
        ),
      Expanded(
        child: _rules.isEmpty
            ? NullStatus(
                label: context.tr('No rules yet'),
                description: context.tr('Rules run top to bottom; the first match wins.'),
                illustration: NullStatusIllustration.rules,
                action: TonalButton(
                  size: TonalButtonSize.bar,
                  glyph: AppGlyphs.add,
                  label: context.tr('Add rule'),
                  onPressed: _busy ? null : _addRule,
                ),
              )
            : visible.isEmpty
                ? NullStatus(
                    label: context.tr('No search results'),
                    illustration: NullStatusIllustration.rules,
                  )
                : searching
                    // A filtered list is a reading aid, not a reordering surface:
                    // dragging while half the rows are hidden would be ambiguous.
                    ? ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                            16, context.contentTopPadding, 16, 16 + context.bottomInset),
                        itemCount: visible.length,
                        itemBuilder: (_, position) {
                          final (index, rule) = visible[position];
                          // The filtered list is its own group: its first and last
                          // visible row carry the group's rounded corners.
                          return _ruleCard(context, rule, index,
                              position: ItemPosition.get(position, visible.length));
                        },
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        padding: EdgeInsets.fromLTRB(
                            16, context.contentTopPadding, 16, 16 + context.bottomInset),
                        itemCount: _rules.length,
                        proxyDecorator: (_, index, animation) => commonProxyDecorator(
                            _ruleCard(context, _rules[index], index), index, animation),
                        onReorderItem: _reorder,
                        itemBuilder: (_, index) => ReorderableDelayedDragStartListener(
                          key: ObjectKey(_rules[index]),
                          index: index,
                          child: _ruleCard(context, _rules[index], index),
                        ),
                      ),
      ),
      _searchBar(context),
    ]);
  }

  /// FlClash's bottom search pill: filters by the type, value, target and
  /// conditions, and stays above the keyboard.
  Widget _searchBar(BuildContext context) {
    final scheme = context.colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 8, 16, 8 + context.bottomInset),
      child: DecoratedBox(
        decoration: ShapeDecoration(color: scheme.surfaceContainerHigh, shape: const StadiumBorder()),
        child: Padding(
          padding: const EdgeInsets.only(left: 16, right: 4),
          child: Row(children: [
            GlyphIcon(AppGlyphs.search, size: 20, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const Key('route-rule-search'),
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: context.tr('Search'),
                  border: const NoInputBorder(),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onChanged: (value) => setState(() => _query = value),
              ),
            ),
            if (_query.isNotEmpty)
              IconButton(
                tooltip: context.tr('Clear search'),
                icon: const GlyphIcon(AppGlyphs.close, size: 18),
                onPressed: () {
                  _searchController.clear();
                  setState(() => _query = '');
                },
              ),
          ]),
        ),
      ),
    );
  }

  /// One rule card, FlClash's row: the type over its value on the left, the target
  /// in its colour on the right, and the selection circle at the edge. A long press
  /// anywhere drags it; tapping opens the editor unless a selection is active.
  ///
  /// [position] is the row's place in the group it belongs to: the cards are one
  /// contiguous surface whose first and last rows carry the rounded corners
  /// (`ItemPositionProvider` is what `DecorationListItem` reads; without it every
  /// corner is square).
  Widget _ruleCard(BuildContext context, Json rule, int index, {ItemPosition? position}) {
    final enabled = rule['disabled'] != true;
    final action = rule['action']?.toString() ?? 'route';
    final outbound = (rule['outbound_id'] as num?)?.toInt() ?? 0;
    final targetColor = routeActionColor(context, action, outbound);
    const mono = TextStyle(fontFamily: 'JetBrainsMono');
    return ItemPositionProvider(
      position: position ?? ItemPosition.get(index, _rules.length),
      child: Opacity(
        opacity: enabled ? 1 : .55,
        child: SelectedDecorationListItem(
          isSelected: _selected.contains(rule),
          isEditing: _selected.isNotEmpty,
          onSelected: () => _toggleSelected(rule),
          onPressed: () {
            if (!_busy) _editRule(_rules.indexOf(rule));
          },
          title: Row(children: [
            Expanded(
              child: Text(
                ruleTypeLabel(rule),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: mono.copyWith(fontSize: 15, fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              ruleTargetLabel(rule),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: mono.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: targetColor),
            ),
          ]),
          subtitle: Text(
            '${ruleName(rule, index)}${enabled ? '' : ' · ${context.tr('Disabled')}'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: mono.copyWith(fontSize: 12, color: context.listSubtitleStyle.color),
          ),
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
