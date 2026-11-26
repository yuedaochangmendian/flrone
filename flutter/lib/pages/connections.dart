import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets.dart';
import '../providers/box_providers.dart';
import '../components/record.dart';

/// Rows add keyword chips by label; the search key is the package name (it appears in the
/// path the haystack indexes) while the chip shows the friendlier app label.
typedef FilterAdder = void Function(String word, {String? label});

/// The connections payload carries `process` as `{path: ...}`; tolerate a bare path too.
String? _processPath(Object? process) =>
    process is Map ? process['path']?.toString() : process?.toString();

/// The page is branded Requests in FlClash's v0.9.5 redesign. Keep the old class
/// name (and route) alive: the typedef resolves to the very same type, so existing
/// `ConnectionsPage` finds, routes and navigations keep working unchanged.
typedef RequestsPage = ConnectionsPage;

/// The user-facing status selector. All keeps the whole feed, Active the still-open
/// requests, Failed the closed ones. The current feed only stamps closed rows, so
/// Failed equals closed; any reason the payload carries is decoration.
enum RequestStatus { all, active, failed }

/// Candidate keys a host may use to explain why a request ended. The current core
/// carries none of them — this is the seam for a future backend change, and rows
/// that do carry one keep it on the card and in the detail.
const _reasonKeys = ['error', 'reason', 'closeReason', 'failedReason', 'errorMessage'];

/// Why a closed request failed, from the payload itself. Reject/drop rules and
/// outbounds are the one failure signal the current Clash API feed already has.
String? _failureReason(Json c) {
  for (final key in _reasonKeys) {
    final value = c[key]?.toString().trim();
    if (value != null && value.isNotEmpty) return value;
  }
  final rule = (c['rule'] as String? ?? '').trim().toLowerCase();
  final outbound = (c['outbound'] as String? ?? '').trim().toLowerCase();
  if (rule == 'reject' || rule == 'reject-drop' || rule.startsWith('reject(') ||
      outbound == 'reject' || outbound == 'drop' || outbound == 'block') {
    return rule.isNotEmpty ? rule : outbound;
  }
  return null;
}

bool _isClosed(Json c) => (c['closedAt'] as num? ?? 0) > 0;

/// The feed has no success/reason signal: a row the core stopped reporting is
/// stamped closed, so Failed = closed. The reason is decoration, shown when a
/// host supplies one; absence of a reason does not make the row Active again.
bool _isFailed(Json c) => _isClosed(c);

/// A closed request's lifetime, formatted the way FlClash shows tracker durations.
/// Active requests have no end stamp yet, so they show nothing rather than a
/// wall-clock estimate.
String _durationText(Json c) {
  if (!_isClosed(c)) return '';
  final start = (c['createdAt'] as num? ?? 0).toInt();
  final end = (c['closedAt'] as num? ?? 0).toInt();
  if (start <= 0 || end <= start) return '—';
  final seconds = (end - start) ~/ 1000;
  if (seconds < 60) return '$seconds s';
  final minutes = seconds / 60;
  if (minutes < 60) {
    return '${minutes < 10 ? minutes.toStringAsFixed(1) : minutes.round()} min';
  }
  return '${(minutes / 60).toStringAsFixed(1)} h';
}

int _minuteOf(Json c) => ((c['createdAt'] as num? ?? 0).toInt() ~/ 60000);

String _minuteLabel(int minute) {
  final date = DateTime.fromMillisecondsSinceEpoch(minute * 60000).toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(date.hour)}:${two(date.minute)}';
}

/// Buckets ordered newest minute first. Rows inside a bucket keep the feed's
/// current sort, so grouping never fights the speed/date/traffic ordering.
class _MinuteGroup {
  const _MinuteGroup(this.minute, this.rows);
  final int minute;
  final List<Json> rows;
}

List<_MinuteGroup> _groupByMinute(List<Json> rows) {
  final buckets = <int, List<Json>>{};
  for (final row in rows) {
    (buckets[_minuteOf(row)] ??= []).add(row);
  }
  final minutes = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
  return [for (final minute in minutes) _MinuteGroup(minute, buckets[minute]!)];
}

