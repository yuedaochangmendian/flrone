import 'dart:async';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/memory_panel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The numbers `Debug.MemoryInfo` reports for a 283.3 MB process: 13.7 MB of ART heap, 100 MB of
/// native allocations (the Go runtime lives there) and the rest. The four add up, because the
/// platform produced all of them.
const _rss = 297061581;
const _app = 14365491;
const _core = 104857600;
const _other = _rss - _app - _core;

void main() {
  Future<StreamController<dynamic>> mount(WidgetTester tester) async {
    const channel = MethodChannel('test.memory');
    final events = StreamController<dynamic>.broadcast();
    addTearDown(events.close);
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en', 'hiddenCards': <String>[]},
          'dashboard': {'status': 'Started'},
        };
      }
      // Like the host: a write answers with the whole merged document, so the
      // startup marker write does not drop the card preferences.
      if (call.method == 'preferences.set') {
        return <String, dynamic>{
          'locale': 'en', 'hiddenCards': <String>[],
          ...json((call.arguments as Map)['value']),
        };
      }
      return null;
    });
    await tester.pumpWidget(BoxApp(controller: BoxController(channel: channel, events: events.stream)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    return events;
  }

  Future<void> push(WidgetTester tester, StreamController<dynamic> events, {int other = _other}) async {
    events.add({'type': 'memory', 'value': {
      'total': 256 * 1024 * 1024, 'rss': _rss, 'app': _app, 'core': _core, 'other': other,
      'running': true, 'remote': false, 'heapInuse': _app, 'heapIdle': 8700000,
    }});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('the card splits the process into the app and the core', (tester) async {
    final events = await mount(tester);
    await push(tester, events);
    expect(find.byType(MemorySummary), findsOneWidget);
    expect(find.text('283.3 MB'), findsOneWidget); // the process total
    expect(find.text('183.3 MB'), findsOneWidget); // the app: everything outside the core
    expect(find.text('100.0 MB'), findsOneWidget); // the core's native allocations
    // The raw allocator remainder is a details-row figure, not a card segment.
    expect(find.text('169.6 MB'), findsNothing);

    await tester.ensureVisible(find.byType(MemoryPanel));
    await tester.pump();
    await tester.tap(find.text('283.3 MB'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(MemoryDetails), findsOneWidget);
    Finder inDetails(String text) => find.descendant(of: find.byType(MemoryDetails), matching: find.text(text));
    expect(inDetails('283.3 MB'), findsWidgets);
    expect(inDetails('100.0 MB'), findsWidgets);
    // The details page keeps the raw "other" figure as a row.
    expect(inDetails('169.6 MB'), findsWidgets);
  });

  testWidgets('a split with no remainder has no zero to print', (tester) async {
    final events = await mount(tester);
    // Nothing outside the two allocators: no "Other" segment to draw, and no zero to print.
    await push(tester, events, other: 0);
    expect(find.text('283.3 MB'), findsOneWidget);
    expect(find.text('183.3 MB'), findsOneWidget);
    expect(find.text('0 B'), findsNothing);
  });
}
