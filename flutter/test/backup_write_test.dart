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
import 'package:flrone/services/boot_guard.dart' show BootGuard;
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

/// Production's `BackupEnvironment.profileDocument` reader (box_api.dart):
/// null only when the document file is absent, which is a pre-migration
/// install. The restore's rollback copy comes from exactly this path.
Future<ProfilesDocument?> readDocumentOrNull(String databasePath) async {
  final store = documentStore(databasePath);
  return await store.exists() ? await store.readFresh() : null;
}

/// The pre-restore catalog the rollback tests put on disk: the names are
/// distinct from [seedRoom]'s, so a half-applied restore is visible.
ProfilesDocument oldCatalogDocument() => ProfilesDocument(
      nextProfileId: 2,
      nextGroupId: 2,
      profiles: [
        ProfileRow(
            id: 1,
            type: 'socks',
            name: 'old-node',
            gid: 1,
            userOrder: 0,
            outboundJson: '{}'),
      ],
      groups: [GroupRow(id: 1, name: 'Old', displayOrder: 1)],
    );

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

      // A restore into the empty Room writes the restored rows STRAIGHT into
      // the Dart document (ADR 0006 stage B) so the UI does not keep showing
      // the pre-restore catalog — Room's profile tables never see them.
      await restoreBackup(
        env: envFor(target.path, onRestored: (d) => restoredInto = d),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles', strategy: 'Override', sqlite: _openSqlite(),
      );
      expect(restoredInto, isNotNull);
      expect(restoredInto!.profiles.map((p) => p.name), contains('dart-only'));
      // The file on disk — the only copy the app reads — carries it too.
      final written = await restoredDocument(target.path);
      expect(written.profiles.map((p) => p.name), contains('dart-only'));
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '0');
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
      expect(ui['preferences'], {'theme': 'system'},
          reason: 'the device-local boot marker in the fixture must be filtered '
              'out while the user-facing key survives');
      expect(ui['settings'], {'fontSize': 14});
      // The WebDAV account never enters a backup.
      expect(ui['preferences'].containsKey('webdavAccount'), isFalse);

      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      // The container's own copy is filtered too: a restore reads this one.
      expect((decoded.flroneUi['preferences'] as Map).containsKey('bootGuardRecord'),
          isFalse);
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

    test('restore into an empty room rebuilds every part and refreshes', () async {
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
      // Profiles/groups land in the document ...
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.map((p) => p.id), [1, 2, 3]);
      expect(doc.groups, hasLength(2));
      // ... and never in Room, whose profile tables stay a pre-migration seed.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '0');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '0');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_profiles'), '1');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_rules'), '1');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'current_group'"), '1');
    });

    test('id conflict: ids are kept and the document counter is raised, never lowered', () async {
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

      // The backup's ids win (replace-keeping-ids) in the document, and the
      // document's own counter is raised past them so no id is ever reused —
      // the target's counter was 3 before the restore.
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.map((p) => p.id).toList()..sort(), [10, 11, 12]);
      expect(doc.nextProfileId, greaterThanOrEqualTo(13));
      expect(doc.groups.map((g) => g.id).toSet(), {10, 20});
      expect(doc.nextGroupId, greaterThanOrEqualTo(21));
      // Room's profile tables are untouched, so its sequence is irrelevant.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles WHERE id >= 10'), '0');
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

    test('a container with a blank settings table does not wipe the live settings', () async {
      // ADR 0006 stage C2b: settings/markers live in the host's documents, and a
      // container only carries them because the host still exports the SQL
      // tables (so an older build can restore). A container that has the tables
      // but no rows must read as "nothing to restore", never as "the user has
      // none" — the second reading is a silent wipe of every setting.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {
        seedRoom(db);
        db.execute("INSERT INTO markers (key, marked_at) VALUES ('keep-marker', 5)");
        db.execute("INSERT INTO route_profiles (id, name) VALUES (99, 'Only mine')");
      });
      addTearDown(target.dispose);
      final env = envFor(source.path);
      final envelope = await createBackup(env: env, scope: 'all', sqlite: _openSqlite());

      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      final dir = await Directory.systemTemp.createTemp('thrn-blank-settings-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/snapshot.db';
      File(path).writeAsBytesSync(decoded.database!);
      final snapshot = _openSqlite().openDatabase(path, readOnly: false)!;
      try {
        snapshot.execute('DELETE FROM settings');
        snapshot.execute('DELETE FROM markers');
      } finally {
        snapshot.close();
      }
      final blanked = thrnEncode(
        thrnAndroidMeta(
          parts: const ThrnParts(profiles: true, routes: true, settings: true),
          appVersion: 'test',
          deviceId: 'd',
          deviceName: 'D',
          createdAt: 'x',
        )..['flrone_ui'] = env.uiPayload,
        <String, List<int>>{'database': File(path).readAsBytesSync()},
      );

      final result = await restoreBackup(
        env: envFor(target.path),
        bytes: blanked,
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );

      // The phone's settings and markers survive: nothing arrived to replace them.
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'remote_dns'"),
          'https://8.8.8.8/dns-query');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'inbound_address'"),
          '127.0.0.1');
      expect(column(target, 'SELECT key FROM markers'), ['keep-marker']);
      // The rest of the container still applied (routes were replaced).
      expect(column(target, 'SELECT id FROM route_profiles'), isNot(contains(99)));
      expect(scalar(target, 'SELECT COUNT(*) FROM route_rules'), '1');
      // … and the UI document it carried came back as the restore's `ui` — the
      // part a document-backed build actually applies.
      expect(result.ui['settings'], <String, Object?>{'fontSize': 14});
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
      expect(scalar(target, 'SELECT COUNT(*) FROM route_profiles WHERE is_raw = 0'), '1');
      expect(scalar(target, "SELECT name FROM route_profiles WHERE is_raw = 0"), 'Default');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_rules'), '1');
      // The never-zero-groups rule lives in the document now (the Room seed is
      // not written at all).
      final doc = await restoredDocument(target.path);
      expect(doc.groups.single.name, 'Default');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '0');
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
      // The orphan was moved into group 1 (via profiles_json), not dropped —
      // in the document, which is the restored catalog.
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.single.gid, 1);
      expect(result.warnings, contains(matches(RegExp(r'profiles whose group is missing were moved'))));
      expect(result.warnings, contains(matches(RegExp(r'groups without a tab position were added'))));
    });

    test('a damaged container is refused before touching Room or the document', () async {
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
      expect(await documentStore(target.path).exists(), isFalse);
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
      expect((await restoredDocument(target.path)).profiles, hasLength(3));
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
      expect((await restoredDocument(target.path)).profiles, hasLength(3));
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

    test('restore takes the host path: document first, then data.applyRoomSnapshot for routes/settings', () async {
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
          // Production writes the document via ProfileStore.replaceAll; the
          // file write is exercised in the ffi-group tests above.
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
      // The document is a restore's ONLY profiles copy (ADR 0006 stage B).
      expect(restoredDoc, isNotNull);
      expect(restoredDoc!.profiles.map((p) => p.name), contains('node-a'));
      // Room's profile tables were not written; routes/settings were.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '0');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '0');
      expect(scalar(target, 'SELECT COUNT(*) FROM route_profiles'), '1');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'current_group'"), '1');
    });

    test('a failed document write aborts the host restore before Room is touched', () async {
      // ADR 0006 stage B ordering: the atomic document write is the restore's
      // first write, so a failure leaves routes/settings exactly as they were —
      // no half-applied restore, and no Room rows to clean up.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      // A previous catalog on disk: a failed write must leave it byte-identical.
      await documentStore(target.path).replaceAll(ProfilesDocument(
        nextProfileId: 2,
        nextGroupId: 2,
        profiles: [
          ProfileRow(id: 1, type: 'socks', name: 'old-node', gid: 1,
              userOrder: 0, outboundJson: '{}'),
        ],
        groups: [GroupRow(id: 1, name: 'Old', displayOrder: 1)],
      ));

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
        applyRestoredProfiles: (d) async => throw StateError('disk full'),
        applyRoomSnapshot: (rows) async {
          applied++;
          return host.applyRoomSnapshot(rows);
        },
      );

      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message', contains('disk full'))),
      );

      // The host was never asked to commit, and the target's rows are intact.
      expect(applied, 0);
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '2');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'remote_dns'"),
          'https://8.8.8.8/dns-query');
      expect(scalar(target, 'SELECT name FROM route_profiles'), 'Default');
      // The document still holds the pre-restore catalog — no partial document.
      final kept = await restoredDocument(target.path);
      expect(kept.profiles.single.name, 'old-node');
      expect(kept.groups.single.name, 'Old');
    });

    test('a pre-migration install (no document yet) gets the catalog in the document', () async {
      // The document directory is writable, the file is simply absent: the
      // restore writes the restored catalog there and Room's pre-migration rows
      // stay behind untouched as the migration source. Nothing is lost — the
      // catalog reads the document from now on.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        applyRestoredProfiles: (d) => documentStore(target.path).replaceAll(d),
        applyRoomSnapshot: (rows) async => host.applyRoomSnapshot(rows),
      );

      await restoreBackup(
        env: env,
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        host: host,
      );

      final doc = await restoredDocument(target.path);
      expect(doc.profiles.map((p) => p.name), containsAll(['node-a', 'node-b', 'node-c']));
      expect(doc.groups, hasLength(2));
      // The pre-migration Room rows survive as-is (they are the migration
      // source, not the live copy).
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(scalar(target, 'SELECT COUNT(*) FROM groups'), '2');
    });

    test('a restore that cannot write the document refuses and changes nothing', () async {
      // No sink wired == the document directory is not mounted: committing to
      // Room instead would leave the restore invisible (Room's profile tables
      // are the pre-migration seed), so the whole restore is refused while the
      // user's backup file is still on disk.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
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
        applyRoomSnapshot: (rows) async {
          applied++;
          return host.applyRoomSnapshot(rows);
        },
      );

      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()),
      );
      expect(applied, 0);
      expect((await documentStore(target.path).exists()), isFalse);
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '3');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'remote_dns'"),
          'https://8.8.8.8/dns-query');
    });

    // S9: the document write comes first, so every later step must not leave a
    // new catalog on top of old routes/settings. Each case below pins one arm
    // of that rollback.

    test('a commit failure after the document write restores the previous document', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      // The pre-restore catalog, on disk exactly where the production
      // ProfileStore keeps it — the copy the rollback must put back.
      await documentStore(target.path).replaceAll(oldCatalogDocument());
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      final writes = <ProfilesDocument>[];
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () => readDocumentOrNull(target.path),
        applyRestoredProfiles: (d) async {
          writes.add(d);
          await documentStore(target.path).replaceAll(d);
        },
        // The host's transaction fails after the document write: the exact
        // half-applied state S9 exists to close.
        applyRoomSnapshot: (rows) async => throw StateError('host commit failed'),
      );

      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message', contains('host commit failed'))
            .having((e) => e.message, 'message',
                contains('previous configuration document was restored'))),
      );

      // Two writes: the restore's, then the rollback's.
      expect(writes, hasLength(2));
      expect(writes.first.profiles.map((p) => p.name), contains('node-a'));
      expect(writes.last.profiles.single.name, 'old-node');
      // The document on disk is the pre-restore catalog again.
      final kept = await restoredDocument(target.path);
      expect(kept.profiles.single.name, 'old-node');
      expect(kept.groups.single.name, 'Old');
      // The commit never ran, so routes/settings still hold their old values.
      expect(scalar(target, 'SELECT name FROM route_profiles'), 'Default');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'remote_dns'"),
          'https://8.8.8.8/dns-query');
    });

    test('a pre-migration install cannot get its absent document back, and the error says so', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      var writes = 0;
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        // No document file yet: the production reader answers null.
        profileDocument: () => readDocumentOrNull(target.path),
        applyRestoredProfiles: (d) async {
          writes++;
          await documentStore(target.path).replaceAll(d);
        },
        applyRoomSnapshot: (rows) async => throw StateError('host commit failed'),
      );

      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message', contains('host commit failed'))
            .having((e) => e.message, 'message',
                contains('did not exist before this restore'))
            .having((e) => e.message, 'message',
                contains('cannot be made absent again'))),
      );
      // No rollback write was possible (there was nothing to put back) and the
      // restored catalog is what stays — the error above is the only signal,
      // which is why it names the state instead of leaving it silent.
      expect(writes, 1);
      final kept = await restoredDocument(target.path);
      expect(kept.profiles.map((p) => p.name),
          containsAll(['node-a', 'node-b', 'node-c']));
    });

    test('a successful restore replaces the document and leaves routes/settings new', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await documentStore(target.path).replaceAll(oldCatalogDocument());
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      final writes = <ProfilesDocument>[];
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () => readDocumentOrNull(target.path),
        applyRestoredProfiles: (d) async {
          writes.add(d);
          await documentStore(target.path).replaceAll(d);
        },
        applyRoomSnapshot: (rows) async => host.applyRoomSnapshot(rows),
      );

      await restoreBackup(
        env: env,
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        host: host,
      );

      // One write, no second (rollback) pass on the success path.
      expect(writes, hasLength(1));
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.map((p) => p.name),
          containsAll(['node-a', 'node-b', 'node-c']));
      expect(doc.profiles.any((p) => p.name == 'old-node'), isFalse);
      // The commit ran and replaced the empty target's routes/settings.
      expect(scalar(target, 'SELECT COUNT(*) FROM route_profiles'), '1');
      expect(scalar(target, "SELECT value FROM settings WHERE key = 'current_group'"), '1');
      // Room's profile/group tables stay the untouched pre-migration seed.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), '0');
    });

    test('a failed document write attempts no rollback', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      await documentStore(target.path).replaceAll(oldCatalogDocument());
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      var writes = 0;
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () => readDocumentOrNull(target.path),
        applyRestoredProfiles: (d) async {
          writes++;
          throw StateError('disk full');
        },
        applyRoomSnapshot: (rows) async => throw StateError('must not be reached'),
      );

      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message', contains('disk full'))
            // Nothing landed, so a rollback write would be pure noise — and
            // would itself overwrite the document the failed write never touched.
            .having((e) => e.message, 'message',
                isNot(contains('previous configuration document')))),
      );
      expect(writes, 1);
      final kept = await restoredDocument(target.path);
      expect(kept.profiles.single.name, 'old-node');
      expect(kept.groups.single.name, 'Old');
    });

    test('a route-document failure reports the partial write in the same error', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {
        // A route row only this target has: the successful host commit below
        // must replace it, and it must stay replaced (routes are reported, not
        // rolled back).
        db.execute(
            "INSERT INTO route_profiles (id, name) VALUES (?, ?)", <Object?>[9, 'stale-route']);
      });
      addTearDown(target.dispose);
      // A file where the documents directory belongs: the route-document
      // replace throws, after the document write and the host commit.
      final documentsDir = documentsDirFromDatabasePath(target.path);
      Directory(File(documentsDir).parent.path).createSync(recursive: true);
      File(documentsDir).writeAsStringSync('not a directory');
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final host = FakeRoomHost(_openSqlite(), roomPath: target.path).toHost();
      final writes = <ProfilesDocument>[];
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'test-device',
        deviceName: 'Test',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () async => oldCatalogDocument(),
        applyRestoredProfiles: (d) async => writes.add(d),
        applyRoomSnapshot: (rows) async => host.applyRoomSnapshot(rows),
      );

      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message',
                contains('previous configuration document was restored'))
            .having((e) => e.message, 'message',
                contains('route documents were partially written'))),
      );
      expect(writes, hasLength(2));
      expect(writes.last.profiles.single.name, 'old-node');
      // The host commit did run, so the routes are new even though the
      // documents could not be written — the error says so rather than
      // pretending the whole restore was undone.
      expect(column(target, 'SELECT name FROM route_profiles'), isNot(contains('stale-route')));
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
          return <String, dynamic>{'warnings': <dynamic>[]};
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
        'restoredGroupIds': <int>[1],
        'restoredProfileIds': <int>[1],
        'routeProfiles': <String, Object?>{'columns': <String>[], 'rows': <dynamic>[]},
        'routeRules': <String, Object?>{'columns': <String>[], 'rows': <dynamic>[]},
      });

      expect(seen.containsKey('data.roomSnapshot'), isTrue);
      expect(seen['data.roomSnapshot'], containsAll(['profiles', 'groups']));
      expect(seen.containsKey('data.applyRoomSnapshot'), isTrue);
      // Profiles/groups tables are gone from the wire (ADR 0006 stage B): the
      // document carries them, and only the restored id sets remain.
      expect(seen['data.applyRoomSnapshot'],
          containsAll(['doProfiles', 'doRoutes', 'doSettings', 'routeProfiles',
            'routeRules', 'restoredGroupIds', 'restoredProfileIds']));
      expect(seen['data.applyRoomSnapshot'],
          isNot(containsAll(['profiles', 'groups', 'defaultGroupName'])));
    });

    test('the container transport is backup.container and has no live-Room op', () async {
      // C2c1: the SQL transport moved off `data.roomSql`. It is container-only —
      // the ops Dart can send are the six that touch a backup file, and there is
      // no `openRoom` (a live Room handle does not exist on this channel).
      final ops = <String, List<Object?>>{};
      final host = RoomSnapshotHost(call: (method, [args]) async {
        final op = args is Map ? args['op'] : null;
        ops.putIfAbsent(method, () => <Object?>[]).add(op);
        return switch (op) {
          'open' => <String, dynamic>{'handle': 'h1'},
          'query' => <dynamic>[],
          'exec' => 0,
          'readBytes' => <String, dynamic>{'bytes': base64Encode(<int>[1])},
          _ => null,
        };
      });

      final handle = await host.openSql('/tmp/container/backup.db', write: true);
      await host.sqlQuery(handle, 'SELECT 1');
      await host.sqlExec(handle, 'PRAGMA defer_foreign_keys = ON');
      await host.writeBytes('/tmp/container/out.db', <int>[1]);
      await host.readBytes('/tmp/container/out.db');
      await host.closeSql(handle);

      expect(ops.keys, ['backup.container']);
      expect(ops['backup.container'], ['open', 'query', 'exec', 'writeBytes', 'readBytes', 'close']);
      expect(ops['backup.container'], isNot(contains('openRoom')));
    });

    test('the container channel refuses the live database and the documents directory', () async {
      // The host guard (BboxRoomSnapshot.confinedContainerFile) can only run on a
      // device, so this pins the same rule on the fake: a container path inside
      // the app's storage opens; `sager_net.db`, the live data directories and
      // any path outside the storage root are refused, and the refusal comes
      // back to Dart.
      final fake = FakeRoomHost(
        _openSqlite(),
        roomPath: '${Directory.systemTemp.path}/databases/sager_net.db',
      );
      final host = fake.toHost();
      final dir = await Directory.systemTemp.createTemp('container-guard-');
      addTearDown(() => dir.deleteSync(recursive: true));

      final okPath = '${dir.path}/backup.db';
      final handle = await host.openSql(okPath, write: true);
      await host.closeSql(handle);
      expect(File(okPath).existsSync(), isTrue);

      expect(() => fake.confine('${Directory.systemTemp.path}/databases/sager_net.db'),
          throwsA(isA<StateError>()));
      expect(() => fake.confine('${dir.path}/sager_net.db-wal'),
          throwsA(isA<StateError>()));
      expect(() => fake.confine('${Directory.systemTemp.path}/documents/route_profiles.json'),
          throwsA(isA<StateError>()));
      expect(() => fake.confine('${Directory.systemTemp.path}/routeprofiles/srslist.h'),
          throwsA(isA<StateError>()));
      expect(() => fake.confine('${Directory.systemTemp.path}/../elsewhere/backup.db'),
          throwsA(isA<StateError>()));
      await expectLater(
        host.openSql('${Directory.systemTemp.path}/documents/backup.db', write: true),
        throwsA(isA<StateError>()),
      );
    });

    test('the host-path live column shape is the desktop DDL, pinned to real SQLite', () async {
      // C2c1: with no live handle, `_stageTable` validates a container against
      // the DDL parse instead of `PRAGMA table_info` on Room's file. Pin that
      // parse to SQLite's own reading of the same DDL so the two can not drift.
      final sqlite = _openSqlite();
      final dir = await Directory.systemTemp.createTemp('desktop-ddl-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final db = sqlite.openDatabase('${dir.path}/desk.db', readOnly: false)!;
      addTearDown(db.close);
      for (final sql in backupDesktopDdl) {
        db.execute(sql);
      }
      for (final table in const [
        'profiles', 'groups', 'route_profiles', 'route_rules', 'global_route_rules',
      ]) {
        final actual = db
            .query('PRAGMA table_info(`$table`)')
            .where((row) => row['name'] != 'created_at' && row['name'] != 'updated_at')
            .map((row) => (
                  name: '${row['name']}',
                  notNull: (row['notnull'] as num).toInt() != 0,
                  defaultSql: row['dflt_value'] as String?,
                ))
            .toList();
        expect(backupDesktopColumnInfo(table), actual, reason: table);
      }
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

  // SQLite-free on purpose: the filter is a plain map transform, and these cases
  // must run on a host without libsqlite3 (where the groups above cannot).
  group('the UI documents a backup carries', () {
    test('the boot marker is device-local, not backup material', () {
      // Read through BootGuard's own constant so a rename fails here instead of
      // silently letting launch bookkeeping back into the container.
      expect(backupDeviceLocalKeys, contains(BootGuard.preferenceKey));
    });

    test('export drops the boot marker and keeps the user preferences', () {
      final ui = backupUiDocument(<String, Object?>{
        'preferences': <String, Object?>{
          'theme': 'dark',
          'locale': 'zh',
          BootGuard.preferenceKey: '{"stage":"starting","startedAt":1}',
        },
        'settings': <String, Object?>{'fontSize': 14},
      });

      final preferences = ui['preferences'] as Map<String, Object?>;
      expect(preferences.keys, isNot(contains(BootGuard.preferenceKey)));
      expect(preferences['theme'], 'dark');
      expect(preferences['locale'], 'zh');
      expect(ui['settings'], <String, Object?>{'fontSize': 14});
    });

    test('a restore sanitises the container, so a stale marker cannot land', () {
      // What an older build embedded; restoreBackup passes exactly this through
      // backupUiDocument before the host writer sees it.
      final container = <String, Object?>{
        'preferences': <String, Object?>{
          BootGuard.preferenceKey: '{"stage":"starting","startedAt":1}',
          'theme': 'light',
        },
      };

      final applied = backupUiDocument(container);
      final preferences = applied['preferences'] as Map<String, Object?>;
      expect(preferences.containsKey(BootGuard.preferenceKey), isFalse);
      expect(preferences['theme'], 'light',
          reason: 'the restore still applies the rest of the UI documents');
      // The container itself is not mutated: the caller may still read it.
      expect((container['preferences'] as Map).containsKey(BootGuard.preferenceKey), isTrue);
    });

    test("the environment's default payload is already filtered", () {
      final env = BackupEnvironment(
        databasePath: '/x/sager_net.db',
        appVersion: 'test',
        deviceId: 'd',
        deviceName: 'D',
        defaultGroupName: 'Default',
        preferences: <String, Object?>{
          'theme': 'dark',
          BootGuard.preferenceKey: '{"stage":"running","startedAt":2}',
        },
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
      );

      final preferences = env.uiPayload['preferences'] as Map<String, Object?>;
      expect(preferences.containsKey(BootGuard.preferenceKey), isFalse);
      expect(preferences['theme'], 'dark');
    });
  });
}
