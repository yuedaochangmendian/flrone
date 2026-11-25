// Rule text: the enum tables Throne for Android exposes as menus, and the
// formatters its `RouteTexts` uses for a rule row. Pure functions over the
// wire shape — no page state, no channel calls.

import 'dart:io';

import '../widgets.dart';

/// A `(stored value, display label)` pair for a rule field that Throne for
/// Android exposes as a fixed `SimpleMenuPreference` instead of free text.
typedef RuleEnumOption = ({String value, String label});

/// The legal stored values, verbatim from Throne for Android's
/// `res/values/arrays.xml` (`route_rule_*_values` / `domain_strategy_values`).
/// The first entry is the empty string: the rule does not narrow the match on
/// that field. `action` keeps this build's `bypass` and adds the `hijack-dns`
/// value the upstream XML carries (additive only, so existing rules survive).
const Map<String, List<RuleEnumOption>> ruleEnumValues = {
  'ip_version': [
    (value: '', label: 'Any'),
    (value: '4', label: 'IPv4'),
    (value: '6', label: 'IPv6'),
  ],
  'network': [
    (value: '', label: 'Any'),
    (value: 'tcp', label: 'tcp'),
    (value: 'udp', label: 'udp'),
    (value: 'icmp', label: 'icmp'),
  ],
  'protocol': [
    (value: '', label: 'Any'),
    (value: 'http', label: 'http'),
    (value: 'tls', label: 'tls'),
    (value: 'quic', label: 'quic'),
    (value: 'stun', label: 'stun'),
    (value: 'dns', label: 'dns'),
    (value: 'bittorrent', label: 'bittorrent'),
    (value: 'dtls', label: 'dtls'),
    (value: 'ssh', label: 'ssh'),
    (value: 'rdp', label: 'rdp'),
    (value: 'ntp', label: 'ntp'),
  ],
  'reject_method': [
    (value: '', label: 'Unset'),
    (value: 'default', label: 'default'),
    (value: 'drop', label: 'drop'),
    (value: 'reply', label: 'reply'),
  ],
  'strategy': [
    (value: '', label: 'Default'),
    (value: 'ipv4_only', label: 'ipv4_only'),
    (value: 'ipv6_only', label: 'ipv6_only'),
    (value: 'prefer_ipv4', label: 'prefer_ipv4'),
    (value: 'prefer_ipv6', label: 'prefer_ipv6'),
  ],
  'action': [
    (value: 'route', label: 'route'),
    (value: 'reject', label: 'reject'),
    (value: 'hijack-dns', label: 'hijack-dns'),
    (value: 'sniff', label: 'sniff'),
    (value: 'resolve', label: 'resolve'),
    (value: 'route-options', label: 'route-options'),
    (value: 'bypass', label: 'bypass'),
  ],
};

/// Throne's `RouteRuleActivity.ensureValue`: a stored value outside the preset
/// list is appended as a selectable option, so opening and saving a rule from
/// an older build never drops or silently rewrites that value.
List<RuleEnumOption> ruleEnumOptions(String key, String current) {
  final presets = ruleEnumValues[key] ?? const <RuleEnumOption>[];
  if (current.isEmpty || presets.any((option) => option.value == current)) {
    return presets;
  }
  return <RuleEnumOption>[...presets, (value: current, label: current)];
}

/// The label for [current]; an empty value resolves to the field's "unset"
/// entry (Any / Unset / Default, depending on the field).
String ruleEnumLabel(String key, String current) {
  for (final option in ruleEnumOptions(key, current)) {
    if (option.value == current) return option.label;
  }
  return current.isEmpty ? 'Any' : current;
}

/// Apply a menu selection. The empty option removes the field entirely instead
/// of storing an empty-string key: Throne's SimpleMenuPreference writes an
/// unset value, and the rule serializer treats a missing key the same way.
Json ruleEnumApply(Json rule, String key, String value) {
  final next = <String, dynamic>{...rule};
  if (value.isEmpty) {
    next.remove(key);
  } else {
    next[key] = value;
  }
  return next;
}

