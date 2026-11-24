import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/pages/network_toolbox.dart';
import 'package:flrone/services/traffic_stats.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

void main() {
  Future<void> mountApp(WidgetTester tester, String channelName, {Json settings = const {}}) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    final channel = MethodChannel(channelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'settings': settings,
          'preferences': {'locale': 'en'},
        };
      }
      if (call.method == 'settings.set') return settings;
      if (call.method == 'preferences.set') return <String, dynamic>{};
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
  }

  testWidgets('the toolbox lists the three network tools and their sections', (tester) async {
    await mountApp(tester, 'test.toolbox-rows');
    openPage(tester.element(find.byType(HomePage)), const NetworkToolboxPage());
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ListItem, 'Connectivity test'), findsOneWidget);
    expect(find.widgetWithText(ListItem, 'Traffic statistics'), findsOneWidget);
    expect(find.widgetWithText(ListItem, 'Speed test'), findsOneWidget);
    // The settings that used to be the Testing entry live here, beside the tools.
    expect(find.widgetWithText(ListItem, 'Test URL'), findsOneWidget);
    expect(find.widgetWithText(ListItem, 'Concurrent tests'), findsOneWidget);
    // A choice row is a ListItem<String>; match its label rather than the raw type.
    expect(find.text('Lookup provider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Simple download URL row shows only for the simple download mode', (tester) async {
    await mountApp(tester, 'test.toolbox-mode-3', settings: {'speedTestMode': 3});
    openPage(tester.element(find.byType(HomePage)), const NetworkToolboxPage());
    await tester.pumpAndSettle();
    expect(find.text('Simple download URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Simple download URL row is hidden in the other modes', (tester) async {
    await mountApp(tester, 'test.toolbox-mode-0', settings: {'speedTestMode': 0});
    openPage(tester.element(find.byType(HomePage)), const NetworkToolboxPage());
    await tester.pumpAndSettle();
    expect(find.text('Simple download URL'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('the lookup provider options skip the ones the probe set cannot honour', () {
    expect(exitLookupProviders, contains('auto'));
    expect(exitLookupProviders, isNot(contains('ip2location')));
    expect(exitLookupProviders, isNot(contains('cloudflare')));
    expect(exitLookupProviderName('ip-api'), 'Lookup provider cleartext');
    expect(exitLookupProviderName('ipwho'), 'ipwho');
  });

  testWidgets('the traffic switches write through the store, details gated on recording', (tester) async {
    await mountApp(tester, 'test.toolbox-traffic');
    addTearDown(() => TrafficStatsStore.instance.setEnabled(false));
    final store = TrafficStatsStore.instance;
    expect(store.enabled, isFalse);
    openPage(tester.element(find.byType(HomePage)), const NetworkToolboxPage());
    await tester.pumpAndSettle();

    // Detail recording is off the table until recording itself is on.
    await tester.tap(find.text('Record details'));
    await tester.pumpAndSettle();
    expect(store.details, isTrue);

    await tester.tap(find.text('Enable traffic statistics'));
    await tester.pumpAndSettle();
    expect(store.enabled, isTrue);

    await tester.tap(find.text('Record details'));
    await tester.pumpAndSettle();
    expect(store.details, isFalse);
    expect(tester.takeException(), isNull);
  });
}
