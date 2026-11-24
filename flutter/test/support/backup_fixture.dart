// The synthetic `sager_net.db` (legacy Room file) and the document/settings
// sink the backup tests use. The DDL mirrors SagerDatabase v20's seven tables;
// enough columns are present to exercise the export/restore mapping, counters
// and settings merge without a device or the Kotlin runtime.
//
// Since ADR 0006 stage C2c2a the backup write path no longer touches this file:
// the tests use it to build the *legacy* database the raw reader
// (`LegacyRoomReader` / `data.legacyRows`) would read, and to prove the
// document-only pipeline leaves it untouched.

import 'dart:io';

import 'package:flrone/data/configuration_store.dart'
    show
        ConfigurationRow,
        NodeRow,
        ConfigurationStore,
        ProfilesDocument,
        documentsDirFromDatabasePath,
        profilesFileName;
import 'package:flrone/data/sqlite.dart' show Sqlite, SqliteDatabase, SqlRow;
import 'package:flrone/services/backup_write.dart';


class RoomFixture {
  RoomFixture(this.sqlite, this.path, {Directory? root})
      : root = root ?? File(path).parent;

  final Sqlite sqlite;
  final String path;

  /// The fixture's own directory, deleted wholesale on [dispose]. [create]
  /// puts the database in `databases/` — the app layout, so
  /// `documentsDirFromDatabasePath` derives a per-fixture `files/documents`
  /// (the kernel route documents' home) instead of a shared systemTemp path.
  final Directory root;

  late final SqliteDatabase db = sqlite.openDatabase(path, readOnly: false)!;

  static Future<RoomFixture> create(
    Sqlite sqlite, {
    required void Function(SqliteDatabase db) seed,
  }) async {
    final dir = await Directory.systemTemp.createTemp('room-fixture-');
    final databases = Directory('${dir.path}/databases')..createSync();
    final path = '${databases.path}/sager_net.db';
    final db = sqlite.openDatabase(path, readOnly: false)!;
    for (final sql in roomDdl) {
      db.execute(sql);
    }
    db.execute('PRAGMA user_version = 20');
    seed(db);
    db.close();
    return RoomFixture(sqlite, path, root: dir);
  }

  SqliteDatabase open({required bool readOnly}) =>
      sqlite.openDatabase(path, readOnly: readOnly)!;

  void dispose() {
    try {
      db.close();
    } on Object {
      // ignore
    }
    try {
      root.deleteSync(recursive: true);
    } on Object {
      // best effort
    }
  }
}