typedef _ConnectionCell = ({int? minute, int count, Json? connection});

/// Test-visible count of minute-bucket regroupings; cached builds do not increment it.
int connectionCellsFlattenCount = 0;

/// Incrementally maintained id -> row index for the applied connection feed.
/// The host replaces maps when a row changes, so identity tells us which rows
/// are new: only those are inserted. Rows that leave the ring are pruned to keep
/// the index bounded; a detail page already showing one keeps its own last-known
/// copy authoritative, so it never flashes back to its initial snapshot.
final Map<Object?, Json> _connectionById = {};
/// Bumped once whenever [_connectionById] changes, so detail pages can watch a
/// scalar instead of the whole feed list.
final connectionFeedRevision = ValueNotifier<int>(0);
Json? connectionById(Object? id) => _connectionById[id];

/// Adopts a new feed snapshot into the id index. Only rows whose map identity
/// changed are processed; the common case (a handful of new/updated maps in a
/// ~1000-row ring) is O(changed), not O(total).
void indexConnections(List<Json> connections) {
  var changed = false;
  final present = <Object?>{};
  for (final row in connections) {
    final id = row['id'];
    present.add(id);
    if (!identical(_connectionById[id], row)) {
      _connectionById[id] = row;
      changed = true;
    }
  }
  // Drop ids that are no longer in the ring; an open detail page holds its own
  // last-known copy, so pruning cannot make it lose the row it is showing.
  _connectionById.removeWhere((id, _) => !present.contains(id));
  if (changed) connectionFeedRevision.value++;
}


/// The sampled connection list.
///
/// The sampler is expensive (a full clash-api list every 1.5 s), so it follows the page's
/// activity rather than its mount: full while the page is on screen, parked while another
/// route covers it or the app is backgrounded (the rows already rendered stay), and off on
/// close. See [_ConnectionsPageState._syncFeedActivity] and the host's `connections.visible`.
///
/// A sample only repaints the rows when it is applied: one arriving while the page's route
/// moves waits, and the newest sample is applied after it settles (`updateWhenRouteSettled`).
class ConnectionsPage extends ConsumerStatefulWidget {
  const ConnectionsPage({super.key});
  @override ConsumerState<ConnectionsPage> createState() => _ConnectionsPageState();
}
/// What the page has asked the host's sampler for (see [ConnectionsApi.connectionsSetVisible]).
/// The page outlives its visibility — it stays mounted under another route and across a
/// background interval — so the feed follows [_ConnectionsPageState._onScreen], not the mount.
enum _FeedMode { off, parked, full }

