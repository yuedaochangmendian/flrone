import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';
import '../widgets.dart';
import '../core/log_batch.dart';
import '../core/log_payload.dart';
import '../providers/box_providers.dart';
import '../common/log_level.dart';
import '../components/record.dart';
import '../components/data_subscription.dart';

/// One line of the merged stream.
///
/// The screen shows the two tails as they were written — the kernel's own log and this
/// process's Android logcat — with the level as a small tag, the timestamp and the text in
/// arrival order. The timestamp and the lowercased search text are derived once here; the
/// list rebuilds about every 300 ms at rest, while a batch arriving during a route transition
/// waits for it to settle (`updateWhenRouteSettled`).
class _LogRow {
  _LogRow(this.entry)
      : millis = (entry['receivedAt'] as num?)?.toInt() ?? 0,
        seq = (entry['seq'] as num?)?.toInt() ?? 0,
        level = logLevelName(entry['level']),
        message = entry['message']?.toString() ?? '',
        time = recordTime((entry['receivedAt'] as num?)?.toInt() ?? 0),
        exportTime = recordTime((entry['receivedAt'] as num?)?.toInt() ?? 0, withMilliseconds: true),
        haystack = (entry['message']?.toString() ?? '').toLowerCase();

  final Json entry;
  final int millis;
  final int seq;
  final String level;
  final String message;
  final String time;
  final String exportTime;
  final String haystack;

  /// Parsed lazily: only a visible row pays for the route/dial regexes.
  LogPayload? _payload;
  LogPayload get payload => _payload ??= LogPayload.parse(message);

  /// Both tails number their entries from 1, so an id alone is ambiguous; `seq` is the
  /// process-local arrival counter the controller stamps on every row of either tail.
  String get key => 'row:$seq';
}

