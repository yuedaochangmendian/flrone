import 'package:super_sliver_list/super_sliver_list.dart';
import '../widgets.dart';
import '../common/log_level.dart';
import '../components/record.dart';
import '../components/data_subscription.dart';

/// The Android logcat ring, as the host samples it (`BboxLogcat`).
///
/// The native side of the app — the VPN service, gomobile's Go runtime, the JNI shim —
/// writes to logcat, not to sing-box's own logger, so none of it reaches the Logs page.
/// The host has implemented `logs.logcat.visible` / `logs.logcat.clear` and a level-graded
/// ring for a while; this is the screen that reads it.
///
/// The wire entry shape is the one the channel already pushes
/// (`{id, level, message, receivedAt}`), which is why the rendering is the Logs page's
/// RecordListItem rather than a separate widget tree. Entries are plain logcat lines
/// (`mm-dd hh:mm:ss.mmm  pid  tid  level  tag: message`), so there is no
/// `LogPayload` splitting here: the whole line is the message.
///
/// The floor is also sent to the host, which passes it to logcat as a filter spec
/// (`*:W`), so raising the level stops the ring recording noise at all — otherwise the
/// 1500-entry tail keeps evicting the lines worth keeping between two looks.
class LogcatPage extends StatefulWidget {
  const LogcatPage({super.key});
  @override State<LogcatPage> createState() => _LogcatPageState();
}

class _LogcatPageState extends State<LogcatPage> {
  String _query = '';
  /// Minimum level shown and recorded; null keeps every level.
  String? _floor;
  bool _floorLoaded = false;
  /// Words tapped on a record's labels; the strip shows them beside the level chip.
  final _words = <String>[];
  final _chips = ValueNotifier<List<ScaffoldKeyword>>(const []);
  bool _exporting = false;
  /// The records frozen when the reader scrolled away from the newest line.
  List<Json>? _paused;
  late final _scroll = ScrollController(initialScrollOffset: double.maxFinite);
  late final _physics = FollowEndScrollPhysics(isFollowing: () => _paused == null);

  String get _search => [_query, ..._words].where((word) => word.trim().isNotEmpty).join(' ');

  @override void didChangeDependencies() {
    super.didChangeDependencies();
    if (_floorLoaded) return;
    _floorLoaded = true;
    // The controller owns the value the host records at, so a level chosen on a previous
    // visit is already the one the ring is sampling with.
    final stored = context.box.logcatLevel ?? context.box.preferences['logcatLevel'];
    _floor = stored is String && stored.isNotEmpty ? stored : null;
    _syncChips();
  }

  @override void dispose() {
    _chips.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _syncChips() {
    _chips.value = [
      if (_floor != null)
        ScaffoldKeyword(
          key: 'logcat:floor',
          label: '≥ $_floor',
          onPressed: _pickFloor,
          onDeleted: () => _chooseFloor(null),
        ),
      for (final word in _words)
        ScaffoldKeyword(
          key: 'logcat:word:$word',
          label: word,
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
    // Persists and restarts the host's tail at the new level when this page is watching.
    context.box.setLogcatLevel(level);
  }

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
    if (_paused == null) setState(() => _paused = List.of(context.box.logcat));
  }

  void _resume() {
    if (_paused != null) setState(() => _paused = null);
  }

  Future<void> _clear() async {
    await context.box.logcatClear();
  }

  Future<void> _export(List<Json> logs) async {
    if (_exporting || logs.isEmpty) return;
    final box = context.box;
    setState(() => _exporting = true);
    try {
      // The bridge redacts on save, exactly as the Logs export does: logcat lines
      // routinely carry package names, URLs and tokens.
      final saved = await box.documentSave('logcat.log',
          logs.map((line) => '${recordTime(line['receivedAt'])} [${line['level']}] ${line['message']}').join('\n'),
          redact: true);
      // A cancelled system picker is neither an export nor an error.
      if (mounted && saved != null) box.showMessage(context.tr(saved == true ? 'Exported' : 'Export failed'));
    } catch (error) {
      box.report(error);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final box = context.watchBox(BoxAspect.logcat);
    final words = _search.toLowerCase().trim().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final logs = (_paused ?? box.logcat).where((item) =>
      logLevelAtLeast(item['level'], _floor) &&
      words.every((word) => [item['level'], item['message']].join(' ').toLowerCase().contains(word)),
    ).toList();
    return BoxDataSubscription(
      // Opening this page is what starts the host's sampling; leaving it stops it.
      data: BoxData.logcat,
      child: Scaffold(
        title: context.tr('Android logcat'),
        keywords: _chips,
        searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
        iconActions: [
          IconButtonData(glyph: AppGlyphs.filter, tooltip: context.tr('Minimum level'),
            isSelected: _floor != null, onPressed: _pickFloor),
          IconButtonData(
            glyph: AppGlyphs.export,
            tooltip: context.tr('Export'),
            onPressed: logs.isEmpty || _exporting ? null : () => _export(logs),
          ),
          IconButtonData(
            glyph: AppGlyphs.clearAll,
            tooltip: context.tr('Clear'),
            onPressed: logs.isEmpty ? null : _clear,
          ),
        ],
        // Read inside the scaffold: with the chip strip shown it publishes a zero top inset,
        // and the list would otherwise add the app bar's height again as a blank band above
        // a filtered (short) list.
        body: Builder(builder: (context) => NullStatusSwitcher(
          isEmpty: logs.isEmpty,
          isSearching: _search.trim().isNotEmpty,
          nullStatus: NullStatus(label: context.tr('No logs'), illustration: NullStatusIllustration.logs),
          child: logs.isEmpty
              ? const SizedBox.shrink()
              : Align(
                  alignment: Alignment.topCenter,
                  child: FloatingScrollbar(
                    controller: _scroll,
                    hintBuilder: (fraction) =>
                        recordTime(logs[(fraction * (logs.length - 1)).round()]['receivedAt']),
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
                        padding: EdgeInsets.only(
                            top: context.contentTopPadding, bottom: 16 + context.bottomInset),
                        extentEstimation: recordListExtentEstimation,
                        itemCount: logs.length,
                        separatorBuilder: (_, _) => const SizedBox(height: recordListGap),
                        itemBuilder: (context, index) =>
                            _LogcatItem(log: logs[index], onLabel: _addWord, onLevel: _toggleFloor),
                      ),
                    ),
                  ),
                ),
        )),
      ),
    );
  }
}

class _LogcatItem extends StatelessWidget {
  const _LogcatItem({required this.log, required this.onLabel, required this.onLevel});

  final Json log;
  final ValueChanged<String> onLabel;
  final ValueChanged<String> onLevel;

  @override
  Widget build(BuildContext context) {
    final level = log['level'].toString().toLowerCase();
    final tone = switch (logLevelRank(level)) {
      3 => RecordTone.warning,
      >= 4 => RecordTone.error,
      _ => RecordTone.neutral,
    };
    final styles = RecordTextStyles.of(context);
    return RecordListItem(
      key: ValueKey(log['id']),
      onTap: () {},
      header: RecordHeader(children: [
        if ((log['receivedAt'] as num? ?? 0) > 0) RecordTimestamp(recordTime(log['receivedAt'])),
        RecordLabel(label: level, tone: tone, onPressed: () => onLevel(level)),
      ]),
      body: SelectableText(log['message'].toString(), style: styles.primary),
    );
  }
}
