// Dart-side backup write path (ADR 0005 phase 4; ADR 0006 stage C2c2a moved it
// off live Room).
//
// P10 moved the THRN byte codec (`backup_store.dart`) and the WebDAV transport
// (`backup_webdav.dart`) to Dart; this file replaced the two native writers that
// remained. Since C2c2a it is a documents-only pipeline:
//
//  * export builds the container's SQL tables from the live documents —
//    `profiles.json` (profiles/groups), the kernel's `global_route_rules.json`
//    (the one route table), and the host's `settings.json`/`markers.json`
//    snapshots; legacy per-profile route containers are no longer read — a
//    container with only the old per-profile tables and no global table simply
//    carries no routes;
//  * restore stages the container (through `backup.container`, the backup's own
//    file) and writes the documents back: the Dart profiles document, the route
//    documents, the host's settings/markers documents. Nothing is read from or
//    written to Room.
//
// The SQL, column order and merge rules remain a literal port of
// `app/src/main/java/io/nekohasekai/sagernet/database/backup/`
// (`BackupExport.kt`, `BackupRestore.kt`, `DesktopSchema.kt`), which in turn
// mirror the Throne desktop's R10 §8.7/§8.8. When changing any of it, change the
// Kotlin source too (until it is deleted) and keep the two in step.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../data/sqlite.dart' show Sqlite, SqliteDatabase, SqlRow;
import 'room_snapshot_host.dart' show HostSqlHandle, RoomSnapshotHost;
import '../data/configuration_store.dart'
    show ConfigurationRow, NodeRow, ProfilesDocument, documentsDirFromDatabasePath;
import 'route_documents.dart';
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
///
/// The same set also filters the UI preferences document ([backupUiDocument],
/// [BackupEnvironment.uiPayload]): a key that describes *this* install's state
/// is not user data, so it belongs in neither direction of a backup.
const Set<String> backupDeviceLocalKeys = <String>{
  'webdavServer', 'webdavUsername', 'webdavPassword', 'webdavPath',
  'deviceId', 'deviceName', 'batteryPromptShown', 'hwidFallback',
  'resumeAfterUpdate', 'updateSkippedVersionCode', 'wifiPermissionAsked',
  'serviceError', 'serviceErrorDns', 'serviceErrorGeo', 'serviceErrorRuleSets',
  'startWithoutRuleSets', 'runningProfiles', 'runningRoute',
  'core_box_api_port',
  // Launch bookkeeping (`BootGuard.preferenceKey`), not user data: a backup
  // restored on another install would otherwise hand it a marker that says the
  // previous launch died. The freshness window neutralises a stale marker, but
  // a first launch should never have to rely on that.
  'bootGuardRecord',
};

/// Android-only keys of the same table (SettingsRegistry.ANDROID_KEYS): a
/// desktop backup keeps this device's values for these; an Android backup
/// replaces them. The restore's merge runs on the host
/// (`FlroneRoomSnapshot.restoreSettings`, stage C2c2a); this copy is the Dart half
/// of the three-way contract `room_snapshot_audit.py` checks.
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
const String _profileId = 'profileId'; // Key.PROFILE_ID
const String _profileCurrent = 'profileCurrent'; // Key.PROFILE_CURRENT
const int _noProfileId = -1919;
const String _tunPrivateRangesIpv6 = 'migration.tun_private_ranges_ipv6';

/// Host facts and document I/O a backup needs but Dart cannot derive on a
/// stock device: app version, device id/name, the document directory (through
/// [databasePath]) and the four settings/markers seams.
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
    this.settingsSnapshot,
    this.markersSnapshot,
    this.restoreSettings,
    this.restoreMarkers,
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
  /// export the document, not a database copy. When supplied, [profileDocument]
  /// is the profiles/groups source; null means a pre-migration install with no
  /// document yet and those two tables export empty.
  final Future<ProfilesDocument?> Function()? profileDocument;

  /// ADR 0006 stage B: the restore's ONLY profiles/groups sink. The staged rows
  /// become the whole document here (production: `ConfigurationStore.replaceAll` —
  /// one atomic temp+rename write), so the app reads them without a Room hop.
  final Future<void> Function(ProfilesDocument doc)? applyRestoredProfiles;

  /// C2c2a: the live `settings.json` document over the host channel
  /// (`settings.snapshot`). Null in a bridge/desktop environment with no host;
  /// a returned map is the export's settings source.
  final Future<Map<String, String>?> Function()? settingsSnapshot;

  /// C2c2a: the live `markers.json` document (`markers.snapshot`), as
  /// `{key, marked_at}` rows.
  final Future<List<SqlRow>?> Function()? markersSnapshot;

  /// C2c2a: one host call that merges the container's settings and repairs the
  /// selection keys (`settings.restore`). Null means this install cannot write
  /// the settings document: a settings restore then refuses before writing.
  final Future<List<String>> Function(SettingsRestore request)? restoreSettings;

  /// C2c2a: one host call that replaces the markers document
  /// (`markers.restore`).
  final Future<void> Function(List<SqlRow> rows)? restoreMarkers;

  Map<String, Object?> get uiPayload => backupUiDocument(<String, Object?>{
        'preferences': preferences,
        'settings': settingsDocument,
        'quality': qualityDocument,
      });
}

