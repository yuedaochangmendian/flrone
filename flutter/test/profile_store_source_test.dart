// The production wiring of the profile document (ADR 0005 final stage):
// path derivation from data.path, the one-time migration trigger, and the
// applyDocument flow Kotlin's parse handlers use. Room and the channel are
// injected, so all of it runs in a plain Dart test.

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
    test('runs once and reads Room when the source is available', () async {
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
        openRoom: () async => room,
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

    test('no Room source does not mark migrated on a fresh install', () async {
      final store = ProfileStore(path: '/doc/profiles.json', fs: MemoryProfileStoreFs());
      var marked = 0;
      final source = ProfileStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        markerRead: () async => false,
        markerWrite: () async => marked++,
        store: store,
        openRoom: () async => null,
      );
      final result = await source.migrate();
      expect(result.migrated, isFalse);
      expect(marked, 0); // next launch retries if a DB appears
      source.dispose();
    });
  });
}
