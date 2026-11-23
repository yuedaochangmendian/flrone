// ADR 0005 final stage: Dart is the storage authority for profiles and groups.
//
// This document is the single source of truth for the `profiles` and `groups`
// rows the app used to keep in Room (`sager_net.db`). Kotlin/Go read it (see
// DartProfileStore.kt) to build the core config; they no longer write those two
// Room tables. Room keeps living on as the authority for settings/routes and as
// a migration source — the tables and DAOs are deliberately NOT dropped, so a
// half-finished migration can always be retried from the original rows.
//
// The JSON keys are the **Room column names**, not friendly Dart names. That is
// intentional: the one-time migration copies rows by column name (like
// RoomToJsonMigration.kt does for the route tables), and the Kotlin reader maps
// straight into ProxyEntity/ProxyGroup without a second naming layer. A second
// layer is exactly where two writers drift apart.
//
// Storage is one file, written atomically (temp file + rename). Every mutation
// loads the document once, edits its mutable lists, and writes it back whole.
// There is no plugin dependency: file IO is dart:io, injected through
// [ProfileStoreFs] so the schema, CRUD and migration logic run in a plain Dart
// test with an in-memory filesystem.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'sqlite.dart' show SqlRow;

/// The document format version. Bump only when the shape changes in a way old
/// readers cannot tolerate; the Kotlin reader checks it before trusting a doc.
const int profilesDocumentVersion = 1;

/// Room's table names, used as the top-level JSON array keys.
const String profilesTable = 'profiles';
const String groupsTable = 'groups';

/// The file name written under `<filesDir>/documents`.
const String profilesFileName = 'profiles.json';

/// The preferences key set once the Room -> JSON handover has completed.
const String profilesMigratedKey = 'profiles_doc_migrated';

// --- row types -------------------------------------------------------------

/// One `profiles` row. Field names mirror the Kotlin `ProxyEntity` columns;
/// [toJson] emits the exact Room column names.
class ProfileRow {
  const ProfileRow({
    required this.id,
    required this.type,
    this.name,
    this.gid = 0,
    this.userOrder = 0,
    this.latency = 0,
    this.latencyAt = 0,
    this.dlSpeed,
    this.ulSpeed,
    this.testCountry,
    this.ipOut,
    this.outboundJson = '',
    this.rx = 0,
    this.tx = 0,
    this.testError,
  });

  final int id;
  final String type;
  final String? name;
  final int gid;
  final int userOrder;
  final int latency;
  final int latencyAt;
  final String? dlSpeed;
  final String? ulSpeed;
  final String? testCountry;
  final String? ipOut;
  final String outboundJson;
  final int rx;
  final int tx;
  final String? testError;

  static const columns = <String>[
    'id', 'type', 'name', 'gid', 'user_order', 'latency', 'latency_at',
    'dl_speed', 'ul_speed', 'test_country', 'ip_out', 'outbound_json',
    'traffic_dl', 'traffic_up', 'test_error',
  ];

  factory ProfileRow.fromJson(Map<String, dynamic> json) => ProfileRow(
        id: _int(json['id']),
        type: _string(json['type']),
        name: _nullableString(json['name']),
        gid: _int(json['gid']),
        userOrder: _int(json['user_order']),
        latency: _int(json['latency']),
        latencyAt: _int(json['latency_at']),
        dlSpeed: _nullableString(json['dl_speed']),
        ulSpeed: _nullableString(json['ul_speed']),
        testCountry: _nullableString(json['test_country']),
        ipOut: _nullableString(json['ip_out']),
        outboundJson: _string(json['outbound_json']),
        rx: _int(json['traffic_dl']),
        tx: _int(json['traffic_up']),
        testError: _nullableString(json['test_error']),
      );

