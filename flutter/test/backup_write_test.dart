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
    show GroupRow, ProfileRow, ProfilesDocument, documentsDirFromDatabasePath;
import 'package:flrone/services/route_documents.dart';
import 'package:flrone/data/sqlite.dart' show Sqlite;
import 'package:flrone/services/backup_store.dart'
    show thrnDecode, thrnEncode, thrnAndroidMeta, ThrnParts;
import 'package:flrone/services/backup_write.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/backup_fixture.dart';
import 'support/fake_room_host.dart' show FakeRoomHost;
import 'package:flrone/services/room_snapshot_host.dart' show RoomSnapshotHost;

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
      expect(backupDesktopDdl, hasLength(12)); // 10 CREATE + 1 ALTER + 1 index
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
      expect(backupDesktopColumns('global_route_rules'), containsAll(['rule_id', 'rule_order', 'action']));
      expect(backupDesktopColumns('global_route_rules'), hasLength(46));
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

  group('P14 host-backed Room path (no app-side SQLite)', () {
    // On a stock Android device `Sqlite.open()` answers null: the app may only
    // dlopen public.libraries.txt entries and AOSP has no libsqlite3.so. These
    // tests pass a mock RoomSnapshotHost and NO `sqlite` so create/restore take
    // the host branch; the mock emulates BboxRoomSnapshot over real SQL.
    //
    // The resolver is forced to null for the group: CI runs on Linux, where
    // libsqlite3.so exists, so leaving the real resolver in place made the ffi
    // path win and the host callbacks never run (expected 1, actual 0).
    setUp(() => resolveBackupSqlite = () => null);
    tearDown(() => resolveBackupSqlite = Sqlite.open);

    test('create takes the host path when ffi is unavailable and keeps the envelope shape', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final host = FakeRoomHost(_openSqlite(), roomPath: source.path).toHost();
      var snapshotCalls = 0;
      final env = BackupEnvironment(
        databasePath: source.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{'theme': 'system'},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        roomSnapshot: (profiles, groups) async {
          snapshotCalls++;
          // Delegate to the fake host's DAO-read emulation.
          return host.roomSnapshot(profiles: profiles, groups: groups);
        },
      );

      // No sqlite injected -> Sqlite.open() is null on this host -> host branch.
      final envelope = await createBackup(env: env, scope: 'all', host: host);

      expect(snapshotCalls, 1);
      expect(envelope['format'], 2);
      expect(envelope['scope'], 'all');
      expect((envelope['profiles'] as List).length, 2);
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      expect(decoded.parts.profiles, isTrue);
      expect(decoded.parts.routes, isTrue);
      expect(decoded.parts.settings, isTrue);
      // The embedded snapshot is a real SQLite DB with the expected rows.
      final tmp = await Directory.systemTemp.createTemp('thrn-host-check-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final path = '${tmp.path}/snapshot.db';
      File(path).writeAsBytesSync(decoded.database!);
      final edb = _openSqlite().openDatabase(path, readOnly: true)!;
      try {
        expect(edb.query('SELECT COUNT(*) FROM profiles').first.values.first, 3);
        expect(edb.query('SELECT COUNT(*) FROM groups').first.values.first, 2);
        expect(edb.query('SELECT COUNT(*) FROM route_rules').first.values.first, 1);
      } finally {
        edb.close();
      }
    });

    test('restore takes the host path, commits via data.applyRoomSnapshot and writes back the Dart document', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);

      // Create over the ffi path (desktop reference) to get a container.
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      ProfilesDocument? restoredDoc;
      var applied = 0;
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        applyRestoredProfiles: (d) async {
          restoredDoc = d;
          // Production writes the document via ProfileStore.replaceAll; here we
          // only assert the doc was rebuilt from committed rows.
        },
        applyRoomSnapshot: (rows) async {
          applied++;
          // Delegate the transactional commit to the fake host's emulation.
          return host.applyRoomSnapshot(rows);
        },
      );

      await restoreBackup(
        env: env,
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        host: host,
      );

      expect(applied, 1);
      // Room (the target file the fake host wrote) holds the restored rows.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '2');
      // The Dart-owned document was rebuilt from the committed rows.
      expect(restoredDoc, isNotNull);
      expect(restoredDoc!.profiles.map((p) => p.name), contains('node-a'));
    });

    test('host restore keeps the committed Room rows and warns when the Dart document writeback fails', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);

      // Create over the ffi path (desktop reference) to get a container.
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      var applied = 0;
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        applyRestoredProfiles: (d) async {
          // The Room commit already happened; a failure here must degrade to a
          // warning, not abort the whole restore or roll Room back.
          throw StateError('disk full');
        },
        applyRoomSnapshot: (rows) async {
          applied++;
          return host.applyRoomSnapshot(rows);
        },
      );

      // Must return normally, not throw.
      final result = await restoreBackup(
        env: env,
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        host: host,
      );

      expect(applied, 1);
      // Room's committed rows survived the document writeback failure.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '2');
      // A single, explicit Chinese warning reaches the UI's warnings->banner path.
      expect(result.warnings.length, 1);
      expect(result.warnings.first, contains('配置文档写回失败'));
      expect(result.warnings.first, contains('disk full'));
    });

    test('host wire exposes the three data.* methods with the expected keys', () async {
      // A focused shape test: record the method + arg keys the host layer sends,
      // returning minimal well-shaped replies. This pins the wire contract that
      // Kotlin's BboxRoomSnapshot handlers must honor.
      final seen = <String, Set<String>>{};
      final wrapped = RoomSnapshotHost(call: (method, [args]) async {
        seen[method] = (args is Map) ? args.keys.map((k) => '$k').toSet() : <String>{};
        if (method == 'data.roomSnapshot') {
          return <String, dynamic>{
            'profiles': <dynamic>[], 'groups': <dynamic>[],
            'routeProfiles': <dynamic>[], 'routeRules': <dynamic>[],
            'settings': <dynamic>[], 'markers': <dynamic>[],
          };
        }
        if (method == 'data.applyRoomSnapshot') {
          return <String, dynamic>{'profiles': <dynamic>[], 'groups': <dynamic>[]};
        }
        return null;
      });

      await wrapped.roomSnapshot(
        profiles: const <Map<String, Object?>>[],
        groups: const <Map<String, Object?>>[],
      );
      await wrapped.applyRoomSnapshot(<String, Object?>{
        'doProfiles': true,
        'doRoutes': true,
        'doSettings': true,
        'profiles': <String, Object?>{'columns': <String>[], 'rows': <dynamic>[]},
        'groups': <String, Object?>{'columns': <String>[], 'rows': <dynamic>[]},
      });

      expect(seen.containsKey('data.roomSnapshot'), isTrue);
      expect(seen['data.roomSnapshot'], containsAll(['profiles', 'groups']));
      expect(seen.containsKey('data.applyRoomSnapshot'), isTrue);
      expect(seen['data.applyRoomSnapshot'],
          containsAll(['doProfiles', 'doRoutes', 'doSettings', 'profiles', 'groups']));
    });

    test('routes back up from the kernel documents and restore into them', () async {
      // ADR 0006 stage A: the live route store is the kernel's documents; the
      // Room route table freezes at the migration hand-over. A backup must not
      // export that freeze, and a restore must land where the app reads.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final sourceDocs =
          RouteDocuments(Directory(documentsDirFromDatabasePath(source.path)));
      sourceDocs.restore(
        profiles: [
          {'id': 42, 'name': 'kernel-only', 'is_raw': 0, 'source_gid': 3},
        ],
        rules: [
          {'route_profile_id': 42, 'rule_order': 0, 'name': 'kernel-rule'},
        ],
        profilesRestored: true,
      );

      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      final tmp = await Directory.systemTemp.createTemp('thrn-routes-');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final snapshotPath = '${tmp.path}/snapshot.db';
      File(snapshotPath).writeAsBytesSync(decoded.database!);
      final embedded = _openSqlite().openDatabase(snapshotPath, readOnly: true)!;
      try {
        // The embedded snapshot carries the documents' rows — Room's frozen
        // 'Default' row never enters the container.
        final names = embedded
            .query('SELECT name FROM route_profiles ORDER BY id')
            .map((row) => row.values.first)
            .toList();
        expect(names, contains('kernel-only'));
        expect(names, isNot(contains('Default')));
      } finally {
        embedded.close();
      }

      // Restore onto another device: the documents are replaced wholesale.
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      final targetDocs =
          RouteDocuments(Directory(documentsDirFromDatabasePath(target.path)));
      targetDocs.writeTable('route_profiles', [
        {'id': 1, 'name': 'stale', '__current': true},
      ]);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      final restored = targetDocs.readTable('route_profiles');
      expect(restored.map((row) => row['name']), contains('kernel-only'));
      expect(restored.any((row) => row['name'] == 'stale'), isFalse);
      // Both sides of the backup come from one restore, so the reference the
      // routes keep into the groups survives the round trip.
      expect(restored.singleWhere((row) => row['id'] == 42)['source_gid'], 3);
    });

    test('a profiles-only restore clears the surviving routes source_gid', () async {
      // One-sided semantics moved to the documents: the surviving routes point
      // into groups the restore just replaced (the old Room resetSourceGids
      // ran against tables the app no longer reads).
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final docs =
          RouteDocuments(Directory(documentsDirFromDatabasePath(source.path)));
      docs.writeTable('route_profiles', [
        {'id': 5, 'name': 'kept', 'is_raw': 0, 'source_gid': 2},
      ]);
      docs.writeTable('route_rules', const []);

      final envelope = await createBackup(
          env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      await restoreBackup(
        env: envFor(source.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      final kept = docs.readTable('route_profiles');
      expect(kept.single['name'], 'kept');
      expect(kept.single['source_gid'], -1);
    });

    test('the global added-rules pool round-trips through the backup', () async {
      // The pool was never staged before ADR 0006's follow-up: a backup
      // silently lost the user's global rules and a restore never brought
      // them back.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final sourceDocs =
          RouteDocuments(Directory(documentsDirFromDatabasePath(source.path)));
      sourceDocs.restore(
        profiles: [
          {'id': 1, 'name': 'Home', 'is_raw': 0},
        ],
        rules: const [],
        profilesRestored: true,
        globalRules: [
          {'rule_id': 1, 'rule_order': 0, 'name': 'global-a', 'action': 'hijack-dns'},
        ],
      );

      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      final targetDocs =
          RouteDocuments(Directory(documentsDirFromDatabasePath(target.path)));
      targetDocs.writeTable('global_route_rules', [
        {'rule_id': 9, 'name': 'stale-global'},
      ]);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      final global = targetDocs.readTable('global_route_rules');
      expect(global.single['name'], 'global-a');
      expect(global.single['action'], 'hijack-dns');
    });

    test('a profiles-only restore clears the groups route_id in the document', () async {
      // ADR 0006 stage B: the document is rebuilt straight from the staged
      // rows and carries the one-sided cleanup the Room commit used to own —
      // the groups name routes that were not restored.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final doc = ProfilesDocument(
        nextProfileId: 3,
        nextGroupId: 3,
        groups: [GroupRow(id: 1, name: 'Default', displayOrder: 1, routeId: 5)],
        profiles: [
          ProfileRow(
              id: 1,
              type: 'socks',
              name: 'node',
              gid: 1,
              userOrder: 0,
              outboundJson: '{}'),
        ],
      );
      ProfilesDocument? restored;
      final env = BackupEnvironment(
        databasePath: source.path,
        appVersion: 'test',
        deviceId: 'd',
        deviceName: 'D',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () async => doc,
        applyRestoredProfiles: (d) async => restored = d,
      );
      final envelope =
          await createBackup(env: env, scope: 'all', sqlite: _openSqlite());
      await restoreBackup(
        env: env,
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      expect(restored, isNotNull);
      expect(restored!.groups.single.routeId, -1);
    });

    test('a backup without groups seeds the default group into the document', () async {
      // The never-zero-groups rule moved into the document builder too: the
      // seed used to happen in the Room commit and the document copied it
      // back. Ids stay >= 1 (ProfileStore treats 0 as invalid).
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      ProfilesDocument? restored;
      final env = BackupEnvironment(
        databasePath: source.path,
        appVersion: 'test',
        deviceId: 'd',
        deviceName: 'D',
        defaultGroupName: '默认组',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () async => ProfilesDocument(
          nextProfileId: 1,
          nextGroupId: 1,
          profiles: const [],
          groups: const [],
        ),
        applyRestoredProfiles: (d) async => restored = d,
      );
      final envelope =
          await createBackup(env: env, scope: 'profiles', sqlite: _openSqlite());
      await restoreBackup(
        env: env,
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      expect(restored, isNotNull);
      final group = restored!.groups.single;
      expect(group.name, '默认组');
      expect(group.id, greaterThanOrEqualTo(1));
    });
  });
}
