// Dart-side Room <-> THRN write path (ADR 0005 phase 4, the last native slice).
//
// P10 moved the THRN byte codec (`backup_store.dart`) and the WebDAV transport
// (`backup_webdav.dart`) to Dart; this file replaces the two native writers that
// remained: Kotlin `BackupExport` (Room -> the embedded SQLite of a THRN
// container) and `BackupRestore` (that SQLite -> Room, with its id counters,
// table repair and settings-merge rules). Everything the host still owns lives
// behind the narrow [BackupDatabase] and [BackupEnvironment] seams below, so the
// mapping/merge logic itself can be exercised against a synthetic Room file on
// any host with a libsqlite3.
//
// Fidelity is the whole point: the SQL, column order and merge rules here are a
// literal port of `app/src/main/java/io/nekohasekai/sagernet/database/backup/`
// (`BackupExport.kt`, `BackupRestore.kt`, `DesktopSchema.kt`), which in turn
// mirror the Throne desktop's R10 §8.7/§8.8. When changing any of it, change the
// Kotlin source too (until it is deleted) and keep the two in step.

import 'dart:convert';
import 'dart:io';

import '../data/sqlite.dart' show Sqlite, SqliteDatabase, SqlRow;
import 'backup_store.dart'
    show
        ThrnParts,
        thrnAndroidMeta,
        thrnDecode,
        thrnEncode,
        thrnPartsFromMeta,
        thrnTextDate;

// ---------------------------------------------------------------------------
// Envelope / environment

/// Room's `settings` device-local keys (SettingsRegistry.DEVICE_LOCAL_KEYS):
/// never exported, never overwritten by a restore.
const Set<String> backupDeviceLocalKeys = <String>{
  'webdavServer', 'webdavUsername', 'webdavPassword', 'webdavPath',
  'deviceId', 'deviceName', 'batteryPromptShown', 'hwidFallback',
  'resumeAfterUpdate', 'updateSkippedVersionCode', 'wifiPermissionAsked',
  'serviceError', 'serviceErrorDns', 'serviceErrorGeo', 'serviceErrorRuleSets',
  'startWithoutRuleSets', 'runningProfiles', 'runningRoute',
  'core_box_api_port',
};

/// Android-only keys of the same table (SettingsRegistry.ANDROID_KEYS): a
/// desktop backup keeps this device's values for these; an Android backup
/// replaces them. Both are imported from a backup only when missing on desktop.
const Set<String> backupAndroidKeys = <String>{
  'serviceMode', 'proxyApps', 'bypassMode', 'individual', 'appendHttpProxy',
  'httpProxyBypass', 'meteredNetwork', 'vpnAllowBypass', 'wakeResetConnections',
  'networkChangeResetConnections', 'showDirectSpeed', 'showProxySpeed',
  'showGroupInNotification', 'notificationActions', 'notificationTitlePrefix',
  'notificationTitleTemplate', 'notificationContentTemplate', 'showTrafficTotal',
  'useSystemTheme', 'appTheme', 'nightTheme', 'amoledTheme', 'appLanguage',
  'groupLayoutMode', 'compactProfileRows', 'compactGroupCards',
  'hideFromRecentApps', 'logBufSize', 'logFontSize', 'appTLSVersion',
  'webdavServer', 'webdavUsername', 'webdavPassword', 'webdavPath',
  'deviceId', 'deviceName', 'profileCurrent', 'runningProfiles', 'runningRoute',
  'profileId', 'previewHintDismissedVersion', 'updateCheckAuto',
  'updateSkippedVersionCode', 'resumeAfterUpdate', 'batteryPromptShown',
  'logExportRedact', 'hwidFallback', 'wifiPermissionAsked', 'serviceError',
  'serviceErrorDns', 'serviceErrorGeo', 'serviceErrorRuleSets',
  'startWithoutRuleSets',
};

const String _rememberId = 'remember_id';
const String _currentGroup = 'current_group';
const String _currentRouteId = 'current_route_id';
const String _inboundAddress = 'inbound_address';
const String _profileId = 'profileId'; // Key.PROFILE_ID
const String _profileCurrent = 'profileCurrent'; // Key.PROFILE_CURRENT
const int _noProfileId = -1919;
const String _tunPrivateRangesIpv6 = 'migration.tun_private_ranges_ipv6';
const String _loopbackAddress = '127.0.0.1';

/// Host facts a backup needs but Dart cannot derive: app version, device id /
/// name and the place Room keeps its file. Mirrors `BackupExport.write` and the
/// `backup.create` handler's `ui` map.
class BackupEnvironment {
  const BackupEnvironment({
    required this.databasePath,
    required this.appVersion,
    required this.deviceId,
    required this.deviceName,
    required this.defaultGroupName,
    required this.preferences,
    required this.settingsDocument,
    required this.qualityDocument,
    this.now,
  });

  final String databasePath;
  final String appVersion;
  final String deviceId;
  final String deviceName;
  final String defaultGroupName;
  /// The host's preferences document minus the WebDAV account (a credential).
  final Map<String, Object?> preferences;
  /// The legacy UI settings document (`readJsonMap(SETTINGS_KEY)`).
  final Map<String, Object?> settingsDocument;
  /// The IP-quality cache document (`readJsonMap(QUALITY_KEY)`).
  final Map<String, Object?> qualityDocument;
  final DateTime Function()? now;

  Map<String, Object?> get uiPayload => <String, Object?>{
        'preferences': preferences,
        'settings': settingsDocument,
        'quality': qualityDocument,
      };
}

/// Resolves the host facts a backup needs. The default reads them from the
/// `data.path` reply (a retained data-plane fact); tests inject a synthetic one.
typedef BackupEnvironmentFactory = Future<BackupEnvironment> Function();

/// Why a backup write failed. Carries the user-facing message the bridge used
/// to emit (`backup_error_*` / `backup_warn_*` strings).
class BackupWriteException implements Exception {
  const BackupWriteException(this.message);
  final String message;
  @override
  String toString() => 'BackupWriteException: $message';
}

/// A room database handle: a thin wrapper so the merge logic can be exercised
/// with a synthetic file. Production callers open [databasePath] read-only for
/// export and read-write for restore (Room stays the authority; Dart is a
/// careful second writer for the restore transaction only).
class BackupDatabase {
  BackupDatabase._(this._db);

  final SqliteDatabase _db;

  /// Opens [path]. [sqlite] defaults to the platform library; tests inject one
  /// loaded from an explicit path.
  static BackupDatabase? open(
    String path, {
    bool readOnly = true,
    Sqlite? sqlite,
  }) {
    final lib = sqlite ?? Sqlite.open();
    if (lib == null) return null;
    final db = lib.openDatabase(path, readOnly: readOnly);
    if (db == null) return null;
    return BackupDatabase._(db);
  }

  List<SqlRow> query(String sql, [List<Object?> params = const []]) =>
      _db.query(sql, params);

  int execute(String sql, [List<Object?> params = const []]) =>
      _db.execute(sql, params);

  void close() => _db.close();
}

// ---------------------------------------------------------------------------
// SQL DDL of the desktop snapshot (DesktopSchema.DDL), verbatim.