/// SagerDatabase v20's seven tables, cut to the columns the backup writer maps.
/// The full `route_rules` column set is copied from backup_write.dart's desktop
/// schema so the mapping's column counts are exercised word-for-word.
final List<String> roomDdl = <String>[
  "CREATE TABLE groups ("
      "id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,"
      "archive INTEGER NOT NULL DEFAULT 0,"
      "skip_auto_update INTEGER NOT NULL DEFAULT 0,"
      "name TEXT NOT NULL DEFAULT '',"
      "url TEXT NOT NULL DEFAULT '',"
      "info TEXT NOT NULL DEFAULT '',"
      "sub_last_update INTEGER NOT NULL DEFAULT 0,"
      "front_proxy_id INTEGER NOT NULL DEFAULT -1,"
      "landing_proxy_id INTEGER NOT NULL DEFAULT -1,"
      "column_width_json TEXT NOT NULL DEFAULT '',"
      "scroll_last_profile INTEGER NOT NULL DEFAULT -1,"
      "auto_clear_unavailable INTEGER NOT NULL DEFAULT 0,"
      "test_sort_by INTEGER NOT NULL DEFAULT 0,"
      "traffic_sort_by INTEGER NOT NULL DEFAULT 0,"
      "test_items_to_show INTEGER NOT NULL DEFAULT 0,"
      "type_sort_by INTEGER NOT NULL DEFAULT 0,"
      "sub_options_json TEXT NOT NULL DEFAULT '{}',"
      "sub_metadata_json TEXT NOT NULL DEFAULT '{}',"
      "sort_method INTEGER NOT NULL DEFAULT 0,"
      "sort_descending INTEGER NOT NULL DEFAULT 0,"
      "display_order INTEGER NOT NULL DEFAULT 0,"
      "route_id INTEGER NOT NULL DEFAULT -1,"
      "import_sub_route INTEGER NOT NULL DEFAULT 0)",
  "CREATE TABLE profiles ("
      "id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,"
      "type TEXT NOT NULL,"
      "name TEXT,"
      "gid INTEGER NOT NULL DEFAULT 0,"
      "user_order INTEGER NOT NULL DEFAULT 0,"
      "latency INTEGER NOT NULL DEFAULT 0,"
      "latency_at INTEGER NOT NULL DEFAULT 0,"
      "dl_speed TEXT,"
      "ul_speed TEXT,"
      "test_country TEXT,"
      "ip_out TEXT,"
      "outbound_json TEXT NOT NULL,"
      "traffic_dl INTEGER NOT NULL DEFAULT 0,"
      "traffic_up INTEGER NOT NULL DEFAULT 0,"
      "test_error TEXT,"
      "FOREIGN KEY(gid) REFERENCES groups(id) ON DELETE CASCADE)",
  "CREATE INDEX idx_profiles_gid_user_order_id ON profiles(gid, user_order, id)",
  "CREATE TABLE route_profiles ("
      "id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,"
      "name TEXT NOT NULL DEFAULT '',"
      "default_outbound_id INTEGER NOT NULL DEFAULT -1,"
      "is_remote INTEGER NOT NULL DEFAULT 0,"
      "remote_url TEXT NOT NULL DEFAULT '',"
      "auto_update INTEGER NOT NULL DEFAULT 0,"
      "remote_last_update INTEGER NOT NULL DEFAULT 0,"
      "is_raw INTEGER NOT NULL DEFAULT 0,"
      "raw_route TEXT NOT NULL DEFAULT '',"
      "prevent_modifications INTEGER NOT NULL DEFAULT 0,"
      "endpoint_profile_ids TEXT NOT NULL DEFAULT '[]',"
      "inner_hop_endpoint_ids TEXT NOT NULL DEFAULT '[]',"
      "dns_json TEXT NOT NULL DEFAULT '',"
      "custom_dns INTEGER NOT NULL DEFAULT 0,"
      "source_gid INTEGER NOT NULL DEFAULT -1,"
      "disabled_global_rule_json TEXT NOT NULL DEFAULT '[]')",
  "CREATE TABLE route_rules ("
      "route_profile_id INTEGER NOT NULL,"
      "rule_order INTEGER NOT NULL,"
      "name TEXT NOT NULL DEFAULT '',"
      "type INTEGER NOT NULL DEFAULT 0,"
      "ip_version TEXT NOT NULL DEFAULT '',"
      "network TEXT NOT NULL DEFAULT '',"
      "protocol TEXT NOT NULL DEFAULT '',"
      "inbound_json TEXT NOT NULL DEFAULT '[]',"
      "domain_json TEXT NOT NULL DEFAULT '[]',"
      "domain_suffix_json TEXT NOT NULL DEFAULT '[]',"
      "domain_keyword_json TEXT NOT NULL DEFAULT '[]',"
      "domain_regex_json TEXT NOT NULL DEFAULT '[]',"
      "source_ip_cidr_json TEXT NOT NULL DEFAULT '[]',"
      "source_ip_is_private INTEGER NOT NULL DEFAULT 0,"
      "ip_cidr_json TEXT NOT NULL DEFAULT '[]',"
      "ip_is_private INTEGER NOT NULL DEFAULT 0,"
      "source_port_json TEXT NOT NULL DEFAULT '[]',"
      "source_port_range_json TEXT NOT NULL DEFAULT '[]',"
      "port_json TEXT NOT NULL DEFAULT '[]',"
      "port_range_json TEXT NOT NULL DEFAULT '[]',"
      "process_name_json TEXT NOT NULL DEFAULT '[]',"
      "process_path_json TEXT NOT NULL DEFAULT '[]',"
      "process_path_regex_json TEXT NOT NULL DEFAULT '[]',"
      "package_name_json TEXT NOT NULL DEFAULT '[]',"
      "rule_set_json TEXT NOT NULL DEFAULT '[]',"
      "invert INTEGER NOT NULL DEFAULT 0,"
      "outbound_id INTEGER NOT NULL DEFAULT -2,"
      "action TEXT NOT NULL DEFAULT 'route',"
      "reject_method TEXT NOT NULL DEFAULT '',"
      "no_drop INTEGER NOT NULL DEFAULT 0,"
      "override_address TEXT NOT NULL DEFAULT '',"
      "override_port TEXT NOT NULL DEFAULT '',"
      "sniffers_json TEXT NOT NULL DEFAULT '[]',"
      "sniff_override_dest INTEGER NOT NULL DEFAULT 0,"
      "strategy TEXT NOT NULL DEFAULT '',"
      "wifi_ssid_json TEXT NOT NULL DEFAULT '[]',"
      "wifi_bssid_json TEXT NOT NULL DEFAULT '[]',"
      "tls_spoof TEXT NOT NULL DEFAULT '',"
      "tls_spoof_method TEXT NOT NULL DEFAULT '',"
      "network_type_json TEXT NOT NULL DEFAULT '[]',"
      "network_is_expensive INTEGER NOT NULL DEFAULT 0,"
      "package_name_regex_json TEXT NOT NULL DEFAULT '[]',"
      "tls_fragment INTEGER NOT NULL DEFAULT 0,"
      "tls_fragment_fallback_delay TEXT NOT NULL DEFAULT '',"
      "tls_record_fragment INTEGER NOT NULL DEFAULT 0,"
      "disabled INTEGER NOT NULL DEFAULT 0,"
      "PRIMARY KEY(route_profile_id, rule_order),"
      "FOREIGN KEY(route_profile_id) REFERENCES route_profiles(id) ON DELETE CASCADE)",
  "CREATE TABLE settings (key TEXT NOT NULL, value TEXT NOT NULL, PRIMARY KEY(key))",
  "CREATE TABLE markers (key TEXT NOT NULL, marked_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), PRIMARY KEY(key))",
  "CREATE TABLE global_route_rules ("
      "rule_id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,"
      "rule_order INTEGER NOT NULL,"
      "name TEXT NOT NULL DEFAULT '',"
      "type INTEGER NOT NULL DEFAULT 0,"
      "ip_version TEXT NOT NULL DEFAULT '',"
      "network TEXT NOT NULL DEFAULT '',"
      "protocol TEXT NOT NULL DEFAULT '',"
      "inbound_json TEXT NOT NULL DEFAULT '[]',"
      "domain_json TEXT NOT NULL DEFAULT '[]',"
      "domain_suffix_json TEXT NOT NULL DEFAULT '[]',"
      "domain_keyword_json TEXT NOT NULL DEFAULT '[]',"
      "domain_regex_json TEXT NOT NULL DEFAULT '[]',"
      "source_ip_cidr_json TEXT NOT NULL DEFAULT '[]',"
      "source_ip_is_private INTEGER NOT NULL DEFAULT 0,"
      "ip_cidr_json TEXT NOT NULL DEFAULT '[]',"
      "ip_is_private INTEGER NOT NULL DEFAULT 0,"
      "source_port_json TEXT NOT NULL DEFAULT '[]',"
      "source_port_range_json TEXT NOT NULL DEFAULT '[]',"
      "port_json TEXT NOT NULL DEFAULT '[]',"
      "port_range_json TEXT NOT NULL DEFAULT '[]',"
      "process_name_json TEXT NOT NULL DEFAULT '[]',"
      "process_path_json TEXT NOT NULL DEFAULT '[]',"
      "process_path_regex_json TEXT NOT NULL DEFAULT '[]',"
      "package_name_json TEXT NOT NULL DEFAULT '[]',"
      "rule_set_json TEXT NOT NULL DEFAULT '[]',"
      "invert INTEGER NOT NULL DEFAULT 0,"
      "outbound_id INTEGER NOT NULL DEFAULT -2,"
      "action TEXT NOT NULL DEFAULT 'route',"
      "reject_method TEXT NOT NULL DEFAULT '',"
      "no_drop INTEGER NOT NULL DEFAULT 0,"
      "override_address TEXT NOT NULL DEFAULT '',"
      "override_port TEXT NOT NULL DEFAULT '',"
      "sniffers_json TEXT NOT NULL DEFAULT '[]',"
      "sniff_override_dest INTEGER NOT NULL DEFAULT 0,"
      "strategy TEXT NOT NULL DEFAULT '',"
      "wifi_ssid_json TEXT NOT NULL DEFAULT '[]',"
      "wifi_bssid_json TEXT NOT NULL DEFAULT '[]',"
      "tls_spoof TEXT NOT NULL DEFAULT '',"
      "tls_spoof_method TEXT NOT NULL DEFAULT '',"
      "network_type_json TEXT NOT NULL DEFAULT '[]',"
      "network_is_expensive INTEGER NOT NULL DEFAULT 0,"
      "package_name_regex_json TEXT NOT NULL DEFAULT '[]',"
      "tls_fragment INTEGER NOT NULL DEFAULT 0,"
      "tls_fragment_fallback_delay TEXT NOT NULL DEFAULT '',"
      "tls_record_fragment INTEGER NOT NULL DEFAULT 0,"
      "disabled INTEGER NOT NULL DEFAULT 0)",
];