class _ConnectionsPageState extends ConsumerState<ConnectionsPage>
    with WidgetsBindingObserver, RouteMotionHoldMixin<ConnectionsPage> {
  /// Filtered/sorted rows, reused across builds. `build` also depends on state (for
  /// `box.running`), so every settings/profile/preference event used to re-join and
  /// re-lowercase seven fields per connection and re-sort an unbounded list.
  ({Object? source, String query, Object? keywords, String status, String filter, String sort, bool running,
    int active, int closed, int failed, List<Json> rows, List<_ConnectionCell> cells})? _derived;

  /// The feed as last applied to the list. A sample arriving while the page's route moves
  /// waits here, and the newest one is applied after it settles — the rows already rendered
  /// stay put through a push or drag instead of being rebuilt under it.
  List<Json> _connections = const [];
  /// Whether rows have ever been applied: only the page's first content skips the hold, so a
  /// pushed page never opens blank.
  bool _hasContent = false;
  bool _listLoaded = false;

  /// Lowercased searchable text cached per connection map. BoxController replaces the map
  /// when a row changes and drops it when the row goes away, which bounds the cache's life.
  static final _haystacks = Expando<String>('ConnectionRecord.haystack');
  static String _haystack(Json connection) {
    final cached = _haystacks[connection];
    if (cached != null) return cached;
    return _haystacks[connection] = [
      connection['destination'], connection['displayDestination'], connection['domain'], connection['outbound'],
      connection['network'], connection['rule'], connection['source'], connection['process'],
    ].join(' ').toLowerCase();
  }

  BoxController? _box;
  String _query = '', _filter = 'All', _sort = 'Speed';
  RequestStatus _status = RequestStatus.all;

  /// The host feed mode this page last asked for, so a gate that flips back and forth
  /// (a route push, a lifecycle burst) costs one channel call per real transition.
  _FeedMode _feed = _FeedMode.off;
  /// The page's tab is the active one and its tickers run, cached in
  /// [didChangeDependencies] because the route listener has no build phase to read it in.
  bool _tabActive = true;
  /// Every route carrying this page: its own, plus the sheets holding it. Watched so a route
  /// pushed over the page parks the feed instead of leaving it sampling behind a cover.
  List<ModalRoute<Object?>> _carriers = const [];

  /// Why the list may be empty: `connections.state` (tunnel/API switch/reachability).
  Json _state = const {};
  bool _enabling = false;
  // Taps on a record's labels filter by them: the strip shows those terms and
  // the search field keeps only what was typed.
  final _keywords = ValueNotifier<List<ScaffoldKeyword>>(const []);
  String get _search => [
    _query,
    ..._keywords.value.map((keyword) => '${keyword.key}'),
  ].where((word) => word.trim().isNotEmpty).join(' ');
  void _keywordsChanged() => setState(() {});
  void _addFilter(String word, {String? label}) {
    if (_keywords.value.any((keyword) => keyword.key == word)) return;
    _keywords.value = [..._keywords.value, ScaffoldKeyword(key: word, label: label ?? word, onDeleted: () => _removeFilter(word))];
  }
  void _removeFilter(String word) =>
    _keywords.value = [for (final keyword in _keywords.value) if (keyword.key != word) keyword];
  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _keywords.addListener(_keywordsChanged);
  }

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_listLoaded) {
      _listLoaded = true;
      // Rows already in the controller are the page's first content: it is applied at once
      // (while the arrival hold keeps a push at zero) instead of waiting for the route.
      showFirstContent(_applyConnections);
    }
    final box = ref.read(boxControllerProvider);
    if (_box == null) {
      _box = box;
      _refreshState();
    }
    _tabActive = PageActivityScope.isActiveOf(context) && TickerMode.valuesOf(context).enabled;
    _watchRoutes();
    _syncFeedActivity();
  }

  /// A sample moved. The page's first content is shown at once; every later one waits while
  /// the route moves, and several held through one transition replay as the newest.
  void _connectionsChanged() {
    if (_hasContent) {
      updateWhenRouteSettled(_applyConnections);
    } else {
      showFirstContent(_applyConnections);
    }
  }

  /// Adopts the feed as it is now. The provider is read inside the callback, so a held
  /// sample replays the newest rows rather than a stale copy taken when it arrived.
  void _applyConnections() {
    if (!mounted) return;
    final source = ref.read(connectionsProvider);
    indexConnections(source);
    setState(() {
      _connections = source;
      _hasContent = _hasContent || source.isNotEmpty;
    });
  }

  /// Follows the routes carrying this page. A push over the page starts the covered route's
  /// `secondaryAnimation`; a pop reverses it. Refreshed in [didChangeDependencies] because a
  /// sheet appearing or closing changes the list while `ModalRoute.of` stays the same.
  void _watchRoutes() {
    final carriers = routesCarrying(context).toList(growable: false);
    if (_sameRoutes(carriers, _carriers)) return;
    for (final route in _carriers) {
      route.secondaryAnimation?.removeStatusListener(_routeMoved);
    }
    _carriers = carriers;
    for (final route in carriers) {
      route.secondaryAnimation?.addStatusListener(_routeMoved);
    }
  }

  static bool _sameRoutes(List<ModalRoute<Object?>> a, List<ModalRoute<Object?>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!identical(a[i], b[i])) return false;
    }
    return true;
  }

  void _routeMoved(AnimationStatus _) => _syncFeedActivity();

  @override void didChangeAppLifecycleState(AppLifecycleState state) => _syncFeedActivity();

  /// Whether the page is on screen: its tab active, its tickers enabled, no route above any
  /// of its carriers, and the app resumed. [BoxDataSubscription]'s rule plus the route check
  /// this page's own feed needs — a covered page keeps its rows but stops sampling.
  bool get _onScreen {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return false;
    if (!_tabActive) return false;
    for (final route in _carriers) {
      if (!route.isCurrent) return false;
    }
    return true;
  }

  /// Moves the host's sampler to match [_onScreen]: full while on screen, parked (feed
  /// stopped, rows and closed ring kept) while covered or backgrounded, off once closed.
  /// The parked state is what lets a detail page or a background interval come back to the
  /// list it had; the host's S6 count loop keeps the dashboard card's number while parked.
  void _syncFeedActivity() {
    final box = _box;
    if (box == null) return;
    final desired = _onScreen ? _FeedMode.full : _FeedMode.parked;
    if (desired == _feed) return;
    // Nothing to park before the first full feed: the host never started sampling.
    if (desired == _FeedMode.parked && _feed == _FeedMode.off) return;
    _feed = desired;
    if (desired == _FeedMode.full) {
      box.connectionsSetVisible(true);
    } else {
      box.connectionsSetVisible(false, pause: true);
    }
  }
  Future<void> _refreshState() async {
    final box = _box;
    if (box == null) return;
    try {
      final state = await box.connectionsState();
      if (mounted) setState(() => _state = state);
    } catch (_) {
      // The state op is a diagnostic; a host without it leaves the plain empty state.
    }
  }

  /// Writes the Clash API port, then reloads the core so the new config serves it.
  Future<void> _enableApi() async {
    final box = _box;
    if (box == null || _enabling) return;
    setState(() => _enabling = true);
    try {
      final result = await box.connectionsEnableApi();
      if (!mounted) return;
      setState(() => _state = result.state);
      if (result.changed) {
        final reload = await confirm(
          context,
          'Restart the core to apply?',
          message: 'The Clash API is enabled; the tunnel reloads before the connection list works.',
          action: 'Reload',
        );
        if (reload) {
          await box.serviceReload();
          await _refreshState();
        }
      }
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _enabling = false);
    }
  }

  /// The empty state, with the reason the list is empty and the one fix it can offer.
  /// When the tunnel is healthy and there are no rows at all, the three status
  /// buckets get distinct copy; a search/filter miss keeps the shared no-results
  /// state (shown by [NullStatusSwitcher]) rather than claiming there is no traffic.
  NullStatus _emptyStatus(BuildContext context, {required RequestStatus status}) {
    final state = _state;
    final label = context.tr('No connections');
    // Diagnostics first: a tunnel that is down or an API that is off/unreachable
    // matters more than any bucket's empty copy. Tests (and users) rely on seeing
    // the fix, not a generic "no requests" when the feed cannot work at all.
    if (state.isEmpty) return NullStatus(label: label, illustration: NullStatusIllustration.connections);
    final running = state['running'] == true;
    final apiEnabled = state['apiEnabled'] == true;
    final reachable = state['reachable'] == true;
    final error = (state['pumpError'] ?? state['error'])?.toString();
    if (!running) {
      return NullStatus(
        label: context.tr('Tunnel is not running'),
        description: context.tr('Start the tunnel to see connections'),
        illustration: NullStatusIllustration.connections,
      );
    }
    if (!apiEnabled) {
      return NullStatus(
        label: context.tr('Connection list is off'),
        description: context.tr('The list reads the core Clash API; enable it and reload the core.'),
        illustration: NullStatusIllustration.connections,
        action: TonalButton(
          size: TonalButtonSize.bar,
          label: context.tr('Enable'),
          onPressed: _enabling ? null : _enableApi,
        ),
      );
    }
    if (!reachable) {
      final where = '${state['address'] ?? ''}:${state['port'] ?? ''}';
      return NullStatus(
        label: context.tr('Clash API is not answering'),
        description: [if (where != ':') where, if (error != null && error.isNotEmpty) error].join('\n'),
        illustration: NullStatusIllustration.connections,
        action: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: [
          TonalButton(size: TonalButtonSize.bar, label: context.tr('Retry'), onPressed: _refreshState),
          TonalButton(size: TonalButtonSize.bar, label: context.tr('Reload'), onPressed: _enabling ? null : _reloadCore),
        ]),
      );
    }
    if (_connections.isEmpty) {
      final emptyLabel = switch (status) {
        RequestStatus.all => context.tr('No requests yet'),
        RequestStatus.active => context.tr('No active requests'),
        RequestStatus.failed => context.tr('No failed requests'),
      };
      return NullStatus(label: emptyLabel, illustration: NullStatusIllustration.requests);
    }
    return NullStatus(label: label, description: error, illustration: NullStatusIllustration.connections);
  }

  /// Rebuilds the running config: a config generated before the API's port was written does
  /// not serve it, and only a reload regenerates it.
  Future<void> _reloadCore() async {
    final box = _box;
    if (box == null || _enabling) return;
    setState(() => _enabling = true);
    try {
      await box.serviceReload();
      await _refreshState();
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _enabling = false);
    }
  }
  @override void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final route in _carriers) {
      route.secondaryAnimation?.removeStatusListener(_routeMoved);
    }
    _carriers = const [];
    _keywords.removeListener(_keywordsChanged);
    _keywords.dispose();
    // Off, even from parked: the rows the page kept are history for a resume, but nothing
    // renders them any more, and the card's count must not be outbid by a stale sample.
    if (_feed != _FeedMode.off) {
      _feed = _FeedMode.off;
      _box?.connectionsSetVisible(false);
    }
    super.dispose();
  }
  Future<void> _closeAll() async {
    final box = ref.read(boxControllerProvider);
    if (await confirm(context, 'Close all active connections?', action: 'Close')) await box.connectionsCloseAll();
  }
  @override Widget build(BuildContext context) {
    // Read the controller from the injected provider; the reactive fields it
    // reads below are watched, so the page rebuilds on their notifications.
    final box = ref.watch(boxControllerProvider);
    // Followed with a listener, not watched: a sample rebuilds the list when it is applied,
    // so several arriving during one route transition cost one repaint, after it.
    ref.listen<List<Json>>(connectionsProvider, (_, _) => _connectionsChanged());
    final source = _connections, keywords = _keywords.value;
    final running = ref.watch(runningProvider);
    final cached = _derived;
    if (cached != null &&
        identical(cached.source, source) &&
        cached.query == _query &&
        identical(cached.keywords, keywords) &&
        cached.status == _status.name &&
        cached.filter == _filter &&
        cached.sort == _sort &&
        cached.running == running) {
      // Unrelated state/preference rebuilds reuse the same filtered+sorted rows.
      return _buildWithList(context, box, cached.cells, cached.active, cached.closed, cached.failed);
    }
    // Tokenised once per derivation. `_search` joins the query with every keyword and was
    // called inside the filter closure, so every connection re-joined and re-split the same
    // search string (~2 string builds + a regex split per row). logs.dart hoists it too.
    final words = _search.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    // One pass over the source after the search filter: each option's count is how many
    // rows it would show, so the selector and menu reflect the current query without a
    // second feed. Status counts are computed over the *searched* set for the same reason.
    final searched = source.where((connection) => words.every(_haystack(connection).contains)).toList();
    var active = 0, closed = 0, failed = 0;
    for (final connection in searched) {
      if (_isClosed(connection)) {
        closed++;
        if (_isFailed(connection)) failed++;
      } else {
        active++;
      }
    }
    final list = searched.where((connection) {
      // New status selector: the feed only stamps closed rows, so Failed = closed.
      if (_status == RequestStatus.active && _isClosed(connection)) return false;
      if (_status == RequestStatus.failed && !_isFailed(connection)) return false;
      // Legacy Active/Closed filter (kept so existing chip/menu flows still work).
      if (_filter == 'Active' && _isClosed(connection) || _filter == 'Closed' && !_isClosed(connection)) return false;
      return true;
    }).toList();
    final key = {'Created': 'createdAt', 'Upload': 'uploadTotal', 'Download': 'downloadTotal'}[_sort];
    num rank(Json c) => key == null ? (c['upload'] as num? ?? 0) + (c['download'] as num? ?? 0) : c[key] as num? ?? 0;
    list.sort((a, b) => rank(b).compareTo(rank(a)));
    // Flatten minute buckets once here, not on every unrelated state rebuild.
    final cells = _flattenCells(list);
    _derived = (source: source, query: _query, keywords: keywords, status: _status.name, filter: _filter,
      sort: _sort, running: running, active: active, closed: closed, failed: failed, rows: list, cells: cells);
    return _buildWithList(context, box, cells, active, closed, failed);
  }

  /// Flattens the sorted rows into minute headers + connection cells. Cached in
  /// [_derived] so a state-only notification never regroups up to 1000 rows.
  static List<_ConnectionCell> _flattenCells(List<Json> list) {
    connectionCellsFlattenCount++;
    return [
      for (final group in _groupByMinute(list)) ...[
        (minute: group.minute, count: group.rows.length, connection: null),
        for (final row in group.rows) (minute: null, count: 0, connection: row),
      ],
    ];
  }

  Widget _buildWithList(BuildContext context, BoxController box, List<_ConnectionCell> cells, [int active = 0, int closed = 0, int failed = 0]) {
    return Scaffold(
      title: context.tr('Requests'),
      keywords: _keywords,
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      iconActions: [IconButtonData(glyph: AppGlyphs.clearAll, tooltip: context.tr('Close all connections'), onPressed: box.running ? _closeAll : null)],
      menuItems: [
        for (final filter in ['Active', 'Closed', 'All'])
          PopupMenuItem(
            label: '${context.tr(filter)} ${switch (filter) {
              'Active' => active,
              'Closed' => closed,
              _ => active + closed,
            }}',
            checked: filter == _filter,
            section: filter == 'Active' ? PopupMenuSection(title: context.tr('Requests')) : null,
            onPressed: () => setState(() => _filter = filter)),
        for (final sort in ['Speed', 'Created', 'Upload', 'Download'])
          PopupMenuItem(glyph: AppGlyphs.sort, label: context.tr(sort), checked: sort == _sort, onPressed: () => setState(() => _sort = sort)),
      ],
      // Read the insets below the scaffold: with a keyword chip shown the strip already holds
      // the app bar's place, and the list must not add that height again (a short, filtered
      // list used to open on a blank band).
      body: Builder(builder: (context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SegmentedControl<RequestStatus>(
            segments: [
              (RequestStatus.all, '${context.tr('All')} ${active + closed}'),
              (RequestStatus.active, '${context.tr('Active')} $active'),
              (RequestStatus.failed, '${context.tr('Failed')} $failed'),
            ],
            value: _status,
            onChanged: (status) => setState(() => _status = status),
          ),
        ),
        Expanded(child: NullStatusSwitcher(
          isEmpty: cells.isEmpty,
          isSearching: _search.trim().isNotEmpty,
          nullStatus: _emptyStatus(context, status: _status),
          child: ListView.separated(
              padding: recordListPadding(context),
              itemCount: cells.length,
              separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
              itemBuilder: (context, index) {
                final cell = cells[index];
                final minute = cell.minute, connection = cell.connection;
                if (minute != null) {
                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
                    child: Row(children: [
                      Text(_minuteLabel(minute), style: AppTextStyle.footnote.of(context, emphasized: true).toTabular),
                      const SizedBox(width: 8),
                      Text('${cell.count}',
                          style: AppTextStyle.footnote.of(context).toTabular
                              .copyWith(color: context.colorScheme.onSurfaceVariant)),
                    ]),
                  );
                }
                return ConnectionRecord(connection: connection!, onFilter: _addFilter);
              },
            ),
        )),
      ])),
    );
  }
}

