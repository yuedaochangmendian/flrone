// The document-only profile ops that moved off `profiles.platform`.
//
// `stats`, `reorder`, `clearTestResults`, `nodeList` and `nodeReorder` read or
// edit the same `profiles.json` document Dart owns; their Kotlin handlers either
// re-read Dart's document or forwarded their write back through
// `DartProfileWriter`. The configuration editor's three ops — `config`, `read`
// and `write` (the group manifest: name/url/autoUpdate/updateIntervalMinutes and
// the node list) — are the same document, so they are here as well. They all run
// on the existing [ConfigurationStore]: still one writer, one atomic edit, no
// second document.
//
// Host interactions that deliberately stay (all narrow, none a second writer):
//
//  * `sort.reposition` — clearing test results also repositions rows in a group
//    kept sorted BY_TEST_RESULT/BY_LATENCY ([GroupSort] in Kotlin). Those sort
//    keys read the parsed outbound model (type/name/address/security) Dart does
//    not have, so [clearTestResults] clears the document and then asks the host
//    for that one narrow action. The alternative — a Dart re-implementation of
//    GroupSort — is the second model ADR 0002 forbids; port it before moving the
//    duty.
//  * `revision.edit` — [write] is a user edit of the group, and
//    `GroupRevisions`' newest-intent counter (Kotlin, in memory) must move
//    *before* the document does: a subscription answer already downloading would
//    otherwise apply over the edit. It is an intent bump, not a write.
//  * `subscription.schedule` — a URL edit is a new subscription, so the poller is
//    re-planned right after the write (the way Kotlin's `write` did); otherwise
//    the old fetch time keeps it off the queue until the next restart.
//  * `data.refresh` — Kotlin reads the same document through DartProfileStore's
//    mtime cache. Every write here calls the existing refresh path (which
//    invalidates that cache and schedules the catalog push), so Kotlin readers
//    never answer pre-write rows. Dart-local reads never need it.
//
// Wire results are the ones the pages consume:
//  * `stats`          -> {groups: 1, outbounds, rules}
//  * `nodeList`       -> {groupId, groupName, nodes: [{id, name, type, delay, testedAt}]}
//  * `config`         -> {content, formatted, revision, stats}
//  * `read`           -> the same manifest text `config.content` carries
//  * the other ops    -> no reply (the facades answer their own bool).

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

/// The user-save intent bump (`profiles.platform` op `revision.edit`,
/// `GroupRevisions.edit`): an answer already downloading is stale from then on.
typedef ProfileGroupEditBegin = Future<void> Function(int groupId);

/// Re-plans the subscription poller (`profiles.platform` op
/// `subscription.schedule`, `SubscriptionScheduler.schedule`).
typedef ProfileSubscriptionReschedule = Future<void> Function();

/// Reads `global_route_rules.json`'s rows, or null when the document is
/// missing/unreadable. Injected by tests; the default reads the file.
typedef ProfileRouteRulesReader =
    Future<List<Map<String, Object?>>?> Function(String documentsDir);

/// The localized default group name (`data.path`'s `defaultGroupName`).
typedef ProfileDefaultGroupNameReader = Future<String> Function();

/// A refused document operation, carrying the user-facing text the Kotlin duty
/// answered through `PlatformException.message`. [toString] is the message alone
/// so the pages' error banners render it unchanged.
class ProfileDocumentFailure implements Exception {
  const ProfileDocumentFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

/// ADR 0008 P1-5: the single selection document Dart owns.
///
/// `documents/profile_selection.json` is the hand-off from Dart (the only writer)
/// to Go's config build and Kotlin's `config.prepare` (readers only). The exact
/// wire shape is a contract — Go and Kotlin parse these four keys, so no field
/// is added or renamed without updating both readers:
///
///     {"version":1,"selectedProfileId":N,"currentGroupId":N,"updatedAt":epochMs}
///
/// `selectedProfileId` is the *member* id (the row Go builds), `currentGroupId`
/// the group the UI has open (settings `current_group`). During migration the
/// readers fall back to the settings-based selection when this file is absent
/// or malformed, so an app upgrade never has to rewrite it at install time.
const int profileSelectionDocumentVersion = 1;
const String profileSelectionFileName = 'profile_selection.json';

/// The Dart-owned selection document and its one atomic writer.
///
/// A [ConfigurationStoreFs] seam keeps it testable in memory; production uses
/// the same [IoConfigurationStoreFs] (temp file + flush + rename) as
/// `profiles.json`, so readers never see a half-written selection.
class ProfileSelectionDocument {
  ProfileSelectionDocument(this.documentsDir, {ConfigurationStoreFs? fs})
      : _fs = fs ?? const IoConfigurationStoreFs();

