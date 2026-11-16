import 'dart:async';
import 'package:flrone/components/record.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/logcat.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

final _records = <Json>[
  {'id': 1, 'level': 'debug', 'message': 'VelocityTracker: LSQ2 speed rezero info'},
  {'id': 2, 'level': 'info', 'message': 'OplusScrollToTopManager: DecorView info dump'},
  {'id': 3, 'level': 'warn', 'message': 'BboxLogcat: read failed'},
  {'id': 4, 'level': 'error', 'message': 'BboxFlutterActivity: no such method'},
];

void main() {
  late StreamController<dynamic> events;
  late BoxController box;
  final calls = <MethodCall>[];
  Object? readyPreferences;

  Future<void> mount(WidgetTester tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('test.logcat');
    events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    calls.clear();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'preferences': ?readyPreferences,
        };
      }
      if (call.method == 'preferences.set') {
        return ((call.arguments as Map)['value'] as Map).cast<String, Object?>();
      }
      return null;
    });
    box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
    openPage(tester.element(find.byType(HomePage)), const LogcatPage());
    await tester.pumpAndSettle();
  }

  Scaffold scaffold(WidgetTester tester) => tester.widget<Scaffold>(
    find.descendant(of: find.byType(LogcatPage), matching: find.byType(Scaffold)).first,
  );

  List<String?> bodies(WidgetTester tester) =>
      tester.widgetList<SelectableText>(find.byType(SelectableText)).map((text) => text.data).toList();

  Future<void> emit(WidgetTester tester, [List<Json>? records]) async {
    events.add({
      'type': 'logcat',
      'value': {'entries': records ?? _records, 'reset': true},
    });
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }

  /// Every `logs.logcat.visible` the page negotiated, oldest first.
  List<Map<Object?, Object?>> negotiated() => [
    for (final call in calls)
      if (call.method == 'logs.logcat.visible') (call.arguments as Map).cast<Object?, Object?>(),
  ];

  testWidgets('the tail renders each line with its level', (tester) async {
    await mount(tester);
    await emit(tester);
    expect(bodies(tester), unorderedEquals(_records.map((record) => record['message'])));
    final tones = {for (final label in tester.widgetList<RecordLabel>(find.byType(RecordLabel))) label.label: label.tone};
    expect(tones, {'debug': RecordTone.neutral, 'info': RecordTone.neutral, 'warn': RecordTone.warning, 'error': RecordTone.error});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a level label raises the floor and the host records at it', (tester) async {
    await mount(tester);
    await emit(tester);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value.map((keyword) => keyword.label), ['≥ warn']);
    expect(bodies(tester), ['BboxLogcat: read failed', 'BboxFlutterActivity: no such method']);
    // The host filters at the source: raising the floor restarts the tail at the new level.
    expect(negotiated().last, {'visible': true, 'level': 'warn'});
    final write = calls.lastWhere((call) => call.method == 'preferences.set');
    expect((((write.arguments as Map)['value']) as Map)['logcatLevel'], 'warn');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the stored level is what the first subscription records at', (tester) async {
    readyPreferences = {'logcatLevel': 'error'};
    addTearDown(() => readyPreferences = null);
    await mount(tester);
    expect(negotiated().first, {'visible': true, 'level': 'error'});
    await emit(tester);
    // The line below the floor never reaches the screen, and the chip says why.
    expect(bodies(tester), ['BboxFlutterActivity: no such method']);
    expect(scaffold(tester).keywords!.value.map((keyword) => keyword.label), ['≥ error']);
    expect(tester.takeException(), isNull);
  });
}
