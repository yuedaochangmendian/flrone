import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets.dart';
import '../providers/box_providers.dart';
import '../components/record.dart';

class ConnectionsPage extends ConsumerStatefulWidget {
  const ConnectionsPage({super.key});
  @override ConsumerState<ConnectionsPage> createState() => _ConnectionsPageState();
}
class _ConnectionsPageState extends ConsumerState<ConnectionsPage> {
  /// Filtered/sorted rows, reused across builds. `build` also depends on state (for
  /// `box.running`), so every settings/profile/preference event used to re-join and
  /// re-lowercase seven fields per connection and re-sort an unbounded list.
  ({Object? source, String query, Object? keywords, String filter, String sort, bool running, List<Json> rows})? _derived;

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
  // Taps on a record's labels filter by them: the strip shows those terms and
  // the search field keeps only what was typed.
  final _keywords = ValueNotifier<List<ScaffoldKeyword>>(const []);
  String get _search => [
    _query,
    ..._keywords.value.map((keyword) => '${keyword.key}'),
  ].where((word) => word.trim().isNotEmpty).join(' ');
  void _keywordsChanged() => setState(() {});
  void _addFilter(String word) {
    if (_keywords.value.any((keyword) => keyword.key == word)) return;
    _keywords.value = [..._keywords.value, ScaffoldKeyword(key: word, label: word, onDeleted: () => _removeFilter(word))];
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
      final list = cached.rows;
      return _buildWithList(context, box, list);
    }
    // Tokenised once per derivation. `_search` joins the query with every keyword and was
    // called inside the filter closure, so every connection re-joined and re-split the same
    // search string (~2 string builds + a regex split per row). logs.dart hoists it too.
    final words = _search.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final list = source.where((connection) {
      final closed = (connection['closedAt'] as num? ?? 0) > 0;
      if (_filter == 'Active' && closed || _filter == 'Closed' && !closed) return false;
      return words.every(_haystack(connection).contains);
    }).toList();
    final key = {'Created': 'createdAt', 'Upload': 'uploadTotal', 'Download': 'downloadTotal'}[_sort];
    num rank(Json c) => key == null ? (c['upload'] as num? ?? 0) + (c['download'] as num? ?? 0) : c[key] as num? ?? 0;
    list.sort((a, b) => rank(b).compareTo(rank(a)));
    _derived = (source: source, query: _query, keywords: keywords, filter: _filter,
      sort: _sort, running: running, rows: list);
    return _buildWithList(context, box, list);
  }

  Widget _buildWithList(BuildContext context, BoxController box, List<Json> list) {
    return Scaffold(
      title: context.tr('Connections'),
      keywords: _keywords,
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      iconActions: [IconButtonData(glyph: AppGlyphs.clearAll, tooltip: context.tr('Close all connections'), onPressed: box.running ? _closeAll : null)],
      menuItems: [
        for (final filter in ['Active', 'Closed', 'All'])
          PopupMenuItem(label: context.tr(filter), checked: filter == _filter,
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
        nullStatus: NullStatus(label: context.tr('No connections'), illustration: NullStatusIllustration.connections),
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
  final ValueChanged<String> onFilter;
  @override Widget build(BuildContext context, WidgetRef ref) {
    final c = connection, box = ref.watch(boxControllerProvider);
    final running = ref.watch(runningProvider);
    final styles = RecordTextStyles.of(context);
    final closed = (c['closedAt'] as num? ?? 0) > 0;
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
          if (closed) RecordLabel(label: context.tr('Closed')),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.start, spacing: 4, children: [
        Text(c['displayDestination']?.toString() ?? c['destination']?.toString() ?? '—', style: styles.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
          if ((c['rule'] as String? ?? '').isNotEmpty) ...[Text(c['rule'].toString(), style: styles.secondary), const RecordArrow()],
          Text(c['outbound']?.toString() ?? '—', style: AppTextStyle.footnote.of(context, emphasized: true).copyWith(color: context.colorScheme.primary)),
        ]),
        Text(c['source']?.toString() ?? '—', style: styles.secondary, maxLines: 1, overflow: TextOverflow.ellipsis),
        Wrap(spacing: 16, runSpacing: 4, children: [for (final upload in [true, false]) Row(mainAxisSize: MainAxisSize.min, spacing: 4, children: [
          GlyphIcon(upload ? AppGlyphs.arrowUp : AppGlyphs.arrowDown, size: 12, color: context.colorScheme.onSurfaceVariant),
          Text('${bytes(c[upload ? 'uploadTotal' : 'downloadTotal'] as num? ?? 0)} · ${bytes(c[upload ? 'upload' : 'download'] as num? ?? 0)}/s', style: styles.secondary.toTabular),
        ])]),
      ]),
    );
  }
}

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
    final values = <String, dynamic>{
      'Destination': c['displayDestination'], 'Source': c['source'], 'Network': c['network'],
      'Protocol': c['protocol'], 'Inbound': c['inbound'], 'Outbound': c['outbound'],
      'Rule matched': c['rule'], 'Chain': (c['chain'] as List? ?? []).join(' → '),
      'Created': localDate(c['createdAt']),
      if ((c['closedAt'] as num? ?? 0) > 0) 'Closed': localDate(c['closedAt']),
      'Upload': bytes(c['uploadTotal'] as num? ?? 0), 'Download': bytes(c['downloadTotal'] as num? ?? 0),
      if (c['process'] != null) 'Process': json(c['process']).entries.map((e) => '${e.key}: ${e.value}').join('\n'),
    };
    return BoxPage(
      title: 'Details',
      actions: [
        IconButtonData(glyph: AppGlyphs.copy, tooltip: context.tr('Copy'), onPressed: () async {
          await Clipboard.setData(ClipboardData(text: values.entries.map((e) => '${e.key}: ${e.value}').join('\n')));
          if (!context.mounted) return;
          box.showMessage(context.tr('Copied'));
        }),
        IconButtonData(glyph: AppGlyphs.close, tooltip: context.tr('Close this connection'),
          onPressed: running && present && (c['closedAt'] as num? ?? 0) == 0 ? () => box.connectionsClose(c['id']) : null),
      ],
      children: [generateGroup([for (final value in values.entries) DetailRow.text(title: context.tr(value.key), value: value.value?.toString() ?? '—')])],
    );
  }
}