  final String documentsDir;
  final ConfigurationStoreFs _fs;

  /// `<filesDir>/documents/profile_selection.json` — the same directory
  /// [ConfigurationStoreSource.store] resolves for `profiles.json`.
  String get path => '$documentsDir${Platform.pathSeparator}'
      '$profileSelectionFileName';

  /// Atomically writes the selection. The caller passes the already-resolved
  /// ids and a clock so tests can pin [updatedAt]; production passes
  /// [DateTime.now].
  Future<void> write({
    required int selectedProfileId,
    required int currentGroupId,
    DateTime? now,
  }) async {
    final updatedAt = (now ?? DateTime.now()).millisecondsSinceEpoch;
    final payload = jsonEncode(<String, dynamic>{
      'version': profileSelectionDocumentVersion,
      'selectedProfileId': selectedProfileId,
      'currentGroupId': currentGroupId,
      'updatedAt': updatedAt,
    });
    await _fs.write(path, payload);
  }
}

/// The Dart-owned half of the old `profiles.platform` document ops.
class ProfileDocumentService {
  ProfileDocumentService({
    required this.storeSource,
    required this.refreshCatalog,
    required this.repositionTestResults,
    required this.beginGroupEdit,
    required this.rescheduleSubscriptions,
    ProfileRouteRulesReader? readRouteRules,
    ProfileDefaultGroupNameReader? readDefaultGroupName,
  })  : _readRouteRules = readRouteRules ?? _readRouteRulesFromDisk,
        _readDefaultGroupName = readDefaultGroupName ?? _defaultGroupNameFallback;

  final ConfigurationStoreSource storeSource;
  final ProfileDocumentRefresh refreshCatalog;
  final ProfileTestResultReposition repositionTestResults;
  final ProfileGroupEditBegin beginGroupEdit;
  final ProfileSubscriptionReschedule rescheduleSubscriptions;
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

  // --- the configuration editor (FlroneProfiles.config/read/write) ----------

  /// The manifest's keys. A foreign key is refused instead of dropped: DNS,
  /// routing rules and log settings are app settings in Throne, not group
  /// fields, so a save must not silently swallow them.
  static const _configKeys = <String>{
    'name',
    'url',
    'autoUpdate',
    'updateIntervalMinutes',
    'nodes',
  };

  /// `FlroneProfiles.config`: the group's manifest as the editor's document,
  /// plus the optimistic-lock revision (`sub_last_update`), the pretty text the
  /// details page parses and the dashboard-style stats.
  Future<Map<String, dynamic>> config(int groupId) async {
    final store = await storeSource.store();
    final document = await store.document;
    final group = _groupOrThrow(document, groupId);
    final text = _manifest(document, group, await _groupDefaultName());
    return <String, dynamic>{
      'content': text,
      // Kotlin re-parsed `content` to answer `formatted`; the manifest is built
      // as that pretty text already, so both keys carry it.
      'formatted': text,
      'revision': '${group.subLastUpdate}',
      'stats': await stats(groupId),
    };
  }

  /// `FlroneProfiles.read`: the same manifest [config] answers, without the stats
  /// and the pretty-print second pass (the export/share caller discards both).
  Future<String> read(int groupId) async {
    final store = await storeSource.store();
    final document = await store.document;
    final group = _groupOrThrow(document, groupId);
    return _manifest(document, group, await _groupDefaultName());
  }

