// Importing a route profile: what the toolbar's "Import" and a shared
// `throne://route/…` link both feed.
//
// Supported formats (the same set RouteShare.fromShareInput accepts upstream):
//   * `throne://route/<base64url>` — the share link, JSON without the padding;
//   * bare or standard-base64 of the same JSON;
//   * the share JSON itself (`{"kind":"throne-route-profile", rules:[…]}`);
//   * a bare rule array (a legacy profile with no name, which opens in the
//     editor for a name);
//   * a sing-box fragment (`{route:{rules:[…]}}`), through RuleImporter.
//
// `throne://remoteroute/…` is not a profile: it carries remote entries, and this
// build has no bridge arm that adds them, so it is reported instead of silently
// half-imported.
//
// Remote route profiles are refreshed by [updateRemoteProfile]: the URL is read
// through `routeGetProfile`, fetched here, parsed with the same codec, and the
// rules written back with `routeSaveRules`. The frozen save API has no
// `remoteLastUpdate` field, so the card's "updated" line comes from whatever
// the host reports; the rules themselves are real.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../common/singbox_rules.dart';
import '../widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/box_providers.dart';

/// What one parsed document yields.
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

  /// A bare rule array has no name or default outbound; the editor asks for one.
  final bool legacyArray;

  int get total => rules.length;
}

const String _routeLinkPrefix = 'throne://route/';
const String _remoteRouteLinkPrefix = 'throne://remoteroute/';

