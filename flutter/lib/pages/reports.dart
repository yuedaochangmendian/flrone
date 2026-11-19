import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

String reportTitle(String kind) => {'crash': 'Crash reports', 'oom': 'Memory reports', 'power': 'Power reports'}[kind]!;

class ReportsPage extends ConsumerStatefulWidget {
  const ReportsPage({super.key, required this.kind});
  final String kind;
  @override ConsumerState<ReportsPage> createState() => _ReportsPageState();
}
class _ReportsPageState extends ConsumerState<ReportsPage> {
  Future<List<Json>>? _reports;
  Future<List<Json>> _load() async => rows(await ref.read(boxControllerProvider).reportList(widget.kind));
  @override void didChangeDependencies() { super.didChangeDependencies(); _reports ??= _load(); }
  void _refresh() => setState(() => _reports = _load());
  @override Widget build(BuildContext context) => Scaffold(title: context.tr(reportTitle(widget.kind)), iconActions: [
    IconButtonData(glyph: AppGlyphs.refresh, onPressed: _refresh, tooltip: context.tr('Refresh')),
    IconButtonData(glyph: AppGlyphs.delete, tooltip: context.tr('Clear'), onPressed: () async {
      final box = ref.read(boxControllerProvider);
      if (await confirm(context, 'Delete all reports?')) {
        await box.reportClear(widget.kind);
        if (mounted) _refresh();
      }
    }),
  ], body: FutureBuilder<List<Json>>(future: _reports, builder: (context, snapshot) => ListView(
    padding: boxPagePadding(context),
    children: [
      if (snapshot.hasError) ErrorState(snapshot.error!, retry: _refresh),
      if (!snapshot.hasData && !snapshot.hasError) const Center(child: ActivityIndicator()),
      if (snapshot.data?.isEmpty == true) const EmptyState('No reports'),
      for (final report in snapshot.data ?? <Json>[]) ListItem(
        title: Text(localDate(report['date'])), subtitle: Text(report['id'].toString()),
        leading: GlyphIcon(report['read'] == true ? AppGlyphs.profiles : AppGlyphs.info),
        onTap: () async {
          await openPage(context, ReportDetail(kind: widget.kind, id: report['id'].toString()));
          if (mounted) _refresh();
        },
      ),
    ],
  )));
}

class ReportDetail extends ConsumerStatefulWidget {
  const ReportDetail({super.key, required this.kind, required this.id});
  final String kind, id;
  @override ConsumerState<ReportDetail> createState() => _ReportDetailState();
}
class _ReportDetailState extends ConsumerState<ReportDetail> {
  Future<List<Json>>? _files;
  bool _config = false, _logs = true, _encrypt = true, _busy = false;
  Json get _args => {'kind': widget.kind, 'id': widget.id};
  @override void didChangeDependencies() { super.didChangeDependencies(); _files ??= ref.read(boxControllerProvider).reportFiles(_args).then(rows); }
  @override Widget build(BuildContext context) => BoxPage(title: reportTitle(widget.kind), loading: _busy, actions: [
    IconButtonData(glyph: AppGlyphs.delete, tooltip: context.tr('Delete'), onPressed: () async {
      final box = ref.read(boxControllerProvider);
      if (await confirm(context, 'Delete', message: widget.id) && await box.reportDelete(_args) && context.mounted) Navigator.pop(context);
    }),
  ], children: [
    FutureBuilder<List<Json>>(future: _files, builder: (context, snapshot) => snapshot.hasError ? ErrorState(snapshot.error!) : generateGroup([
      for (final file in snapshot.data ?? <Json>[]) ListItem(title: Text(file['label'].toString()), subtitle: Text(bytes(file['size'] as num? ?? 0)),
        onTap: () => file['kind'] == 'PROFILE'
          ? ref.read(boxControllerProvider).reportSave({..._args, 'name': file['name']})
          : openPage(context, ReportText(args: {..._args, 'name': file['name']}, title: file['label'].toString())),
        trailing: IconButton(tooltip: context.tr('Export'), icon: const GlyphIcon(AppGlyphs.arrowDown),
          onPressed: () => ref.read(boxControllerProvider).reportSave({..._args, 'name': file['name']}))),
    ])),
    generateSection(title: context.tr('Export'), items: [
      ListItem.toggle(title: Text(context.tr('Include configuration')), value: _config, onChanged: (v) => setState(() => _config = v)),
      ListItem.toggle(title: Text(context.tr('Include logs')), value: _logs, onChanged: (v) => setState(() => _logs = v)),
      ListItem.toggle(title: Text(context.tr('Encrypt for sing-box maintainers')), value: _encrypt, onChanged: (v) => setState(() => _encrypt = v)),
      ListItem(title: Text(context.tr('Export archive')), onTap: _busy ? null : () async {
        setState(() => _busy = true);
        await ref.read(boxControllerProvider).reportExport({..._args, 'config': _config, 'logs': _logs, 'encrypt': _encrypt});
        if (mounted) setState(() => _busy = false);
      }),
    ]),
  ]);
}

class ReportText extends ConsumerStatefulWidget {
  const ReportText({super.key, required this.args, required this.title});
  final Json args;
  final String title;
  @override ConsumerState<ReportText> createState() => _ReportTextState();
}
class _ReportTextState extends ConsumerState<ReportText> {
  Future<dynamic>? _content;
  @override void didChangeDependencies() { super.didChangeDependencies(); _content ??= ref.read(boxControllerProvider).reportRead(widget.args); }
  @override Widget build(BuildContext context) => BoxPage(title: widget.title, children: [
    FutureBuilder<dynamic>(future: _content, builder: (context, snapshot) => snapshot.hasError ? ErrorState(snapshot.error!)
      : snapshot.hasData ? SelectableText(snapshot.data.toString(), style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12))
      : const Center(child: ActivityIndicator())),
  ]);
}