  /// `FlroneProfiles.write`: applies an edited manifest to the group row.
  ///
  /// The checks are the Kotlin ones, under the store's edit lock: the optimistic
  /// revision guard, the key whitelist, then node membership — the count first,
  /// then the canonical-JSON comparison of the round-tripped nodes against the
  /// document's own rows (order-insensitive on keys, so a round trip cannot trip
  /// it). A difference is refused rather than dropped: nodes have their own
  /// screen. JSON parsing happens before the intent bump, so an unparseable save
  /// moves nothing; the bump precedes the locked check, so a save refused by the
  /// revision guard or the whitelist — or one whose group disappeared between
  /// the two calls — may still have moved the revision. That only discards a
  /// subscription answer that predates the save attempt.
  ///
  /// A successful write bumps the group's newest-intent revision *before* the
  /// document edit (`revision.edit`, the bump Kotlin ran ahead of
  /// `GroupRepo.save`), re-plans the subscription poller when the URL changed
  /// (`subscription.schedule`), pushes the catalog (`data.refresh`) and answers
  /// `config(id)` — the same trailing order as the Kotlin op.
  Future<Map<String, dynamic>> write(
    int groupId,
    String? revision,
    String content,
  ) async {
    final parsed = _decodeManifest(content);
    final store = await storeSource.store();
    // Before the document moves: an answer already downloading for this group
    // must not land on top of the user's edit.
    await beginGroupEdit(groupId);
    var urlChanged = false;
    final updated = await store.editGroup(groupId, (group, members) {
      if (revision != null &&
          revision.isNotEmpty &&
          revision != '${group.subLastUpdate}') {
        throw const ProfileDocumentFailure(
          'The configuration was updated since it was opened; reload it and try again',
        );
      }
      for (final key in parsed.keys) {
        if (!_configKeys.contains(key)) {
          throw ProfileDocumentFailure(
            '"$key" is not part of the configuration; DNS, routing rules and log settings are app settings',
          );
        }
      }
      final nodes = parsed['nodes'];
      // `JSONObject.optJSONArray`: an absent or non-array `nodes` carries no
      // membership claim, so the Kotlin op only checked a real array.
      if (nodes is List) {
        if (nodes.length != members.length) {
          throw const ProfileDocumentFailure(
            'Node membership is edited on the Proxies screen, not here',
          );
        }
        if (_canonicalJson(nodes) != _canonicalJson(_expectedNodes(members))) {
          throw const ProfileDocumentFailure(
            'Node fields are edited on the Proxies screen, not here',
          );
        }
      }
      var next = group;
      final name = parsed['name'];
      if (name is String && name.trim().isNotEmpty) {
        next = next.copyWith(name: name);
      }
      if (parsed.containsKey('url')) {
        final url = (parsed['url'] is String ? parsed['url'] as String : '').trim();
        if (url != next.url) {
          // dialog_edit_group.cpp accept: what the old URL's server said no
          // longer applies.
          next = next.copyWith(
            url: url,
            subMetadataJson: '{}',
            subLastUpdate: 0,
            info: '',
          );
          urlChanged = true;
        }
      }
      if (parsed.containsKey('autoUpdate')) {
        next = next.copyWith(skipAutoUpdate: !_optBoolean(parsed['autoUpdate']));
      }
      if (parsed.containsKey('updateIntervalMinutes')) {
        final minutes = _asInt(parsed['updateIntervalMinutes']);
        next = next.copyWith(
          subOptionsJson: _withUpdateInterval(
            next.subOptionsJson,
            minutes < 0 ? 0 : minutes,
          ),
        );
      }
      return next;
    });
    if (updated == null) {
      throw ProfileDocumentFailure('No configuration with id $groupId');
    }
    // The host's catalog/scheduler reads its cached view of the document. Push
    // the new bytes before re-planning the poller: a same-length, same-ms edit
    // is exactly the case the mtime+length cache cannot notice on its own.
    await refreshCatalog();
    if (urlChanged) await rescheduleSubscriptions();
    return config(groupId);
  }

  static ConfigurationRow _groupOrThrow(ProfilesDocument document, int id) {
    for (final group in document.groups) {
      if (group.id == id) return group;
    }
    throw ProfileDocumentFailure('No configuration with id $id');
  }

