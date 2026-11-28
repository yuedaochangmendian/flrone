// The five document-only profile ops that moved off `profiles.platform`.
//
// They are pure `profiles.json` operations, so these tests drive them against
// the real [ConfigurationStore] with an in-memory filesystem: the exact wire
// shapes (`stats`, `nodeList`), the document edits (`reorder`, `nodeReorder`,
// `clearTestResults`) and the two host seams (the catalog refresh and the
// narrow GroupSort reposition) are all observable without a device.

import 'dart:convert';

import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/configuration_store_source.dart';
import 'package:flrone/data/profile_document_service.dart'
    show ProfileSelectionDocument, ProfileDocumentFailure, ProfileDocumentService,
        SelectionDocumentPublisher;
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
      beginGroupEdit: (groupId) async {
        // The host bump precedes the document edit; record where it landed.
        beginOrder.add('begin:$groupId');
      },
      rescheduleSubscriptions: () async => rescheduled.add('schedule'),
      readRouteRules: (dir) async => rules,
      readDefaultGroupName: () async => defaultName,
    );
  }

  final ConfigurationStore store;
  final MemoryConfigurationStoreFs fs;
  late final ProfileDocumentService service;
  int refreshes = 0;
  final repositioned = <int>[];
  final rescheduled = <String>[];
  final beginOrder = <String>[];

  /// Seeds the document, then forgets the seed write so a test can assert
  /// whether the op itself wrote.
  Future<void> seed(ProfilesDocument document) async {
    await store.replaceAll(document);
    fs.writes = 0;
    refreshes = 0;
    repositioned.clear();
    rescheduled.clear();
    beginOrder.clear();
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
          {
            'id': 12,
            'name': 'Node B',
            'type': 'Chain Proxy',
            'typeKey': 'chain',
            'isSelector': false,
            'delay': 0,
            'testedAt': 0,
          },
          {
            'id': 11,
            'name': 'Node A',
            'type': 'VMess',
            'typeKey': 'vmess',
            'isSelector': false,
            'delay': 42,
            'testedAt': 1700000000000,
          },
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

  group('config', () {
    const manifest = '''
{
  "name": "Sub",
  "url": "https://example.test/sub",
  "autoUpdate": true,
  "updateIntervalMinutes": 60,
  "nodes": [
    {
      "tag": "node-a",
      "type": "VMess",
      "delay": 120
    },
    {
      "tag": "node-b",
      "type": "Trojan",
      "delay": 0
    }
  ]
}''';

    test('answers the manifest, the revision and the stats', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [
          ConfigurationRow(
            id: 1,
            name: 'Sub',
            url: 'https://example.test/sub',
            subLastUpdate: 1700000000,
            subOptionsJson: '{"update_interval":60}',
            displayOrder: 0,
          ),
        ],
        profiles: [
          _node(1, gid: 1, name: 'node-a', type: 'vmess', latency: 120, order: 0),
          _node(2, gid: 1, name: 'node-b', type: 'trojan', latency: 0, order: 1),
        ],
      ));

      final answer = await harness.service.config(1);

      expect(answer['content'], manifest);
      expect(answer['formatted'], manifest,
          reason: 'Kotlin answered the same pretty text twice');
      expect(answer['revision'], '1700000000');
      expect(answer['stats'], {'groups': 1, 'outbounds': 2, 'rules': 0});
      // A read never writes and never needs the host refresh.
      expect(harness.fs.writes, 0);
      expect(harness.refreshes, 0);
      expect(harness.beginOrder, isEmpty);
    });

    test('a blank name is the localized default; a local group is not auto-updated', () async {
      final harness = _harness(defaultName: '默认');
      await harness.seed(ProfilesDocument(
        groups: [
          ConfigurationRow(id: 1, name: '', skipAutoUpdate: true, displayOrder: 0),
        ],
      ));

      final answer = await harness.service.config(1);
      expect(answer['content'], '''
{
  "name": "默认",
  "url": "",
  "autoUpdate": false,
  "updateIntervalMinutes": 0,
  "nodes": []
}''');
    });

    test('the interval reads the codec rule: only a whole number counts', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [
        ConfigurationRow(id: 1, name: 'Sub', url: 'https://example.test/sub', subOptionsJson: '{"update_interval":"60"}'),
        ConfigurationRow(id: 2, name: 'Sub two', url: 'https://example.test/two', subOptionsJson: '{"update_interval":59.5}', displayOrder: 1),
      ]));

      // SubscriptionOptions.parse uses JsonValues.toInt: a string or a
      // fractional number is not an interval.
      expect((await harness.service.config(1))['content'], contains('"updateIntervalMinutes": 0'));
      expect((await harness.service.config(2))['content'], contains('"updateIntervalMinutes": 0'));
    });

    test('a missing group is refused with the Kotlin text', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [_group(1)]));

      await expectLater(
        harness.service.config(9),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'No configuration with id 9',
        )),
      );
    });
  });

  group('read', () {
    test('answers the same manifest text without writing', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [
          ConfigurationRow(id: 1, name: 'Sub', url: 'https://example.test/sub', displayOrder: 0),
        ],
        profiles: [
          _node(1, gid: 1, name: 'node-a', type: 'vless', latency: 42, order: 0),
        ],
      ));

      final text = await harness.service.read(1);

      expect(text, '''
{
  "name": "Sub",
  "url": "https://example.test/sub",
  "autoUpdate": true,
  "updateIntervalMinutes": 0,
  "nodes": [
    {
      "tag": "node-a",
      "type": "VLESS",
      "delay": 42
    }
  ]
}''');
      expect((await harness.service.config(1))['content'], text);
      expect(harness.fs.writes, 0);
      expect(harness.refreshes, 0);
    });

    test('a missing group is refused with the Kotlin text', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [_group(1)]));
      await expectLater(
        harness.service.read(9),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'No configuration with id 9',
        )),
      );
    });
  });

  group('write', () {
    ConfigurationRow sub({
      int id = 1,
      int revision = 5,
      String url = 'https://example.test/sub',
      bool skipAutoUpdate = true,
      String options = '{"update_interval":60}',
      String metadata = '{"valid":true}',
      String info = 'leftover',
    }) =>
        ConfigurationRow(
          id: id,
          name: 'Sub',
          url: url,
          subLastUpdate: revision,
          skipAutoUpdate: skipAutoUpdate,
          subOptionsJson: options,
          subMetadataJson: metadata,
          info: info,
          displayOrder: 0,
        );

    test('applies name, autoUpdate and the interval; a URL edit resets the fetch state', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [sub()],
        profiles: [_node(1, gid: 1, name: 'node-a', order: 0)],
      ));

      final answer = await harness.service.write(1, '5', '''
{
  "name": "Renamed",
  "url": "https://example.test/other",
  "autoUpdate": true,
  "updateIntervalMinutes": 90,
  "nodes": [{"tag": "node-a", "type": "VMess", "delay": 0}]
}''');

      final row = (await harness.store.group(1))!;
      expect(row.name, 'Renamed');
      expect(row.url, 'https://example.test/other');
      expect(row.skipAutoUpdate, false);
      expect(row.subOptionsJson, '{"update_interval":90}');
      // A URL edit invalidates what the old server said.
      expect(row.subLastUpdate, 0);
      expect(row.subMetadataJson, '{}');
      expect(row.info, '');
      expect(row.displayOrder, 0, reason: 'other columns stay');

      // The intent bump precedes the local write, then the poller is re-planned,
      // then the catalog is pushed.
      expect(harness.beginOrder, ['begin:1']);
      expect(harness.rescheduled, ['schedule']);
      expect(harness.refreshes, 1);
      expect(harness.fs.writes, 1);

      // The answer is the post-write manifest.
      expect(answer['revision'], '0');
      expect(answer['content'], contains('"name": "Renamed"'));
      expect(answer['content'], contains('"url": "https://example.test/other"'));
      expect(answer['stats'], {'groups': 1, 'outbounds': 1, 'rules': 0});
    });

    test('a save without a URL change keeps the fetch state and leaves the poller alone', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [sub()],
        profiles: [_node(1, gid: 1, name: 'node-a', order: 0)],
      ));

      await harness.service.write(1, '5', '''
{
  "name": "Renamed",
  "url": "https://example.test/sub",
  "nodes": [{"tag": "node-a", "type": "VMess", "delay": 0}]
}''');

      final row = (await harness.store.group(1))!;
      expect(row.name, 'Renamed');
      expect(row.subLastUpdate, 5);
      expect(row.subMetadataJson, '{"valid":true}');
      expect(row.info, 'leftover');
      expect(row.subOptionsJson, '{"update_interval":60}');
      expect(harness.rescheduled, isEmpty);
      expect(harness.refreshes, 1);
    });

    test('removes update_interval when the editor sets zero', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [sub(options: '{"keep_working":true,"update_interval":60}')],
      ));

      await harness.service.write(1, '5', '{"updateIntervalMinutes": 0}');

      // Defaults are omitted by the codec, and its key order is sorted.
      expect((await harness.store.group(1))!.subOptionsJson,
          '{"keep_working":true}');
      expect(harness.rescheduled, isEmpty);
    });

    test('a stale revision is refused before the document moves', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [sub(revision: 9)]));

      await expectLater(
        harness.service.write(1, '8', '{"name": "X"}'),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'The configuration was updated since it was opened; reload it and try again',
        )),
      );
      expect((await harness.store.group(1))!.name, 'Sub');
      expect(harness.fs.writes, 0);
      expect(harness.refreshes, 0);
      // The bump ran before the refused edit; that only discards a stale
      // subscription answer.
      expect(harness.beginOrder, ['begin:1']);
    });

    test('an empty or null revision is the caller that does not track one', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [sub(revision: 9)]));
      await harness.service.write(1, null, '{"name": "A"}');
      await harness.service.write(1, '', '{"name": "B"}');
      expect((await harness.store.group(1))!.name, 'B');
      expect(harness.refreshes, 2);
    });

    test('a foreign key is refused, not dropped', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [sub()]));

      await expectLater(
        harness.service.write(1, '5', '{"dns": {"servers": []}, "name": "X"}'),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          '"dns" is not part of the configuration; DNS, routing rules and log settings are app settings',
        )),
      );
      expect((await harness.store.group(1))!.name, 'Sub');
      expect(harness.fs.writes, 0);
    });

    test('a node count change is refused', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [sub()],
        profiles: [
          _node(1, gid: 1, name: 'node-a', order: 0),
          _node(2, gid: 1, name: 'node-b', order: 1),
        ],
      ));

      await expectLater(
        harness.service.write(1, '5',
            '{"nodes": [{"tag": "node-a", "type": "VMess", "delay": 0}]}'),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'Node membership is edited on the Proxies screen, not here',
        )),
      );
      expect(harness.fs.writes, 0);
    });

    test('same-count node edits are refused by the canonical comparison', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [sub()],
        profiles: [_node(1, gid: 1, name: 'node-a', latency: 120, order: 0)],
      ));

      await expectLater(
        harness.service.write(1, '5',
            '{"nodes": [{"tag": "node-a", "type": "VMess", "delay": 0}]}'),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'Node fields are edited on the Proxies screen, not here',
        )),
      );
      expect(harness.fs.writes, 0);
    });

    test('a round trip passes: key order and numeric form do not matter', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [sub()],
        profiles: [_node(1, gid: 1, name: 'node-a', latency: 120, order: 0)],
      ));

      // delay as 120.0 and the keys out of order: canonical JSON normalises
      // both, as the Kotlin comparison did.
      await harness.service.write(1, '5',
          '{"nodes": [{"delay": 120.0, "type": "VMess", "tag": "node-a"}]}');

      expect((await harness.store.group(1))!.name, 'Sub',
          reason: 'no field of the manifest changed');
      expect(harness.fs.writes, 1, reason: 'the save is still a save');
      expect(harness.refreshes, 1);
    });

    test('an absent nodes key makes no membership claim', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(
        groups: [sub(skipAutoUpdate: false)],
        profiles: [_node(1, gid: 1, name: 'node-a', order: 0)],
      ));

      await harness.service.write(1, '5', '{"autoUpdate": false}');

      expect((await harness.store.group(1))!.skipAutoUpdate, true);
      expect(harness.fs.writes, 1);
    });

    test('an unparseable document is refused before the intent bump', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [sub()]));

      await expectLater(
        harness.service.write(1, '5', 'not-json'),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'Not valid JSON',
        )),
      );
      await expectLater(
        harness.service.write(1, '5', '[]'),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'The configuration must be a JSON object',
        )),
      );
      expect(harness.beginOrder, isEmpty);
      expect(harness.fs.writes, 0);
    });

    test('a missing group is refused with the Kotlin text', () async {
      final harness = _harness();
      await harness.seed(ProfilesDocument(groups: [sub()]));

      await expectLater(
        harness.service.write(9, '5', '{"name": "X"}'),
        throwsA(isA<ProfileDocumentFailure>().having(
          (error) => error.message,
          'message',
          'No configuration with id 9',
        )),
      );
      expect(harness.fs.writes, 0);
      expect(harness.refreshes, 0);
    });
  });

  group('profile selection document (ADR 0008 P1-5)', () {
    test('a selection change writes the exact four-key shape atomically', () async {
      final fs = MemoryConfigurationStoreFs();
      final doc = ProfileSelectionDocument('/app/files/documents', fs: fs);
      final when = DateTime.fromMillisecondsSinceEpoch(1_700_000_000_123);

      await doc.write(
        selectedProfileId: 12,
        currentGroupId: 7,
        now: when,
      );

      expect(fs.writes, 1);
      expect(fs.files[doc.path],
          '{"version":1,"selectedProfileId":12,"currentGroupId":7,"updatedAt":1700000000123}');
      // The contract is exactly these four keys — no extra field for a reader
      // to mis-parse.
      final decoded = jsonDecode(fs.files[doc.path]!) as Map<String, dynamic>;
      expect(decoded.keys.toList(),
          ['version', 'selectedProfileId', 'currentGroupId', 'updatedAt']);
      expect(decoded['version'], 1);
      expect(decoded['selectedProfileId'], 12);
      expect(decoded['currentGroupId'], 7);
      expect(decoded['updatedAt'], 1_700_000_000_123);
    });

    test('each new selection replaces the file; a stable clock still bumps the stamp', () async {
      final fs = MemoryConfigurationStoreFs();
      final doc = ProfileSelectionDocument('/app/files/documents', fs: fs);

      await doc.write(selectedProfileId: 1, currentGroupId: 1,
          now: DateTime.fromMillisecondsSinceEpoch(100));
      await doc.write(selectedProfileId: 2, currentGroupId: 3,
          now: DateTime.fromMillisecondsSinceEpoch(200));

      expect(fs.writes, 2);
      final decoded = jsonDecode(fs.files[doc.path]!) as Map<String, dynamic>;
      expect(decoded['selectedProfileId'], 2);
      expect(decoded['currentGroupId'], 3);
      expect(decoded['updatedAt'], 200);
    });

    test('read parses a valid document and rejects absent/malformed ones', () async {
      final fs = MemoryConfigurationStoreFs();
      final doc = ProfileSelectionDocument('/app/files/documents', fs: fs);

      expect(await doc.read(), isNull);
      await doc.write(selectedProfileId: 5, currentGroupId: 6,
          now: DateTime.fromMillisecondsSinceEpoch(300));
      final state = await doc.read();
      expect(state, isNotNull);
      expect(state!.selectedProfileId, 5);
      expect(state.currentGroupId, 6);
      expect(state.updatedAt, 300);

      await fs.write(doc.path, '{bad json');
      expect(await doc.read(), isNull);
      await fs.write(doc.path, '{"version":2,"selectedProfileId":5,"currentGroupId":6,"updatedAt":300}');
      expect(await doc.read(), isNull);
    });

    test('publisher hydrates from disk and does not rewrite an unchanged selection', () async {
      final fs = MemoryConfigurationStoreFs();
      final doc = ProfileSelectionDocument('/app/files/documents', fs: fs);
      await doc.write(selectedProfileId: 4, currentGroupId: 7,
          now: DateTime.fromMillisecondsSinceEpoch(100));
      fs.writes = 0;

      // A fresh publisher (a fresh UI process) must hydrate, not rewrite.
      final publisher = SelectionDocumentPublisher(doc);
      expect(await publisher.publish(profileId: 4, groupId: 7), isFalse);
      expect(fs.writes, 0);

      // Same selection again: still no write.
      expect(await publisher.publish(profileId: 4, groupId: 7), isFalse);
      expect(fs.writes, 0);

      // A changed selection writes exactly once.
      expect(await publisher.publish(profileId: 9, groupId: 7), isTrue);
      expect(fs.writes, 1);
      expect((await doc.read())!.selectedProfileId, 9);
      expect(await publisher.publish(profileId: 9, groupId: 7), isFalse);
      expect(fs.writes, 1);
    });

    test('publisher resets the cache on a failed write so a later frame retries', () async {
      final fs = _FailFirstWriteFs();
      final doc = ProfileSelectionDocument('/app/files/documents', fs: fs);
      final publisher = SelectionDocumentPublisher(doc);
      final errors = <Object>[];

      // First write fails: the cache is reset, so a later frame carrying the
      // same selection writes again instead of being suppressed as unchanged.
      expect(await publisher.publish(profileId: 1, groupId: 7, onError: errors.add), isTrue);
      expect(errors, isNotEmpty);
      expect(fs.writes, 0);

      expect(await publisher.publish(profileId: 1, groupId: 7, onError: errors.add), isTrue);
      expect(fs.writes, 1);
      expect((await doc.read())!.selectedProfileId, 1);
    });

    test('publisher serializes two rapid publishes in order', () async {
      final fs = MemoryConfigurationStoreFs();
      final doc = ProfileSelectionDocument('/app/files/documents', fs: fs);
      final publisher = SelectionDocumentPublisher(doc);

      // Both calls start before either write completes; the chain guarantees
      // the second (newer) selection lands last.
      final first = publisher.publish(profileId: 1, groupId: 7);
      final second = publisher.publish(profileId: 2, groupId: 8);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(fs.writes, 2);
      final state = (await doc.read())!;
      expect(state.selectedProfileId, 2);
      expect(state.currentGroupId, 8);
    });
  });
}

/// Fails the first write once, then behaves like the in-memory filesystem.
class _FailFirstWriteFs extends MemoryConfigurationStoreFs {
  bool _failed = false;

  @override
  Future<void> write(String path, String content) {
    if (!_failed) {
      _failed = true;
      throw StateError('simulated write failure');
    }
    return super.write(path, content);
  }
}