// Dart backup write-path tests (ADR 0005 phase 4). A synthetic Room file is
// created with the low-level dart:ffi SQLite, exported to THRN by createBackup,
// and restored by restoreBackup. Every case that the native BackupExport /
// BackupRestore handled is pinned here: roundtrip, id counters, settings merge,
// the empty database, a damaged container and an old (v1) container.
//
// On Android/CI `libsqlite3.so` is present, so Sqlite.open() works directly. On
// a Windows host it is not; set BACKUP_TEST_SQLITE to a sqlite3.dll absolute path
// to run these tests there (see the task handoff for the local path).

import 'dart:convert';
import 'dart:io';

import 'package:flrone/data/profile_store.dart'
    show GroupRow, ProfileRow, ProfilesDocument;
import 'package:flrone/data/sqlite.dart' show Sqlite;
import 'package:flrone/services/backup_store.dart'
    show thrnDecode, thrnEncode, thrnAndroidMeta, ThrnParts;
import 'package:flrone/services/backup_write.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/backup_fixture.dart';

Sqlite? _sqlite;
String? get _hostPath => Platform.environment['BACKUP_TEST_SQLITE'];

Sqlite _openSqlite() {
  final cached = _sqlite;
  if (cached != null) return cached;
  final path = _hostPath;
  final sqlite = path == null ? Sqlite.open() : Sqlite.openPath(path);
  if (sqlite == null) {
    throw StateError(
        'No sqlite3 available for the backup write tests. For a host without '
        'libsqlite3.so, set BACKUP_TEST_SQLITE to a sqlite3.dll path.');
  }
  return _sqlite = sqlite;
}

String? scalar(RoomFixture f, String sql, [List<Object?> params = const []]) {
  final db = f.open(readOnly: true);
  try {
    final rows = db.query(sql, params);
    if (rows.isEmpty) return null;
    return '${rows.first.values.first}';
  } finally {
    db.close();
  }
}

List<Object?> column(RoomFixture f, String sql) {
  final db = f.open(readOnly: true);
  try {
    return db.query(sql).map((row) => row.values.first).toList();
  } finally {
    db.close();
  }
}

Future<BackupEnvironment> backupThenRestore(
  RoomFixture f, {
  String scope = 'all',
  String strategy = 'Compatible',
  void Function(RoomFixture f)? mutateBeforeRestore,
  List<String>? warningsSink,
  Map<String, Object?>? uiSink,
  int? refreshed,
}) async {
  final env = envFor(f.path);
  final envelope = await createBackup(env: env, scope: scope, sqlite: _openSqlite());
  final encoded = envelope['thr'] as String;
  if (mutateBeforeRestore != null) mutateBeforeRestore(f);
  final result = await restoreBackup(
    env: env,
    bytes: base64Decode(encoded),
    scope: scope,
    strategy: strategy,
    sqlite: _openSqlite(),
    refresh: () => refreshed = (refreshed ?? 0) + 1,
  );
  warningsSink?.addAll(result.warnings);
  uiSink?.addAll(result.ui);
  return env;
}

