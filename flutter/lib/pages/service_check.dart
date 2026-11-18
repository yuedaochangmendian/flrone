import '../widgets.dart';

/// Service availability check: asks the kernel to reach a set of common
/// services through the running instance's exit and reports, per service,
/// whether it is available, restricted, blocked or unknown.
///
/// The probe and the definitions document live in the pinned core; the page
/// only drives the synchronous `serviceTest` action over the FFI action bus
/// and renders its JSON answer. No channel fallback exists for this action.
class ServiceCheckPage extends StatefulWidget {
  const ServiceCheckPage({super.key});

  @override State<ServiceCheckPage> createState() => _ServiceCheckPageState();
}

class _ServiceCheckPageState extends State<ServiceCheckPage> {
  bool _running = false;
  String? _error;
  List<Json>? _results;
  List<Json>? _ipInfo;
  bool _hasRun = false;

  /// Friendly category names; unknown ids fall back to the raw id.
  static const _categoryNames = <String, String>{
    'ai': 'AI',
    'streaming': 'Streaming',
    'social': 'Social',
    'reputation': 'IP reputation',
  };

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _running = true;
      _error = null;
      _results = null;
      _ipInfo = null;
      _hasRun = true;
    });
    try {
      final value = await context.box.serviceTest(const {});
      if (!mounted) return;
      final payload = json(value);
      final rawResults = payload['results'];
      final results = <Json>[];
      if (rawResults is List) {
        for (final item in rawResults) {
          if (item is Map) results.add(Map<String, dynamic>.from(item));
        }
      }
      final checks = <Json>[];
      final infos = <Json>[];
      for (final entry in results) {
        final error = '${entry['error'] ?? ''}'.trim();
        if (error.isNotEmpty) {
          checks.add({
            'name': entry['tag'] ?? '',
            'status': 'failed',
            'note': error,
          });
          continue;
        }
        final result = json(entry['result']);
        for (final item in (result['checks'] as List? ?? const [])) {
          if (item is Map) checks.add(Map<String, dynamic>.from(item));
        }
        for (final item in (result['ip_info'] as List? ?? const [])) {
          if (item is Map) infos.add(Map<String, dynamic>.from(item));
        }
      }
      setState(() {
        _results = checks;
        _ipInfo = infos;
      });
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _results;
    return BoxPage(
      title: 'Service check',
      loading: _running,
      error: _error,
      children: [
        BoxPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              PanelTitle('Service check', AppGlyphs.verified),
              Text(
                context.tr('Check common services through the running exit'),
                style: context.listSubtitleStyle,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Center(
            child: TonalButton(
              glyph: AppGlyphs.bolt,
              label: context.tr(_running ? 'Checking services…' : 'Run check'),
              onPressed: _running ? null : _run,
            ),
          ),
        ),
        if (result == null && !_hasRun)
          EmptyState(
            'No check results yet',
            message: 'Run the check to see which services the current exit can reach.',
          )
        else if (result != null && result.isEmpty)
          EmptyState('No services were checked')
        else if (result != null) ..._resultSections(result),
      ],
    );
  }

  List<Widget> _resultSections(List<Json> checks) {
    final groups = <String, List<Json>>{};
    for (final check in checks) {
      final category = '${check['category'] ?? ''}';
      groups.putIfAbsent(category, () => []).add(check);
    }
    final sections = <Widget>[];
    for (final entry in groups.entries) {
      final title = _categoryNames[entry.key] ?? entry.key;
      sections.add(BoxPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            PanelTitle(title.isEmpty ? 'Other' : title, AppGlyphs.rules),
            for (final check in entry.value) _checkRow(check),
          ],
        ),
      ));
    }
    final info = _ipInfo ?? const <Json>[];
    if (info.isNotEmpty) {
      sections.add(BoxPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            PanelTitle('Exit IP', AppGlyphs.locate),
            for (final item in info) _ipInfoBlock(item),
          ],
        ),
      ));
    }
    return sections;
  }

  Widget _checkRow(Json check) {
    final name = '${check['name'] ?? check['id'] ?? ''}'.trim();
    final status = '${check['status'] ?? ''}'.trim();
    final region = '${check['region'] ?? ''}'.trim();
    final note = '${check['note'] ?? ''}'.trim();
    final detail = <String>[
      if (region.isNotEmpty) '${context.tr('Region')}: $region',
      if (note.isNotEmpty) note,
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Row(children: [
          Expanded(child: Text(name.isEmpty ? '—' : name, style: context.listTitleStyle)),
          Text(_statusLabel(status), style: context.listSubtitleStyle),
        ]),
        if (detail.isNotEmpty) Text(detail, style: context.listSubtitleStyle),
      ],
    );
  }

  Widget _ipInfoBlock(Json item) {
    String value(Object? raw) {
      final text = '${raw ?? ''}'.trim();
      return text.isEmpty ? '—' : text;
    }

    final provider = value(item['provider']);
    final ip = value(item['ip']);
    final country = value(item['country_code']);
    final asn = value(item['asn']);
    final org = value(item['org']);
    final type = value(item['type']);
    final risk = item['risk_score'];
    final flags = item['flags'];
    final error = value(item['error']);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text('$provider · $ip', style: context.listTitleStyle),
        Text(
          [
            '${context.tr('Country')}: $country',
            '${context.tr('ASN')}: $asn',
            '${context.tr('Organization')}: $org',
            '${context.tr('Type')}: $type',
            '${context.tr('Risk score')}: ${risk ?? '—'}',
            if (flags is List && flags.isNotEmpty) '${context.tr('Flags')}: ${flags.join(', ')}',
          ].join(' · '),
          style: context.listSubtitleStyle,
        ),
        if (error.isNotEmpty) Text(error, style: context.listCaptionStyle),
      ],
    );
  }

  String _statusLabel(String status) {
    // The known values come from servicecheck's Status* constants; unknown
    // statuses (e.g. a new core's) are shown verbatim rather than hidden.
    if (status.isEmpty) return '—';
    return context.tr(status);
  }
}