  /// Reads a raw Room row (column name -> sqlite value). Used by the migration.
  factory ProfileRow.fromRoom(SqlRow row) => ProfileRow(
        id: _int(row['id']),
        type: _string(row['type']),
        name: _nullableString(row['name']),
        gid: _int(row['gid']),
        userOrder: _int(row['user_order']),
        latency: _int(row['latency']),
        latencyAt: _int(row['latency_at']),
        dlSpeed: _nullableString(row['dl_speed']),
        ulSpeed: _nullableString(row['ul_speed']),
        testCountry: _nullableString(row['test_country']),
        ipOut: _nullableString(row['ip_out']),
        outboundJson: _string(row['outbound_json']),
        rx: _int(row['traffic_dl']),
        tx: _int(row['traffic_up']),
        testError: _nullableString(row['test_error']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type,
        'name': name,
        'gid': gid,
        'user_order': userOrder,
        'latency': latency,
        'latency_at': latencyAt,
        'dl_speed': dlSpeed,
        'ul_speed': ulSpeed,
        'test_country': testCountry,
        'ip_out': ipOut,
        'outbound_json': outboundJson,
        'traffic_dl': rx,
        'traffic_up': tx,
        'test_error': testError,
      };

  ProfileRow copyWith({
    int? id,
    String? type,
    String? name,
    bool clearName = false,
    int? gid,
    int? userOrder,
    int? latency,
    int? latencyAt,
    String? dlSpeed,
    bool clearDlSpeed = false,
    String? ulSpeed,
    bool clearUlSpeed = false,
    String? testCountry,
    bool clearTestCountry = false,
    String? ipOut,
    bool clearIpOut = false,
    String? outboundJson,
    int? rx,
    int? tx,
    String? testError,
    bool clearTestError = false,
  }) =>
      ProfileRow(
        id: id ?? this.id,
        type: type ?? this.type,
        name: clearName ? null : (name ?? this.name),
        gid: gid ?? this.gid,
        userOrder: userOrder ?? this.userOrder,
        latency: latency ?? this.latency,
        latencyAt: latencyAt ?? this.latencyAt,
        dlSpeed: clearDlSpeed ? null : (dlSpeed ?? this.dlSpeed),
        ulSpeed: clearUlSpeed ? null : (ulSpeed ?? this.ulSpeed),
        testCountry: clearTestCountry ? null : (testCountry ?? this.testCountry),
        ipOut: clearIpOut ? null : (ipOut ?? this.ipOut),
        outboundJson: outboundJson ?? this.outboundJson,
        rx: rx ?? this.rx,
        tx: tx ?? this.tx,
        testError: clearTestError ? null : (testError ?? this.testError),
      );

  /// Applies a Room-column-keyed **partial** update, leaving every column the
  /// patch does not name untouched. Kotlin's per-column writes (traffic,
  /// latency, test results, group moves) send patches so two writers cannot
  /// clobber each other's columns the way a whole-row `update` would. A null
  /// value in the patch clears the column (the SQL `= NULL` equivalent).
  ProfileRow applyPatch(Map<String, dynamic> patch) {
    String? text(String key, String? current) => patch.containsKey(key)
        ? (patch[key] == null ? null : '${patch[key]}')
        : current;
    int number(String key, int current) =>
        patch.containsKey(key) ? _int(patch[key], fallback: current) : current;
    return copyWith(
      type: text('type', type),
      name: text('name', name),
      clearName: patch.containsKey('name') && patch['name'] == null,
      gid: number('gid', gid),
      userOrder: number('user_order', userOrder),
      latency: number('latency', latency),
      latencyAt: number('latency_at', latencyAt),
      dlSpeed: text('dl_speed', dlSpeed),
      clearDlSpeed: patch.containsKey('dl_speed') && patch['dl_speed'] == null,
      ulSpeed: text('ul_speed', ulSpeed),
      clearUlSpeed: patch.containsKey('ul_speed') && patch['ul_speed'] == null,
      testCountry: text('test_country', testCountry),
      clearTestCountry: patch.containsKey('test_country') && patch['test_country'] == null,
      ipOut: text('ip_out', ipOut),
      clearIpOut: patch.containsKey('ip_out') && patch['ip_out'] == null,
      outboundJson: text('outbound_json', outboundJson) ?? '',
      rx: number('traffic_dl', rx),
      tx: number('traffic_up', tx),
      testError: text('test_error', testError),
      clearTestError: patch.containsKey('test_error') && patch['test_error'] == null,
    );
  }

  /// Mirrors ProxyEntity.clearTestResults(): the test columns revert to their
  /// "untested" defaults while traffic and the outbound data stay.
  ProfileRow clearedTestResults() => copyWith(
        latency: 0,
        latencyAt: 0,
        clearDlSpeed: true,
        clearUlSpeed: true,
        clearTestCountry: true,
        clearIpOut: true,
        clearTestError: true,
      );

  @override
  String toString() => 'ProfileRow($id, $type, $name, gid=$gid, order=$userOrder)';
}

/// One `groups` row. [toJson] emits the Room column names verbatim; the two
/// opaque JSON text columns are carried as strings so Dart never has to
/// understand SubscriptionOptions/SubUserInfo (Kotlin owns that model).
class GroupRow {
  const GroupRow({
    required this.id,
    this.archive = false,
    this.skipAutoUpdate = false,
    this.name = '',
    this.url = '',
    this.info = '',
    this.subLastUpdate = 0,
    this.frontProxyId = -1,
    this.landingProxyId = -1,
    this.columnWidthJson = '',
    this.scrollLastProfile = -1,
    this.autoClearUnavailable = false,
    this.testSortBy = 0,
    this.trafficSortBy = 0,
    this.testItemsToShow = 0,
    this.typeSortBy = 0,
    this.subOptionsJson = '{}',
    this.subMetadataJson = '{}',
    this.sortMethod = 0,
    this.sortDescending = false,
    this.displayOrder = 0,
    this.routeId = -1,
    this.importSubRoute = false,
    this.single = false,
  });

  final int id;
  final bool archive;
  final bool skipAutoUpdate;
  final String name;
  final String url;
  final String info;
  final int subLastUpdate;
  final int frontProxyId;
  final int landingProxyId;
  final String columnWidthJson;
  final int scrollLastProfile;
  final bool autoClearUnavailable;
  final int testSortBy;
  final int trafficSortBy;
  final int testItemsToShow;
  final int typeSortBy;
  final String subOptionsJson;
  final String subMetadataJson;
  final int sortMethod;
  final bool sortDescending;
  final int displayOrder;
  final int routeId;
  final bool importSubRoute;

  /// The single-node container (Throne's Default group).
  ///
  /// A document-only extension key, not a Room column — [columns] deliberately
  /// stays the Room list for the one-time migration. The explicit flag replaced
  /// matching the container by its localized default name, which broke whenever
  /// a translation changed.
  final bool single;

  static const columns = <String>[
    'id', 'archive', 'skip_auto_update', 'name', 'url', 'info',
    'sub_last_update', 'front_proxy_id', 'landing_proxy_id',
    'column_width_json', 'scroll_last_profile', 'auto_clear_unavailable',
    'test_sort_by', 'traffic_sort_by', 'test_items_to_show', 'type_sort_by',
    'sub_options_json', 'sub_metadata_json', 'sort_method', 'sort_descending',
    'display_order', 'route_id', 'import_sub_route',
  ];

  bool get isSubscription => url.isNotEmpty;

  factory GroupRow.fromJson(Map<String, dynamic> json) => GroupRow(
        id: _int(json['id']),
        archive: _bool(json['archive']),
        skipAutoUpdate: _bool(json['skip_auto_update']),
        name: _string(json['name']),
        url: _string(json['url']),
        info: _string(json['info']),
        subLastUpdate: _int(json['sub_last_update']),
        frontProxyId: _int(json['front_proxy_id'], fallback: -1),
        landingProxyId: _int(json['landing_proxy_id'], fallback: -1),
        columnWidthJson: _string(json['column_width_json']),
        scrollLastProfile: _int(json['scroll_last_profile'], fallback: -1),
        autoClearUnavailable: _bool(json['auto_clear_unavailable']),
        testSortBy: _int(json['test_sort_by']),
        trafficSortBy: _int(json['traffic_sort_by']),
        testItemsToShow: _int(json['test_items_to_show']),
        typeSortBy: _int(json['type_sort_by']),
        subOptionsJson: _string(json['sub_options_json'], fallback: '{}'),
        subMetadataJson: _string(json['sub_metadata_json'], fallback: '{}'),
        sortMethod: _int(json['sort_method']),
        sortDescending: _bool(json['sort_descending']),
        displayOrder: _int(json['display_order']),
        routeId: _int(json['route_id'], fallback: -1),
        importSubRoute: _bool(json['import_sub_route']),
        single: json['single'] == true,
      );

