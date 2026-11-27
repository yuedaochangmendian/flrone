// The five document-only profile ops that moved off `profiles.platform`.
//
// `stats`, `reorder`, `clearTestResults`, `nodeList` and `nodeReorder` used to
// be Kotlin handlers in FlroneProfileDuty. None of them needed the Throne
// outbound model for the write itself: each one read or edited the same
// `profiles.json` document Dart owns (the Kotlin `nodeReorder`/`reorder` paths
// even forwarded the write back through `DartProfileWriter`). They live here
// now, on the existing [ConfigurationStore] — still one writer, one atomic
// edit, no second document.
//
// Two host interactions deliberately stay:
//
//  * `sort.reposition` — clearing test results also repositions rows in a group
//    kept sorted BY_TEST_RESULT/BY_LATENCY ([GroupSort] in Kotlin). Those sort
//    keys read the parsed outbound model (type/name/address/security) Dart does
//    not have, so [clearTestResults] clears the document and then asks the host
//    for that one narrow action. The alternative — a Dart re-implementation of
//    GroupSort — is the second model ADR 0002 forbids; port it before moving the
//    duty.
//  * `data.refresh` — Kotlin reads the same document through DartProfileStore's
//    mtime cache. Every write here calls the existing refresh path (which
//    invalidates that cache and schedules the catalog push), so Kotlin readers
//    never answer pre-write rows. Dart-local reads never need it.
//
// Wire results are the ones the pages consume:
//  * `stats`          -> {groups: 1, outbounds, rules}
//  * `nodeList`       -> {groupId, groupName, nodes: [{id, name, type, delay, testedAt}]}
//  * the other three  -> no reply (the facades answer their own bool).

import 'dart:convert';
import 'dart:io';

import 'configuration_store.dart';
import 'configuration_store_source.dart';

/// The host-side `data.refresh` (Kotlin invalidates its document cache and
/// schedules the catalog push).
typedef ProfileDocumentRefresh = Future<void> Function();

/// The one narrow Kotlin duty left from `clearTestResults`: GroupSort's
/// test-result reposition (`profiles.platform` op `sort.reposition`).
typedef ProfileTestResultReposition = Future<void> Function(int groupId);

/// Reads `global_route_rules.json`'s rows, or null when the document is
/// missing/unreadable. Injected by tests; the default reads the file.
typedef ProfileRouteRulesReader =
    Future<List<Map<String, Object?>>?> Function(String documentsDir);

/// The localized default group name (`data.path`'s `defaultGroupName`).
typedef ProfileDefaultGroupNameReader = Future<String> Function();

/// The Dart-owned half of the old `profiles.platform` document ops.
class ProfileDocumentService {
  ProfileDocumentService({
    required this.storeSource,
    required this.refreshCatalog,
    required this.repositionTestResults,
    ProfileRouteRulesReader? readRouteRules,
    ProfileDefaultGroupNameReader? readDefaultGroupName,
  })  : _readRouteRules = readRouteRules ?? _readRouteRulesFromDisk,
        _readDefaultGroupName = readDefaultGroupName ?? _defaultGroupNameFallback;

  final ConfigurationStoreSource storeSource;
  final ProfileDocumentRefresh refreshCatalog;
  final ProfileTestResultReposition repositionTestResults;
  final ProfileRouteRulesReader _readRouteRules;
  final ProfileDefaultGroupNameReader _readDefaultGroupName;

  /// Kotlin's `R.string.group_default_name` when the host cannot answer.
  static const String defaultGroupNameFallback = 'Default';

  String? _defaultGroupName;

  /// `FlroneProfiles.stats`: the group card's three counts.
  ///
  /// `groups` stays 1 (the card is one configuration), `outbounds` is the
  /// document's membership count and `rules` is the global rule table after
  /// [RouteManager]'s stale-outbound filter — a rule that names an outbound no
  /// longer in the document never reaches a build, so it is not counted.
  Future<Map<String, dynamic>> stats(int groupId) async {
    final store = await storeSource.store();
    final document = await store.document;
    var outbounds = 0;
    for (final profile in document.profiles) {
      if (profile.gid == groupId) outbounds++;
    }
    final rules = await _globalRuleCount(store, document);
    return <String, dynamic>{
      'groups': 1,
      'outbounds': outbounds,
      'rules': rules,
    };
  }

