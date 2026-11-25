// Import sing-box / share-link rule fragments into the one global rule table.
//
// A pasted fragment may be a `throne://route/…` share link, a bare rule array,
// a `{route:{rules:[…]}}` sing-box fragment, or a whole config with `dns.rules`.
// Route rules append to the global table; DNS rules append to the DNS object —
// there is no profile to choose any more, so the import sheet has one target.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../common/singbox_rules.dart';
import '../components/form.dart';
import '../ui/json/engine/json_tree.dart';
import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// The parsed fragment handed back to the page that opened the import dialog.
class RuleImportRequest {
  const RuleImportRequest(this.result);
  final RuleImportResult result;
}

/// Route rules join the global table; DNS rules join the DNS object.
Future<void> applyRuleImport(BoxController box, RuleImportRequest request) async {
  final result = request.result;
  if (result.routeRules.isNotEmpty) {
    final existing = json(await box.routeGlobalRules());
    final rules = [...rows(existing['rules']), ...result.routeRules];
    await box.routeSaveGlobalRules(rules);
  }
  if (result.dnsRules.isNotEmpty) {
    final raw = (box.settings['dnsObject'] ?? '').toString().trim();
    var dns = <String, dynamic>{};
    if (raw.isNotEmpty) {
      final parsed = JsonTree.parse(raw);
      final plain = parsed.root == null ? null : JsonTree.toPlain(parsed.root!);
      if (plain is! Map) {
        throw StateError('The DNS object is not a JSON object; fix it in Settings, DNS first');
      }
      dns = Map<String, dynamic>.from(plain);
    }
    final existing = dns['rules'];
    dns['rules'] = [if (existing is List) ...existing, ...result.dnsRules];
    await box.setSetting('dnsObject', jsonEncode(dns));
  }
}

/// A parsed share document: the rules in editor shape, plus the metadata a
/// legacy share link carried. The metadata is kept for the codec tests; the
/// only write target is the global rule list.
class RouteDocument {
  const RouteDocument({
    this.name,
    this.defaultOutbound,
    this.rules = const [],
    this.dns,
    this.customDns = false,
    this.warnings = const [],
    this.legacyArray = false,
  });

  final String? name;
  final String? defaultOutbound;
  final List<Json> rules;
  final Map<String, dynamic>? dns;
  final bool customDns;
  final List<String> warnings;
  final bool legacyArray;

  int get total => rules.length;
}

const String _routeLinkPrefix = 'throne://route/';

/// Encodes rules as the `throne://route/…` share link, compact-keyed JSON in
/// base64url without padding — the inverse of [parseRouteDocument].
String routeShareLink({
  required String name,
  required String defaultOutbound,
  required List<Json> rules,
  Map<String, dynamic>? dns,
  bool customDns = false,
}) {
  final object = <String, dynamic>{
    'kind': 'throne-route-profile',
    'v': 1,
    'name': name,
    'default_outbound': defaultOutbound,
    if (customDns && dns != null) 'dns': dns,
    'rules': [
      for (final rule in rules)
        {
          ...Map<String, dynamic>.from(rule),
          if ((rule['action']?.toString() ?? 'route') == 'reject' &&
              (rule['reject_method']?.toString() ?? '').isNotEmpty)
            'method': rule['reject_method'],
        },
    ],
  };
  return 'throne://route/${base64Url.encode(utf8.encode(jsonEncode(object))).replaceAll('=', '')}';
}

/// Parses a share-link/JSON rule document; null when the text is none of the
/// shapes above.
RouteDocument? parseRouteDocument(String text) {
  var input = text.trim();
  if (input.isEmpty) return null;
  if (input.toLowerCase().startsWith(_routeLinkPrefix)) {
    input = input.substring(_routeLinkPrefix.length);
    final cut = input.indexOf(RegExp(r'[?#]'));
    if (cut >= 0) input = input.substring(0, cut);
  }
  Map<String, dynamic>? object;
  List<dynamic>? array;
  for (final candidate in _candidates(input)) {
    final decoded = _decode(candidate);
    if (decoded is Map<String, dynamic>) {
      if (_looksLikeRouteObject(decoded)) {
        object = decoded;
        break;
      }
    } else if (decoded is List) {
      array = decoded;
      break;
    }
  }
  if (object != null) {
    final warnings = <String>[];
    final rules = <Json>[];
    final rawRules = object['rules'];
    if (rawRules is List) {
      for (final entry in rawRules) {
        if (entry is Map) rules.add(_ruleFromShare(entry, warnings));
      }
    }
    final dns = object['dns'];
    return RouteDocument(
      name: object['name']?.toString(),
      defaultOutbound: _outboundName(object['default_outbound'] ?? object['defaultOutbound']),
      rules: rules,
      dns: dns is Map ? Map<String, dynamic>.from(dns) : null,
      customDns: dns is Map,
      warnings: warnings,
    );
  }
  if (array != null) {
    final warnings = <String>[];
    final rules = [
      for (final entry in array)
        if (entry is Map) _ruleFromShare(entry, warnings),
    ];
    return RouteDocument(rules: rules, warnings: warnings, legacyArray: true);
  }
  return null;
}

