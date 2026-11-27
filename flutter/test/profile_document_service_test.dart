// The five document-only profile ops that moved off `profiles.platform`.
//
// They are pure `profiles.json` operations, so these tests drive them against
// the real [ConfigurationStore] with an in-memory filesystem: the exact wire
// shapes (`stats`, `nodeList`), the document edits (`reorder`, `nodeReorder`,
// `clearTestResults`) and the two host seams (the catalog refresh and the
// narrow GroupSort reposition) are all observable without a device.

import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/configuration_store_source.dart';
import 'package:flrone/data/profile_document_service.dart';
import 'package:flutter_test/flutter_test.dart';

const _dbPath = '/app/databases/sager_net.db';
const _profilesPath = '/app/files/documents/profiles.json';

ConfigurationRow _group(
  int id, {
  String name = '',
  String url = '',
  int order = 0,
  bool single = false,
}) =>
    ConfigurationRow(
      id: id,
      name: name,
      url: url,
      displayOrder: order,
      single: single,
    );

NodeRow _node(
  int id, {
  int gid = 1,
  int order = 0,
  String? name,
  String type = 'vmess',
  String outboundJson = '{}',
  int latency = 0,
  int latencyAt = 0,
  String? dlSpeed,
  String? ipOut,
  int rx = 100,
}) =>
    NodeRow(
      id: id,
      type: type,
      name: name ?? 'node-$id',
      gid: gid,
      userOrder: order,
      outboundJson: outboundJson,
      latency: latency,
      latencyAt: latencyAt,
      dlSpeed: dlSpeed,
      ipOut: ipOut,
      rx: rx,
    );

/// One service over a real store with the host seams recorded.
class _Harness {
  _Harness({
    required this.store,
    required this.fs,
    List<Map<String, Object?>>? rules,
    String defaultName = 'Default',
  }) {
    service = ProfileDocumentService(
      storeSource: ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath},
        store: store,
      ),
      refreshCatalog: () async => refreshes++,
      repositionTestResults: (groupId) async => repositioned.add(groupId),
      readRouteRules: (dir) async => rules,
      readDefaultGroupName: () async => defaultName,
    );
  }

  final ConfigurationStore store;
  final MemoryConfigurationStoreFs fs;
  late final ProfileDocumentService service;
  int refreshes = 0;
  final repositioned = <int>[];

  /// Seeds the document, then forgets the seed write so a test can assert
  /// whether the op itself wrote.
  Future<void> seed(ProfilesDocument document) async {
    await store.replaceAll(document);
    fs.writes = 0;
    refreshes = 0;
    repositioned.clear();
  }
}

_Harness _harness({
  List<Map<String, Object?>>? rules,
  String defaultName = 'Default',
}) {
  final fs = MemoryConfigurationStoreFs();
  return _Harness(
    store: ConfigurationStore(path: _profilesPath, fs: fs),
    fs: fs,
    rules: rules,
    defaultName: defaultName,
  );
}