  /// `FlroneProfiles.document(group)`: the group manifest the editor opens, in
  /// the Kotlin key order (name, url, autoUpdate, updateIntervalMinutes,
  /// nodes). Dart's two-space encoder emits the same layout the Android
  /// `org.json` `toString(2)` answer had (keys in insertion order, arrays one
  /// item per line, empty containers inline); only exotic string escapes can
  /// differ, and nothing reads this text as a storage contract — [write] parses
  /// it. Node `tag`/`type` are rendered from the document columns, the same
  /// rule [nodeList] documents (`_nodeName`/`_nodeType`).
  static String _manifest(
    ProfilesDocument document,
    ConfigurationRow group,
    String defaultName,
  ) {
    final nodes = <Object?>[
      for (final node in ConfigurationStore.membersOf(document, group.id))
        <String, Object?>{
          'tag': _nodeName(node),
          'type': _nodeType(node),
          'delay': node.latency,
        },
    ];
    return const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'name': _groupDisplayName(group, defaultName),
      'url': group.url,
      'autoUpdate': !group.skipAutoUpdate,
      'updateIntervalMinutes': _updateInterval(group.subOptionsJson),
      'nodes': nodes,
    });
  }

  /// The rows the editor's `nodes` array must round-trip to, in list order.
  /// The manifest builds its `nodes` from these same renderers, so a document
  /// [config] handed to the editor always compares equal here; only a real edit
  /// trips the check.
  static List<Object?> _expectedNodes(List<NodeRow> members) => <Object?>[
        for (final node in members)
          <String, Object?>{
            'tag': _nodeName(node),
            'type': _nodeType(node),
            'delay': node.latency,
          },
      ];

  /// Parses the editor's manifest text. `JSONObject(content)` used to throw on
  /// anything that is not one JSON object; the refusals carry their own text.
  static Map<String, dynamic> _decodeManifest(String content) {
    final Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw const ProfileDocumentFailure('Not valid JSON');
    }
    if (decoded is! Map) {
      throw const ProfileDocumentFailure(
        'The configuration must be a JSON object',
      );
    }
    return Map<String, dynamic>.from(decoded);
  }

  /// `group.subOptions.updateInterval` (`SubscriptionOptions.parse`): the
  /// codec's `update_interval`, clamped at zero (`JsonValues.toInt`: a whole
  /// number in range, anything else — a string included — reads as 0).
  static int _updateInterval(String subOptionsJson) {
    final options = _decodeObject(subOptionsJson);
    final minutes = _jsonInt(options?['update_interval']);
    return minutes < 0 ? 0 : minutes;
  }

  /// `JsonValues.toInt` (QJsonValue::toInt): only a whole number that fits an
  /// int reads as that number; everything else is 0. The options codec does not
  /// coerce strings, unlike `JSONObject.optInt` in the editor payload.
  static int _jsonInt(Object? value) {
    if (value is int) {
      return value >= -0x80000000 && value <= 0x7fffffff ? value : 0;
    }
    if (value is double) {
      return value.isFinite &&
              value == value.truncateToDouble() &&
              value >= -2147483648.0 &&
              value <= 2147483647.0
          ? value.toInt()
          : 0;
    }
    return 0;
  }

  /// `SubscriptionOptions.toJsonString()` for the one field the manifest owns:
  /// keys sorted, compact, `update_interval` emitted only when > 0 (the codec
  /// omits defaults). The rest of the opaque column is carried as-is — Dart does
  /// not parse SubscriptionOptions, and no reader depends on the key text.
  static String _withUpdateInterval(String subOptionsJson, int minutes) {
    final options = _decodeObject(subOptionsJson) ?? <String, dynamic>{};
    if (minutes > 0) {
      options['update_interval'] = minutes;
    } else {
      options.remove('update_interval');
    }
    return _compactJson(options);
  }

  /// Order-insensitive serialization for JSON structure comparison: object keys
  /// sort and whole numbers normalise to their integral form, so a round trip of
  /// the same data cannot trip an equality check. Port of the old
  /// `canonicalJson` in FlroneProfiles.kt (`membership equality` in the write
  /// contract).
  static String _canonicalJson(Object? value) {
    if (value == null) return 'null';
    if (value is Map) {
      final keys = <String>[for (final key in value.keys) '$key']..sort();
      return '{${[
        for (final key in keys) '${jsonEncode(key)}:${_canonicalJson(value[key])}',
      ].join(',')}}';
    }
    if (value is List) {
      return '[${[
        for (final item in value) _canonicalJson(item),
      ].join(',')}]';
    }
    if (value is bool) return value ? 'true' : 'false';
    if (value is num) {
      final d = value.toDouble();
      if (d.isFinite && d == d.truncateToDouble()) return d.toInt().toString();
      return d.toString();
    }
    return jsonEncode('$value');
  }

  /// Compact, key-sorted JSON — the `JsonWriter` shape the opaque codec columns
  /// are stored in.
  static String _compactJson(Object? value) {
    if (value is Map) {
      final keys = <String>[for (final key in value.keys) '$key']..sort();
      return '{${[
        for (final key in keys) '${jsonEncode(key)}:${_compactJson(value[key])}',
      ].join(',')}}';
    }
    if (value is List) {
      return '[${[
        for (final item in value) _compactJson(item),
      ].join(',')}]';
    }
    return jsonEncode(value);
  }

  /// `JSONObject.optBoolean`: a real boolean or the strings "true"/"false" set
  /// the flag; every other value keeps the false default.
  static bool _optBoolean(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      switch (value.toLowerCase()) {
        case 'true':
          return true;
        case 'false':
          return false;
      }
    }
    return false;
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