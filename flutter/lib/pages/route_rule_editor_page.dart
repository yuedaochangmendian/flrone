// One route rule, Throne for Android's RouteRuleActivity: the well-known fields
// on top, everything else in a collapsed "Advanced" group, and the action-driven
// visibility the native form applies (a reject rule has a reject method, a route
// rule has an outbound, a sniff rule has sniffers).
//
// The field set is RouteRule.kt's: 45 members. `type` and `disabled` are row
// metadata (the simple-address family decides some fixed actions), the rest are
// conditions and options.
//
// Wire spelling
// -------------
// The kernel echoes a rule with both its column names (`domain_json`) and, for
// five conditions, the short name (`domain`). A save that sent both could land
// either spelling depending on map iteration, so this page canonicalises: reads
// take the column name first and the short name second, writes emit the column
// names only. Every other key the wire carried is preserved untouched, which is
// what keeps a rule the editor cannot represent alive across an edit of its
// neighbour.

import '../components/form.dart';
import '../widgets.dart';

/// One rule from the wire (`routeRules`) into the editor's flat map.
Json ruleFromWire(Json wire) {
  final rule = <String, dynamic>{
    'name': wire['name']?.toString() ?? '',
    'type': wire['type']?.toString() ?? 'custom',
    'disabled': wire['disabled'] == true,
    'action': wire['action']?.toString() ?? 'route',
    'outbound_id': (wire['outbound_id'] as num?)?.toInt() ?? -2,
  };
  for (final key in ruleStringFields) {
    rule[key] = wire[key]?.toString() ?? '';
  }
  for (final key in ruleListFields) {
    final values = wire['${key}_json'] ?? wire[key];
    rule[key] = _strings(values);
  }
  for (final key in ruleBoolFields) {
    rule[key] = wire[key] == true;
  }
  // Keys this build has no editor for survive the round trip.
  for (final entry in wire.entries) {
    if (rule.containsKey(entry.key) || entry.key.endsWith('_json')) continue;
    rule[entry.key] = entry.value;
  }
  return rule;
}

/// The editor's flat map back to the kernel's rule shape: the column names the
/// store marshals, plus the metadata fields. Empty lists and strings are left
/// out — a stored empty condition is the same as no condition, and leaving them
/// out keeps the wire small.
Json ruleToWire(Json rule) {
  final wire = <String, dynamic>{
    'name': rule['name']?.toString() ?? '',
    'type': rule['type']?.toString() ?? 'custom',
    'disabled': rule['disabled'] == true,
    'action': rule['action']?.toString() ?? 'route',
    'outbound_id': (rule['outbound_id'] as num?)?.toInt() ?? -2,
  };
  for (final key in ruleStringFields) {
    final value = rule[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) wire[key] = value;
  }
  for (final key in ruleListFields) {
    final values = _strings(rule[key]);
    if (values.isNotEmpty) wire['${key}_json'] = values;
  }
  for (final key in ruleBoolFields) {
    if (rule[key] == true) wire[key] = true;
  }
  for (final entry in rule.entries) {
    if (wire.containsKey(entry.key) || ruleStringFields.contains(entry.key) ||
        ruleListFields.contains(entry.key) || ruleBoolFields.contains(entry.key)) {
      continue;
    }
    wire[entry.key] = entry.value;
  }
  return wire;
}

/// `RouteRule.STRING_FIELDS`.
const ruleStringFields = [
  'ip_version', 'network', 'protocol', 'reject_method', 'override_address',
  'override_port', 'tls_fragment_fallback_delay', 'tls_spoof', 'tls_spoof_method', 'strategy',
];

/// `RouteRule.LIST_FIELDS`.
const ruleListFields = [
  'inbound', 'domain', 'domain_suffix', 'domain_keyword', 'domain_regex', 'source_ip_cidr',
  'ip_cidr', 'source_port', 'source_port_range', 'port', 'port_range', 'process_name',
  'process_path', 'process_path_regex', 'package_name', 'package_name_regex', 'network_type',
  'wifi_ssid', 'wifi_bssid', 'rule_set', 'sniffers',
];

/// `RouteRule.BOOL_FIELDS`.
const ruleBoolFields = [
  'source_ip_is_private', 'ip_is_private', 'tls_fragment', 'tls_record_fragment',
  'invert', 'no_drop', 'sniff_override_dest', 'network_is_expensive',
];