Iterable<String> _candidates(String input) sync* {
  yield input;
  yield* _base64Tries(input, base64Url);
  yield* _base64Tries(input, base64);
}

Iterable<String> _base64Tries(String input, Base64Codec codec) sync* {
  final padded = input.padRight(input.length + (4 - input.length % 4) % 4, '=');
  for (final candidate in [padded, input]) {
    try {
      yield utf8.decode(codec.decode(candidate));
    } catch (_) {
      // Not this codec; the next candidate gets a turn.
    }
  }
}

dynamic _decode(String text) {
  try {
    return jsonDecode(text);
  } catch (_) {
    return null;
  }
}

bool _looksLikeRouteObject(Map<String, dynamic> object) {
  if (object['kind']?.toString() == 'throne-route-profile') return true;
  if (object['rules'] is List) return true;
  if (object.containsKey('default_outbound') || object.containsKey('defaultOutbound')) return true;
  return false;
}

Json _ruleFromShare(Map<dynamic, dynamic> source, List<String> warnings) {
  final rule = <String, dynamic>{
    'name': source['name']?.toString() ?? '',
    'type': source['type']?.toString() ?? 'custom',
    'action': source['action']?.toString() ?? 'route',
    'disabled': source['disabled'] == true,
  };
  final outbound = source['outbound'] ?? source['outbound_id'];
  final id = _outboundId(outbound);
  if (id != null) rule['outbound_id'] = id;
  for (final key in const [
    'ip_version', 'network', 'protocol', 'reject_method', 'override_address', 'override_port',
    'tls_fragment_fallback_delay', 'tls_spoof', 'tls_spoof_method', 'strategy',
  ]) {
    final value = source[key] ?? (key == 'reject_method' ? source['method'] : null);
    if (value != null) rule[key] = value.toString();
  }
  for (final key in const [
    'inbound', 'domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'source_ip_cidr',
    'ip_cidr', 'source_port', 'source_port_range', 'port', 'port_range', 'process_name',
    'process_path', 'process_path_regex', 'package_name', 'package_name_regex', 'network_type',
    'wifi_ssid', 'wifi_bssid', 'rule_set', 'sniffers',
  ]) {
    final value = source[key];
    if (value is List) {
      rule[key] = value.map((item) => item.toString()).toList();
    } else if (value != null) {
      rule[key] = [value.toString()];
    }
  }
  for (final key in const [
    'source_ip_is_private', 'ip_is_private', 'invert', 'no_drop', 'sniff_override_dest',
    'network_is_expensive', 'tls_fragment', 'tls_record_fragment',
  ]) {
    if (source[key] == true) rule[key] = true;
  }
  if (source.containsKey('override_destination')) {
    rule['sniff_override_dest'] = source['override_destination'] == true;
  }
  return rule;
}

int? _outboundId(Object? value) {
  if (value is num) {
    final id = value.toInt();
    return const {-1, -2, -3, -5}.contains(id) ? id : -1;
  }
  return switch (value?.toString().toLowerCase()) {
    'proxy' => -1,
    'direct' => -2,
    'block' || 'reject' => -3,
    'warp-bypass' || 'warp_bypass' => -5,
    _ => null,
  };
}

String? _outboundName(Object? value) => switch (value?.toString().toLowerCase()) {
      'proxy' => 'proxy',
      'direct' => 'direct',
      'block' || 'reject' => 'block',
      'warp-bypass' || 'warp_bypass' => 'warp-bypass',
      _ => null,
    };

/// A parsed document's rules in the shape the kernel stores: `_json` column
/// names, no short names beside them.
List<Json> routeRulesForStore(List<Json> rules) =>
    [for (final rule in rules) ruleToWire(ruleFromWire(rule))];

/// False for anything that is not a public http(s) host: loopback, private
/// ranges, link-local, `.local` and a bare hostname all fail. Kept as a pure
/// guard for link parsing; the global table has no remote profiles to fetch.
bool isSafeRemoteRouteUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return false;
  final address = InternetAddress.tryParse(host);
  if (address == null) return host.contains('.');
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) return false;
  if (address.type == InternetAddressType.IPv4) {
    final bytes = address.rawAddress;
    final a = bytes[0], b = bytes[1];
    if (a == 10 || a == 127 || a == 0) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 100 && b >= 64 && b <= 127) return false;
    if (a >= 224) return false;
    return true;
  }
  return (address.rawAddress[0] & 0xe0) == 0x20;
}

/// The import sheet: paste a fragment, see what the schema says about it, then
/// commit. Route rules go to the global table, DNS rules to the DNS object.
class RuleImportPage extends ConsumerStatefulWidget {
  const RuleImportPage({super.key});

  @override
  ConsumerState<RuleImportPage> createState() => _RuleImportPageState();
}

