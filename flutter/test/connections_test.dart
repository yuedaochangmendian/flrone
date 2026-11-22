import 'dart:async';
import 'package:flrone/components/record.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/pages/connections.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// One mounted connections page with a unique channel; records every channel call so tests can
/// assert the process lookup is per-path and cached, and can feed in `apps.process` replies.
class _Harness {
  final MethodChannel channel;
  final StreamController<dynamic> events;
  final List<MethodCall> calls = [];
  final Map<String, dynamic> processReplies = {};
  _Harness._(this.channel, this.events);

  static Future<_Harness> mount(WidgetTester tester, {String name = 'test.connections.info'}) async {
    final events = StreamController<dynamic>.broadcast();
    final channel = MethodChannel(name);
    final harness = _Harness._(channel, events);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      harness.calls.add(call);
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}};
      }
      if (call.method == 'apps.process') {
        return harness.processReplies[(call.arguments as Map)['path']];
      }
      return null;
    });
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ConnectionsPage());
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
    return harness;
  }

  Future<void> push(WidgetTester tester, List<dynamic> rows) async {
    events.add({'type': 'connections', 'value': rows});
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }
}

Json _row(Object id, {String processPath = '', String protocol = '', int closedAt = 0}) => {
  'id': id, 'createdAt': 1700000000000, 'closedAt': closedAt,
  'network': 'tcp', 'protocol': protocol,
  'destination': '1.2.3.4:443', 'displayDestination': 'example.com',
  'outbound': 'proxy', 'rule': 'geosite', 'source': '10.0.0.2:5',
  'chain': ['proxy'],
  'upload': 0, 'download': 0, 'uploadTotal': 0, 'downloadTotal': 0,
  if (processPath.isNotEmpty) 'process': {'path': processPath},
};

const _apk = '/data/app/~~AbC/com.example.app-XyZ/base.apk';

/// A real 1x1 PNG: Image.memory decodes during pump, so a truncated header throws.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c, 0x02, 0x00, 0x00, 0x00,
  0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xfc, 0xff, 0x1f, 0x00,
  0x03, 0x03, 0x02, 0x00, 0xef, 0xbf, 0x97, 0xd9, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
]);

void main() {
  testWidgets('connection subscriptions are released when their page closes', (tester) async {
    final visibility = <bool>[];
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.connections');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'connections.visible') visibility.add((call.arguments as Map)['visible'] == true);
      return call.method == 'ready' ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}} : null;
    });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(HomePage));
    openPage(context, const ConnectionsPage());
    await tester.pumpAndSettle();
    expect(visibility, [true]);
    final pageContext = tester.element(find.byType(ConnectionsPage));
    pageContext.safeNestedPop();
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.byType(ConnectionsPage), findsNothing);
    expect(visibility, [true, false]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('a keyword chip does not leave a blank band above the list', (tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.connections.band');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Started'}}
        : null);
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    openPage(tester.element(find.byType(HomePage)), const ConnectionsPage());
    await tester.pumpAndSettle();
    events.add({
      'type': 'connections',
      'value': [
        {
          'id': 1, 'createdAt': 1700000000000, 'network': 'tcp', 'destination': 'example.com:443',
          'outbound': 'proxy', 'rule': 'geosite', 'source': '10.0.0.2:5',
          'upload': 0, 'download': 0, 'uploadTotal': 0, 'downloadTotal': 0,
        },
      ],
    });
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    ListView verticalList() => tester.widgetList<ListView>(find.byType(ListView))
        .firstWhere((view) => view.scrollDirection == Axis.vertical);
    // Without a chip the body runs under the floating bar, so the list carries its height.
    expect((verticalList().padding! as EdgeInsets).top, greaterThan(0));
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'TCP')).onPressed!();
    await tester.pumpAndSettle();
    // The strip now holds the bar's place, so the list must not add that gap again.
    expect((verticalList().padding! as EdgeInsets).top, 0);
    final listRect = tester.getRect(find.byWidget(verticalList()));
    final itemRect = tester.getRect(find.byType(RecordListItem).first);
    expect(itemRect.top - listRect.top, lessThan(0.5));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('resolves the process path into an app label, icon and tap-to-filter chip', (tester) async {
    final h = await _Harness.mount(tester);
    h.processReplies[_apk] = {
      'package': 'com.example.app', 'label': 'Example App', 'icon': _png,
    };
    await h.push(tester, [_row(1, processPath: _apk, protocol: 'TLS')]);
    expect(find.text('Example App'), findsOneWidget);
    // Protocol is filterable alongside the network label.
    expect(find.widgetWithText(RecordLabel, 'TLS'), findsOneWidget);

    final lookups = h.calls.where((call) => call.method == 'apps.process').toList();
    expect(lookups.length, 1);
    expect((lookups.first.arguments as Map)['path'], _apk);
    // A rebuild must not re-ask: the Future is cached per distinct path.
    await tester.pump();
    expect(h.calls.where((call) => call.method == 'apps.process').length, 1);

    // Tapping the label adds a keyword chip keyed by the package, labelled by the app name.
    await tester.tap(find.text('Example App'));
    await tester.pumpAndSettle();
    expect(find.text('Example App'), findsWidgets); // chip label + row label
    expect(find.widgetWithText(RecordLabel, 'TLS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unresolvable process falls back to the source line', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.connections.fallback');
    await h.push(tester, [_row(2, processPath: '/data/local/tmp/tool')]);
    // The raw path is not an app name: keep the old source line instead of printing it.
    expect(find.text('/data/local/tmp/tool'), findsNothing);
    expect(find.text('10.0.0.2:5'), findsOneWidget);
    expect(h.calls.where((call) => call.method == 'apps.process').length, 1);
    // No chip is added by tapping the line (the host could not resolve a package).
    await tester.tap(find.text('10.0.0.2:5'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('Active/Closed/All menu labels carry derived counts', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.connections.counts');
    await h.push(tester, [
      _row(1), _row(2), _row(3, closedAt: 1700000001000),
    ]);
    final scaffold = tester.widget<Scaffold>(
      find.descendant(of: find.byType(ConnectionsPage), matching: find.byType(Scaffold)).first,
    );
    final labels = scaffold.menuItems.map((item) => item.label).toList();
    expect(labels, contains('Active 2'));
    expect(labels, contains('Closed 1'));
    expect(labels, contains('All 3'));
  });

  testWidgets('connection detail groups rows into Overview/Route/Process/Traffic sections', (tester) async {
    final h = await _Harness.mount(tester, name: 'test.connections.detail');
    await h.push(tester, [_row(4, processPath: _apk)]);
    await tester.tap(find.byType(RecordListItem).first);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionDetail), findsOneWidget);
    // Section headers are ListHeaders; "Process" also names a DetailRow title inside its section.
    for (final section in ['Overview', 'Route', 'Process', 'Traffic']) {
      expect(find.descendant(of: find.byType(ListHeader), matching: find.text(section)), findsOneWidget);
    }
    // The original rows are still present under their sections (DetailRow titles).
    expect(find.descendant(of: find.byType(DetailRow), matching: find.text('Destination')), findsOneWidget);
    expect(find.descendant(of: find.byType(DetailRow), matching: find.text('Upload')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