const List<String> desktopDdl = <String>[
  '''CREATE TABLE IF NOT EXISTS entity_ids (
    profile_last_id INTEGER NOT NULL DEFAULT 0,
    group_last_id INTEGER NOT NULL DEFAULT 0,
    route_profile_last_id INTEGER NOT NULL DEFAULT 0,
    otp_profile_last_id INTEGER NOT NULL DEFAULT 0
  )''',
  '''CREATE TABLE IF NOT EXISTS profiles (
    id INTEGER PRIMARY KEY,
    type TEXT NOT NULL,
    name TEXT,
    gid INTEGER NOT NULL DEFAULT 0,
    latency INTEGER NOT NULL DEFAULT 0,
    dl_speed TEXT,
    ul_speed TEXT,
    test_country TEXT,
    ip_out TEXT,
    outbound_json TEXT NOT NULL,
    traffic_dl INTEGER NOT NULL DEFAULT 0,
    traffic_up INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    FOREIGN KEY(gid) REFERENCES groups(id) ON DELETE CASCADE
  )''',
  'ALTER TABLE profiles ADD COLUMN latency_at INTEGER NOT NULL DEFAULT 0',
  'CREATE INDEX IF NOT EXISTS idx_profiles_name ON profiles(name)',
  '''CREATE TABLE IF NOT EXISTS groups (
    id INTEGER PRIMARY KEY,
    archive INTEGER NOT NULL DEFAULT 0,
    skip_auto_update INTEGER NOT NULL DEFAULT 0,
    name TEXT NOT NULL DEFAULT '',
    url TEXT,
    info TEXT,
    sub_last_update INTEGER NOT NULL DEFAULT 0,
    front_proxy_id INTEGER NOT NULL DEFAULT -1,
    landing_proxy_id INTEGER NOT NULL DEFAULT -1,
    column_width_json TEXT,
    profiles_json TEXT NOT NULL DEFAULT '[]',
    scroll_last_profile INTEGER NOT NULL DEFAULT -1,
    auto_clear_unavailable INTEGER NOT NULL DEFAULT 0,
    test_sort_by INTEGER NOT NULL DEFAULT 0,
    traffic_sort_by INTEGER NOT NULL DEFAULT 0,
    test_items_to_show INTEGER NOT NULL DEFAULT 0,
    type_sort_by INTEGER NOT NULL DEFAULT 0,
    sub_options_json TEXT NOT NULL DEFAULT '{}',
    sub_metadata_json TEXT NOT NULL DEFAULT '{}',
    sort_method INTEGER NOT NULL DEFAULT 0,
    sort_descending INTEGER NOT NULL DEFAULT 0,
    route_id INTEGER NOT NULL DEFAULT -1,
    import_sub_route INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
  )''',
  '''CREATE TABLE IF NOT EXISTS groups_order (
    group_id INTEGER NOT NULL PRIMARY KEY,
    display_order INTEGER NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS route_profiles (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    default_outbound_id INTEGER NOT NULL DEFAULT -1,
    is_raw INTEGER NOT NULL DEFAULT 0,
    raw_route TEXT NOT NULL DEFAULT '',
    prevent_modifications INTEGER NOT NULL DEFAULT 0,
    is_remote INTEGER NOT NULL DEFAULT 0,
    remote_url TEXT NOT NULL DEFAULT '',
    auto_update INTEGER NOT NULL DEFAULT 0,
    remote_last_update INTEGER NOT NULL DEFAULT 0,
    endpoint_profile_ids TEXT NOT NULL DEFAULT '[]',
    inner_hop_endpoint_ids TEXT NOT NULL DEFAULT '[]',
    dns_json TEXT NOT NULL DEFAULT '',
    custom_dns INTEGER NOT NULL DEFAULT 0,
    source_gid INTEGER NOT NULL DEFAULT -1,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
  )''',
  '''CREATE TABLE IF NOT EXISTS route_rules (
    route_profile_id INTEGER NOT NULL,
    rule_order INTEGER NOT NULL,
    name TEXT NOT NULL DEFAULT '',
    type INTEGER NOT NULL DEFAULT 0,
    ip_version TEXT,
    network TEXT,
    protocol TEXT,
    inbound_json TEXT,
    domain_json TEXT,
    domain_suffix_json TEXT,
    domain_keyword_json TEXT,
    domain_regex_json TEXT,
    source_ip_cidr_json TEXT,
    source_ip_is_private INTEGER NOT NULL DEFAULT 0,
    ip_cidr_json TEXT,
    ip_is_private INTEGER NOT NULL DEFAULT 0,
    source_port_json TEXT,
    source_port_range_json TEXT,
    port_json TEXT,
    port_range_json TEXT,
    process_name_json TEXT,
    process_path_json TEXT,
    process_path_regex_json TEXT,
    rule_set_json TEXT,
    invert INTEGER NOT NULL DEFAULT 0,
    outbound_id INTEGER NOT NULL DEFAULT -2,
    action TEXT NOT NULL DEFAULT 'route',
    reject_method TEXT,
    no_drop INTEGER NOT NULL DEFAULT 0,
    override_address TEXT,
    override_port TEXT,
    sniffers_json TEXT,
    sniff_override_dest INTEGER NOT NULL DEFAULT 0,
    strategy TEXT,
    wifi_ssid_json TEXT,
    wifi_bssid_json TEXT,
    tls_spoof TEXT,
    tls_spoof_method TEXT,
    package_name_json TEXT,
    tls_fragment INTEGER NOT NULL DEFAULT 0,
    tls_fragment_fallback_delay TEXT,
    tls_record_fragment INTEGER NOT NULL DEFAULT 0,
    disabled INTEGER NOT NULL DEFAULT 0,
    network_type_json TEXT,
    network_is_expensive INTEGER NOT NULL DEFAULT 0,
    package_name_regex_json TEXT,
    PRIMARY KEY (route_profile_id, rule_order),
    FOREIGN KEY(route_profile_id) REFERENCES route_profiles(id) ON DELETE CASCADE
  )''',
  '''CREATE TABLE IF NOT EXISTS otp_profiles (
    id INTEGER PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    issuer TEXT NOT NULL DEFAULT '',
    secret TEXT NOT NULL DEFAULT '',
    algorithm INTEGER NOT NULL DEFAULT 0,
    type INTEGER NOT NULL DEFAULT 0,
    digits INTEGER NOT NULL DEFAULT 6,
    period INTEGER NOT NULL DEFAULT 30,
    counter INTEGER NOT NULL DEFAULT 0,
    sort_order INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now')),
    updated_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
  )''',
  '''CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )''',
  '''CREATE TABLE IF NOT EXISTS markers (
    key TEXT PRIMARY KEY,
    marked_at INTEGER NOT NULL DEFAULT (strftime('%s', 'now'))
  )''',
];

// ---------------------------------------------------------------------------
// Shared helpers

class _SqlTable {
  _SqlTable(this.columns, [List<List<Object?>>? rows])
      : rows = rows ?? <List<Object?>>[];

  final List<String> columns;
  final List<List<Object?>> rows;

  int index(String column) => columns.indexOf(column);
}

