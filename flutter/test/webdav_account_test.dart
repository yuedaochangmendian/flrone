// The WebDAV account at rest (alignment item S10): the password is a Keystore
// envelope in the preferences document, with the form and the `webdav.*`
// answers unchanged. These tests pin the rules that keep an upgrade and a
// Keystore reset from losing the secret *or* leaking it:
//
//   * a save seals a non-empty password, and never writes plaintext;
//   * a read opens the envelope and round-trips the account;
//   * a legacy plaintext account still reads (no write during a read) and
//     becomes ciphertext on the next save;
//   * an envelope this device cannot open reads as an empty password with a
//     diagnostic — never as a throw, and never as ciphertext handed to a server;
//   * a save that cannot seal fails instead of falling back to plaintext.
//
// The enveloping primitive itself is Kotlin (`SecureBox.kt`, pinned by
// `SecureBoxTest` on the JVM); here it is a stand-in so the store's contract is
// exercised on any host. Two groups drive the real default functions through the
// `io.flrone/secure` MethodChannel mock, which is what proves the channel name
// and the envelope prefix agree with the host.

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

/// The stand-in envelope: the marker plus the plaintext, so a test can assert
/// both what was stored and that only the store's own tokens open.
const _fakeMarker = 'enc:v1:test:';

String _fakeSeal(String plaintext) => '$_fakeMarker$plaintext';

String? _fakeOpen(String token) =>
    token.startsWith(_fakeMarker) ? token.substring(_fakeMarker.length) : null;

