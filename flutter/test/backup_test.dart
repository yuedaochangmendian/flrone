import 'dart:async';
import 'dart:convert';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/pages/backup.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flrone/services/backup_webdav.dart';
import 'package:flrone/services/backup_store.dart';
import 'package:flrone/services/webdav_client.dart' show WebDavException;
import 'support/errors.dart';
import 'support/fake_webdav_backup.dart';

const _sample = {'format': 'bbox-1', 'profiles': [{'id': 1, 'name': 'Synthetic', 'content': '{}'}]};
const _account = {'uri': 'https://dav.example.test/directory', 'user': 'account', 'password': 'synthetic', 'fileName': 'test.json'};

Future<BoxController> _mount(
  WidgetTester tester,
  Future<dynamic> Function(MethodCall) handler, {
  String strategy = 'Compatible',
  Future<bool> Function(Map<String, dynamic>?)? webDavChecker,
  Map<String, dynamic>? account,
  bool Function()? failAccountSave,
  List<MethodCall>? recordCalls,
  WebDavBackupTransport? webDavBackup,
}) async {
  reportFlutterErrors();
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  const channel = MethodChannel('test.backup');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  // ADR 0005 phase 1: the account is a Dart-owned value in the preferences
  // document. `ready` carries it (as the host's legacy fold does) and there is no
  // webdav.get/set channel anymore. preferences.set is the persistence path.
  final preferences = <String, dynamic>{
    'locale': 'en', 'restoreStrategy': strategy,
    'webdavAccount': ?account,
  };
  messenger.setMockMethodCallHandler(channel, (call) async {
    recordCalls?.add(call);
    if (call.method == 'ready') {
      return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'},
      'preferences': Map<String, dynamic>.from(preferences)};
    }
    if (call.method == 'preferences.set') {
      if (failAccountSave?.call() == true) {
        throw PlatformException(code: 'disk', message: 'Synthetic account save failed');
      }
      final values = json(call.arguments)['value'] as Map<String, dynamic>;
      values.forEach((key, value) {
        if (value == null) {
          preferences.remove(key);
        } else {
          preferences[key] = value;
        }
      });
      return Map<String, dynamic>.from(preferences);
    }
    return handler(call);
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  final box = BoxController(
    channel: channel,
    events: const Stream.empty(),
    // WebDAV connectivity is pure Dart now; inject a deterministic probe so
    // the page never opens a socket in a widget test.
    webDavChecker: webDavChecker ?? (_) async => true,
    // ADR 0005 phase 4: the WebDAV backup transport is Dart-owned; inject a fake.
    webDavBackupFactory: (_, {appVersion = ''}) => webDavBackup,
  );
  await tester.pumpWidget(BoxApp(controller: box));
  await tester.pumpAndSettle();
  unawaited(openPage(tester.element(find.byType(HomePage)), const BackupPage()));
  await tester.pumpAndSettle();
  return box;
}

Future<void> _tapRow(WidgetTester tester, String key) async {
  await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 160,
    scrollable: find.descendant(of: find.byType(BackupPage), matching: find.byType(Scrollable)).first);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('canceled local pickers never report success or restore data; exports use compact JSON', (tester) async {
    final calls = <MethodCall>[];
    await _mount(tester, (call) async {
      calls.add(call);
      if (call.method == 'backup.create') return _sample;
      if (call.method == 'backup.open') return _sample;
      if (call.method == 'document.save') return false;
      return null;
    });
    await _tapRow(tester, 'local-backup');
    expect(find.text('Backup complete'), findsNothing);
    final content = json(calls.singleWhere((call) => call.method == 'document.save').arguments)['content'] as String;
    expect(content, jsonEncode(_sample));
    await _tapRow(tester, 'local-restore');
    await tester.tap(find.text('Restore profiles only'));
    await tester.pumpAndSettle();
    // The read comes first now, so it carries no scope; the choice is what the dialog is for.
    expect(calls.singleWhere((call) => call.method == 'backup.open').arguments, isNull);
    expect(find.text('Restore 1 profiles?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'backup.restore'), isEmpty);
    expect(find.text('Restore complete'), findsNothing);
    expect(find.byType(BackupPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a cancelled local picker asks nothing further and restores nothing', (tester) async {
    final calls = <MethodCall>[];
    await _mount(tester, (call) async {
      calls.add(call);
      // The bridge answers null when the user backs out of the file picker.
      if (call.method == 'backup.open') return null;
      return null;
    });
    await _tapRow(tester, 'local-restore');
    expect(find.text('No backup to restore'), findsNothing);
    expect(find.text('Restore profiles only'), findsNothing);
    expect(calls.where((call) => call.method == 'backup.restore'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a backup without profiles refuses a profiles-only restore', (tester) async {
    final calls = <MethodCall>[];
    await _mount(tester, (call) async {
      calls.add(call);
      if (call.method == 'backup.open') return {'format': 'bbox-1', 'profiles': <Json>[]};
      return null;
    });
    await _tapRow(tester, 'local-restore');
    await tester.tap(find.text('Restore profiles only'));
    await tester.pumpAndSettle();
    expect(find.text('This backup holds no profiles'), findsOneWidget);
    expect(find.text('Restore 0 profiles?'), findsNothing);
    expect(calls.where((call) => call.method == 'backup.restore'), isEmpty);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final (scope, strategy) in [('profiles', 'Override'), ('all', 'Compatible')]) {
    testWidgets('restore passes $scope/$strategy and a failed restore remains retryable', (tester) async {
      final calls = <MethodCall>[];
      var reject = true;
      await _mount(tester, (call) async {
        calls.add(call);
        if (call.method == 'backup.open') return _sample;
        if (call.method == 'backup.restore') {
          if (reject) throw PlatformException(code: 'restore', message: 'Synthetic restore failed');
          return 1;
        }
        return null;
      }, strategy: strategy);
      for (var attempt = 0; attempt < 2; attempt++) {
        await _tapRow(tester, 'local-restore');
        await tester.tap(find.text(scope == 'profiles' ? 'Restore profiles only' : 'Restore all data'));
        await tester.pumpAndSettle();
        expect(find.text(strategy == 'Override'
          ? 'Profiles missing from this backup will be removed.'
          : 'Matching profiles will be replaced. Other profiles will be kept.'), findsOneWidget);
        await tester.tap(find.text('Restore').last);
        await tester.pumpAndSettle();
        final args = json(calls.lastWhere((call) => call.method == 'backup.restore').arguments);
        expect(args['scope'], scope);
        expect(args['strategy'], strategy);
        expect(args['backup'], _sample);
        if (attempt == 0) {
          expect(find.text('Restore complete'), findsNothing);
          expect(find.byType(BackupPage), findsOneWidget);
          reject = false;
        } else {
          expect(find.text('Restore complete'), findsOneWidget);
          await tester.tap(find.text('Close'));
          await tester.pumpAndSettle();
        }
      }
      expect(calls.where((call) => call.method == 'backup.restore'), hasLength(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('WebDAV upload takes bytes from backup.create and uses the Dart transport, not a picker', (tester) async {
    final calls = <MethodCall>[];
    final containerBytes = utf8.encode('THRN-synthetic-container');
    final envelope = {
      'format': 2,
      'thr': base64Encode(containerBytes),
      'scope': 'all',
      'profiles': <dynamic>[],
    };
    final uploaded = Completer<void>();
    final fake = FakeWebDavBackup(uploadCompleter: uploaded.future);
    await _mount(tester, (call) async {
      calls.add(call);
      if (call.method == 'backup.create') return envelope;
      return null;
    }, account: _account, webDavBackup: fake);
    await tester.tap(find.byKey(const ValueKey('remote-backup')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Backup complete'), findsNothing);
    // The scope-derived parts and the native-exported bytes reach the Dart
    // transport; there is no webdav.upload channel and no document.save.
    expect(fake.uploaded, isEmpty); // still awaiting the server
    expect(calls.where((call) => call.method == 'backup.create'), hasLength(1));
    expect(calls.where((call) => call.method == 'webdav.upload'), isEmpty);
    expect(calls.where((call) => call.method == 'document.save'), isEmpty);
    uploaded.complete();
    await tester.pumpAndSettle();
    expect(fake.uploaded, hasLength(1));
    expect(fake.uploaded.single, containerBytes);
    expect(fake.uploadedParts.single, containsAll(['profiles', 'routes', 'settings']));
    expect(find.text('Backup complete'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('WebDAV remote restore reads a Dart-decoded container and hands the same envelope to backup.restore', (tester) async {
    final calls = <MethodCall>[];
    final container = thrnEncode(
      thrnAndroidMeta(
        parts: const ThrnParts(profiles: true, settings: true),
        appVersion: '4.10.1',
        deviceId: 'device-A',
        deviceName: 'Pixel',
        createdAt: 'Thu Sep 24 03:43:00 2026',
      ),
      {thrnDatabase: utf8.encode('SQLite format 3\u0000')},
    );
    final entry = WebDavBackupEntry(
      file: 'throne_backup_test.thrbackup',
      createdAt: 1,
      size: container.length,
      deviceName: 'Pixel',
      platform: 'android',
      appVersion: '4.10.1',
      parts: const ['profiles'],
      indexed: true,
      thisDevice: false,
    );
    final fake = FakeWebDavBackup(entries: [entry], downloadBytes: container);
    await _mount(tester, (call) async {
      calls.add(call);
      if (call.method == 'backup.restore') return null;
      return null;
    }, account: _account, webDavBackup: fake);
    await _tapRow(tester, 'remote-restore');
    await tester.pumpAndSettle();
    expect(fake.downloadCount, 1);
    // No webdav.read channel; the read came from the Dart transport.
    expect(calls.where((call) => call.method == 'webdav.read'), isEmpty);
    // A synthetic DB has no profiles table, so the preview count is 0; choose
    // "all" scope, which allows a zero-profile restore to proceed.
    await tester.tap(find.text('Restore all data'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restore').last);
    await tester.pumpAndSettle();
    final restore = json(calls.lastWhere((call) => call.method == 'backup.restore').arguments);
    expect(restore['scope'], 'all');
    expect(base64Decode(restore['backup']['thr'] as String), container);
    expect(find.text('Restore complete'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WebDAV remote restore with no backups shows the empty message', (tester) async {
    final fake = FakeWebDavBackup(entries: const []);
    await _mount(tester, (call) async => null, account: _account, webDavBackup: fake);
    await _tapRow(tester, 'remote-restore');
    await tester.pumpAndSettle();
    expect(find.text('No remote backup found'), findsOneWidget);
    expect(fake.downloadCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WebDAV remote restore with a failing transport stays usable', (tester) async {
    final fake = FakeWebDavBackup(listError: const WebDavException('auth'));
    await _mount(tester, (call) async => null, account: _account, webDavBackup: fake);
    await _tapRow(tester, 'remote-restore');
    await tester.pumpAndSettle();
    // The error is reported through box.report, but the page survives.
    expect(find.byType(BackupPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('WebDAV form validates its directory URL and preserves edits after failed save and canceled dismissal', (tester) async {
    final calls = <MethodCall>[];
    var reject = true;
    await _mount(tester, (call) async {
      // preferences.set is handled by _mount for the account; this handler sees
      // only non-account methods. The account save is simulated as failing by
      // throwing from the shared mock below (see the reject flag on 'save').
      return null;
    }, failAccountSave: () => reject, recordCalls: calls);
    await tester.tap(find.text('Bind'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a WebDAV HTTP or HTTPS directory address'), findsOneWidget);
    expect(calls.where((call) => call.method == 'webdav.set'), isEmpty);
    expect(calls.where((call) => call.method == 'preferences.set'), isEmpty);
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'https://dav.example.test/directory');
    await tester.enterText(fields.at(1), 'account');
    await tester.enterText(fields.at(2), 'synthetic');
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Synthetic account save failed'), findsOneWidget);
    final formContext = tester.element(find.byType(WebDAVForm));
    final dismissed = SheetDismissScope.of(formContext)!.value!();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await dismissed;
    expect(find.byType(WebDAVForm), findsOneWidget);
    expect(tester.widget<TextFormField>(fields.at(0)).controller!.text, 'https://dav.example.test/directory');
    reject = false;
    await tester.tap(find.byTooltip('Save'));
    await tester.pumpAndSettle();
    expect(find.byType(WebDAVForm), findsNothing);
    // ADR 0005 phase 1: the account saves through preferences.set (webdav.set is
    // gone); the value is one `webdavAccount` object in the document.
    final accountWrite = json(calls.lastWhere((call) => call.method == 'preferences.set').arguments)['value'] as Map<String, dynamic>;
    expect(accountWrite['webdavAccount'], {
      'uri': 'https://dav.example.test/directory', 'user': 'account', 'password': 'synthetic', 'fileName': defaultBackupFileName,
    });
    expect(find.text('account'), findsOneWidget);
    // The connectivity probe reads the Dart-owned account and runs the injected
    // checker; there is no webdav.get / webdav.check channel method anymore.
    expect(calls.where((call) => call.method == 'webdav.get'), isEmpty);
    expect(calls.where((call) => call.method == 'webdav.check'), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
