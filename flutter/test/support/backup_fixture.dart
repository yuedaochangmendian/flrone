// A synthetic Room (`sager_net.db`) for the backup write-path tests. The DDL
// mirrors SagerDatabase v20's seven tables; enough columns are present to
// exercise the export/restore mapping, counters and settings merge without a
// device or the Kotlin runtime.

import 'dart:io';

import 'package:flrone/data/sqlite.dart' show Sqlite, SqliteDatabase;
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

/// Seeds a representative Room database: two groups, three nodes, a route
/// profile with one rule, and the settings keys that exercise selection repair.
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
}

BackupEnvironment envFor(String path) => BackupEnvironment(
      databasePath: path,
      appVersion: 'test',
      deviceId: 'test-device',
      deviceName: 'Test',
      defaultGroupName: 'Default',
      preferences: const <String, Object?>{'theme': 'system'},
      settingsDocument: const <String, Object?>{'fontSize': 14},
      qualityDocument: const <String, Object?>{},
    );
