import 'package:super_sliver_list/super_sliver_list.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets.dart';
import '../providers/box_providers.dart';
import '../common/log_level.dart';
import '../components/record.dart';
import '../components/data_subscription.dart';

/// One line of the merged stream.
///
/// The screen shows the two tails as they were written — the kernel's own log and this
/// process's Android logcat — with no categorisation: no source tag, no level badge, no
/// archive selector, just time and text in arrival order. The timestamp and the lowercased
/// search text are derived once here; the list rebuilds about every 300 ms at rest, while a
/// batch arriving during a route transition waits for it to settle (`updateWhenRouteSettled`).
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

class _LogsPageState extends ConsumerState<LogsPage> with RouteMotionHoldMixin<LogsPage> {
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
  /// The merged rows as last applied to the list. A controller batch only rebuilds them when
  /// it is applied: a batch arriving while the page's route moves waits, and the newest one
  /// is applied once the route settles.
  List<_LogRow> _rows = const [];
  /// Whether rows have ever been applied: only the page's first content skips the hold, so a
  /// pushed page never opens blank.
  bool _hasContent = false;
  bool _tailsLoaded = false;
  late final _scroll = ScrollController(initialScrollOffset: double.maxFinite);
  late final _physics = FollowEndScrollPhysics(isFollowing: () => _paused == null);

  /// The text the search field asks for.
  String get _search => _query;

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_tailsLoaded) {
      _tailsLoaded = true;
      // Rows already in the controller are the page's first content: it is applied at once
      // (while the arrival hold keeps a push at zero) instead of waiting for the route.
      showFirstContent(_applyTails);
    }
    // A replaced controller must move the listener too: build watches the new box, but
    // the old listener would keep the stale one alive and miss level changes.
    final box = ref.read(boxControllerProvider);
    if (!identical(box, _box)) {
      _box?.removeListener(_boxChanged);
      _box = box;
      box.addListener(_boxChanged);
    }
    if (_levelLoaded) return;
    _levelLoaded = true;
    // The logcat tail's stored level is the recording level this screen shows; the host log
    // setting is the fallback for a profile that never opened the screen.
    final stored = box.logcatLevel;
    _level = stored != null && stored.isNotEmpty ? stored : _settingLevel(box);
    if (box.logcatLevel != _level) box.setLogcatLevel(_level);
  }

  @override void dispose() {
    _box?.removeListener(_boxChanged);
    _keywords.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// A tail moved. The page's first content is shown at once; every later batch waits while
  /// the route moves, and several batches held through one transition replay as the newest.
  void _tailsChanged() {
    if (_hasContent) {
      updateWhenRouteSettled(_applyTails);
    } else {
      showFirstContent(_applyTails);
    }
  }

  /// Adopts both tails as they are now. The providers are read inside the callback, so a
  /// held batch replays the newest rows rather than the ones that arrived with it.
  void _applyTails() {
    if (!mounted) return;
    // A paused reader is looking at a frozen snapshot; merging a batch it will not see is
    // wasted work. _resume merges the tails as they are then.
    if (_paused != null) return;
    final rows = _merge(ref.read(logsProvider), ref.read(logcatProvider));
    setState(() {
      _rows = rows;
      _hasContent = _hasContent || rows.isNotEmpty;
    });
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

  /// Both tails in the order the list renders them (oldest first: the list is reversed, so
  /// the newest lands at the top), merged when a batch is applied.
  static List<_LogRow> _merge(List<Json> logs, List<Json> logcat) => [
        for (final entry in logs) _LogRow(entry),
        for (final entry in logcat) _LogRow(entry),
      ]..sort(_compareRows);

  /// Time order, with the shared arrival sequence breaking ties: `List.sort` is not stable
  /// and two lines written in the same millisecond must not swap places between rebuilds.
  static int _compareRows(_LogRow a, _LogRow b) {
    final byTime = a.millis.compareTo(b.millis);
    if (byTime != 0) return byTime;
    return a.seq.compareTo(b.seq);
  }

  void _pause() {
    // A reader action: it applies now, even while a batch is held behind a moving route.
    if (_paused == null) setState(() => _paused = List.of(_rows));
  }

  void _resume() {
    if (_paused == null) return;
    // Batches that arrived while paused were not merged (see _applyTails): adopt the tails
    // as they are now, in the same frame that unfreezes the list, so it never shows a gap.
    final rows = _merge(ref.read(logsProvider), ref.read(logcatProvider));
    setState(() {
      _paused = null;
      _rows = rows;
      _hasContent = _hasContent || rows.isNotEmpty;
    });
  }

  /// Empties the Android logcat ring. The kernel tail keeps its history: it is the file the
  /// diagnostics export reads.
  Future<void> _clear() async {
    // Irreversible and ring-wide, so it asks first like every other destructive action here.
    if (!await confirm(context, 'Clear the Android log?', action: 'Clear')) return;
    if (!mounted) return;
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
    // The controller is read from the injected provider; no Riverpod write, no second source.
    final box = ref.watch(boxControllerProvider);
    // Both tails are followed with listeners, not watched: a batch rebuilds the rows when it
    // is applied, so several arriving during one route transition cost one repaint, after it.
    ref.listen<List<Json>>(logsProvider, (_, _) => _tailsChanged());
    ref.listen<List<Json>>(logcatProvider, (_, _) => _tailsChanged());
    final words = _search.toLowerCase().trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final rows = (_paused ?? _rows)
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
