// ADR 0005 phase 1: the WebDAV account is a Dart-owned value in the preferences
// document. These tests pin the four behaviours that keep an upgrade from losing
// an account: persistence + cold start, the legacy Room fold, no channel
// webdav.get/set, and the connectivity probe using the Dart-owned account.
//
// The Kotlin half (folding the legacy account into `preferences` on `ready` and
// mirroring writes back to Room) is a thin host adapter; the migration contract
// it feeds is exercised here through the same map shape it emits.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/services/webdav_account.dart';
import 'package:flrone/services/webdav_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _legacy = <String, dynamic>{
  'uri': 'https://dav.example.test/legacy',
  'user': 'old-user',
  'password': 'old-secret',
  'fileName': 'old.json',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebDavAccountStore', () {
    late Map<String, dynamic> prefs;
    late List<Map<String, dynamic>> writes;
    late WebDavAccountStore store;

    setUp(() {
      prefs = <String, dynamic>{'theme': 'dark'};
      writes = <Map<String, dynamic>>[];
      store = WebDavAccountStore(
        readPreferences: () => prefs,
        writePreferences: (values) async {
          writes.add(values);
          values.forEach((key, value) {
            if (value == null) {
              prefs.remove(key);
            } else {
              prefs[key] = value;
            }
          });
        },
      );
    });

    test('save then a fresh store reads the account back (cold start)', () async {
      final saved = await store.save(_legacy);
      expect(saved, _legacy);

      // A fresh store with a fresh preferences map that has persisted the write.
      final reloaded = Map<String, dynamic>.from(prefs);
      final cold = WebDavAccountStore(
        readPreferences: () => reloaded,
        writePreferences: (values) async => throw 'unexpected write',
      );
      expect(cold.read(), _legacy);
    });

    test('first read sees the legacy Room value folded into preferences on ready', () async {
      // This is the map shape the host produces in preferencesWithLegacyWebDav():
      // the legacy webdav() answer placed under webdavAccount, with no Dart write.
      prefs[webdavAccountKey] = Map<String, dynamic>.from(_legacy);
      expect(store.read(), _legacy);
      // Nothing was written yet: the fold was host-side, not a Dart mutation.
      expect(writes, isEmpty);
    });

    test('unbind removes the value and a fresh store reads null', () async {
      await store.save(_legacy);
      expect(await store.save(null), isNull);
      expect(prefs.containsKey(webdavAccountKey), isFalse);
      expect(store.read(), isNull);
    });

    test('a corrupt or partial value never produces a half-account', () {
      prefs[webdavAccountKey] = 'not-a-map';
      expect(store.read(), isNull);
      prefs[webdavAccountKey] = <String, dynamic>{'uri': 'https://only-uri.test'};
      expect(store.read(), <String, dynamic>{
        'uri': 'https://only-uri.test', 'user': '', 'password': '', 'fileName': '',
      });
    });

    test('password is stored verbatim in the document (masking is a UI-only concern)', () async {
      await store.save(_legacy);
      final stored = prefs[webdavAccountKey] as Map<String, dynamic>;
      // The form's secret field masks on screen; the value itself must round-trip
      // intact or Basic auth breaks. No API returns a masked password.
      expect(stored['password'], 'old-secret');
      expect(store.read()!['password'], 'old-secret');
    });
  });

  group('BoxController WebDAV account integration', () {
    const channel = MethodChannel('test.webdav-account');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late StreamController<dynamic> events;
    late BoxController box;
    late Map<String, dynamic> prefs;
    late List<MethodCall> calls;
    late WebDavAccount? probedAccount;

    setUp(() {
      events = StreamController<dynamic>.broadcast();
      prefs = <String, dynamic>{
        // Simulate the host's ready fold: a legacy Room account is now in the doc.
        webdavAccountKey: Map<String, dynamic>.from(_legacy),
      };
      calls = <MethodCall>[];
      probedAccount = null;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'preferences.set':
            final values = json(call.arguments)['value'] as Map<String, dynamic>;
            values.forEach((key, value) {
              if (value == null) {
                prefs.remove(key);
              } else {
                prefs[key] = value;
              }
            });
            return Map<String, dynamic>.from(prefs);
          default:
            return null;
        }
      });
      box = BoxController(
        channel: channel,
        events: events.stream,
        webDavChecker: (account) async {
          probedAccount = account;
          return true;
        },
      );
      // No initialize() needed: webdavAccount reads the field directly.
    });

    tearDown(() async {
      box.dispose();
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('webdavGet reads the preferences document, not a channel', () async {
      box.preferences = Map<String, dynamic>.from(prefs);
      expect(await box.webdavGet(), _legacy);
      expect(calls.where((c) => c.method == 'webdav.get'), isEmpty);
      expect(calls.where((c) => c.method == 'webdav.set'), isEmpty);
    });

    test('webdavSet writes preferences.set and the store sees it', () async {
      box.preferences = Map<String, dynamic>.from(prefs);
      final updated = <String, dynamic>{..._legacy, 'password': 'new-secret'};
      final result = await box.webdavSet(updated);
      expect(result, updated);
      final write = calls.firstWhere((c) => c.method == 'preferences.set');
      final value = json(write.arguments)['value'] as Map<String, dynamic>;
      expect(value[webdavAccountKey], updated);
      // setPreferences refreshes the controller's map from the channel reply.
      expect(box.webDavAccount.read(), updated);
    });

    test('webdavCheck probes the Dart-owned account, not a channel', () async {
      box.preferences = Map<String, dynamic>.from(prefs);
      expect(await box.webdavCheck(), isTrue);
      expect(probedAccount, _legacy);
      expect(calls.where((c) => c.method == 'webdav.get'), isEmpty);
      expect(calls.where((c) => c.method == 'webdav.check'), isEmpty);
    });
  });
}
