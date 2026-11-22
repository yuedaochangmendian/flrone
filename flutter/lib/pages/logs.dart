import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets.dart';
import '../providers/box_providers.dart';
import '../common/log_level.dart';
import '../components/record.dart';
import '../components/data_subscription.dart';

/// Inputs that decide whether the merged row list can be reused. Lists compare by identity
/// inside a record, so a same-length window whose last id advanced still invalidates.
typedef _RowsKey = ({
  Object? logs,
  int logsLength,
  int logsLastId,
  Object? logcat,
  int logcatLength,
  int logcatLastId,
});

/// One line of the merged stream.
///
/// The screen shows the two tails as they were written — the kernel's own log and this
/// process's Android logcat — with no categorisation: no source tag, no level badge, no
/// archive selector, just time and text in arrival order. The timestamp and the lowercased
/// search text are derived once here; the list rebuilds about every 300 ms.
class _LogRow {
  _LogRow(this.entry)
      : millis = (entry['receivedAt'] as num?)?.toInt() ?? 0,
        seq = (entry['seq'] as num?)?.toInt() ?? 0,
        message = entry['message']?.toString() ?? '',
        time = recordTime((entry['receivedAt'] as num?)?.toInt() ?? 0),
        exportTime = recordTime((entry['receivedAt'] as num?)?.toInt() ?? 0, withMilliseconds: true),
        haystack = (entry['message']?.toString() ?? '').toLowerCase();

  final Json entry;
  final int millis;
  final int seq;
  final String message;
  final String time;
  final String exportTime;
  final String haystack;

  /// Both tails number their entries from 1, so an id alone is ambiguous; `seq` is the
  /// process-local arrival counter the controller stamps on every row of either tail.
  String get key => 'row:$seq';
}

