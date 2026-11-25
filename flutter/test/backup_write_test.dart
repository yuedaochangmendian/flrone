// Dart backup write-path tests (ADR 0005 phase 4; ADR 0006 stage C2c2a).
//
// The path is documents-only now: the export builds the THRN container's SQL
// tables from `profiles.json`, the kernel's `route_*.json` documents and the
// host's settings/markers snapshots; the restore writes those documents back.
// The synthetic `sager_net.db` these tests create is the *legacy* file, used to
// prove it is neither read nor written by the pipeline.
//
// On Android/CI `libsqlite3.so` is present, so Sqlite.open() works directly. On
// a Windows host it is not; set BACKUP_TEST_SQLITE to a sqlite3.dll absolute path
// to run these tests there (see the task handoff for the local path).

import 'dart:convert';
import 'dart:io';

import 'package:flrone/data/configuration_store.dart'
    show ConfigurationRow, NodeRow, ProfilesDocument, documentsDirFromDatabasePath;
import 'package:flrone/services/route_documents.dart';
import 'package:flrone/data/sqlite.dart' show Sqlite, SqliteDatabase;
import 'package:flrone/services/backup_store.dart'
    show thrnDecode, thrnEncode, thrnAndroidMeta, ThrnParts;
import 'package:flrone/services/backup_write.dart';
import 'package:flrone/services/boot_guard.dart' show BootGuard;
import 'package:flutter_test/flutter_test.dart';

import 'support/backup_fixture.dart';
import 'support/fake_backup_host.dart' show FakeBackupHost, legacyReply;
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

/// Writes the profiles document the production reader would see on disk.
Future<void> seedDocument(String databasePath, ProfilesDocument doc) =>
    documentStore(databasePath).replaceAll(doc);

/// The kernel's global route document a previous (live) session left behind.
void seedRouteDocuments(
  String databasePath, {
  List<Map<String, Object?>> global = const [
    {'rule_id': 1, 'rule_order': 0, 'name': 'kernel-rule', 'action': 'route'},
  ],
}) {
  RouteDocuments(Directory(documentsDirFromDatabasePath(databasePath)))
      .restore(globalRules: global);
}

RouteDocuments routeDocuments(String databasePath) =>
    RouteDocuments(Directory(documentsDirFromDatabasePath(databasePath)));

/// The container's embedded database as a queryable file.
Future<SqliteDatabase> _writeContainer(List<int> bytes) async {
  final dir = await Directory.systemTemp.createTemp('thrn-inspect-');
  addTearDown(() => dir.deleteSync(recursive: true));
  final path = '${dir.path}/snapshot.db';
  File(path).writeAsBytesSync(bytes);
  return _openSqlite().openDatabase(path, readOnly: true)!;
}

/// Re-encodes an envelope with the global route table dropped (a container
/// from before the pool was backed up).
Future<List<int>> withoutGlobalRules(Map<String, Object?> envelope) async {
  final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
  final dir = await Directory.systemTemp.createTemp('thrn-old-');
  final path = '${dir.path}/snapshot.db';
  File(path).writeAsBytesSync(decoded.database!);
  final db = _openSqlite().openDatabase(path, readOnly: false)!;
  db.execute('DROP TABLE global_route_rules');
  db.close();
  final bytes = File(path).readAsBytesSync();
  dir.deleteSync(recursive: true);
  return thrnEncode(decoded.meta, {'database': bytes});
}

/// Re-encodes an envelope with the settings table blank (a container that
/// carries no settings block).
Future<List<int>> withoutSettings(Map<String, Object?> envelope) async {
  final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
  final dir = await Directory.systemTemp.createTemp('thrn-blank-');
  final path = '${dir.path}/snapshot.db';
  File(path).writeAsBytesSync(decoded.database!);
  final db = _openSqlite().openDatabase(path, readOnly: false)!;
  db.execute('DELETE FROM settings');
  db.close();
  final bytes = File(path).readAsBytesSync();
  dir.deleteSync(recursive: true);
  return thrnEncode(decoded.meta, {'database': bytes});
}

BackupEnvironment hostEnv(
  String path,
  RoomSnapshotHost host, {
  void Function(ProfilesDocument doc)? onRestored,
}) =>
    BackupEnvironment(
      databasePath: path,
      appVersion: 'test',
      deviceId: 'test-device',
      deviceName: 'Test',
      defaultGroupName: 'Default',
      preferences: const <String, Object?>{'theme': 'system'},
      settingsDocument: const <String, Object?>{},
      qualityDocument: const <String, Object?>{},
      profileDocument: () async {
        final store = documentStore(path);
        return await store.exists() ? await store.readFresh() : null;
      },
      applyRestoredProfiles: (doc) async {
        await documentStore(path).replaceAll(doc);
        onRestored?.call(doc);
      },
      settingsSnapshot: () => host.settingsSnapshot(),
      markersSnapshot: () => host.markersSnapshot(),
      restoreSettings: (request) => host.restoreSettings(
        settings: request.settings,
        fromAndroid: request.fromAndroid,
        restoredProfiles: request.restoredProfiles,
        groupIds: request.groupIds,
        profileIds: request.profileIds,
      ),
      restoreMarkers: (rows) => host.restoreMarkers(rows),
    );