void main() {
  group('stats', () {
    test('answers the group membership and the stale-filtered rule count', () async {
      final harness = _harness(rules: [
        {'id': 1, 'outbound_id': -1, 'rule_order': 0}, // built-in target
        {'id': 2, 'outbound_id': 2, 'rule_order': 1}, // names a live profile
        {'id': 3, 'outbound_id': 99, 'rule_order': 2}, // stale outbound
        {'id': 4, 'rule_order': 3}, // absent outbound_id = -1
      ]);
      await harness.seed(ProfilesDocument(
        groups: [_group(1), _group(2, order: 1)],
        profiles: [
          _node(1, gid: 1),
          _node(2, gid: 1, order: 1),
          _node(3, gid: 2),
        ],
      ));

      expect(await harness.service.stats(1), {
        'groups': 1,
        'outbounds': 2,
        'rules': 3,
      });
      expect(await harness.service.stats(2), {
        'groups': 1,
        'outbounds': 1,
        'rules': 3,
      });
      // A read never writes and never needs the host refresh.
      expect(harness.fs.writes, 0);
      expect(harness.refreshes, 0);
    });

    test('a missing or unreadable rule document counts zero rules', () async {
      final harness = _harness(rules: null);
      await harness.seed(ProfilesDocument(
        groups: [_group(1)],
        profiles: [_node(1, gid: 1)],
      ));
      expect((await harness.service.stats(1))['rules'], 0);
    });

    test('a corrupt rule row is dropped by the stale filter, not counted', () async {
      final harness = _harness(rules: [
        {'id': 1, 'outbound_id': '7'},
        {'id': 2, 'outbound_id': 'not-a-number'},
      ]);
      await harness.seed(ProfilesDocument(
        groups: [_group(1)],
        profiles: [_node(7, gid: 1)],
      ));
      // '7' resolves to the live profile; an unparseable id falls back to -1
      // (RouteJsonStore's optLong default) and stays.
      expect((await harness.service.stats(1))['rules'], 2);
    });
  });

  group('reorderGroups', () {
    test('puts the listed groups first, ignores unknown ids and refreshes', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [
        _group(1, name: 'a', order: 0),
        _group(2, name: 'b', order: 1),
        _group(3, name: 'c', order: 2),
      ]));

      await harness.service.reorderGroups([3, 99, 3, 1]);

      final groups = await harness.store.groups();
      expect(groups.map((group) => group.id).toList(), [1, 2, 3]);
      expect(
        {for (final group in groups) group.id: group.displayOrder},
        {1: 1, 2: 2, 3: 0},
        reason: '3 first, 1 next; the unlisted 2 follows',
      );
      expect(harness.fs.writes, 1);
      expect(harness.refreshes, 1);
    });

    test('an empty catalog only refreshes; it does not create a document', () async {
      final harness = _harness();
      // No seed: the store has never been written.
      await harness.service.reorderGroups([1, 2]);
      expect(harness.fs.writes, 0);
      expect(await harness.store.exists(), isFalse);
      expect(harness.refreshes, 1);
    });
  });

  group('clearTestResults', () {
    test('clears every member of the group and asks for the kept sort', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [_group(1), _group(2, order: 1)],
        profiles: [
          _node(1,
              gid: 1,
              latency: 120,
              latencyAt: 1700000000,
              dlSpeed: '10Mbps',
              ipOut: '203.0.113.1'),
          _node(2, gid: 1, order: 1, latency: 80),
          _node(3, gid: 2, latency: 50),
        ],
      ));

      await harness.service.clearTestResults(1);

      final first = (await harness.store.profile(1))!;
      expect(first.latency, 0);
      expect(first.latencyAt, 0);
      expect(first.dlSpeed, isNull);
      expect(first.ipOut, isNull);
      // Traffic and the outbound document survive (ProxyEntity.clearTestResults).
      expect(first.rx, 100);
      expect(first.outboundJson, isNotEmpty);
      expect((await harness.store.profile(2))!.latency, 0);
      expect((await harness.store.profile(3))!.latency, 50,
          reason: 'another group is untouched');
      expect(harness.repositioned, [1]);
      expect(harness.refreshes, 1);
      expect(harness.fs.writes, 1);
    });

    test('an empty group does not write, but still refreshes and skips the sort', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [_group(1)],
        profiles: [_node(1, gid: 1)],
      ));
      await harness.service.clearTestResults(9);
      expect(harness.fs.writes, 0);
      expect(harness.refreshes, 1);
      expect(harness.repositioned, isEmpty);
    });
  });

  group('nodeList', () {
    test('answers the container and its rows in list order', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [
          _group(2, name: 'subscription', url: 'https://example.test', order: 0),
          _group(3, name: 'Single nodes', order: 1, single: true),
        ],
        profiles: [
          _node(11, gid: 3, name: 'Node A', order: 1, latency: 42, latencyAt: 1700000000),
          _node(12, gid: 3, name: 'Node B', order: 0, type: 'chain', latency: 0),
        ],
      ));

      expect(await harness.service.nodeList(), {
        'groupId': 3,
        'groupName': 'Single nodes',
        'nodes': [
          {'id': 12, 'name': 'Node B', 'type': 'Chain Proxy', 'delay': 0, 'testedAt': 0},
          {'id': 11, 'name': 'Node A', 'type': 'VMess', 'delay': 42, 'testedAt': 1700000000000},
        ],
      });
    });

    test('prunes every empty container except the one holding nodes', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [
          _group(1, name: 'Default', order: 0), // legacy, unnamed flag
          _group(2, name: 'Old empty', order: 1, single: true),
          _group(3, name: 'Single nodes', order: 2, single: true),
          _group(4, name: 'subscription', url: 'https://example.test', order: 3),
        ],
        profiles: [
          _node(9, gid: 3, name: 'kept'),
        ],
      ));

      final answer = await harness.service.nodeList();

      expect(answer['groupId'], 3);
      expect((answer['nodes'] as List).length, 1);
      expect((await harness.store.groups()).map((group) => group.id).toList(), [3, 4]);
      expect(harness.refreshes, 1, reason: 'the prune pushes the catalog');
    });

    test('keeps the first container when none holds nodes', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [
          _group(1, name: 'Default', order: 0, single: true),
          _group(2, name: 'Old empty', order: 1, single: true),
          _group(3, name: 'subscription', url: 'https://example.test', order: 2),
        ],
      ));

      final answer = await harness.service.nodeList();

      expect(answer['groupId'], 1);
      expect((await harness.store.groups()).map((group) => group.id).toList(), [1, 3]);
      expect(harness.refreshes, 1);
    });

    test('a subscription is never the single-node container, even named Default', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [
        _group(1, name: 'Default', url: 'https://example.test', order: 0),
      ]));

      expect((await harness.service.nodeList())['groupId'], 0);
    });

    test('no container answers an empty list and writes nothing', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [
        _group(1, name: 'subscription', url: 'https://example.test'),
      ]));

      expect(await harness.service.nodeList(), {
        'groupId': 0,
        'groupName': '',
        'nodes': <Map<String, Object?>>[],
      });
      expect(harness.fs.writes, 0);
      expect(harness.refreshes, 0);
    });

    test('the localized default name marks a legacy container', () async {
      final harness = _harness(defaultName: '默认');
      await harness.seed(ProfilesDocument(groups: [
        _group(1, name: '默认', order: 0),
        _group(2, name: 'subscription', url: 'https://example.test', order: 1),
      ]));
      expect((await harness.service.nodeList())['groupId'], 1);
    });

    test('empty stored names fall back to the protocol label', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [_group(1, name: 'Single', single: true)],
        profiles: [
          _node(1, gid: 1, name: '', type: 'vless'),
        ],
      ));
      final node = ((await harness.service.nodeList())['nodes'] as List).single;
      expect(node['name'], 'VLESS');
      expect(node['type'], 'VLESS');
    });
  });

  group('reorderNodes', () {
    test('writes dense userOrder positions and refreshes', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [_group(1)],
        profiles: [
          _node(1, gid: 1, order: 0),
          _node(2, gid: 1, order: 1),
          _node(3, gid: 1, order: 2),
        ],
      ));

      await harness.service.reorderNodes(1, [3, 1]);

      expect(
        (await harness.store.profilesOfGroup(1)).map((node) => node.id).toList(),
        [3, 1, 2],
      );
      expect(
        (await harness.store.profilesOfGroup(1)).map((node) => node.userOrder).toList(),
        [0, 1, 2],
      );
      expect(harness.fs.writes, 1);
      expect(harness.refreshes, 1);
    });
  });

  group('custom display type', () {
    Future<Object?> typeOf(String outboundJson) async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [_group(1, name: 'Single', single: true)],
        profiles: [
          _node(1, gid: 1, type: 'custom', outboundJson: outboundJson),
        ],
      ));
      return ((await harness.service.nodeList())['nodes'] as List).single['type'];
    }

    test('keeps the outbound/config shapes of Custom.displayType', () async {
      expect(
        await typeOf('{"type":"custom","subtype":"outbound","config":"{\\"type\\":\\"vless\\"}"}'),
        'Custom Vless Outbound',
      );
      expect(await typeOf('{"type":"custom","subtype":"fullconfig","config":"{}"}'),
          'Custom Config');
      expect(await typeOf('{"type":"custom","subtype":"outbound","config":"not-json"}'),
          'Custom Outbound');
      expect(await typeOf('broken'), 'Custom');
    });
  });
}