class ConnectionRecord extends ConsumerWidget {
  const ConnectionRecord({super.key, required this.connection, required this.onFilter});
  final Json connection;
  final FilterAdder onFilter;
  @override Widget build(BuildContext context, WidgetRef ref) {
    final c = connection, box = ref.watch(boxControllerProvider);
    final running = ref.watch(runningProvider);
    final styles = RecordTextStyles.of(context);
    final closed = _isClosed(c);
    final failed = closed ? _failureReason(c) : null;
    final duration = _durationText(c);
    final protocol = (c['protocol'] as String? ?? '').trim();
    final path = _processPath(c['process']);
    return RecordListItem(
      key: ValueKey(c['id']),
      onTap: () => openPage(context, ConnectionDetail(initial: c)),
      header: RecordHeader(
        trailing: !closed && running ? Tooltip(
          message: context.tr('Close this connection'), child: Semantics(button: true, child: InkWell(
            customBorder: AppShape.circle, onTap: () => box.connectionsClose(c['id']),
            child: SizedBox.square(dimension: 28, child: Center(child: GlyphIcon(AppGlyphs.block, size: 16, color: context.colorScheme.onSurfaceVariant))),
          )),
        ) : null,
        children: [
          RecordTimestamp(recordTime(c['createdAt'])),
          RecordLabel(label: c['network'].toString().toUpperCase(), onPressed: () => onFilter(c['network'].toString())),
          if (protocol.isNotEmpty)
            RecordLabel(label: protocol, onPressed: () => onFilter(protocol)),
          if (closed) RecordLabel(label: context.tr('Closed')),
          if (duration.isNotEmpty && duration != '—') RecordLabel(label: duration),
          if (failed != null) RecordLabel(label: failed, tone: RecordTone.error),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
        Text(c['displayDestination']?.toString() ?? c['destination']?.toString() ?? '—', style: styles.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
          if ((c['rule'] as String? ?? '').isNotEmpty) ...[Text(c['rule'].toString(), style: styles.secondary), const RecordArrow()],
          Text(c['outbound']?.toString() ?? '—', style: AppTextStyle.footnote.of(context, emphasized: true).copyWith(color: context.colorScheme.primary)),
        ]),
        if (path != null) _ProcessLine(path: path, source: c['source']?.toString(), onFilter: onFilter, secondary: styles.secondary)
        else Text(c['source']?.toString() ?? '—', style: styles.secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
        Wrap(spacing: 16, runSpacing: 4, children: [for (final upload in [true, false]) Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
          GlyphIcon(upload ? AppGlyphs.arrowUp : AppGlyphs.arrowDown, size: 12, color: context.colorScheme.onSurfaceVariant),
          Text('${bytes(c[upload ? 'uploadTotal' : 'downloadTotal'] as num? ?? 0)} · ${bytes(c[upload ? 'upload' : 'download'] as num? ?? 0)}/s', style: styles.secondary.toTabular),
        ])]),
      ]),
    );
  }
}