/// Seeds a representative legacy database: two groups, three nodes, a route
/// profile with one rule, settings rows (selection + device-local) and a
/// marker. Nothing in the backup data plane reads it any more; it is the raw
/// reader's fixture.
void seedRoom(SqliteDatabase db) {
  void group(int id, String name, String url, int order) => db.execute(
      'INSERT INTO groups (id, name, url, display_order) VALUES (?, ?, ?, ?)',
      <Object?>[id, name, url, order]);
  void profile(int id, String type, String name, int gid, int order) =>
      db.execute(
          'INSERT INTO profiles (id, type, name, gid, user_order, outbound_json) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          <Object?>[id, type, name, gid, order, '{}']);
  void setting(String key, String value) => db.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?)', <Object?>[key, value]);

  group(1, 'Default', '', 1);
  group(2, 'Sub', 'https://example.test', 2);
  profile(1, 'socks', 'node-a', 1, 0);
  profile(2, 'http', 'node-b', 1, 1);
  profile(3, 'trojan', 'node-c', 2, 0);
  db.execute('INSERT INTO route_profiles (id, name) VALUES (?, ?)', <Object?>[1, 'Default']);
  db.execute(
      'INSERT INTO route_rules (route_profile_id, rule_order, name, protocol, action) '
      'VALUES (?, ?, ?, ?, ?)',
      <Object?>[1, 0, 'Route DNS', 'dns', 'hijack-dns']);
  setting('current_group', '1');
  setting('current_route_id', '1');
  setting('profileId', '2');
  setting('profileCurrent', '2');
  setting('inbound_address', '127.0.0.1');
  setting('remote_dns', 'https://8.8.8.8/dns-query');
  setting('webdavServer', 'https://private.test/');
  setting('deviceId', 'this-device');
  db.execute('INSERT INTO markers (key, marked_at) VALUES (?, ?)', <Object?>['seen-1', 1700000000]);
}