  /// `FlroneProfiles.reorder`: the profile grid's tab order.
  ///
  /// The listed ids come first (duplicates and ids absent from the document
  /// are dropped, as `GroupRepo.setDisplayOrder` did), the rest follow in their
  /// current order.
  Future<void> reorderGroups(List<int> ids) async {
    final store = await storeSource.store();
    final document = await store.document;
    final existing = <int>[for (final group in document.groups) group.id];
    final wanted = _distinct(ids);
    final ordered = <int>[
      ...wanted.where(existing.contains),
      ...existing.where((id) => !ids.contains(id)),
    ];
    if (ordered.isEmpty) {
      // No groups to order. The old Kotlin op still scheduled its catalog
      // refresh; keep that, but do not create a document for a no-op.
      await refreshCatalog();
      return;
    }
    await store.reorderGroups(ordered);
    await refreshCatalog();
  }

  /// `FlroneProfiles.clearGroupTestResults`: clear every member's stored test
  /// columns, then let Kotlin's kept sort reposition the rows.
  Future<void> clearTestResults(int groupId) async {
    final store = await storeSource.store();
    final document = await store.document;
    final hasMembers = document.profiles.any((profile) => profile.gid == groupId);
    if (hasMembers) {
      // The document edit is the whole write; `clearedTestResults()` mirrors
      // ProxyEntity.clearTestResults (traffic and outbound data survive).
      await store.clearGroupTestResults(groupId);
    }
    // The old path always posted its catalog reload; the refresh also
    // invalidates Kotlin's parsed snapshot before the sort duty reads it.
    await refreshCatalog();
    if (hasMembers) await repositionTestResults(groupId);
  }

  /// `FlroneProfiles.listNodes`: the single-node container's rows in list order.
  ///
  /// This is the port of the old prune as well: opening the page removes empty
  /// single-node containers an older build left behind (the two-container
  /// "Default" duplication). The delete is a plain document edit; the Kotlin
  /// `current_group` setting self-heals (`GroupRepo.currentId()` falls back to
  /// the first group when the stored id is gone), and an empty container cannot
  /// hold the selected/running profile, so no service stop or selection clear
  /// is needed — the one side effect `GroupRepo.delete` would have had.
  ///
  /// Known rendering difference from the Kotlin op: the wire's `name`/`type`
  /// come from the documented columns, not from re-parsing `outbound_json`.
  /// A row whose stored name is empty renders the protocol label instead of the
  /// parsed server address; a corrupt row renders its stored type instead of
  /// Kotlin's InvalidOutbound reason. Single nodes are created through the typed
  /// form or the importer, both of which store a name, so this only affects
  /// hand-edited documents.
  Future<Map<String, dynamic>> nodeList() async {
    final store = await storeSource.store();
    final document = await store.document;
    final defaultName = await _groupDefaultName();

    if (await _pruneEmptyNodeContainers(store, document, defaultName)) {
      // The old prune refreshed only when it actually removed a container.
      await refreshCatalog();
    }

    final containers = _containers(document.groups, defaultName);
    final container = containers.isEmpty ? null : containers.first;
    final groupId = container?.id ?? 0;
    final nodes = groupId > 0
        ? await store.profilesOfGroup(groupId)
        : const <NodeRow>[];
    return <String, dynamic>{
      'groupId': groupId,
      'groupName': container == null
          ? ''
          : _groupDisplayName(container, defaultName),
      'nodes': <Map<String, Object?>>[
        for (final node in nodes)
          <String, Object?>{
            'id': node.id,
            'name': _nodeName(node),
            'type': _nodeType(node),
            'delay': node.latency,
            'testedAt': node.latencyAt * 1000,
          },
      ],
    };
  }