  factory GroupRow.fromRoom(SqlRow row) => GroupRow(
        id: _int(row['id']),
        archive: _bool(row['archive']),
        skipAutoUpdate: _bool(row['skip_auto_update']),
        name: _string(row['name']),
        url: _string(row['url']),
        info: _string(row['info']),
        subLastUpdate: _int(row['sub_last_update']),
        frontProxyId: _int(row['front_proxy_id'], fallback: -1),
        landingProxyId: _int(row['landing_proxy_id'], fallback: -1),
        columnWidthJson: _string(row['column_width_json']),
        scrollLastProfile: _int(row['scroll_last_profile'], fallback: -1),
        autoClearUnavailable: _bool(row['auto_clear_unavailable']),
        testSortBy: _int(row['test_sort_by']),
        trafficSortBy: _int(row['traffic_sort_by']),
        testItemsToShow: _int(row['test_items_to_show']),
        typeSortBy: _int(row['type_sort_by']),
        subOptionsJson: _string(row['sub_options_json'], fallback: '{}'),
        subMetadataJson: _string(row['sub_metadata_json'], fallback: '{}'),
        sortMethod: _int(row['sort_method']),
        sortDescending: _bool(row['sort_descending']),
        displayOrder: _int(row['display_order']),
        routeId: _int(row['route_id'], fallback: -1),
        importSubRoute: _bool(row['import_sub_route']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'archive': archive,
        'skip_auto_update': skipAutoUpdate,
        'name': name,
        'url': url,
        'info': info,
        'sub_last_update': subLastUpdate,
        'front_proxy_id': frontProxyId,
        'landing_proxy_id': landingProxyId,
        'column_width_json': columnWidthJson,
        'scroll_last_profile': scrollLastProfile,
        'auto_clear_unavailable': autoClearUnavailable,
        'test_sort_by': testSortBy,
        'traffic_sort_by': trafficSortBy,
        'test_items_to_show': testItemsToShow,
        'type_sort_by': typeSortBy,
        'sub_options_json': subOptionsJson,
        'sub_metadata_json': subMetadataJson,
        'sort_method': sortMethod,
        'sort_descending': sortDescending,
        'display_order': displayOrder,
        'route_id': routeId,
        'import_sub_route': importSubRoute,
        // Extension key, emitted only when set so a normal group's row stays
        // exactly the Room columns.
        if (single) 'single': true,
      };

  GroupRow copyWith({
    int? id,
    bool? archive,
    bool? skipAutoUpdate,
    String? name,
    String? url,
    String? info,
    int? subLastUpdate,
    int? frontProxyId,
    int? landingProxyId,
    String? columnWidthJson,
    int? scrollLastProfile,
    bool? autoClearUnavailable,
    int? testSortBy,
    int? trafficSortBy,
    int? testItemsToShow,
    int? typeSortBy,
    String? subOptionsJson,
    String? subMetadataJson,
    int? sortMethod,
    bool? sortDescending,
    int? displayOrder,
    int? routeId,
    bool? importSubRoute,
    bool? single,
  }) =>
      GroupRow(
        id: id ?? this.id,
        archive: archive ?? this.archive,
        skipAutoUpdate: skipAutoUpdate ?? this.skipAutoUpdate,
        name: name ?? this.name,
        url: url ?? this.url,
        info: info ?? this.info,
        subLastUpdate: subLastUpdate ?? this.subLastUpdate,
        frontProxyId: frontProxyId ?? this.frontProxyId,
        landingProxyId: landingProxyId ?? this.landingProxyId,
        columnWidthJson: columnWidthJson ?? this.columnWidthJson,
        scrollLastProfile: scrollLastProfile ?? this.scrollLastProfile,
        autoClearUnavailable: autoClearUnavailable ?? this.autoClearUnavailable,
        testSortBy: testSortBy ?? this.testSortBy,
        trafficSortBy: trafficSortBy ?? this.trafficSortBy,
        testItemsToShow: testItemsToShow ?? this.testItemsToShow,
        typeSortBy: typeSortBy ?? this.typeSortBy,
        subOptionsJson: subOptionsJson ?? this.subOptionsJson,
        subMetadataJson: subMetadataJson ?? this.subMetadataJson,
        sortMethod: sortMethod ?? this.sortMethod,
        sortDescending: sortDescending ?? this.sortDescending,
        displayOrder: displayOrder ?? this.displayOrder,
        routeId: routeId ?? this.routeId,
        importSubRoute: importSubRoute ?? this.importSubRoute,
        single: single ?? this.single,
      );

  /// Room-column-keyed partial update; see [ProfileRow.applyPatch]. Null clears
  /// nullable columns; the two opaque codec columns are carried verbatim.
  GroupRow applyPatch(Map<String, dynamic> patch) {
    String str(String key, String current) => patch.containsKey(key)
        ? (patch[key] == null ? '' : '${patch[key]}')
        : current;
    int number(String key, int current, [int fallback = 0]) =>
        patch.containsKey(key) ? _int(patch[key], fallback: fallback) : current;
    bool flag(String key, bool current) => patch.containsKey(key)
        ? _bool(patch[key])
        : current;
    return copyWith(
      archive: flag('archive', archive),
      skipAutoUpdate: flag('skip_auto_update', skipAutoUpdate),
      name: str('name', name),
      url: str('url', url),
      info: str('info', info),
      subLastUpdate: number('sub_last_update', subLastUpdate),
      frontProxyId: number('front_proxy_id', frontProxyId, -1),
      landingProxyId: number('landing_proxy_id', landingProxyId, -1),
      columnWidthJson: str('column_width_json', columnWidthJson),
      scrollLastProfile: number('scroll_last_profile', scrollLastProfile, -1),
      autoClearUnavailable: flag('auto_clear_unavailable', autoClearUnavailable),
      testSortBy: number('test_sort_by', testSortBy),
      trafficSortBy: number('traffic_sort_by', trafficSortBy),
      testItemsToShow: number('test_items_to_show', testItemsToShow),
      typeSortBy: number('type_sort_by', typeSortBy),
      subOptionsJson: str('sub_options_json', subOptionsJson),
      subMetadataJson: str('sub_metadata_json', subMetadataJson),
      sortMethod: number('sort_method', sortMethod),
      sortDescending: flag('sort_descending', sortDescending),
      displayOrder: number('display_order', displayOrder),
      routeId: number('route_id', routeId, -1),
      importSubRoute: flag('import_sub_route', importSubRoute),
    );
  }

  @override
  String toString() => 'GroupRow($id, $name, subscription=$isSubscription)';
}

// --- document --------------------------------------------------------------

/// The whole `profiles.json` document, envelope included. Row lists are mutable
/// (the store edits them in place before persisting).
class ProfilesDocument {
  ProfilesDocument({
    this.version = profilesDocumentVersion,
    this.name = 'profiles',
    this.nextProfileId = 1,
    this.nextGroupId = 1,
    List<ProfileRow>? profiles,
    List<GroupRow>? groups,
  })  : profiles = profiles ?? <ProfileRow>[],
        groups = groups ?? <GroupRow>[];

  final int version;
  final String name;

  /// Next-id counters are mutable: bulk/import operations advance them in place
  /// inside the store's serialized edit.
  int nextProfileId;
  int nextGroupId;
  final List<ProfileRow> profiles;
  final List<GroupRow> groups;