/// The hint under a list field's per-line editor, matching what Throne for Android's
/// `RouteRuleActivity` shows above its own multi-line dialog: what one line is, and — for the
/// domain matches — the example that makes the difference between them clear.
const ruleFieldHints = <String, String>{
  'domain': 'One domain per line; only that exact host matches.',
  'domain_suffix': 'One suffix per line; google.com matches google.com and its subdomains.',
  'domain_keyword': 'One keyword per line; the host has to contain it.',
  'domain_regex': 'One Go regular expression per line, matched against the host.',
  'ip_cidr': 'One CIDR per line, for example 10.0.0.0/8 or 2001:db8::/32.',
  'source_ip_cidr': 'One CIDR per line; the connection\'s own address has to fall inside it.',
  'port': 'One port per line.',
  'port_range': 'One range per line, for example 1000:2000.',
  'source_port': 'One port per line; the connection\'s own source port.',
  'source_port_range': 'One range per line, for example 1000:2000.',
  'process_name': 'One process name per line.',
  'process_path': 'One absolute process path per line.',
  'process_path_regex': 'One Go regular expression per line, matched against the path.',
  'package_name': 'One Android package per line, for example com.example.app.',
  'package_name_regex': 'One regular expression per line, matched against the package name.',
  'inbound': 'One inbound tag per line.',
  'wifi_ssid': 'One network name per line.',
  'wifi_bssid': 'One access point address per line.',
  'sniffers': 'One sniffer per line.',
};

/// The hint for [key]; a field without one still gets the "one per line" reminder.
String ruleFieldHint(BuildContext context, String key) =>
    context.tr(ruleFieldHints[key] ?? 'One value per line.');

// Rule-field validation
// ---------------------
// Manual entry is the only way in since 4.17.0 dropped external import, so a
// typo used to reach the kernel with no way to locate it. These are pure
// functions: the editor calls [validateRuleFields] before saving and points at
// the offending field; tests call it with no widget tree at all.
//
// `labelKey` / `reasonKey` are English source keys fed through `tr()` at the
// call site, so the message localises with the rest of the app. Every key used
// below already exists in l10n.dart except the 'Process name regex' label,
// which currently falls back to English until the integrator adds its zh entry.

/// The label key shown for each validated field.
const ruleFieldLabelKeys = <String, String>{
  'ip_cidr': 'IP CIDR',
  'source_ip_cidr': 'Source IP CIDR',
  'port': 'Port',
  'source_port': 'Source port',
  'port_range': 'Port range',
  'source_port_range': 'Source port range',
  'domain_regex': 'Domain regex',
  'package_name_regex': 'Package name regex',
  'process_name_regex': 'Process name regex',
  'process_path_regex': 'Process path regex',
  'override_port': 'Override port',
  'tls_fragment_fallback_delay': 'Fragment fallback delay',
};

const _cidrFields = ['ip_cidr', 'source_ip_cidr'];
const _portFields = ['port', 'source_port', 'port_range', 'source_port_range'];
const _regexFields = [
  'domain_regex', 'package_name_regex', 'process_name_regex', 'process_path_regex',
];

/// One field-level failure. [detail] is the offending value, appended verbatim
/// so the user can see exactly which line to fix.
class RuleFieldIssue {
  const RuleFieldIssue({
    required this.field,
    required this.labelKey,
    required this.reasonKey,
    this.detail = '',
  });

  /// The rule-map key that failed validation.
  final String field;
  /// English source key for the field name, passed through `tr()`.
  final String labelKey;
  /// English source key for the failure reason, passed through `tr()`.
  final String reasonKey;
  /// The offending value (usually one line), shown in parentheses.
  final String detail;

  /// A single-line message. [tr] behaves like `BuildContext.tr`; tests pass
  /// `(key) => key` to get the source text.
  String describe(String Function(String) tr) {
    final base = '${tr(labelKey)}: ${tr(reasonKey)}';
    return detail.isEmpty ? base : '$base ($detail)';
  }
}