/// Parses a route profile document; null when the text is none of the shapes
/// above.
RouteDocument? parseRouteDocument(String text) {
  var input = text.trim();
  if (input.isEmpty) return null;
  if (input.toLowerCase().startsWith(_routeLinkPrefix)) {
    input = input.substring(_routeLinkPrefix.length);
    // A link pasted from a URL field may carry a query or fragment.
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
      // {"route": {"rules": [...]}} — a sing-box config; not a route profile.
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

/// The text shapes one document may come in, most specific first: the raw JSON,
/// then base64url (with or without padding), then standard base64.
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

/// A share rule object back into the editor's stored-rule map. The share key
/// `outbound` is the stored `outbound_id`, and a name resolves to the fixed
/// outbounds only; a server name cannot be resolved here and is reported.
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

/// The full import path: the share shapes first, a sing-box fragment second.
/// Throws with a readable message when the text is none of them.
Future<RouteDocument> importRouteText(String text) async {
  final trimmed = text.trim();
  if (trimmed.toLowerCase().startsWith(_remoteRouteLinkPrefix)) {
    throw StateError(
      'This is a remote-profile link: it carries a list of remote URLs, and this build has no '
      'importer for it. Paste one profile link (throne://route/…) instead.',
    );
  }
  final document = parseRouteDocument(trimmed);
  if (document != null) return document;
  // A sing-box fragment: the importer understands {route:{rules:[…]}} and the
  // bare shapes around it, and checks them against the bundled schema. The
  // schema asset is optional (a slim build, a test host), so a failure to load
  // it says so instead of masking the parse as "not a profile".
  final RuleImportResult result;
  try {
    result = await RuleImporter().run(trimmed, kind: RuleImportKind.route);
  } catch (error) {
    throw StateError('Not a route profile, a share link, or a sing-box rule fragment: ${BoxController.describe(error)}');
  }
  if (result.error == null && result.routeRules.isNotEmpty) {
    return RouteDocument(
      rules: result.routeRules,
      warnings: [for (final problem in result.problems) '${problem.rule}: ${problem.reason}'],
    );
  }
  throw StateError(result.error ?? 'Not a route profile, a share link, or a sing-box rule fragment.');
}

/// The document's rules in the shape the kernel stores: `_json` column names, no short names.
///
/// A parsed document is editor-shaped (the short field names the rule page edits), but the
/// save handlers are not the editor: `ruleRowFromWire` maps `_json` keys and the five short
/// names it knows, and stores any other short name verbatim. A `rule_set` sent as-is would
/// land beside an empty `rule_set_json`, which Kotlin (`RouteJsonStore`) reads — the rule
/// then builds as a match-all. Canonicalising here keeps the import honest for every
/// condition, not just the five with an alias.
List<Json> routeRulesForStore(List<Json> rules) =>
    [for (final rule in rules) ruleToWire(ruleFromWire(rule))];

/// Saves a parsed document as a new profile; answers the new id (0 on failure).
Future<int> saveImportedProfile(BoxController box, RouteDocument document, {String? name}) async {
  final saved = await box.routeSaveProfile(
    id: 0,
    name: (name ?? document.name ?? '').trim().isEmpty ? 'Imported profile' : (name ?? document.name)!.trim(),
    defaultOutbound: document.defaultOutbound ?? 'direct',
    isRemote: false,
  );
  final id = saved is num ? saved.toInt() : (saved is Map ? (saved['id'] as num?)?.toInt() ?? 0 : 0);
  if (id > 0 && document.rules.isNotEmpty) {
    await box.routeSaveRules(id, routeRulesForStore(document.rules));
  }
  return id;
}

/// Fetches a remote profile's rule document and replaces its rules. Answers the
/// number of rules written.
///
/// This is the card menu's "Update", so the fetch is bounded and refuses a
/// non-http(s) URL: a profile document names a download the phone performs.
Future<int> updateRemoteProfile(BoxController box, int id) async {
  final detail = json(await box.routeGetProfile(id));
  final url = (detail['remoteUrl'] ?? detail['remote_url'] ?? '').toString().trim();
  if (url.isEmpty) throw StateError('This profile has no remote URL');
  if (!isSafeRemoteRouteUrl(url)) {
    throw StateError('Refusing to fetch $url: only public http(s) hosts are allowed');
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close().timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw StateError('The remote answered ${response.statusCode}');
    }
    final text = await utf8.decoder.bind(response).join();
    final document = await importRouteText(text);
    if (document.rules.isEmpty) throw StateError('The remote document carried no rules');
    await box.routeSaveRules(id, routeRulesForStore(document.rules));
    return document.rules.length;
  } finally {
    client.close(force: true);
  }
}

/// False for anything that is not a public http(s) host: loopback, private
/// ranges, link-local, `.local` and a bare hostname all fail.
bool isSafeRemoteRouteUrl(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return false;
  final address = InternetAddress.tryParse(host);
  if (address == null) return host.contains('.'); // a bare dev hostname is not a public host
  if (address.isLoopback || address.isLinkLocal || address.isMulticast) return false;
  if (address.type == InternetAddressType.IPv4) {
    final bytes = address.rawAddress;
    final a = bytes[0], b = bytes[1];
    if (a == 10 || a == 127 || a == 0) return false;
    if (a == 169 && b == 254) return false;
    if (a == 172 && b >= 16 && b <= 31) return false;
    if (a == 192 && b == 168) return false;
    if (a == 100 && b >= 64 && b <= 127) return false; // carrier-grade NAT
    if (a >= 224) return false;
    return true;
  }
  // IPv6: only the global unicast range 2000::/3 is public.
  return (address.rawAddress[0] & 0xe0) == 0x20;
}

// --- the page ------------------------------------------------------------------

/// The import sheet: paste a link or a document, see what it is, save it.
class RouteImportPage extends ConsumerStatefulWidget {
  const RouteImportPage({super.key});

  @override
  ConsumerState<RouteImportPage> createState() => _RouteImportPageState();
}

class _RouteImportPageState extends ConsumerState<RouteImportPage> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;
  RouteDocument? _parsed;
  Timer? _previewDebounce;
  int _previewSeq = 0;

  @override
  void dispose() {
    _previewDebounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) showAppBanner(context, context.tr('Empty clipboard'), level: BannerLevel.warning);
      return;
    }
    setState(() => _controller.text = text);
    await _preview();
  }

  /// Typing coalesces into one parse 250 ms later; without this each keystroke
  /// launched a concurrent `importRouteText` and a slow early parse could
  /// overwrite the preview of newer text.
  void _previewSoon() {
    _previewDebounce?.cancel();
    _previewDebounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) _preview();
    });
  }

  Future<void> _preview() async {
    final seq = ++_previewSeq;
    final text = _controller.text.trim();
    setState(() {
      _error = null;
      _parsed = null;
    });
    if (text.isEmpty) return;
    try {
      final document = await importRouteText(text);
      if (mounted && seq == _previewSeq) setState(() => _parsed = document);
    } catch (error) {
      if (mounted && seq == _previewSeq) setState(() => _error = BoxController.describe(error));
    }
  }

  Future<void> _import() async {
    final document = _parsed;
    if (document == null) return;
    setState(() => _busy = true);
    try {
      final id = await saveImportedProfile(ref.read(boxControllerProvider), document);
      if (!mounted) return;
      if (id <= 0) {
        setState(() {
          _busy = false;
          _error = context.tr('The profile was not saved');
        });
        return;
      }
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = BoxController.describe(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final document = _parsed;
    return Scaffold(
      title: context.tr('Import'),
      isLoading: _busy,
      primaryAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: context.tr('Save'),
        onPressed: document == null || _busy ? null : _import,
      ),
      iconActions: [
        IconButtonData(glyph: AppGlyphs.paste, tooltip: context.tr('Paste'), onPressed: _paste),
      ],
      body: ListView(
        padding: boxPagePadding(context),
        children: [
          generateSection(items: [
            ListItem(
              title: Text(context.tr('Route link or document')),
              subtitle: Text(context.tr(
                'A throne://route/… link, the share JSON or its base64, a rule array, or a sing-box fragment.',
              )),
            ),
          ]),
          const SizedBox(height: 8),
          BoxPanel(
            padding: const EdgeInsets.all(12),
            child: TextField(
              key: const Key('route-import-field'),
              controller: _controller,
              minLines: 6,
              maxLines: 12,
              autocorrect: false,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
              decoration: const InputDecoration(hintText: 'throne://route/…'),
              onChanged: (_) => _previewSoon(),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Card(
              radius: AppCorner.lg,
              isError: true,
              child: ListItem(
                leading: GlyphIcon(AppGlyphs.warning, color: context.colorScheme.error),
                title: Text(context.tr('Not a route profile')),
                subtitle: Text(_error!),
              ),
            ),
          ],
          if (document != null) ...[
            const SizedBox(height: 12),
            generateSection(title: context.tr('What will be imported'), items: [
              ListItem(
                leading: const GlyphIcon(AppGlyphs.rules),
                title: Text(document.name?.trim().isNotEmpty == true
                    ? document.name!.trim()
                    : context.tr('Imported profile')),
                subtitle: Text('${document.rules.length} ${context.tr('rules')}'
                    '${document.defaultOutbound == null ? '' : ' · ${context.tr('Default')}: ${context.tr(document.defaultOutbound!)}'}'),
              ),
              if (document.customDns) ListItem(
                leading: const GlyphIcon(AppGlyphs.dns),
                title: Text(context.tr('The document carries its own DNS')),
                subtitle: Text(context.tr('It is kept with the profile, as the desktop shares it.')),
              ),
              if (document.legacyArray) ListItem(
                leading: const GlyphIcon(AppGlyphs.info),
                title: Text(context.tr('The document is a bare rule array')),
                subtitle: Text(context.tr('It is saved as a new profile; edit the name after importing.')),
              ),
              for (final warning in document.warnings.take(6)) ListItem(
                leading: GlyphIcon(AppGlyphs.info, color: context.colorScheme.tertiary),
                title: Text(warning),
              ),
            ]),
          ],
        ],
      ),
    );
  }
}