void main() {
  group('Dart backup write path (Room -> THRN -> Room)', () {
    test('export reads the Dart document, not stale Room, and restore writes it back', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);

      // Dart holds a profile Room has never seen: a newly created node that
      // only reached the document (Room is no longer written).
      final doc = ProfilesDocument(
        nextProfileId: 5,
        nextGroupId: 3,
        groups: [GroupRow(id: 1, name: 'Default', displayOrder: 1)],
        profiles: [
          ProfileRow(id: 1, type: 'socks', name: 'node-a', gid: 1, userOrder: 0, outboundJson: '{}'),
          ProfileRow(id: 4, type: 'vless', name: 'dart-only', gid: 1, userOrder: 1, outboundJson: '{"type":"vless"}'),
        ],
      );
      ProfilesDocument? restoredInto;
      final env = BackupEnvironment(
        databasePath: source.path,
        appVersion: 'test', deviceId: 'd', deviceName: 'D', defaultGroupName: 'Default',
        preferences: const <String, Object?>{}, settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () async => doc,
        applyRestoredProfiles: (d) async => restoredInto = d,
      );
      final envelope = await createBackup(env: env, scope: 'profiles', sqlite: _openSqlite());

      // The preview and the embedded snapshot both carry the Dart-only node.
      expect(envelope['profiles'], hasLength(1));
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      final tmp = await Directory.systemTemp.createTemp('thrn-dart-doc-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/snapshot.db';
      File(path).writeAsBytesSync(decoded.database!);
      final edb = _openSqlite().openDatabase(path, readOnly: true)!;
      try {
        expect(edb.query('SELECT COUNT(*) FROM profiles').first.values.first, 2);
        expect(edb.query("SELECT name FROM profiles WHERE id = 4").first.values.first, 'dart-only');
      } finally {
        edb.close();
      }

      // A restore into the empty Room rewrites the Dart document so the UI
      // does not keep showing the pre-restore catalog.
      await restoreBackup(
        env: BackupEnvironment(
          databasePath: target.path,
          appVersion: 'test', deviceId: 'd', deviceName: 'D', defaultGroupName: 'Default',
          preferences: const <String, Object?>{}, settingsDocument: const <String, Object?>{},
          qualityDocument: const <String, Object?>{},
          applyRestoredProfiles: (d) async => restoredInto = d,
        ),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles', strategy: 'Override', sqlite: _openSqlite(),
      );
      expect(restoredInto, isNotNull);
      expect(restoredInto!.profiles.map((p) => p.name), contains('dart-only'));
    });

    test('create -> restore roundtrip keeps groups, nodes, route rules and settings', () async {
      final f = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(f.dispose);
      final envelope = await createBackup(
          env: envFor(f.path), scope: 'all', sqlite: _openSqlite());

      // Envelope shape is unchanged: the page's confirmation and the WebDAV
      // transport read exactly these keys.
      expect(envelope['format'], 2);
      expect(envelope['scope'], 'all');
      expect((envelope['profiles'] as List).length, 2);
      expect(base64Decode(envelope['thr'] as String).sublist(0, 4),
          equals(const <int>[0x54, 0x48, 0x52, 0x4E]));
      final ui = envelope['ui'] as Map;
      expect(ui['preferences'], {'theme': 'system'});
      expect(ui['settings'], {'fontSize': 14});
      // The WebDAV account never enters a backup.
      expect(ui['preferences'].containsKey('webdavAccount'), isFalse);

      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      expect(decoded.parts.profiles, isTrue);
      expect(decoded.parts.routes, isTrue);
      expect(decoded.parts.settings, isTrue);
      final embedded = decoded.database!;
      final tmp = await Directory.systemTemp.createTemp('thrn-check-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final embeddedPath = '${tmp.path}/snapshot.db';
      File(embeddedPath).writeAsBytesSync(embedded);
      final edb = _openSqlite().openDatabase(embeddedPath, readOnly: true)!;
      try {
        expect(edb.query('SELECT COUNT(*) FROM profiles').first.values.first, 3);
        expect(edb.query('SELECT COUNT(*) FROM groups').first.values.first, 2);
        expect(edb.query('SELECT COUNT(*) FROM groups_order').first.values.first, 2);
        expect(edb.query('SELECT COUNT(*) FROM route_rules').first.values.first, 1);
        // The desktop mapping keeps ids and dense orders.
        expect(edb.query('SELECT profiles_json FROM groups WHERE id = 1').first.values.first,
            '[1,2]');
        expect(edb.query('SELECT profiles_json FROM groups WHERE id = 2').first.values.first,
            '[3]');
        // device-local keys never leave the phone.
        expect(edb.query("SELECT COUNT(*) FROM settings WHERE key = 'webdavServer'")
            .first.values.first, 0);
        expect(edb.query("SELECT value FROM settings WHERE key = 'remember_id'")
            .first.values.first, '2');
        // The desktop counters never go below the ids in use.
        final counters = edb.query('SELECT * FROM entity_ids').first;
        expect(counters['profile_last_id'], greaterThanOrEqualTo(3));
        expect(counters['group_last_id'], greaterThanOrEqualTo(2));
      } finally {
        edb.close();
      }
    });

    test('restore into an empty room rebuilds all parts and refreshes', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(env: env, scope: 'all', sqlite: _openSqlite());
      var refreshCount = 0;
      final warnings = <String>[];
      final result = await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
        refresh: () => refreshCount++,
      );
      warnings.addAll(result.warnings);

      expect(refreshCount, 1);
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '2');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_profiles'), '1');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_rules'), '1');
      expect(column(target, 'SELECT id FROM profiles ORDER BY id'), [1, 2, 3]);
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'current_group'"), '1');
    });

    test('id conflict: ids are kept but sqlite_sequence is raised, never lowered', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {
        // Source used ids 10, 11, 12 with a high-water mark of 12.
        seedRoom(db);
        db.execute('UPDATE profiles SET id = 10 WHERE id = 1');
        db.execute('UPDATE profiles SET id = 11 WHERE id = 2');
        db.execute('UPDATE profiles SET id = 12 WHERE id = 3');
        db.execute('UPDATE groups SET id = 10 WHERE id = 1');
        db.execute('UPDATE groups SET id = 20 WHERE id = 2');
        db.execute('UPDATE profiles SET gid = 10 WHERE gid = 1');
        db.execute('UPDATE profiles SET gid = 20 WHERE gid = 2');
        db.execute("INSERT INTO sqlite_sequence (name, seq) VALUES ('profiles', 12)");
        db.execute("INSERT INTO sqlite_sequence (name, seq) VALUES ('groups', 20)");
      });
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(env: env, scope: 'all', sqlite: _openSqlite());
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );

      // The backup's ids win (replace-keeping-ids), and the target's counter was
      // 3 before; raising it to 12 stops reused ids from being handed out again.
      expect(column(target, 'SELECT id FROM profiles ORDER BY id'), [10, 11, 12]);
      final seq = column(target, "SELECT seq FROM sqlite_sequence WHERE name = 'profiles'");
      expect(seq, [12]);
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'profileId'"), null);
    });

    test('settings merge keeps device-local rows and repairs dangling selections', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {
        seedRoom(db);
        db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('deviceId', 'kept-device')");
        db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('wifiPermissionAsked', 'true')");
        db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('runningProfiles', '9')");
      });
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(env: env, scope: 'all', sqlite: _openSqlite());
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );

      // Device-local rows are untouched by the restore.
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'deviceId'"), 'kept-device');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'wifiPermissionAsked'"), 'true');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'webdavServer'"),
          'https://private.test/');
      // A desktop backup keeps Android-only rows the phone already has.
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'runningProfiles'"), '9');
      // Selection keys name existing rows after the merge.
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'current_group'"), isNotNull);
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'current_route_id'"), isNotNull);
    });

    test('profiles-only scope does not touch routes or settings', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {
        seedRoom(db);
        db.execute("INSERT INTO route_profiles (id, name) VALUES (99, 'Only mine')");
        db.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('remote_dns', 'mine')");
      });
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(
          env: env, scope: 'profiles', sqlite: _openSqlite());
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      expect(decoded.parts.routes, isFalse);
      expect(decoded.parts.settings, isFalse);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      // The target's extra route profile survives (routes part not restored).
      expect(column(target, 'SELECT id FROM route_profiles ORDER BY id'), contains(99));
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'remote_dns'"), 'mine');
    });

    test('an empty database exports cleanly and restores the default group/route', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(env: env, scope: 'all', sqlite: _openSqlite());
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '1');
      expect(scalar(target, "SELECT name FROM groups WHERE id = (SELECT MIN(id) FROM groups)"), 'Default');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_profiles WHERE is_raw = 0'), '1');
      expect(scalar(target, "SELECT name FROM route_profiles WHERE is_raw = 0"), 'Default');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_rules'), '1');
    });

    test('table repair: orphan profiles are moved and untabbed groups get an order', () async {
      // Build a desktop-shaped snapshot with a group that has no groups_order
      // row and a profile whose gid names no group, but whose id appears in that
      // group's profiles_json. Restore must repair both and emit warnings.
      final dir = await Directory.systemTemp.createTemp('thrn-repair-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/malformed.db';
      final db = _openSqlite().openDatabase(path, readOnly: false)!;
      for (final sql in backupDesktopDdl) {
        db.execute(sql);
      }
      db.execute("INSERT INTO groups (id, name) VALUES (1, 'Only')");
      // No groups_order row: group 1 is "untabbed".
      db.execute("INSERT INTO profiles (id, type, name, gid, outbound_json) VALUES (7, 'socks', 'orphan', 999, '{}')");
      db.execute("UPDATE groups SET profiles_json = '[7]' WHERE id = 1");
      db.execute("INSERT INTO entity_ids (profile_last_id, group_last_id, route_profile_last_id, otp_profile_last_id) VALUES (7, 1, 0, 0)");
      db.close();
      final embedded = File(path).readAsBytesSync();
      final container = thrnEncode(
        thrnAndroidMeta(
          parts: const ThrnParts(profiles: true, routes: false, settings: false),
          appVersion: 'x', deviceId: 'x', deviceName: 'x', createdAt: 'x',
        ),
        {'database': embedded},
      );
      final target = await RoomFixture.create(_openSqlite(), seed: (d) {});
      addTearDown(target.dispose);
      final result = await restoreBackup(
        env: envFor(target.path),
        bytes: container,
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      // The orphan was moved into group 1 (via profiles_json), not dropped.
      expect(column(target, 'SELECT gid FROM profiles WHERE id = 7'), [1]);
      expect(result.warnings, contains(matches(RegExp(r'profiles whose group is missing were moved'))));
      expect(result.warnings, contains(matches(RegExp(r'groups without a tab position were added'))));
    });

    test('a damaged container is refused before touching Room', () async {
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      final before = scalar(target, 'SELECT COUNT(*) FROM profiles');
      final bytes = thrnEncode(
        thrnAndroidMeta(
          parts: const ThrnParts(profiles: true, routes: true, settings: true),
          appVersion: 'x',
          deviceId: 'x',
          deviceName: 'x',
          createdAt: 'x',
        ),
        {'database': utf8.encode('SQLite format 3\u0000')},
      );
      // Truncate the payload: the decoder must fail with a corrupt-container error.
      final damaged = bytes.sublist(0, bytes.length - 5);
      expect(
        () async => restoreBackup(
          env: envFor(target.path),
          bytes: damaged,
          scope: 'all',
          strategy: 'Override',
          sqlite: _openSqlite(),
        ),
        throwsA(isA<Exception>()),
      );
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), before);
    });

    test('an old (v1) container without parts restores every database part', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(env: env, scope: 'all', sqlite: _openSqlite());
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      // Re-encode as v1 (no parts object): composition falls back to "all parts".
      final v1 = thrnEncode(
        {'platform': 'android', 'created_at': 'old'},
        {'database': decoded.database!},
        version: 1,
      );
      await restoreBackup(
        env: envFor(target.path),
        bytes: v1,
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_rules'), '1');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'remote_dns'"),
          isNotNull);
    });

    test('desktop DDL and column mapping match the Kotlin DesktopSchema contract', () {
      // Fidelity guard: BackupExport.kt copies each of these tables by column
      // name into DesktopSchema's DDL. A drift in either list is silent data
      // loss, so pin the exact counts and the derived/extension columns.
      expect(backupDesktopDdl, hasLength(11)); // 9 CREATE + 1 ALTER + 1 index
      expect(backupDesktopColumns('profiles'), containsAll(['latency_at', 'outbound_json', 'traffic_dl']));
      expect(backupDesktopColumns('profiles'), hasLength(15));
      expect(backupDesktopColumns('groups'), containsAll(['profiles_json', 'route_id', 'sub_metadata_json', 'sort_method']));
      expect(backupDesktopColumns('groups'), hasLength(25));
      expect(backupDesktopColumns('route_profiles'), containsAll(['dns_json', 'custom_dns', 'source_gid', 'is_raw']));
      expect(backupDesktopColumns('route_profiles'), hasLength(17));
      // route_rules ends with Android-only columns, which a desktop restore
      // treats as unsupported-field repairs.
      expect(backupDesktopColumns('route_rules'), hasLength(46));
      expect(backupDesktopColumns('route_rules'), containsAll([
        'network_type_json', 'network_is_expensive', 'package_name_regex_json',
        'tls_fragment', 'tls_record_fragment', 'disabled',
      ]));
      expect(backupDesktopColumns('settings'), ['key', 'value']);
      expect(backupDesktopColumns('markers'), ['key', 'marked_at']);
    });

    test('a container whose parts do not match the scope exports a useful warning set', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(
          env: env, scope: 'profiles', sqlite: _openSqlite());
      final warnings = <String>[];
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      ).then((r) => warnings.addAll(r.warnings));
      // A profiles-only backup still restores profiles into the empty target.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(warnings, isA<List<String>>());
    });
  });
}