/// Interpret a rule field that may be a `List` or a newline/comma separated
/// string as a list of trimmed, non-empty values.
List<String> _fieldValues(Object? value) {
  if (value is List) {
    return [for (final item in value) item.toString().trim()]
        .where((item) => item.isNotEmpty)
        .toList();
  }
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return const <String>[];
  return text.split(RegExp(r'[\n,]')).map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

/// A bare IP is accepted because Throne's own `Validation.cidr` calls these
/// fields with `allowBareIp = true`. A prefix, when present, must be a decimal
/// within 0..32 (IPv4) or 0..128 (IPv6).
bool _isValidCidr(String text) {
  final slash = text.lastIndexOf('/');
  final String address;
  if (slash < 0) {
    address = text;
  } else {
    address = text.substring(0, slash);
    final bitsText = text.substring(slash + 1);
    if (!RegExp(r'^\d+$').hasMatch(bitsText)) return false;
    final bits = int.tryParse(bitsText);
    if (bits == null) return false;
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null) return false;
    final max = parsed.type == InternetAddressType.IPv4 ? 32 : 128;
    if (bits > max) return false;
  }
  return InternetAddress.tryParse(address) != null;
}

/// Validates a single port or an `a-b` / `a:b` range. Returns the English
/// source key of the reason, or `null` when [text] is acceptable.
String? _portProblem(String text) {
  if (text.isEmpty) return 'Ports must be numbers';
  final parts = text.split(RegExp(r'[:-]'));
  if (parts.length > 2) return 'Invalid value';
  final values = <int>[];
  for (final part in parts) {
    if (part.isEmpty) return 'Invalid value';
    if (!RegExp(r'^\d+$').hasMatch(part)) return 'Ports must be numbers';
    final value = int.tryParse(part);
    if (value == null || value < 1 || value > 65535) {
      return 'Ports must be between 1 and 65535';
    }
    values.add(value);
  }
  if (values.length == 2 && values[0] >= values[1]) return 'Port out of range';
  return null;
}

// Go duration units, mirroring sing's `common/badoption/internal/my_time`.
// Bare non-negative integers are accepted too: the task's numeric semantics
// and the real duration semantics both have to survive a round trip.
final _durationPattern = RegExp(
  r'^(?:\d+(?:\.\d+)?(?:ns|us|µs|μs|ms|s|m|h|d))+$',
);

bool _isValidFallbackDelay(String text) =>
    RegExp(r'^\d+$').hasMatch(text) || _durationPattern.hasMatch(text);

/// The first invalid field in [rule], or `null` when every validated value is
/// acceptable. Empty fields are skipped; a valid rule keeps its original map
/// untouched (this function never mutates).
RuleFieldIssue? validateRuleFields(Json rule) {
  RuleFieldIssue issue(String field, String reasonKey, [String detail = '']) =>
      RuleFieldIssue(
        field: field,
        labelKey: ruleFieldLabelKeys[field] ?? field,
        reasonKey: reasonKey,
        detail: detail,
      );

  for (final field in _cidrFields) {
    for (final value in _fieldValues(rule[field])) {
      if (!_isValidCidr(value)) return issue(field, 'Invalid value', value);
    }
  }
  for (final field in _portFields) {
    for (final value in _fieldValues(rule[field])) {
      final reason = _portProblem(value);
      if (reason != null) return issue(field, reason, value);
    }
  }
  for (final field in _regexFields) {
    for (final value in _fieldValues(rule[field])) {
      try {
        RegExp(value);
      } on FormatException {
        return issue(field, 'Invalid regular expression', value);
      }
    }
  }

  final overridePort = rule['override_port']?.toString().trim() ?? '';
  if (overridePort.isNotEmpty) {
    final value = int.tryParse(overridePort);
    // `0` is Throne's "unset" sentinel, kept so existing rules survive a save.
    if (value == null || value < 0 || value > 65535) {
      return issue('override_port', 'Must be a port number', overridePort);
    }
  }

  final delayText = rule['tls_fragment_fallback_delay']?.toString().trim() ?? '';
  if (delayText.isNotEmpty && !_isValidFallbackDelay(delayText)) {
    return issue('tls_fragment_fallback_delay', 'Invalid value', delayText);
  }
  return null;
}

/// A rule's row title: its name, or the first match value, or its position.
String ruleName(Json rule, int index) {
  final name = rule['name']?.toString() ?? '';
  if (name.isNotEmpty) return name;
  for (final key in const ['domain', 'domain_suffix', 'ip_cidr', 'port', 'rule_set', 'package_name']) {
    // The wire carries every list column as `<key>_json`; only five also have a short alias.
    final list = rule['${key}_json'] ?? rule[key];
    if (list is List && list.isNotEmpty) return '${list.first}';
  }
  return '#${index + 1}';
}

