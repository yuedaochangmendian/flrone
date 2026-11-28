// S8: the one-time stored-row Xray bridge over the Dart-owned profiles document.
//
// The migration must detect exactly the rows LegacyXray.migrateStored converted,
// rewrite them through the Go `profileMigrate` action, apply every row patch plus
// the completion marker in ONE serialized document edit, leave modern rows alone,
// and be idempotent (the marker short-circuits, and a marker-less second scan
// finds nothing). A refusal keeps the row and is logged; an action failure leaves
// the marker unwritten so the owner can retry after the kernel driver attaches.

import 'dart:convert';

import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/legacy_xray_migration.dart';
import 'package:flutter_test/flutter_test.dart';

const _path = '/app/files/documents/profiles.json';
const _uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';

const _legacyVlessJson =
    '{"protocol":"vless","tag":"legacy-node","settings":{"vnext":['
    '{"address":"vless.example.com","port":443,"users":['
    '{"id":"$_uuid","encryption":"none"}]}]}}';

const _legacyCustomJson =
    '{"type":"custom","subtype":"xrayoutbound","config":'
    '"{\\"protocol\\":\\"trojan\\",\\"settings\\":{\\"servers\\":'
    '[{\\"address\\":\\"t.example.com\\",\\"port\\":443,'
    '\\"password\\":\\"p\\"}]}}" }';

const _migratedVlessJson =
    '{"type":"vless","tag":"legacy-node","server":"vless.example.com",'
    '"server_port":443,"uuid":"$_uuid","encryption":"none"}';

const _migratedTrojanJson =
    '{"type":"trojan","tag":"legacy-custom","server":"t.example.com",'
    '"server_port":443,"password":"p"}';

const _modernVlessJson =
    '{"type":"vless","tag":"modern","server":"modern.example.com",'
    '"server_port":443,"uuid":"$_uuid","encryption":"none"}';

Map<String, dynamic> _row(int id, String type, String json, {String? name}) =>
    <String, dynamic>{
      'id': id,
      'type': type,
      'name': name,
      'gid': 1,
      'user_order': id - 1,
      'latency': 0,
      'latency_at': 0,
      'outbound_json': json,
    };

String _documentJson(List<Map<String, dynamic>> rows) =>
    jsonEncode(<String, dynamic>{
      'version': 1,
      'name': 'profiles',
      'nextProfileId': rows.length + 1,
      'nextGroupId': 1,
      'profiles': rows,
      'groups': <dynamic>[],
    });

ConfigurationStore _storeWith(MemoryConfigurationStoreFs fs, String document) {
  fs.files[_path] = document;
  return ConfigurationStore(path: _path, fs: fs);
}

class _FakeMigrator {
  _FakeMigrator(this.onCall);

  final Future<LegacyXrayMigrationReply> Function(String type, String json)
  onCall;
  final List<String> types = <String>[];
  final List<String> payloads = <String>[];

  Future<LegacyXrayMigrationReply> call(String type, String json) {
    types.add(type);
    payloads.add(json);
    return onCall(type, json);
  }
}

LegacyXrayMigrationReply _migrated({
  required String type,
  required String json,
  String name = '',
}) => LegacyXrayMigrationReply(
  migrated: true,
  type: type,
  json: json,
  name: name,
);