WebDavAccountStore _store(
  Map<String, dynamic> prefs,
  List<Map<String, dynamic>> writes, {
  bool sealFails = false,
  List<String>? sealCalls,
  List<String>? openCalls,
}) =>
    WebDavAccountStore(
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
      seal: (plaintext) async {
        sealCalls?.add(plaintext);
        if (sealFails) throw const WebDavSecretException('the keystore is locked');
        return _fakeSeal(plaintext);
      },
      open: (token) async {
        openCalls?.add(token);
        return _fakeOpen(token);
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('WebDavAccountStore', () {
    late Map<String, dynamic> prefs;
    late List<Map<String, dynamic>> writes;
    late List<String> sealCalls;
    late List<String> openCalls;
    late WebDavAccountStore store;

    setUp(() {
      prefs = <String, dynamic>{'theme': 'dark'};
      writes = <Map<String, dynamic>>[];
      sealCalls = <String>[];
      openCalls = <String>[];
      store = _store(prefs, writes, sealCalls: sealCalls, openCalls: openCalls);
    });

    test('save seals the password; a fresh store reads the account back', () async {
      final saved = await store.save(_legacy);
      // The reply is what the form shows: the plaintext account, as `webdav.set` did.
      expect(saved, _legacy);
      final stored = prefs[webdavAccountKey] as Map<String, dynamic>;
      expect(stored['password'], '${_fakeMarker}old-secret');
      expect(stored['password'], isNot('old-secret'));

      final cold = _store(Map<String, dynamic>.from(prefs), <Map<String, dynamic>>[]);
      expect(await cold.read(), _legacy);
    });

    test('a legacy plaintext account reads as-is and nothing is written', () async {
      prefs[webdavAccountKey] = Map<String, dynamic>.from(_legacy);
      expect(await store.read(), _legacy);
      // Migration is lazy: a pure read mutates nothing, so an upgrade keeps
      // working even when a write would fail.
      expect(writes, isEmpty);
      expect(sealCalls, isEmpty);
      // No envelope, so there is nothing to open either.
      expect(openCalls, isEmpty);
      expect(store.lastDiagnostic, isNull);
    });

    test('the first save after a legacy read migrates it to ciphertext', () async {
      prefs[webdavAccountKey] = Map<String, dynamic>.from(_legacy);
      final account = await store.read();
      await store.save(account);
      final stored = prefs[webdavAccountKey] as Map<String, dynamic>;
      expect(stored['password'], '${_fakeMarker}old-secret');
      expect(await store.read(), _legacy);
    });

    test('unbind removes the value and a fresh store reads null', () async {
      await store.save(_legacy);
      expect(await store.save(null), isNull);
      expect(prefs.containsKey(webdavAccountKey), isFalse);
      expect(await store.read(), isNull);
    });

    test('a corrupt or partial value never produces a half-account', () async {
      prefs[webdavAccountKey] = 'not-a-map';
      expect(await store.read(), isNull);
      prefs[webdavAccountKey] = <String, dynamic>{'uri': 'https://only-uri.test'};
      expect(await store.read(), <String, dynamic>{
        'uri': 'https://only-uri.test', 'user': '', 'password': '', 'fileName': '',
      });
    });

    test('an unopenable envelope reads as an empty password with a diagnostic', () async {
      // A token this device did not seal: what a Keystore reset or a reinstall
      // leaves behind. The account stays visible, the secret does not.
      prefs[webdavAccountKey] = <String, dynamic>{
        ..._legacy,
        'password': 'enc:v1:from-another-install',
      };
      final account = await store.read();
      expect(account, isNotNull);
      expect(account!['uri'], _legacy['uri']);
      expect(account['user'], _legacy['user']);
      expect(account['password'], '');
      expect(store.lastDiagnostic, contains('cannot be decrypted'));
      // Nothing was rewritten: a read never repairs the document.
      expect(writes, isEmpty);

      // A later readable state clears the diagnostic.
      prefs[webdavAccountKey] = Map<String, dynamic>.from(_legacy);
      await store.read();
      expect(store.lastDiagnostic, isNull);
    });

    test('re-saving an already sealed password does not seal it twice', () async {
      await store.save(_legacy);
      final sealedToken = (prefs[webdavAccountKey] as Map<String, dynamic>)['password'];
      sealCalls.clear();
      final answered = await store.save({..._legacy, 'password': sealedToken});
      expect(sealCalls, isEmpty);
      expect((prefs[webdavAccountKey] as Map<String, dynamic>)['password'], sealedToken);
      // The reply is the plaintext again, never the envelope.
      expect(answered!['password'], 'old-secret');
    });

    test('an empty password is stored as empty, not sealed', () async {
      await store.save({..._legacy, 'password': ''});
      expect((prefs[webdavAccountKey] as Map<String, dynamic>)['password'], '');
      expect(sealCalls, isEmpty);
    });

    test('a sealing failure fails the save and writes nothing', () async {
      final failing = _store(prefs, writes, sealFails: true);
      await expectLater(
        failing.save(_legacy),
        throwsA(isA<WebDavSecretException>()),
      );
      expect(writes, isEmpty);
      expect(prefs.containsKey(webdavAccountKey), isFalse);
    });
  });

  group('platform keystore defaults', () {
    const secure = MethodChannel(secureChannelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(secure, null));

    test('a save without a host fails instead of storing plaintext', () async {
      // The test host has no `io.flrone/secure` handler, which is also a
      // non-Android build: the one outcome that must never happen is a plaintext
      // document, so the store must refuse.
      await expectLater(
        sealWithPlatformKeystore('secret'),
        throwsA(isA<WebDavSecretException>()),
      );
      final prefs = <String, dynamic>{};
      final store = WebDavAccountStore(
        readPreferences: () => prefs,
        writePreferences: (values) async => prefs.addAll(values),
      );
      await expectLater(store.save(_legacy), throwsA(isA<WebDavSecretException>()));
      expect(prefs, isEmpty);
    });

    test('a host refusal surfaces its message', () async {
      messenger.setMockMethodCallHandler(secure, (call) async {
        throw PlatformException(code: 'seal_failed', message: 'KeyStoreException');
      });
      await expectLater(
        sealWithPlatformKeystore('secret'),
        throwsA(isA<WebDavSecretException>().having(
          (error) => error.toString(),
          'message',
          contains('KeyStoreException'),
        )),
      );
    });

    test('a host answer that is not an envelope is refused', () async {
      messenger.setMockMethodCallHandler(secure, (call) async => 'secret');
      await expectLater(
        sealWithPlatformKeystore('secret'),
        throwsA(isA<WebDavSecretException>()),
      );
    });

    test('open answers null when the host is absent, refuses or says null', () async {
      expect(await openWithPlatformKeystore('enc:v1:abc'), isNull);

      messenger.setMockMethodCallHandler(secure, (call) async {
        throw PlatformException(code: 'open_failed');
      });
      expect(await openWithPlatformKeystore('enc:v1:abc'), isNull);

      messenger.setMockMethodCallHandler(secure, (call) async => null);
      expect(await openWithPlatformKeystore('enc:v1:abc'), isNull);
    });

    test('the default save writes the envelope the host answered', () async {
      final prefs = <String, dynamic>{};
      messenger.setMockMethodCallHandler(secure, (call) async {
        final value = (call.arguments as Map)['value'] as String;
        return switch (call.method) {
          'seal' => _fakeSeal(value),
          'open' => _fakeOpen(value),
          _ => fail('unexpected ${call.method}'),
        };
      });
      final store = WebDavAccountStore(
        readPreferences: () => prefs,
        writePreferences: (values) async => prefs.addAll(values),
      );
      final answered = await store.save(_legacy);
      expect(answered, _legacy);
      expect((prefs[webdavAccountKey] as Map<String, dynamic>)['password'],
          '${_fakeMarker}old-secret');
      expect(await store.read(), _legacy);
    });
  });

  group('BoxController WebDAV account integration', () {
    const channel = MethodChannel('test.webdav-account');
    const secure = MethodChannel(secureChannelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late StreamController<dynamic> events;
    late BoxController box;
    late Map<String, dynamic> prefs;
    late List<MethodCall> calls;
    late WebDavAccount? probedAccount;

    setUp(() {
      events = StreamController<dynamic>.broadcast();
      prefs = <String, dynamic>{
        // The document as a build since S10 leaves it: the password sealed.
        webdavAccountKey: <String, dynamic>{
          ..._legacy,
          'password': '${_fakeMarker}old-secret',
        },
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
      messenger.setMockMethodCallHandler(secure, (call) async {
        calls.add(call);
        final value = (call.arguments as Map)['value'] as String;
        return switch (call.method) {
          'seal' => _fakeSeal(value),
          'open' => _fakeOpen(value),
          _ => fail('unexpected ${call.method}'),
        };
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
      messenger.setMockMethodCallHandler(secure, null);
    });

    test('webdavGet opens the stored envelope, not a channel', () async {
      box.preferences = Map<String, dynamic>.from(prefs);
      expect(await box.webdavGet(), _legacy);
      expect(calls.where((c) => c.method == 'webdav.get'), isEmpty);
      expect(calls.where((c) => c.method == 'webdav.set'), isEmpty);
      expect(calls.where((c) => c.method == 'open'), hasLength(1));
    });

    test('webdavSet seals through the secure channel and echoes the plaintext', () async {
      box.preferences = Map<String, dynamic>.from(prefs);
      final updated = <String, dynamic>{..._legacy, 'password': 'new-secret'};
      final result = await box.webdavSet(updated);
      expect(result, updated);
      final write = calls.firstWhere((c) => c.method == 'preferences.set');
      final value = json(write.arguments)['value'] as Map<String, dynamic>;
      expect((value[webdavAccountKey] as Map<String, dynamic>)['password'],
          '${_fakeMarker}new-secret');
      // The controller's map refreshes from the channel reply, and reading it
      // back opens the envelope.
      expect(await box.webDavAccount.read(), updated);
    });

    test('webdavCheck probes the decrypted account and reports a bad envelope', () async {
      box.preferences = Map<String, dynamic>.from(prefs);
      expect(await box.webdavCheck(), isTrue);
      expect(probedAccount, _legacy);
      expect(calls.where((c) => c.method == 'webdav.check'), isEmpty);

      // A document sealed by another device: the probe still runs, with an empty
      // password, and the reason is surfaced where the user asked to connect.
      prefs[webdavAccountKey] = <String, dynamic>{
        ..._legacy,
        'password': 'enc:v1:from-another-install',
      };
      box.preferences = Map<String, dynamic>.from(prefs);
      final message = box.messages.first;
      expect(await box.webdavCheck(), isTrue);
      expect(probedAccount!['password'], '');
      expect(await message, contains('cannot be decrypted'));
    });

    test('a failed seal surfaces from webdavSet and leaves the document alone', () async {
      box.preferences = Map<String, dynamic>.from(prefs);
      messenger.setMockMethodCallHandler(secure, (call) async {
        calls.add(call);
        throw PlatformException(code: 'seal_failed', message: 'KeyStoreException');
      });
      await expectLater(
        box.webdavSet(<String, dynamic>{..._legacy, 'password': 'new-secret'}),
        throwsA(isA<WebDavSecretException>()),
      );
      expect(calls.where((c) => c.method == 'preferences.set'), isEmpty);
      expect(box.preferences[webdavAccountKey], prefs[webdavAccountKey]);
    });
  });
}