List<String> _strings(Object? value) {
  if (value is List) {
    return [for (final item in value) item.toString().trim()].where((item) => item.isNotEmpty).toList();
  }
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) return <String>[];
  // A hand-typed value may carry one per line or a comma-separated list.
  return text.split(RegExp(r'[\n,]')).map((item) => item.trim()).where((item) => item.isNotEmpty).toList();
}

/// The fixed match targets (`OutboundIds`): proxy, direct, block, WARP bypass.
const routeRuleTargets = [(-1, 'Proxy'), (-2, 'Direct'), (-3, 'Block'), (-5, 'WARP bypass')];

/// The rule's own page. [initial] is the editor-shaped rule (see [ruleFromWire]);
/// the page answers the edited rule, or `null` on dismissal. Delete answers
/// [RouteRuleEditorResult.deleted] through the same result.
class RouteRuleEditorPage extends StatefulWidget {
  const RouteRuleEditorPage({super.key, required this.initial, this.isNew = false});

  final Json initial;
  final bool isNew;

  @override
  State<RouteRuleEditorPage> createState() => _RouteRuleEditorPageState();
}

/// What the rule page answers: an edited rule, or the request to delete it.
class RouteRuleEditorResult {
  const RouteRuleEditorResult.rule(this.rule) : deleted = false;
  const RouteRuleEditorResult.deleted()
      : rule = null,
        deleted = true;

  final Json? rule;
  final bool deleted;
}

class _RouteRuleEditorPageState extends State<RouteRuleEditorPage> {
  late Json _rule = {...widget.initial};
  bool _advanced = false;
  final _name = TextEditingController();
  final _listControllers = <String, TextEditingController>{};

  @override
  void initState() {
    super.initState();
    _name.text = _rule['name']?.toString() ?? '';
    _advanced = _hasAdvancedValues;
  }

