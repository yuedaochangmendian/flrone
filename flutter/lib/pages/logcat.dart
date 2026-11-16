import 'package:super_sliver_list/super_sliver_list.dart';
import '../widgets.dart';
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
class LogcatPage extends StatefulWidget {
  const LogcatPage({super.key});
  @override State<LogcatPage> createState() => _LogcatPageState();
}

class _LogcatPageState extends State<LogcatPage> {
  String _query = '';
  final _keywords = ValueNotifier<List<ScaffoldKeyword>>(const []);
  bool _exporting = false;
  /// The records frozen when the reader scrolled away from the newest line.
  List<Json>? _paused;
  late final _scroll = ScrollController(initialScrollOffset: double.maxFinite);
  late final _physics = FollowEndScrollPhysics(isFollowing: () => _paused == null);

  String get _search => [
    _query,
    ..._keywords.value.map((keyword) => '${keyword.key}'),
  ].where((word) => word.trim().isNotEmpty).join(' ');

  @override void initState() {
    super.initState();
    _keywords.addListener(_keywordsChanged);
  }

  @override void dispose() {
    _keywords.removeListener(_keywordsChanged);
    _keywords.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _keywordsChanged() => setState(() {});

  void _addFilter(String word) {
    if (_keywords.value.any((keyword) => keyword.key == word)) return;
    _keywords.value = [
      ..._keywords.value,
      ScaffoldKeyword(key: word, label: word, onDeleted: () => _removeFilter(word)),
    ];
  }

  void _removeFilter(String word) => _keywords.value =
      [for (final keyword in _keywords.value) if (keyword.key != word) keyword];

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
    final logs = (_paused ?? box.logcat)
        .where((item) => words.every((word) => [item['level'], item['message']].join(' ').toLowerCase().contains(word)))
        .toList();
    return BoxDataSubscription(
      // Opening this page is what starts the host's sampling; leaving it stops it.
      data: BoxData.logcat,
      child: Scaffold(
        title: context.tr('Android logcat'),
        keywords: _keywords,
        searchState: AppBarSearchState(onSearch: (query) => setState(() => _query = query)),
        iconActions: [
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
        body: NullStatusSwitcher(
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
                        itemBuilder: (context, index) => _LogcatItem(log: logs[index], onLabel: _addFilter),
                      ),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _LogcatItem extends StatelessWidget {
  const _LogcatItem({required this.log, required this.onLabel});

  final Json log;
  final ValueChanged<String> onLabel;

  @override
  Widget build(BuildContext context) {
    final level = log['level'].toString().toLowerCase();
    final tone = switch (level) {
      'w' || 'warn' || 'warning' => RecordTone.warning,
      'e' || 'error' || 'f' || 'fatal' || 'a' || 'assert' => RecordTone.error,
      _ => RecordTone.neutral,
    };
    final styles = RecordTextStyles.of(context);
    return RecordListItem(
      key: ValueKey(log['id']),
      onTap: () {},
      header: RecordHeader(children: [
        if ((log['receivedAt'] as num? ?? 0) > 0) RecordTimestamp(recordTime(log['receivedAt'])),
        RecordLabel(label: level, tone: tone, onPressed: () => onLabel(level)),
      ]),
      body: SelectableText(log['message'].toString(), style: styles.primary),
    );
  }
}