/// 28dp rounded avatar + app label, both resolved from the process path. The icon bytes come
/// from the controller's per-path cache, so a rebuild never re-asks. An unresolvable path (a
/// system process, a path outside an app) keeps the old source line rather than printing the
/// whole APK path as if it were an app name.
class _ProcessLine extends ConsumerWidget {
  const _ProcessLine({required this.path, this.source, required this.onFilter, required this.secondary});
  final String path;
  final String? source;
  final FilterAdder onFilter;
  final TextStyle secondary;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(boxControllerProvider).processInfoFor(path);
    return FutureBuilder<Json>(
      future: info,
      builder: (context, snapshot) {
        final data = snapshot.data ?? const <String, dynamic>{};
        final label = data['label']?.toString();
        final pkg = data['package']?.toString();
        if (pkg == null || label == null) {
          return Text(source ?? '—', style: secondary, maxLines: 1, overflow: TextOverflow.ellipsis);
        }
        final bytes = data['icon'] as Uint8List?;
        return Row(spacing: 6, children: [
          _appAvatar(bytes: bytes),
          Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 1, children: [
            GestureDetector(
              onTap: () => onFilter(pkg, label: label),
              child: Text(label, style: secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (source != null && source!.isNotEmpty)
              Text(source!, style: secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
          ])),
        ]);
      },
    );
  }
}