/// Quotes identifiers the Kotlin way (backticks, doubled inside a name).
String _sqlName(String name) => '`${name.replaceAll('`', '``')}`';
String _quoted(Iterable<String> columns) => columns.map(_sqlName).join(',');

List<String> _columnsOf(BackupDatabase db, String table) => db
    .query('PRAGMA table_info(${_sqlName(table)})')
    .map((row) => '${row['name']}')
    .toList();

bool _hasTable(BackupDatabase db, String table) => db
        .query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            <Object?>[table])
        .isNotEmpty;

int? _longQuery(BackupDatabase db, String sql, [List<Object?> params = const []]) {
  final rows = db.query(sql, params);
  if (rows.isEmpty) return null;
  final value = rows.first.values.first;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

void _insertRows(
  BackupDatabase db,
  String table,
  List<String> columns,
  Iterable<List<Object?>> rows,
) {
  if (rows.isEmpty) return;
  final sql = 'INSERT INTO ${_sqlName(table)} (${_quoted(columns)}) '
      'VALUES (${columns.map((_) => '?').join(',')})';
  for (final row in rows) {
    db.execute(sql, row.toList());
  }
}

List<Object?> _jsonArrayIds(String text) {
  try {
    final value = jsonDecode(text);
    if (value is! List) return const <Object?>[];
    return value.map((item) {
      if (item is int) return item;
      if (item is num) return item.toInt();
      return null;
    }).toList();
  } catch (_) {
    return const <Object?>[];
  }
}

String _jsonArrayOf(Iterable<int> ids) =>
    '[${ids.map((id) => id.toString()).join(',')}]';

int _toId(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? 0;
  return 0;
}

bool _isTrue(Object? value) => value == 1 || value == true;

// ---------------------------------------------------------------------------
// export: Room -> the desktop SQLite -> THRN

/// The parts to export; `profiles` is always on (BboxBackup.selection).
class BackupSelection {
  const BackupSelection({
    required this.profiles,
    required this.routes,
    required this.settings,
  });

  final bool profiles;
  final bool routes;
  final bool settings;

  bool get any => profiles || routes || settings;
}

class _Snapshot {
  _SqlTable? profiles;
  _SqlTable? groups;
  _SqlTable? routeProfiles;
  _SqlTable? routeRules;
  _SqlTable? markers;
  Map<String, String>? settings;

  final Map<int, List<int>> members = <int, List<int>>{};
  final List<_Tab> tabs = <_Tab>[];
  final Map<String, int> counters = <String, int>{};
}

class _Tab {
  const _Tab(this.id, this.order);
  final int id;
  final int order;
}

/// Creates a THRN envelope from Room's live database.
///
/// [enrichUi] builds the `ui` map from the current host documents; it is called
/// once at the start so a backup never embeds the WebDAV password.
Future<Map<String, Object?>> createBackup({
  required BackupEnvironment env,
  required String scope,
  Sqlite? sqlite,
  BackupDatabase Function(String path, {bool readOnly, Sqlite? sqlite})? open,
  Map<String, Object?> Function()? enrichUi,
}) async {
  final ui = enrichUi?.call() ?? env.uiPayload;
  final selection = BackupSelection(
    profiles: true,
    routes: scope != 'profiles',
    settings: scope != 'profiles',
  );
  if (!selection.any) {
    throw const BackupWriteException('Nothing was selected for backup');
  }

  final opener = open ?? BackupDatabase.open;
  final source = opener(env.databasePath, readOnly: true, sqlite: sqlite);
  if (source == null) {
    throw const BackupWriteException('The local database cannot be opened');
  }
  final dir = await Directory.systemTemp.createTemp('thrn-export-');
  final snapshotPath = '${dir.path}/backup.db';
  BackupDatabase? target;
  try {
    target = opener(snapshotPath, readOnly: false, sqlite: sqlite);
    if (target == null) {
      throw const BackupWriteException('The backup database cannot be created');
    }
    final snapshot = _snapshot(source, selection);
    _buildDatabase(target, snapshot, selection, env);
    _verify(target, selection);
    final bytes = File(snapshotPath).readAsBytesSync();
    final containerBytes = thrnEncode(
      thrnAndroidMeta(
        parts: ThrnParts(
          profiles: selection.profiles,
          routes: selection.routes,
          settings: selection.settings,
        ),
        appVersion: env.appVersion,
        deviceId: env.deviceId,
        deviceName: env.deviceName,
        createdAt: thrnTextDate((env.now ?? DateTime.now)()),
      )..['flrone_ui'] = ui,
      <String, List<int>>{'database': bytes},
    );
    final groups = _profileNames(source);
    return <String, Object?>{
      'format': 2,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'scope': scope,
      'profiles': groups,
      'thr': base64Encode(containerBytes),
      'ui': ui,
    };
  } finally {
    target?.close();
    source.close();
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // best-effort cleanup
    }
  }
}

_SqlTable _copyTable(
  BackupDatabase live,
  String table,
  String order,
  List<String> desktopColumns,
) {
  final android = _columnsOf(live, table).toSet();
  final columns = desktopColumns.where((c) => android.contains(c)).toList();
  final rows = <List<Object?>>[];
  for (final row in live.query(
      'SELECT ${_quoted(columns)} FROM ${_sqlName(table)} ORDER BY $order')) {
    rows.add(columns.map((c) => row[c]).toList());
  }
  return _SqlTable(columns, rows);
}

_Snapshot _snapshot(BackupDatabase live, BackupSelection selection) {
  final s = _Snapshot();
  final desktop = <String, List<String>>{
    for (final table in const ['profiles', 'groups', 'route_profiles', 'route_rules', 'settings', 'markers'])
      table: _desktopColumnsFor(table),
  };

  for (final row in live.query(
      'SELECT `id`, `display_order` FROM `groups` ORDER BY `display_order`, `id`')) {
    s.tabs.add(_Tab(_toId(row['id']), _toId(row['display_order'])));
  }
  for (final row in live.query(
      'SELECT `gid`, `id` FROM `profiles` ORDER BY `gid`, `user_order`, `id`')) {
    final gid = _toId(row['gid']);
    (s.members[gid] ??= <int>[]).add(_toId(row['id']));
  }
  final routes = <({int id, bool raw})>[];
  for (final row in live.query('SELECT `id`, `is_raw` FROM `route_profiles` ORDER BY `id`')) {
    routes.add((id: _toId(row['id']), raw: _isTrue(row['is_raw'])));
  }
  final sequences = <String, int>{};
  try {
    for (final row in live.query('SELECT `name`, `seq` FROM `sqlite_sequence`')) {
      sequences['${row['name']}'] = _toId(row['seq']);
    }
  } on Object {
    // sqlite_sequence is absent on a fresh database.
  }
  final profileIds = s.members.values.expand((ids) => ids).toList();
  final groupIds = s.tabs.map((t) => t.id).toList();
  s.counters['profiles'] = [
    sequences['profiles'] ?? 0,
    if (profileIds.isNotEmpty) profileIds.reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);
  s.counters['groups'] = [
    sequences['groups'] ?? 0,
    if (groupIds.isNotEmpty) groupIds.reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);
  s.counters['route_profiles'] = [
    sequences['route_profiles'] ?? 0,
    if (routes.isNotEmpty) routes.map((r) => r.id).reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);

  if (selection.profiles) {
    s.profiles = _copyTable(live, 'profiles', '`id`', desktop['profiles']!);
    s.groups = _copyTable(live, 'groups', '`display_order`, `id`', desktop['groups']!);
  }
  if (selection.routes) {
    s.routeProfiles = _copyTable(live, 'route_profiles', '`id`', desktop['route_profiles']!);
    s.routeRules = _copyTable(
        live, 'route_rules', '`route_profile_id`, `rule_order`', desktop['route_rules']!);
  }
  if (selection.settings) {
    final stored = <String, String>{};
    for (final row in live.query('SELECT `key`, `value` FROM `settings` ORDER BY `key`')) {
      final key = row['key'];
      final value = row['value'];
      if (key is String && value is String) stored[key] = value;
    }
    s.settings = _exportedSettings(stored, groupIds, profileIds.toSet(), routes);
    s.markers = _copyTable(live, 'markers', '`key`', desktop['markers']!);
    final keyIndex = s.markers!.index('key');
    if (!s.markers!.rows.any((row) => row[keyIndex] == _tunPrivateRangesIpv6)) {
      final row = List<Object?>.filled(s.markers!.columns.length, null);
      if (keyIndex >= 0) row[keyIndex] = _tunPrivateRangesIpv6;
      final at = s.markers!.index('marked_at');
      if (at >= 0) {
        row[at] = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      }
      s.markers!.rows.add(row);
    }
  }
  return s;
}

