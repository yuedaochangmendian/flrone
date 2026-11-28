// S7: the auto-selector editor's document state lives in Dart now.
//
// The selector row is one `profiles.json` profile whose `outbound_json` is the
// `AutoSelector.exportToJson` document. These tests drive the real
// [ConfigurationStore] with an in-memory filesystem: the editor seed (`info`),
// the field merge (`save`), the pin and the create — including the runtime state
// (`pool`/`last_built`/`history`) an editor save must carry through untouched.

import 'dart:convert';

import 'package:flrone/data/auto_selector_document.dart';
import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/configuration_store_source.dart';
import 'package:flrone/data/profile_document_service.dart'
    show ProfileDocumentFailure, ProfileDocumentService;
import 'package:flutter_test/flutter_test.dart';

const _profilesPath = '/app/files/documents/profiles.json';

ConfigurationRow _group(
  int id, {
  String name = '',
  int order = 0,
  bool single = false,
}) =>
    ConfigurationRow(
      id: id,
      name: name,
      displayOrder: order,
      single: single,
    );

NodeRow _selectorRow(
  int id, {
  int gid = 1,
  String name = 'Auto',
  AutoSelectorDocument? document,
}) {
  final selector = document ?? AutoSelectorDocument.defaults();
  if (document == null) {
    selector
      ..gids = <int>[gid]
      ..name = name;
  }
  return NodeRow(
    id: id,
    type: autoSelectorType,
    name: selector.name,
    gid: gid,
    outboundJson: selector.encode(),
  );
}

class _Harness {
  _Harness({String defaultName = 'Default'}) {
    fs = MemoryConfigurationStoreFs();
    store = ConfigurationStore(path: _profilesPath, fs: fs);
    service = ProfileDocumentService(
      storeSource: ConfigurationStoreSource(
        resolvePath: () async => {'path': '/app/databases/sager_net.db'},
        store: store,
      ),
      refreshCatalog: () async => refreshes++,
      repositionTestResults: (groupId) async {},
      beginGroupEdit: (groupId) async {},
      rescheduleSubscriptions: () async {},
      readDefaultGroupName: () async => defaultName,
    );
  }

  late final MemoryConfigurationStoreFs fs;
  late final ConfigurationStore store;
  late final ProfileDocumentService service;
  int refreshes = 0;

  Future<void> seed(ProfilesDocument document) async {
    await store.replaceAll(document);
    fs.writes = 0;
    refreshes = 0;
  }
}

