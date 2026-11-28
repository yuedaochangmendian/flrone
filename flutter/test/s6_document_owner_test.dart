// S6 Option A: the service engine is the single owner of documents/profiles.json.
//
// These tests pin the UI's read-only, stamp-checked view and the relay contract:
//  * an external (owner-isolate) write that moves the mtime+length stamp is
//    reparsed instead of answered from the stale cache;
//  * a relay failure keeps its error text (no silent null for structural writes);
//  * one structural op is one relay op — no read-then-row-upsert decomposition;
//  * nodeList (which prunes) and a backup replaceAll both go through the relay;
//  * the owner's applyDocument path maps one envelope to ONE applyCombined.
//
// Everything runs against an in-memory filesystem / loopback seam; no device.

import 'dart:convert';

import 'package:flrone/box.dart';
import 'package:flrone/data/configuration_store.dart';
import 'package:flrone/data/configuration_store_source.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _dbPath = '/app/databases/sager_net.db';
const _profilesPath = '/app/files/documents/profiles.json';

const _seed = <String, dynamic>{
  'version': 1,
  'name': 'profiles',
  'nextProfileId': 2,
  'nextGroupId': 2,
  'profiles': <dynamic>[
    <String, dynamic>{
      'id': 1,
      'type': 'vmess',
      'name': 'node-1',
      'gid': 1,
      'user_order': 0,
      'outbound_json': '{}',
    },
  ],
  'groups': <dynamic>[
    <String, dynamic>{'id': 1, 'name': 'Sub', 'display_order': 0},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a read-only store reparses when an external stamp changes', () async {
    final fs = MemoryConfigurationStoreFs();
    fs.externalWrite(_profilesPath, jsonEncode(_seed),
        at: DateTime(2026, 1, 1));
    final store = ConfigurationStore(path: _profilesPath, fs: fs, readOnly: true);

    final first = await store.document;
    expect(first.profiles.single.name, 'node-1');

    // The owner wrote a same-length rename with a new mtime. The cached copy
    // must not be served.
    final renamed = Map<String, dynamic>.from(_seed);
    renamed['profiles'] = <dynamic>[
      <String, dynamic>{
        ...(_seed['profiles'] as List).single as Map<String, dynamic>,
        'name': 'NODE',
      },
    ];
    fs.externalWrite(_profilesPath, jsonEncode(renamed),
        at: DateTime(2026, 1, 2));

    final second = await store.document;
    expect(second.profiles.single.name, 'NODE',
        reason: 'a moved stamp forces a reparse of the owner bytes');
  });

  test('a read-only store refuses a local edit', () async {
    final fs = MemoryConfigurationStoreFs();
    fs.externalWrite(_profilesPath, jsonEncode(_seed));
    final store = ConfigurationStore(path: _profilesPath, fs: fs, readOnly: true);

    expect(store.createNode(type: 'socks', gid: 1),
        throwsA(isA<StateError>()),
        reason: 'the UI view must never race the owner with a local write');
  });

  test('relay error text is preserved, not swallowed into a null', () async {
    const channel = MethodChannel('test.s6.relay');
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      throw PlatformException(code: 'owner', message: 'revision guard refused');
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    final fs = MemoryConfigurationStoreFs();
    final box = BoxController(
      channel: channel,
      configurationStoreSource: ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath},
        store: ConfigurationStore(path: _profilesPath, fs: fs),
      ),
      documentRelay: (method, args) => throw PlatformException(
        code: 'owner',
        message: 'revision guard refused',
      ),
    );
    addTearDown(box.dispose);

    await expectLater(
      box.configurationWrite(1, '{"name":"X"}', '0'),
      throwsA(isA<PlatformException>().having(
        (e) => e.message,
        'message',
        'revision guard refused',
      )),
    );
  });

  test('one structural write is one relay op, not a read-then-upsert', () async {
    final ops = <String>[];
    final fs = MemoryConfigurationStoreFs();
    final box = BoxController(
      channel: const MethodChannel('test.s6.oneop'),
      configurationStoreSource: ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath},
        store: ConfigurationStore(path: _profilesPath, fs: fs),
      ),
      documentRelay: (method, args) async {
        ops.add(method);
        return <String, dynamic>{'ok': true};
      },
    );
    addTearDown(box.dispose);

    await box.configurationWrite(1, '{"name":"X"}', '0');
    expect(ops, ['configurationWrite']);
  });

  test('nodeList goes through the owner because it prunes', () async {
    final ops = <String>[];
    final fs = MemoryConfigurationStoreFs();
    final box = BoxController(
      channel: const MethodChannel('test.s6.nodelist'),
      configurationStoreSource: ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath},
        store: ConfigurationStore(path: _profilesPath, fs: fs),
      ),
      documentRelay: (method, args) async {
        ops.add(method);
        return <String, dynamic>{
          'groupId': 0,
          'groupName': '',
          'nodes': <dynamic>[],
        };
      },
    );
    addTearDown(box.dispose);

    final answer = await box.nodeList();
    expect(ops, ['configurationNodeList']);
    expect(answer['nodes'], isEmpty);
  });

  test('a backup replaceAll goes through the relay as one op', () async {
    final ops = <String>[];
    Map<String, dynamic>? sent;
    final fs = MemoryConfigurationStoreFs();
    const channel = MethodChannel('test.s6.backup');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'data.path') {
        return <String, dynamic>{
          'path': _dbPath,
          'appVersion': 'test',
          'defaultGroupName': 'Default',
          'backupUi': <String, dynamic>{},
        };
      }
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance
        .defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(
      channel: channel,
      configurationStoreSource: ConfigurationStoreSource(
        resolvePath: () async => {'path': _dbPath},
        store: ConfigurationStore(path: _profilesPath, fs: fs),
      ),
      documentRelay: (method, args) async {
        ops.add(method);
        sent = args;
        return true;
      },
    );
    addTearDown(box.dispose);

    final doc = ProfilesDocument.fromJson(_seed);
    // Drive the same environment hook the backup writer uses.
    final env = await box.resolveBackupEnvironment();
    await env.applyRestoredProfiles!(doc);

    expect(ops, ['applyRestoredProfiles']);
    expect(sent!['document']['profiles'], isA<List>());
    expect(sent!['document']['groups'], isA<List>());
  });

  test('an applyDocument envelope maps to one combined store edit', () async {
    final fs = MemoryConfigurationStoreFs();
    fs.externalWrite(_profilesPath, jsonEncode(_seed));
    final source = ConfigurationStoreSource(
      resolvePath: () async => {'path': _dbPath},
      store: ConfigurationStore(path: _profilesPath, fs: fs),
    );
    final writesBefore = fs.writes;

    final doc = AppliedProfilesDocument.parse(<String, dynamic>{
      'profilePatches': <String, dynamic>{
        '1': <String, dynamic>{'name': 'renamed'},
      },
    })!;
    final allocated = await source.apply(doc);

    expect(allocated.profiles, isEmpty);
    expect(fs.writes, writesBefore + 1,
        reason: 'one apply is ONE applyCombined/persist');
    expect((await (await source.store()).profile(1))!.name, 'renamed');
  });
}
