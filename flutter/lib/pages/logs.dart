import 'package:super_sliver_list/super_sliver_list.dart';
import '../widgets.dart';
import '../common/log_level.dart';
import '../common/log_payload.dart';
import '../components/record.dart';
import '../components/data_subscription.dart';

/// Which tail the list shows: both live ones, one of them alone, or the previous session.
enum _LogSource { all, kernel, android, previous }

/// One row of the merged list, tagged with the tail it came from.
///
/// The two sources are disjoint — the core writes to its own log file and never to
/// logcat — so the merged view is a time-ordered union, not a dedupe. The tag is also
/// what keeps their ids apart: both tails number their entries from 1.
class _LogRow {
  const _LogRow(this.source, this.entry);

  final _LogSource source;
  final Json entry;

  int get id => (entry['id'] as num?)?.toInt() ?? -1;
  int get millis => (entry['receivedAt'] as num?)?.toInt() ?? 0;
  String get level => logLevelName(entry['level']);
  String get message => entry['message']?.toString() ?? '';

  /// A row's identity across both id spaces; the list reuses keys on rebuild.
  String get key => '${source.name}:$id';
}

/// The app's log screen: the kernel's own log and this process's Android logcat in one
/// place, because they answer different halves of "what happened" and the reader does not
/// always know in advance which half they need.
///
/// The switch is the whole difference between the two screens this replaces: "all" is a
/// time-ordered union with a source tag on every row, "kernel"/"android" isolate one tail
/// when the other is noise. Both are subscribed for the page's lifetime, so switching is
/// instant; the cost is the host's 500 ms logcat sampling while the screen is open, which
/// is what the merged view needs anyway.
///
/// Levels are a **recording** level, not a display filter: one control sets the core's
/// `log level` setting (the kernel writes nothing below it) and the filter spec the host
/// gives logcat, so both tails record at the chosen level. The list then shows whatever
/// was recorded — picking `warn` does not hide earlier `info` lines, it stops new ones.
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});
  @override State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  String _query = '';
  _LogSource _source = _LogSource.all;
  /// The level both sources record at (the core's `logLevel` setting).
  String _level = 'info';
  bool _levelLoaded = false;
  BoxController? _box;
  /// Words tapped on a record's labels; the strip shows them beside the level chip.
  final _words = <String>[];
  final _chips = ValueNotifier<List<ScaffoldKeyword>>(const []);
  bool _exporting = false;
  /// The previous session's tail, fetched the first time its segment is opened.
  List<Json>? _previous;
  bool _previousLoading = false;
  /// The rows frozen when the reader scrolled away from the newest line; null while following.
  List<_LogRow>? _paused;
  late final _scroll = ScrollController(initialScrollOffset: double.maxFinite);
  late final _physics = FollowEndScrollPhysics(isFollowing: () => _paused == null);

  static const _sourceLabels = {
    _LogSource.kernel: 'Kernel',
    _LogSource.android: 'Android',
    _LogSource.previous: 'Previous session',
  };

  /// The text the search field and the tapped labels ask for.
  String get _search => [_query, ..._words].where((word) => word.trim().isNotEmpty).join(' ');

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_levelLoaded) return;
    _levelLoaded = true;
    final box = _box = context.box;
    // The kernel setting is the single source of truth. The logcat ring has its own stored
    // level; it is brought in line here so both tails record at the level this screen shows.
    _level = _settingLevel(box);
    if (box.logcatLevel != _level) box.setLogcatLevel(_level);
    box.addListener(_boxChanged);
    _syncChips();
  }

  @override void dispose() {
    _box?.removeListener(_boxChanged);
    _chips.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String _settingLevel(BoxController box) {
    final value = box.settings['logLevel'];
    return value is String && value.isNotEmpty ? value : 'info';
  }

  /// Follows the setting when it is changed elsewhere (the settings page has the same row).
  void _boxChanged() {
    final box = _box;
    if (box == null) return;
    final level = _settingLevel(box);
    if (level == _level) return;
    _level = level;
    _syncChips();
    // Another screen changed the kernel level; the ring follows it too.
    if (box.logcatLevel != level) box.setLogcatLevel(level);
  }

  /// The strip the app bar shows: the recording level first, then the tapped words.
  void _syncChips() {
    _chips.value = [
      ScaffoldKeyword(
        key: 'logs:level',
        label: '${context.tr('Recording level')} $_level',
        onPressed: _pickLevel,
      ),
      for (final word in _words)
        ScaffoldKeyword(
          key: 'logs:word:$word',
          label: word,
          // A section break separates the level from the search words.
          startsSection: _words.isNotEmpty && word == _words.first,
          onDeleted: () => _removeWord(word),
        ),
    ];
  }

  void _addWord(String word) {
    if (_words.contains(word)) return;
    setState(() => _words.add(word));
    _syncChips();
  }

  void _removeWord(String word) {
    setState(() => _words.remove(word));
    _syncChips();
  }

  /// Sets the level both tails record at: the core's `logLevel` setting (the kernel writes
  /// nothing below it; a running service reloads to apply it) and logcat's filter spec.
  /// The rows already recorded are left alone — this is not a filter.
  void _chooseLevel(String level) {
    if (!mounted || level == _level) return;
    final box = context.box;
    setState(() => _level = level);
    _syncChips();
    box.setSetting('logLevel', level, autoRestart: true);
    box.setLogcatLevel(level);
  }

  Future<void> _pickLevel() async {
    final picked = await showOptionSheet<String>(
      context: context,
      title: context.tr('Recording level'),
      note: context.tr('Changing it restarts the service to apply the core setting'),
      selected: _level,
      options: [for (final level in coreLogLevels) (level, level)],
    );
    if (picked == null || !mounted) return;
    _chooseLevel(picked);
  }

  void _selectSource(_LogSource source) {
    if (source == _source) return;
    // A frozen snapshot belongs to the source that was showing; the new one starts live.
    setState(() {
      _source = source;
      _paused = null;
    });
    // The archive is read once per visit: the host parses the whole previous file.
    if (source == _LogSource.previous && _previous == null && !_previousLoading) {
      _loadPrevious();
    }
  }

  Future<void> _loadPrevious() async {
    final box = context.box;
    setState(() => _previousLoading = true);
    try {
      final batch = json(await box.logsPrevious());
      if (mounted) setState(() => _previous = rows(batch['entries']));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _previousLoading = false);
    }
  }

  /// Both live tails, in the order the list renders them (oldest first: the list is reversed,
  /// so the newest lands at the top). The previous session is its own archive, never merged:
  /// it is a different file, and mixing it in would double every line the live tail replayed.
  List<_LogRow> _sourceRows(BoxController box) => switch (_source) {
    _LogSource.kernel => [for (final entry in box.logs) _LogRow(_LogSource.kernel, entry)],
    _LogSource.android => [for (final entry in box.logcat) _LogRow(_LogSource.android, entry)],
    _LogSource.previous => [for (final entry in _previous ?? const <Json>[]) _LogRow(_LogSource.previous, entry)],
    _LogSource.all => [
        for (final entry in box.logs) _LogRow(_LogSource.kernel, entry),
        for (final entry in box.logcat) _LogRow(_LogSource.android, entry),
      ]..sort(_compareRows),
  };

  /// Time order, with the source and then the id breaking ties: `List.sort` is not stable
  /// and two lines written in the same millisecond must not swap places between rebuilds.
  /// Kernel timestamps are second-precision (the logged stamp) while logcat carries
  /// milliseconds, so a tie is normal at a busy second.
  static int _compareRows(_LogRow a, _LogRow b) {
    final byTime = a.millis.compareTo(b.millis);
    if (byTime != 0) return byTime;
    final bySource = a.source.index.compareTo(b.source.index);
    return bySource != 0 ? bySource : a.id.compareTo(b.id);
  }

  void _pause() {
    if (_paused == null) setState(() => _paused = List.of(_sourceRows(context.box)));
  }

  void _resume() {
    if (_paused != null) setState(() => _paused = null);
  }

  /// Only the logcat ring can be cleared from here: `logs.clear` truncates the core's log
  /// file, which the diagnostics export reads, so the kernel tail keeps its history.
  Future<void> _clear() async {
    if (_source == _LogSource.kernel) return;
    await context.box.logcatClear();
  }

  Future<void> _export(List<_LogRow> rows) async {
    if (_exporting || rows.isEmpty) return;
    final box = context.box;
    setState(() => _exporting = true);
    try {
      // Every line says which tail it came from, so a saved file stays readable after the
      // screen's switch has moved. The bridge redacts like the native export: log lines
      // carry URLs and keys.
      final saved = await box.documentSave(
        'B-box.log',
        rows.map((row) => '${recordTime(row.millis)} [${row.source.name}] [${row.level}] ${row.message}').join('\n'),
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
    final box = context.watchBox(BoxAspect.logs);
    // Both tails change under the merged view: `state` carries the kernel's push events,
    // `logs` the channel's batch. Watching `logs` alone would leave the kernel half stale
    // while the host is in charge of it.
    context.watchBox(BoxAspect.logcat);
    final words = _search.toLowerCase().trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    // The level is a recording level, not a filter: rows are only narrowed by the typed
    // words and the labels tapped on them.
    final rows = (_paused ?? _sourceRows(box)).where((row) =>
      words.every((word) => '${row.entry['level']} ${row.message}'.toLowerCase().contains(word)),
    ).toList();
    final showSource = _source == _LogSource.all;
    return BoxDataSubscription(
      // Two subscriptions, one page: each owns its tail and stops the host's sampling when
      // the screen goes away. Logcat is sampled even in the kernel-only view so switching
      // segments does not start from an empty ring.
      data: BoxData.logs,
      child: BoxDataSubscription(
        data: BoxData.logcat,
        child: Scaffold(
          title: context.tr('Logs'),
          keywords: _chips,
          searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
          iconActions: [
            IconButtonData(glyph: AppGlyphs.filter, tooltip: context.tr('Recording level'),
              onPressed: _pickLevel),
            IconButtonData(glyph: AppGlyphs.export, tooltip: context.tr('Export'),
              onPressed: rows.isEmpty || _exporting ? null : () => _export(rows)),
            IconButtonData(glyph: AppGlyphs.clearAll, tooltip: context.tr('Clear Android log'),
              onPressed: _source == _LogSource.kernel || rows.isEmpty ? null : _clear),
          ],
          // The body is built below the scaffold's own insets: while the chip strip is shown
          // the header already sits where the app bar was, and the list must not add that
          // gap again (a filtered, short list used to open on a blank band).
          body: Builder(builder: (context) => Column(children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, context.contentTopPadding, 16, 8),
              child: SegmentedControl<_LogSource>(
                key: const ValueKey('log-source'),
                segments: [
                  (_LogSource.all, context.tr('All')),
                  for (final source in [_LogSource.kernel, _LogSource.android, _LogSource.previous])
                    (source, context.tr(_sourceLabels[source]!)),
                ],
                value: _source,
                onChanged: _selectSource,
              ),
            ),
            Expanded(
              child: NullStatusSwitcher(
                isLoading: _previousLoading && _source == _LogSource.previous,
                loadingStatus: const Center(child: ActivityIndicator()),
                isEmpty: rows.isEmpty,
                isSearching: _search.trim().isNotEmpty,
                nullStatus: NullStatus(
                  label: context.tr(_source == _LogSource.previous ? 'No previous session' : 'No logs'),
                  illustration: NullStatusIllustration.logs,
                ),
                child: rows.isEmpty
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: Alignment.topCenter,
                        child: FloatingScrollbar(
                          controller: _scroll,
                          hintBuilder: (fraction) => recordTime(rows[(fraction * (rows.length - 1)).round()].millis),
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
                              itemBuilder: (context, index) => _LogItem(
                                row: rows[index],
                                showSource: showSource,
                                onLabel: _addWord,
                                onLevel: _chooseLevel,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ])),
        ),
      ),
    );
  }
}

class _LogItem extends StatelessWidget {
  const _LogItem({required this.row, required this.showSource, required this.onLabel, required this.onLevel});

  final _LogRow row;
  /// Only the merged view needs to say where a line came from.
  final bool showSource;
  final ValueChanged<String> onLabel;
  final ValueChanged<String> onLevel;

  @override Widget build(BuildContext context) {
    final level = row.level;
    final tone = switch (logLevelRank(level)) {
      3 => RecordTone.warning,
      >= 4 => RecordTone.error,
      _ => RecordTone.neutral,
    };
    final styles = RecordTextStyles.of(context);
    return RecordListItem(
      key: ValueKey(row.key),
      onTap: () {},
      header: RecordHeader(
        children: [
          if (row.millis > 0) RecordTimestamp(recordTime(row.millis)),
          RecordLabel(label: level, tone: tone, onPressed: () => onLevel(level)),
        ],
        trailing: showSource
            ? RecordLabel(label: context.tr(_LogsPageState._sourceLabels[row.source]!))
            : null,
      ),
      // Kernel lines carry a subsystem the payload splits out; logcat lines are already
      // `tag: message`, so the whole line is the message there. The previous session is a
      // core log file too, so it renders through the same payload.
      body: row.source == _LogSource.android
          ? SelectableText(row.message, style: styles.primary)
          : _LogBody(payload: LogPayload.of(row.entry)),
    );
  }
}

class _LogBody extends StatelessWidget {
  const _LogBody({required this.payload});

  final LogPayload payload;

  @override Widget build(BuildContext context) {
    final styles = RecordTextStyles.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(payload.message, style: styles.primary),
        if (payload.source.isNotEmpty) Text(payload.source, style: styles.secondary),
      ],
    );
  }
}