  factory ProfilesDocument.fromJson(Map<String, dynamic> json) {
    final version = _int(json['version'], fallback: -1);
    if (version != profilesDocumentVersion) {
      throw ProfileStoreFormatException(
        'unsupported profiles document version $version '
        '(expected $profilesDocumentVersion)',
      );
    }
    final rawProfiles = json[profilesTable];
    final rawGroups = json[groupsTable];
    if (rawProfiles is! List || rawGroups is! List) {
      throw const ProfileStoreFormatException(
        'profiles document is missing the profiles/groups arrays',
      );
    }
    return ProfilesDocument(
      version: version,
      name: _string(json['name'], fallback: 'profiles'),
      nextProfileId: _int(json['nextProfileId'], fallback: 1),
      nextGroupId: _int(json['nextGroupId'], fallback: 1),
      profiles: rawProfiles
          .whereType<Map>()
          .map((r) => ProfileRow.fromJson(Map<String, dynamic>.from(r)))
          .toList(),
      groups: rawGroups
          .whereType<Map>()
          .map((r) => GroupRow.fromJson(Map<String, dynamic>.from(r)))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'name': name,
        'nextProfileId': nextProfileId,
        'nextGroupId': nextGroupId,
        profilesTable: profiles.map((p) => p.toJson()).toList(),
        groupsTable: groups.map((g) => g.toJson()).toList(),
      };

  @override
  String toString() =>
      'ProfilesDocument(v$version, ${profiles.length} profiles, ${groups.length} groups)';
}

/// Thrown when the document on disk cannot be trusted: a wrong version or a
/// shape this build does not understand. Callers must NOT overwrite such a
/// file — the safe action is to leave it for inspection and fall back.
class ProfileStoreFormatException implements Exception {
  const ProfileStoreFormatException(this.message);

  final String message;

  @override
  String toString() => 'ProfileStoreFormatException: $message';
}

// --- filesystem seam -------------------------------------------------------

/// The minimal file operations the store needs. In production [IoProfileStoreFs]
/// wraps dart:io; tests use an in-memory implementation.
abstract class ProfileStoreFs {
  Future<bool> exists(String path);
  Future<String> read(String path);
  /// Atomically replaces [path] with [content] (temp file + rename in prod).
  Future<void> write(String path, String content);
  /// Byte length of [path], or null when the filesystem cannot report it.
  /// Diagnostics only: a failure here must never turn a valid document corrupt.
  Future<int?> size(String path) async => null;
}

/// The production filesystem. The documents directory is derived from the
/// `data.path` fact (the Room database path): `<app>/databases/sager_net.db`
/// has parent `<app>/databases`, whose parent is `<app>`; Go's documents live
/// at `<filesDir>/documents`, so we join `<app>/files/documents`.
class IoProfileStoreFs implements ProfileStoreFs {
  const IoProfileStoreFs();

  @override
  Future<bool> exists(String path) async => File(path).exists();

  @override
  Future<String> read(String path) => File(path).readAsString();