/// The desktop column lists in `DesktopSchema.DDL` order, minus derived columns.
List<String> _desktopColumnsFor(String table) => switch (table) {
      'profiles' => const <String>[
          'id', 'type', 'name', 'gid', 'latency', 'dl_speed', 'ul_speed',
          'test_country', 'ip_out', 'outbound_json', 'traffic_dl', 'traffic_up',
          'created_at', 'updated_at', 'latency_at',
        ],
      'groups' => const <String>[
          'id', 'archive', 'skip_auto_update', 'name', 'url', 'info',
          'sub_last_update', 'front_proxy_id', 'landing_proxy_id',
          'column_width_json', 'profiles_json', 'scroll_last_profile',
          'auto_clear_unavailable', 'test_sort_by', 'traffic_sort_by',
          'test_items_to_show', 'type_sort_by', 'sub_options_json',
          'sub_metadata_json', 'sort_method', 'sort_descending', 'route_id',
          'import_sub_route', 'created_at', 'updated_at',
        ],
      'route_profiles' => const <String>[
          'id', 'name', 'default_outbound_id', 'is_raw', 'raw_route',
          'prevent_modifications', 'is_remote', 'remote_url', 'auto_update',
          'remote_last_update', 'endpoint_profile_ids', 'inner_hop_endpoint_ids',
          'dns_json', 'custom_dns', 'source_gid', 'created_at', 'updated_at',
        ],
      'route_rules' => const <String>[
          'route_profile_id', 'rule_order', 'name', 'type', 'ip_version',
          'network', 'protocol', 'inbound_json', 'domain_json',
          'domain_suffix_json', 'domain_keyword_json', 'domain_regex_json',
          'source_ip_cidr_json', 'source_ip_is_private', 'ip_cidr_json',
          'ip_is_private', 'source_port_json', 'source_port_range_json',
          'port_json', 'port_range_json', 'process_name_json', 'process_path_json',
          'process_path_regex_json', 'rule_set_json', 'invert', 'outbound_id',
          'action', 'reject_method', 'no_drop', 'override_address',
          'override_port', 'sniffers_json', 'sniff_override_dest', 'strategy',
          'wifi_ssid_json', 'wifi_bssid_json', 'tls_spoof', 'tls_spoof_method',
          'package_name_json', 'tls_fragment', 'tls_fragment_fallback_delay',
          'tls_record_fragment', 'disabled', 'network_type_json',
          'network_is_expensive', 'package_name_regex_json',
        ],
      'settings' => const <String>['key', 'value'],
      'markers' => const <String>['key', 'marked_at'],
      _ => const <String>[],
    };

Map<String, String> _exportedSettings(
  Map<String, String> stored,
  List<int> groupIds,
  Set<int> profileIds,
  List<({int id, bool raw})> routes,
) {
  final out = <String, String>{};
  stored.forEach((key, value) {
    if (!backupDeviceLocalKeys.contains(key)) out[key] = value;
  });
  int? id(String? key) => key == null ? null : int.tryParse((stored[key] ?? '').trim());

  final group = id(_currentGroup) != null && groupIds.contains(id(_currentGroup))
      ? id(_currentGroup)
      : (groupIds.isNotEmpty ? groupIds.first : null);
  if (group != null) out[_currentGroup] = group.toString();

  final usable = routes.where((r) => !r.raw).map((r) => r.id).toList();
  final route = (id(_currentRouteId) != null && usable.contains(id(_currentRouteId)))
      ? id(_currentRouteId)
      : (usable.isNotEmpty ? usable.first : (routes.isNotEmpty ? routes.first.id : null));
  if (route != null) out[_currentRouteId] = route.toString();

  final remember = <String?>[_profileId, _profileCurrent, _rememberId]
      .map(id)
      .firstWhere(
        (value) => value != null && profileIds.contains(value),
        orElse: () => null,
      );
  out[_rememberId] = (remember ?? _noProfileId).toString();
  return out;
}

void _buildDatabase(
  BackupDatabase db,
  _Snapshot s,
  BackupSelection selection,
  BackupEnvironment env,
) {
  for (final sql in desktopDdl) {
    db.execute(sql);
  }
  db.execute(
    'INSERT INTO entity_ids (profile_last_id, group_last_id, route_profile_last_id, otp_profile_last_id) '
    'VALUES (?, ?, ?, 0)',
    <Object?>[
      s.counters['profiles'] ?? 0,
      s.counters['groups'] ?? 0,
      s.counters['route_profiles'] ?? 0,
    ],
  );
  final groups = s.groups;
  if (groups != null) {
    final idIndex = groups.index('id');
    final columns = <String>[...groups.columns, 'profiles_json'];
    final rows = groups.rows.map((row) {
      final id = _toId(row[idIndex]);
      final memberIds = s.members[id] ?? const <int>[];
      return <Object?>[...row, _jsonArrayOf(memberIds)];
    }).toList();
    _insertRows(db, 'groups', columns, rows);
    _insertRows(
      db,
      'groups_order',
      const ['group_id', 'display_order'],
      s.tabs.map((tab) => <Object?>[tab.id, tab.order]),
    );
  }
  if (s.profiles != null) {
    _insertRows(db, 'profiles', s.profiles!.columns, s.profiles!.rows);
  }
  if (s.routeProfiles != null) {
    _insertRows(db, 'route_profiles', s.routeProfiles!.columns, s.routeProfiles!.rows);
  }
  final rules = s.routeRules;
  if (rules != null) {
    final profile = rules.index('route_profile_id');
    final order = rules.index('rule_order');
    Object? last;
    var next = 0;
    for (final row in rules.rows) {
      if (row[profile] != last) {
        last = row[profile];
        next = 0;
      }
      row[order] = next++;
    }
    _insertRows(db, 'route_rules', rules.columns, rules.rows);
  }
  if (selection.settings) {
    _insertRows(
      db,
      'settings',
      const ['key', 'value'],
      (s.settings ?? const <String, String>{})
          .entries
          .map((e) => <Object?>[e.key, e.value]),
    );
    if (s.markers != null) {
      _insertRows(db, 'markers', s.markers!.columns, s.markers!.rows);
    }
  }
}

