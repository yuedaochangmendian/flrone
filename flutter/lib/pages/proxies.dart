import 'dart:async';

import '../widgets.dart';
import '../components/data_subscription.dart';
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
    with WidgetsBindingObserver {
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
  bool _nodesVisible = false;
  bool _pageActive = false;
  // One restore attempt per configuration entry; reset when the active id
  // changes so switching away and back replays the remembered node.
  String? _restoredFor;
  // The target the last restore was scheduled for, so a normal rebuild does
  // not allocate another post-frame closure and re-enter the memory check.
  String? _restoreScheduledFor;

  String _profileKey(BoxController box) => box.remote
      ? 'remote:${box.dashboard['remote']}'
      : 'local:${box.selectedProfileId}';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _syncNodesVisible() {
    final box = _box;
    if (box == null) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final visible =
        _pageActive &&
        (lifecycle == null || lifecycle == AppLifecycleState.resumed);
    if (visible == _nodesVisible) return;
    _nodesVisible = visible;
    box.setGroupsVisible(this, visible);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final box = ref.read(boxControllerProvider);
    if (!identical(_box, box)) {
      _box?.setGroupsVisible(this, false);
      _box = box;
      _nodesVisible = false;
    }
    // PageSwitcher keeps every tab mounted so its state survives a switch. The
    // node rows are still the largest payload the bridge carries, so this page
    // may only ask for them while it is actually the visible tab: mounting the
    // hidden tab at startup used to pull the whole catalog into the first
    // frame (and into every later catalog revision).
    _pageActive =
        PageActivityScope.isActiveOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _syncNodesVisible();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncNodesVisible();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_nodesVisible) _box?.setGroupsVisible(this, false);
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
    // single node needs far less. Clamped: 500 nodes × the floor used to
    // produce a ~67-minute timer that kept the button disabled the whole time.
    final perNode = (box.settings['urlTestTimeoutMs'] as num?)?.toInt() ?? 0;
    final budgetMs = (perNode > 0 ? perNode : 8000) * ids.length + 15000;
    final timeout = Duration(
      milliseconds: budgetMs.clamp(15000, const Duration(minutes: 5).inMilliseconds),
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
    var selected = false;
    try {
      selected = await box.groupSelect(
        group['tag'],
        node['tag'],
        nodeId: nodeId,
      );
    } finally {
      // The optimistic overlay must not outlive its call: a throw used to leave
      // the row showing a selection the catalog never confirmed.
      if (!selected && mounted && nodeId != null) {
        setState(() => _optimistic.remove(groupTag));
      }
    }
    if (!selected) return;
    // This tap IS the configuration's remembered choice: mark the memory
    // restored for the configuration the node belongs to, so the next build
    // does not re-issue the same select.
    _restoredFor = _memoryKey(box, group);
    await _rememberSelection(box, group, node);
    if (box.preferences['closeConnectionsOnSelect'] == true) {
      await box.connectionsCloseAll();
    }
  }

  /// The memory key for a node picked in [group]: the group's own
  /// configuration, which is the node's one — not whatever is selected. The
  /// tabbed page could show another configuration's group, and filing by the
  /// selection stored the choice in the wrong profile.
  String _memoryKey(BoxController box, Json group) {
    if (box.remote) return _profileKey(box);
    final groupId = (group['id'] as num?)?.toInt() ?? 0;
    return 'local:${groupId > 0 ? groupId : box.selectedProfileId}';
  }

  /// Only a real user tap records a choice. The native first-member fallback
  /// that runs on a configuration switch must never overwrite this memory.
  Future<void> _rememberSelection(BoxController box, Json group, Json node) async {
    final key = _memoryKey(box, group);
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

  /// Filtered/sorted node rows for the visible configuration's group, reused
  /// across builds.
  ///
  /// [build] runs on every state and testSession event (about 1 Hz plus the
  /// 400 ms session relay), so without this the whole node set was filtered,
  /// lowercased and sorted per frame. The key is the raw `items` value by
  /// identity: `groupsWire` rebuilds that list only when the catalog revision
  /// moves, so an unchanged list means the same rows came in.
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
    final matched = rows(source)
        .where((node) => words.every(node['tag'].toString().toLowerCase().contains))
        .toList();
    // Hiding timed-out nodes must never turn a healthy list into the empty
    // screen: when every matched node failed, show them with their -1 delays
    // instead of pretending the configuration or the search matched nothing.
    var nodes = hide
        ? matched
            .where((node) =>
                !((node['testedAt'] as num? ?? 0) > 0 && (node['delay'] as num? ?? 0) <= 0))
            .toList()
        : matched;
    if (nodes.isEmpty && matched.isNotEmpty) nodes = matched;
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

  /// The pages below the bar: the empty state, or the selected configuration's
  /// nodes. Split out so [build] can stack the delay-test button over it.
  ///
  /// One screen, one configuration: the Proxies screen draws exactly the
  /// profile the Profiles screen has selected. There are no group tabs and no
  /// group header — the group IS the configuration the user picked, so
  /// repeating its name here was the "not one-to-one" the screen kept showing.
  /// The Profiles screen's mode switch (profiles ⇄ single nodes) changes the
  /// selection, so this screen follows it without a second source of truth.
  Widget _proxiesBody(List<Json> groups, bool list, BoxController box) {
    final noSelection = !box.remote && box.selectedProfileId <= 0;
    // The dashboard lane can arrive before the bulk groups lane. In that gap the
    // new selectedProfileId matches no group yet; showing "No proxy groups"
    // read as an empty configuration. Treat it as loading instead.
    final selectionPending = !noSelection &&
        box.selectedProfileId > 0 &&
        (!box.groupsReceived || box.groups.isNotEmpty);
    final profileKey = box.remote
        ? 'remote:${box.dashboard['remote']}'
        : 'local:${box.selectedProfileId}';
    return groups.isEmpty
      ? NullStatus(
          label: context.tr(
            noSelection
                ? 'No profile selected'
                : selectionPending
                    ? 'Loading'
                    : box.running
                        ? 'No proxy groups in this configuration'
                        : 'Start the service to view proxy groups',
          ),
          description: noSelection
              ? context.tr('Pick a profile on the Profiles page to show its nodes here.')
              : null,
          illustration: NullStatusIllustration.proxies,
        )
      : list
      ? ProxyListView(
          key: ValueKey(profileKey),
          profileKey: profileKey,
          groups: [
            for (final group in groups) ProxyListGroup(group, _nodes(group)),
          ],
          cardBuilder: _card,
          onTest: _testGroup,
        )
      : Padding(
          padding: EdgeInsets.only(top: context.contentTopPadding),
          child: _grid(groups.first),
        );
  }

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
      // The counts-only payload carries nodeCount but no rows: that is a frame
      // before the bulk groups event, not an empty configuration or a search
      // miss. A genuine empty group and a filtered-out search read differently.
      final pending = (group['nodeCount'] as num? ?? 0) > 0 &&
          rows(group['items']).isEmpty;
      return NullStatus(
        label: context.tr(
          pending
              ? 'Loading'
              : _query.trim().isNotEmpty
                  ? 'No results'
                  : 'No nodes',
        ),
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
    // One screen, one configuration. The Proxies screen draws exactly the
    // profile the Profiles screen has selected. The authoritative pair is the
    // group whose id is the selected profile; the selection marker is only the
    // fallback for a catalog that has not carried ids yet. (Preferring the
    // marker first showed the previous configuration for one generation after
    // every switch: the old group keeps its marker until its event arrives.)
    // The single-node container is a configuration like any other, so the
    // Profiles screen's mode switch (profiles ⇄ single nodes) moves this
    // screen by moving the selection.
    final allGroups = box.groups;
    final selectedId = box.selectedProfileId;
    final carriesIds = allGroups.any((group) => group['id'] != null);
    Json? target;
    if (selectedId > 0) {
      for (final group in allGroups) {
        if ((group['id'] as num?)?.toInt() == selectedId) {
          target = group;
          break;
        }
      }
      // A counts-only payload (no ids at all) cannot be matched; its selection
      // marker is then the only link we have. When the ids ARE there and none
      // matches, the event predates the selection: the empty state is the
      // honest answer, not the previous configuration's leftover marker.
      if (target == null && !carriesIds) {
        for (final group in allGroups) {
          if (((group['selectedId'] as num?)?.toInt() ?? 0) > 0) {
            target = group;
            break;
          }
        }
      }
    }
    // No selection, or a catalog event that has not caught up with the
    // selection yet: nothing to show. The stored rows are leftovers from the
    // previous configuration, and listing them read as if one were active.
    final noSelection = !box.remote && selectedId <= 0;
    final groups = noSelection || target == null
        ? const <Json>[]
        : <Json>[target];
    if (groups.isNotEmpty && groups.first['tag'] != _currentGroup) {
      _currentGroup = groups.first['tag'] as String?;
    }
    // Schedule the restore only when the page's target changes. This used to
    // run on every build (1 Hz state plus the test-session relay), allocating a
    // closure and re-entering the memory check each frame.
    final restoreKey = groups.isEmpty
        ? null
        : '${_profileKey(box)}|${groups.first['tag']}';
    if (restoreKey != null && restoreKey != _restoreScheduledFor) {
      _restoreScheduledFor = restoreKey;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_maybeRestore(box, groups));
      });
    }
    final liveTags = groups.map((group) => group['tag'].toString()).toSet();
    _selectedOffsets.removeWhere((tag, _) => !liveTags.contains(tag));
    if (_scrolls.keys.any((tag) => !liveTags.contains(tag))) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Retire against the page's live groups, not the whole catalog: a
        // configuration that is merely not selected still exists in
        // `box.groups`, so the old predicate never disposed its controller.
        for (final tag
            in _scrolls.keys.where((tag) => !liveTags.contains(tag)).toList()) {
          _scrolls.remove(tag)?.dispose();
        }
      });
    }
    final list = box.preferences['proxyLayout'] == 'List';
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
            // Both layouts get the group's test button: it used to live in the
            // group header, which the one-configuration page no longer draws.
            if (groups.isNotEmpty) _delayTestFab(),
          ],
        ),
      ),
    );
  }
}
