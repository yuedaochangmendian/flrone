import 'dart:async';

import '../widgets.dart';
import '../components/data_subscription.dart';
import '../components/group_tabs.dart';
import '../components/proxy_card.dart';
import '../components/proxy_list.dart';
import '../components/proxy_motion.dart';
import '../components/proxies_setting.dart';
import 'test_panel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

class ProxiesPage extends ConsumerStatefulWidget {
  const ProxiesPage({super.key});
  @override
  ConsumerState<ProxiesPage> createState() => _ProxiesPageState();
}

/// Preferences key for the node chosen per configuration. The native side
/// keeps one global selected proxy, so switching a configuration selects its
/// first member and forgets what the previous one used. Remember the choice
/// here and replay it when that configuration becomes active again.
const _proxySelectedKey = 'proxySelected';

class _ProxiesPageState extends ConsumerState<ProxiesPage>
    with TickerProviderStateMixin {
  String _query = '';
  final _testing = <int>{};
  final _testLabels = <String>{};
  // FlClash runs a batch as a queue: groups waiting their turn show a clock,
  // the one under test a spinner, and finished groups their delays.
  final _queued = <String>{};
  Json _session = const {};

  /// The session's per-node rows, indexed by node id once per [build] (see the note there).
  Map<int, Json> _sessionRowsById = const {};
  final _scrolls = <String, ScrollController>{};
  final _selectedOffsets = <String, double>{};

  /// groupTag -> nodeId: the tap's optimistic pick (FlClash writes its
  /// selection map on the tap frame instead of waiting for the rebuild),
  /// dropped when the catalog event confirms it or the action fails.
  final _optimistic = <String, int>{};
  String? _currentGroup;
  BoxController? _box;
  // One restore attempt per configuration entry; reset when the active id
  // changes so switching away and back replays the remembered node.
  String? _restoredFor;

  String _profileKey(BoxController box) => box.remote
      ? 'remote:${box.dashboard['remote']}'
      : 'local:${box.selectedProfileId}';

  /// Drives the group tab strip and its pages. Rebuilt when the group list
  /// changes, because prism's controller owns a fixed length.
  TabController? _tabs;
  String _tabsSignature = '';

  TabController _tabsFor(List<Json> groups) {
    final signature = groups
        .map((group) => group['tag'].toString())
        .join('\u0000');
    if (_tabs == null || signature != _tabsSignature) {
      _tabs?.dispose();
      _tabsSignature = signature;
      _tabs = TabController(
        length: groups.length,
        initialIndex: groups
            .indexWhere((group) => group['tag'] == _currentGroup)
            .clamp(0, groups.length - 1),
        vsync: this,
      );
    }
    return _tabs!;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_box == null) {
      _box = ref.read(boxControllerProvider);
      // The node rows are the largest payload the bridge carries, so they only travel while this
      // screen is open; every other screen renders the group counts.
      _box!.setGroupsVisible(this, true);
    }
  }

  @override
  void dispose() {
    _box?.setGroupsVisible(this, false);
    _tabs?.dispose();
    for (final scroll in _scrolls.values) {
      scroll.dispose();
    }
    super.dispose();
  }

  Future<void> _locate() async {
    final scroll = _scrolls[_currentGroup],
        offset = _selectedOffsets[_currentGroup];
    if (scroll == null || !scroll.hasClients || offset == null) return;
    await scroll.animateTo(
      offset.clamp(
        scroll.position.minScrollExtent,
        scroll.position.maxScrollExtent,
      ),
      duration: context.motionDuration(commonDuration),
      curve: proxyMotionCurve,
    );
  }

  // Testing and selecting both work with the service stopped: a test runs over its own instance of the
  // profile, and a selection is a stored preference the next start reads, so neither waits for the VPN.
  // FlClash gives the group button the filtered/visible rows and the node button exactly one row, and
  // dedupes the targets: one node measured twice under two aliases is one measurement.
  Future<void> _test(
    String tag, {
    List<int>? profileIds,
    bool groupTest = false,
  }) async {
    final testingGroup = groupTest || profileIds == null;
    final ids = (profileIds ?? _allIds(tag)).toSet().toList();
    if (testingGroup && _testLabels.contains(tag)) return;
    if (!testingGroup && profileIds.any(_testing.contains)) return;
    // Nothing to measure: every row is REJECT/PASS/a selector, or the search and the
    // hide-timed-out filter left none. Returning silently left the button looking broken.
    if (ids.isEmpty) {
      ref.read(boxControllerProvider).showMessage(context.tr('No testable nodes here'));
      return;
    }
    if (_queued.contains(tag)) return;
    // One group at a time, as FlClash's coordinator does: a second group's run
    // waits its turn instead of sharing the core with the first.
    if (testingGroup && _testLabels.isNotEmpty) return;
    final box = ref.read(boxControllerProvider);
    // The wait follows the configured per-node timeout (Testing settings →
    // Test timeout), plus slack for the batch's own overhead. A group of 200
    // nodes at the 8 s floor needs far more than the old flat 60 s, and a
    // single node needs far less.
    final perNode = (box.settings['urlTestTimeoutMs'] as num?)?.toInt() ?? 0;
    final timeout = Duration(
      milliseconds: (perNode > 0 ? perNode : 8000) * ids.length + 15000,
    );
    setState(() {
      _testing.addAll(ids);
      if (testingGroup) _testLabels.add(tag);
    });
    try {
      // A false answer means the host refused or ran out of budget — most often because
      // another session was still winding down. It used to be dropped on the floor: the
      // spinner cleared and nothing had been measured, which reads as "the button does
      // nothing".
      final ran = await box.groupTest(tag, profileIds: profileIds).timeout(timeout);
      if (!ran && mounted) box.showMessage(context.tr('The test did not finish'));
    } catch (error) {
      if (mounted) box.report(error);
    } finally {
      if (mounted) {
        setState(() {
          _testing.removeAll(ids);
          if (testingGroup) _testLabels.remove(tag);
        });
      }
    }
  }

  /// A node the delay test skips: FlClash's `_isNonTestableProxy` — the
  /// built-in REJECT/PASS rows and anything the core resolves itself. Testing
  /// one measures nothing and would only paint a timeout on a working config.
  bool _testable(Json node) {
    final tag = node['tag'].toString().toUpperCase();
    if (tag == 'REJECT' || tag == 'REJECT-DROP' || tag == 'PASS') return false;
    return node['type'].toString().toUpperCase() != 'REMATCH';
  }

  List<int> _nodeIds(Iterable<Json> nodes) => [
    for (final node in nodes)
      if (_testable(node))
        if ((node['id'] as num?)?.toInt() case final int id) id,
  ];

  List<int> _visibleIds(String tag) {
    final group = ref.read(boxControllerProvider).groups
        .where((item) => item['tag'].toString() == tag)
        .firstOrNull;
    return group == null ? const [] : _nodeIds(_nodes(group));
  }

  List<int> _allIds(String tag) {
    final group = ref.read(boxControllerProvider).groups
        .where((item) => item['tag'].toString() == tag)
        .firstOrNull;
    return group == null ? const [] : _nodeIds(rows(group['items']));
  }

  Future<void> _testGroup(String tag) =>
      _test(tag, profileIds: _visibleIds(tag), groupTest: true);

  Future<void> _select(Json group, Json node) async {
    final box = ref.read(boxControllerProvider);
    if (group['selectable'] != true) return;
    final selectedId = (group['selectedId'] as num?)?.toInt();
    final nodeId = (node['id'] as num?)?.toInt();
    if (selectedId != null && nodeId != null
        ? selectedId == nodeId
        : node['tag'] == group['selected']) {
      return;
    }
    final groupTag = group['tag'].toString();
    // Optimistic pick on the tap frame: the row flips now instead of after the
    // full core rebuild (FlClash's changeProxy writes its map synchronously).
    if (nodeId != null) {
      setState(() => _optimistic[groupTag] = nodeId);
    }
    if (await box.groupSelect(group['tag'], node['tag'], nodeId: nodeId)) {
      await _rememberSelection(box, group, node);
      if (box.preferences['closeConnectionsOnSelect'] == true) {
        await box.connectionsCloseAll();
      }
    } else if (mounted) {
      // Roll the row back to the catalog's marker.
      setState(() => _optimistic.remove(groupTag));
    }
  }

  /// Only a real user tap records a choice. The native first-member fallback
  /// that runs on a configuration switch must never overwrite this memory.
  Future<void> _rememberSelection(BoxController box, Json group, Json node) async {
    final key = _profileKey(box);
    final saved = json(box.preferences[_proxySelectedKey]);
    saved[key] = {
      'group': group['tag'],
      'id': node['id'],
      'tag': node['tag'],
    };
    while (saved.length > 64) {
      saved.remove(saved.keys.first);
    }
    await box.setPreference(_proxySelectedKey, saved);
  }

  /// Re-issues the remembered node selection for the configuration that just
  /// became active. The host has a single global slot and selects the target
  /// group's first member on a switch, so without this an A -> B -> A trip
  /// forgets the node A was using.
  Future<void> _maybeRestore(
    BoxController box,
    List<Json> groups,
  ) async {
    if (box.remote || box.selectedProfileId <= 0 || box.transitioning) return;
    final key = _profileKey(box);
    if (_restoredFor == key) return;
    final memory = json(box.preferences[_proxySelectedKey])[key];
    if (memory is! Map) {
      // Nothing remembered for this configuration; do not retry on every frame.
      _restoredFor = key;
      return;
    }
    final groupTag = memory['group'];
    final group = groups
        .cast<Json?>()
        .firstWhere(
          (group) => group?['tag'] == groupTag && group?['selectable'] == true,
          orElse: () => null,
        );
    // The group itself may arrive in a later catalog generation (counts-only
    // first). Leave the attempt open until its rows are present.
    if (group == null) return;
    // `groupSelect` reports success even when the native side no-ops, so the
    // existence guard has to live here. Prefer the id, then the tag — the same
    // precedence the native resolver uses.
    final nodes = rows(group['items']);
    final rememberedId = (memory['id'] as num?)?.toInt();
    final rememberedTag = memory['tag'];
    final node = nodes.cast<Json?>().firstWhere(
          (node) => rememberedId != null &&
              (node?['id'] as num?)?.toInt() == rememberedId,
          orElse: () => nodes.cast<Json?>().firstWhere(
                (node) => node?['tag'] == rememberedTag,
                orElse: () => null,
              ),
        );
    if (node == null) {
      // A subscription refresh or rename removed this node; nothing to restore.
      _restoredFor = key;
      return;
    }
    final selectedId = (group['selectedId'] as num?)?.toInt();
    final nodeId = (node['id'] as num?)?.toInt();
    if (selectedId != null && nodeId != null
        ? selectedId == nodeId
        : node['tag'] == group['selected']) {
      _restoredFor = key; // already live; avoid an extra core reload
      return;
    }
    _restoredFor = key;
    if (await box.groupSelect(group['tag'], node['tag'], nodeId: nodeId)) {
      if (mounted) setState(() => _currentGroup = group['tag'] as String?);
    }
  }

  /// Filtered/sorted node rows per group, reused across builds.
  ///
  /// [build] runs on every state and testSession event (about 1 Hz plus the 400 ms session
  /// relay), and the tab style constructs *every* group's grid, not just the visible one — so
  /// without this the whole node set of every group was filtered, lowercased and sorted per
  /// frame. The key is the raw `items` value by identity: `groupsWire` rebuilds that list only
  /// when the catalog revision moves, so an unchanged list means the same rows came in.
  /// (`rows()` allocates a new list each call, so comparing *its* result would never hit.)
  final _nodesCache = <String, ({Object? source, String query, String sort, bool hide, List<Json> rows})>{};

  List<Json> _nodes(Json group) {
    final tag = group['tag'].toString();
    final source = group['items'];
    final sort = ref.read(boxControllerProvider).preferences['proxySort'] as String? ?? 'Default';
    final hide = ref.read(boxControllerProvider).preferences['hideTimeoutProxies'] == true;
    final cached = _nodesCache[tag];
    if (cached != null &&
        identical(cached.source, source) &&
        cached.query == _query &&
        cached.sort == sort &&
        cached.hide == hide) {
      return cached.rows;
    }
    final words = _query.toLowerCase().trim().split(RegExp(r'\s+'));
    final nodes = rows(source)
        .where(
          (node) =>
              words.every(node['tag'].toString().toLowerCase().contains) &&
              !(hide &&
                  (node['testedAt'] as num? ?? 0) > 0 &&
                  (node['delay'] as num? ?? 0) <= 0),
        )
        .toList();
    if (sort == 'Name') {
      nodes.sort((a, b) => a['tag'].toString().compareTo(b['tag'].toString()));
    }
    if (sort == 'Latency') {
      int delay(Json node) => (node['delay'] as num? ?? 0) > 0
          ? (node['delay'] as num).toInt()
          : 0x7fffffff;
      nodes.sort((a, b) => delay(a).compareTo(delay(b)));
    }
    // Replaced (not merged) so a group that disappears cannot keep a stale entry alive.
    _nodesCache[tag] = (source: source, query: _query, sort: sort, hide: hide, rows: nodes);
    return nodes;
  }

  /// The pages below the bar: the empty state, the list style or the tab
  /// style. Split out so [build] can stack the delay-test button over it.
  Widget _proxiesBody(List<Json> groups, bool list, BoxController box) =>
      groups.isEmpty
      ? NullStatus(
          label: context.tr(
            box.running
                ? 'No proxy groups in this configuration'
                : 'Start the service to view proxy groups',
          ),
          illustration: NullStatusIllustration.proxies,
        )
      : list
      ? ProxyListView(
          key: ValueKey(
            box.remote
                ? 'remote:${box.dashboard['remote']}'
                : 'local:${box.selectedProfileId}',
          ),
          profileKey: box.remote
              ? 'remote:${box.dashboard['remote']}'
              : 'local:${box.selectedProfileId}',
          groups: [
            for (final group in groups) ProxyListGroup(group, _nodes(group)),
          ],
          testing: _testLabels,
          queued: Set.of(_queued),
          cardBuilder: _card,
          onTest: _testGroup,
        )
      : Builder(
          builder: (context) {
            final tabs = _tabsFor(groups);
            return Padding(
              padding: EdgeInsets.only(top: context.contentTopPadding),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: GroupTabs(
                      controller: tabs,
                      groups: groups,
                      onSelected: (index) {
                        if (mounted) {
                          setState(
                            () =>
                                _currentGroup = groups[index]['tag'] as String,
                          );
                        }
                      },
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      controller: tabs,
                      children: [
                        for (final group in groups)
                          Column(
                            children: [
                              if (group['selectable'] != true)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Text(
                                    context.tr('Automatic selection'),
                                    style: context.listCaptionStyle,
                                  ),
                                ),
                              Expanded(child: _grid(group)),
                            ],
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        );

  /// FlClash's DelayTestButton: the current group's latency run, over the list.
  ///
  /// A Prism press region on a primary circular fill is the app's equivalent of
  /// the small FAB it replaces: same position, tooltip, 48 dp hit area (matching
  /// Material's kMinInteractiveDimension) and a disabled state while a test is
  /// in flight, with Prism's [ActivityIndicator] as the spinner.
  Widget _delayTestFab() {
    final tag = _currentGroup;
    if (tag == null) return const SizedBox.shrink();
    final testing = _testLabels.contains(tag);
    final scheme = context.colorScheme;
    final label = context.tr('Test latency');
    return Positioned(
      right: 16,
      bottom: 16 + context.bottomInset,
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          enabled: !testing,
          label: label,
          child: ElasticPress(
            enabled: !testing,
            child: PressRegion(
              onTap: testing ? null : () => _testGroup(tag),
              shape: AppShape.full,
              fill: testing
                  ? scheme.onSurface.withValues(alpha: .12)
                  : scheme.primary,
              overlay: PressRegion.pressOverlay,
              child: SizedBox.square(
                dimension: 48,
                child: Center(
                  child: testing
                      ? ActivityIndicator(size: 18, semanticLabel: label)
                      : GlyphIcon(AppGlyphs.bolt, color: scheme.onPrimary),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context, Json group, Json node) {
    final groupTag = group['tag'].toString(), nodeTag = node['tag'].toString();
    final id = (node['id'] as num?)?.toInt();
    final groupTest =
        _testLabels.contains(groupTag) || _queued.contains(groupTag);
    // FlClash's per-node animation, from whichever signal knows the node is
    // being measured right now:
    //   * a node tap marks exactly that id in `_testing` and owns the card until
    //     `groups.test` returns;
    //   * a group run pushes the shared session's rows, and the row's own phase
    //     decides (TESTING spins, QUEUED shows the clock, DONE clears);
    //   * a group run whose rows have not arrived yet is all queued.
    //
    // `_testing` is only trusted when the card is not part of a group run:
    // `_test` marks every id of a batch in it so the action can be awaited once,
    // and reading that as "this node is being measured" painted the whole group
    // as running and made the session rows unreachable. The rows carry the real
    // per-node progress, so a group run defers to them and the batch set only
    // keeps a single node's own tap spinning.
    final individualTest = !groupTest && id != null && _testing.contains(id);
    final sessionRow = groupTest && _session['running'] == true
        ? _sessionRowsById[id]
        : null;
    final phase = individualTest
        ? ProxyTestPhase.running
        : switch (sessionRow?['phase']) {
            'TESTING' => ProxyTestPhase.running,
            'QUEUED' => ProxyTestPhase.queued,
            'DONE' => ProxyTestPhase.idle,
            // A group test starts as a queue, then the session's row phases take over
            // one card at a time, matching FlClash's per-node animation.
            _ when groupTest => ProxyTestPhase.queued,
            _ => ProxyTestPhase.idle,
          };
    final pending = _optimistic[groupTag];
    if (pending != null && id != null) {
      // Catalog confirmation retires the overlay; both sides agree, so the
      // removal itself is not a visual change.
      if ((group['selectedId'] as num?)?.toInt() == pending) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _optimistic.remove(groupTag));
        });
      }
    }
    return ProxyNodeCard(
      group: group,
      node: node,
      phase: phase,
      // The tap's optimistic pick rides over the catalog until the catalog
      // event confirms it.
      selectedOverride: pending == null || id == null ? null : pending == id,
      onSelect: () => _select(group, node),
      onTest: () {
        if (id != null) _test(nodeTag, profileIds: [id]);
      },
    );
  }

  Widget _grid(Json group) {
    final nodes = _nodes(group);
    if (nodes.isEmpty) {
      _selectedOffsets.remove(group['tag']);
      return NullStatus(
        label: context.tr('No results'),
        illustration: NullStatusIllustration.proxies,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = proxyColumns(
          constraints.maxWidth - 32,
          ref.read(boxControllerProvider).preferences,
        );
        final metrics = ProxyCardMetrics.of(context, ref.read(boxControllerProvider).preferences);
        final selectedId = (group['selectedId'] as num?)?.toInt();
        final selected = nodes.indexWhere(
          (node) => selectedId != null
              ? (node['id'] as num?)?.toInt() == selectedId
              : node['tag'] == group['selected'],
        );
        if (selected < 0) {
          _selectedOffsets.remove(group['tag']);
        } else {
          _selectedOffsets[group['tag'].toString()] =
              (selected ~/ columns) * metrics.rowExtent;
        }
        return GridView.builder(
          key: PageStorageKey('proxy-grid:${group['tag']}'),
          controller: _scrolls.putIfAbsent(
            group['tag'].toString(),
            () => sheetScrollController(context),
          ),
          // The latency FAB floats over the grid's bottom-right corner. Leave
          // a full button plus a gap so the last row can scroll clear of it.
          padding: EdgeInsets.fromLTRB(16, 0, 16, 72 + context.bottomInset),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            mainAxisExtent: metrics.extent,
          ),
          itemCount: nodes.length,
          itemBuilder: (context, index) => _card(context, group, nodes[index]),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final box = ref.watchBoxState();
    _session = ref.watch(testSessionProvider);
    // Indexed once per build instead of per card: `_card` ran `rows(_session['rows'])` and a
    // linear scan for *every* visible node, so a group run over 500 nodes cost
    // O(cards × rows) allocations and comparisons per frame at the 400 ms relay rate.
    _sessionRowsById = {
      for (final row in rows(_session['rows']))
        if ((row['id'] as num?)?.toInt() case final int id) id: row,
    };
    // The screen follows the configuration selection: whichever profile is
    // selected, its nodes are what shows here. The selection marker rides in
    // the same `groups` event as the rows (`selectedId` is non-zero only on the
    // group holding the selected member), so derive the filter from that event
    // itself. `dashboard.selectedProfileId` is a separate event that can still
    // be from the previous generation when this frame builds; using it as the
    // primary filter is what made the two screens disagree intermittently.
    final selectedId = box.selectedProfileId;
    final allGroups = box.groups;
    final owning = allGroups
        .where((group) => ((group['selectedId'] as num?)?.toInt() ?? 0) > 0)
        .toList();
    final carriesIds = allGroups.any((group) => group['id'] != null);
    final byId = selectedId > 0
        ? allGroups
            .where((group) => (group['id'] as num?)?.toInt() == selectedId)
            .toList()
        : const <Json>[];
    // Prefer the marker that rides in the same event as the rows. When the
    // catalog does carry ids but none belongs to the just-selected
    // configuration, this is a stale generation: show the empty state rather
    // than silently widening to the previous configuration's groups. A
    // counts-only payload (no ids at all) cannot be filtered, so keep all of
    // its groups until the full catalog arrives.
    final groups = owning.isNotEmpty
        ? owning
        : byId.isNotEmpty
            ? byId
            : !carriesIds || selectedId <= 0
                ? allGroups
                : const <Json>[];
    // Restore outside build(): a channel call here would run during the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_maybeRestore(box, groups));
    });
    final liveTags = groups.map((group) => group['tag'].toString()).toSet();
    _selectedOffsets.removeWhere((tag, _) => !liveTags.contains(tag));
    if (_scrolls.keys.any((tag) => !liveTags.contains(tag))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = box.groups
            .map((group) => group['tag'].toString())
            .toSet();
        for (final tag
            in _scrolls.keys.where((tag) => !current.contains(tag)).toList()) {
          _scrolls.remove(tag)?.dispose();
        }
      });
    }
    final list = box.preferences['proxyLayout'] == 'List';
    if (!groups.any((group) => group['tag'] == _currentGroup)) {
      // Land on a group that has nodes. Otherwise an unselected configuration's empty group comes
      // first and the page reads as if the import brought nothing. `nodeCount` carries this before
      // the node rows arrive, so the choice does not depend on them.
      final withNodes = groups.where(
        (group) => ((group['nodeCount'] as num?)?.toInt() ?? 0) > 0,
      );
      _currentGroup =
          (withNodes.isNotEmpty ? withNodes.first : groups.firstOrNull)?['tag']
              as String?;
    }
    return BoxDataSubscription(
      data: BoxData.testSession,
      child: Scaffold(
        title: context.tr('Proxies'),
        searchState: AppBarSearchState(
          onSearch: (query) => setState(() => _query = query),
        ),
        iconActions: [
          if (!list)
            IconButtonData(
              glyph: AppGlyphs.locate,
              tooltip: context.tr('Scroll to selected'),
              onPressed: groups.isEmpty ? null : _locate,
            ),
        ],
        menuItems: [
          PopupMenuItem(
            glyph: AppGlyphs.sliders,
            label: context.tr('Proxies settings'),
            onPressed: () => showProxiesSetting(context),
          ),
          PopupMenuItem(
            glyph: AppGlyphs.bolt,
            label: context.tr('Test all'),
            onPressed: () async {
              if (_testing.isNotEmpty || _queued.isNotEmpty) return;
              final tags = groups
                  .map((group) => group['tag'].toString())
                  .toList(growable: false);
              setState(() => _queued.addAll(tags));
              try {
                for (final tag in tags) {
                  if (!mounted) return;
                  setState(() => _queued.remove(tag));
                  await _test(tag, profileIds: _allIds(tag), groupTest: true);
                }
              } finally {
                if (mounted) setState(() => _queued.clear());
              }
            },
          ),
          PopupMenuItem(
            glyph: AppGlyphs.dashboard,
            label: context.tr('Test panel'),
            onPressed: () => openForm(context, const TestPanelPage()),
          ),
        ],
        body: Stack(
          children: [
            Positioned.fill(child: _proxiesBody(groups, list, box)),
            if (groups.isNotEmpty && !list) _delayTestFab(),
          ],
        ),
      ),
    );
  }
}