ProfilesDocument sampleDocument() => ProfilesDocument(
      nextProfileId: 5,
      nextGroupId: 3,
      groups: [
        ConfigurationRow(id: 1, name: 'Default', displayOrder: 1),
        ConfigurationRow(id: 2, name: 'Sub', url: 'https://example.test', displayOrder: 2),
      ],
      profiles: [
        NodeRow(id: 1, type: 'socks', name: 'node-a', gid: 1, userOrder: 0, outboundJson: '{}'),
        NodeRow(
            id: 4,
            type: 'vless',
            name: 'dart-only',
            gid: 1,
            userOrder: 1,
            outboundJson: '{"type":"vless"}'),
        NodeRow(id: 3, type: 'trojan', name: 'node-c', gid: 2, userOrder: 0, outboundJson: '{}'),
      ],
    );

/// The pre-restore catalog the rollback tests put on disk: the names are
/// distinct from [sampleDocument]'s, so a half-applied restore is visible.
ProfilesDocument oldCatalogDocument() => ProfilesDocument(
      nextProfileId: 2,
      nextGroupId: 2,
      profiles: [
        NodeRow(
            id: 1,
            type: 'socks',
            name: 'old-node',
            gid: 1,
            userOrder: 0,
            outboundJson: '{}'),
      ],
      groups: [ConfigurationRow(id: 1, name: 'Old', displayOrder: 1)],
    );

/// The production document location for a fixture: `<app>/files/documents/`
/// `profiles.json`, derived from the same layout
/// [documentsDirFromDatabasePath] uses. A fresh [ConfigurationStore] per call reads
/// what the restore wrote.
ConfigurationStore documentStore(String databasePath) => ConfigurationStore(
    path: '${documentsDirFromDatabasePath(databasePath)}/$profilesFileName');

/// The document a restore left on disk. Throws when the file is absent, which
/// is the assertion most callers want anyway.
Future<ProfilesDocument> restoredDocument(String databasePath) =>
    documentStore(databasePath).readFresh();

/// The settings/markers documents as the host holds them (SettingsJsonStore).
/// The merge emulation mirrors `BboxRoomSnapshot.restoreSettings` — the Kotlin
/// unit test pins the real rules; this keeps the Dart roundtrip tests honest.
class BackupSink {
  BackupSink({
    Map<String, String>? settings,
    List<Map<String, Object?>>? markers,
  })  : settings = Map<String, String>.from(settings ?? const <String, String>{}),
        markers = [
          for (final row in markers ?? const <Map<String, Object?>>[])
            Map<String, Object?>.from(row),
        ];

  Map<String, String> settings;
  List<Map<String, Object?>> markers;
  int settingsRestores = 0;
  int markerRestores = 0;
  int settingsSnapshots = 0;
  int markerSnapshots = 0;

  Map<String, String> snapshotSettings() {
    settingsSnapshots++;
    return Map<String, String>.from(settings);
  }

