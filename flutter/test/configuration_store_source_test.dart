// The production wiring of the profile document (ADR 0005 final stage):
// path derivation from data.path, the applyDocument flow Kotlin's parse
// handlers use, and the document diagnostics. The path fact is injected, so
// all of it runs in a plain Dart test.

import 'package:flrone/data/configuration_document_status.dart';
import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/configuration_store_source.dart';
import 'package:flutter_test/flutter_test.dart';

const _dbPath = '/data/user/0/com.throneflclash/databases/sager_net.db';

void main() {
  group('profile document path', () {
    test('documents dir is derived from data.path (databases -> files/documents)', () {
      final dir = documentsDirFromDatabasePath(_dbPath);
      expect(dir, contains('files'));
      expect(dir, endsWith('documents'));
      expect(dir, contains('com.throneflclash'));
    });
  });

  group('ConfigurationStoreSource applyDocument', () {
    test('applies pushed rows into the store and reports it', () async {
      final fs = MemoryConfigurationStoreFs();
      final store = ConfigurationStore(path: '/doc/profiles.json', fs: fs);
      final source = ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
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
      final fs = MemoryConfigurationStoreFs();
      final store = ConfigurationStore(path: '/doc/profiles.json', fs: fs);
      await store.replaceAll(ProfilesDocument(
        groups: [ConfigurationRow(id: 1), ConfigurationRow(id: 2)],
        profiles: [
          NodeRow(id: 1, type: 'vmess', gid: 1, userOrder: 0, rx: 10, latency: 100),
          NodeRow(id: 2, type: 'vmess', gid: 1, userOrder: 1),
        ],
      ));
      final source = ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
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
      final fs = MemoryConfigurationStoreFs();
      final store = ConfigurationStore(path: '/doc/profiles.json', fs: fs);
      await store.replaceAll(ProfilesDocument(
        profiles: [
          NodeRow(id: 1, type: 'vmess', gid: 1),
          NodeRow(id: 2, type: 'vmess', gid: 1),
        ],
        groups: [ConfigurationRow(id: 1)],
      ));
      final source = ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
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

  group('ConfigurationDocumentStatus', () {
    test('status() reports missing, ok (with forced reload) and corrupt', () async {
      final fs = MemoryConfigurationStoreFs();
      final store = ConfigurationStore(path: '/doc/profiles.json', fs: fs);
      final source = ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath, 'version': 20},
        store: store,
      );

      expect(await source.status(), isA<ConfigurationDocumentMissing>());

      await store.replaceAll(ProfilesDocument(
        groups: [ConfigurationRow(id: 1)],
        profiles: [NodeRow(id: 1, type: 'ss', gid: 1)],
      ));
      var ok = await source.status() as ConfigurationDocumentOk;
      expect(ok.groups, 1);
      expect(ok.profiles, 1);
      expect(ok.bytes, isNotNull);

      // Damaging the file behind a cached snapshot must show as corrupt: status()
      // forces a reload instead of trusting the cached document.
      fs.files['/doc/profiles.json'] = '{ broken';
      final corrupt = await source.status();
      expect(corrupt, isA<ConfigurationDocumentCorrupt>());
      expect((corrupt as ConfigurationDocumentCorrupt).message, isNotEmpty);
      source.dispose();
    });
  });
}
