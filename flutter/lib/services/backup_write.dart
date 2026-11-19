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
import 'room_snapshot_host.dart' show HostSqlHandle, RoomSnapshotHost;
import '../data/profile_store.dart'
    show GroupRow, ProfileRow, ProfilesDocument;
import 'backup_store.dart'
    show
        ThrnParts,
        thrnAndroidMeta,
        thrnDecode,
        thrnEncode,
        thrnPartsFromMeta,
        thrnTextDate;

/// Resolves this process's SQLite library. Production is [Sqlite.open].
///
/// Tests override it with `() => null` to simulate a stock Android device,
/// where the app cannot dlopen the platform library (`libsqlite3.so` is absent
/// from AOSP, `libsqlite.so` is not in public.libraries.txt) and the host path
/// must take over. Choosing the backend by "does this host have a loadable
/// library" rather than "which platform is this" is what keeps the desktop/CI
/// ffi path and the device host path testable on one machine.
Sqlite? Function() resolveBackupSqlite = Sqlite.open;

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
    this.profileDocument,
    this.applyRestoredProfiles,
    this.roomSnapshot,
    this.applyRoomSnapshot,
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

  /// ADR 0005: Dart is the sole writer of profiles/groups, so a backup MUST
  /// export the document, not Room's (now unwritten) tables. When supplied,
  /// [profileDocument] replaces the Room reads for those two tables; routes,
  /// settings and the counters still come from Room. Production injects the
  /// live `ProfileStore` document; tests inject a synthetic one.
  final Future<ProfilesDocument?> Function()? profileDocument;

  /// Called after a restore has committed the profiles/groups back to Room, so
  /// the Dart document can be rebuilt from them and the UI refreshed. The
  /// argument is the restored document; null when the backup had no profiles
  /// part. Production writes it via `ProfileStore.replaceAll`.
  final Future<void> Function(ProfilesDocument doc)? applyRestoredProfiles;

  /// P14/Android: reads Room's live tables through the host (the process that
  /// owns Room), in the same column shape the ffi path gets. Null on desktop/CI
  /// where `Sqlite.open()` works and the host has no Room. Arguments are the
  /// Dart-owned document rows, which win over Room's stale copies.
  final Future<Map<String, dynamic>?> Function(
    List<Map<String, Object?>>? profiles,
    List<Map<String, Object?>>? groups,
  )? roomSnapshot;

  /// P14/Android: commits staged rows back to Room in one host transaction and
  /// returns the committed profile/group rows for rebuilding the Dart document.
  final Future<Map<String, dynamic>> Function(Map<String, Object?> rows)?
      applyRoomSnapshot;

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
  BackupDatabase._(this._ffi, this._host, this._handle);

  /// Desktop/CI: a dart:ffi connection. Null on Android (no public libsqlite).
  final SqliteDatabase? _ffi;
  /// Android: the host that owns Room/SQLite, reached over MethodChannel.
  final RoomSnapshotHost? _host;
  /// Android: the opaque handle of the host-opened database.
  final HostSqlHandle? _handle;

  /// Opens [path]. Prefers dart:ffi (desktop/CI); on Android, where the app
  /// cannot dlopen SQLite, falls back to the host's own connection.
  ///
  /// [sqlite] lets tests inject a library from an explicit path; [host] lets
  /// the production caller / tests inject the MethodChannel backend. Callers
  /// that need the host must inject it — no global channel dependency here.
  static Future<BackupDatabase?> open(
    String path, {
    bool readOnly = true,
    Sqlite? sqlite,
    RoomSnapshotHost? host,
    bool room = false,
  }) async {
    final lib = sqlite ?? resolveBackupSqlite();
    if (lib != null) {
      final db = lib.openDatabase(path, readOnly: readOnly);
      if (db != null) return BackupDatabase._(db, null, null);
    }
    if (host == null) return null;
    final handle = room
        ? await host.openRoom(path, write: !readOnly)
        : await host.openSql(path, write: !readOnly);
    return BackupDatabase._(null, host, handle);
  }

  Future<List<SqlRow>> query(String sql, [List<Object?> params = const []]) async {
    final ffi = _ffi;
    if (ffi != null) return ffi.query(sql, params);
    return _host!.sqlQuery(_handle!, sql, params);
  }

  Future<int> execute(String sql, [List<Object?> params = const []]) async {
    final ffi = _ffi;
    if (ffi != null) return ffi.execute(sql, params);
    return _host!.sqlExec(_handle!, sql, params);
  }

  Future<void> close() async {
    final ffi = _ffi;
    if (ffi != null) {
      ffi.close();
      return;
    }
    await _host!.closeSql(_handle!);
  }
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

Future<List<String>> _columnsOf(BackupDatabase db, String table) async =>
    (await db.query('PRAGMA table_info(${_sqlName(table)})'))
        .map((row) => '${row['name']}')
        .toList();

Future<bool> _hasTable(BackupDatabase db, String table) async =>
    (await db.query(
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            <Object?>[table]))
        .isNotEmpty;