  @override
  void dispose() {
    _name.dispose();
    for (final controller in _listControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  /// A rule that already fills an advanced field opens with the group expanded:
  /// hiding the value of a rule that carries it would read as a lost edit.
  bool get _hasAdvancedValues => const [
        'domain_keyword', 'domain_regex', 'ip_is_private', 'source_ip_cidr',
        'source_ip_is_private', 'port', 'port_range', 'source_port', 'source_port_range',
        'invert', 'override_address', 'override_port', 'tls_fragment', 'tls_record_fragment',
        'no_drop', 'package_name_regex', 'process_name', 'process_path', 'process_path_regex',
        'network_is_expensive', 'wifi_ssid', 'wifi_bssid', 'tls_spoof', 'sniffers',
      ].any((key) {
        final value = _rule[key];
        return value is List ? value.isNotEmpty : value != null && value != false && '$value'.isNotEmpty;
      });

  String get _action => _rule['action']?.toString() ?? 'route';

  bool get _routes => _action == 'route' || _action == 'bypass' || _action == 'route-options';

  void _set(String key, Object? value) {
    setState(() {
      if (value == null) {
        _rule.remove(key);
      } else {
        _rule[key] = value;
      }
    });
  }

  Future<void> _pickEnum(String key, String title) async {
    final current = _rule[key]?.toString() ?? '';
    final picked = await showOptionSheet<String>(
      context: context,
      title: context.tr(title),
      options: [for (final option in ruleEnumOptions(key, current)) (option.value, option.label)],
      selected: current,
    );
    if (picked == null || !mounted) return;
    setState(() => _rule = ruleEnumApply(_rule, key, picked));
  }

  Future<void> _pickOutbound() async {
    final current = (_rule['outbound_id'] as num?)?.toInt() ?? -2;
    final options = <(int, String)>[
      for (final (id, label) in routeRuleTargets) (id, context.tr(label)),
    ];
    // The server profiles are a real target too: their tags resolve through the
    // group catalog, and the kernel stores the id.
    try {
      for (final node in await context.box.groupNodes()) {
        final id = (node['id'] as num?)?.toInt() ?? 0;
        final tag = node['tag']?.toString() ?? '';
        if (id > 0 && tag.isNotEmpty) options.add((id, tag));
      }
    } catch (_) {
      // No catalog (the API is off): the four fixed targets still stand.
    }
    if (!mounted) return;
    final picked = await showOptionSheet<int>(
      context: context,
      title: context.tr('Outbound'),
      options: options,
      selected: current,
    );
    if (picked != null && mounted) _set('outbound_id', picked);
  }

  Future<void> _editLines(String key, String title) async {
    final hint = ruleFieldHint(context, key);
    final initial = _strings(_rule[key]).join('\n');
    final text = await showAppDialog<String>(
      context,
      child: _LinesDialog(title: context.tr(title), hint: hint, initial: initial),
    );
    if (text == null || !mounted) return;
    final values = text.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).toList();
    _set(key, values.isEmpty ? null : values);
  }

  /// The rule-set picker: a search over the installed catalog, filtered to
  /// public http(s) URLs the core may download from.
  Future<void> _pickRuleSets() async {
    final picked = await showAppDialog<List<String>>(
      context,
      child: _RuleSetPicker(initial: _strings(_rule['rule_set'])),
    );
    if (picked == null || !mounted) return;
    _set('rule_set', picked.isEmpty ? null : picked);
  }

  void _save() {
    final rule = <String, dynamic>{..._rule, 'name': _name.text.trim()};
    if ((rule['action']?.toString() ?? 'route') != 'reject') {
      rule.remove('reject_method');
      rule.remove('no_drop');
    } else {
      rule.remove('outbound_id');
    }
    Navigator.pop(context, RouteRuleEditorResult.rule(rule));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      title: context.tr(widget.isNew ? 'Add rule' : 'Edit rule'),
      confirmationAction: IconButtonData(
        glyph: AppGlyphs.check,
        tooltip: context.tr('Save'),
        onPressed: _save,
      ),
      iconActions: [
        if (!widget.isNew)
          IconButtonData(
            glyph: AppGlyphs.delete,
            tooltip: context.tr('Delete'),
            onPressed: () => Navigator.pop(context, const RouteRuleEditorResult.deleted()),
          ),
      ],
      body: ListView(
        // The first child is a titled section, whose header carries its own
        // top gap; sectionsTopPadding keeps that from doubling the page inset.
        padding: boxPagePadding(context).copyWith(top: context.sectionsTopPadding),
        children: [
          generateSection(title: context.tr('Rule'), items: [
            ListItem(
              title: Text(context.tr('Name'), maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * .45),
                child: TooltipText(text: Text(
                  _rule['name']?.toString() ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.end,
                  style: context.listValueStyle,
                )),
              ),
              onTap: () async {
                final edited = await showAppDialog<String>(
                  context,
                  child: InputDialog(title: context.tr('Name'), value: _rule['name']?.toString() ?? ''),
                );
                if (edited != null) _set('name', edited);
              },
            ),
            ListItem(
              title: Text(context.tr('Action')),
              trailing: Text(context.tr(ruleEnumLabel('action', _action)), style: context.listValueStyle),
              onTap: () => _pickEnum('action', 'Action'),
            ),
            if (_routes)
              ListItem(
                title: Text(context.tr('Outbound')),
                trailing: Text(_outboundLabel(context), style: context.listValueStyle),
                onTap: _pickOutbound,
              ),
            if (_action == 'reject')
              ListItem(
                title: Text(context.tr('Reject method')),
                trailing: Text(ruleEnumLabel('reject_method', _rule['reject_method']?.toString() ?? ''),
                    style: context.listValueStyle),
                onTap: () => _pickEnum('reject_method', 'Reject method'),
              ),
            if (_action == 'reject')
              ListItem.toggle(
                title: Text(context.tr('Keep the connection open')),
                value: _rule['no_drop'] == true,
                onChanged: (value) => _set('no_drop', value),
              ),
            if (_action == 'resolve')
              ListItem(
                title: Text(context.tr('Strategy')),
                trailing: Text(ruleEnumLabel('strategy', _rule['strategy']?.toString() ?? ''),
                    style: context.listValueStyle),
                onTap: () => _pickEnum('strategy', 'Strategy'),
              ),
            if (_action == 'sniff')
              ListItem(
                title: Text(context.tr('Sniffers')),
                subtitle: Text(_strings(_rule['sniffers']).join(', ')),
                onTap: () => _editLines('sniffers', 'Sniffers'),
              ),
            ListItem.toggle(
              title: Text(context.tr('Override the destination')),
              subtitle: Text(context.tr('Use the sniffed host instead of the dialled one.')),
              value: _rule['sniff_override_dest'] == true,
              onChanged: (value) => _set('sniff_override_dest', value),
            ),
          ]),
          generateSection(title: context.tr('Match'), items: [
            _linesRow('domain_suffix', 'Domain suffix'),
            _linesRow('domain', 'Domain'),
            _linesRow('ip_cidr', 'IP CIDR'),
            ListItem(
              title: Text(context.tr('Rule set')),
              subtitle: Text(_strings(_rule['rule_set']).join(', ')),
              onTap: _pickRuleSets,
            ),
            _linesRow('package_name', 'Apps'),
            ListItem(
              title: Text(context.tr('Network type')),
              subtitle: Text(_strings(_rule['network_type']).join(', ')),
              onTap: () => _pickNetworkTypes(),
            ),
          ]),
          const SizedBox(height: 8),
          generateSection(items: [
            ListItem(
              leading: GlyphIcon(_advanced ? AppGlyphs.chevronUp : AppGlyphs.chevronDown),
              title: Text(context.tr('Advanced')),
              subtitle: Text(context.tr('Keywords, ports, protocols, TLS options and the WiFi conditions.')),
              onTap: () => setState(() => _advanced = !_advanced),
            ),
          ]),
          if (_advanced) ...[
            generateSection(items: [
              _linesRow('domain_keyword', 'Domain keyword'),
              _linesRow('domain_regex', 'Domain regex'),
              ListItem.toggle(
                title: Text(context.tr('Private IP')),
                value: _rule['ip_is_private'] == true,
                onChanged: (value) => _set('ip_is_private', value),
              ),
              _linesRow('source_ip_cidr', 'Source IP CIDR'),
              ListItem.toggle(
                title: Text(context.tr('Private source IP')),
                value: _rule['source_ip_is_private'] == true,
                onChanged: (value) => _set('source_ip_is_private', value),
              ),
              _linesRow('port', 'Port'),
              _linesRow('port_range', 'Port range'),
              _linesRow('source_port', 'Source port'),
              _linesRow('source_port_range', 'Source port range'),
              ListItem(
                title: Text(context.tr('Network')),
                trailing: Text(ruleEnumLabel('network', _rule['network']?.toString() ?? ''),
                    style: context.listValueStyle),
                onTap: () => _pickEnum('network', 'Network'),
              ),
              ListItem(
                title: Text(context.tr('Protocol')),
                trailing: Text(ruleEnumLabel('protocol', _rule['protocol']?.toString() ?? ''),
                    style: context.listValueStyle),
                onTap: () => _pickEnum('protocol', 'Protocol'),
              ),
              ListItem(
                title: Text(context.tr('IP version')),
                trailing: Text(ruleEnumLabel('ip_version', _rule['ip_version']?.toString() ?? ''),
                    style: context.listValueStyle),
                onTap: () => _pickEnum('ip_version', 'IP version'),
              ),
              _linesRow('inbound', 'Inbound'),
              ListItem.toggle(
                title: Text(context.tr('Invert')),
                subtitle: Text(context.tr('Match what the conditions do NOT list.')),
                value: _rule['invert'] == true,
                onChanged: (value) => _set('invert', value),
              ),
              if (_routes) ...[
                ListItem.input(
                  title: Text(context.tr('Override address')),
                  dialogTitle: context.tr('Override address'),
                  value: _rule['override_address']?.toString() ?? '',
                  onChanged: (value) => _set('override_address', value),
                ),
                ListItem.input(
                  title: Text(context.tr('Override port')),
                  dialogTitle: context.tr('Override port'),
                  keyboardType: TextInputType.number,
                  value: _rule['override_port']?.toString() ?? '',
                  onChanged: (value) => _set('override_port', value),
                ),
                ListItem.toggle(
                  title: Text(context.tr('TLS fragment')),
                  value: _rule['tls_fragment'] == true,
                  onChanged: (value) => _set('tls_fragment', value),
                ),
                if (_rule['tls_fragment'] == true)
                  ListItem.input(
                    title: Text(context.tr('Fragment fallback delay')),
                    dialogTitle: context.tr('Fragment fallback delay'),
                    hintText: 'e.g. 500ms',
                    value: _rule['tls_fragment_fallback_delay']?.toString() ?? '',
                    onChanged: (value) => _set('tls_fragment_fallback_delay', value),
                  ),
                ListItem.toggle(
                  title: Text(context.tr('TLS record fragment')),
                  value: _rule['tls_record_fragment'] == true,
                  onChanged: (value) => _set('tls_record_fragment', value),
                ),
              ],
              _linesRow('package_name_regex', 'Package name regex'),
              _linesRow('process_name', 'Process name'),
              _linesRow('process_path', 'Process path'),
              _linesRow('process_path_regex', 'Process path regex'),
              ListItem.toggle(
                title: Text(context.tr('Metered network')),
                value: _rule['network_is_expensive'] == true,
                onChanged: (value) => _set('network_is_expensive', value),
              ),
              _linesRow('wifi_ssid', 'WiFi network name'),
              _linesRow('wifi_bssid', 'WiFi access point'),
            ]),
          ],
        ],
      ),
    );
  }

  ListItem _linesRow(String key, String title) => ListItem(
        title: Text(context.tr(title)),
        subtitle: Text(_summaryOf(key)),
        onTap: () => _editLines(key, title),
      );

  String _summaryOf(String key) {
    final values = _strings(_rule[key]);
    if (values.isEmpty) return context.tr('Not set');
    return values.length == 1 ? values.first : '${values.first} +${values.length - 1}';
  }

  String _outboundLabel(BuildContext context) {
    final id = (_rule['outbound_id'] as num?)?.toInt() ?? -2;
    for (final (targetId, label) in routeRuleTargets) {
      if (targetId == id) return context.tr(label);
    }
    return id > 0 ? context.tr('Server') : outboundToken(id);
  }

  Future<void> _pickNetworkTypes() async {
    const values = ['wifi', 'cellular', 'ethernet', 'other'];
    final picked = await showOptionSheet<String>(
      context: context,
      title: context.tr('Network type'),
      options: [
        for (final value in values) (value, value),
      ],
      selected: _strings(_rule['network_type']).firstOrNull,
    );
    if (picked == null || !mounted) return;
    final current = _strings(_rule['network_type']);
    if (current.contains(picked)) {
      current.remove(picked);
    } else {
      current.add(picked);
    }
    _set('network_type', current.isEmpty ? null : current);
  }
}