/// The outbound side of "route → x", Throne's `RouteTexts.outboundName`: the
/// fixed targets as their tokens, a server profile as its id (the picker that
/// reads `groups.nodes` is the only name source, and the row stays synchronous).
String outboundToken(int id) => switch (id) {
  -1 => 'proxy',
  -2 => 'direct',
  -3 => 'block',
  -5 => 'warp-bypass',
  > 0 => '#$id',
  _ => '$id',
};

/// The action line's colour: reject red, route → direct green, route → proxy
/// blue, everything else the config purple. These come from the theme's
/// [ColorScheme], so both hues and contrast follow the active light/dark and
/// accent palette instead of a fixed Material palette.
Color routeActionColor(BuildContext context, String action, int outboundId) {
  final colors = context.colorScheme;
  return switch (action) {
    'reject' => colors.error,
    'route' || 'bypass' => outboundId == -2 ? colors.success : colors.primary,
    _ => colors.tertiary,
  };
}

/// The rule's effect line: "route → direct", "reject (drop)", "resolve
/// (strategy)" — the tokens are the sing-box / desktop names, as upstream.
String ruleActionText(Json rule) {
  final action = rule['action']?.toString() ?? 'route';
  final method = rule['reject_method']?.toString().trim() ?? '';
  final strategy = rule['strategy']?.toString().trim() ?? '';
  return switch (action) {
    'route' || 'bypass' =>
      '$action → ${outboundToken((rule['outbound_id'] as num?)?.toInt() ?? 0)}',
    'reject' => method.isEmpty ? action : '$action ($method)',
    'resolve' => strategy.isEmpty ? action : '$action ($strategy)',
    _ => action,
  };
}

/// The rule's leading column in the FlClash-style row: the match kind its first
/// filled condition uses ("DOMAIN-SUFFIX", "IP-CIDR", "RULE-SET"), or "AND" when
/// several kinds narrow it at once. "MATCH" is the catch-all row.
String ruleTypeLabel(Json rule) {
  const kinds = <String, String>{
    'domain': 'DOMAIN',
    'domain_suffix': 'DOMAIN-SUFFIX',
    'domain_keyword': 'DOMAIN-KEYWORD',
    'domain_regex': 'DOMAIN-REGEX',
    'rule_set': 'RULE-SET',
    'ip_cidr': 'IP-CIDR',
    'source_ip_cidr': 'SRC-IP',
    'package_name': 'PACKAGE',
    'package_name_regex': 'PACKAGE-REGEX',
    'process_name': 'PROCESS',
    'process_path': 'PROCESS-PATH',
    'process_path_regex': 'PROCESS-PATH-REGEX',
    'port': 'PORT',
    'port_range': 'PORT-RANGE',
    'source_port': 'SRC-PORT',
    'source_port_range': 'SRC-PORT-RANGE',
    'inbound': 'INBOUND',
    'protocol': 'PROTOCOL',
    'network': 'NETWORK',
    'ip_version': 'IP-VERSION',
    'wifi_ssid': 'WIFI-SSID',
    'wifi_bssid': 'WIFI-BSSID',
    'sniffers': 'SNIFF',
    'network_type': 'NETWORK-TYPE',
  };
  bool filled(String key) {
    final raw = rule['${key}_json'] ?? rule[key];
    if (raw is List) return raw.isNotEmpty;
    return raw != null && raw.toString().trim().isNotEmpty;
  }

  final used = <String>[
    for (final entry in kinds.entries)
      if (filled(entry.key)) entry.value,
    if (rule['ip_is_private'] == true || rule['source_ip_is_private'] == true) 'PRIVATE-IP',
    if (rule['network_is_expensive'] == true) 'METERED',
  ];
  if (used.isEmpty) return 'MATCH';
  return used.length == 1 ? used.first : 'AND';
}