/// The app's log screen: the kernel's own log and this process's Android logcat in one
/// time-ordered stream.
///
/// There used to be a source switch (all / kernel / android / previous session), a per-row
/// level badge that doubled as a display filter, a recording-level picker and a lifecycle
/// diagnostic toggle. The screen keeps what reading a tail needs: the two merged sources,
/// the level tag, search, level facets, pause-on-scroll, export and clear.
class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});
  @override ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage>
    with RouteMotionHoldMixin<LogsPage> {
  /// Above this many rows the list is a full viewport; shrink-wrapping only
  /// exists so a short tail starts directly under the bar.
  static const _shrinkWrapLimit = 40;

  String _query = '';
  /// Selected display levels; empty means every level. This is a view filter;
  /// the recording level is the General → Logs setting.
  final _levels = <String>{};
  final _keywords = ValueNotifier<List<ScaffoldKeyword>>(const []);
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
    if (_tailsLoaded) return;
    _tailsLoaded = true;
    // Rows already in the controller are the page's first content: it is applied at once
    // (while the arrival hold keeps a push at zero) instead of waiting for the route.
    showFirstContent(_applyTails);
  }

  @override void dispose() {
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

  /// The merged rows of both tails as recorded. Closing a source stops it from
  /// producing new rows; it never rewrites the history already on screen.
  List<_LogRow> _mergeTails() => _merge(ref.read(logsProvider), ref.read(logcatProvider));

  /// Adopts both tails as they are now. The providers are read inside the callback, so a
  /// held batch replays the newest rows rather than the ones that arrived with it.
  void _applyTails() {
    if (!mounted) return;
    final rows = _mergeTails();
    setState(() {
      _rows = rows;
      _hasContent = _hasContent || rows.isNotEmpty;
      // A paused reader keeps the head it was reading while the tail keeps
      // arriving (FlClash's pausedMaxLogsLength); it never jumps to newest.
      final paused = _paused;
      if (paused != null) _paused = _retainTrimmedHead(paused, rows, pausedLogLimit);
    });
    _updateKeywords();
  }

  /// Level facet chips: `all` plus one chip per level with its row count. This
  /// is the display filter; the recording level stays on the toolbar.
  void _updateKeywords() {
    if (_rows.isEmpty) {
      _keywords.value = const [];
      return;
    }
    final counts = <String, int>{};
    for (final row in _rows) {
      counts[row.level] = (counts[row.level] ?? 0) + 1;
    }
    final levels = [
      for (final level in coreLogLevels)
        if (counts[level] != null) level,
    ];
    _keywords.value = [
      ScaffoldKeyword(
        key: 'all',
        label: 'all ${_rows.length}',
        selected: _levels.isEmpty,
        onPressed: () {
          setState(_levels.clear);
          _updateKeywords();
        },
      ),
      for (final level in levels)
        ScaffoldKeyword(
          key: level,
          label: '$level ${counts[level]}',
          selected: _levels.contains(level),
          onPressed: () {
            setState(() {
              if (!_levels.remove(level)) _levels.add(level);
            });
            _updateKeywords();
          },
        ),
    ];
  }

  void _showDetails(_LogRow row) {
    showAppDialog<void>(
      context,
      child: Builder(builder: (dialogContext) => AlertDialog(
        title: row.level,
        child: SingleChildScrollView(
          child: SelectableText(row.message, style: RecordTextStyles.of(dialogContext).primary),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(dialogContext.tr('Close')))],
      )),
    );
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
    // Adopt the tails as they are now in the same frame that unfreezes the list.
    final rows = _mergeTails();
    setState(() {
      _paused = null;
      _rows = rows;
      _hasContent = _hasContent || rows.isNotEmpty;
    });
    _updateKeywords();
  }

  /// Keeps the head a paused reader was looking at when the ring trimmed it,
  /// then appends the newest tail (FlClash's `retainTrimmedHead`).
  static List<_LogRow> _retainTrimmedHead(
    List<_LogRow> current,
    List<_LogRow> latest,
    int limit,
  ) {
    if (current.isEmpty || latest.isEmpty) return latest;
    final first = latest.first;
    final index = current.indexWhere((row) => row.key == first.key);
    if (index == 0) return latest;
    final head = index > 0 ? current.sublist(0, index) : current;
    final merged = [...head, ...latest];
    return merged.length > limit ? merged.sublist(merged.length - limit) : merged;
  }

  /// Empties both tails: the kernel's core.log and the Android logcat ring.
  Future<void> _clear() async {
    // Irreversible, so it asks first like every other destructive action here.
    if (!await confirm(context, 'Clear all logs?', action: 'Clear')) return;
    if (!mounted) return;
    final box = ref.read(boxControllerProvider);
    try {
      await Future.wait([box.logsClear(), box.logcatClear()]);
      if (mounted) showAppBanner(context, context.tr('Done'));
    } catch (error) {
      box.report(error);
      // The channel can refuse the clear (host unavailable, permission denied);
      // say so instead of leaving the rows silently on screen.
      if (mounted) {
        showAppBanner(context, '${context.tr('Error')}: ${BoxController.describe(error)}',
          level: BannerLevel.error);
      }
    }
  }

  Future<void> _export(List<_LogRow> rows) async {
    if (_exporting || rows.isEmpty) return;
    final box = ref.read(boxControllerProvider);
    setState(() => _exporting = true);
    try {
      // The merged stream is exported as it reads: one line, one timestamp. The bridge
      // redacts like the native export — log lines carry URLs and keys.
      final saved = await box.documentSave(
        'Flrone.log',
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
        .where((row) => (_levels.isEmpty || _levels.contains(row.level)) && words.every(row.haystack.contains))
        .toList();
    final Widget content = Scaffold(
          title: context.tr('Logs'),
          keywords: _keywords,
          searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
          iconActions: [
            IconButtonData(glyph: AppGlyphs.clearAll, tooltip: context.tr('Clear all logs'),
              // Availability follows the two tails, not the search filter: `_clear`
              // empties both rings, so a filter with no matches must not disable it.
              onPressed: box.logcat.isEmpty && box.logs.isEmpty ? null : _clear),
            IconButtonData(glyph: AppGlyphs.export, tooltip: context.tr('Export'),
              onPressed: _rows.isEmpty || _exporting ? null : () => _export(_rows)),
          ],
          // The body is built below the scaffold's own insets: while the chip strip is shown
          // the header already sits where the app bar was, and the list must not add that gap
          // again (a filtered, short list used to open on a blank band).
          body: Builder(builder: (context) => NullStatusSwitcher(
            isEmpty: rows.isEmpty,
            isSearching: _search.trim().isNotEmpty || _levels.isNotEmpty,
            nullStatus: NullStatus(
              label: context.tr('No logs'),
              illustration: NullStatusIllustration.logs,
            ),
            child: rows.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    // The list runs under the floating toolbar; leave the bar's height
                    // above it so the newest rows are not hidden behind the title/search.
                    padding: EdgeInsets.only(top: context.contentTopPadding),
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: FloatingScrollbar(
                        controller: _scroll,
                        hintBuilder: (fraction) {
                          if (rows.isEmpty) return '';
                          final index = (fraction * (rows.length - 1))
                              .round()
                              .clamp(0, rows.length - 1);
                          return rows[index].time;
                        },
                        child: ScrollToEndBox(
                          controller: _scroll,
                          enable: _paused == null,
                          onCancelToEnd: _pause,
                          onResumeToEnd: _resume,
                          child: SuperListView.separated(
                            controller: _scroll,
                            physics: _physics,
                            reverse: true,
                            // A short tail hugs the toolbar; a long one (both rings can
                            // hold logRingLimit lines each) must stay lazy. Shrink-wrapping
                            // a thousand SelectableText rows lays every one out on each
                            // batch, which is what turned one diagnostic frame into a
                            // multi-hundred-ms rebuild on a phone. Past the threshold the
                            // viewport is already full, so shrinkWrap changes nothing there.
                            shrinkWrap: rows.length <= _shrinkWrapLimit,
                            padding: EdgeInsets.only(bottom: 16 + context.bottomInset),
                            itemCount: rows.length,
                            extentEstimation: (_, _) => 96.0,
                            separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
                            itemBuilder: (context, index) {
                              final row = rows[index];
                              final tone = switch (row.level) {
                                'warn' => RecordTone.warning,
                                'error' || 'fatal' || 'panic' => RecordTone.error,
                                _ => RecordTone.neutral,
                              };
                              return RecordListItem(
                                key: ValueKey(row.key),
                                header: RecordHeader(children: [
                                  if (row.millis > 0) RecordTimestamp(row.time),
                                  RecordLabel(label: row.level, tone: tone),
                                ]),
                                body: _LogBody(row: row),
                                onTap: () => _showDetails(row),
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
  )));
    return BoxDataSubscription(
      data: BoxData.logs,
      child: BoxDataSubscription(data: BoxData.logcat, child: content),
    );
  }
}

/// One log row's body: a parsed routing/dial line reads as destination, rule,
/// proxy and error (FlClash's LogPayload layout); everything else keeps its
/// original text.
class _LogBody extends StatelessWidget {
  const _LogBody({required this.row});
  final _LogRow row;

  @override Widget build(BuildContext context) {
    final route = row.payload.route;
    final styles = RecordTextStyles.of(context);
    if (route == null) return SelectableText(row.message, style: styles.primary);
    final scheme = context.colorScheme;
    final source = [route.source, route.sourceDetail].where((text) => text.isNotEmpty).join('  ·  ');
    return SelectableText.rich(TextSpan(children: [
      TextSpan(text: route.destination, style: styles.title),
      if (route.error.isNotEmpty)
        TextSpan(text: '\n${route.error}', style: styles.secondary.copyWith(color: scheme.error)),
      const TextSpan(text: '\n'),
      if (route.rule.isNotEmpty) ...[
        TextSpan(text: route.rule, style: styles.secondary),
        const TextSpan(text: ' → ', style: TextStyle(fontFamily: 'JetBrainsMono')),
      ],
      TextSpan(text: route.proxy, style: styles.primary.copyWith(color: scheme.primary)),
      if (source.isNotEmpty) TextSpan(text: '\n$source', style: styles.secondary),
    ]));
  }
}
