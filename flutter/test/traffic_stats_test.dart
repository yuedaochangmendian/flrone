import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/pages/tools.dart';
import 'package:flrone/pages/traffic_stats.dart';
import 'package:flrone/services/traffic_stats.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

void main() {
  group('TrafficLedger', () {
    test('deltas land in the current hour and the profile bucket', () {
      var now = DateTime(2026, 11, 23, 10, 30);
      final ledger = TrafficLedger(clock: () => now);
      ledger.record(100, 200, profileId: '7', profileName: 'Main');
      ledger.record(50, 25, profileId: '7');
      final day = ledger.day(now)!;
      expect(day.up, 150);
      expect(day.down, 225);
      expect(day.hourUp[10], 150);
      expect(day.profiles['7']!.name, 'Main');
      expect(day.profiles['7']!.total, 375);
    });

    test('a new day starts a new bucket and the old one survives', () {
      var now = DateTime(2026, 11, 23, 23, 59);
      final ledger = TrafficLedger(clock: () => now);
      ledger.record(10, 10);
      now = DateTime(2026, 11, 24, 0, 1);
      ledger.record(5, 5);
      expect(ledger.days.length, 2);
      expect(ledger.day(now)!.hourUp[0], 5);
      expect(ledger.totalBetween(DateTime(2026, 11, 23), DateTime(2026, 11, 24)), 30);
    });

    test('retention drops days older than the window', () {
      var now = DateTime(2026, 11, 1);
      final ledger = TrafficLedger(clock: () => now);
      ledger.record(1, 1);
      now = DateTime(2026, 12, 15);
      ledger.record(2, 2);
      expect(ledger.days.keys, [TrafficLedger.keyOf(now)]);
    });

    test('json round trip keeps hours and profiles', () {
      final now = DateTime(2026, 11, 23, 8);
      final ledger = TrafficLedger(clock: () => now);
      ledger.record(1000, 2000, profileId: '3', profileName: 'Tokyo');
      final restored = TrafficLedger(clock: () => now)..load(json(ledger.toJson()));
      final day = restored.day(now)!;
      expect(day.up, 1000);
      expect(day.hourDown[8], 2000);
      expect(day.profiles['3']!.name, 'Tokyo');
    });
  });

  testWidgets('the traffic page renders today, the hourly chart and the history', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    const channel = MethodChannel('test.traffic-stats');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'}};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final now = DateTime.now();
    final ledger = TrafficLedger();
    final today = DayTraffic()..up = 1 << 20 ..down = 2 << 20;
    today.hourUp[10] = 1 << 20;
    today.hourDown[10] = 2 << 20;
    today.profiles['7'] = ProfileTraffic()..name = 'Tokyo'..up = 1 << 20..down = 2 << 20;
    ledger.days[TrafficLedger.keyOf(now)] = today;
    ledger.days[TrafficLedger.keyOf(now.subtract(const Duration(days: 1)))] = DayTraffic()
      ..up = 1 << 19
      ..down = 1 << 19;

    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), TrafficStatsPage(ledger: ledger));
    await tester.pumpAndSettle();

    expect(find.text('Traffic statistics'), findsWidgets);
    expect(find.text('Today'), findsWidgets);
    expect(find.text('Tokyo'), findsOneWidget);
    // The hourly chart's 6-hour axis labels.
    expect(find.text('0'), findsWidgets);
    expect(find.text('12'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tools page lists the traffic statistics entry', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    const channel = MethodChannel('test.traffic-tools');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'}};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ToolsPage());
    await tester.pumpAndSettle();
    expect(find.text('Traffic statistics'), findsOneWidget);
  });
}