  List<SqlRow> snapshotMarkers() {
    markerSnapshots++;
    return [for (final row in markers) Map<String, Object?>.from(row)];
  }

  List<String> restoreSettings(SettingsRestore request) {
    settingsRestores++;
    final warnings = <String>[];
    final incoming = request.settings;
    final next = Map<String, String>.from(settings);
    if (incoming != null) {
      for (final key in next.keys.toList()) {
        if (backupDeviceLocalKeys.contains(key)) continue;
        if (!request.fromAndroid && backupAndroidKeys.contains(key)) continue;
        if (!incoming.containsKey(key)) next.remove(key);
      }
      incoming.forEach((key, value) {
        if (backupDeviceLocalKeys.contains(key)) return;
        if (!request.fromAndroid && backupAndroidKeys.contains(key)) {
          next.putIfAbsent(key, () => value);
          return;
        }
        next[key] = value;
      });
    }
    final groupIds = request.groupIds;
    if (groupIds != null) {
      final current = int.tryParse((next['current_group'] ?? '').trim());
      if (current == null || !groupIds.contains(current)) {
        if (groupIds.isEmpty) {
          next.remove('current_group');
        } else {
          next['current_group'] = groupIds.first.toString();
        }
      }
    }
    final profileIds = request.profileIds?.toSet();
    if (profileIds != null) {
      if (incoming != null && request.restoredProfiles && !request.fromAndroid) {
        final remember = int.tryParse((incoming['remember_id'] ?? '').trim());
        if (remember != null && profileIds.contains(remember)) {
          next['profileId'] = remember.toString();
          next['profileCurrent'] = remember.toString();
        }
      }
      for (final key in const ['profileId', 'profileCurrent']) {
        final id = int.tryParse((next[key] ?? '').trim());
        if (id != null && id > 0 && !profileIds.contains(id)) next.remove(key);
      }
    }
    final routeIds = request.routeIds;
    if (routeIds != null) {
      final current = int.tryParse((next['current_route_id'] ?? '').trim());
      if (current == null || !routeIds.contains(current)) {
        if (routeIds.isEmpty) {
          next.remove('current_route_id');
        } else {
          next['current_route_id'] = routeIds.first.toString();
        }
      }
    }
    final inbound = incoming?['inbound_address']?.trim();
    if (inbound != null && inbound.isNotEmpty && inbound != '127.0.0.1') {
      next['inbound_address'] = '127.0.0.1';
      warnings.add('The backup lets other devices connect (inbound address $inbound); '
          'this was turned off. Turn it on again in the inbound settings if you need it.');
    }
    settings = next;
    return warnings;
  }

  void restoreMarkers(List<SqlRow> rows) {
    markerRestores++;
    markers = [for (final row in rows) Map<String, Object?>.from(row)];
  }
}

/// The production environment for a fixture path: the profiles document is the
/// file on disk (as in `box_api.dart`), and the settings/markers seams go
/// through [BackupSink] (the host documents' stand-in).
BackupEnvironment envFor(
  String path, {
  BackupSink? sink,
  void Function(ProfilesDocument doc)? onRestored,
  Map<String, Object?>? preferences,
}) {
  final documents = sink ?? BackupSink();
  return BackupEnvironment(
    databasePath: path,
    appVersion: 'test',
    deviceId: 'test-device',
    deviceName: 'Test',
    defaultGroupName: 'Default',
    // The live preferences document holds launch bookkeeping
    // (`BootGuard.preferenceKey`) as well as user-facing keys; a backup must
    // carry only the latter. The real value rides along here so every
    // export/restore case also exercises the device-local filter.
    preferences: preferences ??
        const <String, Object?>{
          'theme': 'system',
          'bootGuardRecord':
              '{"stage":"starting","startedAt":1,"failureCount":0}',
        },
    settingsDocument: const <String, Object?>{'fontSize': 14},
    qualityDocument: const <String, Object?>{},
    // ADR 0006 stage B: the document is a restore's only profiles sink, so
    // the fixture writes the real file (the atomic temp+rename writer).
    profileDocument: () async {
      final store = documentStore(path);
      return await store.exists() ? await store.readFresh() : null;
    },
    applyRestoredProfiles: (doc) async {
      await documentStore(path).replaceAll(doc);
      onRestored?.call(doc);
    },
    settingsSnapshot: () async => documents.snapshotSettings(),
    markersSnapshot: () async => documents.snapshotMarkers(),
    restoreSettings: (request) async => documents.restoreSettings(request),
    restoreMarkers: (rows) async => documents.restoreMarkers(rows),
  );
}
