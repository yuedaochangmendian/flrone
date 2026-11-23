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

class ConnectionsPage extends ConsumerStatefulWidget {
  const ConnectionsPage({super.key});
  @override ConsumerState<ConnectionsPage> createState() => _ConnectionsPageState();
}
class _ConnectionsPageState extends ConsumerState<ConnectionsPage> {
  /// Filtered/sorted rows, reused across builds. `build` also depends on state (for
  /// `box.running`), so every settings/profile/preference event used to re-join and
  /// re-lowercase seven fields per connection and re-sort an unbounded list.
  ({Object? source, String query, Object? keywords, String filter, String sort, bool running, int active, int closed, List<Json> rows})? _derived;

  /// Lowercased searchable text cached per connection map. BoxController replaces the map
  /// when a row changes and drops it when the row goes away, which bounds the cache's life.
  static final _haystacks = Expando<String>('ConnectionRecord.haystack');
  static String _haystack(Json connection) {
    final cached = _haystacks[connection];
    if (cached != null) return cached;
    return _haystacks[connection] = [
      connection['destination'], connection['domain'], connection['outbound'],
      connection['network'], connection['rule'], connection['source'], connection['process'],
    ].join(' ').toLowerCase();
  }

  BoxController? _box;
  String _query = '', _filter = 'Active', _sort = 'Speed';

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
    _keywords.addListener(_keywordsChanged);
  }

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_box == null) {
      _box = ref.read(boxControllerProvider);
      _box!.connectionsSetVisible(true);
      _refreshState();
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
  NullStatus _emptyStatus(BuildContext context) {
    final state = _state;
    final label = context.tr('No connections');
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
    _keywords.removeListener(_keywordsChanged);
    _keywords.dispose();
    _box?.connectionsSetVisible(false);
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
    final source = ref.watch(connectionsProvider), keywords = _keywords.value;
    final running = ref.watch(runningProvider);
    final cached = _derived;
    if (cached != null &&
        identical(cached.source, source) &&
        cached.query == _query &&
        identical(cached.keywords, keywords) &&
        cached.filter == _filter &&
        cached.sort == _sort &&
        cached.running == running) {
      // Unrelated state/preference rebuilds reuse the same filtered+sorted rows.
      return _buildWithList(context, box, cached.rows, cached.active, cached.closed);
    }
    // Tokenised once per derivation. `_search` joins the query with every keyword and was
    // called inside the filter closure, so every connection re-joined and re-split the same
    // search string (~2 string builds + a regex split per row). logs.dart hoists it too.
    final words = _search.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    // One pass over the source after the search filter: each option's count is how many
    // rows it would show, so the menu reflects the current query without a second feed.
    final searched = source.where((connection) => words.every(_haystack(connection).contains)).toList();
    var active = 0, closed = 0;
    for (final connection in searched) {
      if ((connection['closedAt'] as num? ?? 0) > 0) {
        closed++;
      } else {
        active++;
      }
    }
    final list = searched.where((connection) {
      final isClosed = (connection['closedAt'] as num? ?? 0) > 0;
      if (_filter == 'Active' && isClosed || _filter == 'Closed' && !isClosed) return false;
      return true;
    }).toList();
    final key = {'Created': 'createdAt', 'Upload': 'uploadTotal', 'Download': 'downloadTotal'}[_sort];
    num rank(Json c) => key == null ? (c['upload'] as num? ?? 0) + (c['download'] as num? ?? 0) : c[key] as num? ?? 0;
    list.sort((a, b) => rank(b).compareTo(rank(a)));
    _derived = (source: source, query: _query, keywords: keywords, filter: _filter,
      sort: _sort, running: running, active: active, closed: closed, rows: list);
    return _buildWithList(context, box, list, active, closed);
  }

  Widget _buildWithList(BuildContext context, BoxController box, List<Json> list, [int active = 0, int closed = 0]) {
    return Scaffold(
      title: context.tr('Connections'),
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
            section: filter == 'Active' ? PopupMenuSection(title: context.tr('Connections')) : null,
            onPressed: () => setState(() => _filter = filter)),
        for (final sort in ['Speed', 'Created', 'Upload', 'Download'])
          PopupMenuItem(glyph: AppGlyphs.sort, label: context.tr(sort), checked: sort == _sort, onPressed: () => setState(() => _sort = sort)),
      ],
      // Read the insets below the scaffold: with a keyword chip shown the strip already holds
      // the app bar's place, and the list must not add that height again (a short, filtered
      // list used to open on a blank band).
      body: Builder(builder: (context) => NullStatusSwitcher(
        isEmpty: list.isEmpty, isSearching: _search.trim().isNotEmpty,
        nullStatus: _emptyStatus(context),
        child: ListView.separated(
            padding: recordListPadding(context),
            itemCount: list.length,
            separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
            itemBuilder: (context, index) {
              final connection = list[index];
              return ConnectionRecord(connection: connection, onFilter: _addFilter);
            },
          ),
      )),
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
    final closed = (c['closedAt'] as num? ?? 0) > 0;
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
    final connections = ref.watch(connectionsProvider);
    final running = ref.watch(runningProvider);
    var present = false;
    for (final connection in connections) {
      if (connection['id'] == widget.initial['id']) { _cached = connection; present = true; break; }
    }
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
      'Traffic': [
        MapEntry('Upload', bytes(c['uploadTotal'] as num? ?? 0)),
        MapEntry('Download', bytes(c['downloadTotal'] as num? ?? 0)),
        MapEntry('Created', localDate(c['createdAt'])),
        if ((c['closedAt'] as num? ?? 0) > 0) MapEntry('Closed', localDate(c['closedAt'])),
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
