import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/pages/connections.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/errors.dart';

Future<StreamController<dynamic>> mountApp(
  WidgetTester tester, {
  required Map<String, dynamic> preferences,
  Map<String, dynamic> settings = const {},
  List<dynamic> connections = const [],
  Object? updatesReply = false,
  Object? updatesThrow,
  required List<MethodCall> calls,
}) async {
  reportFlutterErrors();
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
  addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
  final events = StreamController<dynamic>.broadcast();
  addTearDown(events.close);
  const channel = MethodChannel('test.dashboard-cards');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    switch (call.method) {
      case 'ready':
        return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'},
          'preferences': preferences, 'settings': settings};
      case 'dashboard.egress':
        return {'ip': '203.0.113.1', 'country': 'CN', 'type': 'Residential'};
      case 'updates.check': if (updatesThrow != null) throw updatesThrow; return updatesReply;
      case 'preferences.set':
        preferences.addAll(json((call.arguments as Map)['value']));
        return preferences;
    }
    return null;
  });
  addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(channel, null));
  await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  if (connections.isNotEmpty) {
    events.add({'type': 'connections', 'value': connections});
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
  }
  return events;
}

void main() {
  testWidgets('Connections card counts active and closed and opens the page', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final calls = <MethodCall>[];
    final events = await mountApp(tester, calls: calls, preferences: {
      'locale': 'en',
      'dashboardCards': ['Status', 'Connections'],
      'hiddenCards': <String>[],
    }, connections: [
      {'id': 'a', 'createdAt': now},
      {'id': 'b', 'createdAt': now},
      {'id': 'c', 'createdAt': now, 'closedAt': now},
    ]);
    // The live feed's rows are the fresher value while the page is open, but only a running
    // service can have active connections — the card starts from the ready wire (Stopped).
    events.add({
      'type': 'dashboard',
      'value': {'status': 'Started', 'connections': 0},
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('Closed'), findsOneWidget);
    // Two rows have no closedAt (active); the sampled feed also carries one closed row.
    expect(find.text('2'), findsOneWidget);
    await tester.ensureVisible(find.text('Connections').first);
    await tester.tap(find.text('Connections').first);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the Connections card reads the host count without the list feed', (tester) async {
    final calls = <MethodCall>[];
    final events = await mountApp(tester, calls: calls, preferences: {
      'locale': 'en',
      'dashboardCards': ['Connections'],
      'hiddenCards': <String>[],
    });
    // No `connections` event ever arrives: the count must come from the dashboard wire alone
    // (the host polls it every 2 s while the service is connected).
    events.add({
      'type': 'dashboard',
      'value': {'status': 'Started', 'connections': 4},
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('4'), findsOneWidget);
    // Closed rows exist only in the sampled list, so the card does not invent one.
    expect(find.text('Closed'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stopped service does not count the last session\'s sampled rows', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final calls = <MethodCall>[];
    await mountApp(tester, calls: calls, preferences: {
      'locale': 'en',
      'dashboardCards': ['Connections'],
      'hiddenCards': <String>[],
    }, connections: [
      {'id': 'a', 'createdAt': now},
      {'id': 'b', 'createdAt': now},
      {'id': 'c', 'createdAt': now},
    ]);
    // The ready wire says Stopped; the rows are what the last session's feed left behind.
    expect(find.text('3'), findsNothing);
    expect(find.text('0'), findsNWidgets(2), reason: 'Active and Closed both read 0');
    expect(tester.takeException(), isNull);
  });

  testWidgets('update badge appears when the auto check returns an offer', (tester) async {
    final preferences = <String, dynamic>{'locale': 'en'};
    final calls = <MethodCall>[];
    await mountApp(tester, calls: calls, preferences: preferences,
      settings: {'updateCheckAuto': true},
      updatesReply: {'available': true, 'version': '9.9.9', 'hasMetadata': true,
        'notes': 'notes', 'url': 'https://example.org/release'});
    expect(find.text('Update available 9.9.9'), findsOneWidget);
    // The check timestamp and the full offer are cached in preferences.
    expect(preferences['updateCheckedAt'], isA<num>());
    expect(preferences['updateOffer'], contains('9.9.9'));
    // Tapping the badge reuses the About release dialog from the cached payload,
    // without another network round-trip.
    final before = calls.where((c) => c.method == 'updates.check').length;
    await tester.tap(find.text('Update available 9.9.9'));
    await tester.pumpAndSettle();
    expect(find.text('Flrone 9.9.9'), findsOneWidget);
    expect(calls.where((c) => c.method == 'updates.check').length, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a later check with no update clears the cached offer', (tester) async {
    final preferences = <String, dynamic>{'locale': 'en'};
    final calls = <MethodCall>[];
    // First round: an offer is cached and the badge shows.
    await mountApp(tester, calls: calls, preferences: preferences,
      settings: {'updateCheckAuto': true},
      updatesReply: {'available': true, 'version': '9.9.9', 'hasMetadata': true,
        'notes': 'notes', 'url': 'https://example.org/release'});
    expect(find.text('Update available 9.9.9'), findsOneWidget);
    expect(preferences['updateOffer'], contains('9.9.9'));
    // Simulate the next daily window: the cache stamp is old again, but the
    // previously stored offer is still there. A "no update" reply must retire it.
    preferences.remove('updateCheckedAt');
    await tester.pumpWidget(const SizedBox.shrink());
    await mountApp(tester, calls: calls, preferences: preferences,
      settings: {'updateCheckAuto': true},
      updatesReply: {'available': false});
    expect(calls.where((c) => c.method == 'updates.check'), hasLength(2));
    expect(preferences['updateOffer'], '');
    expect(find.textContaining('Update available'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('no update request when the cached check is fresh', (tester) async {
    final calls = <MethodCall>[];
    await mountApp(tester, calls: calls,
      preferences: {'locale': 'en', 'updateCheckedAt': DateTime.now().millisecondsSinceEpoch},
      settings: {'updateCheckAuto': true},
      updatesReply: {'available': true, 'version': '9.9.9', 'hasMetadata': true});
    expect(calls.where((c) => c.method == 'updates.check'), isEmpty);
    expect(find.textContaining('Update available'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed update check does not burn the daily attempt', (tester) async {
    final preferences = <String, dynamic>{'locale': 'en'};
    final calls = <MethodCall>[];
    await mountApp(tester, calls: calls, preferences: preferences,
      settings: {'updateCheckAuto': true}, updatesThrow: PlatformException(code: 'offline'));
    expect(calls.where((c) => c.method == 'updates.check'), isNotEmpty);
    // No stamp: the next mount may retry instead of waiting a day for a failed request.
    expect(preferences['updateCheckedAt'], isNull);
    expect(find.textContaining('Update available'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