  @override
  Future<int?> size(String path) async {
    try {
      return await File(path).length();
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> write(String path, String content) async {
    final file = File(path);
    final parent = file.parent;
    if (!await parent.exists()) await parent.create(recursive: true);
    final temp = File('$path.${DateTime.now().microsecondsSinceEpoch}.tmp');
    try {
      // `flush: true` is the route documents' standard (and the difference between a rename
      // that survives a power cut and a zero-length authority file): without it the rename can
      // land while the new bytes are still in the page cache.
      await temp.writeAsString(content, flush: true);
      await temp.rename(path);
    } finally {
      if (await temp.exists()) {
        try {
          await temp.delete();
        } on FileSystemException {
          // A leftover temp is harmless; the next write uses a different name.
        }
      }
    }
  }
}

/// Derives the documents directory from the Room database path published by
/// `data.path`. Kept here (not in box.dart) so the migration and the store
/// agree on one path rule.
String documentsDirFromDatabasePath(String databasePath) {
  final db = File(databasePath);
  final appDir = db.parent.parent;
  return '${appDir.path}${Platform.pathSeparator}files'
      '${Platform.pathSeparator}documents';
}

/// In-memory filesystem for tests.
class MemoryProfileStoreFs implements ProfileStoreFs {
  final Map<String, String> files = {};
  int writes = 0;

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<String> read(String path) async {
    final value = files[path];
    if (value == null) throw FileSystemException('missing', path);
    return value;
  }

  @override
  Future<void> write(String path, String content) async {
    files[path] = content;
    writes++;
  }

  @override
  Future<int?> size(String path) async =>
      files.containsKey(path) ? utf8.encode(files[path]!).length : null;
}

// --- store -----------------------------------------------------------------

/// The ids Dart assigned to rows that arrived with a non-positive client id.
/// Profiles and groups are kept in separate maps because both sides number
/// their temporary ids from -1 (a shared map would collide).
class AllocatedProfileIds {
  const AllocatedProfileIds({this.profiles = const {}, this.groups = const {}});

  final Map<int, int> profiles;
  final Map<int, int> groups;
}

/// The Dart-owned profile/group document.
///
/// Mutations are read-modify-write against one in-memory copy and are serialized
/// by a [Future] chain so two concurrent UI calls cannot lose each other's edit.
/// Every mutation persists the whole document atomically.
class ProfileStore {
  ProfileStore({
    required this.path,
    ProfileStoreFs? fs,
  }) : _fs = fs ?? const IoProfileStoreFs();

  final String path;
  final ProfileStoreFs _fs;

  ProfilesDocument? _doc;
  Future<void> _tail = Future.value();

  /// Whether a valid document is currently loaded (or has been written).
  bool get loaded => _doc != null;

  /// The document, loading from disk on first use. An empty document is
  /// synthesized when the file does not exist yet (fresh install).
  Future<ProfilesDocument> get document {
    final cached = _doc;
    if (cached != null) return Future.value(cached);
    // The load runs under the same lock as edits: an un-locked load could
    // finish after a replaceAll and install the pre-replace snapshot, which
    // the next edit would then persist. Callers already inside the lock must
    // use [_documentLocked] — the lock is not re-entrant.
    return _synchronized(_documentLocked);
  }

  /// Cache-miss load without taking the lock, for callers that already hold it.
  Future<ProfilesDocument> _documentLocked() async {
    final late = _doc; // a queued write may have installed it meanwhile
    if (late != null) return late;
    final loaded = await _load();
    _doc = loaded;
    return loaded;
  }

  /// Alias for [document] matching the store API name used by callers.
  Future<ProfilesDocument> read() => document;

  Future<ProfilesDocument> _load() async {
    if (!await _fs.exists(path)) return ProfilesDocument();
    final text = await _fs.read(path);
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      throw const ProfileStoreFormatException('profiles.json is not valid JSON');
    }
    if (decoded is! Map) {
      throw const ProfileStoreFormatException('profiles.json is not an object');
    }
    return ProfilesDocument.fromJson(Map<String, dynamic>.from(decoded));
  }

  /// Forces a re-read from disk, e.g. after an external `applyDocument` write.
  ///
  /// Serialized with [_edit]: a reload landing between an edit's read and its
  /// persist would install the pre-edit document, and the edit would then
  /// overwrite the newer file with it.
  Future<ProfilesDocument> reload() => _synchronized(() async {
        _doc = await _load();
        return _doc!;
      });

  /// Parses the file without touching the live cache (diagnostics only).
  ///
  /// [reload] replaces `_doc`, which is the copy a concurrent `_edit` reads and
  /// writes back: a diagnostics read racing a write could otherwise install the
  /// pre-write document and make the next edit overwrite the newer file. This
  /// read is deliberately side-effect free.
  Future<ProfilesDocument> readFresh() => _load();

  /// Whether the backing file exists (used by the migration gate).
  Future<bool> exists() => _fs.exists(path);

  /// Byte length of the backing file for diagnostics; null when unknown.
  Future<int?> size() => _fs.size(path);

  /// Serializes an in-place edit of the document and persists it.
  Future<T> _edit<T>(T Function(ProfilesDocument doc) action) => _synchronized(() async {
        final doc = await _documentLocked();
        final result = action(doc);
        await _persist(doc);
        return result;
      });

  /// Runs [body] after every queued operation and makes every later operation
  /// wait for it — the discipline that keeps reloads and multi-step applies
  /// from interleaving with (and being overwritten by) an in-flight edit.
  Future<T> _synchronized<T>(Future<T> Function() body) async {
    final previous = _tail;
    final completer = Completer<void>();
    _tail = completer.future;
    await previous;
    try {
      return await body();
    } finally {
      completer.complete();
    }
  }

  Future<void> _persist(ProfilesDocument doc) async {
    await _fs.write(path, jsonEncode(doc.toJson()));
  }

  /// Replaces the whole document atomically (used by the one-time migration and
  /// by `profiles.applyDocument` full rewrites).
  Future<void> replaceAll(ProfilesDocument doc) => _synchronized(() async {
        // Even a caller-built document must not hand out an id that already
        // exists: normalise the counters past the largest row, exactly as the
        // migration does. A stale counter is the classic way two writers collide.
        final maxP = doc.profiles.fold<int>(0, (m, p) => p.id > m ? p.id : m);
        final maxG = doc.groups.fold<int>(0, (m, g) => g.id > m ? g.id : m);
        final normalized = ProfilesDocument(
          version: doc.version,
          name: doc.name,
          nextProfileId: _maxNext(doc.nextProfileId, maxP, null),
          nextGroupId: _maxNext(doc.nextGroupId, maxG, null),
          profiles: doc.profiles,
          groups: doc.groups,
        );
        await _persist(normalized);
        _doc = normalized;
      });

  // --- reads ---------------------------------------------------------------

  Future<List<ProfileRow>> list() async =>
      List.unmodifiable((await document).profiles);

  Future<List<GroupRow>> groups() async =>
      List.unmodifiable((await document).groups);

  Future<ProfileRow?> profile(int id) async {
    if (id <= 0) return null;
    for (final p in (await document).profiles) {
      if (p.id == id) return p;
    }
    return null;
  }

  Future<GroupRow?> group(int id) async {
    if (id <= 0) return null;
    for (final g in (await document).groups) {
      if (g.id == id) return g;
    }
    return null;
  }

  Future<List<ProfileRow>> profilesOfGroup(int gid) async {
    final rows = (await document).profiles.where((p) => p.gid == gid).toList();
    rows.sort((a, b) => a.userOrder.compareTo(b.userOrder) == 0
        ? a.id.compareTo(b.id)
        : a.userOrder.compareTo(b.userOrder));
    return List.unmodifiable(rows);
  }

  // --- profile writes ------------------------------------------------------

  /// Creates a profile with the next id. [outboundJson] is the protocol
  /// contract text; Dart stores it verbatim and never parses it.
  Future<ProfileRow> createProfile({
    required String type,
    String? name,
    required int gid,
    String outboundJson = '',
    int? userOrder,
  }) async {
    late final ProfileRow created;
    await _edit((doc) {
      final order = userOrder ?? nextProfileOrder(doc, gid);
      created = ProfileRow(
        id: doc.nextProfileId,
        type: type,
        name: name,
        gid: gid,
        userOrder: order,
        outboundJson: outboundJson,
      );
      doc.profiles.add(created);
      doc.nextProfileId += 1;
      _compact(doc, gid);
    });
    return created;
  }

  /// Replaces a profile wholesale (matched by id). No-op when absent.
  Future<void> updateProfile(ProfileRow row) async {
    await _edit((doc) {
      final index = doc.profiles.indexWhere((p) => p.id == row.id);
      if (index >= 0) doc.profiles[index] = row;
    });
  }

  /// Short alias used by the channel layer.
  Future<void> update(ProfileRow row) => updateProfile(row);

  /// Deletes a profile and compacts its group's userOrder to stay dense.
  Future<bool> deleteProfile(int id) async {
    late final bool removed;
    await _edit((doc) {
      final index = doc.profiles.indexWhere((p) => p.id == id);
      if (index < 0) {
        removed = false;
        return;
      }
      final gid = doc.profiles[index].gid;
      doc.profiles.removeAt(index);
      _compact(doc, gid);
      removed = true;
    });
    return removed;
  }

  /// Deletes many profiles; returns the ids actually removed.
  Future<List<int>> deleteProfiles(Iterable<int> ids) async {
    final wanted = ids.toSet();
    final removed = <int>[];
    await _edit((doc) {
      final gids = <int>{};
      doc.profiles.removeWhere((p) {
        if (!wanted.contains(p.id)) return false;
        removed.add(p.id);
        gids.add(p.gid);
        return true;
      });
      for (final gid in gids) {
        _compact(doc, gid);
      }
    });
    return removed;
  }

  /// Deletes an arbitrary mix of profile and group ids, used by the delete
  /// handlers (a group delete cascades to its members).
  Future<void> deleteIds({
    Iterable<int> profileIds = const [],
    Iterable<int> groupIds = const [],
  }) async {
    await _edit((doc) => _deleteIdsIn(doc, profileIds, groupIds));
  }

  void _deleteIdsIn(
    ProfilesDocument doc,
    Iterable<int> profileIds,
    Iterable<int> groupIds,
  ) {
    final wantedProfiles = profileIds.toSet();
    final wantedGroups = groupIds.toSet();
    final gids = <int>{};
    doc.profiles.removeWhere((p) {
      if (wantedProfiles.contains(p.id)) {
        gids.add(p.gid);
        return true;
      }
      return wantedGroups.contains(p.gid); // group delete cascades
    });
    doc.groups.removeWhere((g) => wantedGroups.contains(g.id));
    // Never leave zero groups: keep the smallest surviving one, or seed one.
    if (doc.groups.isEmpty) {
      doc.groups.add(GroupRow(id: doc.nextGroupId, displayOrder: 1));
      doc.nextGroupId += 1;
    }
    for (final gid in gids) {
      _compact(doc, gid);
    }
  }

  /// Sets the group's member order to [ids] followed by any remaining members
  /// in their current order, keeping userOrder dense (0..n-1).
  Future<void> reorderGroup(int gid, List<int> ids) async {
    await _edit((doc) => _setOrder(doc, gid, ids));
  }

  /// Convenience reorder for the first group (used by the reorder channel arm
  /// while the UI carries a single active group id).
  Future<void> reorder(List<int> ids) async {
    final doc = await document;
    if (doc.groups.isEmpty) return;
    await reorderGroup(doc.groups.first.id, ids);
  }

  void _setOrder(ProfilesDocument doc, int gid, List<int> ids) {
    final current = doc.profiles.where((p) => p.gid == gid).toList();
    final members = current.map((p) => p.id).toSet();
    final wanted = ids.where(members.contains).toSet();
    final ordered = <int>[
      ...ids.where(wanted.contains),
      ...current.map((p) => p.id).where((id) => !wanted.contains(id)),
    ];
    final positions = <int, int>{for (final p in current) p.id: p.userOrder};
    final orderedSet = <int, int>{for (var i = 0; i < ordered.length; i++) ordered[i]: i};
    for (var i = 0; i < doc.profiles.length; i++) {
      final p = doc.profiles[i];
      if (p.gid != gid) continue;
      final index = orderedSet[p.id];
      if (index != null && positions[p.id] != index) {
        doc.profiles[i] = p.copyWith(userOrder: index);
      }
    }
  }

  Future<void> clearTestResults(Iterable<int> ids) async {
    final wanted = ids.toSet();
    await _edit((doc) {
      for (var i = 0; i < doc.profiles.length; i++) {
        if (wanted.contains(doc.profiles[i].id)) {
          doc.profiles[i] = doc.profiles[i].clearedTestResults();
        }
      }
    });
  }

  Future<void> clearGroupTestResults(int gid) async {
    await _edit((doc) {
      for (var i = 0; i < doc.profiles.length; i++) {
        if (doc.profiles[i].gid == gid) {
          doc.profiles[i] = doc.profiles[i].clearedTestResults();
        }
      }
    });
  }

  Future<void> clearTraffic(Iterable<int> ids) async {
    final wanted = ids.toSet();
    await _edit((doc) {
      for (var i = 0; i < doc.profiles.length; i++) {
        if (wanted.contains(doc.profiles[i].id)) {
          doc.profiles[i] = doc.profiles[i].copyWith(rx: 0, tx: 0);
        }
      }
    });
  }

  Future<void> clearGroupTraffic(int gid) async {
    await _edit((doc) {
      for (var i = 0; i < doc.profiles.length; i++) {
        if (doc.profiles[i].gid == gid) {
          doc.profiles[i] = doc.profiles[i].copyWith(rx: 0, tx: 0);
        }
      }
    });
  }

  // --- group writes --------------------------------------------------------

  Future<GroupRow> createGroup({String name = '', String url = ''}) async {
    late final GroupRow created;
    await _edit((doc) {
      final maxOrder = doc.groups.fold<int>(
          0, (m, g) => g.displayOrder > m ? g.displayOrder : m);
      created = GroupRow(
        id: doc.nextGroupId,
        name: name,
        url: url,
        displayOrder: maxOrder + 1,
      );
      doc.groups.add(created);
      doc.nextGroupId += 1;
    });
    return created;
  }

  Future<void> updateGroup(GroupRow row) async {
    await _edit((doc) {
      final index = doc.groups.indexWhere((g) => g.id == row.id);
      if (index >= 0) doc.groups[index] = row;
    });
  }

  Future<bool> deleteGroup(int id) async {
    late final bool removed;
    await _edit((doc) {
      final index = doc.groups.indexWhere((g) => g.id == id);
      if (index < 0 || doc.groups.length <= 1) {
        removed = false;
        return;
      }
      doc.groups.removeAt(index);
      // A group's profiles go with it (Room's foreign-key cascade).
      doc.profiles.removeWhere((p) => p.gid == id);
      removed = true;
    });
    return removed;
  }

  Future<void> reorderGroups(List<int> ids) async {
    await _edit((doc) => _reorderGroupsIn(doc, ids));
  }

  void _reorderGroupsIn(ProfilesDocument doc, List<int> ids) {
    final existing = doc.groups.map((g) => g.id).toList();
    final ordered = <int>[
      ...ids.where(existing.contains),
      ...existing.where((id) => !ids.contains(id)),
    ];
    final positions = <int, int>{for (var i = 0; i < ordered.length; i++) ordered[i]: i};
    for (var i = 0; i < doc.groups.length; i++) {
      final index = positions[doc.groups[i].id];
      if (index != null) {
        doc.groups[i] = doc.groups[i].copyWith(displayOrder: index);
      }
    }
  }

  // --- bulk / authority ----------------------------------------------------

  /// Imports parsed rows (from Kotlin's parse-only handlers via
  /// `profiles.applyDocument`), merging by id. Existing ids are replaced;
  /// new ids are appended. next*Id counters advance past the largest id.
  Future<void> importRows({
    List<ProfileRow> profiles = const [],
    List<GroupRow> groups = const [],
    int? nextProfileId,
    int? nextGroupId,
  }) async {
    await _edit((doc) => _importRowsIn(doc, profiles, groups, nextProfileId, nextGroupId));
  }

  void _importRowsIn(
    ProfilesDocument doc,
    List<ProfileRow> profiles,
    List<GroupRow> groups,
    int? nextProfileId,
    int? nextGroupId,
  ) {
    final pIndex = <int, int>{
      for (var i = 0; i < doc.profiles.length; i++) doc.profiles[i].id: i
    };
    for (final p in profiles) {
      final i = pIndex[p.id];
      if (i == null) {
        pIndex[p.id] = doc.profiles.length;
        doc.profiles.add(p);
      } else {
        doc.profiles[i] = p;
      }
    }
    final gIndex = <int, int>{
      for (var i = 0; i < doc.groups.length; i++) doc.groups[i].id: i
    };
    for (final g in groups) {
      final i = gIndex[g.id];
      if (i == null) {
        gIndex[g.id] = doc.groups.length;
        doc.groups.add(g);
      } else {
        doc.groups[i] = g;
      }
    }
    final maxP = doc.profiles.fold<int>(0, (m, p) => p.id > m ? p.id : m);
    final maxG = doc.groups.fold<int>(0, (m, g) => g.id > m ? g.id : m);
    doc.nextProfileId = _maxNext(doc.nextProfileId, maxP, nextProfileId);
    doc.nextGroupId = _maxNext(doc.nextGroupId, maxG, nextGroupId);
  }

  /// Imports parsed rows the way [importRows] does, but lets a caller hand rows
  /// with a non-positive **client id** (Kotlin allocates a temporary negative id
  /// before Dart, the id authority, can assign the real one). Every such row is
  /// given the next id from the matching counter, and the mapping from the
  /// original client id to the assigned id is returned so the caller can fix up
  /// its in-memory entities. Positive ids are kept as-is (idempotent re-import).
  Future<AllocatedProfileIds> importRowsAllocating({
    List<ProfileRow> profiles = const [],
    List<GroupRow> groups = const [],
  }) async {
    final profileIds = <int, int>{};
    final groupIds = <int, int>{};
    await _edit(
        (doc) => _importRowsAllocatingIn(doc, profiles, groups, profileIds, groupIds));
    return AllocatedProfileIds(profiles: profileIds, groups: groupIds);
  }

  void _importRowsAllocatingIn(
    ProfilesDocument doc,
    List<ProfileRow> profiles,
    List<GroupRow> groups,
    Map<int, int> profileIds,
    Map<int, int> groupIds,
  ) {
    for (final p in profiles) {
      final resolved = p.id <= 0 ? _allocateProfile(doc, p) : p;
      if (p.id <= 0) profileIds[p.id] = resolved.id;
      _upsertProfile(doc, resolved);
    }
    for (final g in groups) {
      final resolved = g.id <= 0 ? _allocateGroup(doc, g) : g;
      if (g.id <= 0) groupIds[g.id] = resolved.id;
      _upsertGroup(doc, resolved);
    }
    _syncCounters(doc);
  }

  /// A combined `profiles.applyDocument` request — replace-all, deletes, row
  /// imports (with or without id allocation), column patches, traffic deltas
  /// and reorders — applied as ONE serialized edit and one persist. The merge
  /// used to run as several independent edits, which let a traffic tick or a
  /// UI reorder land between its steps and observe a half-applied request.
  ///
  /// Returns the client→real id map when [allocateIds] (empty otherwise).
  Future<AllocatedProfileIds> applyCombined({
    required bool replaceAll,
    int? nextProfileId,
    int? nextGroupId,
    List<ProfileRow> profiles = const [],
    List<GroupRow> groups = const [],
    bool allocateIds = false,
    Iterable<int> deleteProfileIds = const [],
    Iterable<int> deleteGroupIds = const [],
    Map<int, Map<String, dynamic>> patches = const {},
    Map<int, ({int rx, int tx})> traffic = const {},
    Map<int, Map<String, dynamic>> groupPatches = const {},
    int? reorderGroupId,
    List<int>? reorderProfileIds,
    bool reorderGroups = false,
  }) =>
      _edit((doc) {
        if (replaceAll) {
          // The whole document is replaced but version/name survive, and the
          // counters normalise past the largest row — `replaceAll`'s rules.
          if (nextProfileId != null) doc.nextProfileId = nextProfileId;
          if (nextGroupId != null) doc.nextGroupId = nextGroupId;
          doc.profiles
            ..clear()
            ..addAll(profiles);
          doc.groups
            ..clear()
            ..addAll(groups);
          _syncCounters(doc);
          return const AllocatedProfileIds();
        }
        if (deleteProfileIds.isNotEmpty || deleteGroupIds.isNotEmpty) {
          _deleteIdsIn(doc, deleteProfileIds, deleteGroupIds);
        }
        final allocated = <int, int>{};
        final allocatedGroups = <int, int>{};
        if (allocateIds) {
          _importRowsAllocatingIn(doc, profiles, groups, allocated, allocatedGroups);
        } else if (profiles.isNotEmpty || groups.isNotEmpty) {
          _importRowsIn(doc, profiles, groups, nextProfileId, nextGroupId);
        }
        _patchProfilesIn(doc, patches);
        _addTrafficIn(doc, traffic);
        _patchGroupsIn(doc, groupPatches);
        if (reorderGroupId != null && reorderProfileIds != null) {
          _setOrder(doc, reorderGroupId, reorderProfileIds);
        }
        if (reorderGroups) {
          _reorderGroupsIn(doc, doc.groups.map((g) => g.id).toList());
        }
        return AllocatedProfileIds(profiles: allocated, groups: allocatedGroups);
      });

  ProfileRow _allocateProfile(ProfilesDocument doc, ProfileRow row) => row.copyWith(id: doc.nextProfileId++);

  GroupRow _allocateGroup(ProfilesDocument doc, GroupRow row) => row.copyWith(id: doc.nextGroupId++);

  void _upsertProfile(ProfilesDocument doc, ProfileRow row) {
    final i = doc.profiles.indexWhere((p) => p.id == row.id);
    if (i < 0) {
      doc.profiles.add(row);
    } else {
      doc.profiles[i] = row;
    }
  }

  void _upsertGroup(ProfilesDocument doc, GroupRow row) {
    final i = doc.groups.indexWhere((g) => g.id == row.id);
    if (i < 0) {
      doc.groups.add(row);
    } else {
      doc.groups[i] = row;
    }
  }

  void _syncCounters(ProfilesDocument doc) {
    final maxP = doc.profiles.fold<int>(0, (m, p) => p.id > m ? p.id : m);
    final maxG = doc.groups.fold<int>(0, (m, g) => g.id > m ? g.id : m);
    if (doc.nextProfileId <= maxP) doc.nextProfileId = maxP + 1;
    if (doc.nextGroupId <= maxG) doc.nextGroupId = maxG + 1;
  }

  /// Applies Room-column-keyed partial updates by id. Missing ids are skipped
  /// (the row was deleted between the read and the write); present rows keep
  /// every column the patch does not name. Used for high-frequency writes
  /// (traffic, latency, test results) so they cannot clobber a concurrent edit.
  Future<void> patchProfiles(Map<int, Map<String, dynamic>> patches) async {
    if (patches.isEmpty) return;
    await _edit((doc) => _patchProfilesIn(doc, patches));
  }

  void _patchProfilesIn(
      ProfilesDocument doc, Map<int, Map<String, dynamic>> patches) {
    for (var i = 0; i < doc.profiles.length; i++) {
      final patch = patches[doc.profiles[i].id];
      if (patch != null) doc.profiles[i] = doc.profiles[i].applyPatch(patch);
    }
  }

  Future<void> patchGroups(Map<int, Map<String, dynamic>> patches) async {
    if (patches.isEmpty) return;
    await _edit((doc) => _patchGroupsIn(doc, patches));
  }

  void _patchGroupsIn(
      ProfilesDocument doc, Map<int, Map<String, dynamic>> patches) {
    for (var i = 0; i < doc.groups.length; i++) {
      final patch = patches[doc.groups[i].id];
      if (patch != null) doc.groups[i] = doc.groups[i].applyPatch(patch);
    }
  }

  /// Atomically adds traffic deltas to the named rows inside the serialized
  /// edit, so concurrent speed-test credits cannot lose each other's increments
  /// (a read-then-absolute-patch from Kotlin would race on the cached snapshot).
  Future<void> addTraffic(Map<int, ({int rx, int tx})> deltas) async {
    if (deltas.isEmpty) return;
    await _edit((doc) => _addTrafficIn(doc, deltas));
  }

  void _addTrafficIn(
      ProfilesDocument doc, Map<int, ({int rx, int tx})> deltas) {
    for (var i = 0; i < doc.profiles.length; i++) {
      final delta = deltas[doc.profiles[i].id];
      if (delta != null) {
        final p = doc.profiles[i];
        doc.profiles[i] = p.copyWith(rx: p.rx + delta.rx, tx: p.tx + delta.tx);
      }
    }
  }

  static int _maxNext(int current, int maxId, int? explicit) {
    final fromMax = maxId + 1;
    final candidate = explicit ?? (fromMax > current ? fromMax : current);
    return candidate > current ? candidate : current;
  }

  // --- helpers -------------------------------------------------------------

  static int nextProfileOrder(ProfilesDocument doc, int gid) {
    var max = -1;
    for (final p in doc.profiles) {
      if (p.gid == gid && p.userOrder > max) max = p.userOrder;
    }
    return max + 1;
  }

  static void _compact(ProfilesDocument doc, int gid) {
    final members = doc.profiles.where((p) => p.gid == gid).toList()
      ..sort((a, b) => a.userOrder.compareTo(b.userOrder) == 0
          ? a.id.compareTo(b.id)
          : a.userOrder.compareTo(b.userOrder));
    for (var i = 0; i < members.length; i++) {
      if (members[i].userOrder != i) {
        final index = doc.profiles.indexOf(members[i]);
        doc.profiles[index] = members[i].copyWith(userOrder: i);
      }
    }
  }
}

// --- migration -------------------------------------------------------------

/// What the migration needs from the retired database. Kept narrow so the row
/// mapping is testable with a fixed set of [SqlRow]s; the host supplies the
/// rows (Kotlin's `LegacyRoomReader`, the only reader of that file — ADR 0006
/// stage C2c2b2 removed Room and the ffi SQLite reader).
abstract class RoomProfileReader {
  List<SqlRow> profiles();
  List<SqlRow> groups();
}

/// Result of a migration attempt, for diagnostics on the Dart side.
class ProfilesMigrationResult {
  const ProfilesMigrationResult({
    required this.migrated,
    required this.profileCount,
    required this.groupCount,
  });