void _verify(BackupDatabase db, BackupSelection selection) {
  void zero(String what, String sql) {
    final n = _longQuery(db, sql) ?? 0;
    if (n != 0) throw BackupWriteException('backup check failed: $what ($n)');
  }

  if (selection.profiles) {
    zero(
        'groups without one tab',
        'SELECT COUNT(*) FROM groups g WHERE (SELECT COUNT(*) FROM groups_order o WHERE o.group_id = g.id) != 1');
    zero('tabs without a group',
        'SELECT COUNT(*) FROM groups_order o WHERE NOT EXISTS (SELECT 1 FROM groups g WHERE g.id = o.group_id)');
    zero('profiles without a group',
        'SELECT COUNT(*) FROM profiles p WHERE NOT EXISTS (SELECT 1 FROM groups g WHERE g.id = p.gid)');
    final members = <int, Set<int>>{};
    for (final row in db.query('SELECT gid, id FROM profiles')) {
      (members[_toId(row['gid'])] ??= <int>{}).add(_toId(row['id']));
    }
    for (final row in db.query('SELECT id, profiles_json FROM groups')) {
      final gid = _toId(row['id']);
      final raw = row['profiles_json'];
      final listed = raw is String ? _jsonArrayIds(raw) : const <Object?>[];
      final ids = listed.whereType<int>().toSet();
      if (ids.length != listed.length ||
          ids.difference(members[gid] ?? <int>{}).isNotEmpty ||
          (members[gid] ?? <int>{}).difference(ids).isNotEmpty) {
        throw BackupWriteException('backup check failed: profiles_json of group $gid');
      }
    }
  }
  if (selection.routes) {
    zero('rules without a routing profile',
        'SELECT COUNT(*) FROM route_rules r WHERE NOT EXISTS (SELECT 1 FROM route_profiles p WHERE p.id = r.route_profile_id)');
    zero(
        'rule order',
        'SELECT COUNT(*) FROM (SELECT COUNT(*) AS n, MIN(rule_order) AS lo, MAX(rule_order) AS hi '
        'FROM route_rules GROUP BY route_profile_id) WHERE lo != 0 OR hi != n - 1');
    if (selection.settings &&
        (_longQuery(db, 'SELECT COUNT(*) FROM route_profiles') ?? 0) > 0) {
      zero(
          'current_route_id',
          "SELECT COUNT(*) FROM settings s WHERE s.key = 'current_route_id' AND "
          'NOT EXISTS (SELECT 1 FROM route_profiles p WHERE p.id = CAST(s.value AS INTEGER))');
    }
  }
}

/// The `profiles` preview array of the envelope `backup.create` hands out.
/// Kotlin's `BboxBackup.create` reads `GroupRepo.rawGroups()` — one entry per
/// group with its node count — so the confirmation dialog's count is groups,
/// not nodes. Kept identical here; the WebDAV/Dart read path (`backup_store`'s
/// `profileNamesFromContainer`) has its own preview shape and is unchanged.
List<Map<String, Object?>> _profileNames(BackupDatabase db) {
  if (!_hasTable(db, 'groups')) return const <Map<String, Object?>>[];
  final counts = <int, int>{};
  if (_hasTable(db, 'profiles')) {
    for (final row in db.query('SELECT gid, COUNT(*) AS n FROM profiles GROUP BY gid')) {
      counts[_toId(row['gid'])] = _toId(row['n']);
    }
  }
  final out = <Map<String, Object?>>[];
  for (final row in db.query('SELECT id, name, url FROM groups ORDER BY display_order, id')) {
    final id = _toId(row['id']);
    out.add(<String, Object?>{
      'name': row['name'] ?? '',
      'type': ((row['url'] as String?) ?? '').isEmpty ? 'local' : 'subscription',
      'url': row['url'] ?? '',
      'nodes': counts[id] ?? 0,
    });
  }
  return out;
}

// ---------------------------------------------------------------------------
// restore: THRN -> embedded SQLite -> Room

/// The parts to restore. Mirrors `BackupRestore.Choice`.
class RestoreChoice {
  const RestoreChoice({
    required this.profiles,
    required this.routes,
    required this.settings,
  });

  final bool profiles;
  final bool routes;
  final bool settings;

  bool get any => profiles || routes || settings;
}

class _ColumnInfo {
  _ColumnInfo(this.name, this.notNull, this.defaultSql);
  final String name;
  final bool notNull;
  final String? defaultSql;
}

List<_ColumnInfo> _columnsInfo(BackupDatabase db, String table) => db
    .query('PRAGMA table_info(${_sqlName(table)})')
    .map((row) => _ColumnInfo(
          '${row['name']}',
          _isTrue(row['notnull']),
          row['dflt_value'] is String ? row['dflt_value'] as String : null,
        ))
    .toList();

class _Staged {
  _SqlTable? groups;
  _SqlTable? profiles;
  _SqlTable? routeProfiles;
  _SqlTable? routeRules;
  Map<String, String>? settings;
  _SqlTable? markers;
  final Map<String, int> counters = <String, int>{};
}

/// Result of a restore: the warnings the native bridge used to emit.
class RestoreResult {
  const RestoreResult(this.warnings, this.ui);
  final List<String> warnings;
  final Map<String, Object?> ui;
}

/// Restores a staged envelope into Room.
///
/// [bytes] is the decoded `thr` member; [scope] and [strategy] keep the same
/// semantics as `BboxBackup.restore`. [env] supplies the Room file path and the
/// host facts the settings repair needs.
Future<RestoreResult> restoreBackup({
  required BackupEnvironment env,
  required List<int> bytes,
  required String scope,
  required String strategy,
  Sqlite? sqlite,
  BackupDatabase Function(String path, {bool readOnly, Sqlite? sqlite})? open,
  void Function()? refresh,
  Future<void> Function(Map<String, Object?> ui)? applyUi,
}) async {
  final container = thrnDecode(bytes);
  final available = thrnPartsFromMeta(
      container.version, container.meta, container.keys);
  final allParts = scope != 'profiles';
  final choice = RestoreChoice(
    profiles: available.profiles,
    routes: available.routes && allParts && strategy == 'Override',
    settings: available.settings && allParts,
  );
  if (!choice.any) {
    throw const BackupWriteException('This backup holds nothing Throne can restore');
  }
  final embedded = container.database;
  if (embedded == null || embedded.isEmpty) {
    throw const BackupWriteException('This backup has no database entry');
  }

  final opener = open ?? BackupDatabase.open;
  final dir = await Directory.systemTemp.createTemp('thrn-restore-');
  final stagedPath = '${dir.path}/restore.db';
  File(stagedPath).writeAsBytesSync(embedded);
  BackupDatabase? bak;
  BackupDatabase? main;
  final warnings = <String>[];
  try {
    bak = opener(stagedPath, readOnly: false, sqlite: sqlite);
    main = opener(env.databasePath, readOnly: false, sqlite: sqlite);
    if (bak == null || main == null) {
      throw const BackupWriteException('The backup database cannot be opened');
    }
    final staged = _stage(bak, main, choice, warnings);
    _commit(staged, choice, container.isAndroid, main, env, warnings);

    // The native bridge applied the UI documents after Room's commit and asked
    // for a catalog refresh; keep the same order so no screen sees half a state.
    final ui = container.flroneUi;
    if (scope == 'all' && applyUi != null) {
      await applyUi(ui);
    }
    refresh?.call();
    return RestoreResult(List<String>.unmodifiable(warnings), ui);
  } finally {
    bak?.close();
    main?.close();
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // best-effort cleanup
    }
  }
}

