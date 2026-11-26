import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/pages/settings.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

void main() {
  for (final available in [true, false]) {
    testWidgets('About checks Flrone releases and handles available=$available', (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.about');
      final calls = <MethodCall>[];
      final update = Completer<Json>();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'ready': return {'version': '1.0', 'coreVersion': '1.15',
            'coreRef': '48273be2870fd2c81059628ff2cc439ac711808e',
            'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'}};
          case 'updates.check': return update.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
      await tester.pumpAndSettle();
      openPage(tester.element(find.byType(HomePage)), const AboutPage());
      await tester.pumpAndSettle();
      // The hero is the launcher's artwork, so the asset has to be in the bundle and not just named.
      expect(find.byWidgetPredicate((widget) {
        final decoration = widget is DecoratedBox ? widget.decoration : null;
        final image = decoration is ShapeDecoration ? decoration.image?.image : null;
        return image is AssetImage && image.assetName == 'assets/images/app_icon.webp';
      }), findsOneWidget);
      // The About page carries both credits in-app (shown only, not tapped: the
      // update flow below asserts on every url.open call this test makes).
      await tester.ensureVisible(find.text('giturass/B-box'));
      expect(find.text('giturass/B-box'), findsOneWidget);
      expect(find.text('B-box: early migration approach'), findsOneWidget);
      expect(find.text('Bettbox: detailed feature reference'), findsOneWidget);
      // The core's own version plus the short pin, so a build's core is identifiable.
      expect(find.text('sing-box 1.15 (48273be)'), findsOneWidget);
      // The version badge is the update entry; the licence badge opens the licences.
      expect(find.text('GPL-3.0'), findsOneWidget);
      final check = find.text('v1.0');
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pump();
      expect(calls.where((call) => call.method == 'updates.check'), hasLength(1));
      update.complete({'available': available, 'hasMetadata': true, 'version': '2.0',
        'notes': 'Release notes', 'url': 'https://github.com/yuedaochangmendian/throne-flclash-ui/releases/tag/v2.0',
        'downloadUrl': 'https://github.com/yuedaochangmendian/throne-flclash-ui/releases/download/v2.0/Flrone-2.0-arm64-v8a.apk'});
      await tester.pumpAndSettle();
      expect(find.text(available ? 'Update available' : 'You are up to date'), findsOneWidget);
      if (available) {
        expect(find.text('Release notes'), findsOneWidget);
        await tester.tap(find.text('Download'));
        await tester.pumpAndSettle();
        expect((calls.lastWhere((call) => call.method == 'url.open').arguments as Map)['url'],
          'https://github.com/yuedaochangmendian/throne-flclash-ui/releases/download/v2.0/Flrone-2.0-arm64-v8a.apk');
      } else {
        expect(find.text('Download'), findsNothing);
        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(calls.where((call) => call.method == 'url.open'), isEmpty);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    });
  }

  testWidgets('release notes switch language and collapse when long', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.about-notes');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final longEnglish = List.filled(60, '* A long release note line that wraps several times on a phone.').join('\n');
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready': return {'version': '1.0', 'coreVersion': '1.15',
          'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'}};
        case 'updates.check': return {
          'available': true, 'hasMetadata': true, 'version': '2.0',
          'notes': longEnglish, 'notesZh': '中文说明',
          'url': 'https://example.org/release',
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const AboutPage());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('v1.0'));
    await tester.tap(find.text('v1.0'));
    await tester.pumpAndSettle();

    // README's language line: both names visible, one at a time selected.
    expect(find.text('简体中文'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.textContaining('A long release note line'), findsWidgets);
    expect(find.text('Show more'), findsOneWidget);
    expect(find.text('Show less'), findsNothing);

    await tester.tap(find.text('简体中文'));
    await tester.pumpAndSettle();
    expect(find.text('中文说明'), findsOneWidget);
    expect(find.text('Show more'), findsNothing, reason: 'the Chinese note is short');

    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show more'));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('About keeps only the version badge as its update entry', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.about-update-settings');
    final settings = <String, dynamic>{'allowBetaUpdate': false, 'updateCheckAuto': false};
    final edits = <Json>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {'version': '1.0', 'coreVersion': '1.15',
            'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'},
            'settings': settings};
        case 'settings.set':
          final args = json(call.arguments);
          edits.add(args);
          settings[args['key'] as String] = args['value'];
          return settings;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const AboutPage());
    await tester.pumpAndSettle();

    // The version badge is the only update control; the channel/auto-check
    // preferences and their restore-defaults action are gone from this page.
    expect(find.text('v1.0'), findsOneWidget);
    expect(find.text('Update settings'), findsNothing);
    expect(find.text('Updates'), findsNothing);
    expect(find.text('Allow beta versions'), findsNothing);
    expect(find.text('Check for updates automatically'), findsNothing);
    expect(edits, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('General page has no duplicate update settings entry', (tester) async {
    reportFlutterErrors();
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.general-no-updates');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': '1.0', 'coreVersion': '1.15', 'dashboard': {'status': 'Stopped'},
          'capabilities': {'update': true}};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const GeneralPage());
    await tester.pumpAndSettle();
    expect(find.text('Update settings'), findsNothing);
    expect(find.text('Allow beta versions'), findsNothing);
    expect(find.text('Updates'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('update dialog with no download file opens the release page', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.about-no-file');
    final calls = <MethodCall>[];
    final update = Completer<Json>();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') {
        return {'version': '1.0', 'coreVersion': '1.15',
          'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'}};
      }
      if (call.method == 'updates.check') return update.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const AboutPage());
    await tester.pumpAndSettle();
    // An offer with a release page but no APK must still offer a working link.
    await tester.ensureVisible(find.text('v1.0'));
    await tester.tap(find.text('v1.0'));
    await tester.pump();
    update.complete({
      'available': true, 'hasMetadata': true, 'version': '2.0',
      'url': 'https://github.com/yuedaochangmendian/throne-flclash-ui/releases/tag/v2.0',
    });
    await tester.pumpAndSettle();
    expect(find.text('Releases'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
    await tester.tap(find.text('Releases'));
    await tester.pumpAndSettle();
    expect((calls.lastWhere((call) => call.method == 'url.open').arguments as Map)['url'],
      'https://github.com/yuedaochangmendian/throne-flclash-ui/releases/tag/v2.0');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