  final bool migrated;
  final int profileCount;
  final int groupCount;
}

/// One-time, idempotent legacy -> JSON handover.
///
/// The document file is the marker: when it exists and parses, the migration
/// is considered done (even if the preferences marker write was interrupted),
/// so a restart after a crash never re-copies stale rows over newer JSON.
/// A half-written file can never exist: replaceAll writes to a temp path and
/// renames atomically, so a crash before the rename leaves no document and the
/// next launch simply retries. The retired database is untouched — retry always
/// has a source (Kotlin reads it read-only, see LegacyRoomReader).
///
/// [alreadyMigrated] and [markMigrated] are callbacks so this function does not
/// depend on the preferences channel: the caller wires them to its own store.
Future<ProfilesMigrationResult> migrateProfilesFromRoom({
  required ProfileStore store,
  required RoomProfileReader room,
  required Future<bool> Function() alreadyMigrated,
  required Future<void> Function() markMigrated,
  bool force = false,
}) async {
  if (!force && await alreadyMigrated()) {
    return const ProfilesMigrationResult(migrated: false, profileCount: 0, groupCount: 0);
  }
  // A valid document on disk also means "done", even without the preference
  // marker (the process may have died between the atomic rename and the mark).
  // Under [force] (explicit recovery) a *corrupt* document is rebuilt from Room
  // instead of failing; a still-valid document is never overwritten with the
  // stale Room copy — that would throw away newer edits the document holds.
  if (!force && await store.exists()) {
    await store.reload(); // throws on a corrupt doc rather than overwriting it
    await markMigrated();
    return const ProfilesMigrationResult(migrated: false, profileCount: 0, groupCount: 0);
  }
  if (force && await store.exists()) {
    try {
      await store.reload();
      // Document still parses: it is authoritative and newer than Room.
      await markMigrated();
      return const ProfilesMigrationResult(migrated: false, profileCount: 0, groupCount: 0);
    } on ProfileStoreFormatException {
      // Corrupt document — fall through and rebuild it from Room below.
    }
  }

  final profileRows = room.profiles().map(ProfileRow.fromRoom).toList();
  final groupRows = room.groups().map(GroupRow.fromRoom).toList();
  final maxProfile = profileRows.fold<int>(0, (m, p) => p.id > m ? p.id : m);
  final maxGroup = groupRows.fold<int>(0, (m, g) => g.id > m ? g.id : m);

  final doc = ProfilesDocument(
    nextProfileId: maxProfile + 1,
    nextGroupId: maxGroup + 1,
    profiles: profileRows,
    groups: groupRows,
  );
  await store.replaceAll(doc);
  await markMigrated();
  return ProfilesMigrationResult(
    migrated: true,
    profileCount: profileRows.length,
    groupCount: groupRows.length,
  );
}

// --- scalar helpers --------------------------------------------------------

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

String? _nullableString(Object? value) => value is String ? value : null;

bool _bool(Object? value) {
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is num) return value != 0;
  if (value is String) return value == 'true' || value == '1';
  return false;
}