_Staged _stage(
  BackupDatabase bak,
  BackupDatabase main,
  RestoreChoice choice,
  List<String> warnings,
) {
  final staged = _Staged();
  if (choice.profiles) _stageProfiles(bak, main, staged, warnings);
  if (choice.routes) _stageRoutes(bak, main, staged, warnings);
  if (choice.settings) _stageSettings(bak, main, staged, warnings);
  if ((choice.profiles || choice.routes) && _hasTable(bak, 'entity_ids')) {
    final columns = _columnsOf(bak, 'entity_ids').toSet();
    const counterColumns = <MapEntry<String, String>>{
      MapEntry('profiles', 'profile_last_id'),
      MapEntry('groups', 'group_last_id'),
      MapEntry('route_profiles', 'route_profile_last_id'),
    };
    for (final entry in counterColumns) {
      if (!columns.contains(entry.value)) continue;
      final value = _longQuery(
          bak, 'SELECT MAX(${_sqlName(entry.value)}) FROM `entity_ids`');
      if (value != null) staged.counters[entry.key] = value;
    }
  }
  return staged;
}

void _require(BackupDatabase bak, String table) {
  if (!_hasTable(bak, table)) {
    throw BackupWriteException('The backup has no $table table.');
  }
}

/// copyTable (Database.cpp:296-313): shared columns by name, defaults for
/// NOT NULL columns, extra columns appended, rows that still miss a value skipped.
_SqlTable _stageTable(
  BackupDatabase bak,
  BackupDatabase main,
  String table,
  String order,
  List<String> warnings, {
  List<String> extra = const <String>[],
}) {
  final mainColumns = _columnsInfo(main, table);
  final bakColumns = _columnsOf(bak, table).toSet();
  for (final column in mainColumns) {
    if (column.notNull &&
        column.defaultSql == null &&
        !bakColumns.contains(column.name) &&
        !extra.contains(column.name)) {
      throw BackupWriteException(
          "The backup's $table table has no ${column.name} column.");
    }
  }
  final shared = mainColumns
      .where((c) => bakColumns.contains(c.name) && !extra.contains(c.name))
      .toList();
  final defaults = shared.map((column) {
    if (!column.notNull || column.defaultSql == null) return null;
    final rows = bak.query('SELECT ${column.defaultSql}');
    if (rows.isEmpty) return null;
    return rows.first.values.first;
  }).toList();
  final out = _SqlTable([...shared.map((c) => c.name), ...extra]);
  var skipped = 0;
  for (final row in bak.query(
      'SELECT ${_quoted(shared.map((c) => c.name))} FROM ${_sqlName(table)} ORDER BY $order')) {
    final staged = List<Object?>.filled(out.columns.length, null);
    var complete = true;
    for (var i = 0; i < shared.length; i++) {
      var value = row[shared[i].name];
      if (value == null && shared[i].notNull) value = defaults[i];
      if (value == null && shared[i].notNull) {
        complete = false;
        break;
      }
      staged[i] = value;
    }
    if (complete) {
      out.rows.add(staged);
    } else {
      skipped++;
    }
  }
  if (skipped > 0) warnings.add('$skipped invalid rows of $table were skipped.');
  return out;
}

void _stageProfiles(
  BackupDatabase bak,
  BackupDatabase main,
  _Staged staged,
  List<String> warnings,
) {
  _require(bak, 'groups');
  _require(bak, 'profiles');
  final groups = _stageTable(bak, main, 'groups', '`id`', warnings,
      extra: const ['display_order']);
  final groupId = groups.index('id');
  final groupIds = <int>{};
  for (final row in groups.rows) {
    groupIds.add(_toId(row[groupId]));
  }

  final tabs = <int, int>{};
  var orphanTabs = 0;
  if (_hasTable(bak, 'groups_order')) {
    for (final row in bak.query(
        'SELECT group_id, display_order FROM groups_order ORDER BY display_order, group_id')) {
      final id = row['group_id'];
      final order = row['display_order'];
      if (id == null || order == null) continue;
      final value = _toId(id);
      if (groupIds.contains(value)) {
        tabs.putIfAbsent(value, () => _toId(order));
      } else {
        orphanTabs++;
      }
    }
  }
  if (orphanTabs > 0) {
    warnings.add('$orphanTabs tab positions without a group were dropped.');
  }
  final untabbed = groupIds.where((id) => !tabs.containsKey(id)).toList();
  if (untabbed.isNotEmpty) {
    var next = (tabs.values.isEmpty ? 0 : tabs.values.reduce((a, b) => a > b ? a : b)) + 1;
    for (final id in untabbed) {
      tabs[id] = next++;
    }
    warnings.add('${untabbed.length} groups without a tab position were added at the end.');
  }
  final displayOrder = groups.index('display_order');
  for (final row in groups.rows) {
    row[displayOrder] = tabs[_toId(row[groupId])];
  }
  final tabOrder = tabs.entries.toList()
    ..sort((a, b) => a.value != b.value ? a.value.compareTo(b.value) : a.key.compareTo(b.key));
  final orderedIds = tabOrder.map((e) => e.key).toList();

  final listed = <int, List<int>>{};
  if (_columnsOf(bak, 'groups').contains('profiles_json')) {
    for (final row in bak.query('SELECT id, profiles_json FROM groups')) {
      final raw = row['profiles_json'];
      if (raw is! String) continue;
      listed[_toId(row['id'])] = _jsonArrayIds(raw).whereType<int>().toList();
    }
  }

  final profiles = _stageTable(bak, main, 'profiles', '`id`', warnings,
      extra: const ['user_order']);
  final profileId = profiles.index('id');
  final gid = profiles.index('gid');
  var moved = 0;
  var dropped = 0;
  profiles.rows.removeWhere((row) {
    final current = row[gid];
    if (current != null && groupIds.contains(_toId(current))) return false;
    final id = _toId(row[profileId]);
    final target = orderedIds.cast<int?>().firstWhere(
          (candidate) => candidate != null && (listed[candidate] ?? const <int>[]).contains(id),
          orElse: () => orderedIds.isEmpty ? null : orderedIds.first,
        );
    if (target == null) {
      dropped++;
      return true;
    }
    row[gid] = target;
    moved++;
    return false;
  });
  if (moved > 0) warnings.add('$moved profiles whose group is missing were moved to another group.');
  if (dropped > 0) warnings.add('$dropped profiles without any group were skipped.');

  final members = <int, List<int>>{};
  for (final row in profiles.rows) {
    final group = _toId(row[gid]);
    (members[group] ??= <int>[]).add(_toId(row[profileId]));
  }
  final position = <int, int>{};
  var unlisted = 0;
  members.forEach((group, ids) {
    final own = ids.toSet();
    final ordered = <int>{};
    for (final id in (listed[group] ?? const <int>[])) {
      if (own.contains(id)) ordered.add(id);
    }
    final rest = ids.where((id) => !ordered.contains(id)).toList()..sort();
    unlisted += rest.length;
    ordered.addAll(rest);
    var index = 0;
    for (final id in ordered) {
      position[id] = index++;
    }
  });
  if (unlisted > 0) {
    warnings.add('$unlisted profiles missing from their group were added at its end.');
  }
  final userOrder = profiles.index('user_order');
  for (final row in profiles.rows) {
    row[userOrder] = position[_toId(row[profileId])];
  }
  staged.groups = groups;
  staged.profiles = profiles;
}

