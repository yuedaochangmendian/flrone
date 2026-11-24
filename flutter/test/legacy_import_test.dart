// The one-time legacy import off `data.legacyRows` (ADR 0006 stage C2c2a).
//
// The profiles/groups seed is Dart's (`ConfigurationStoreSource`); the rows come from
// the host's raw, read-only read of the retired database, only while
// `profiles.json` is absent. These tests pin the seed-once behaviour and the
// empty/none-created fresh-install answer on the Dart side; the Kotlin reader's
// own contract (never create/migrate, per-table eligibility) is
// `LegacyRoomReaderTest`.

import 'dart:io';

import 'package:flrone/data/configuration_store.dart'
    show ConfigurationStore, RoomNodeReader, documentsDirFromDatabasePath;
import 'package:flrone/data/configuration_store_source.dart'
    show ConfigurationStoreSource, MapRoomNodeReader;
import 'package:flrone/data/sqlite.dart' show Sqlite;
import 'package:flutter_test/flutter_test.dart';

import 'support/backup_fixture.dart';
import 'support/fake_backup_host.dart' show legacyReply;

Sqlite? _sqlite;
String? get _hostPath => Platform.environment['BACKUP_TEST_SQLITE'];

Sqlite _openSqlite() {
  final cached = _sqlite;
  if (cached != null) return cached;
  final path = _hostPath;
  final sqlite = path == null ? Sqlite.open() : Sqlite.openPath(path);
  if (sqlite == null) {
    throw StateError('No sqlite3 available: set BACKUP_TEST_SQLITE to a sqlite3.dll path.');
  }
  return _sqlite = sqlite;
}

void main() {
  test('the legacy rows seed the profiles document once', () async {
    final fixture = await RoomFixture.create(_openSqlite(), seed: seedRoom);
    addTearDown(fixture.dispose);
    final documents = documentsDirFromDatabasePath(fixture.path);
    var reads = 0;
    final store = ConfigurationStore(path: '$documents/profiles.json');
    var marked = false;

    Future<Map<String, dynamic>?> readRows() async {
      reads++;
      return legacyReply(_openSqlite(), fixture.path, documentsDir: documents);
    }

    final source = ConfigurationStoreSource(
      resolvePath: () async => {'path': fixture.path, 'version': 20},
      markerRead: () async => marked,
      markerWrite: () async => marked = true,
      store: store,
      // The device cannot open SQLite from Dart; the host reader answers.
      readRoomRows: () async {
        final reply = await readRows();
        final profiles = reply?['profiles'];
        final groups = reply?['groups'];
        if (profiles is! List || groups is! List) return null;
        return MapRoomNodeReader(
          [for (final row in profiles) Map<String, Object?>.from(row as Map)],
          [for (final row in groups) Map<String, Object?>.from(row as Map)],
        );
      },
    );

    final result = await source.migrate();
    expect(result.migrated, isTrue);
    expect(result.profileCount, 3);
    expect(result.groupCount, 2);
    expect(reads, 1);
    final doc = await store.readFresh();
    expect(doc.profiles.map((p) => p.name), containsAll(['node-a', 'node-b', 'node-c']));
    expect(doc.groups.map((g) => g.name), containsAll(['Default', 'Sub']));

    // A second call shares the completed future: no second broad read.
    await source.migrate();
    expect(reads, 1);

    // A fresh source with the marker set and the document on disk never asks.
    Future<RoomNodeReader?> hostRead() async {
      reads++;
      return null;
    }

    final second = ConfigurationStoreSource(
      resolvePath: () async => {'path': fixture.path, 'version': 20},
      markerRead: () async => marked,
      markerWrite: () async {},
      store: store,
      readRoomRows: hostRead,
    );
    await second.migrate();
    expect(reads, 1);
    source.dispose();
    second.dispose();
  });

  test('a fresh install imports nothing and creates no database', () async {
    final dir = await Directory.systemTemp.createTemp('legacy-import-fresh-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final databasePath = '${dir.path}/databases/sager_net.db';
    final documents = documentsDirFromDatabasePath(databasePath);
    final reply = legacyReply(_openSqlite(), databasePath, documentsDir: documents);
    expect(reply['profiles'], isEmpty);
    expect(reply['groups'], isEmpty);
    expect(File(databasePath).existsSync(), isFalse);
    expect(Directory('${dir.path}/databases').existsSync(), isFalse);

    final store = ConfigurationStore(path: '$documents/profiles.json');
    final source = ConfigurationStoreSource(
      resolvePath: () async => {'path': databasePath, 'version': 20},
      markerRead: () async => false,
      markerWrite: () async {},
      store: store,
      readRoomRows: () async => MapRoomNodeReader(
        [for (final row in reply['profiles'] as List) Map<String, Object?>.from(row as Map)],
        [for (final row in reply['groups'] as List) Map<String, Object?>.from(row as Map)],
      ),
    );
    final result = await source.migrate();
    expect(result.migrated, isTrue);
    expect(result.profileCount, 0);
    expect(result.groupCount, 0);
    // A working (empty) document is still created — the catalog must exist.
    expect(await store.exists(), isTrue);
    expect((await store.readFresh()).profiles, isEmpty);
    // …but the legacy database was not created by the import.
    expect(File(databasePath).existsSync(), isFalse);
    source.dispose();
  });

  test('a document that already exists gates the legacy rows out', () async {
    final fixture = await RoomFixture.create(_openSqlite(), seed: seedRoom);
    addTearDown(fixture.dispose);
    final documents = documentsDirFromDatabasePath(fixture.path);
    final store = ConfigurationStore(path: '$documents/profiles.json');
    await store.replaceAll(sampleDocument());

    final reply = legacyReply(_openSqlite(), fixture.path, documentsDir: documents);
    expect(reply['profiles'], isEmpty);
    expect(reply['groups'], isEmpty);
    expect(reply['routeProfiles'], isNotEmpty);
  });
}
