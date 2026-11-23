import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/pages/tools.dart';
import 'package:flrone/pages/traffic_stats.dart';
import 'package:flrone/services/traffic_stats.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

Json _delta({
  int proxyUp = 0,
  int proxyDown = 0,
  int directUp = 0,
  int directDown = 0,
  Map<String, List<int>> hosts = const {},
  Map<String, List<int>> nodes = const {},
  Map<String, List<int>> rules = const {},
}) => {
      'proxyUp': proxyUp,
      'proxyDown': proxyDown,
      'directUp': directUp,
      'directDown': directDown,
      if (hosts.isNotEmpty) 'hosts': hosts,
      if (nodes.isNotEmpty) 'nodes': nodes,
      if (rules.isNotEmpty) 'rules': rules,
    };

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

    test('attribution merges the proxy/direct split and the maps', () {
      var now = DateTime(2026, 11, 23, 10);
      final ledger = TrafficLedger(clock: () => now);
      ledger.record(1000, 2000);
      ledger.mergeAttribution(_delta(
        proxyUp: 800, proxyDown: 1600,
        directUp: 200, directDown: 400,
        hosts: {'a.example': [800, 1600], 'b.example': [200, 400]},
        nodes: {'Tokyo': [800, 1600]},
        rules: {'geosite-a': [1000, 2000]},
      ));
      final day = ledger.day(now)!;
      expect(day.proxyUp + day.proxyDown, 2400);
      expect(day.directUp + day.directDown, 600);
      expect(day.hosts['a.example']!.total, 2400);
      expect(day.nodes['Tokyo']!.total, 2400);
      expect(day.rules['geosite-a']!.total, 3000);
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
      final ledger = TrafficLedger(clock: () => now, retentionDays: 30);
      ledger.record(1, 1);
      now = DateTime(2026, 12, 15);
      ledger.record(2, 2);
      expect(ledger.days.keys, [TrafficLedger.keyOf(now)]);
    });

    test('json round trip keeps hours, split, maps and profiles', () {
      final now = DateTime(2026, 11, 23, 8);
      final ledger = TrafficLedger(clock: () => now);
      ledger.record(1000, 2000, profileId: '3', profileName: 'Tokyo');
      ledger.mergeAttribution(_delta(proxyUp: 600, directUp: 400, hosts: {'a.example': [1000, 2000]}));
      final restored = TrafficLedger(clock: () => now)..load(json(ledger.toJson()));
      final day = restored.day(now)!;
      expect(day.up, 1000);
      expect(day.hourDown[8], 2000);
      expect(day.profiles['3']!.name, 'Tokyo');
      expect(day.proxyUp, 600);
      expect(day.directUp, 400);
      expect(day.hosts['a.example']!.down, 2000);
    });
  });

  Future<void> mountApp(WidgetTester tester, String channelName) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 900);
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
        return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}, 'preferences': {'locale': 'en'}};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pumpAndSettle();
  }

  testWidgets('the traffic page renders the switch, totals, rules and ranking', (tester) async {
    await mountApp(tester, 'test.traffic-stats');
    final now = DateTime.now();
    final ledger = TrafficLedger();
    final today = DayTraffic()..up = 1 << 20..down = 2 << 20;
    today.hourUp[10] = 1 << 20;
    today.hourDown[10] = 2 << 20;
    today.mergeAttribution(_delta(
      proxyUp: 1 << 20, proxyDown: 2 << 20,
      hosts: {'a.example': [1 << 20, 2 << 20]},
      nodes: {'Tokyo': [1 << 20, 2 << 20]},
      rules: {'geosite-a': [1 << 20, 2 << 20]},
    ));
    today.profiles['7'] = ProfileTraffic()..name = 'Main'..up = 1 << 20..down = 2 << 20;
    ledger.days[TrafficLedger.keyOf(now)] = today;
    ledger.days[TrafficLedger.keyOf(now.subtract(const Duration(days: 1)))] = DayTraffic()
      ..up = 1 << 19
      ..down = 1 << 19;

    openPage(tester.element(find.byType(HomePage)), TrafficStatsPage(ledger: ledger));
    await tester.pumpAndSettle();

    expect(find.text('Traffic statistics'), findsWidgets);
    expect(find.text('Enable traffic statistics'), findsOneWidget);
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('This week'), findsOneWidget);
    expect(find.text('This month'), findsOneWidget);
    expect(find.text('Rule hits'), findsOneWidget);
    expect(find.text('geosite-a'), findsOneWidget);
    // The ranking lives below the fold; the page builds list children lazily.
    await tester.drag(find.text('Rule hits'), const Offset(0, -500));
    await tester.pumpAndSettle();
    expect(find.text('Ranking'), findsOneWidget);
    expect(find.text('Domain'), findsOneWidget);
    expect(find.text('a.example'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the tools page lists the traffic statistics entry', (tester) async {
    await mountApp(tester, 'test.traffic-tools');
    openPage(tester.element(find.byType(HomePage)), const ToolsPage());
    await tester.pumpAndSettle();
    expect(find.text('Traffic statistics'), findsOneWidget);
  });
}