Future<int?> _longQuery(BackupDatabase db, String sql, [List<Object?> params = const []]) async {
  final rows = await db.query(sql, params);
  if (rows.isEmpty) return null;
  final value = rows.first.values.first;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

Future<void> _insertRows(
  BackupDatabase db,
  String table,
  List<String> columns,
  Iterable<List<Object?>> rows,
) async {
  if (rows.isEmpty) return;
  final sql = 'INSERT INTO ${_sqlName(table)} (${_quoted(columns)}) '
      'VALUES (${columns.map((_) => '?').join(',')})';
  for (final row in rows) {
    await db.execute(sql, row.toList());
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

/// Live Room tables as the host DAO read them (Android), keyed by table name.
/// The rows are the full column set of each Room table; Dart projects/sorts the
/// columns it needs, so no SQL is issued against Room from this side.
typedef RoomRows = Map<String, List<SqlRow>>;

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
  Future<BackupDatabase?> Function(String path, {bool readOnly, Sqlite? sqlite, RoomSnapshotHost? host, bool room})? open,
  RoomSnapshotHost? host,
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
  // Use the host only when dart:ffi genuinely cannot load SQLite (stock
  // Android). Desktop/CI always takes the ffi path even though a host is wired.
  final useHost = (sqlite ?? resolveBackupSqlite()) == null && host != null;
  final effectiveHost = useHost ? host : null;
  final source = await opener(env.databasePath, readOnly: true, sqlite: sqlite, host: effectiveHost, room: useHost);
  if (source == null) {
    throw const BackupWriteException('The local database cannot be opened');
  }
  final dir = await Directory.systemTemp.createTemp('thrn-export-');
  final snapshotPath = '${dir.path}/backup.db';
  BackupDatabase? target;
  try {
    target = await opener(snapshotPath, readOnly: false, sqlite: sqlite, host: effectiveHost);
    if (target == null) {
      throw const BackupWriteException('The backup database cannot be created');
    }
    // ADR 0005: profiles/groups come from the Dart document (the write
    // authority); Room's copies are stale. Routes/settings/counters still read
    // from Room. A missing document falls back to Room for pre-migration
    // installs, so an old device can still export its catalog.
    final profileDoc = await env.profileDocument?.call();
    RoomRows? roomRows;
    if (effectiveHost != null && env.roomSnapshot != null) {
      // Android: Room's owner reads the source tables through its DAOs. Dart is
      // still the only mapper/stager; ffi is deliberately not used here.
      final reply = await env.roomSnapshot!(
        profileDoc?.profiles.map((p) => p.toJson()).cast<Map<String, Object?>>().toList(),
        profileDoc?.groups.map((g) => g.toJson()).cast<Map<String, Object?>>().toList(),
      );
      if (reply == null) {
        throw const BackupWriteException('The host could not read Room for the backup');
      }
      roomRows = <String, List<SqlRow>>{};
      for (final entry in reply.entries) {
        if (entry.value is! List || entry.key == 'sequences') continue;
        final List<SqlRow> parsed = <SqlRow>[];
        for (final r in entry.value) {
          if (r is Map) parsed.add(Map<String, Object?>.from(r));
        }
        roomRows[entry.key] = parsed;
      }
    }
    final snapshot = await _snapshot(source, selection, profileDoc, env, roomRows);
    await _buildDatabase(target, snapshot, selection, env);
    await _verify(target, selection);
    final bytes = (effectiveHost != null)
        ? await effectiveHost.readBytes(snapshotPath)
        : File(snapshotPath).readAsBytesSync();
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
    final groups = await _profileNames(source, snapshot);
    return <String, Object?>{
      'format': 2,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'scope': scope,
      'profiles': groups,
      'thr': base64Encode(containerBytes),
      'ui': ui,
    };
  } finally {
    await target?.close();
    await source.close();
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // best-effort cleanup
    }
  }
}

Future<_SqlTable> _copyTable(
  BackupDatabase live,
  String table,
  String order,
  List<String> desktopColumns,
) async {
  final android = (await _columnsOf(live, table)).toSet();
  final columns = desktopColumns.where((c) => android.contains(c)).toList();
  final rows = <List<Object?>>[];
  for (final row in await live.query(
      'SELECT ${_quoted(columns)} FROM ${_sqlName(table)} ORDER BY $order')) {
    rows.add(columns.map((c) => row[c]).toList());
  }
  return _SqlTable(columns, rows);
}

/// A Dart [ProfileRow] as a desktop `profiles` row. Only the columns the
/// document carries are filled; `created_at`/`updated_at` are left null so the
/// DDL defaults apply (the Room export omits them the same way).
List<Object?> _profileDesktopRow(ProfileRow p) {
  final values = <String, Object?>{
    'id': p.id,
    'type': p.type,
    'name': p.name,
    'gid': p.gid,
    'latency': p.latency,
    'latency_at': p.latencyAt,
    'dl_speed': p.dlSpeed,
    'ul_speed': p.ulSpeed,
    'test_country': p.testCountry,
    'ip_out': p.ipOut,
    'outbound_json': p.outboundJson,
    'traffic_dl': p.rx,
    'traffic_up': p.tx,
  };
  return _desktopColumnsFor('profiles')
      .where((c) => c != 'created_at' && c != 'updated_at')
      .map((c) => values[c])
      .toList();
}

/// A Dart [GroupRow] as a desktop `groups` row. `profiles_json` (the desktop's
/// membership index) is derived from the document's profiles by the caller via
/// [_buildDatabase]; here it is left for that step to fill.
List<Object?> _groupDesktopRow(GroupRow g) {
  final values = <String, Object?>{
    'id': g.id,
    'archive': g.archive ? 1 : 0,
    'skip_auto_update': g.skipAutoUpdate ? 1 : 0,
    'name': g.name,
    'url': g.url,
    'info': g.info,
    'sub_last_update': g.subLastUpdate,
    'front_proxy_id': g.frontProxyId,
    'landing_proxy_id': g.landingProxyId,
    'column_width_json': g.columnWidthJson,
    'scroll_last_profile': g.scrollLastProfile,
    'auto_clear_unavailable': g.autoClearUnavailable ? 1 : 0,
    'test_sort_by': g.testSortBy,
    'traffic_sort_by': g.trafficSortBy,
    'test_items_to_show': g.testItemsToShow,
    'type_sort_by': g.typeSortBy,
    'sub_options_json': g.subOptionsJson,
    'sub_metadata_json': g.subMetadataJson,
    'sort_method': g.sortMethod,
    'sort_descending': g.sortDescending ? 1 : 0,
    'route_id': g.routeId,
    'import_sub_route': g.importSubRoute ? 1 : 0,
  };
  // `profiles_json` is filled by _buildDatabase (it appends the column), and
  // created_at/updated_at use their DDL defaults — naming them with an explicit
  // NULL would bypass those defaults. Leave all three out of the column list.
  return _desktopColumnsFor('groups')
      .where((c) => c != 'profiles_json' && c != 'created_at' && c != 'updated_at')
      .map((c) => values[c])
      .toList();
}

Future<_Snapshot> _snapshot(
  BackupDatabase live,
  BackupSelection selection,
  ProfilesDocument? profileDoc, [
  BackupEnvironment? env,
  RoomRows? roomRows,
]) async {
  final s = _Snapshot();
  final desktop = <String, List<String>>{
    for (final table in const ['profiles', 'groups', 'route_profiles', 'route_rules', 'settings', 'markers'])
      table: _desktopColumnsFor(table),
  };

  // Android: rows came from Room's DAO over the host channel. Desktop/CI: read
  // the same tables through dart:ffi. Both paths feed identical Dart mapping.
  Future<List<SqlRow>> tableRows(String table, String orderSql) async {
    final hostRows = roomRows?[table];
    if (hostRows != null) return hostRows;
    return live.query('SELECT * FROM ${_sqlName(table)} ORDER BY $orderSql');
  }

  // ADR 0005: when Dart's document is available it is the ONLY truth for the
  // profiles/groups tables. Build the tab/member/counter facts and the copied
  // rows from it instead of the stale Room tables.
  if (profileDoc != null) {
    final groups = List<GroupRow>.from(profileDoc.groups)
      ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder) == 0
          ? a.id.compareTo(b.id)
          : a.displayOrder.compareTo(b.displayOrder));
    for (final g in groups) {
      s.tabs.add(_Tab(g.id, g.displayOrder));
    }
    final orderedProfiles = List<ProfileRow>.from(profileDoc.profiles)
      ..sort((a, b) => a.gid.compareTo(b.gid) == 0
          ? (a.userOrder.compareTo(b.userOrder) == 0
              ? a.id.compareTo(b.id)
              : a.userOrder.compareTo(b.userOrder))
          : a.gid.compareTo(b.gid));
    for (final p in orderedProfiles) {
      (s.members[p.gid] ??= <int>[]).add(p.id);
    }
    final profileIds = orderedProfiles.map((p) => p.id).toList();
    final groupIds = groups.map((g) => g.id).toList();
    s.counters['profiles'] = profileIds.isEmpty ? 0 : profileIds.reduce((a, b) => a > b ? a : b);
    s.counters['groups'] = groupIds.isEmpty ? 0 : groupIds.reduce((a, b) => a > b ? a : b);
    if (selection.profiles) {
      // Emit the exact desktop column names; columns the desktop DDL has but the
      // document does not carry (created_at/updated_at) fall back to the
      // database defaults, matching the Room path's derived-column omission.
      s.profiles = _SqlTable(
        desktop['profiles']!.where((c) => c != 'created_at' && c != 'updated_at').toList(),
        orderedProfiles.map(_profileDesktopRow).toList(),
      );
      // profiles_json is derived in _buildDatabase (appended to this list), so
      // keep it out of the copied columns to avoid naming it twice.
      s.groups = _SqlTable(
        desktop['groups']!
            .where((c) => c != 'profiles_json' && c != 'created_at' && c != 'updated_at')
            .toList(),
        groups.map(_groupDesktopRow).toList(),
      );
    }
  } else {
    final groups = await tableRows('groups', '`display_order`, `id`');
    final orderedGroups = List<SqlRow>.from(groups)
      ..sort((a, b) {
        final c = _toId(a['display_order']).compareTo(_toId(b['display_order']));
        return c != 0 ? c : _toId(a['id']).compareTo(_toId(b['id']));
      });
    for (final row in orderedGroups) {
      s.tabs.add(_Tab(_toId(row['id']), _toId(row['display_order'])));
    }
    final profiles = await tableRows('profiles', '`gid`, `user_order`, `id`');
    final orderedProfiles = List<SqlRow>.from(profiles)
      ..sort((a, b) {
        final c = _toId(a['gid']).compareTo(_toId(b['gid']));
        if (c != 0) return c;
        final u = _toId(a['user_order']).compareTo(_toId(b['user_order']));
        return u != 0 ? u : _toId(a['id']).compareTo(_toId(b['id']));
      });
    for (final row in orderedProfiles) {
      final gid = _toId(row['gid']);
      (s.members[gid] ??= <int>[]).add(_toId(row['id']));
    }
  }
  final routes = <({int id, bool raw})>[];
  final routeRows = await tableRows('route_profiles', '`id`');
  final orderedRoutes = List<SqlRow>.from(routeRows)
    ..sort((a, b) => _toId(a['id']).compareTo(_toId(b['id'])));
  for (final row in orderedRoutes) {
    routes.add((id: _toId(row['id']), raw: _isTrue(row['is_raw'])));
  }
  final sequences = <String, int>{};
  if (roomRows != null) {
    // The host derives sequences from AUTOINCREMENT high-water ids (DAO reads);
    // Dart folds max(id) below regardless, so this is only an optional floor.
  } else {
    try {
      for (final row in await live.query('SELECT `name`, `seq` FROM `sqlite_sequence`')) {
        sequences['${row['name']}'] = _toId(row['seq']);
      }
    } on Object {
      // sqlite_sequence is absent on a fresh database.
    }
  }
  final profileIds = s.members.values.expand((ids) => ids).toList();
  final groupIds = s.tabs.map((t) => t.id).toList();
  // When the Dart document supplied the rows it also supplied the counters
  // (next*Id); fold the stale Room sequence in only as a lower bound so a
  // restored/high-water id can never be reused.
  s.counters['profiles'] = [
    s.counters['profiles'] ?? 0,
    sequences['profiles'] ?? 0,
    if (profileIds.isNotEmpty) profileIds.reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);
  s.counters['groups'] = [
    s.counters['groups'] ?? 0,
    sequences['groups'] ?? 0,
    if (groupIds.isNotEmpty) groupIds.reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);
  s.counters['route_profiles'] = [
    sequences['route_profiles'] ?? 0,
    if (routes.isNotEmpty) routes.map((r) => r.id).reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);

  Future<_SqlTable> copy(String table, String order, List<String> columns) async {
    if (roomRows?[table] != null) {
      final rows = roomRows![table]!;
      // The host reads full column sets via DAO/SELECT *. With rows present,
      // use their keys; for an empty table use the full desktop column list so
      // derived rows (e.g. the markers IPv6 flag) still have a valid shape.
      final cols = rows.isEmpty
          ? List<String>.from(columns)
          : columns.where((c) => rows.any((r) => r.containsKey(c))).toList();
      final ordered = List<SqlRow>.from(rows);
      if (table == 'groups') {
        ordered.sort((a, b) {
          final c = _toId(a['display_order']).compareTo(_toId(b['display_order']));
          return c != 0 ? c : _toId(a['id']).compareTo(_toId(b['id']));
        });
      } else if (table == 'route_rules') {
        ordered.sort((a, b) {
          final c = _toId(a['route_profile_id']).compareTo(_toId(b['route_profile_id']));
          return c != 0 ? c : _toId(a['rule_order']).compareTo(_toId(b['rule_order']));
        });
      } else {
        ordered.sort((a, b) => _toId(a['id']).compareTo(_toId(b['id'])));
      }
      return _SqlTable(cols, ordered.map((r) => cols.map((c) => r[c]).toList()).toList());
    }
    return _copyTable(live, table, order, columns);
  }

  if (selection.profiles && profileDoc == null) {
    s.profiles = await copy('profiles', '`id`', desktop['profiles']!);
    s.groups = await copy('groups', '`display_order`, `id`', desktop['groups']!);
  }
  if (selection.routes) {
    s.routeProfiles = await copy('route_profiles', '`id`', desktop['route_profiles']!);
    s.routeRules = await copy('route_rules', '`route_profile_id`, `rule_order`', desktop['route_rules']!);
  }
  if (selection.settings) {
    final stored = <String, String>{};
    final settingsRows = roomRows?['settings'];
    if (settingsRows != null) {
      for (final row in settingsRows) {
        final key = row['key'];
        final value = row['value'];
        if (key is String && value is String) stored[key] = value;
      }
    } else {
      for (final row in await live.query('SELECT `key`, `value` FROM `settings` ORDER BY `key`')) {
        final key = row['key'];
        final value = row['value'];
        if (key is String && value is String) stored[key] = value;
      }
    }
    s.settings = _exportedSettings(stored, groupIds, profileIds.toSet(), routes);
    s.markers = await copy('markers', '`key`', desktop['markers']!);
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

Future<void> _buildDatabase(
  BackupDatabase db,
  _Snapshot s,
  BackupSelection selection,
  BackupEnvironment env,
) async {
  for (final sql in desktopDdl) {
    await db.execute(sql);
  }
  await db.execute(
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
    await _insertRows(db, 'groups', columns, rows);
    await _insertRows(
      db,
      'groups_order',
      const ['group_id', 'display_order'],
      s.tabs.map((tab) => <Object?>[tab.id, tab.order]),
    );
  }
  if (s.profiles != null) {
    await _insertRows(db, 'profiles', s.profiles!.columns, s.profiles!.rows);
  }
  if (s.routeProfiles != null) {
    await _insertRows(db, 'route_profiles', s.routeProfiles!.columns, s.routeProfiles!.rows);
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
    await _insertRows(db, 'route_rules', rules.columns, rules.rows);
  }
  if (selection.settings) {
    await _insertRows(
      db,
      'settings',
      const ['key', 'value'],
      (s.settings ?? const <String, String>{})
          .entries
          .map((e) => <Object?>[e.key, e.value]),
    );
    if (s.markers != null) {
      await _insertRows(db, 'markers', s.markers!.columns, s.markers!.rows);
    }
  }
}

Future<void> _verify(BackupDatabase db, BackupSelection selection) async {
  Future<void> zero(String what, String sql) async {
    final n = await _longQuery(db, sql) ?? 0;
    if (n != 0) throw BackupWriteException('backup check failed: $what ($n)');
  }

  if (selection.profiles) {
    await zero(
        'groups without one tab',
        'SELECT COUNT(*) FROM groups g WHERE (SELECT COUNT(*) FROM groups_order o WHERE o.group_id = g.id) != 1');
    await zero('tabs without a group',
        'SELECT COUNT(*) FROM groups_order o WHERE NOT EXISTS (SELECT 1 FROM groups g WHERE g.id = o.group_id)');
    await zero('profiles without a group',
        'SELECT COUNT(*) FROM profiles p WHERE NOT EXISTS (SELECT 1 FROM groups g WHERE g.id = p.gid)');
    final members = <int, Set<int>>{};
    for (final row in await db.query('SELECT gid, id FROM profiles')) {
      (members[_toId(row['gid'])] ??= <int>{}).add(_toId(row['id']));
    }
    for (final row in await db.query('SELECT id, profiles_json FROM groups')) {
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
    await zero('rules without a routing profile',
        'SELECT COUNT(*) FROM route_rules r WHERE NOT EXISTS (SELECT 1 FROM route_profiles p WHERE p.id = r.route_profile_id)');
    await zero(
        'rule order',
        'SELECT COUNT(*) FROM (SELECT COUNT(*) AS n, MIN(rule_order) AS lo, MAX(rule_order) AS hi '
        'FROM route_rules GROUP BY route_profile_id) WHERE lo != 0 OR hi != n - 1');
    if (selection.settings &&
        (await _longQuery(db, 'SELECT COUNT(*) FROM route_profiles') ?? 0) > 0) {
      await zero(
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
Future<List<Map<String, Object?>>> _profileNames(BackupDatabase db, [_Snapshot? snapshot]) async {
  // ADR 0005: derive the preview from the Dart-backed snapshot when profiles
  // were exported from the document (Room's tables are stale by then).
  if (snapshot != null && snapshot.groups != null) {
    final counts = <int, int>{};
    for (final row in snapshot.profiles?.rows ?? const <List<Object?>>[]) {
      final gidIndex = snapshot.profiles!.index('gid');
      final gid = _toId(row[gidIndex]);
      counts[gid] = (counts[gid] ?? 0) + 1;
    }
    final g = snapshot.groups!;
    final idIndex = g.index('id');
    final nameIndex = g.index('name');
    final urlIndex = g.index('url');
    final out = <Map<String, Object?>>[];
    // Tab order lives in the snapshot's `tabs` (the desktop groups_order table),
    // not in the groups row — sort by it before emitting the preview.
    final orderById = <int, int>{for (final tab in snapshot.tabs) tab.id: tab.order};
    final byOrder = g.rows.toList()
      ..sort((a, b) {
        final c = (orderById[_toId(a[idIndex])] ?? 0).compareTo(orderById[_toId(b[idIndex])] ?? 0);
        return c != 0 ? c : _toId(a[idIndex]).compareTo(_toId(b[idIndex]));
      });
    for (final row in byOrder) {
      final id = _toId(row[idIndex]);
      final url = (row[urlIndex] as String?) ?? '';
      out.add(<String, Object?>{
        'name': row[nameIndex] ?? '',
        'type': url.isEmpty ? 'local' : 'subscription',
        'url': url,
        'nodes': counts[id] ?? 0,
      });
    }
    return out;
  }
  if (!await _hasTable(db, 'groups')) return const <Map<String, Object?>>[];
  final counts = <int, int>{};
  if (await _hasTable(db, 'profiles')) {
    for (final row in await db.query('SELECT gid, COUNT(*) AS n FROM profiles GROUP BY gid')) {
      counts[_toId(row['gid'])] = _toId(row['n']);
    }
  }
  final out = <Map<String, Object?>>[];
  for (final row in await db.query('SELECT id, name, url FROM groups ORDER BY display_order, id')) {
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

Future<List<_ColumnInfo>> _columnsInfo(BackupDatabase db, String table) async =>
    (await db.query('PRAGMA table_info(${_sqlName(table)})'))
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
  Future<BackupDatabase?> Function(String path, {bool readOnly, Sqlite? sqlite, RoomSnapshotHost? host, bool room})? open,
  RoomSnapshotHost? host,
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
  final useHost = (sqlite ?? resolveBackupSqlite()) == null && host != null;
  final effectiveHost = useHost ? host : null;
  final dir = await Directory.systemTemp.createTemp('thrn-restore-');
  final stagedPath = '${dir.path}/restore.db';
  if (effectiveHost != null) {
    await effectiveHost.writeBytes(stagedPath, embedded);
  } else {
    File(stagedPath).writeAsBytesSync(embedded);
  }
  BackupDatabase? bak;
  BackupDatabase? main;
  final warnings = <String>[];
  try {
    bak = await opener(stagedPath, readOnly: false, sqlite: sqlite, host: effectiveHost);
    main = await opener(env.databasePath, readOnly: false, sqlite: sqlite, host: effectiveHost, room: effectiveHost != null);
    if (bak == null || main == null) {
      throw const BackupWriteException('The backup database cannot be opened');
    }
    final staged = await _stage(bak, main, choice, warnings);
    if (effectiveHost != null && env.applyRoomSnapshot != null) {
      // Android: Room's owner commits the staged rows in one transaction and
      // returns the committed profile/group rows for the Dart document.
      final reply = await env.applyRoomSnapshot!(_hostRestoreArgs(
        staged, choice, container.isAndroid, env,));

      // ADR 0005: Dart is still the only writer of profiles.json. Rebuild the
      // document from the rows the host actually committed, then apply UI docs
      // and refresh — in that order, so no screen sees half a state.
      if (choice.profiles && env.applyRestoredProfiles != null) {
        final committed = _rowsFromHost(reply, 'profiles');
        final committedGroups = _rowsFromHost(reply, 'groups');
        await env.applyRestoredProfiles!(
          _documentFromRows(committed, committedGroups, staged),
        );
      }
    } else {
      await _commit(staged, choice, container.isAndroid, main, env, warnings);
      if (choice.profiles && env.applyRestoredProfiles != null) {
        await env.applyRestoredProfiles!(await _documentFromRoom(main, staged));
      }
    }

    final ui = container.flroneUi;
    if (scope == 'all' && applyUi != null) {
      await applyUi(ui);
    }
    refresh?.call();
    return RestoreResult(List<String>.unmodifiable(warnings), ui);
  } finally {
    await bak?.close();
    await main?.close();
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // best-effort cleanup
    }
  }
}

Future<_Staged> _stage(
  BackupDatabase bak,
  BackupDatabase main,
  RestoreChoice choice,
  List<String> warnings,
) async {
  final staged = _Staged();
  if (choice.profiles) await _stageProfiles(bak, main, staged, warnings);
  if (choice.routes) await _stageRoutes(bak, main, staged, warnings);
  if (choice.settings) await _stageSettings(bak, main, staged, warnings);
  if ((choice.profiles || choice.routes) && await _hasTable(bak, 'entity_ids')) {
    final columns = (await _columnsOf(bak, 'entity_ids')).toSet();
    const counterColumns = <MapEntry<String, String>>{
      MapEntry('profiles', 'profile_last_id'),
      MapEntry('groups', 'group_last_id'),
      MapEntry('route_profiles', 'route_profile_last_id'),
    };
    for (final entry in counterColumns) {
      if (!columns.contains(entry.value)) continue;
      final value = await _longQuery(
          bak, 'SELECT MAX(${_sqlName(entry.value)}) FROM `entity_ids`');
      if (value != null) staged.counters[entry.key] = value;
    }
  }
  return staged;
}

Future<void> _require(BackupDatabase bak, String table) async {
  if (!await _hasTable(bak, table)) {
    throw BackupWriteException('The backup has no $table table.');
  }
}

/// copyTable (Database.cpp:296-313): shared columns by name, defaults for
/// NOT NULL columns, extra columns appended, rows that still miss a value skipped.
Future<_SqlTable> _stageTable(
  BackupDatabase bak,
  BackupDatabase main,
  String table,
  String order,
  List<String> warnings, {
  List<String> extra = const <String>[],
}) async {
  final mainColumns = await _columnsInfo(main, table);
  final bakColumns = (await _columnsOf(bak, table)).toSet();
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
  final defaults = <Object?>[];
  for (final column in shared) {
    if (!column.notNull || column.defaultSql == null) {
      defaults.add(null);
      continue;
    }
    final rows = await bak.query('SELECT ${column.defaultSql}');
    defaults.add(rows.isEmpty ? null : rows.first.values.first);
  }
  final out = _SqlTable([...shared.map((c) => c.name), ...extra]);
  var skipped = 0;
  for (final row in await bak.query(
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

Future<void> _stageProfiles(
  BackupDatabase bak,
  BackupDatabase main,
  _Staged staged,
  List<String> warnings,
) async {
  await _require(bak, 'groups');
  await _require(bak, 'profiles');
  final groups = await _stageTable(bak, main, 'groups', '`id`', warnings,
      extra: const ['display_order']);
  final groupId = groups.index('id');
  final groupIds = <int>{};
  for (final row in groups.rows) {
    groupIds.add(_toId(row[groupId]));
  }

  final tabs = <int, int>{};
  var orphanTabs = 0;
  if (await _hasTable(bak, 'groups_order')) {
    for (final row in await bak.query(
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
  if ((await _columnsOf(bak, 'groups')).contains('profiles_json')) {
    for (final row in await bak.query('SELECT id, profiles_json FROM groups')) {
      final raw = row['profiles_json'];
      if (raw is! String) continue;
      listed[_toId(row['id'])] = _jsonArrayIds(raw).whereType<int>().toList();
    }
  }

  final profiles = await _stageTable(bak, main, 'profiles', '`id`', warnings,
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

Future<void> _stageRoutes(
  BackupDatabase bak,
  BackupDatabase main,
  _Staged staged,
  List<String> warnings,
) async {
  await _require(bak, 'route_profiles');
  final profiles = await _stageTable(bak, main, 'route_profiles', '`id`', warnings);
  final idIndex = profiles.index('id');
  final ids = <int>{};
  for (final row in profiles.rows) {
    ids.add(_toId(row[idIndex]));
  }
  final rules = await _hasTable(bak, 'route_rules')
      ? await _stageTable(bak, main, 'route_rules', '`route_profile_id`, `rule_order`', warnings)
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
    await _skipUnsupportedRules(bak, main, rules, warnings);
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

Future<void> _skipUnsupportedRules(
  BackupDatabase bak,
  BackupDatabase main,
  _SqlTable rules,
  List<String> warnings,
) async {
  final known = (await _columnsOf(main, 'route_rules')).toSet();
  final unknown = (await _columnsOf(bak, 'route_rules')).where((c) => !known.contains(c)).toList();
  if (unknown.isEmpty) return;
  final hasValue = unknown
      .map((column) => '(${_sqlName(column)} IS NOT NULL AND ${_sqlName(column)} NOT IN (\'\', \'[]\', 0, \'0\'))')
      .toList();
  final offenders = <({Object? owner, Object? order}), List<String>>{};
  final sql = 'SELECT `route_profile_id`, `rule_order`, ${hasValue.join(',')} '
      'FROM `route_rules` WHERE ${hasValue.join(' OR ')}';
  for (final row in await bak.query(sql)) {
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

Future<void> _stageSettings(
  BackupDatabase bak,
  BackupDatabase main,
  _Staged staged,
  List<String> warnings,
) async {
  await _require(bak, 'settings');
  final rows = <String, String>{};
  var skipped = 0;
  for (final row in await bak.query('SELECT key, value FROM settings')) {
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
  staged.markers = await _hasTable(bak, 'markers')
      ? await _stageTable(bak, main, 'markers', '`key`', warnings)
      : null;
}

// -- commit -----------------------------------------------------------------

Future<void> _commit(
  _Staged staged,
  RestoreChoice choice,
  bool fromAndroid,
  BackupDatabase db,
  BackupEnvironment env,
  List<String> warnings,
) async {
  // `PRAGMA defer_foreign_keys = ON`: the replacement happens in one transaction
  // and cross-table references are checked only at commit.
  final lanWasOn = await _lanWasOn(db);
  await db.execute('BEGIN IMMEDIATE');
  try {
    await db.execute('PRAGMA defer_foreign_keys = ON');
    if (choice.profiles) {
      await db.execute('DELETE FROM `profiles`');
      await db.execute('DELETE FROM `groups`');
      await _insertRows(db, 'groups', staged.groups!.columns, staged.groups!.rows);
      await _insertRows(db, 'profiles', staged.profiles!.columns, staged.profiles!.rows);
    }
    if (choice.routes) {
      await db.execute('DELETE FROM `route_rules`');
      await db.execute('DELETE FROM `route_profiles`');
      await _insertRows(db, 'route_profiles', staged.routeProfiles!.columns, staged.routeProfiles!.rows);
      await _insertRows(db, 'route_rules', staged.routeRules!.columns, staged.routeRules!.rows);
    }
    if (choice.profiles != choice.routes) {
      await db.execute('UPDATE `groups` SET `route_id` = -1');
      await db.execute('UPDATE `route_profiles` SET `source_gid` = -1');
    }
    if (choice.profiles || choice.routes) {
      for (final entry in staged.counters.entries) {
        await _raiseSequence(db, entry.key, entry.value);
      }
    }
    if (choice.settings) await _applySettings(db, staged, fromAndroid);

    // Configs.cpp:32-44 initDB: an empty table gets a fresh Default row.
    if (choice.profiles &&
        (await _longQuery(db, 'SELECT COUNT(*) FROM `groups`') ?? 0) == 0) {
      await _insertDefaultGroup(db, env.defaultGroupName);
    }
    if (choice.routes &&
        (await _longQuery(db, 'SELECT COUNT(*) FROM `route_profiles` WHERE `is_raw` = 0') ?? 0) == 0) {
      await _insertDefaultRoute(db);
    }
    await _fixSelection(db, choice, staged, fromAndroid, lanWasOn, warnings);

    final fk = await db.query('PRAGMA foreign_key_check');
    if (fk.isNotEmpty) {
      throw BackupWriteException(
          'The restored ${fk.first.values.first} table refers to missing rows.');
    }
    await db.execute('COMMIT');
  } on Object {
    await db.execute('ROLLBACK');
    rethrow;
  }
}

/// Builds the Dart-owned document from the profiles/groups rows committed to
/// Room by a restore. Reads only columns the document schema carries, so the
/// result round-trips through [ProfilesDocument.toJson] unchanged.
Future<ProfilesDocument> _documentFromRoom(BackupDatabase db, _Staged staged) async {
  Future<List<SqlRow>> rows(String table) async {
    if (!await _hasTable(db, table)) return const <SqlRow>[];
    return db.query('SELECT * FROM $table ORDER BY `id`');
  }

  final profiles = <ProfileRow>[];
  for (final row in await rows('profiles')) {
    profiles.add(ProfileRow(
      id: _toId(row['id']),
      type: '${row['type'] ?? ''}',
      name: row['name'] as String?,
      gid: _toId(row['gid']),
      userOrder: _toId(row['user_order']),
      latency: _toId(row['latency']),
      latencyAt: _toId(row['latency_at']),
      dlSpeed: row['dl_speed'] as String?,
      ulSpeed: row['ul_speed'] as String?,
      testCountry: row['test_country'] as String?,
      ipOut: row['ip_out'] as String?,
      outboundJson: '${row['outbound_json'] ?? ''}',
      rx: _toId(row['traffic_dl']),
      tx: _toId(row['traffic_up']),
      testError: row['test_error'] as String?,
    ));
  }
  final groups = <GroupRow>[];
  for (final row in await rows('groups')) {
    groups.add(GroupRow(
      id: _toId(row['id']),
      archive: _isTrue(row['archive']),
      skipAutoUpdate: _isTrue(row['skip_auto_update']),
      name: '${row['name'] ?? ''}',
      url: '${row['url'] ?? ''}',
      info: '${row['info'] ?? ''}',
      subLastUpdate: _toId(row['sub_last_update']),
      frontProxyId: row['front_proxy_id'] == null ? -1 : _toId(row['front_proxy_id']),
      landingProxyId: row['landing_proxy_id'] == null ? -1 : _toId(row['landing_proxy_id']),
      columnWidthJson: '${row['column_width_json'] ?? ''}',
      scrollLastProfile: row['scroll_last_profile'] == null ? -1 : _toId(row['scroll_last_profile']),
      autoClearUnavailable: _isTrue(row['auto_clear_unavailable']),
      testSortBy: _toId(row['test_sort_by']),
      trafficSortBy: _toId(row['traffic_sort_by']),
      testItemsToShow: _toId(row['test_items_to_show']),
      typeSortBy: _toId(row['type_sort_by']),
      subOptionsJson: '${row['sub_options_json'] ?? '{}'}',
      subMetadataJson: '${row['sub_metadata_json'] ?? '{}'}',
      sortMethod: _toId(row['sort_method']),
      sortDescending: _isTrue(row['sort_descending']),
      displayOrder: _toId(row['display_order']),
      routeId: row['route_id'] == null ? -1 : _toId(row['route_id']),
      importSubRoute: _isTrue(row['import_sub_route']),
    ));
  }
  final nextP = [
    staged.counters['profiles'] ?? 0,
    if (profiles.isNotEmpty) profiles.map((p) => p.id).reduce((a, b) => a > b ? a : b) + 1,
  ].reduce((a, b) => a > b ? a : b);
  final nextG = [
    staged.counters['groups'] ?? 0,
    if (groups.isNotEmpty) groups.map((g) => g.id).reduce((a, b) => a > b ? a : b) + 1,
  ].reduce((a, b) => a > b ? a : b);
  return ProfilesDocument(
    nextProfileId: nextP,
    nextGroupId: nextG,
    profiles: profiles,
    groups: groups,
  );
}

Future<void> _insertDefaultGroup(BackupDatabase db, String name) async {
  final maxOrder = await _longQuery(db, 'SELECT COALESCE(MAX(`display_order`), 0) FROM `groups`') ?? 0;
  final nextId = (await _longQuery(db, 'SELECT MAX(`id`) FROM `groups`') ?? 0) + 1;
  await db.execute(
    'INSERT INTO `groups` (`id`, `name`, `display_order`) VALUES (?, ?, ?)',
    <Object?>[nextId, name, maxOrder + 1],
  );
}

Future<void> _insertDefaultRoute(BackupDatabase db) async {
  final nextId = (await _longQuery(db, 'SELECT MAX(`id`) FROM `route_profiles`') ?? 0) + 1;
  await db.execute(
    'INSERT INTO `route_profiles` (`id`, `name`, `default_outbound_id`) VALUES (?, ?, -1)',
    <Object?>[nextId, 'Default'],
  );
  await db.execute(
    'INSERT INTO `route_rules` (`route_profile_id`, `rule_order`, `name`, `protocol`, `action`) '
    'VALUES (?, 0, \'Route DNS\', \'dns\', \'hijack-dns\')',
    <Object?>[nextId],
  );
}

Future<void> _raiseSequence(BackupDatabase db, String table, int value) async {
  if (value <= 0) return;
  final updated = await db.execute(
      'UPDATE sqlite_sequence SET seq = MAX(seq, ?) WHERE name = ?',
      <Object?>[value, table]);
  if (updated == 0) {
    await db.execute('INSERT INTO sqlite_sequence (name, seq) VALUES (?, ?)',
        <Object?>[table, value]);
  }
}

Future<bool> _lanWasOn(BackupDatabase db) async {
  final rows = await db.query('SELECT `value` FROM `settings` WHERE `key` = ?',
      <Object?>[_inboundAddress]);
  if (rows.isEmpty) return false;
  final address = rows.first.values.first;
  return address is String && !_isLoopback(address);
}

bool _isLoopback(String address) {
  final a = address.trim().replaceAll(RegExp(r'^[\[]|[\]]$'), '');
  return a.isEmpty || a == 'localhost' || a == '::1' || a.startsWith('127.') || a == '0.0.0.0';
}

Future<void> _applySettings(
  BackupDatabase db,
  _Staged staged,
  bool fromAndroid,
) async {
  final kept = <String>{
    ...backupDeviceLocalKeys,
    if (!fromAndroid) ...backupAndroidKeys,
  };
  if (kept.isNotEmpty) {
    await db.execute(
      'DELETE FROM `settings` WHERE `key` NOT IN (${kept.map((_) => '?').join(',')})',
      kept.toList(),
    );
  } else {
    await db.execute('DELETE FROM `settings`');
  }
  for (final entry in (staged.settings ?? const <String, String>{}).entries) {
    if (backupDeviceLocalKeys.contains(entry.key)) continue;
    final isAndroidOnly = backupAndroidKeys.contains(entry.key);
    if (!fromAndroid && isAndroidOnly) {
      await db.execute('INSERT OR IGNORE INTO `settings` (`key`, `value`) VALUES (?, ?)',
          <Object?>[entry.key, entry.value]);
    } else {
      await db.execute('INSERT OR REPLACE INTO `settings` (`key`, `value`) VALUES (?, ?)',
          <Object?>[entry.key, entry.value]);
    }
  }
  await db.execute('DELETE FROM `markers`');
  if (staged.markers != null) {
    await _insertRows(db, 'markers', staged.markers!.columns, staged.markers!.rows);
  }
}

Future<String?> _readSetting(BackupDatabase db, String key) async {
  final rows = await db.query('SELECT `value` FROM `settings` WHERE `key` = ?',
      <Object?>[key]);
  if (rows.isEmpty) return null;
  final value = rows.first.values.first;
  return value is String ? value : null;
}

Future<void> _writeSetting(BackupDatabase db, String key, String? value) async {
  if (value == null) {
    await db.execute('DELETE FROM `settings` WHERE `key` = ?', <Object?>[key]);
  } else {
    await db.execute('INSERT OR REPLACE INTO `settings` (`key`, `value`) VALUES (?, ?)',
        <Object?>[key, value]);
  }
}

Future<void> _fixSelection(
  BackupDatabase db,
  RestoreChoice choice,
  _Staged staged,
  bool fromAndroid,
  bool lanWasOn,
  List<String> warnings,
) async {
  Future<List<int>> ids(String sql) async =>
      (await db.query(sql)).map((row) => _toId(row.values.first)).toList();

  if (choice.profiles || choice.settings) {
    final groups = await ids('SELECT `id` FROM `groups` ORDER BY `display_order`, `id`');
    final current = await _readSetting(db, _currentGroup);
    if (current == null || !groups.contains(int.tryParse(current.trim()))) {
      await _writeSetting(db, _currentGroup,
          groups.isEmpty ? null : groups.first.toString());
    }
    final profiles = (await ids('SELECT `id` FROM `profiles`')).toSet();
    if (choice.settings && choice.profiles && !fromAndroid) {
      final remember = int.tryParse((staged.settings?[_rememberId] ?? '').trim());
      if (remember != null && profiles.contains(remember)) {
        await _writeSetting(db, _profileId, remember.toString());
        await _writeSetting(db, _profileCurrent, remember.toString());
      }
    }
    for (final key in const [_profileId, _profileCurrent]) {
      final id = int.tryParse(((await _readSetting(db, key)) ?? '').trim());
      if (id != null && id > 0 && !profiles.contains(id)) {
        await _writeSetting(db, key, null);
      }
    }
  }

  if (choice.routes || choice.settings) {
    final usable = await ids('SELECT `id` FROM `route_profiles` WHERE `is_raw` = 0 ORDER BY `id`');
    final current = await _readSetting(db, _currentRouteId);
    if (current == null || !usable.contains(int.tryParse(current.trim()))) {
      await _writeSetting(db, _currentRouteId,
          usable.isEmpty ? null : usable.first.toString());
    }
  }

  if (choice.settings && !lanWasOn) {
    final address = await _readSetting(db, _inboundAddress);
    if (address != null && !_isLoopback(address)) {
      await _writeSetting(db, _inboundAddress, _loopbackAddress);
      warnings.add('The backup lets other devices connect (inbound address $address); '
          'this was turned off. Turn it on again in the inbound settings if you need it.');
    }
  }
}

// ---------------------------------------------------------------------------
// Android host restore bridge (P14).

/// Builds the argument map for `data.applyRoomSnapshot` from the Dart-staged
/// rows. Every table is sent column-keyed; the host writes only through Room
/// DAO methods (profiles/groups/routes/settings/markers) plus the same
/// parameterized SQL for counters/selection that this file uses on desktop.
Map<String, Object?> _hostRestoreArgs(
  _Staged staged,
  RestoreChoice choice,
  bool fromAndroid,
  BackupEnvironment env,
) {
  Map<String, Object?> table(_SqlTable? t) {
    if (t == null) return <String, Object?>{};
    return <String, Object?>{
      'columns': t.columns,
      'rows': t.rows.map((r) => r.toList()).toList(),
    };
  }
  return <String, Object?>{
    'profiles': table(staged.profiles),
    'groups': table(staged.groups),
    'routeProfiles': table(staged.routeProfiles),
    'routeRules': table(staged.routeRules),
    'markers': table(staged.markers),
    'settings': staged.settings ?? const <String, String>{},
    'counters': staged.counters,
    'doProfiles': choice.profiles,
    'doRoutes': choice.routes,
    'doSettings': choice.settings,
    'fromAndroid': fromAndroid,
    'defaultGroupName': env.defaultGroupName,
  };
}

/// Decodes a column-keyed row list from the host reply.
List<SqlRow> _rowsFromHost(Map<String, dynamic> reply, String key) {
  final value = reply[key];
  if (value is! List) return const <SqlRow>[];
  return value
      .whereType<Map>()
      .map((r) => Map<String, Object?>.from(r))
      .toList();
}

/// Builds the Dart document from rows the host commit returned. Same mapping as
/// [_documentFromRoom]; kept separate so the Android path never re-opens Room
/// from Dart (which cannot dlopen SQLite on a stock device).
ProfilesDocument _documentFromRows(
  List<SqlRow> profileRows,
  List<SqlRow> groupRows,
  _Staged staged,
) {
  final profiles = <ProfileRow>[];
  for (final row in profileRows) {
    profiles.add(ProfileRow(
      id: _toId(row['id']),
      type: '${row['type'] ?? ''}',
      name: row['name'] as String?,
      gid: _toId(row['gid']),
      userOrder: _toId(row['user_order']),
      latency: _toId(row['latency']),
      latencyAt: _toId(row['latency_at']),
      dlSpeed: row['dl_speed'] as String?,
      ulSpeed: row['ul_speed'] as String?,
      testCountry: row['test_country'] as String?,
      ipOut: row['ip_out'] as String?,
      outboundJson: '${row['outbound_json'] ?? ''}',
      rx: _toId(row['traffic_dl']),
      tx: _toId(row['traffic_up']),
      testError: row['test_error'] as String?,
    ));
  }
  final groups = <GroupRow>[];
  for (final row in groupRows) {
    groups.add(GroupRow(
      id: _toId(row['id']),
      archive: _isTrue(row['archive']),
      skipAutoUpdate: _isTrue(row['skip_auto_update']),
      name: '${row['name'] ?? ''}',
      url: '${row['url'] ?? ''}',
      info: '${row['info'] ?? ''}',
      subLastUpdate: _toId(row['sub_last_update']),
      frontProxyId: row['front_proxy_id'] == null ? -1 : _toId(row['front_proxy_id']),
      landingProxyId: row['landing_proxy_id'] == null ? -1 : _toId(row['landing_proxy_id']),
      columnWidthJson: '${row['column_width_json'] ?? ''}',
      scrollLastProfile: row['scroll_last_profile'] == null ? -1 : _toId(row['scroll_last_profile']),
      autoClearUnavailable: _isTrue(row['auto_clear_unavailable']),
      testSortBy: _toId(row['test_sort_by']),
      trafficSortBy: _toId(row['traffic_sort_by']),
      testItemsToShow: _toId(row['test_items_to_show']),
      typeSortBy: _toId(row['type_sort_by']),
      subOptionsJson: '${row['sub_options_json'] ?? '{}'}',
      subMetadataJson: '${row['sub_metadata_json'] ?? '{}'}',
      sortMethod: _toId(row['sort_method']),
      sortDescending: _isTrue(row['sort_descending']),
      displayOrder: _toId(row['display_order']),
      routeId: row['route_id'] == null ? -1 : _toId(row['route_id']),
      importSubRoute: _isTrue(row['import_sub_route']),
    ));
  }
  final nextP = [
    staged.counters['profiles'] ?? 0,
    if (profiles.isNotEmpty) profiles.map((p) => p.id).reduce((a, b) => a > b ? a : b) + 1,
  ].reduce((a, b) => a > b ? a : b);
  final nextG = [
    staged.counters['groups'] ?? 0,
    if (groups.isNotEmpty) groups.map((g) => g.id).reduce((a, b) => a > b ? a : b) + 1,
  ].reduce((a, b) => a > b ? a : b);
  return ProfilesDocument(
    nextProfileId: nextP,
    nextGroupId: nextG,
    profiles: profiles,
    groups: groups,
  );
}

// ---------------------------------------------------------------------------
// Introspection used by tests (not part of the production surface).

/// Exported for parity tests: the desktop column list of a table.
List<String> backupDesktopColumns(String table) => _desktopColumnsFor(table);

/// Exported for parity tests: the DDL list.
List<String> get backupDesktopDdl => desktopDdl;
