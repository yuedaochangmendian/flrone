import 'package:super_sliver_list/super_sliver_list.dart';
import '../widgets.dart';
import '../common/log_level.dart';
import '../common/log_payload.dart';
import '../components/record.dart';
import '../components/data_subscription.dart';

/// FlClash's log view, carried over as-is: one export action, an empty state, a scrollbar that
/// names the record at the thumb, and a list that follows the newest line until the reader
/// scrolls away from it. The records themselves are rendered by [_LogItem] / [_LogBody], which
/// keep FlClash's shape and parse this fork's sing-box / Xray lines instead of mihomo's.
///
/// This is the kernel's own log. A record's level is a floor, not a keyword: tapping `info`
/// keeps info and above, so a debug line whose *message* happens to contain the word "info"
/// no longer slips through a filter that reads `info` (it used to — the level was turned into
/// search text and matched inside the message).
class LogsPage extends StatefulWidget {
  const LogsPage({super.key});
  @override State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  /// Where the chosen floor is kept between visits, beside the other UI preferences.
  static const _levelPreference = 'logsLevel';

  String _query = '';
  /// Minimum level the list shows; null keeps every level.
  String? _floor;
  bool _floorLoaded = false;
  /// Words tapped on a record's labels; the strip shows them beside the level chip.
  final _words = <String>[];
  final _chips = ValueNotifier<List<ScaffoldKeyword>>(const []);
  bool _exporting = false;
  /// The records frozen when the reader scrolled away from the newest line; null while following.
  List<Json>? _paused;
  late final _scroll = ScrollController(initialScrollOffset: double.maxFinite);
  late final _physics = FollowEndScrollPhysics(isFollowing: () => _paused == null);

  /// The text the search field and the tapped labels ask for.
  String get _search => [_query, ..._words].where((word) => word.trim().isNotEmpty).join(' ');

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_floorLoaded) return;
    _floorLoaded = true;
    final stored = context.box.preferences[_levelPreference];
    _floor = stored is String && stored.isNotEmpty ? stored : null;
    _syncChips();
  }

  @override void dispose() {
    _chips.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// The strip the app bar shows: the level floor first, then the tapped words.
  void _syncChips() {
    _chips.value = [
      if (_floor != null)
        ScaffoldKeyword(
          key: '$_levelPreference:floor',
          label: '≥ $_floor',
          onPressed: _pickFloor,
          onDeleted: () => _chooseFloor(null),
        ),
      for (final word in _words)
        ScaffoldKeyword(
          key: '$_levelPreference:word:$word',
          label: word,
          // A section break separates the floor from the search words.
          startsSection: _floor != null && word == _words.first,
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

  void _chooseFloor(String? level) {
    if (!mounted) return;
    setState(() => _floor = level);
    _syncChips();
    context.box.setPreference(_levelPreference, level ?? '');
  }

  /// A level badge is a shortcut for the floor: tap it to keep that level and above, tap the
  /// same one again to stop filtering.
  void _toggleFloor(String level) => _chooseFloor(_floor == level ? null : level);

  Future<void> _pickFloor() async {
    final picked = await showOptionSheet<String>(
      context: context,
      title: context.tr('Minimum level'),
      selected: _floor ?? '',
      options: [('', context.tr('All levels')), for (final level in logLevelNames) (level, level)],
    );
    if (picked == null || !mounted) return;
    _chooseFloor(picked.isEmpty ? null : picked);
  }

  void _pause() {
    if (_paused == null) setState(() => _paused = List.of(context.box.logs));
  }

  void _resume() {
    if (_paused != null) setState(() => _paused = null);
  }

  Future<void> _export(List<Json> logs) async {
    if (_exporting || logs.isEmpty) return;
    final box = context.box;
    setState(() => _exporting = true);
    try {
      // Log lines carry URLs and keys; the bridge redacts like the native export.
      final saved = await box.documentSave('B-box.log',
        logs.map((line) => '${recordTime(line['receivedAt'])} [${line['level']}] ${line['message']}').join('\n'), redact: true);
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
    final words = _search.toLowerCase().trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final logs = (_paused ?? box.logs).where((item) =>
      logLevelAtLeast(item['level'], _floor) &&
      words.every((word) => [item['level'], item['message']].join(' ').toLowerCase().contains(word)),
    ).toList();
    return BoxDataSubscription(data: BoxData.logs, child: Scaffold(
      title: context.tr('Logs'),
      keywords: _chips,
      searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
      iconActions: [
        IconButtonData(glyph: AppGlyphs.filter, tooltip: context.tr('Minimum level'),
          isSelected: _floor != null, onPressed: _pickFloor),
        IconButtonData(glyph: AppGlyphs.export, tooltip: context.tr('Export'),
          onPressed: logs.isEmpty || _exporting ? null : () => _export(logs)),
      ],
      // The body is built below the scaffold's own insets: while the chip strip is shown the
      // header already sits where the app bar was, and the list must not add that gap again.
      // Read here, outside this build's context, `contentTopPadding` still answers with the
      // bar's height and a filtered (short) list opened on a blank band the height of the bar.
      body: Builder(builder: (context) => NullStatusSwitcher(
        isEmpty: logs.isEmpty,
        isSearching: _search.trim().isNotEmpty,
        nullStatus: NullStatus(label: context.tr('No logs'), illustration: NullStatusIllustration.logs),
        child: logs.isEmpty ? const SizedBox.shrink() : Align(
          alignment: Alignment.topCenter,
          child: FloatingScrollbar(
            controller: _scroll,
            hintBuilder: (fraction) => recordTime(logs[(fraction * (logs.length - 1)).round()]['receivedAt']),
            child: ScrollToEndBox(
              controller: _scroll, enable: _paused == null,
              onCancelToEnd: _pause, onResumeToEnd: _resume,
              child: SuperListView.separated(
                controller: _scroll, physics: _physics, reverse: true, shrinkWrap: true,
                // The body starts at the top of the window with the app bar floating over it.
                padding: EdgeInsets.only(top: context.contentTopPadding, bottom: 16 + context.bottomInset),
                extentEstimation: recordListExtentEstimation,
                itemCount: logs.length,
                separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
                itemBuilder: (context, index) => _LogItem(log: logs[index], onLabel: _addWord, onLevel: _toggleFloor),
              ),
            ),
          ),
        ),
      )),
    ));
  }
}

class _LogItem extends StatelessWidget {
  const _LogItem({required this.log, required this.onLabel, required this.onLevel});

  final Json log;
  final ValueChanged<String> onLabel;
  final ValueChanged<String> onLevel;

  @override Widget build(BuildContext context) {
    final level = log['level'].toString().toLowerCase();
    final tone = switch (logLevelRank(level)) {
      3 => RecordTone.warning,
      >= 4 => RecordTone.error,
      _ => RecordTone.neutral,
    };
    return RecordListItem(
      key: ValueKey(log['id']),
      onTap: () {},
      header: RecordHeader(children: [
        if ((log['receivedAt'] as num? ?? 0) > 0) RecordTimestamp(recordTime(log['receivedAt'])),
        RecordLabel(label: level, tone: tone, onPressed: () => onLevel(level)),
      ]),
      body: _LogBody(payload: LogPayload.of(log)),
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
