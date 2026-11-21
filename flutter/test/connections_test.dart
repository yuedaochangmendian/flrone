import 'dart:async';
import 'package:flrone/components/record.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/pages/connections.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