void main() {
  test('detects the legacy shapes and applies one combined patch', () async {
    final fs = MemoryConfigurationStoreFs();
    final store = _storeWith(
      fs,
      _documentJson(<Map<String, dynamic>>[
        _row(1, 'xrayvless', _legacyVlessJson, name: 'legacy-node'),
        _row(2, 'custom', _legacyCustomJson),
        _row(3, 'vless', _modernVlessJson, name: 'modern'),
      ]),
    );
    final fake = _FakeMigrator((type, json) async {
      if (type == 'xrayvless') {
        return _migrated(
          type: 'vless',
          json: _migratedVlessJson,
          name: 'legacy-node',
        );
      }
      return _migrated(
        type: 'trojan',
        json: _migratedTrojanJson,
        name: 'legacy-custom',
      );
    });

    final outcome = await LegacyXrayMigration(
      store: store,
      migrate: fake.call,
    ).ensure();

    expect(fake.types, <String>[
      'xrayvless',
      'custom',
    ], reason: 'the modern vless row must not cross the action bus');
    expect(outcome.completed, isTrue);
    expect(outcome.changed, isTrue);
    expect(outcome.migrated, 2);
    expect(outcome.refused, 0);
    expect(
      fs.writes,
      1,
      reason: 'all row patches plus the marker are ONE edit',
    );

    final doc = await store.document;
    expect(doc.legacyXrayMigration, legacyXrayMigrationVersion);
    expect(doc.profiles[0].type, 'vless');
    expect(doc.profiles[0].outboundJson, _migratedVlessJson);
    expect(doc.profiles[0].name, 'legacy-node');
    expect(doc.profiles[1].type, 'trojan');
    expect(doc.profiles[1].outboundJson, _migratedTrojanJson);
    expect(doc.profiles[1].name, 'legacy-custom');
    expect(doc.profiles[2].type, 'vless');
    expect(doc.profiles[2].outboundJson, _modernVlessJson);
    expect(doc.profiles[2].name, 'modern');
  });

  test('leaves modern rows untouched and only records the marker', () async {
    final fs = MemoryConfigurationStoreFs();
    final store = _storeWith(
      fs,
      _documentJson(<Map<String, dynamic>>[
        _row(1, 'vless', _modernVlessJson, name: 'modern'),
        _row(
          2,
          'custom',
          '{"type":"custom","subtype":"outbound","config":"{}"}',
        ),
      ]),
    );
    final fake = _FakeMigrator((type, json) async {
      fail('a modern row must never reach profileMigrate');
    });

    final outcome = await LegacyXrayMigration(
      store: store,
      migrate: fake.call,
    ).ensure();

    expect(fake.types, isEmpty);
    expect(outcome.completed, isTrue);
    expect(outcome.changed, isFalse);
    expect(fs.writes, 1, reason: 'the completion marker is the one write');
    final doc = await store.document;
    expect(doc.legacyXrayMigration, legacyXrayMigrationVersion);
    expect(doc.profiles[1].type, 'custom');
    expect(
      doc.profiles[1].outboundJson,
      '{"type":"custom","subtype":"outbound","config":"{}"}',
    );
  });

  test('is idempotent on a second run', () async {
    final fs = MemoryConfigurationStoreFs();
    final store = _storeWith(
      fs,
      _documentJson(<Map<String, dynamic>>[
        _row(1, 'xrayvless', _legacyVlessJson, name: 'legacy-node'),
      ]),
    );
    final first = _FakeMigrator(
      (type, json) async => _migrated(
        type: 'vless',
        json: _migratedVlessJson,
        name: 'legacy-node',
      ),
    );
    final firstRun = await LegacyXrayMigration(
      store: store,
      migrate: first.call,
    ).ensure();
    expect(firstRun.changed, isTrue);
    expect(fs.writes, 1);

    final second = _FakeMigrator((type, json) async {
      fail('the marker must short-circuit the second scan');
    });
    final secondRun = await LegacyXrayMigration(
      store: store,
      migrate: second.call,
    ).ensure();

    expect(secondRun.alreadyDone, isTrue);
    expect(secondRun.completed, isTrue);
    expect(secondRun.changed, isFalse);
    expect(second.types, isEmpty);
    expect(fs.writes, 1);
    final doc = await store.document;
    expect(doc.profiles.single.type, 'vless');
    expect(doc.profiles.single.outboundJson, _migratedVlessJson);
  });

  test('keeps and logs a refused row without retrying it', () async {
    final fs = MemoryConfigurationStoreFs();
    final store = _storeWith(
      fs,
      _documentJson(<Map<String, dynamic>>[
        _row(1, 'xrayvless', _legacyVlessJson, name: 'legacy-node'),
      ]),
    );
    final logs = <String>[];
    final fake = _FakeMigrator(
      (type, json) async => const LegacyXrayMigrationReply(
        migrated: false,
        reason: 'This Xray profile cannot be converted: the XDRIVE transport has no sing-box counterpart',
      ),
    );

    final outcome = await LegacyXrayMigration(
      store: store,
      migrate: fake.call,
      log: logs.add,
    ).ensure();

    expect(outcome.completed, isTrue);
    expect(outcome.changed, isFalse);
    expect(outcome.refused, 1);
    expect(outcome.migrated, 0);
    expect(
      fs.writes,
      1,
      reason: 'the marker records the decision, no row patch',
    );
    expect(logs.join('\n'), contains('XDRIVE transport'));

    final doc = await store.document;
    expect(doc.profiles.single.type, 'xrayvless');
    expect(doc.profiles.single.outboundJson, _legacyVlessJson);
    expect(doc.legacyXrayMigration, legacyXrayMigrationVersion);

    final second = _FakeMigrator((type, json) async {
      fail('a refused row must not be retried once the marker is recorded');
    });
    final secondRun = await LegacyXrayMigration(
      store: store,
      migrate: second.call,
    ).ensure();
    expect(secondRun.alreadyDone, isTrue);
    expect(second.types, isEmpty);
    expect(fs.writes, 1);
  });

  test('an action failure leaves the marker unwritten and retries', () async {
    final fs = MemoryConfigurationStoreFs();
    final store = _storeWith(
      fs,
      _documentJson(<Map<String, dynamic>>[
        _row(1, 'xrayvless', _legacyVlessJson, name: 'legacy-node'),
      ]),
    );
    var available = false;
    final fake = _FakeMigrator((type, json) async {
      if (!available) {
        throw StateError('the kernel action bus is not attached yet');
      }
      return _migrated(
        type: 'vless',
        json: _migratedVlessJson,
        name: 'legacy-node',
      );
    });
    final migration = LegacyXrayMigration(store: store, migrate: fake.call);

    final failed = await migration.ensure();
    expect(failed.error, contains('action bus'));
    expect(failed.completed, isFalse);
    expect(
      fs.writes,
      0,
      reason: 'no row patch and no marker after a transport error',
    );
    expect((await store.document).profiles.single.type, 'xrayvless');

    available = true;
    final retried = await migration.ensure();

    expect(retried.error, isNull);
    expect(retried.migrated, 1);
    expect(fs.writes, 1);
    final doc = await store.document;
    expect(doc.profiles.single.type, 'vless');
    expect(doc.legacyXrayMigration, legacyXrayMigrationVersion);
  });

  test('a whole-document replace resets the marker and the restored rows are scanned', () async {
    final fs = MemoryConfigurationStoreFs();
    final store = _storeWith(
      fs,
      _documentJson(<Map<String, dynamic>>[
        _row(1, 'xrayvless', _legacyVlessJson, name: 'legacy-node'),
      ]),
    );
    await LegacyXrayMigration(
      store: store,
      migrate: _FakeMigrator(
        (type, json) async => _migrated(
          type: 'vless',
          json: _migratedVlessJson,
          name: 'legacy-node',
        ),
      ).call,
    ).ensure();
    expect(
      (await store.document).legacyXrayMigration,
      legacyXrayMigrationVersion,
    );

    // A backup restore writes a foreign document; its rows may still be legacy.
    await store.replaceAll(
      ProfilesDocument(
        profiles: <NodeRow>[
          NodeRow.fromJson(
            _row(9, 'xrayvless', _legacyVlessJson, name: 'restored'),
          ),
        ],
        nextProfileId: 10,
        nextGroupId: 1,
      ),
    );
    expect((await store.document).legacyXrayMigration, 0);

    final fake = _FakeMigrator(
      (type, json) async =>
          _migrated(type: 'vless', json: _migratedVlessJson, name: 'restored'),
    );
    final outcome = await LegacyXrayMigration(
      store: store,
      migrate: fake.call,
    ).ensure();

    expect(fake.types, <String>['xrayvless']);
    expect(outcome.migrated, 1);
    final doc = await store.document;
    expect(doc.profiles.single.type, 'vless');
    expect(doc.profiles.single.name, 'restored');
    expect(doc.legacyXrayMigration, legacyXrayMigrationVersion);

    // The owner's restore path is `applyCombined(replaceAll: true)`; it must
    // reset the marker the same way the UI fallback's replaceAll does.
    await store.applyCombined(
      replaceAll: true,
      profiles: <NodeRow>[
        NodeRow.fromJson(_row(10, 'xrayvless', _legacyVlessJson, name: 'again')),
      ],
      groups: const <ConfigurationRow>[],
    );
    expect((await store.document).legacyXrayMigration, 0);
  });

  test('detection mirrors LegacyXray.migrateStored precedence', () {
    NodeRow row(String type, String json) =>
        NodeRow(id: 1, type: type, outboundJson: json);

    expect(
      LegacyXrayMigration.isLegacyXrayRow(row('xrayvless', '{}')),
      isTrue,
      reason: 'the stored type alone is the old Xray row',
    );
    expect(
      LegacyXrayMigration.isLegacyXrayRow(
        row('custom', '{"subtype":"xrayfullconfig","config":"{}"}'),
      ),
      isTrue,
    );
    expect(
      LegacyXrayMigration.isLegacyXrayRow(
        row('anything', '{"type":"xrayvless","server":"a"}'),
      ),
      isTrue,
      reason: 'the JSON type also selects the legacy conversion',
    );
    expect(
      LegacyXrayMigration.isLegacyXrayRow(row('vless', _legacyVlessJson)),
      isTrue,
      reason: 'a top-level protocol key is the bare Xray outbound shape',
    );
    expect(
      LegacyXrayMigration.isLegacyXrayRow(
        row('custom', '{"type":"custom","subtype":"outbound","config":"x"}'),
      ),
      isFalse,
      reason: 'a modern custom row is not Xray even when its config text mentions protocol',
    );
    expect(
      LegacyXrayMigration.isLegacyXrayRow(row('vless', _modernVlessJson)),
      isFalse,
    );
    expect(
      LegacyXrayMigration.isLegacyXrayRow(row('vless', 'not json')),
      isFalse,
    );
    expect(LegacyXrayMigration.isLegacyXrayRow(row('vless', '')), isFalse);
  });
}