class _RuleImportPageState extends ConsumerState<RuleImportPage> {
  String _input = '';
  Timer? _debounce;
  RuleImportResult? _result;
  Map<String, int> _outboundIds = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  /// The server tags a rule may name as its outbound; a dead service only
  /// leaves them unresolvable, which the preview reports per rule.
  Future<void> _load() async {
    try {
      final nodes = await ref.read(boxControllerProvider).groupNodes();
      if (!mounted) return;
      setState(() => _outboundIds = {
        for (final node in nodes)
          if ('${node['tag'] ?? ''}'.isNotEmpty) '${node['tag']}': (node['id'] as num?)?.toInt() ?? 0,
      });
    } catch (_) {}
  }

  void _changed(String value) {
    _input = value;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _parse);
  }

  Future<void> _parse() async {
    final text = _input.trim();
    if (text.isEmpty) {
      if (mounted) setState(() { _result = null; });
      return;
    }
    final result = await RuleImporter(outboundIds: _outboundIds)
        .run(text, kind: RuleImportKind.route);
    if (!mounted) return;
    setState(() => _result = result);
  }

  bool get _canImport {
    final result = _result;
    return result != null && result.error == null && result.total > 0;
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    return Surface(
      color: SurfaceLevel.floatingOf(context.colorScheme).colorOf(context.colorScheme),
      shape: AppShape.all(AppCorner.alert),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.sizeOf(context).height * .82),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(context.tr('Import rules from JSON'),
              style: AppTextStyle.title3.of(context, emphasized: true)),
            const SizedBox(height: 12),
            Flexible(child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(context.tr('Paste a sing-box fragment carrying route or DNS rules; both are recognised automatically and checked against the schema first.'),
                  style: AppTextStyle.caption1.of(context)),
                const SizedBox(height: 10),
                SizedBox(height: 210, child: TextField(
                  key: const Key('rule-import-field'),
                  expands: true, minLines: null, maxLines: null,
                  keyboardType: TextInputType.multiline, textAlignVertical: TextAlignVertical.top,
                  autocorrect: false, onChanged: _changed,
                  style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
                  decoration: const InputDecoration(border: AppShape.input,
                    isDense: true, contentPadding: EdgeInsets.fromLTRB(12, 12, 12, 12)),
                )),
                if (result != null) ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150), child: _summary(result)),
              ])),
            ),
            const SizedBox(height: 8),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
              TextButton(
                onPressed: _canImport ? () => Navigator.pop(context, RuleImportRequest(result!)) : null,
                child: Text(context.tr('Import')),
              ),
            ]),
          ]),
        ),
      ),
      ),
    );
  }

  Widget _summary(RuleImportResult? result) {
    final problems = result?.problems ?? const <RuleImportProblem>[];
    final usesDns = (result?.dnsRules.isNotEmpty ?? false) &&
        ref.read(boxControllerProvider).settings['useDnsObject'] != true;
    final rows = <Widget>[
      if (result == null) ListItem(
        leading: const GlyphIcon(AppGlyphs.info),
        title: Text(context.tr('Paste a sing-box rule fragment')),
        subtitle: Text(context.tr(
          'A rule, an array of rules, {"rules": [...]}, or a config carrying "route" and "dns".')),
      ) else ...[
        if (result.error != null) ListItem(
          leading: GlyphIcon(AppGlyphs.warning, color: context.colorScheme.error),
          title: Text(context.tr('Not a rule fragment')),
          subtitle: Text(result.error!),
        ) else ...[
          ListItem(
            leading: const GlyphIcon(AppGlyphs.check),
            title: Text(context.tr('Route rules to add')),
            trailing: Text('${result.routeRules.length}', style: context.listValueStyle),
          ),
          ListItem(
            leading: const GlyphIcon(AppGlyphs.dns),
            title: Text(context.tr('DNS rules to add')),
            trailing: Text('${result.dnsRules.length}', style: context.listValueStyle),
          ),
          if (usesDns) ListItem(
            leading: GlyphIcon(AppGlyphs.info, color: context.colorScheme.tertiary),
            title: Text(context.tr('DNS rules wait for the DNS object')),
            subtitle: Text(context.tr(
              'They are stored in the DNS object, which Settings, DNS has switched off; turn it on for them to apply.')),
          ),
          if (result.hasErrors) ListItem(
            leading: GlyphIcon(AppGlyphs.warning, color: context.colorScheme.error),
            title: Text(context.tr('The schema rejects part of this fragment')),
            subtitle: Text(context.tr('Fix the underlined fields before importing.')),
          ),
          for (final problem in problems.take(20)) ListItem(
            leading: GlyphIcon(AppGlyphs.warning, color: const Color(0xfff08c00)),
            title: Text(problem.rule),
            subtitle: Text(problem.reason),
          ),
        ],
      ],
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: Material(
        color: context.colorScheme.surfaceContainerLow,
        child: ListView(shrinkWrap: true, children: rows),
      ),
    );
  }
}
