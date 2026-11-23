// The production wiring of the profile document (ADR 0005 final stage):
// path derivation from data.path, the one-time migration trigger, and the
// applyDocument flow Kotlin's parse handlers use. The legacy reader and the
// channel are injected, so all of it runs in a plain Dart test.

import 'package:flrone/data/profile_document_status.dart';
import 'package:flrone/data/profile_store.dart';
import 'package:flrone/data/profile_store_source.dart';
import 'package:flrone/data/sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

const _dbPath = '/data/user/0/com.throneflclash/databases/sager_net.db';

class _Room implements RoomProfileReader {
  _Room(this.rows);

  final List<SqlRow> rows;

  @override
  List<SqlRow> profiles() => rows.where((r) => r['_t'] == 'profiles').toList();

  @override
  List<SqlRow> groups() => rows.where((r) => r['_t'] == 'groups').toList();
}

void main() {
  group('profile document path', () {
    test('documents dir is derived from data.path (databases -> files/documents)', () {
      final dir = documentsDirFromDatabasePath(_dbPath);
      expect(dir, contains('files'));
      expect(dir, endsWith('documents'));
      expect(dir, contains('com.throneflclash'));
    });
  });

  group('ProfileStoreSource applyDocument', () {
    test('applies pushed rows into the store and reports it', () async {
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => true,
        markerWrite: () async {},
        store: store,
      );

      final doc = AppliedProfilesDocument(
        profiles: [
          {
            'id': 1,
            'type': 'vmess',
            'name': 'imported',
            'gid': 1,
            'user_order': 0,
            'outbound_json': '{}',
          },
        ],
        groups: [
          {'id': 1, 'name': 'sub', 'display_order': 1},
        ],
        nextProfileId: 2,
        nextGroupId: 2,
      );
      await source.apply(doc);

      expect((await store.profile(1))?.name, 'imported');
      expect((await store.group(1))?.name, 'sub');
      expect((await store.document).nextProfileId, 2);
      source.dispose();
    });

    test('apply decodes column patches, allocation and reorder from one request', () async {
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      await store.replaceAll(ProfilesDocument(
        groups: [GroupRow(id: 1), GroupRow(id: 2)],
        profiles: [
          ProfileRow(id: 1, type: 'vmess', gid: 1, userOrder: 0, rx: 10, latency: 100),
          ProfileRow(id: 2, type: 'vmess', gid: 1, userOrder: 1),
        ],
      ));
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => true,
        markerWrite: () async {},
        store: store,
      );
      final doc = AppliedProfilesDocument.parse({
        'profilePatches': {'1': {'traffic_dl': 99, 'test_error': null}},
        'profiles': [
          {'id': -1, 'type': 'trojan', 'gid': 1, 'outbound_json': '{}'},
        ],
        'allocateIds': true,
        'reorderGroupId': 1,
        'reorderProfileIds': [2, 1],
      })!;
      final allocated = await source.apply(doc);

      expect(allocated.profiles, {-1: 3});
      expect(allocated.groups, isEmpty);
      final first = (await store.profile(1))!;
      expect(first.rx, 99); // patch, not clobbered by the upsert
      expect(first.type, 'vmess'); // patch did not touch type
      expect((await store.profile(3))?.type, 'trojan'); // allocated
      expect((await store.profilesOfGroup(1)).map((p) => p.id), [2, 1, 3]);
      source.dispose();
    });

    test('delete ids cascade to group members', () async {
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      await store.replaceAll(ProfilesDocument(
        profiles: [
          ProfileRow(id: 1, type: 'vmess', gid: 1),
          ProfileRow(id: 2, type: 'vmess', gid: 1),
        ],
        groups: [GroupRow(id: 1)],
      ));
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => true,
        markerWrite: () async {},
        store: store,
      );
      await source.apply(const AppliedProfilesDocument(deleteGroupIds: [1]));
      expect(await store.profile(1), isNull);
      expect(await store.profile(2), isNull);
      // Never zero groups: a fresh Default is seeded.
      expect((await store.groups()).length, 1);
      source.dispose();
    });
  });

  group('migration trigger', () {
    test('runs once and reads the legacy rows when the host supplies them', () async {
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      final room = _Room([
        {
          '_t': 'profiles',
          'id': 1,
          'type': 'ss',
          'gid': 1,
          'user_order': 0,
          'outbound_json': '{}',
        },
        {'_t': 'groups', 'id': 1, 'name': 'g', 'display_order': 1},
      ]);
      var marked = 0;
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => false,
        markerWrite: () async => marked++,
        store: store,
        readRoomRows: () async => MapRoomProfileReader(
          room.profiles(),
          room.groups(),
        ),
      );
      final result = await source.migrate();
      expect(result.migrated, isTrue);
      expect(result.profileCount, 1);
      expect(marked, 1);
      // A second call shares the same future; no second migration.
      await source.migrate();
      expect(marked, 1);
      source.dispose();
    });

    test('no legacy reader still creates a working empty document', () async {
      // The document must exist even when no host reader is wired: a missing
      // file leaves every Kotlin write with no store while every read goes
      // through DartProfileStore, so the catalog stays empty forever (the
      // v4.14.0-pre.26 import regression). The fresh install (no database) case
      // is exactly this one.
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      var marked = 0;
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => false,
        markerWrite: () async => marked++,
        store: store,
      );
      final result = await source.migrate();
      expect(result.migrated, isTrue);
      expect(marked, 1);
      expect(await store.exists(), isTrue);
      expect(await store.groups(), isEmpty);
      source.dispose();
    });

    test('the host reader is used when this isolate cannot open Room', () async {
      // Android cannot dlopen the platform SQLite, so the migration source is
      // the host's raw read of the retired database (`data.legacyRows`).
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      var hostReads = 0;
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => false,
        markerWrite: () async {},
        store: store,
        readRoomRows: () async {
          hostReads++;
          return MapRoomProfileReader([
            {'id': 2, 'type': 'ss', 'gid': 5, 'user_order': 0, 'outbound_json': '{}'},
          ], [
            {'id': 5, 'name': 'host group', 'display_order': 1},
          ]);
        },
      );
      final result = await source.migrate();
      expect(hostReads, 1);
      expect(result.migrated, isTrue);
      expect(result.profileCount, 1);
      expect(result.groupCount, 1);
      expect((await store.profile(2))?.type, 'ss');
      expect((await store.group(5))?.name, 'host group');
      source.dispose();
    });

    test('a wired-but-failing host reader surfaces instead of blanking the catalog', () async {
      final store = ProfileStore(path: '/doc/profiles.json', fs: MemoryProfileStoreFs());
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => false,
        markerWrite: () async {},
        store: store,
        readRoomRows: () async => null,
      );
      await expectLater(source.migrate(), throwsA(isA<StateError>()));
      expect(await store.exists(), isFalse, reason: 'the legacy rows must stay the only copy');
      source.dispose();
    });

    test('a completed marker does not skip migration when the file is missing', () async {
      // The pre.26–29 failure mode: the write reported success (marker set) but
      // the document never landed. A marker-only short-circuit strands the
      // catalog empty forever; the document must be rebuilt from the legacy rows.
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      final room = _Room([
        {
          '_t': 'profiles',
          'id': 1,
          'type': 'ss',
          'gid': 1,
          'user_order': 0,
          'outbound_json': '{}',
        },
        {'_t': 'groups', 'id': 1, 'name': 'g', 'display_order': 1},
      ]);
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => true, // marker says done
        markerWrite: () async {},
        store: store,
        readRoomRows: () async => MapRoomProfileReader(
          room.profiles(),
          room.groups(),
        ),
      );
      expect(await store.exists(), isFalse);
      final result = await source.migrate();
      expect(result.migrated, isTrue, reason: 'missing file must be rebuilt');
      expect(await store.exists(), isTrue);
      expect((await store.profile(1))?.type, 'ss');
      source.dispose();
    });

    test('a corrupt document is never silently accepted by a completed marker', () async {
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      fs.files['/doc/profiles.json'] = '{ not json';
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => true,
        markerWrite: () async {},
        store: store,
      );
      await expectLater(source.migrate(), throwsA(isA<ProfileStoreFormatException>()));
      expect(fs.files['/doc/profiles.json'], '{ not json', reason: 'never overwrite a corrupt doc on the silent path');
      source.dispose();
    });
  });

  group('ProfileDocumentStatus', () {
    test('status() reports missing, ok (with forced reload) and corrupt', () async {
      final fs = MemoryProfileStoreFs();
      final store = ProfileStore(path: '/doc/profiles.json', fs: fs);
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => true,
        markerWrite: () async {},
        store: store,
      );

      expect(await source.status(), isA<ProfileDocumentMissing>());

      await store.replaceAll(ProfilesDocument(
        groups: [GroupRow(id: 1)],
        profiles: [ProfileRow(id: 1, type: 'ss', gid: 1)],
      ));
      var ok = await source.status() as ProfileDocumentOk;
      expect(ok.groups, 1);
      expect(ok.profiles, 1);
      expect(ok.bytes, isNotNull);

      // Damaging the file behind a cached snapshot must show as corrupt: status()
      // forces a reload instead of trusting the cached document.
      fs.files['/doc/profiles.json'] = '{ broken';
      final corrupt = await source.status();
      expect(corrupt, isA<ProfileDocumentCorrupt>());
      expect((corrupt as ProfileDocumentCorrupt).message, isNotEmpty);
      source.dispose();
    });
  });
}
