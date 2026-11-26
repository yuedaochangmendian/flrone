// ADR 0005 final stage: tests for the Dart-owned profile/group document.
//
// These run in plain Dart (no platform channel, no libsqlite3): the filesystem
// is injected, so every rule that protects user data — schema fidelity, atomic
// writes, dense reordering — is checked without a device.

import 'dart:convert';

import 'package:flrone/data/configuration_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _path = '/app/files/documents/profiles.json';

NodeRow _profile(int id, {int gid = 1, int order = 0, String type = 'vmess'}) =>
    NodeRow(
      id: id,
      type: type,
      name: 'node-$id',
      gid: gid,
      userOrder: order,
      outboundJson: '{"tag":"node-$id","type":"$type"}',
      latency: 120,
      latencyAt: 1700000000,
      dlSpeed: '10Mbps',
      rx: 100,
      tx: 200,
    );

ConfigurationRow _group(int id, {String name = '', String url = '', int order = 0}) =>
    ConfigurationRow(
      id: id,
      name: name,
      url: url,
      displayOrder: order,
      subOptionsJson: '{"update_interval":60}',
      subMetadataJson: '{"valid":true,"total":1000}',
    );

void main() {
  group('ProfilesDocument schema', () {
    test('profiles carry every container column with the exact names', () {
      final row = _profile(7);
      final json = row.toJson();
      expect(
        json.keys.toSet(),
        NodeRow.columns.toSet(),
        reason: 'NodeRow.toJson must mirror the ProxyEntity columns exactly',
      );
      expect(json['id'], 7);
      expect(json['user_order'], 0);
      expect(json['traffic_dl'], 100);
      expect(json['traffic_up'], 200);
      expect(json['outbound_json'], contains('vmess'));
    });

    test('groups carry every ProxyGroup column with the exact names', () {
      final json = _group(1).toJson();
      expect(json.keys.toSet(), ConfigurationRow.columns.toSet());
      expect(ConfigurationRow.columns, contains('import_sub_route'));
      expect(ConfigurationRow.columns, contains('column_width_json'));
      expect(ConfigurationRow.columns.length, 23);
    });

    test('the single-node container carries a document-only flag', () {
      // A normal group's row keeps exactly the container columns.
      expect(_group(1).toJson().containsKey('single'), isFalse);
      expect(ConfigurationRow.columns, isNot(contains('single')));

      final container = ConfigurationRow(id: 2, name: 'Default', single: true);
      final json = container.toJson();
      expect(json['single'], isTrue);
      expect(ConfigurationRow.fromJson(json).single, isTrue);
      expect(ConfigurationRow.fromJson(_group(1).toJson()).single, isFalse);
      // A patch that does not mention the flag must keep it (the marker cannot
      // be lost by an unrelated group edit).
      expect(container.applyPatch({'name': 'Renamed'}).single, isTrue);
    });

    test('document roundtrips profiles, groups and next ids', () async {
      final fs = MemoryConfigurationStoreFs();
      final store = ConfigurationStore(path: _path, fs: fs);
      final doc = ProfilesDocument(
        nextProfileId: 9,
        nextGroupId: 3,
        profiles: [_profile(7), _profile(8)],
        groups: [_group(1, order: 0), _group(2, order: 1)],
      );
      await store.replaceAll(doc);
      // read back through a fresh store to prove the bytes, not the cache
      final restored = await ConfigurationStore(path: _path, fs: fs).document;
      expect(restored.profiles.length, 2);
      expect(restored.groups.length, 2);
      expect(restored.nextProfileId, 9);
      expect(restored.nextGroupId, 3);
      expect(restored.profiles.first.name, 'node-7');
      expect(restored.groups.last.displayOrder, 1);
    });

    test('JSON envelope uses version/name/next ids and container table names', () {
      final json = ProfilesDocument(
        nextProfileId: 5,
        nextGroupId: 2,
        profiles: [_profile(1)],
        groups: [_group(1)],
      ).toJson();
      expect(json['version'], profilesDocumentVersion);
      expect(json['name'], 'profiles');
      expect(json['nextProfileId'], 5);
      expect(json['nextGroupId'], 2);
      expect(json['profiles'], isA<List>());
      expect(json['groups'], isA<List>());
    });

    test('a wrong version is rejected, not silently upgraded', () {
      final fs = MemoryConfigurationStoreFs();
      fs.files[_path] = jsonEncode({'version': 999, 'profiles': [], 'groups': []});
      final store = ConfigurationStore(path: _path, fs: fs);
      expect(store.document, throwsA(isA<ConfigurationStoreFormatException>()));
    });
  });

  group('ConfigurationStore CRUD', () {
    test('create/list/profile/group and next ids', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(groups: [_group(1)]));

      final p = await store.createNode(type: 'vmess', name: 'a', gid: 1);
      expect(p.id, 1);
      expect(p.userOrder, 0);
      final g = await store.createGroup(name: 'second');
      expect(g.id, 2);
      expect(g.displayOrder, 1);

      expect((await store.list()).length, 1);
      expect((await store.groups()).length, 2);
      expect((await store.profile(1))?.name, 'a');
      expect((await store.group(2))?.name, 'second');
      expect((await store.document).nextProfileId, 2);
      expect((await store.document).nextGroupId, 3);
    });

    test('delete compacts userOrder to stay dense', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(
        groups: [_group(1)],
        profiles: [_profile(1, order: 0), _profile(2, order: 1), _profile(3, order: 2)],
      ));
      expect(await store.deleteNode(2), isTrue);
      final orders = (await store.profilesOfGroup(1)).map((p) => p.userOrder).toList();
      expect(orders, [0, 1]);
    });

    test('reorder keeps only group members and stays dense', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(
        groups: [_group(1), _group(2)],
        profiles: [
          _profile(1, gid: 1, order: 0),
          _profile(2, gid: 1, order: 1),
          _profile(3, gid: 1, order: 2),
          _profile(9, gid: 2, order: 0),
        ],
      ));
      await store.reorderGroup(1, [3, 1]);
      final ids = (await store.profilesOfGroup(1)).map((p) => p.id).toList();
      expect(ids, [3, 1, 2]);
      // untouched group still intact
      expect((await store.profile(9))?.gid, 2);
    });

    test('clearTestResults resets test columns but keeps traffic and data', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(profiles: [_profile(1)]));
      await store.clearTestResults([1]);
      final p = (await store.profile(1))!;
      expect(p.latency, 0);
      expect(p.latencyAt, 0);
      expect(p.dlSpeed, isNull);
      expect(p.ipOut, isNull);
      expect(p.rx, 100); // traffic preserved
      expect(p.outboundJson, contains('vmess')); // outbound preserved
    });

    test('addTraffic accumulates deltas atomically on the current row', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(profiles: [_profile(1)]));
      await store.addTraffic({1: (rx: 50, tx: 25)});
      await store.addTraffic({1: (rx: 50, tx: 25)});
      final p = (await store.profile(1))!;
      expect(p.rx, 200); // 100 initial + 50 + 50
      expect(p.tx, 250); // 200 initial + 25 + 25
    });

    test('clearTraffic zeroes rx/tx only', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(profiles: [_profile(1)]));
      await store.clearTraffic([1]);
      final p = (await store.profile(1))!;
      expect(p.rx, 0);
      expect(p.tx, 0);
      expect(p.latency, 120);
    });

    test('importRows merges by id and advances next ids', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(
        profiles: [_profile(1)],
        groups: [_group(1)],
      ));
      await store.importRows(
        profiles: [_profile(1, type: 'trojan'), _profile(5)],
        groups: [_group(2)],
      );
      expect((await store.profile(1))?.type, 'trojan'); // replaced
      expect(await store.profile(5), isNotNull); // appended
      expect((await store.document).nextProfileId, 6);
      expect((await store.document).nextGroupId, 3);
    });

    test('importRowsAllocating assigns real ids to negative client ids', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(groups: [_group(1)]));
      final allocated = await store.importRowsAllocating(
        profiles: [
          _profile(-1, gid: 1),
          _profile(-2, gid: 1, type: 'trojan'),
        ],
        groups: [_group(-1, name: 'new')],
      );
      expect(allocated.profiles, {-1: 1, -2: 2});
      expect(allocated.groups, {-1: 2});
      expect((await store.profile(1))?.type, 'vmess');
      expect((await store.profile(2))?.type, 'trojan');
      expect((await store.group(2))?.name, 'new');
      expect((await store.document).nextProfileId, 3);
      expect((await store.document).nextGroupId, 3);
    });

    test('column patches update only named fields and clear explicit nulls', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(groups: [_group(1)], profiles: [_profile(1)]));
      await store.patchProfiles({
        1: {
          'traffic_dl': 999,
          'latency': -1,
          'test_error': null,
          'dl_speed': null,
        },
      });
      final p = (await store.profile(1))!;
      expect(p.rx, 999);
      expect(p.latency, -1);
      expect(p.testError, isNull);
      expect(p.dlSpeed, isNull);
      expect(p.type, 'vmess'); // untouched
      expect(p.name, 'node-1'); // untouched
      await store.patchGroups({1: {'route_id': -1, 'sub_last_update': 42}});
      expect((await store.group(1))?.subLastUpdate, 42);
      expect((await store.group(1))?.name, ''); // untouched
    });

    test('deleteGroup cascades to its profiles and refuses the last group', () async {
      final store = ConfigurationStore(path: _path, fs: MemoryConfigurationStoreFs());
      await store.replaceAll(ProfilesDocument(
        groups: [_group(1)],
        profiles: [_profile(1, gid: 1)],
      ));
      expect(await store.deleteGroup(1), isFalse); // never delete the last group
      await store.replaceAll(ProfilesDocument(
        groups: [_group(1), _group(2)],
        profiles: [_profile(1, gid: 1)],
      ));
      expect(await store.deleteGroup(1), isTrue);
      expect(await store.profile(1), isNull); // cascade
    });
  });

}