/// The app's log screen: the kernel's own log and this process's Android logcat in one
/// time-ordered stream.
///
/// There used to be a source switch (all / kernel / android / previous session) and a per-row
/// level badge that doubled as a display filter. Both are gone: the reader wants the whole
/// tail, and a badge narrows the screen to a category the line already spells out in its own
/// text. What stays is the toolbar's **recording** level (one choice for both tails), search,
/// export and pause-on-scroll.
class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});
  @override ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  String _query = '';
  /// The level both tails record at: the core's `logLevel` plus logcat's filter spec.
  /// `silent` is a client-side level (see [logRecordingLevels]) and is read back from the
  /// stored logcat level, so the label survives a restart.
  String _level = 'info';
  final _keywords = ValueNotifier<List<ScaffoldKeyword>>(const []);
  bool _levelLoaded = false;
  BoxController? _box;
  bool _exporting = false;
  /// The rows frozen when the reader scrolled away from the newest line; null while following.
  List<_LogRow>? _paused;
  /// The merged list is cheap to keep and expensive to rebuild (two tails, up to 2×512 rows
  /// plus a sort on every 300 ms tick), so hold it until an input actually moves. The last id
  /// catches a same-length batch replacing a window in place; identity catches a new list.
  _RowsKey? _rowsKey;
  List<_LogRow> _rows = const [];
  late final _scroll = ScrollController(initialScrollOffset: double.maxFinite);
  late final _physics = FollowEndScrollPhysics(isFollowing: () => _paused == null);

  /// The text the search field asks for.
  String get _search => _query;

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_levelLoaded) return;
    _levelLoaded = true;
    final box = ref.read(boxControllerProvider);
    _box = box;
    // The logcat tail's stored level is the recording level this screen shows; the host log
    // setting is the fallback for a profile that never opened the screen.
    final stored = box.logcatLevel;
    _level = stored != null && stored.isNotEmpty ? stored : _settingLevel(box);
    if (box.logcatLevel != _level) box.setLogcatLevel(_level);
    box.addListener(_boxChanged);
  }

  @override void dispose() {
    _box?.removeListener(_boxChanged);
    _keywords.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _settingLevel(BoxController box) {
    final value = box.settings['logLevel'];
    return value is String && value.isNotEmpty ? value : 'info';
  }

  void _boxChanged() {
    final box = _box;
    if (box == null) return;
    final stored = box.logcatLevel;
    if (stored == null || stored.isEmpty || stored == _level) return;
    setState(() => _level = stored);
  }

  /// Sets the level both tails record at: the core's `logLevel` setting (the kernel writes
  /// nothing below it; a running service reloads to apply it) and logcat's filter spec.
  /// `silent` has no core counterpart, so it is written as `panic` (the core's quietest)
  /// while the app drops every line it records itself. Rows already recorded are left alone —
  /// this is not a filter.
  void _chooseLevel(String level) {
    if (!mounted || level == _level) return;
    final box = ref.read(boxControllerProvider);
    setState(() => _level = level);
    box.setSetting('logLevel', level == 'silent' ? 'panic' : level, autoRestart: true);
    box.setLogcatLevel(level);
  }

  Future<void> _pickLevel() async {
    final picked = await showOptionSheet<String>(
      context: context,
      title: context.tr('Recording level'),
      note: context.tr('Changing it restarts the service to apply the core setting'),
      selected: _level,
      options: [for (final level in logRecordingLevels) (level, level)],
    );
    if (picked == null || !mounted) return;
    _chooseLevel(picked);
  }

  static int _lastId(List<Json> list) =>
      list.isEmpty ? -1 : (list.last['id'] as num?)?.toInt() ?? -1;

  /// Both tails in the order the list renders them (oldest first: the list is reversed, so
  /// the newest lands at the top). The wrap + sort is held until an input moves; unrelated
  /// preference rebuilds and the 300 ms log ticks then only re-run the search filter.
  List<_LogRow> _mergedRows(BoxController box) {
    final logs = box.logs, logcat = box.logcat;
    final key = (
      logs: logs,
      logsLength: logs.length,
      logsLastId: _lastId(logs),
      logcat: logcat,
      logcatLength: logcat.length,
      logcatLastId: _lastId(logcat),
    );
    final cached = _rowsKey;
    if (cached != null &&
        identical(cached.logs, key.logs) &&
        cached.logsLength == key.logsLength &&
        cached.logsLastId == key.logsLastId &&
        identical(cached.logcat, key.logcat) &&
        cached.logcatLength == key.logcatLength &&
        cached.logcatLastId == key.logcatLastId) {
      return _rows;
    }
    _rowsKey = key;
    return _rows = [
      for (final entry in logs) _LogRow(entry),
      for (final entry in logcat) _LogRow(entry),
    ]..sort(_compareRows);
  }

  /// Time order, with the shared arrival sequence breaking ties: `List.sort` is not stable
  /// and two lines written in the same millisecond must not swap places between rebuilds.
  static int _compareRows(_LogRow a, _LogRow b) {
    final byTime = a.millis.compareTo(b.millis);
    if (byTime != 0) return byTime;
    return a.seq.compareTo(b.seq);
  }

  void _pause() {
    if (_paused == null) setState(() => _paused = List.of(_mergedRows(ref.read(boxControllerProvider))));
  }

  void _resume() {
    if (_paused != null) setState(() => _paused = null);
  }

  /// Empties the Android logcat ring. The kernel tail keeps its history: it is the file the
  /// diagnostics export reads.
  Future<void> _clear() async {
    await ref.read(boxControllerProvider).logcatClear();
  }

  Future<void> _export(List<_LogRow> rows) async {
    if (_exporting || rows.isEmpty) return;
    final box = ref.read(boxControllerProvider);
    setState(() => _exporting = true);
    try {
      // The merged stream is exported as it reads: one line, one timestamp. The bridge
      // redacts like the native export — log lines carry URLs and keys.
      final saved = await box.documentSave(
        'B-box.log',
        rows.map((row) => '${row.exportTime} ${row.message}').join('\n'),
        redact: true,
      );
      // A cancelled system picker is neither an export nor an error.
      if (mounted && saved != null) box.showMessage(context.tr(saved == true ? 'Exported' : 'Export failed'));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override Widget build(BuildContext context) {
    // Both tails change under the merged view, so watch both. The controller is
    // read from the injected provider; no Riverpod write, no second source.
    final box = ref.watch(boxControllerProvider);
    ref.watch(logsProvider);
    ref.watch(logcatProvider);
    final words = _search.toLowerCase().trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final rows = (_paused ?? _mergedRows(box))
        .where((row) => words.every(row.haystack.contains))
        .toList();
    return BoxDataSubscription(
      // Two subscriptions, one page: each owns its tail and stops the host's sampling when
      // the screen goes away.
      data: BoxData.logs,
      child: BoxDataSubscription(
        data: BoxData.logcat,
        child: Scaffold(
          title: context.tr('Logs'),
          keywords: _keywords,
          searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
          iconActions: [
            IconButtonData(glyph: AppGlyphs.filter, tooltip: context.tr('Recording level'),
              onPressed: _pickLevel),
            IconButtonData(glyph: AppGlyphs.export, tooltip: context.tr('Export'),
              onPressed: rows.isEmpty || _exporting ? null : () => _export(rows)),
            IconButtonData(glyph: AppGlyphs.clearAll, tooltip: context.tr('Clear Android log'),
              // Availability follows the logcat ring, not the search filter: `_clear` empties
              // the whole ring, so a filter with no matches must not disable it.
              onPressed: box.logcat.isEmpty ? null : _clear),
          ],
          // The body is built below the scaffold's own insets: while the chip strip is shown
          // the header already sits where the app bar was, and the list must not add that gap
          // again (a filtered, short list used to open on a blank band).
          body: Builder(builder: (context) => NullStatusSwitcher(
            isEmpty: rows.isEmpty,
            isSearching: _search.trim().isNotEmpty,
            nullStatus: NullStatus(
              label: context.tr('No logs'),
              illustration: NullStatusIllustration.logs,
            ),
            child: rows.isEmpty
                ? const SizedBox.shrink()
                : Align(
                    alignment: Alignment.topCenter,
                    child: FloatingScrollbar(
                      controller: _scroll,
                      hintBuilder: (fraction) => rows[(fraction * (rows.length - 1)).round()].time,
                      child: ScrollToEndBox(
                        controller: _scroll,
                        enable: _paused == null,
                        onCancelToEnd: _pause,
                        onResumeToEnd: _resume,
                        child: SuperListView.separated(
                          controller: _scroll,
                          physics: _physics,
                          reverse: true,
                          shrinkWrap: true,
                          padding: EdgeInsets.only(bottom: 16 + context.bottomInset),
                          extentEstimation: recordListExtentEstimation,
                          itemCount: rows.length,
                          separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
                          itemBuilder: (context, index) {
                            final row = rows[index];
                            return RecordListItem(
                              key: ValueKey(row.key),
                              onTap: () {},
                              header: RecordHeader(children: [
                                if (row.millis > 0) RecordTimestamp(row.time),
                              ]),
                              body: SelectableText(row.message, style: RecordTextStyles.of(context).primary),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
          )),
        ),
      ),
    );
  }
}
