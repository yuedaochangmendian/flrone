import '../widgets.dart';
import '../components/form.dart';

/// One made-up connection walked through the running core's route rules.
///
/// The kernel's route tester dials nothing: it resolves the domain/IP, feeds a
/// synthetic inbound context through the rule chain and reports every step and
/// the final action. That is the desktop's TestRoute, exposed by the pinned AAR
/// and called through the action bus, so this page adds no new native surface.
class RouteTestPage extends StatefulWidget {
  const RouteTestPage({super.key});

  @override State<RouteTestPage> createState() => _RouteTestPageState();
}

class _RouteTestPageState extends State<RouteTestPage> {
  static const _networks = ['tcp', 'udp'];
  static const _protocols = ['auto', 'tls', 'http', 'quic', 'none'];

  final _domain = TextEditingController();
  final _ip = TextEditingController();
  final _port = TextEditingController(text: '443');
  final _package = TextEditingController();
  String _network = 'tcp';
  String _protocol = 'auto';
  bool _running = false;
  String? _error;
  Json? _result;

  @override
  void dispose() {
    _domain.dispose();
    _ip.dispose();
    _port.dispose();
    _package.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    FocusScope.of(context).unfocus();
    final domain = _domain.text.trim();
    final ip = _ip.text.trim();
    if (domain.isEmpty && ip.isEmpty) {
      setState(() => _error = context.tr('Enter a domain or IP address'));
      return;
    }
    final port = int.tryParse(_port.text.trim());
    if (port != null && (port < 1 || port > 65535)) {
      setState(() => _error = context.tr('Port out of range'));
      return;
    }
    setState(() {
      _running = true;
      _error = null;
      _result = null;
    });
    try {
      final value = await context.box.routeTest({
        if (domain.isNotEmpty) 'domain': domain,
        if (ip.isNotEmpty) 'ip': ip,
        'port': port ?? 443,
        'network': _network,
        'protocol': _protocol,
        if (_package.text.trim().isNotEmpty) 'packageName': _package.text.trim(),
      });
      if (mounted) setState(() => _result = json(value));
    } catch (error) {
      if (mounted) setState(() => _error = BoxController.describe(error));
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return BoxPage(
      title: 'Route test',
      loading: _running,
      error: _error,
      children: [
        // Same intro panel as the Connectivity page, so the diagnostic tools read alike.
        BoxPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 10,
            children: [
              PanelTitle('Route test', AppGlyphs.target),
              Text(
                context.tr('Match one connection against the route rules'),
                style: context.listSubtitleStyle,
              ),
            ],
          ),
        ),
        generateSection(title: context.tr('Request'), items: [
          FormRow(
            title: context.tr('Domain'),
            trailing: FormRowTextField(controller: _domain, hintText: 'example.com'),
          ),
          FormRow(
            title: context.tr('IP address'),
            trailing: FormRowTextField(controller: _ip, hintText: '1.1.1.1'),
          ),
          FormRow(
            title: context.tr('Port'),
            trailing: FormRowTextField(
              controller: _port,
              hintText: '443',
              keyboardType: TextInputType.number,
            ),
          ),
          ListItem.options(
            title: Text(context.tr('Network')),
            options: _networks,
            value: _network,
            textBuilder: (value) => value.toUpperCase(),
            onChanged: (value) => setState(() => _network = value),
          ),
          ListItem.options(
            title: Text(context.tr('Protocol')),
            options: _protocols,
            value: _protocol,
            textBuilder: (value) => value,
            onChanged: (value) => setState(() => _protocol = value),
          ),
          FormRow(
            title: context.tr('Package name'),
            trailing: FormRowTextField(controller: _package, hintText: 'com.example.app'),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Center(
            child: TonalButton(
              glyph: AppGlyphs.target,
              label: context.tr('Run test'),
              onPressed: _running ? null : _run,
            ),
          ),
        ),
        if (result != null) ..._resultSections(result),
      ],
    );
  }

  List<Widget> _resultSections(Json result) {
    final error = '${result['error'] ?? ''}'.trim();
    if (error.isNotEmpty) {
      return [
        BoxPanel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              PanelTitle('Route result', AppGlyphs.warning),
              SelectableText(error, style: context.listSubtitleStyle),
            ],
          ),
        ),
      ];
    }
    final steps = (result['steps'] as List? ?? const [])
        .whereType<Map>()
        .map((step) => Map<String, dynamic>.from(step))
        .toList();
    final chain = [
      for (final item in (result['outbound_chain'] as List? ?? const [])) '$item',
    ].where((item) => item.isNotEmpty).join(' › ');
    Widget value(String label, Object? raw) {
      final text = '${raw ?? ''}'.trim();
      return FormRow(title: label, trailing: Text(text.isEmpty ? '—' : text));
    }

    return [
      generateSection(title: context.tr('Route result'), items: [
        value(context.tr('Destination'), result['destination']),
        value(context.tr('Final action'), result['action']),
        value(context.tr('Outbound'), result['outbound']),
        if (chain.isNotEmpty) value(context.tr('Outbound chain'), chain),
        value(context.tr('Inbound'), result['inbound']),
      ]),
      BoxPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            PanelTitle('Steps', AppGlyphs.target),
            if (steps.isEmpty)
              Text(context.tr('No steps'), style: context.listSubtitleStyle)
            else
              for (final step in steps) _step(step),
          ],
        ),
      ),
    ];
  }

  Widget _step(Map<String, dynamic> step) {
    final index = step['index'] ?? '';
    final title = '#$index ${step['rule'] ?? ''}'.trim();
    final detail = [
      if ('${step['action'] ?? ''}'.isNotEmpty) '${step['action']}',
      if ('${step['action_detail'] ?? ''}'.isNotEmpty) '${step['action_detail']}',
      if ('${step['matched'] ?? ''}'.isNotEmpty) '${context.tr('Matched')}: ${step['matched']}',
      if ('${step['note'] ?? ''}'.isNotEmpty) '${step['note']}',
      if ('${step['error'] ?? ''}'.isNotEmpty) '${step['error']}',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        Text(title, style: context.listTitleStyle),
        if (detail.isNotEmpty)
          Text(detail, style: context.listSubtitleStyle),
      ],
    );
  }
}
