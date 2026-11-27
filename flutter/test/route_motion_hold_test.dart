import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/pages/connections.dart';
import 'package:flrone/pages/logs.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

/// One line of the kernel tail, as the controller stores it.
Json _line(int id, String message) =>
    {'id': id, 'level': 'info', 'message': message, 'receivedAt': 1000 + id};

/// One connection row; the list renders `displayDestination`.
Json _connection(int id, String host) => {
  'id': id,
  'createdAt': 1700000000000 + id,
  'closedAt': 0,
  'network': 'tcp',
  'protocol': '',
  'destination': '$host:443',
  'displayDestination': host,
  'outbound': 'proxy',
  'rule': 'geosite',
  'source': '10.0.0.2:5',
  'chain': ['proxy'],
  'upload': 0,
  'download': 0,
  'uploadTotal': 0,
  'downloadTotal': 0,
};

void main() {
  late StreamController<dynamic> events;

  /// The real app shell over a mocked bridge, so a page opened here is the page that ships.
  Future<void> mountApp(WidgetTester tester, String channelName) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    events = StreamController<dynamic>.broadcast();
    final channel = MethodChannel(channelName);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started'},
            'settings': {'logLevel': 'info'},
          };
        case 'settings.set':
          return {'logLevel': (call.arguments as Map)['value']};
        case 'preferences.set':
          return ((call.arguments as Map)['value'] as Map).cast<String, Object?>();
      }
      return null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
  }

  /// Feeds one controller batch. The controller coalesces these over its batch window, so
  /// the clock has to pass it before the list hears about them.
  Future<void> emit(WidgetTester tester, String type, Object value) async {
    events.add({'type': type, 'value': value});
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
  }

  Future<void> openLogs(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const LogsPage());
    await tester.pumpAndSettle();
  }

  Future<void> openConnections(WidgetTester tester) async {
    openPage(tester.element(find.byType(HomePage)), const ConnectionsPage());
    await tester.pumpAndSettle();
  }

  /// Pushes a card route that takes two seconds to settle over [page] and leaves it moving.
  /// Only a card route drives the covered page's `secondaryAnimation`.
  Future<void> cover(WidgetTester tester, BuildContext page) async {
    Navigator.of(page).push(SlowCardRoute<void>(builder: (_) => const SizedBox.expand()));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  /// The log rows as rendered, oldest first. A route under an opaque card one is still built
  /// but skipped by the default finders, so the covered page is addressed with `skipOffstage`.
  List<String?> logBodies(WidgetTester tester) => tester
      .widgetList<SelectableText>(find.byType(SelectableText, skipOffstage: false))
      .map((text) => text.data)
      .toList();

  Finder text(String value) => find.text(value, skipOffstage: false);

  Scaffold scaffoldOf(WidgetTester tester, Type page) => tester.widget<Scaffold>(
    find.descendant(of: find.byType(page, skipOffstage: false), matching: find.byType(Scaffold))
        .first,
  );

  group('logs', () {
    testWidgets('a batch arriving under a moving card route waits for it to settle', (tester) async {
      await mountApp(tester, 'test.route-hold.logs.cover');
      await openLogs(tester);
      await emit(tester, 'logs', {'reset': true, 'entries': [_line(1, 'first line')]});
      await tester.pumpAndSettle();

      final page = tester.element(find.byType(LogsPage, skipOffstage: false));
      await cover(tester, page);
      expect(isRouteMoving(page), isTrue, reason: 'the cover route must still be moving');
      await emit(tester, 'logs', {'reset': true, 'entries': [_line(2, 'second line')]});
      expect(isRouteMoving(page), isTrue);
      expect(logBodies(tester), ['first line'], reason: 'a batch under a moving route is not painted');

      await tester.pumpAndSettle();
      expect(logBodies(tester), ['second line']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only the newest of two held log batches is replayed', (tester) async {
      await mountApp(tester, 'test.route-hold.logs.latest');
      await openLogs(tester);
      await emit(tester, 'logs', {'reset': true, 'entries': [_line(1, 'first line')]});
      await tester.pumpAndSettle();

      final page = tester.element(find.byType(LogsPage, skipOffstage: false));
      await cover(tester, page);
      await emit(tester, 'logs', {'reset': true, 'entries': [_line(2, 'second line')]});
      await emit(tester, 'logs', {'reset': true, 'entries': [_line(3, 'third line')]});
      expect(isRouteMoving(page), isTrue);
      expect(logBodies(tester), ['first line'], reason: 'neither held batch is painted');

      await tester.pumpAndSettle();
      expect(logBodies(tester), ['third line'], reason: 'the newest held batch is the one applied');
      expect(tester.takeException(), isNull);
    });

    testWidgets('first rows already in the controller are painted while the page arrives', (tester) async {
      await mountApp(tester, 'test.route-hold.logs.first');
      // Collected before any screen exists: these rows are the page's first content.
      await emit(tester, 'logs', {'reset': true, 'entries': [_line(1, 'first line')]});
      Navigator.of(tester.element(find.byType(HomePage))).push(SlowCardRoute<void>(
        builder: (_) => const SheetProvider(type: SheetType.page, child: LogsPage()),
      ));
      await tester.pump();
      // The sliver builds its lazy rows one frame after the page itself appears; at 100 ms the
      // two-second arrival is still moving, so a held first content would still be blank here.
      await tester.pump(const Duration(milliseconds: 100));

      final page = tester.element(find.byType(LogsPage, skipOffstage: false));
      expect(isRouteMoving(page), isTrue, reason: 'the page is still arriving');
      expect(logBodies(tester), ['first line'], reason: 'first content is shown, not held');

      await tester.pumpAndSettle();
      expect(logBodies(tester), ['first line']);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search applies at once while a log batch is held behind a moving route', (tester) async {
      await mountApp(tester, 'test.route-hold.logs.reader');
      await openLogs(tester);
      await emit(tester, 'logs', {
        'reset': true,
        'entries': [_line(1, 'alpha line'), _line(2, 'beta line')],
      });
      await tester.pumpAndSettle();

      final page = tester.element(find.byType(LogsPage, skipOffstage: false));
      await cover(tester, page);
      await emit(tester, 'logs', {'reset': true, 'entries': [_line(3, 'gamma line')]});
      expect(isRouteMoving(page), isTrue);

      // A reader action is not a batch: it applies on the tap frame.
      scaffoldOf(tester, LogsPage).searchState!.onSearch('alpha');
      await tester.pump();
      expect(logBodies(tester), ['alpha line']);
      expect(isRouteMoving(page), isTrue, reason: 'the reader action did not wait for the route');

      await tester.pumpAndSettle();
      expect(logBodies(tester), ['alpha line']);
      expect(tester.takeException(), isNull);
    });
  });

  group('connections', () {
    testWidgets('a sample arriving under a moving card route waits for it to settle', (tester) async {
      await mountApp(tester, 'test.route-hold.connections.cover');
      await openConnections(tester);
      await emit(tester, 'connections', [_connection(1, 'first.example')]);
      await tester.pumpAndSettle();
      expect(text('first.example'), findsOneWidget);

      final page = tester.element(find.byType(ConnectionsPage, skipOffstage: false));
      await cover(tester, page);
      expect(isRouteMoving(page), isTrue, reason: 'the cover route must still be moving');
      await emit(tester, 'connections', [_connection(2, 'second.example')]);
      expect(text('first.example'), findsOneWidget);
      expect(text('second.example'), findsNothing, reason: 'a sample under a moving route is not painted');

      await tester.pumpAndSettle();
      expect(text('first.example'), findsNothing);
      expect(text('second.example'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only the newest of two held samples is replayed', (tester) async {
      await mountApp(tester, 'test.route-hold.connections.latest');
      await openConnections(tester);
      await emit(tester, 'connections', [_connection(1, 'first.example')]);
      await tester.pumpAndSettle();

      final page = tester.element(find.byType(ConnectionsPage, skipOffstage: false));
      await cover(tester, page);
      await emit(tester, 'connections', [_connection(2, 'second.example')]);
      await emit(tester, 'connections', [_connection(3, 'third.example')]);
      expect(isRouteMoving(page), isTrue);
      expect(text('first.example'), findsOneWidget);
      expect(text('second.example'), findsNothing);
      expect(text('third.example'), findsNothing);

      await tester.pumpAndSettle();
      expect(text('third.example'), findsOneWidget);
      expect(text('second.example'), findsNothing, reason: 'the newest held sample is the one applied');
      expect(tester.takeException(), isNull);
    });

    testWidgets('first rows already in the controller are painted while the page arrives', (tester) async {
      await mountApp(tester, 'test.route-hold.connections.first');
      await emit(tester, 'connections', [_connection(1, 'first.example')]);
      Navigator.of(tester.element(find.byType(HomePage))).push(SlowCardRoute<void>(
        builder: (_) => const SheetProvider(type: SheetType.page, child: ConnectionsPage()),
      ));
      await tester.pump();

      final page = tester.element(find.byType(ConnectionsPage, skipOffstage: false));
      expect(isRouteMoving(page), isTrue, reason: 'the page is still arriving');
      expect(text('first.example'), findsOneWidget, reason: 'first content is shown, not held');

      await tester.pumpAndSettle();
      expect(text('first.example'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('search applies at once while a sample is held behind a moving route', (tester) async {
      await mountApp(tester, 'test.route-hold.connections.reader');
      await openConnections(tester);
      await emit(tester, 'connections', [
        _connection(1, 'first.example'),
        _connection(2, 'second.example'),
      ]);
      await tester.pumpAndSettle();

      final page = tester.element(find.byType(ConnectionsPage, skipOffstage: false));
      await cover(tester, page);
      await emit(tester, 'connections', [_connection(3, 'third.example')]);
      expect(isRouteMoving(page), isTrue);

      scaffoldOf(tester, ConnectionsPage).searchState!.onSearch('first');
      await tester.pump();
      expect(text('first.example'), findsOneWidget);
      expect(text('second.example'), findsNothing);
      expect(isRouteMoving(page), isTrue, reason: 'the reader action did not wait for the route');

      await tester.pumpAndSettle();
      expect(text('first.example'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
