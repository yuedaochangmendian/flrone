import 'dart:async';

import 'package:flrone/components/connectivity/connectivity_page.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/network_toolbox.dart';
import 'package:flrone/pages/traffic_stats.dart';
import 'package:flrone/services/traffic_stats.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

void main() {
  Future<void> mountApp(WidgetTester tester, String channelName,
      {Json settings = const {}, Locale locale = const Locale('en')}) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(420, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.platformDispatcher.localesTestValue = [locale];
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
          'preferences': {'locale': locale.languageCode},
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

  Future<void> openToolbox(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const NetworkToolboxPage());
    await tester.pumpAndSettle();
  }

  testWidgets('the toolbox shows every card title and description', (tester) async {
    await mountApp(tester, 'test.toolbox-cards');
    await openToolbox(tester);

    for (final title in [
      'Speed test', 'Connectivity test', 'Traffic statistics', 'Node tests',
      'Speed test settings', 'Traffic statistics settings', 'Exit detection',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'card title $title');
    }
    expect(find.text('Measure download, upload speed and latency'), findsOneWidget);
    expect(find.text('Check whether common services are reachable'), findsOneWidget);
    expect(find.text('View traffic by day, week or month'), findsOneWidget);
    expect(find.text('Test URL, timeout and concurrency'), findsOneWidget);
    expect(find.text('Mode, timeout and simple download URL'), findsOneWidget);
    expect(find.text('Recording switches, retention and clearing'), findsOneWidget);
    expect(find.text('Country lookup and provider'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the card titles are translated', (tester) async {
    await mountApp(tester, 'test.toolbox-zh', locale: const Locale('zh'));
    await openToolbox(tester);
    for (final title in [
      '测速', '连通性测试', '流量统计', '节点测试', '测速设置', '流量统计设置', '出口检测',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'card title $title');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the speed test card opens the SpeedTestPage', (tester) async {
    await mountApp(tester, 'test.toolbox-speed');
    await openToolbox(tester);

    await tester.tap(find.text('Speed test'));
    await tester.pumpAndSettle();
    expect(find.byType(SpeedTestPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the connectivity card opens the ConnectivityPage', (tester) async {
    await mountApp(tester, 'test.toolbox-connectivity');
    await openToolbox(tester);

    await tester.tap(find.text('Connectivity test'));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectivityPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping the traffic card opens the TrafficStatsPage', (tester) async {
    await mountApp(tester, 'test.toolbox-traffic-page');
    await openToolbox(tester);

    await tester.tap(find.text('Traffic statistics'));
    await tester.pumpAndSettle();
    expect(find.byType(TrafficStatsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('node tests card opens a sheet with Test URL and Concurrent tests', (tester) async {
    await mountApp(tester, 'test.toolbox-node-sheet');
    await openToolbox(tester);

    await tester.tap(find.text('Node tests'));
    await tester.pumpAndSettle();
    expect(find.text('Test URL'), findsOneWidget);
    expect(find.text('Concurrent tests'), findsOneWidget);
    expect(find.text('Direct test URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mode 3 shows Simple download URL in the speed settings sheet', (tester) async {
    await mountApp(tester, 'test.toolbox-speed-sheet-3', settings: {'speedTestMode': 3});
    await openToolbox(tester);

    await tester.tap(find.text('Speed test settings'));
    await tester.pumpAndSettle();
    expect(find.text('Speed test mode'), findsOneWidget);
    expect(find.text('Speed test timeout'), findsOneWidget);
    expect(find.text('Simple download URL'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('other modes hide Simple download URL in the speed settings sheet', (tester) async {
    await mountApp(tester, 'test.toolbox-speed-sheet-0', settings: {'speedTestMode': 0});
    await openToolbox(tester);

    await tester.tap(find.text('Speed test settings'));
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

  testWidgets('the traffic settings sheet toggles write through the store', (tester) async {
    await mountApp(tester, 'test.toolbox-traffic-sheet');
    addTearDown(() => TrafficStatsStore.instance.setEnabled(false));
    final store = TrafficStatsStore.instance;
    expect(store.enabled, isFalse);
    await openToolbox(tester);

    await tester.tap(find.text('Traffic statistics settings'));
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