void main() {
  group('Dart backup write path (documents -> THRN -> documents)', () {
    test('export reads the Dart document, not the legacy database', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      await seedDocument(source.path, sampleDocument());

      final envelope = await createBackup(
          env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());

      // The preview and the embedded snapshot both carry the document's rows.
      expect(envelope['profiles'], hasLength(2));
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      final embedded = await _writeContainer(decoded.database!);
      addTearDown(embedded.close);
      expect(embedded.query('SELECT COUNT(*) FROM profiles').first.values.first, 3);
      expect(
        embedded.query("SELECT name FROM profiles WHERE id = 4").first.values.first,
        'dart-only',
      );
      // Room's stale rows never enter: node-b exists only in the legacy file.
      expect(embedded.query("SELECT name FROM profiles WHERE name = 'node-b'"), isEmpty);
    });

    test('create -> restore round-trips profiles, routes, settings and markers', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);

      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);
      final sourceSink = BackupSink(settings: {
        'remote_dns': 'https://8.8.8.8/dns-query',
        'appTheme': 'dark',
        'profileCurrent': '4',
        'deviceId': 'source-device',
        'webdavServer': 'https://private.test/',
      }, markers: [
        {'key': 'seen-1', 'marked_at': 1700000000},
      ]);
      final envelope = await createBackup(
          env: envFor(source.path, sink: sourceSink), scope: 'all', sqlite: _openSqlite());

      // The target has its own catalog, documents and selection.
      await seedDocument(target.path, oldCatalogDocument());
      routeDocuments(target.path).writeTable('global_route_rules', [
        {'rule_id': 7, 'rule_order': 0, 'name': 'stale'},
      ]);
      final targetSink = BackupSink(settings: {
        'deviceId': 'target-device',
        'webdavServer': 'local',
        'remote_dns': 'old',
        'appTheme': 'light',
        'current_group': '99',
        'profileId': '99',
      }, markers: [
        {'key': 'old-marker', 'marked_at': 1},
      ]);
      final before = scalar(target, 'SELECT COUNT(*) FROM profiles');

      await restoreBackup(
        env: envFor(target.path, sink: targetSink),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );

      // Profiles/groups: the document is the only copy.
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.map((p) => p.name), containsAll(['node-a', 'dart-only', 'node-c']));
      expect(doc.groups.map((g) => g.name), containsAll(['Default', 'Sub']));
      expect(doc.nextProfileId, greaterThanOrEqualTo(5));

      // Routes: the one global table was replaced.
      final routes = routeDocuments(target.path).readTable('global_route_rules');
      expect(routes.map((r) => r['name']), contains('kernel-rule'));
      expect(routes.any((r) => r['name'] == 'stale'), isFalse);

      // Settings: merged through the sink, device-local untouched.
      expect(targetSink.settings['remote_dns'], 'https://8.8.8.8/dns-query');
      expect(targetSink.settings['appTheme'], 'dark');
      expect(targetSink.settings['deviceId'], 'target-device');
      expect(targetSink.settings['webdavServer'], 'local');
      expect(targetSink.settings['current_group'], '1');
      expect(targetSink.settings['profileCurrent'], '4');
      expect(targetSink.settings['profileId'], isNull);
      expect(targetSink.settingsRestores, 1);

      // Markers: whole-set replacement plus the one-time IPv6 migration marker.
      expect(targetSink.markerRestores, 1);
      expect(targetSink.markers.map((r) => r['key']), contains('seen-1'));
      expect(targetSink.markers.any((r) => r['key'] == 'old-marker'), isFalse);
      expect(targetSink.markers.map((r) => r['key']),
          contains('migration.tun_private_ranges_ipv6'));

      // Nothing reads or writes the legacy database.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), before);
    });

    test('restore keeps the highest id and raises the document counter', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, ProfilesDocument(
        nextProfileId: 9,
        nextGroupId: 2,
        groups: const [ConfigurationRow(id: 1, name: 'Default', displayOrder: 1)],
        profiles: const [
          NodeRow(id: 8, type: 'ss', name: 'high', gid: 1, userOrder: 0, outboundJson: '{}'),
        ],
      ));
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      await seedDocument(target.path, ProfilesDocument(
        nextProfileId: 2,
        nextGroupId: 2,
        groups: const [ConfigurationRow(id: 1, name: 'Old', displayOrder: 1)],
        profiles: const [
          NodeRow(id: 1, type: 'ss', name: 'old', gid: 1, userOrder: 0, outboundJson: '{}'),
        ],
      ));
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.single.id, 8);
      expect(doc.nextProfileId, 9);
    });

    test('a container with a blank settings table does not wipe the live settings', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());
      final blank = await withoutSettings(envelope);

      final targetSink = BackupSink(settings: {'remote_dns': 'mine', 'appTheme': 'light'});
      await seedDocument(target.path, oldCatalogDocument());
      await restoreBackup(
        env: envFor(target.path, sink: targetSink),
        bytes: blank,
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      // Nothing to apply: the live values stay and only the selection is repaired.
      expect(targetSink.settings['remote_dns'], 'mine');
      expect(targetSink.settings['appTheme'], 'light');
      expect(targetSink.settings['current_group'], '1');
    });

    test('profiles-only scope does not touch routes, settings or markers', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      expect(decoded.parts.routes, isFalse);
      expect(decoded.parts.settings, isFalse);

      await seedDocument(target.path, oldCatalogDocument());
      routeDocuments(target.path).writeTable('global_route_rules', [
        {'rule_id': 7, 'rule_order': 0, 'name': 'kept'},
      ]);
      final targetSink = BackupSink(settings: {'remote_dns': 'mine'}, markers: [
        {'key': 'keep', 'marked_at': 3},
      ]);
      await restoreBackup(
        env: envFor(target.path, sink: targetSink),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      expect(targetSink.settings['remote_dns'], 'mine');
      expect(targetSink.markers.single['key'], 'keep');
      expect(targetSink.markerRestores, 0);
      final routes = routeDocuments(target.path).readTable('global_route_rules');
      expect(routes.single['name'], 'kept');
    });

    test('an empty store exports cleanly and restores the default group/route', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      // No document, no route documents, no settings: a fresh install.
      final envelope = await createBackup(
          env: envFor(source.path, sink: BackupSink()), scope: 'all', sqlite: _openSqlite());
      expect(envelope['profiles'], isEmpty);

      final sink = BackupSink();
      await restoreBackup(
        env: envFor(target.path, sink: sink),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      final doc = await restoredDocument(target.path);
      expect(doc.groups.single.name, 'Default');
      // No route part in the container: the live global document is untouched.
      expect(routeDocuments(target.path).readTable('global_route_rules'), isEmpty);
    });

    test('table repair: orphan profiles are moved and untabbed groups get an order', () async {
      final dir = await Directory.systemTemp.createTemp('thrn-repair-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/malformed.db';
      final db = _openSqlite().openDatabase(path, readOnly: false)!;
      for (final sql in backupDesktopDdl) {
        db.execute(sql);
      }
      db.execute("INSERT INTO groups (id, name) VALUES (1, 'Only')");
      db.execute("INSERT INTO profiles (id, type, name, gid, outbound_json) VALUES (7, 'socks', 'orphan', 999, '{}')");
      db.execute("UPDATE groups SET profiles_json = '[7]' WHERE id = 1");
      db.execute("INSERT INTO entity_ids (profile_last_id, group_last_id, otp_profile_last_id) VALUES (7, 1, 0)");
      db.close();
      final container = thrnEncode(
        thrnAndroidMeta(
          parts: const ThrnParts(profiles: true, routes: false, settings: false),
          appVersion: 'x', deviceId: 'x', deviceName: 'x', createdAt: 'x',
        ),
        {'database': File(path).readAsBytesSync()},
      );
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      final result = await restoreBackup(
        env: envFor(target.path),
        bytes: container,
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.single.gid, 1);
      expect(result.warnings,
          contains(matches(RegExp(r'profiles whose group is missing were moved'))));
      expect(result.warnings,
          contains(matches(RegExp(r'groups without a tab position were added'))));
    });

    test('a damaged container is refused before touching the documents', () async {
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      final sink = BackupSink(settings: {'remote_dns': 'mine'});
      final bytes = thrnEncode(
        thrnAndroidMeta(
          parts: const ThrnParts(profiles: true, routes: true, settings: true),
          appVersion: 'x', deviceId: 'x', deviceName: 'x', createdAt: 'x',
        ),
        {'database': utf8.encode('SQLite format 3\u0000')},
      );
      final damaged = bytes.sublist(0, bytes.length - 5);
      await expectLater(
        restoreBackup(
          env: envFor(target.path, sink: sink),
          bytes: damaged,
          scope: 'all',
          strategy: 'Override',
          sqlite: _openSqlite(),
        ),
        throwsA(isA<Exception>()),
      );
      expect(await documentStore(target.path).exists(), isFalse);
      expect(sink.settingsRestores, 0);
      expect(sink.settings['remote_dns'], 'mine');
    });

    test('an old (v1) container without parts restores every document part', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);
      final sourceSink = BackupSink(settings: {'remote_dns': 'https://8.8.8.8/dns-query'});
      final envelope = await createBackup(
          env: envFor(source.path, sink: sourceSink), scope: 'all', sqlite: _openSqlite());
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      final v1 = thrnEncode(
        {'platform': 'android', 'created_at': 'old'},
        {'database': decoded.database!},
        version: 1,
      );
      final sink = BackupSink();
      await restoreBackup(
        env: envFor(target.path, sink: sink),
        bytes: v1,
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      expect((await restoredDocument(target.path)).profiles, hasLength(3));
      expect(routeDocuments(target.path).readTable('global_route_rules').single['name'],
          'kernel-rule');
      expect(sink.settings['remote_dns'], 'https://8.8.8.8/dns-query');
    });

    test('desktop DDL and column mapping match the Kotlin DesktopSchema contract', () {
      expect(backupDesktopDdl, hasLength(10)); // 8 CREATE + 1 ALTER + 1 index
      expect(backupDesktopColumns('profiles'), containsAll(['latency_at', 'outbound_json', 'traffic_dl']));
      expect(backupDesktopColumns('profiles'), hasLength(15));
      expect(backupDesktopColumns('groups'), containsAll(['profiles_json', 'route_id', 'sub_metadata_json', 'sort_method']));
      expect(backupDesktopColumns('groups'), hasLength(25));
      expect(backupDesktopColumns('global_route_rules'), containsAll(['rule_id', 'rule_order', 'action']));
      expect(backupDesktopColumns('global_route_rules'), hasLength(46));
      expect(backupDesktopColumns('settings'), ['key', 'value']);
      expect(backupDesktopColumns('markers'), ['key', 'marked_at']);
    });

    test('a container whose parts do not match the scope restores what it can', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      final sink = BackupSink();
      await restoreBackup(
        env: envFor(target.path, sink: sink),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      expect((await restoredDocument(target.path)).profiles, hasLength(3));
      // No routes/settings part in the container: the live ones stay.
      expect(sink.settingsRestores, 1);
      expect(sink.markerRestores, 0);
    });
  });

  group('host-backed path (no app-side SQLite)', () {
    // On a stock Android device `Sqlite.open()` answers null: the app may only
    // dlopen public.libraries.txt entries and AOSP has no libsqlite3.so. These
    // tests pass a mock RoomSnapshotHost and NO `sqlite` so create/restore take
    // the host branch; the mock emulates the Kotlin document ops and container
    // transport over real SQL.
    setUp(() => resolveBackupSqlite = () => null);
    tearDown(() => resolveBackupSqlite = Sqlite.open);

    test('create takes the host path and reads the document snapshots', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);
      final sink = BackupSink(settings: {
        'remote_dns': 'https://8.8.8.8/dns-query',
        'profileCurrent': '4',
      }, markers: [
        {'key': 'seen-1', 'marked_at': 1700000000},
      ]);
      final fake = FakeBackupHost(_openSqlite(), sink: sink);
      final host = fake.toHost();

      final envelope = await createBackup(
          env: hostEnv(source.path, host), scope: 'all', host: host);

      expect(fake.methods, containsAll(['settings.snapshot', 'markers.snapshot']));
      expect(fake.methods, isNot(contains('data.roomSnapshot')));
      expect(envelope['profiles'], hasLength(2));
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      expect(decoded.parts.profiles && decoded.parts.routes && decoded.parts.settings, isTrue);
      final embedded = await _writeContainer(decoded.database!);
      addTearDown(embedded.close);
      expect(embedded.query('SELECT COUNT(*) FROM profiles').first.values.first, 3);
      expect(embedded.query('SELECT COUNT(*) FROM global_route_rules').first.values.first, 1);
      expect(
        embedded.query("SELECT value FROM settings WHERE key = 'remote_dns'").first.values.first,
        'https://8.8.8.8/dns-query',
      );
      expect(embedded.query('SELECT COUNT(*) FROM markers').first.values.first, 2);
    });

    test('restore takes the host path: document first, then settings.restore and markers.restore',
        () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);
      final sourceSink = BackupSink(settings: {'remote_dns': 'new'}, markers: [
        {'key': 'new-marker', 'marked_at': 5},
      ]);
      final envelope = await createBackup(
          env: envFor(source.path, sink: sourceSink), scope: 'all', sqlite: _openSqlite());

      final sink = BackupSink(settings: {'remote_dns': 'old', 'deviceId': 'phone'});
      final fake = FakeBackupHost(_openSqlite(), sink: sink);
      final host = fake.toHost();
      await seedDocument(target.path, oldCatalogDocument());
      final before = scalar(target, 'SELECT COUNT(*) FROM profiles');

      await restoreBackup(
        env: hostEnv(target.path, host),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        host: host,
      );

      // The document is the restore's only profiles copy (stage B).
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.map((p) => p.name), contains('dart-only'));
      expect(sink.settings['remote_dns'], 'new');
      expect(sink.settings['deviceId'], 'phone');
      expect(sink.settingsRestores, 1);
      expect(sink.markerRestores, 1);
      expect(fake.methods, isNot(contains('data.applyRoomSnapshot')));
      // Ordering: the settings/markers document writes happen after the
      // document write and before the route documents are replaced.
      final restoreCalls = fake.methods.where((m) => m.endsWith('.restore')).toList();
      expect(restoreCalls, ['settings.restore', 'markers.restore']);
      // The legacy database is never a target.
      expect(scalar(target, 'SELECT COUNT(*) FROM profiles'), before);
    });

    test('a failed document write aborts the host restore before the settings write', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      final sink = BackupSink(settings: {'remote_dns': 'old'});
      final fake = FakeBackupHost(_openSqlite(), sink: sink);
      final host = fake.toHost();
      await seedDocument(target.path, oldCatalogDocument());
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'd',
        deviceName: 'D',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () async {
          final store = documentStore(target.path);
          return await store.exists() ? await store.readFresh() : null;
        },
        applyRestoredProfiles: (d) async => throw StateError('disk full'),
        settingsSnapshot: () => host.settingsSnapshot(),
        markersSnapshot: () => host.markersSnapshot(),
        restoreSettings: (r) => host.restoreSettings(
          settings: r.settings,
          fromAndroid: r.fromAndroid,
          restoredProfiles: r.restoredProfiles,
          groupIds: r.groupIds,
          profileIds: r.profileIds,
        ),
        restoreMarkers: (rows) => host.restoreMarkers(rows),
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

      expect(sink.settingsRestores, 0);
      expect(sink.markerRestores, 0);
      expect(sink.settings['remote_dns'], 'old');
      final kept = await restoredDocument(target.path);
      expect(kept.profiles.single.name, 'old-node');
    });

    test('a pre-migration install (no document yet) gets the catalog in the document', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      final sink = BackupSink();
      final fake = FakeBackupHost(_openSqlite(), sink: sink);
      final host = fake.toHost();
      expect(await documentStore(target.path).exists(), isFalse);

      ProfilesDocument? restored;
      await restoreBackup(
        env: hostEnv(target.path, host, onRestored: (d) => restored = d),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Override',
        host: host,
      );
      expect(restored, isNotNull);
      expect((await restoredDocument(target.path)).profiles, hasLength(3));
      // The selection repair was told the restored ids, not a database seed.
      expect(sink.settings['current_group'], '1');
    });

    test('a restore that cannot write the document refuses and changes nothing', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      final sink = BackupSink(settings: {'remote_dns': 'mine'});
      final fake = FakeBackupHost(_openSqlite(), sink: sink);
      final host = fake.toHost();
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'd',
        deviceName: 'D',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        settingsSnapshot: () => host.settingsSnapshot(),
        markersSnapshot: () => host.markersSnapshot(),
        restoreSettings: (r) => host.restoreSettings(
          settings: r.settings,
          fromAndroid: r.fromAndroid,
          restoredProfiles: r.restoredProfiles,
          groupIds: r.groupIds,
          profileIds: r.profileIds,
        ),
        restoreMarkers: (rows) => host.restoreMarkers(rows),
      );
      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'profiles',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()),
      );
      expect(sink.settingsRestores, 0);
      expect(sink.settings['remote_dns'], 'mine');
      expect(await documentStore(target.path).exists(), isFalse);
    });

    test('a settings failure after the document write restores the previous document', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      await seedDocument(target.path, oldCatalogDocument());
      final fake = FakeBackupHost(_openSqlite());
      final host = fake.toHost();
      final env = BackupEnvironment(
        databasePath: target.path,
        appVersion: 'test',
        deviceId: 'd',
        deviceName: 'D',
        defaultGroupName: 'Default',
        preferences: const <String, Object?>{},
        settingsDocument: const <String, Object?>{},
        qualityDocument: const <String, Object?>{},
        profileDocument: () async => documentStore(target.path).readFresh(),
        applyRestoredProfiles: (d) async => documentStore(target.path).replaceAll(d),
        settingsSnapshot: () => host.settingsSnapshot(),
        markersSnapshot: () => host.markersSnapshot(),
        restoreSettings: (r) async => throw StateError('settings write failed'),
        restoreMarkers: (rows) => host.restoreMarkers(rows),
      );
      await expectLater(
        restoreBackup(
          env: env,
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'profiles',
          strategy: 'Override',
          host: host,
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message', contains('previous configuration document was restored'))),
      );
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.single.name, 'old-node');
      expect(doc.groups.single.name, 'Old');
    });

    test('host wire exposes the document methods and none of the retired Room ops', () async {
      final seen = <String, Set<String>>{};
      final host = RoomSnapshotHost(call: (method, [args]) async {
        seen[method] = (args is Map) ? args.keys.map((k) => '$k').toSet() : <String>{};
        return switch (method) {
          'settings.snapshot' => <String, dynamic>{'rows': <dynamic>[]},
          'markers.snapshot' => <String, dynamic>{'rows': <dynamic>[]},
          'settings.restore' => <String, dynamic>{'warnings': <dynamic>[]},
          'data.legacyRows' => <String, dynamic>{
              'profiles': <dynamic>[], 'groups': <dynamic>[],
            },
          _ => null,
        };
      });

      await host.settingsSnapshot();
      await host.markersSnapshot();
      await host.restoreSettings(
        settings: const <String, String>{},
        fromAndroid: true,
        restoredProfiles: true,
        groupIds: const <int>[1],
        profileIds: const <int>[1],
      );
      await host.restoreMarkers(const <Map<String, Object?>>[]);
      final legacy = await host.legacyRows();

      expect(seen.keys, containsAll([
        'settings.snapshot', 'markers.snapshot', 'settings.restore', 'markers.restore',
        'data.legacyRows',
      ]));
      expect(seen.keys, isNot(contains('data.roomSnapshot')));
      expect(seen.keys, isNot(contains('data.applyRoomSnapshot')));
      expect(seen.keys, isNot(contains('data.roomProfiles')));
      expect(seen['settings.restore'], containsAll([
        'hasSettings', 'settings', 'fromAndroid', 'restoredProfiles',
        'restoredGroupIds', 'restoredProfileIds',
      ]));
      expect(legacy, isNotNull);
    });

    test('the container transport is backup.container and has no live-database op', () async {
      // C2c1: the SQL transport moved off `data.roomSql`. It is container-only —
      // the ops Dart can send are the six that touch a backup file, and there is
      // no `openRoom` (a live handle does not exist on this channel).
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
      final fake = FakeBackupHost(
        _openSqlite(),
        containerRoot: Directory.systemTemp.path,
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
      expect(() => fake.confine('${Directory.systemTemp.path}/documents/global_route_rules.json'),
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
      // With no live handle, `_stageTable` validates a container against the DDL
      // parse instead of `PRAGMA table_info` on the database. Pin that parse to
      // SQLite's own reading of the same DDL so the two can not drift.
      final sqlite = _openSqlite();
      final dir = await Directory.systemTemp.createTemp('desktop-ddl-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final db = sqlite.openDatabase('${dir.path}/desk.db', readOnly: false)!;
      addTearDown(db.close);
      for (final sql in backupDesktopDdl) {
        db.execute(sql);
      }
      for (final table in const [
        'profiles', 'groups', 'global_route_rules',
      ]) {
        final actual = db
            .query('PRAGMA table_info(`$table`)')
            .where((row) => row['name'] != 'created_at' && row['name'] != 'updated_at')
            .map((row) => (
                  name: '${row['name']}',
                  notNull: row['notnull'] == 1,
                  defaultSql: row['dflt_value'] as String?,
                ))
            .toList();
        expect(actual, backupDesktopColumnInfo(table), reason: table);
      }
    });

    test('routes back up from the kernel documents and restore into them', () async {
      // ADR 0006 stage A: the live route store is the kernel's documents. A
      // backup must not export a database freeze, and a restore must land where
      // the app reads.
      final source = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(source.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);

      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      final embedded = await _writeContainer(decoded.database!);
      addTearDown(embedded.close);
      final names = embedded
          .query('SELECT name FROM global_route_rules ORDER BY rule_id')
          .map((row) => row.values.first)
          .toList();
      expect(names, contains('kernel-rule'));

      final target = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(target.dispose);
      routeDocuments(target.path).writeTable('global_route_rules', [
        {'rule_id': 1, 'rule_order': 0, 'name': 'stale'},
      ]);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      final restored = routeDocuments(target.path).readTable('global_route_rules');
      expect(restored.map((row) => row['name']), contains('kernel-rule'));
      expect(restored.any((row) => row['name'] == 'stale'), isFalse);
    });

    test('a profiles-only restore clears the surviving routes source_gid', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      await seedDocument(source.path, sampleDocument());
      final docs = routeDocuments(source.path);
      docs.writeTable('global_route_rules', [
        {'rule_id': 5, 'rule_order': 0, 'name': 'kept'},
      ]);

      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      await restoreBackup(
        env: envFor(source.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      final kept = docs.readTable('global_route_rules');
      expect(kept.single['name'], 'kept');
    });

    test('the global added-rules pool round-trips through the backup', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path, global: [
        {'rule_id': 1, 'rule_order': 0, 'name': 'global-a', 'action': 'hijack-dns'},
      ]);

      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());
      // The container itself carries the pool — the export side of the claim.
      final decoded = thrnDecode(base64Decode(envelope['thr'] as String));
      final embedded = await _writeContainer(decoded.database!);
      addTearDown(embedded.close);
      expect(
        embedded
            .query('SELECT name FROM global_route_rules ORDER BY rule_id')
            .map((row) => row.values.first),
        ['global-a'],
      );
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      routeDocuments(target.path).writeTable('global_route_rules', [
        {'rule_id': 9, 'name': 'stale-global'},
      ]);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      final global = routeDocuments(target.path).readTable('global_route_rules');
      expect(global.single['name'], 'global-a');
      expect(global.single['action'], 'hijack-dns');
    });

    test('a container without the global table leaves the live pool alone', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      await seedDocument(target.path, oldCatalogDocument());
      seedRouteDocuments(target.path, global: [
        {'rule_id': 9, 'name': 'kept-global'},
      ]);
      await restoreBackup(
        env: envFor(target.path),
        bytes: await withoutGlobalRules(envelope),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      // The other two documents were replaced; the pool was not carried, so it
      // survives untouched — null is "do not replace", not "no rules".
      expect(
        routeDocuments(target.path).readTable('global_route_rules').single['name'],
        'kept-global',
      );
    });

    test('a profiles-only restore never resurrects the source global pool', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path, global: [
        {'rule_id': 1, 'rule_order': 0, 'name': 'source-global'},
      ]);
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      await seedDocument(target.path, oldCatalogDocument());
      seedRouteDocuments(target.path, global: [
        {'rule_id': 9, 'name': 'kept-global'},
      ]);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      // Profiles came over; the pool is not part of a one-sided restore.
      expect(
        (await restoredDocument(target.path)).profiles.map((p) => p.name),
        contains('node-a'),
      );
      expect(
        routeDocuments(target.path).readTable('global_route_rules').single['name'],
        'kept-global',
      );
    });

    test('a later UI failure restores the profiles and the route documents', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path, global: [
        {'rule_id': 1, 'rule_order': 0, 'name': 'source-global'},
      ]);
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      await seedDocument(target.path, oldCatalogDocument());
      seedRouteDocuments(target.path, global: [
        {'rule_id': 3, 'rule_order': 0, 'name': 'old-global'},
      ]);
      await expectLater(
        restoreBackup(
          env: envFor(target.path),
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          sqlite: _openSqlite(),
          applyUi: (ui) async => throw StateError('ui rejected'),
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message',
                contains('The previous configuration document was restored.'))
            .having((e) => e.message, 'message',
                contains('The previous route document was restored.'))),
      );
      // Both documents are the pre-restore ones, contents included.
      final doc = await restoredDocument(target.path);
      expect(doc.profiles.single.name, 'old-node');
      expect(doc.groups.single.name, 'Old');
      final routes = routeDocuments(target.path);
      expect(routes.readTable('global_route_rules').single['name'], 'old-global');
    });

    test('a later failure puts the previous global route document back', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      await seedDocument(target.path, oldCatalogDocument());
      routeDocuments(target.path).writeTable('global_route_rules', [
        {'rule_id': 7, 'rule_order': 0, 'name': 'old-global'},
      ]);
      await expectLater(
        restoreBackup(
          env: envFor(target.path),
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          sqlite: _openSqlite(),
          applyUi: (ui) async => throw StateError('ui rejected'),
        ),
        throwsA(isA<BackupWriteException>().having(
            (e) => e.message,
            'message',
            contains('The previous route document was restored.'))),
      );
      expect(
        routeDocuments(target.path).readTable('global_route_rules').single['name'],
        'old-global',
      );
      expect((await restoredDocument(target.path)).profiles.single.name, 'old-node');
    });

    test('a restore into an absent document set removes what it created', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path);
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());
      expect(Directory(documentsDirFromDatabasePath(target.path)).existsSync(), isFalse);

      await expectLater(
        restoreBackup(
          env: envFor(target.path),
          bytes: base64Decode(envelope['thr'] as String),
          scope: 'all',
          strategy: 'Override',
          sqlite: _openSqlite(),
          applyUi: (ui) async => throw StateError('ui rejected'),
        ),
        throwsA(isA<BackupWriteException>()
            .having((e) => e.message, 'message',
                contains('The configuration document did not exist before this restore'))
            .having((e) => e.message, 'message',
                contains('did not exist before this restore; the one it created was removed'))),
      );
      // Nothing was there to put back, so the route files the failed restore
      // created are gone — the kernel's hand-over marker included. The
      // profiles document keeps the asymmetry the note spells out.
      final routes = routeDocuments(target.path);
      expect(routes.established, isFalse);
      for (final table in routeDocumentTables) {
        expect(
          File('${documentsDirFromDatabasePath(target.path)}'
                  '${Platform.pathSeparator}$table.json')
              .existsSync(),
          isFalse,
          reason: table,
        );
      }
      expect(await documentStore(target.path).exists(), isTrue);
      expect((await restoredDocument(target.path)).profiles.map((p) => p.name),
          contains('node-a'));
    });

    test('a successful restore leaves the new route documents and no residue', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await seedDocument(source.path, sampleDocument());
      seedRouteDocuments(source.path, global: [
        {'rule_id': 1, 'rule_order': 0, 'name': 'source-global'},
      ]);
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'all', sqlite: _openSqlite());

      await seedDocument(target.path, oldCatalogDocument());
      seedRouteDocuments(target.path, global: [
        {'rule_id': 3, 'rule_order': 0, 'name': 'old-global'},
      ]);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'all',
        strategy: 'Override',
        sqlite: _openSqlite(),
      );
      final routes = routeDocuments(target.path);
      expect(routes.readTable('global_route_rules').single['name'], 'source-global');
      final names = [
        for (final entry
            in Directory(documentsDirFromDatabasePath(target.path)).listSync())
          entry.uri.pathSegments.last,
      ];
      expect(names.where((name) => name.endsWith('.tmp')), isEmpty);
    });

    test('a profiles-only restore clears the groups route_id in the document', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      await seedDocument(
        source.path,
        ProfilesDocument(
          nextProfileId: 2,
          nextGroupId: 2,
          groups: const [ConfigurationRow(id: 1, name: 'Default', displayOrder: 1, routeId: 42)],
          profiles: const [
            NodeRow(id: 1, type: 'ss', name: 'n', gid: 1, userOrder: 0, outboundJson: '{}'),
          ],
        ),
      );
      final envelope =
          await createBackup(env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      await restoreBackup(
        env: envFor(source.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      final doc = await restoredDocument(source.path);
      expect(doc.groups.single.routeId, -1);
    });

    test('a backup without groups seeds the default group into the document', () async {
      final source = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(source.dispose);
      final envelope = await createBackup(
          env: envFor(source.path), scope: 'profiles', sqlite: _openSqlite());
      final target = await RoomFixture.create(_openSqlite(), seed: (db) {});
      addTearDown(target.dispose);
      await restoreBackup(
        env: envFor(target.path),
        bytes: base64Decode(envelope['thr'] as String),
        scope: 'profiles',
        strategy: 'Compatible',
        sqlite: _openSqlite(),
      );
      final doc = await restoredDocument(target.path);
      expect(doc.groups.single.name, 'Default');
      expect(doc.groups.single.id, greaterThan(0));
    });
  });

  group('the UI documents a backup carries', () {
    test('the boot marker is device-local, not backup material', () {
      expect(backupDeviceLocalKeys, contains(BootGuard.preferenceKey));
    });

    test('export drops the boot marker and keeps the user preferences', () {
      final filtered = backupUiDocument(<String, Object?>{
        'preferences': <String, Object?>{
          'theme': 'dark',
          BootGuard.preferenceKey: '{"stage":"starting"}',
        },
      });
      final preferences = filtered['preferences'] as Map;
      expect(preferences['theme'], 'dark');
      expect(preferences.containsKey(BootGuard.preferenceKey), isFalse);
    });

    test('a restore sanitises the container, so a stale marker cannot land', () {
      final filtered = backupUiDocument(<String, Object?>{
        'preferences': <String, Object?>{BootGuard.preferenceKey: '{"stage":"dead"}'},
      });
      expect((filtered['preferences'] as Map).isEmpty, isTrue);
    });

    test("the environment's default payload is already filtered", () {
      final env = envFor('unused/databases/sager_net.db');
      final preferences = env.uiPayload['preferences'] as Map;
      expect(preferences.containsKey(BootGuard.preferenceKey), isFalse);
      expect(preferences['theme'], 'system');
    });
  });

  group('legacy import (data.legacyRows)', () {
    test('a raw read returns the four ADR 0006 table groups while documents are absent', () async {
      final fixture = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(fixture.dispose);
      final documents = documentsDirFromDatabasePath(fixture.path);
      final reply = legacyReply(_openSqlite(), fixture.path, documentsDir: documents);
      expect(reply['profiles'], isNotEmpty);
      expect(reply['groups'], isNotEmpty);
      expect(reply['settings'], isNotEmpty);
      expect(reply['markers'], isNotEmpty);
      // The reader ran read-only: the file is untouched.
      expect(File(fixture.path).existsSync(), isTrue);
      expect(scalar(fixture, 'SELECT COUNT(*) FROM profiles'), '3');
    });

    test('a fresh install answers empty and never creates the database', () async {
      final dir = await Directory.systemTemp.createTemp('legacy-fresh-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = '${dir.path}/databases/sager_net.db';
      final reply = legacyReply(_openSqlite(), path, documentsDir: '${dir.path}/documents');
      for (final key in const [
        'profiles', 'groups', 'settings', 'markers',
      ]) {
        expect(reply[key], isEmpty, reason: key);
      }
      expect(File(path).existsSync(), isFalse);
      expect(Directory('${dir.path}/databases').existsSync(), isFalse);
    });

    test('documents that exist gate their tables out of the reply', () async {
      final fixture = await RoomFixture.create(_openSqlite(), seed: seedRoom);
      addTearDown(fixture.dispose);
      final documents = documentsDirFromDatabasePath(fixture.path);
      Directory(documents).createSync(recursive: true);
      File('$documents/profiles.json').writeAsStringSync('{}');
      final reply = legacyReply(_openSqlite(), fixture.path, documentsDir: documents);
      expect(reply['profiles'], isEmpty);
      expect(reply['groups'], isEmpty);
      expect(reply['settings'], isNotEmpty);
      expect(reply['markers'], isNotEmpty);
    });
  });
}