/// The settings half of a restore, as `settings.restore` receives it.
class SettingsRestore {
  const SettingsRestore({
    required this.settings,
    required this.fromAndroid,
    required this.restoredProfiles,
    this.groupIds,
    this.profileIds,
  });

  /// Null: the container carried no settings block — keep the live values and
  /// only run the selection repair.
  final Map<String, String>? settings;
  final bool fromAndroid;

  /// Whether this restore replaced the profiles document (enables the desktop
  /// `remember_id` translation).
  final bool restoredProfiles;

  /// The catalog the selection keys may point at. Null = no document to compare
  /// with, so that key is left alone.
  final List<int>? groupIds;
  final List<int>? profileIds;
}

/// The UI documents as a backup carries them: the same map with the
/// device-local preferences removed ([backupDeviceLocalKeys]).
///
/// One filter for both directions, because both used to bypass it:
///
///  * export wrote the preferences document verbatim, so launch bookkeeping
///    (`bootGuardRecord`) travelled inside the container;
///  * restore hands the container's `flrone_ui` to the host writer wholesale, so
///    a container made by an older build would put that key back.
///
/// A restore therefore never has to trust the container for install-local state:
/// the freshness window in `boot_guard.dart` still protects a marker that a
/// device wrote itself, and this keeps a foreign one from arriving at all.
Map<String, Object?> backupUiDocument(Map<String, Object?> ui) {
  final preferences = ui['preferences'];
  if (preferences is! Map) return ui;
  final filtered = <String, Object?>{
    for (final entry in preferences.entries)
      if (!backupDeviceLocalKeys.contains('${entry.key}'))
        '${entry.key}': entry.value,
  };
  return <String, Object?>{...ui, 'preferences': filtered};
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

/// A handle to a **backup container** file: a thin wrapper so the merge logic
/// can be exercised with a synthetic file. Production opens the temp snapshot
/// (export) or the staged database (restore); it never opens the live database
/// (ADR 0006 stage C2c2a — the data plane reads/writes documents only).
class BackupDatabase {
  BackupDatabase._(this._ffi, this._host, this._handle);

  /// Desktop/CI: a dart:ffi connection. Null on Android (no public libsqlite).
  final SqliteDatabase? _ffi;
  /// Android: the host that owns the framework SQLite, reached over MethodChannel.
  final RoomSnapshotHost? _host;
  /// Android: the opaque handle of the host-opened **container** database.
  final HostSqlHandle? _handle;

  /// Opens [path]. Prefers dart:ffi (desktop/CI); on Android, where the app
  /// cannot dlopen SQLite, falls back to the host's container transport.
  ///
  /// C2c1/C2c2a: this only ever opens a backup container file. There is no
  /// live-database op on the channel (`data.roomSql`'s `openRoom` and the
  /// `data.roomSnapshot`/`data.applyRoomSnapshot` DAO pumps are gone).
  ///
  /// [sqlite] lets tests inject a library from an explicit path; [host] lets
  /// the production caller / tests inject the MethodChannel backend. Callers
  /// that need the host must inject it — no global channel dependency here.
  static Future<BackupDatabase?> open(
    String path, {
    bool readOnly = true,
    Sqlite? sqlite,
    RoomSnapshotHost? host,
  }) async {
    final lib = sqlite ?? resolveBackupSqlite();
    if (lib != null) {
      final db = lib.openDatabase(path, readOnly: readOnly);
      if (db != null) return BackupDatabase._(db, null, null);
    }
    if (host == null) return null;
    final handle = await host.openSql(path, write: !readOnly);
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
  '''CREATE TABLE IF NOT EXISTS global_route_rules (
    rule_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
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
    package_name_regex_json TEXT
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

/// A staged table built from the kernel documents' row maps: the desktop
/// columns the rows actually carry (empty rows keep the full shape), sorted by
/// [sortKeys] like the SQL `copy` orders, cells positionally aligned and bools
/// flattened to 0/1 for the SQLite bind — Go's rowBool/rowInt64 accept both
/// spellings on the way back into a document.
_SqlTable _docTable(
  List<String> columns,
  List<Map<String, Object?>> rows,
  List<String> sortKeys,
) {
  final ordered = List<Map<String, Object?>>.from(rows)
    ..sort((a, b) {
      for (final key in sortKeys) {
        final c = _toId(a[key]).compareTo(_toId(b[key]));
        if (c != 0) return c;
      }
      return 0;
    });
  final cols = ordered.isEmpty
      ? List<String>.from(columns)
      : columns.where((c) => ordered.any((r) => r.containsKey(c))).toList();
  return _SqlTable(cols, [
    for (final row in ordered)
      [
        for (final col in cols)
          row[col] is bool ? ((row[col] as bool) ? 1 : 0) : row[col],
      ],
  ]);
}

/// The staged rows back into the document shape (column-keyed maps).
List<SqlRow> _tableToMaps(_SqlTable? table) {
  if (table == null) return const [];
  return [
    for (final row in table.rows)
      {for (var i = 0; i < table.columns.length; i++) table.columns[i]: row[i]},
  ];
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
// export: the live documents -> the desktop SQLite -> THRN

/// The parts to export; `profiles` is always on (FlroneBackup.selection).
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
  _SqlTable? globalRouteRules;
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

/// Creates a THRN envelope from the live documents and the settings/markers
/// snapshots — no live database is opened (ADR 0006 stage C2c2a).
///
/// [enrichUi] builds the `ui` map from the current host documents; it is called
/// once at the start so a backup never embeds the WebDAV password.
Future<Map<String, Object?>> createBackup({
  required BackupEnvironment env,
  required String scope,
  Sqlite? sqlite,
  Future<BackupDatabase?> Function(String path, {bool readOnly, Sqlite? sqlite, RoomSnapshotHost? host})? open,
  RoomSnapshotHost? host,
  Map<String, Object?> Function()? enrichUi,
}) async {
  final ui = backupUiDocument(enrichUi?.call() ?? env.uiPayload);
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
  final dir = await Directory.systemTemp.createTemp('thrn-export-');
  final snapshotPath = '${dir.path}/backup.db';
  BackupDatabase? target;
  try {
    // The export's own container is the only database this side opens: the
    // source tables are the documents (profiles.json, route_*.json, the host's
    // settings/markers snapshots).
    target = await opener(snapshotPath, readOnly: false, sqlite: sqlite, host: effectiveHost);
    if (target == null) {
      throw const BackupWriteException('The backup database cannot be created');
    }
    final profileDoc = await env.profileDocument?.call();
    final snapshot = await _snapshot(selection, profileDoc, env);
    await _buildDatabase(target, snapshot, selection);
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
    final groups = _profileNames(snapshot);
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
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // best-effort cleanup
    }
  }
}

/// A Dart [NodeRow] as a desktop `profiles` row. Only the columns the
/// document carries are filled; `created_at`/`updated_at` are left null so the
/// DDL defaults apply.
List<Object?> _profileDesktopRow(NodeRow p) {
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

/// A Dart [ConfigurationRow] as a desktop `groups` row. `profiles_json` (the desktop's
/// membership index) is derived from the document's profiles by the caller via
/// [_buildDatabase]; here it is left for that step to fill.
List<Object?> _groupDesktopRow(ConfigurationRow g) {
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

/// Builds the desktop snapshot from the live documents.
///
/// Every table has a document source (ADR 0006 stage C2c2a):
///  * profiles/groups — the Dart `profiles.json` document ([profileDoc]);
///  * routes — the kernel's one global route document, read off the UI isolate;
///  * settings/markers — the host's `SettingsJsonStore` snapshots.
/// A missing document yields an empty table (a fresh/pre-migration install);
/// no live database is consulted.
Future<_Snapshot> _snapshot(
  BackupSelection selection,
  ProfilesDocument? profileDoc,
  BackupEnvironment env,
) async {
  final s = _Snapshot();
  final desktop = <String, List<String>>{
    for (final table in const ['profiles', 'groups', 'global_route_rules', 'settings', 'markers'])
      table: _desktopColumnsFor(table),
  };

  if (profileDoc != null) {
    final groups = List<ConfigurationRow>.from(profileDoc.groups)
      ..sort((a, b) => a.displayOrder.compareTo(b.displayOrder) == 0
          ? a.id.compareTo(b.id)
          : a.displayOrder.compareTo(b.displayOrder));
    for (final g in groups) {
      s.tabs.add(_Tab(g.id, g.displayOrder));
    }
    final orderedProfiles = List<NodeRow>.from(profileDoc.profiles)
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
      // database defaults.
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
  }

  // Routes: the kernel's global document is the live store (ADR 0002 phase 3c).
  // The document work runs in a worker isolate (FlClash's backupTask pattern):
  // the export reads it off the UI isolate and RouteDocuments is constructed
  // inside the worker because file handles do not cross isolate boundaries.
  final globalRows = await _readGlobalRouteRowsOffUi(env.databasePath);
  final profileIds = s.members.values.expand((ids) => ids).toList();
  final groupIds = s.tabs.map((t) => t.id).toList();
  // The document supplies the counters (next ids); the max ids are a floor so
  // a restored/high-water id can never be reused.
  s.counters['profiles'] = [
    s.counters['profiles'] ?? 0,
    if (profileIds.isNotEmpty) profileIds.reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);
  s.counters['groups'] = [
    s.counters['groups'] ?? 0,
    if (groupIds.isNotEmpty) groupIds.reduce((a, b) => a > b ? a : b),
  ].reduce((a, b) => a > b ? a : b);

  if (selection.routes) {
    s.globalRouteRules = _docTable(
      desktop['global_route_rules']!, globalRows, const ['rule_id']);
  }
  if (selection.settings) {
    // ADR 0006 stage C2c2a: the host's settings/markers documents are the
    // store; their snapshots arrive in the same column shape the tables used to
    // have, so the container still carries both SQL tables and an older build
    // can restore what this one exports.
    final snapshotter = env.settingsSnapshot;
    final Map<String, String> stored;
    if (snapshotter == null) {
      stored = const <String, String>{};
    } else {
      final rows = await snapshotter();
      if (rows == null) {
        // A wired snapshot that could not answer must not become an empty
        // settings table: restoring that container would wipe the user's
        // settings on another install.
        throw const BackupWriteException('The settings could not be read for the backup');
      }
      stored = rows;
    }
    s.settings = _exportedSettings(stored, groupIds, profileIds.toSet());
    final markerRows = env.markersSnapshot == null
        ? const <SqlRow>[]
        : (await env.markersSnapshot!() ?? const <SqlRow>[]);
    s.markers = _docTable(desktop['markers']!, markerRows, const ['key']);
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
      // The one global rule table: `rule_id` instead of an owner column.
      // otherwise the same rule columns (GlobalRouteRuleEntity : RouteRuleColumns).
      'global_route_rules' => const <String>[
          'rule_id', 'rule_order', 'name', 'type', 'ip_version',
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

/// The desktop DDL's column metadata for [table], in `PRAGMA table_info` shape.
///
/// The container's own schema contract — the DDL every container is built from
/// — is the live column shape for a restore: there is no live database to ask
/// (ADR 0006 stage C2c2a). `backup_write_test` pins this parse against a real
/// `PRAGMA table_info` on the same DDL, so the two sources can not drift
/// silently.
///
/// `created_at`/`updated_at` are dropped: they are not live columns for a
/// staged row (the container's DDL default fills them).
List<_ColumnInfo> _desktopColumnsInfo(String table) =>
    _ddlColumnCache.putIfAbsent(table, () => _ddlColumns(table));

final Map<String, List<_ColumnInfo>> _ddlColumnCache = <String, List<_ColumnInfo>>{};

const Set<String> _ddlDerivedColumns = <String>{'created_at', 'updated_at'};

List<_ColumnInfo> _ddlColumns(String table) {
  final out = <_ColumnInfo>[];
  final create = 'CREATE TABLE IF NOT EXISTS $table (';
  final alter = 'ALTER TABLE $table ADD COLUMN ';
  for (final statement in desktopDdl) {
    final upper = statement.toUpperCase();
    final createAt = upper.indexOf(create.toUpperCase());
    if (createAt >= 0) {
      final open = statement.indexOf('(', createAt);
      final close = statement.lastIndexOf(')');
      if (open < 0 || close <= open) continue;
      for (final part in _splitDdlColumns(statement.substring(open + 1, close))) {
        final column = _ddlColumn(part);
        if (column != null && !_ddlDerivedColumns.contains(column.name)) out.add(column);
      }
      continue;
    }
    final alterAt = upper.indexOf(alter.toUpperCase());
    if (alterAt >= 0) {
      final column = _ddlColumn(statement.substring(alterAt + alter.length));
      if (column != null && !_ddlDerivedColumns.contains(column.name)) out.add(column);
    }
  }
  return out;
}

/// Splits a `CREATE TABLE` body on commas that sit outside parentheses and
/// quotes (`DEFAULT (strftime('%s', 'now'))` keeps its comma).
Iterable<String> _splitDdlColumns(String body) sync* {
  var depth = 0;
  var start = 0;
  var quote = '';
  for (var i = 0; i < body.length; i++) {
    final c = body[i];
    if (quote.isNotEmpty) {
      if (c == quote) quote = '';
      continue;
    }
    if (c == "'" || c == '"' || c == '`') {
      quote = c;
    } else if (c == '(') {
      depth++;
    } else if (c == ')') {
      depth--;
    } else if (c == ',' && depth == 0) {
      yield body.substring(start, i);
      start = i + 1;
    }
  }
  yield body.substring(start);
}

_ColumnInfo? _ddlColumn(String part) {
  final text = part.trim();
  if (text.isEmpty) return null;
  final upper = text.toUpperCase();
  for (final constraint in const [
    'PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE', 'CHECK', 'CONSTRAINT',
  ]) {
    if (upper.startsWith(constraint)) return null;
  }
  final name = text.split(RegExp(r'\s+')).first;
  final notNull = RegExp(r'\bNOT\s+NULL\b', caseSensitive: false).hasMatch(text);
  final defaultMatch =
      RegExp(r'\bDEFAULT\s+(.+)$', caseSensitive: false, dotAll: true).firstMatch(text);
  return _ColumnInfo(name, notNull, defaultMatch?.group(1)?.trim());
}

Map<String, String> _exportedSettings(
  Map<String, String> stored,
  List<int> groupIds,
  Set<int> profileIds,
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
) async {
  for (final sql in desktopDdl) {
    await db.execute(sql);
  }
  await db.execute(
    'INSERT INTO entity_ids (profile_last_id, group_last_id, otp_profile_last_id) '
    'VALUES (?, ?, 0)',
    <Object?>[
      s.counters['profiles'] ?? 0,
      s.counters['groups'] ?? 0,
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
  // Only the single global table is written.
  final globalRules = s.globalRouteRules;
  if (globalRules != null) {
    await _insertRows(
        db, 'global_route_rules', globalRules.columns, globalRules.rows);
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
    // One table: only duplicate rule ids and non-contiguous order need a
    // check; there is no owner row to reference and no current selection.
    await zero('duplicate rule ids',
        'SELECT COUNT(*) FROM (SELECT rule_id FROM global_route_rules '
        'GROUP BY rule_id HAVING COUNT(*) > 1)');
  }
}

/// The `profiles` preview array of the envelope `backup.create` hands out:
/// one entry per group with its node count (the confirmation dialog's count is
/// groups, not nodes). Derived from the document-backed snapshot, which is the
/// only source now.
List<Map<String, Object?>> _profileNames(_Snapshot snapshot) {
  final groups = snapshot.groups;
  if (groups == null) return const <Map<String, Object?>>[];
  final counts = <int, int>{};
  final profileTable = snapshot.profiles;
  if (profileTable != null) {
    final gidIndex = profileTable.index('gid');
    for (final row in profileTable.rows) {
      final gid = _toId(row[gidIndex]);
      counts[gid] = (counts[gid] ?? 0) + 1;
    }
  }
  final idIndex = groups.index('id');
  final nameIndex = groups.index('name');
  final urlIndex = groups.index('url');
  final out = <Map<String, Object?>>[];
  // Tab order lives in the snapshot's `tabs` (the desktop groups_order table),
  // not in the groups row — sort by it before emitting the preview.
  final orderById = <int, int>{for (final tab in snapshot.tabs) tab.id: tab.order};
  final byOrder = groups.rows.toList()
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

// ---------------------------------------------------------------------------
// restore: THRN -> staged rows -> the live documents

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
  const _ColumnInfo(this.name, this.notNull, this.defaultSql);
  final String name;
  final bool notNull;
  final String? defaultSql;
}

class _Staged {
  _SqlTable? groups;
  _SqlTable? profiles;
  _SqlTable? globalRouteRules;
  Map<String, String>? settings;
  _SqlTable? markers;
  final Map<String, int> counters = <String, int>{};
}

/// Result of a restore: the warnings the native bridge used to emit, and the
/// UI documents the container carried.
class RestoreResult {
  const RestoreResult(this.warnings, this.ui);
  final List<String> warnings;
  final Map<String, Object?> ui;
}

/// Restores a staged envelope into the live documents: profiles/groups into the
/// Dart document, routes into the kernel's route documents, settings/markers
/// into the host's documents.
///
/// [bytes] is the decoded `thr` member; [scope] and [strategy] keep the same
/// semantics as `FlroneBackup.restore`. [env] supplies the document directory
/// (derived from [BackupEnvironment.databasePath]) and the document sinks. No
/// live database is opened (ADR 0006 stage C2c2a).
///
/// The document write comes first (ADR 0006 stage B) and is rolled back to the
/// captured pre-restore document if any later step fails, so a failed restore
/// never leaves the new catalog on top of old routes/settings. The route
/// documents get the same treatment: their pre-replace contents are captured
/// and put back when the route write itself, or any later step, fails (see
/// [RouteDocuments.snapshot]).
Future<RestoreResult> restoreBackup({
  required BackupEnvironment env,
  required List<int> bytes,
  required String scope,
  required String strategy,
  Sqlite? sqlite,
  Future<BackupDatabase?> Function(String path, {bool readOnly, Sqlite? sqlite, RoomSnapshotHost? host})? open,
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
  // Refuse before any write when the profiles part has nowhere to go. The
  // document is the live copy, so "commit the routes and skip the document"
  // would leave the restore half applied and the old catalog on screen
  // (ADR 0006 stage B).
  final applyProfiles = choice.profiles ? env.applyRestoredProfiles : null;
  if (choice.profiles && applyProfiles == null) {
    throw const BackupWriteException(
        'This install cannot write the configuration document, so the restore '
        'was not applied. Nothing was changed.');
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
  final warnings = <String>[];
  try {
    bak = await opener(stagedPath, readOnly: false, sqlite: sqlite, host: effectiveHost);
    if (bak == null) {
      throw const BackupWriteException('The backup database cannot be opened');
    }
    final staged = await _stage(bak, choice, warnings);
    // ADR 0006 stage B: the staged rows go straight into the document — the one
    // file, one writer the app reads — with no database hop. `replaceAll`
    // writes a temp file and renames it, so the document is replaced
    // all-or-nothing.
    ProfilesDocument? restored;
    // The document this restore is about to replace: the rollback copy for
    // every step after the write. Null means a pre-migration install (no
    // document yet — the production reader reports null only then).
    ProfilesDocument? previous;
    if (choice.profiles) {
      try {
        previous = await env.profileDocument?.call();
      } on Object catch (error) {
        throw BackupWriteException(
            'The current configuration document could not be read, so nothing '
            'was restored: $error');
      }
      restored = _documentFromStaged(staged, choice, env.defaultGroupName);
      try {
        await applyProfiles!(restored);
      } on Object catch (error) {
        throw BackupWriteException(
            'The configuration document could not be written, so nothing was '
            'restored: $error');
      }
    }
    // Every write below happens after the document write, so a failure must not
    // leave the new catalog on top of the old routes/settings — the
    // half-applied restore the user reads as success-then-stale. The route
    // documents are captured before their first write (the replace when the
    // container carries routes, the source_gid cleanup on a profiles-only
    // restore) so the same failure can put those files back too; the note in
    // the error text says how that went.
    RouteDocumentsSnapshot? routesBefore;
    final ui = backupUiDocument(container.flroneUi);
    try {
      // Capture first: the snapshot must describe the pre-restore documents,
      // and neither the settings write nor the route write may precede it.
      if (choice.routes || choice.profiles) {
        try {
          routesBefore = await _snapshotRouteDocumentsOffUi(env.databasePath);
        } on Object catch (error) {
          throw BackupWriteException(
              'The current route documents could not be read, so nothing was '
              'restored: $error');
        }
      }
      // ADR 0006 stage C2c2a: settings and markers leave through the host's
      // document writers, one call each. The selection repair rides
      // `settings.restore`, fed with the ids of the catalog this restore leaves
      // behind (the restored document, or the surviving one).
      if (choice.profiles || choice.routes || choice.settings) {
        final restoreSettings = env.restoreSettings;
        if (restoreSettings == null) {
          throw const BackupWriteException(
              'This install cannot commit the restored settings, so nothing '
              'was restored.');
        }
        warnings.addAll(await restoreSettings(SettingsRestore(
          settings: choice.settings ? staged.settings : null,
          fromAndroid: container.isAndroid,
          restoredProfiles: choice.profiles,
          groupIds: await _selectionGroupIds(choice, restored, env),
          profileIds: await _selectionProfileIds(choice, restored, env),
        )));
      }
      if (choice.settings && staged.markers != null) {
        final restoreMarkers = env.restoreMarkers;
        if (restoreMarkers == null) {
          throw const BackupWriteException(
              'This install cannot commit the restored markers, so nothing '
              'was restored.');
        }
        await restoreMarkers(_tableToMaps(staged.markers));
      }

      // ADR 0002 phase 3c: the store the app reads after a restore is the
      // kernel's global route document, not a database table. The document
      // replace below is the only route write. A failure here reaches the
      // catch: the snapshot taken above puts the previous file back.
      if (choice.routes && staged.globalRouteRules != null) {
        // null = the container carried no route table at all: leave the live
        // document alone. An empty table genuinely means "no rules".
        await _restoreRouteDocumentsOffUi(
          env.databasePath,
          _tableToMaps(staged.globalRouteRules),
        );
      }

      if (scope == 'all' && applyUi != null) {
        await applyUi(ui);
      }
    } on Object catch (error) {
      // The routes are rolled back with the profiles document: the two are
      // separate files, so neither can be undone inside the other's writer,
      // but a failed restore must not leave one new and one old.
      final routesNote = routesBefore == null
          ? null
          : await _restoreRouteSnapshotOffUi(env.databasePath, routesBefore);
      if (choice.profiles) {
        final notes =
            await _rollbackProfiles(applyProfiles!, previous, routesNote);
        throw BackupWriteException('${_restoreErrorText(error)}$notes');
      }
      if (routesNote != null) {
        throw BackupWriteException('${_restoreErrorText(error)}\n$routesNote');
      }
      rethrow;
    }
    // A refresh is a UI notification, not a data step: a listener failure must
    // not undo a committed restore.
    refresh?.call();
    return RestoreResult(List<String>.unmodifiable(warnings), ui);
  } finally {
    await bak?.close();
    try {
      dir.deleteSync(recursive: true);
    } on Object {
      // best-effort cleanup
    }
  }
}

/// The message of a restore failure without the exception wrapper: the
/// rollback notes are appended to it, and prefixing them with
/// `BackupWriteException: ` a second time would read as two failures.
String _restoreErrorText(Object error) =>
    error is BackupWriteException ? error.message : '$error';

/// Puts the pre-restore configuration document back after a later restore step
/// failed, and describes the outcome for the error message (a leading newline
/// plus the notes, so the original reason stays the first line).
///
/// [previous] is the document captured before the restore's own write. A null
/// value cannot be rolled back: the atomic apply path
/// (`ConfigurationStore.replaceAll` in production) replaces a document, it cannot
/// delete one, and the production reader reports null only when the file does
/// not exist (a pre-migration install). Staying silent about that would leave
/// exactly the half-applied state this rollback exists to prevent, so the note
/// says the restored catalog is still in place.
///
/// [routesNote] is the route-document rollback's own outcome
/// ([RouteDocuments.restoreSnapshot]); null means the snapshot could not be
/// taken or no route document was touched, and the note says the routes are
/// unchanged.
Future<String> _rollbackProfiles(
  Future<void> Function(ProfilesDocument doc) applyProfiles,
  ProfilesDocument? previous,
  String? routesNote,
) async {
  final notes = <String>[];
  if (previous == null) {
    notes.add('The configuration document did not exist before this restore, '
        'so it cannot be made absent again: the restored catalog is still in '
        'place.');
  } else {
    try {
      await applyProfiles(previous);
      notes.add('The previous configuration document was restored.');
    } on Object catch (error) {
      notes.add('The previous configuration document could not be restored '
          '($error); the restored catalog is still in place.');
    }
  }
  notes.add(routesNote ?? 'The route documents were not changed.');
  return '\n${notes.join(' ')}';
}

Future<_Staged> _stage(
  BackupDatabase bak,
  RestoreChoice choice,
  List<String> warnings,
) async {
  final staged = _Staged();
  if (choice.profiles) await _stageProfiles(bak, staged, warnings);
  if (choice.routes) {
    // Only the one global table is read. A container with no global table —
    // including an old per-profile container — carries no routes and leaves
    // the live document alone.
    if (await _hasTable(bak, 'global_route_rules')) {
      staged.globalRouteRules =
          await _stageTable(bak, 'global_route_rules', '`rule_id`', warnings);
    }
  }
  if (choice.settings) await _stageSettings(bak, staged, warnings);
  if ((choice.profiles || choice.routes) && await _hasTable(bak, 'entity_ids')) {
    final columns = (await _columnsOf(bak, 'entity_ids')).toSet();
    const counterColumns = <MapEntry<String, String>>{
      MapEntry('profiles', 'profile_last_id'),
      MapEntry('groups', 'group_last_id'),
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
///
/// The live column shape is this app's own DDL contract — the schema every
/// container is built from — via [_desktopColumnsInfo]: the restore has no live
/// database handle to ask (ADR 0006 stage C2c2a).
Future<_SqlTable> _stageTable(
  BackupDatabase bak,
  String table,
  String order,
  List<String> warnings, {
  List<String> extra = const <String>[],
}) async {
  final liveColumns = _desktopColumnsInfo(table);
  final bakColumns = (await _columnsOf(bak, table)).toSet();
  for (final column in liveColumns) {
    if (column.notNull &&
        column.defaultSql == null &&
        !bakColumns.contains(column.name) &&
        !extra.contains(column.name)) {
      throw BackupWriteException(
          "The backup's $table table has no ${column.name} column.");
    }
  }
  final shared = liveColumns
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
  _Staged staged,
  List<String> warnings,
) async {
  await _require(bak, 'groups');
  await _require(bak, 'profiles');
  final groups = await _stageTable(bak, 'groups', '`id`', warnings,
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

  final profiles = await _stageTable(bak, 'profiles', '`id`', warnings,
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

Future<void> _stageSettings(
  BackupDatabase bak,
  _Staged staged,
  List<String> warnings,
) async {
  // A container whose `settings` table is blank is a container that carries no
  // settings — not "the user has none". Without the table there is nothing to
  // stage, and the caller keeps what the install has; the alternative (an empty
  // staged map) is what wiped a phone's settings on a restore from such a
  // container. An export always writes the derived selection rows, so a real
  // "all settings reset" backup still arrives non-empty.
  if (await _hasTable(bak, 'settings')) {
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
    staged.settings = rows.isEmpty ? null : rows;
  } else {
    staged.settings = null;
  }
  // Markers are staged whether or not the settings rows came through: they are
  // their own replacement, and blank markers mean the same thing as blank
  // settings (nothing to apply).
  if (await _hasTable(bak, 'markers')) {
    final markers = await _stageTable(bak, 'markers', '`key`', warnings);
    staged.markers = markers.rows.isEmpty ? null : markers;
  } else {
    staged.markers = null;
  }
}

// ---------------------------------------------------------------------------
// selection repair inputs (the host merges them; no live database is read)

Future<List<int>?> _selectionGroupIds(
  RestoreChoice choice,
  ProfilesDocument? restored,
  BackupEnvironment env,
) async {
  final doc = choice.profiles ? restored : await _currentDocument(env);
  if (doc == null) return null;
  return _restoredGroupOrder(doc);
}

Future<List<int>?> _selectionProfileIds(
  RestoreChoice choice,
  ProfilesDocument? restored,
  BackupEnvironment env,
) async {
  final doc = choice.profiles ? restored : await _currentDocument(env);
  if (doc == null) return null;
  return doc.profiles.map((p) => p.id).toList();
}

/// The surviving profiles document, or null when this install has none yet (a
/// pre-migration install). A read failure is treated as "no catalog to repair
/// against": the restore itself does not depend on it.
Future<ProfilesDocument?> _currentDocument(BackupEnvironment env) async {
  try {
    return await env.profileDocument?.call();
  } on Object {
    return null;
  }
}

/// The restored groups' ids in tab order (display order, then id) — the order
/// the selection always used (`ORDER BY display_order, id`).
List<int> _restoredGroupOrder(ProfilesDocument doc) =>
    (List<ConfigurationRow>.from(doc.groups)
      ..sort((a, b) => a.displayOrder != b.displayOrder
          ? a.displayOrder.compareTo(b.displayOrder)
          : a.id.compareTo(b.id)))
        .map((g) => g.id)
        .toList();

/// The profiles document rebuilt **straight from the staged rows** — the one
/// builder both restore paths share (ADR 0006 stage B). Room's profile/group
/// tables are never touched (stage C2c2a removed the last write).
///
/// Carries the restore semantics the old database commit used to own:
/// * a default group when the backup has none (never zero groups), named from
///   the environment's localised default;
/// * on a restore without routes, the groups' `route_id` clears — the routes
///   they name were not restored.
ProfilesDocument _documentFromStaged(
  _Staged staged,
  RestoreChoice choice,
  String defaultGroupName,
) {
  final doc = _documentFromRows(
    _tableToMaps(staged.profiles),
    _tableToMaps(staged.groups),
    staged,
  );
  if (doc.groups.isEmpty) {
    // id >= 1: ConfigurationStore treats id 0 as invalid, and an empty backup still
    // needs a group for its (possibly empty) profile set to live in.
    final id = doc.nextGroupId <= 0 ? 1 : doc.nextGroupId;
    return ProfilesDocument(
      nextProfileId: doc.nextProfileId,
      nextGroupId: id + 1,
      profiles: doc.profiles,
      groups: [ConfigurationRow(id: id, name: defaultGroupName, displayOrder: 1)],
    );
  }
  if (choice.profiles && !choice.routes) {
    final groups = [
      for (final g in doc.groups)
        g.routeId == -1 ? g : g.copyWith(routeId: -1),
    ];
    return ProfilesDocument(
      nextProfileId: doc.nextProfileId,
      nextGroupId: doc.nextGroupId,
      profiles: doc.profiles,
      groups: groups,
    );
  }
  return doc;
}

/// The row→model mapping [_documentFromStaged] applies to the staged rows
/// (column-keyed maps — the shape both the container's tables and the host
/// replies share).
ProfilesDocument _documentFromRows(
  List<SqlRow> profileRows,
  List<SqlRow> groupRows,
  _Staged staged,
) {
  final profiles = <NodeRow>[];
  for (final row in profileRows) {
    profiles.add(NodeRow(
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
  final groups = <ConfigurationRow>[];
  for (final row in groupRows) {
    groups.add(ConfigurationRow(
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

/// Exported for parity tests: the DDL-derived column metadata of a table (the
/// restore's stand-in for `PRAGMA table_info`).
List<({String name, bool notNull, String? defaultSql})> backupDesktopColumnInfo(
        String table) =>
    [
      for (final column in _desktopColumnsInfo(table))
        (name: column.name, notNull: column.notNull, defaultSql: column.defaultSql),
    ];

/// Exported for parity tests: the DDL list.
List<String> get backupDesktopDdl => desktopDdl;

// The route-document work of an export/restore runs in a worker isolate
// (FlClash's backupTask pattern). The Isolate.run closures live in these tiny
// helpers on purpose: a closure shares its enclosing scope's Context — and the
// callers' scope holds the BackupDatabase whose DynamicLibrary cannot cross an
// isolate boundary. Here the scope is exactly the primitive parameters.

Future<List<Map<String, Object?>>> _readGlobalRouteRowsOffUi(
  String databasePath,
) =>
    // The timeout fallback is what widget tests ride (their fake clock cannot
    // complete a real isolate future) and what a wedged isolate degrades to.
    Isolate.run(() => _readGlobalRouteRows(databasePath)).timeout(
      const Duration(seconds: 2),
      onTimeout: () => _readGlobalRouteRows(databasePath),
    );

/// The one global table: a container without the document is an empty table.
/// Legacy per-profile route documents are ignored.
List<Map<String, Object?>> _readGlobalRouteRows(String databasePath) {
  final docs = RouteDocuments(Directory(documentsDirFromDatabasePath(databasePath)));
  return docs.readTable('global_route_rules');
}

Future<void> _restoreRouteDocumentsOffUi(
  String databasePath,
  List<Map<String, Object?>> globalRules,
) => Isolate.run(
      () => _restoreRouteDocuments(databasePath, globalRules),
    ).timeout(
      const Duration(seconds: 2),
      onTimeout: () => _restoreRouteDocuments(databasePath, globalRules),
    );

void _restoreRouteDocuments(
  String databasePath,
  List<Map<String, Object?>> globalRules,
) {
  RouteDocuments(Directory(documentsDirFromDatabasePath(databasePath)))
      .restore(globalRules: globalRules);
}

RouteDocuments _routeDocumentsAt(String databasePath) =>
    RouteDocuments(Directory(documentsDirFromDatabasePath(databasePath)));

Future<RouteDocumentsSnapshot> _snapshotRouteDocumentsOffUi(
  String databasePath,
) =>
    Isolate.run(() => _routeDocumentsAt(databasePath).snapshot()).timeout(
      const Duration(seconds: 2),
      onTimeout: () => _routeDocumentsAt(databasePath).snapshot(),
    );

/// Puts a captured route-document set back; the note it returns rides the
/// restore's error text. Never throws: a rollback failure is reported, because
/// the original failure is the one the user must read first.
Future<String> _restoreRouteSnapshotOffUi(
  String databasePath,
  RouteDocumentsSnapshot snapshot,
) async {
  try {
    return await Isolate.run(
      () => _routeDocumentsAt(databasePath).restoreSnapshot(snapshot),
    ).timeout(
      const Duration(seconds: 2),
      onTimeout: () => _routeDocumentsAt(databasePath).restoreSnapshot(snapshot),
    );
  } on Object catch (error) {
    return 'The previous route documents could not be restored ($error); the '
        'restored routes are still in place.';
  }
}