void _stageRoutes(
  BackupDatabase bak,
  BackupDatabase main,
  _Staged staged,
  List<String> warnings,
) {
  _require(bak, 'route_profiles');
  final profiles = _stageTable(bak, main, 'route_profiles', '`id`', warnings);
  final idIndex = profiles.index('id');
  final ids = <int>{};
  for (final row in profiles.rows) {
    ids.add(_toId(row[idIndex]));
  }
  final rules = _hasTable(bak, 'route_rules')
      ? _stageTable(bak, main, 'route_rules', '`route_profile_id`, `rule_order`', warnings)
      : _SqlTable(const <String>[]);
  final owner = rules.index('route_profile_id');
  final before = rules.rows.length;
  if (owner >= 0) {
    rules.rows.removeWhere((row) => !ids.contains(_toId(row[owner])));
  }
  if (rules.rows.length < before) {
    warnings.add('${before - rules.rows.length} rules of missing routing profiles were skipped.');
  }
  if (owner >= 0) {
    _skipUnsupportedRules(bak, main, rules, warnings);
    final order = rules.index('rule_order');
    final next = <Object?, int>{};
    for (final row in rules.rows) {
      final key = row[owner];
      final n = next[key] ?? 0;
      row[order] = n;
      next[key] = n + 1;
    }
  }
  final rawIndex = profiles.index('is_raw');
  if (rawIndex >= 0) {
    final raw = profiles.rows.where((row) => _isTrue(row[rawIndex])).length;
    if (raw > 0) {
      warnings.add('$raw raw routing profiles from Throne desktop are kept read-only; Android cannot use them.');
    }
  }
  staged.routeProfiles = profiles;
  staged.routeRules = rules;
}

void _skipUnsupportedRules(
  BackupDatabase bak,
  BackupDatabase main,
  _SqlTable rules,
  List<String> warnings,
) {
  final known = _columnsOf(main, 'route_rules').toSet();
  final unknown = _columnsOf(bak, 'route_rules').where((c) => !known.contains(c)).toList();
  if (unknown.isEmpty) return;
  final hasValue = unknown
      .map((column) => '(${_sqlName(column)} IS NOT NULL AND ${_sqlName(column)} NOT IN (\'\', \'[]\', 0, \'0\'))')
      .toList();
  final offenders = <({Object? owner, Object? order}), List<String>>{};
  final sql = 'SELECT `route_profile_id`, `rule_order`, ${hasValue.join(',')} '
      'FROM `route_rules` WHERE ${hasValue.join(' OR ')}';
  for (final row in bak.query(sql)) {
    final key = (owner: row['route_profile_id'], order: row['rule_order']);
    offenders[key] = <String>[
      for (var i = 0; i < unknown.length; i++)
        if (_toId(row.values.elementAt(i + 2)) != 0) unknown[i],
    ];
  }
  final owner = rules.index('route_profile_id');
  final order = rules.index('rule_order');
  final used = <String>{};
  final before = rules.rows.length;
  rules.rows.removeWhere((row) {
    final key = (owner: row[owner], order: row[order]);
    final columns = offenders[key];
    if (columns == null) return false;
    used.addAll(columns);
    return true;
  });
  final skipped = before - rules.rows.length;
  if (skipped > 0) {
    final fields = unknown.where((c) => used.contains(c)).join(', ');
    warnings.add('$skipped routing rules were skipped because they use fields this app does not support ($fields).');
  }
}

void _stageSettings(
  BackupDatabase bak,
  BackupDatabase main,
  _Staged staged,
  List<String> warnings,
) {
  _require(bak, 'settings');
  final rows = <String, String>{};
  var skipped = 0;
  for (final row in bak.query('SELECT key, value FROM settings')) {
    final key = row['key'];
    final value = row['value'];
    if (key == null || value == null) {
      skipped++;
      continue;
    }
    rows['$key'] = '$value';
  }
  if (skipped > 0) warnings.add('$skipped invalid rows of settings were skipped.');
  staged.settings = rows;
  staged.markers = _hasTable(bak, 'markers')
      ? _stageTable(bak, main, 'markers', '`key`', warnings)
      : null;
}

// -- commit -----------------------------------------------------------------

void _commit(
  _Staged staged,
  RestoreChoice choice,
  bool fromAndroid,
  BackupDatabase db,
  BackupEnvironment env,
  List<String> warnings,
) {
  // `PRAGMA defer_foreign_keys = ON`: the replacement happens in one transaction
  // and cross-table references are checked only at commit.
  final lanWasOn = _lanWasOn(db);
  db.execute('BEGIN IMMEDIATE');
  try {
    db.execute('PRAGMA defer_foreign_keys = ON');
    if (choice.profiles) {
      db.execute('DELETE FROM `profiles`');
      db.execute('DELETE FROM `groups`');
      _insertRows(db, 'groups', staged.groups!.columns, staged.groups!.rows);
      _insertRows(db, 'profiles', staged.profiles!.columns, staged.profiles!.rows);
    }
    if (choice.routes) {
      db.execute('DELETE FROM `route_rules`');
      db.execute('DELETE FROM `route_profiles`');
      _insertRows(db, 'route_profiles', staged.routeProfiles!.columns, staged.routeProfiles!.rows);
      _insertRows(db, 'route_rules', staged.routeRules!.columns, staged.routeRules!.rows);
    }
    if (choice.profiles != choice.routes) {
      db.execute('UPDATE `groups` SET `route_id` = -1');
      db.execute('UPDATE `route_profiles` SET `source_gid` = -1');
    }
    if (choice.profiles || choice.routes) {
      staged.counters.forEach((table, value) => _raiseSequence(db, table, value));
    }
    if (choice.settings) _applySettings(db, staged, fromAndroid);

    // Configs.cpp:32-44 initDB: an empty table gets a fresh Default row.
    if (choice.profiles &&
        (_longQuery(db, 'SELECT COUNT(*) FROM `groups`') ?? 0) == 0) {
      _insertDefaultGroup(db, env.defaultGroupName);
    }
    if (choice.routes &&
        (_longQuery(db, 'SELECT COUNT(*) FROM `route_profiles` WHERE `is_raw` = 0') ?? 0) == 0) {
      _insertDefaultRoute(db);
    }
    _fixSelection(db, choice, staged, fromAndroid, lanWasOn, warnings);

    final fk = db.query('PRAGMA foreign_key_check');
    if (fk.isNotEmpty) {
      throw BackupWriteException(
          'The restored ${fk.first.values.first} table refers to missing rows.');
    }
    db.execute('COMMIT');
  } on Object {
    db.execute('ROLLBACK');
    rethrow;
  }
}