  /// `FlroneProfiles.reorderNodes`: the container's member order in the
  /// profiles document (dense `user_order`, the rest keep their relative order).
  Future<void> reorderNodes(int groupId, List<int> ids) async {
    final store = await storeSource.store();
    await store.reorderGroup(groupId, ids);
    await refreshCatalog();
  }

  // --- route rules ---------------------------------------------------------

  /// The build's global rule count: every row whose `outbound_id` is absent or
  /// still names a document profile (`RouteManager.dropStaleOutbounds`).
  Future<int> _globalRuleCount(
    ConfigurationStore store,
    ProfilesDocument document,
  ) async {
    final rows =
        await _readRouteRules(_documentsDir(store.path)) ?? const <Map<String, Object?>>[];
    if (rows.isEmpty) return 0;
    final ids = <int>{for (final profile in document.profiles) profile.id};
    var count = 0;
    for (final row in rows) {
      final outboundId = _asInt(row['outbound_id'], fallback: -1);
      if (outboundId <= 0 || ids.contains(outboundId)) count++;
    }
    return count;
  }

  /// The default reader: `<documents>/global_route_rules.json`, the envelope Go
  /// writes. Missing/unreadable is null, which the caller treats as an empty
  /// table — the same answer `RouteJsonStore.allGlobalRules()` gives.
  ///
  /// Synchronous like `RouteDocuments.readTable` (the backup path's reader of
  /// the same document): the file is the kernel's one rule table and this read
  /// happens when the profile card's counts are requested, not per frame. It
  /// also keeps the call fake-time-safe in widget tests, where a real async
  /// file read never completes (the rule-set picker hit the same trap).
  static Future<List<Map<String, Object?>>?> _readRouteRulesFromDisk(
    String documentsDir,
  ) async {
    final file = File(
      '$documentsDir${Platform.pathSeparator}global_route_rules.json',
    );
    try {
      if (!file.existsSync()) return null;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      final rows = decoded['rows'];
      if (rows is! List) return null;
      return <Map<String, Object?>>[
        for (final row in rows)
          if (row is Map) Map<String, Object?>.from(row),
      ];
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  /// `<files>/documents` is the parent of the profiles document the store owns.
  static String _documentsDir(String profilesPath) =>
      File(profilesPath).parent.path;

  // --- single-node container (FlroneProfiles.listNodes/prune) --------------

  static Future<String> _defaultGroupNameFallback() async =>
      defaultGroupNameFallback;

  Future<String> _groupDefaultName() async {
    final cached = _defaultGroupName;
    if (cached != null) return cached;
    try {
      final name = await _readDefaultGroupName();
      if (name.trim().isNotEmpty) {
        _defaultGroupName = name;
        return name;
      }
    } on Object {
      // The host fact is cosmetic (a legacy container's localized label); a
      // failed lookup must not fail the page.
    }
    return defaultGroupNameFallback;
  }

  /// `ProxyGroup.isSingleNodeGroup()`: the flagged document row, or a row that
  /// predates the flag and still carries a blank/default name.
  static bool _isSingleNodeGroup(
    ConfigurationRow group,
    String defaultName,
  ) {
    if (group.isSubscription) return false;
    return group.single ||
        group.name.trim().isEmpty ||
        group.name == defaultName;
  }

  static List<ConfigurationRow> _containers(
    List<ConfigurationRow> groups,
    String defaultName,
  ) =>
      <ConfigurationRow>[
        for (final group in _tabOrder(groups))
          if (_isSingleNodeGroup(group, defaultName)) group,
      ];

  /// `DartProfileStore.groups()` order: display order, document order on ties.
  static List<ConfigurationRow> _tabOrder(List<ConfigurationRow> groups) {
    final indexed = <({int index, ConfigurationRow group})>[
      for (var index = 0; index < groups.length; index++)
        (index: index, group: groups[index]),
    ];
    indexed.sort((a, b) {
      final byOrder = a.group.displayOrder.compareTo(b.group.displayOrder);
      return byOrder != 0 ? byOrder : a.index.compareTo(b.index);
    });
    return <ConfigurationRow>[for (final entry in indexed) entry.group];
  }

  /// `ProxyGroup.displayName()`: a blank name is the localized default.
  static String _groupDisplayName(ConfigurationRow group, String defaultName) =>
      group.name.trim().isEmpty ? defaultName : group.name;

  /// The old prune: keep the first container that holds nodes (or the first
  /// container when none does), delete every other empty one. The store refuses
  /// to delete the last group, matching `GroupRepo.delete`.
  static Future<bool> _pruneEmptyNodeContainers(
    ConfigurationStore store,
    ProfilesDocument document,
    String defaultName,
  ) async {
    final containers = _containers(document.groups, defaultName);
    if (containers.isEmpty) return false;
    final members = <int, int>{};
    for (final profile in document.profiles) {
      members[profile.gid] = (members[profile.gid] ?? 0) + 1;
    }
    final keep = containers.firstWhere(
      (group) => (members[group.id] ?? 0) > 0,
      orElse: () => containers.first,
    );
    var removed = false;
    for (final group in containers) {
      if (group.id == keep.id) continue;
      if ((members[group.id] ?? 0) > 0) continue;
      if (await store.deleteGroup(group.id)) removed = true;
    }
    return removed;
  }

  // --- node row rendering (ProxyEntity.displayName/displayType) -----------

  /// The display label for the canonical protocol types
  /// (`OutboundFactory`'s creators and their `displayType()` values). The
  /// document stores the raw type; the old wire carried the parsed label.
  static const Map<String, String> _typeLabels = <String, String>{
    'socks': 'Socks',
    'http': 'HTTP',
    'shadowsocks': 'Shadowsocks',
    'vmess': 'VMess',
    'vless': 'VLESS',
    'trojan': 'Trojan',
    'hysteria': 'Hysteria',
    // OutboundFactory's aliases: old/hand-written rows may carry the URI type
    // rather than the creator's canonical type.
    'hysteria2': 'Hysteria',
    'openvpn-client': 'OpenVPN',
    'tuic': 'TUIC',
    'juicity': 'Juicity',
    'trusttunnel': 'TrustTunnel',
    'anytls': 'AnyTLS',
    'mieru': 'Mieru',
    'snell': 'Snell',
    'shadowtls': 'ShadowTLS',
    'wireguard': 'WireGuard',
    'masque': 'MASQUE',
    'openvpn': 'OpenVPN',
    'openconnect': 'OpenConnect',
    'ssh': 'SSH',
    'naive': 'Naive',
    'chain': 'Chain Proxy',
    'direct': 'Direct',
    'autoselector': 'Auto Selector',
  };

  /// `ProxyEntity.displayName()`: the stored outbound name, or the display
  /// type when the row has none (Kotlin would render the parsed address there;
  /// see the class note on the one rendering difference).
  static String _nodeName(NodeRow node) {
    final name = node.name ?? '';
    return name.isEmpty ? _nodeType(node) : name;
  }

  /// `ProxyEntity.displayType()` for the raw stored type. `custom` keeps its
  /// three shapes (`Custom Config`, `Custom <Type> Outbound`, `Custom
  /// Outbound`) because the marker lives in the stored outbound document.
  static String _nodeType(NodeRow node) {
    if (node.type != 'custom') return _typeLabels[node.type] ?? node.type;
    final document = _decodeObject(node.outboundJson);
    final subtype = document?['subtype'];
    if (subtype == 'fullconfig') return 'Custom Config';
    if (subtype == 'outbound') {
      final config = document?['config'];
      final configDocument =
          config is String ? _decodeObject(config) : null;
      final customType = configDocument?['type'];
      final label = customType is String && customType.isNotEmpty
          ? '${customType[0].toUpperCase()}${customType.substring(1)}'
          : '';
      return label.isEmpty ? 'Custom Outbound' : 'Custom $label Outbound';
    }
    return subtype is String && subtype.isNotEmpty ? subtype : 'Custom';
  }

  static Map<String, dynamic>? _decodeObject(String text) {
    if (text.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(text);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  static int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? fallback;
    return fallback;
  }

  static List<int> _distinct(List<int> ids) {
    final seen = <int>{};
    return <int>[
      for (final id in ids)
        if (seen.add(id)) id,
    ];
  }
}