void main() {
  group('AutoSelectorDocument', () {
    test('an empty object is not a selector document', () {
      expect(AutoSelectorDocument.isSelectorJson(<String, dynamic>{}), isFalse);
      expect(
        AutoSelectorDocument.isSelectorJson(<String, dynamic>{'pinned_id': 1}),
        isTrue,
      );
    });

    test('a missing key takes the Kotlin member default', () {
      final selector = AutoSelectorDocument.fromJson(<String, dynamic>{});
      expect(selector.name, '');
      expect(selector.gids, isEmpty);
      expect(selector.excludeUnavailable, isTrue);
      expect(selector.poolCap, 1000);
      expect(selector.buildLimit, 300);
      expect(selector.intervalSec, 300);
      expect(selector.balanceMode, 'rotate');
      expect(selector.pinnedId, -1);
    });

    test('a legacy gid becomes the first tracked group', () {
      final selector =
          AutoSelectorDocument.fromJson(<String, dynamic>{'gid': 7});
      expect(selector.gids, <int>[7]);
      expect(selector.toJson()['gid'], 7);
    });

    test('the stored text carries every exportToJson key, sorted, with gid first group', () {
      final selector = AutoSelectorDocument.defaults()
        ..gids = <int>[4, 9]
        ..name = 'Sel';
      final encoded = selector.encode();
      final decoded = Map<String, dynamic>.from(jsonDecode(encoded) as Map);
      expect(decoded.keys.toList(), selector.toJson().keys.toList());
      expect(decoded['gid'], 4);
      expect(decoded['gids'], <int>[4, 9]);
      expect(decoded['type'], autoSelectorType);
      expect(decoded['name'], 'Sel');
      // Sorted keys are the JsonWriter shape Kotlin/Go already parse.
      final keys = decoded.keys.toList();
      final sorted = <String>[...keys]..sort();
      expect(keys, sorted);
    });

    test('normalize clamps in the Kotlin order', () {
      final selector = AutoSelectorDocument.fromJson(<String, dynamic>{
        'gids': <int>[3, 3, -1],
        'interval_sec': 1,
        'bench_interval_sec': 2,
        'watch_interval_sec': 100,
        'active_size': 1,
        'expected': 4,
        'sampling': 99,
        'dial_retries': 9,
        'balance_interval_sec': 1,
        'balance_mode': 'sticky',
      });
      expect(selector.gids, <int>[3]);
      expect(selector.intervalSec, 10);
      expect(selector.benchIntervalSec, 10);
      expect(selector.watchIntervalSec, 10);
      expect(selector.activeSize, 4, reason: 'activeSize rises to expected');
      expect(selector.sampling, 60);
      expect(selector.dialRetries, 5);
      expect(selector.balanceIntervalSec, 5);
      expect(selector.balanceMode, 'rotate');
    });
  });

  group('ProfileDocumentService auto-selector', () {
    test('info is the editor seed with groups in tab order', () async {
      final harness = _Harness();
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[
          _group(2, name: 'Zeta', order: 2),
          _group(1, name: '', order: 1),
        ],
        profiles: <NodeRow>[
          _selectorRow(
            9,
            gid: 2,
            name: 'Auto',
            document: AutoSelectorDocument.defaults()
              ..gids = <int>[2]
              ..name = 'Auto'
              ..pinnedId = 5
              ..pool = <int>[5, 6],
          ),
        ],
      ));

      final info = await harness.service.autoSelectorInfo(9);

      expect(info['id'], 9);
      expect(info['name'], 'Auto');
      expect(info['gids'], <int>[2]);
      expect(info['pinnedId'], 5);
      expect(info['poolCap'], 1000);
      expect(info['balanceMode'], 'rotate');
      expect(info['excludeUnavailable'], isTrue);
      expect(info['groups'], <Map<String, Object?>>[
        {'id': 1, 'name': 'Default'},
        {'id': 2, 'name': 'Zeta'},
      ]);
      expect(harness.refreshes, 0, reason: 'a read never writes');
    });

    test('info normalises the stored document like the Kotlin parse', () async {
      final harness = _Harness();
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[_group(1, name: 'G')],
        profiles: <NodeRow>[
          _selectorRow(
            9,
            gid: 1,
            document: AutoSelectorDocument.defaults()
              ..gids = <int>[1]
              ..intervalSec = 1,
          ),
        ],
      ));

      final info = await harness.service.autoSelectorInfo(9);
      expect(info['intervalSec'], 10);
    });

    test('info refuses a missing row and a non-selector row', () async {
      final harness = _Harness();
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[_group(1, name: 'G')],
        profiles: <NodeRow>[
          NodeRow(id: 7, type: 'vmess', name: 'node', gid: 1),
        ],
      ));

      await expectLater(
        harness.service.autoSelectorInfo(9),
        throwsA(isA<ProfileDocumentFailure>()),
      );
      await expectLater(
        harness.service.autoSelectorInfo(7),
        throwsA(isA<ProfileDocumentFailure>()),
      );
    });

    test('save merges the editor values and keeps runtime state', () async {
      final harness = _Harness();
      final seed = AutoSelectorDocument.defaults()
        ..gids = <int>[1]
        ..name = 'Old'
        ..pool = <int>[5, 6]
        ..pinnedId = 6
        ..lastBuilt = <int>[5]
        ..history = <Object?>[
          <String, Object?>{'id': 5, 'builds': 3},
        ];
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[_group(1, name: 'G')],
        profiles: <NodeRow>[_selectorRow(9, gid: 1, document: seed)],
      ));

      final info = await harness.service.autoSelectorInfo(9);
      final saved = await harness.service.autoSelectorSave(9, <String, dynamic>{
        ...info,
        'name': '  Renamed  ',
        'nameFilter': '  hk  ',
        'intervalSec': 1,
        'expected': 4,
        'gids': <int>[1, 2],
        // The editor spreads its whole seed; id/groups/pinnedId are not fields.
        'pinnedId': 999,
      });

      expect(saved['name'], 'Renamed');
      expect(saved['nameFilter'], 'hk');
      expect(saved['intervalSec'], 10, reason: 'the next parse normalises');
      expect(saved['expected'], 4);
      expect(saved['gids'], <int>[1, 2]);
      expect(saved['pinnedId'], 6, reason: 'a form save never moves the pin');

      final row = (await harness.store.profile(9))!;
      expect(row.type, autoSelectorType);
      expect(row.name, 'Renamed', reason: 'the profile column follows the document name');
      final stored = AutoSelectorDocument.fromJson(
        Map<String, dynamic>.from(jsonDecode(row.outboundJson) as Map),
      );
      expect(stored.pool, <int>[5, 6]);
      expect(stored.pinnedId, 6);
      expect(stored.lastBuilt, <int>[5]);
      expect(stored.history, hasLength(1));
      expect(harness.refreshes, 1, reason: 'the host catalog is pushed once');
    });

    test('save keeps absent keys and refuses a foreign row', () async {
      final harness = _Harness();
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[_group(1, name: 'G')],
        profiles: <NodeRow>[
          _selectorRow(
            9,
            gid: 1,
            document: AutoSelectorDocument.defaults()
              ..gids = <int>[1]
              ..name = 'Keep'
              ..countryFilter = 'HK',
          ),
          NodeRow(id: 8, type: 'vmess', name: 'node', gid: 1),
        ],
      ));

      final saved = await harness.service.autoSelectorSave(9, <String, dynamic>{
        'balance': true,
      });
      expect(saved['name'], 'Keep');
      expect(saved['countryFilter'], 'HK');
      expect(saved['balance'], isTrue);

      await expectLater(
        harness.service.autoSelectorSave(8, <String, dynamic>{'name': 'x'}),
        throwsA(isA<ProfileDocumentFailure>()),
      );
    });

    test('pin stores the member id and returns to automatic with -1', () async {
      final harness = _Harness();
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[_group(1, name: 'G')],
        profiles: <NodeRow>[
          _selectorRow(
            9,
            gid: 1,
            document: AutoSelectorDocument.defaults()
              ..gids = <int>[1]
              ..pool = <int>[3, 4],
          ),
        ],
      ));

      final pinned = await harness.service.autoSelectorPin(9, 4);
      expect(pinned['pinnedId'], 4);
      var stored = AutoSelectorDocument.fromJson(
        Map<String, dynamic>.from(
          jsonDecode((await harness.store.profile(9))!.outboundJson) as Map,
        ),
      );
      expect(stored.pinnedId, 4);
      expect(stored.pool, <int>[3, 4]);

      final automatic = await harness.service.autoSelectorPin(9, -1);
      expect(automatic['pinnedId'], -1);
      stored = AutoSelectorDocument.fromJson(
        Map<String, dynamic>.from(
          jsonDecode((await harness.store.profile(9))!.outboundJson) as Map,
        ),
      );
      expect(stored.pinnedId, -1);
      expect(harness.refreshes, 2);
    });

    test('create uses the first group in tab order', () async {
      final harness = _Harness();
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[
          _group(2, name: 'Late', order: 5),
          _group(3, name: 'First', order: 1),
        ],
      ));

      final info = await harness.service.autoSelectorCreate(0, '  Fresh  ');
      expect(info['name'], 'Fresh');
      expect(info['gids'], <int>[3]);
      final row = (await harness.store.profile((info['id'] as num).toInt()))!;
      expect(row.type, autoSelectorType);
      expect(row.gid, 3);
      expect(row.name, 'Fresh');
      expect(harness.refreshes, 1);
    });

    test('create defaults the name and the group id', () async {
      final harness = _Harness();
      await harness.seed(ProfilesDocument(
        groups: <ConfigurationRow>[_group(1, name: 'G')],
      ));

      final info = await harness.service.autoSelectorCreate(null, null);
      expect(info['name'], autoSelectorDefaultName);
      expect(info['gids'], <int>[1]);
    });

    test('create seeds the Default container in an empty document', () async {
      final harness = _Harness(defaultName: 'Default');
      await harness.seed(ProfilesDocument());

      final info = await harness.service.autoSelectorCreate(0, null);
      final document = await harness.store.document;
      expect(document.groups, hasLength(1));
      final group = document.groups.single;
      expect(group.name, 'Default');
      expect(group.single, isTrue);
      expect(info['gids'], <int>[group.id]);
      expect(info['groups'], <Map<String, Object?>>[
        {'id': group.id, 'name': 'Default'},
      ]);
    });
  });
}