void _insertDefaultGroup(BackupDatabase db, String name) {
  final maxOrder = _longQuery(db, 'SELECT COALESCE(MAX(`display_order`), 0) FROM `groups`') ?? 0;
  final nextId = (_longQuery(db, 'SELECT MAX(`id`) FROM `groups`') ?? 0) + 1;
  db.execute(
    'INSERT INTO `groups` (`id`, `name`, `display_order`) VALUES (?, ?, ?)',
    <Object?>[nextId, name, maxOrder + 1],
  );
}

void _insertDefaultRoute(BackupDatabase db) {
  final nextId = (_longQuery(db, 'SELECT MAX(`id`) FROM `route_profiles`') ?? 0) + 1;
  db.execute(
    'INSERT INTO `route_profiles` (`id`, `name`, `default_outbound_id`) VALUES (?, ?, -1)',
    <Object?>[nextId, 'Default'],
  );
  db.execute(
    'INSERT INTO `route_rules` (`route_profile_id`, `rule_order`, `name`, `protocol`, `action`) '
    'VALUES (?, 0, \'Route DNS\', \'dns\', \'hijack-dns\')',
    <Object?>[nextId],
  );
}

void _raiseSequence(BackupDatabase db, String table, int value) {
  if (value <= 0) return;
  final updated = db.execute(
      'UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = ?',
      <Object?>[value, table]);
  if (updated == 0) {
    db.execute('INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)',
        <Object?>[table, value]);
  }
}

bool _lanWasOn(BackupDatabase db) {
  final rows = db.query('SELECT `value` FROM `settings` WHERE `key` = ?',
      <Object?>[_inboundAddress]);
  if (rows.isEmpty) return false;
  final address = rows.first.values.first;
  return address is String && !_isLoopback(address);
}

bool _isLoopback(String address) {
  final a = address.trim().replaceAll(RegExp(r'^[\[]|[\]]$'), '');
  return a.isEmpty || a == 'localhost' || a == '::1' || a.startsWith('127.') || a == '0.0.0.0';
}

void _applySettings(
  BackupDatabase db,
  _Staged staged,
  bool fromAndroid,
) {
  final kept = <String>{
    ...backupDeviceLocalKeys,
    if (!fromAndroid) ...backupAndroidKeys,
  };
  if (kept.isNotEmpty) {
    db.execute(
      'DELETE FROM `settings` WHERE `key` NOT IN (${kept.map((_) => '?').join(',')})',
      kept.toList(),
    );
  } else {
    db.execute('DELETE FROM `settings`');
  }
  for (final entry in (staged.settings ?? const <String, String>{}).entries) {
    if (backupDeviceLocalKeys.contains(entry.key)) continue;
    final isAndroidOnly = backupAndroidKeys.contains(entry.key);
    if (!fromAndroid && isAndroidOnly) {
      db.execute('INSERT OR IGNORE INTO `settings` (`key`, `value`) VALUES (?, ?)',
          <Object?>[entry.key, entry.value]);
    } else {
      db.execute('INSERT OR REPLACE INTO `settings` (`key`, `value`) VALUES (?, ?)',
          <Object?>[entry.key, entry.value]);
    }
  }
  db.execute('DELETE FROM `markers`');
  if (staged.markers != null) {
    _insertRows(db, 'markers', staged.markers!.columns, staged.markers!.rows);
  }
}

String? _readSetting(BackupDatabase db, String key) {
  final rows = db.query('SELECT `value` FROM `settings` WHERE `key` = ?',
      <Object?>[key]);
  if (rows.isEmpty) return null;
  final value = rows.first.values.first;
  return value is String ? value : null;
}

void _writeSetting(BackupDatabase db, String key, String? value) {
  if (value == null) {
    db.execute('DELETE FROM `settings` WHERE `key` = ?', <Object?>[key]);
  } else {
    db.execute('INSERT OR REPLACE INTO `settings` (`key`, `value`) VALUES (?, ?)',
        <Object?>[key, value]);
  }
}

void _fixSelection(
  BackupDatabase db,
  RestoreChoice choice,
  _Staged staged,
  bool fromAndroid,
  bool lanWasOn,
  List<String> warnings,
) {
  List<int> ids(String sql) => db.query(sql).map((row) => _toId(row.values.first)).toList();

  if (choice.profiles || choice.settings) {
    final groups = ids('SELECT `id` FROM `groups` ORDER BY `display_order`, `id`');
    final current = _readSetting(db, _currentGroup);
    if (current == null || !groups.contains(int.tryParse(current.trim()))) {
      _writeSetting(db, _currentGroup,
          groups.isEmpty ? null : groups.first.toString());
    }
    final profiles = ids('SELECT `id` FROM `profiles`').toSet();
    if (choice.settings && choice.profiles && !fromAndroid) {
      final remember = int.tryParse((staged.settings?[_rememberId] ?? '').trim());
      if (remember != null && profiles.contains(remember)) {
        _writeSetting(db, _profileId, remember.toString());
        _writeSetting(db, _profileCurrent, remember.toString());
      }
    }
    for (final key in const [_profileId, _profileCurrent]) {
      final id = int.tryParse((_readSetting(db, key) ?? '').trim());
      if (id != null && id > 0 && !profiles.contains(id)) {
        _writeSetting(db, key, null);
      }
    }
  }

  if (choice.routes || choice.settings) {
    final usable = ids('SELECT `id` FROM `route_profiles` WHERE `is_raw` = 0 ORDER BY `id`');
    final current = _readSetting(db, _currentRouteId);
    if (current == null || !usable.contains(int.tryParse(current.trim()))) {
      _writeSetting(db, _currentRouteId,
          usable.isEmpty ? null : usable.first.toString());
    }
  }

  if (choice.settings && !lanWasOn) {
    final address = _readSetting(db, _inboundAddress);
    if (address != null && !_isLoopback(address)) {
      _writeSetting(db, _inboundAddress, _loopbackAddress);
      warnings.add('The backup lets other devices connect (inbound address $address); '
          'this was turned off. Turn it on again in the inbound settings if you need it.');
    }
  }
}

// ---------------------------------------------------------------------------
// Introspection used by tests (not part of the production surface).

/// Exported for parity tests: the desktop column list of a table.
List<String> backupDesktopColumns(String table) => _desktopColumnsFor(table);

/// Exported for parity tests: the DDL list.
List<String> get backupDesktopDdl => desktopDdl;