/// A multiline value editor, the same treatment `rule_import.dart` gives a
/// pasted fragment: one value per line, monospace, no suggestions.
class _LinesDialog extends StatefulWidget {
  const _LinesDialog({required this.title, required this.hint, required this.initial});

  final String title, hint, initial;

  @override
  State<_LinesDialog> createState() => _LinesDialogState();
}

class _LinesDialogState extends State<_LinesDialog> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        hasFields: true,
        title: widget.title,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(widget.hint, style: AppTextStyle.caption1.of(context)),
          ),
          TextField(
            key: const Key('route-rule-lines-field'),
            controller: _controller,
            minLines: 4,
            maxLines: 10,
            autocorrect: false,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
            decoration: const InputDecoration(),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(context.tr('Save'))),
        ],
      );
}

/// The rule-set catalog picker: search `routes.ruleSets`, list what the catalog
/// answers, and refuse a URL the core must not download from.
class _RuleSetPicker extends StatefulWidget {
  const _RuleSetPicker({required this.initial});

  final List<String> initial;

  @override
  State<_RuleSetPicker> createState() => _RuleSetPickerState();
}

class _RuleSetPickerState extends State<_RuleSetPicker> {
  final _selected = <String>{};
  final _search = TextEditingController();
  List<Json> _entries = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selected.addAll(widget.initial);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final answer = json(await context.box.routeRuleSets(_search.text.trim(), 50));
      if (!mounted) return;
      setState(() {
        _entries = rows(answer['entries']);
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = BoxController.describe(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Surface(
      color: SurfaceLevel.floatingOf(context.colorScheme).colorOf(context.colorScheme),
      shape: AppShape.all(AppCorner.alert),
      child: Material(
        type: MaterialType.transparency,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.sizeOf(context).height * .8),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(context.tr('Rule set'), style: AppTextStyle.title3.of(context, emphasized: true)),
              const SizedBox(height: 12),
              TextField(
                key: const Key('route-rule-set-search'),
                controller: _search,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: context.tr('Search'),
                  suffixIcon: IconButton(
                    tooltip: context.tr('Search'),
                    icon: const GlyphIcon(AppGlyphs.search),
                    onPressed: _load,
                  ),
                ),
                onSubmitted: (_) => _load(),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: _loading
                    ? const Center(child: ActivityIndicator.page())
                    : _error != null
                        ? ErrorState(_error!, retry: _load)
                        : ListView(
                            shrinkWrap: true,
                            children: [
                              for (final entry in _entries)
                                ListItem.checkbox(
                                  value: _selected.contains(entry['name']?.toString() ?? ''),
                                  title: Text(entry['name']?.toString() ?? ''),
                                  subtitle: Text(
                                    entry['url']?.toString() ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  onChanged: (value) => setState(() {
                                    final name = entry['name']?.toString() ?? '';
                                    if (value == true) {
                                      _selected.add(name);
                                    } else {
                                      _selected.remove(name);
                                    }
                                  }),
                                ),
                              if (_entries.isEmpty)
                                ListItem(title: Text(context.tr('No results'))),
                            ],
                          ),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(context.tr('Cancel'))),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected.toList()),
                  child: Text(context.tr('Save')),
                ),
              ]),
            ]),
          ),
        ),
      ),
    );
  }
}