/// The rule's effect in the row's trailing column, FlClash's target view:
/// "DIRECT", "REJECT-DROP", "PROXY", or a node's id. The tokens are the desktop
/// names, so a rule reads the same here and in the config.
String ruleTargetLabel(Json rule) {
  final action = rule['action']?.toString() ?? 'route';
  final outbound = (rule['outbound_id'] as num?)?.toInt() ?? 0;
  return switch (action) {
    'route' || 'bypass' => switch (outbound) {
        -1 => 'PROXY',
        -2 => 'DIRECT',
        -3 => 'REJECT',
        -5 => 'WARP-BYPASS',
        > 0 => 'NODE #$outbound',
        _ => 'OUT $outbound',
      },
    'reject' => rule['reject_method']?.toString().trim() == 'drop'
        ? 'REJECT-DROP'
        : 'REJECT',
    'hijack-dns' => 'HIJACK-DNS',
    'sniff' => 'SNIFF',
    'resolve' => 'RESOLVE',
    'route-options' => 'ROUTE-OPTIONS',
    _ => action.toUpperCase(),
  };
}

/// The main conditions, Throne's `RouteTexts.ruleConditions`: "suffix:
/// google.com +2 · rule-set: geosite-ir" — first value plus a count, the field
/// tokens lowercase, in the same order the desktop lists them.
String ruleConditions(BuildContext context, Json rule) {
  String list(String label, String key) {
    // The kernel writes every list column as `<key>_json` and mirrors only five of them under
    // the short name (`wireRules`), so a rule whose only condition is e.g. `rule_set` reads
    // nothing from `rule[key]`. Column first, short name second — the same order
    // `ruleFromWire` uses.
    final raw = rule['${key}_json'] ?? rule[key];
    final List<String> items;
    if (raw is List) {
      items = raw.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
    } else {
      final value = raw?.toString().trim() ?? '';
      items = value.isEmpty ? const <String>[] : [value];
    }
    if (items.isEmpty) return '';
    return '$label: ${items.first}${items.length > 1 ? ' +${items.length - 1}' : ''}';
  }

  String scalar(String label, String key) {
    final value = rule[key]?.toString().trim() ?? '';
    return value.isEmpty ? '' : '$label: $value';
  }

  final parts = <String>[
    list('suffix', 'domain_suffix'),
    list('domain', 'domain'),
    list('keyword', 'domain_keyword'),
    list('regex', 'domain_regex'),
    list('rule-set', 'rule_set'),
    list('ip', 'ip_cidr'),
    if (rule['ip_is_private'] == true) context.tr('Private IP'),
    list('app', 'package_name'),
    list('app regex', 'package_name_regex'),
    list('process', 'process_name'),
    list('path', 'process_path'),
    list('path regex', 'process_path_regex'),
    list('port', 'port'),
    list('port range', 'port_range'),
    scalar('protocol', 'protocol'),
    scalar('network', 'network'),
    scalar('ip version', 'ip_version'),
    list('source ip', 'source_ip_cidr'),
    if (rule['source_ip_is_private'] == true) context.tr('Private source IP'),
    list('source port', 'source_port'),
    list('source port range', 'source_port_range'),
    list('inbound', 'inbound'),
    list('network type', 'network_type'),
    if (rule['network_is_expensive'] == true) context.tr('Metered'),
    list('ssid', 'wifi_ssid'),
    list('bssid', 'wifi_bssid'),
  ].where((part) => part.isNotEmpty).toList();
  if (parts.isEmpty) parts.add(context.tr('No conditions'));
  if (rule['invert'] == true) parts.add(context.tr('Inverted'));
  return parts.join(' · ');
}

/// The rule row's two lines, Throne's layout_route_rule_item: the action on
/// top in its colour, the conditions under it in the secondary tone. One Text
/// with the subtitle style the list rows already use, so the row reads like
/// any other while the action line carries the route palette.
Widget ruleRowSubtitle(BuildContext context, Json rule) {
  final action = rule['action']?.toString() ?? 'route';
  final actionColor = routeActionColor(
      context, action, (rule['outbound_id'] as num?)?.toInt() ?? 0);
  final base = context.listSubtitleStyle;
  final colorScheme = Theme.of(context).colorScheme;
  final state = context.tr(rule['disabled'] == true ? 'Disabled' : 'Enabled');
  return Text.rich(
    TextSpan(children: [
      TextSpan(text: '$state · ', style: base.copyWith(color: rule['disabled'] == true ? colorScheme.error : null)),
      TextSpan(
          text: ruleActionText(rule),
          style: base.copyWith(color: actionColor, fontWeight: FontWeight.w500)),
      TextSpan(
          text: '\n${ruleConditions(context, rule)}',
          style: base.copyWith(fontWeight: FontWeight.normal)),
    ]),
  );
}