Widget _appAvatar({Uint8List? bytes}) => ClipRRect(
  borderRadius: BorderRadius.circular(8),
  child: SizedBox.square(dimension: 28, child: bytes == null
    ? Center(child: GlyphIcon(AppGlyphs.appsList, size: 16))
    : Image.memory(bytes, width: 28, height: 28, fit: BoxFit.cover, gaplessPlayback: true)),
);

class ConnectionDetail extends ConsumerStatefulWidget {
  const ConnectionDetail({super.key, required this.initial});
  final Json initial;
  @override ConsumerState<ConnectionDetail> createState() => _ConnectionDetailState();
}
class _ConnectionDetailState extends ConsumerState<ConnectionDetail> {
  late Json _cached = widget.initial;
  @override Widget build(BuildContext context) {
    final box = ref.watch(boxControllerProvider);
    // Watch only the feed revision, not the whole list: a batch that changes
    // unrelated rows no longer rescans ~1000 entries for this one id.
    connectionFeedRevision.value;
    final running = ref.watch(runningProvider);
    final live = connectionById(widget.initial['id']);
    var present = live != null;
    if (live != null) _cached = live;
    final c = _cached;
    // The same rows, grouped by what they describe. All sections stay in `rows` for copy.
    final sections = <String, List<MapEntry<String, dynamic>>>{
      'Overview': [
        MapEntry('Destination', c['displayDestination']), MapEntry('Source', c['source']),
        MapEntry('Network', c['network']), MapEntry('Protocol', c['protocol']),
        MapEntry('Inbound', c['inbound']), MapEntry('Outbound', c['outbound']),
      ],
      'Route': [
        MapEntry('Rule matched', c['rule']),
        MapEntry('Chain', (c['chain'] as List? ?? []).join(' → ')),
      ],
      if (c['process'] != null)
        'Process': [
          MapEntry('Process', json(c['process']).entries.map((e) => '${e.key}: ${e.value}').join('\n')),
        ],
      if (_isClosed(c) && _failureReason(c) != null)
        'Failure': [MapEntry('Reason', _failureReason(c))],
      'Traffic': [
        MapEntry('Upload', bytes(c['uploadTotal'] as num? ?? 0)),
        MapEntry('Download', bytes(c['downloadTotal'] as num? ?? 0)),
        MapEntry('Created', localDate(c['createdAt'])),
        if (_isClosed(c)) ...[
          MapEntry('Closed', localDate(c['closedAt'])),
          MapEntry('Duration', _durationText(c)),
        ],
      ],
    };
    final rows = sections.values.expand((section) => section).toList();
    return BoxPage(
      title: 'Details',
      actions: [
        IconButtonData(glyph: AppGlyphs.copy, tooltip: context.tr('Copy'), onPressed: () async {
          await Clipboard.setData(ClipboardData(text: rows.map((e) => '${e.key}: ${e.value}').join('\n')));
          if (!context.mounted) return;
          box.showMessage(context.tr('Copied'));
        }),
        IconButtonData(glyph: AppGlyphs.close, tooltip: context.tr('Close this connection'),
          onPressed: running && present && (c['closedAt'] as num? ?? 0) == 0 ? () => box.connectionsClose(c['id']) : null),
      ],
      children: [for (final section in sections.entries)
        generateSection(title: context.tr(section.key), items: [
          for (final value in section.value)
            DetailRow.text(title: context.tr(value.key), value: value.value?.toString() ?? '—'),
        ])],
    );
  }
}
