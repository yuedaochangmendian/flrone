// S8: the service engine's document owner runs the one-time legacy Xray scan.
//
// This pins the wiring, not just the pure scan: resolving the owner's store
// migrates the document before the first consumer reads it, and a scan that
// failed because the kernel action bus was not attached is retried by
// `ensureLegacyXrayMigration(force: true)` (the post-initialize hook).

import 'dart:convert';
import 'dart:io';

import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/data/legacy_xray_migration.dart';
import 'package:flrone/service_entry.dart';
import 'package:flutter_test/flutter_test.dart';

const _uuid = 'b831381d-6324-4d53-ad4f-8cda48b30811';
const _legacyJson =
    '{"protocol":"vless","tag":"legacy-node","settings":{"vnext":['
    '{"address":"vless.example.com","port":443,"users":['
    '{"id":"$_uuid","encryption":"none"}]}]}}';
const _migratedJson =
    '{"type":"vless","tag":"legacy-node","server":"vless.example.com",'
    '"server_port":443,"uuid":"$_uuid","encryption":"none"}';

String _document(List<Map<String, dynamic>> rows) => jsonEncode(<String, dynamic>{
      'version': 1,
      'name': 'profiles',
      'nextProfileId': rows.length + 1,
      'nextGroupId': 1,
      'profiles': rows,
      'groups': <dynamic>[],
    });

Map<String, dynamic> _row(int id, String type, String json) => <String, dynamic>{
      'id': id,
      'type': type,
      'name': 'legacy-node',
      'gid': 1,
      'user_order': 0,
      'latency': 0,
      'latency_at': 0,
      'outbound_json': json,
    };

class _FakeHost implements KernelHost {
  _FakeHost(this.directory);

  final Directory directory;
  final List<String> calls = <String>[];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) async {
    calls.add(method);
    if (method == 'document.path') {
      return <String, dynamic>{
        'directory': directory.path,
        'defaultGroupName': 'Default',
      };
    }
    return null;
  }

  @override
  Map<String, dynamic> get dashboard => <String, dynamic>{};

  @override
  List<Map<String, dynamic>> get configurations => const <Map<String, dynamic>>[];
}

LegacyXrayMigrationReply _migrated() => const LegacyXrayMigrationReply(
      migrated: true,
      type: 'vless',
      name: 'legacy-node',
      json: _migratedJson,
    );

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('flrone-s8-xray-owner-');
  });

  tearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });

  File profilesFile() => File(
        '${directory.path}${Platform.pathSeparator}profiles.json',
      );

  test('resolving the owner store migrates the document before it is read', () async {
    profilesFile().writeAsStringSync(_document(<Map<String, dynamic>>[
      _row(1, 'xrayvless', _legacyJson),
    ]));
    final host = _FakeHost(directory);
    final owner = DocumentOwner(
      host,
      migrateLegacyXrayRow: (type, json) async {
        expect(type, 'xrayvless');
        expect(json, _legacyJson);
        return _migrated();
      },
    );
    addTearDown(owner.dispose);

    final store = await owner.store;

    final doc = await store.document;
    expect(doc.profiles.single.type, 'vless');
    expect(doc.profiles.single.outboundJson, _migratedJson);
    expect(doc.legacyXrayMigration, legacyXrayMigrationVersion);
    expect(host.calls, contains('data.refresh'));

    final again = await owner.ensureLegacyXrayMigration(force: true);
    expect(again.alreadyDone, isTrue);
  });

  test('a scan that found no action bus is retried after initialize', () async {
    profilesFile().writeAsStringSync(_document(<Map<String, dynamic>>[
      _row(1, 'xrayvless', _legacyJson),
    ]));
    final host = _FakeHost(directory);
    var attached = false;
    final owner = DocumentOwner(
      host,
      migrateLegacyXrayRow: (type, json) async {
        if (!attached) throw StateError('the kernel action bus is not attached yet');
        return _migrated();
      },
    );
    addTearDown(owner.dispose);

    // The lazy scan races engine initialization in production: the store still
    // resolves and the old row is left untouched, with no marker.
    final store = await owner.store;
    var doc = await store.document;
    expect(doc.profiles.single.type, 'xrayvless');
    expect(doc.legacyXrayMigration, 0);

    attached = true;
    final retried = await owner.ensureLegacyXrayMigration(force: true);

    expect(retried.error, isNull);
    expect(retried.migrated, 1);
    doc = await store.document;
    expect(doc.profiles.single.type, 'vless');
    expect(doc.profiles.single.outboundJson, _migratedJson);
    expect(doc.legacyXrayMigration, legacyXrayMigrationVersion);
  });
}