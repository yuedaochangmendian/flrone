import 'dart:async';
import 'dart:math' as math;
import 'package:flrone/components/record.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/logs.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

/// Two tails with interleaved timestamps, so every assertion is also an ordering check.
final _kernel = <Json>[
  {'id': 1, 'level': 'info', 'message': 'INFO[0001] inbound connection from 10.0.0.2', 'receivedAt': 1000},
  {'id': 2, 'level': 'warn', 'message': 'WARN[0002] lookup failed for example.com', 'receivedAt': 3000},
];
final _logcat = <Json>[
  // The reported bug: a debug line whose text mentions "info" must not survive an `info` floor.
  {'id': 1, 'level': 'debug', 'message': 'VelocityTracker: speed rezero info dump', 'receivedAt': 2000},
  {'id': 2, 'level': 'error', 'message': 'BboxFlutterActivity: no such method', 'receivedAt': 4000},
];

void main() {
  late StreamController<dynamic> events;
  late BoxController box;
  String? exported;
  final calls = <MethodCall>[];
  final messages = <String>[];
  Object? saveResult = true;
  Completer<Object?>? pendingSave;
  Object? readyPreferences;

  Future<void> mount(WidgetTester tester) async {
    tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
    addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(360, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const channel = MethodChannel('test.logs');
    events = StreamController<dynamic>.broadcast();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    calls.clear(); messages.clear(); saveResult = true; pendingSave = null; exported = null;
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
        // The host answers with the merged document; the page only needs the write recorded.
        return ((call.arguments as Map)['value'] as Map).cast<String, Object?>();
      }
      if (call.method == 'document.save') {
        exported = json(call.arguments)['content'] as String;
        if (saveResult is PlatformException) throw saveResult!;
        return pendingSave == null ? saveResult : await pendingSave!.future;
      }
      return null;
    });
    box = BoxController(channel: channel, events: events.stream);
    final messageSubscription = box.messages.listen(messages.add);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await messageSubscription.cancel();
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
    openPage(tester.element(find.byType(HomePage)), const LogsPage());
    await tester.pumpAndSettle();
  }

  Scaffold scaffold(WidgetTester tester) => tester.widget<Scaffold>(
    find.descendant(of: find.byType(LogsPage), matching: find.byType(Scaffold)).first,
  );

  // The toolbar folds whatever does not fit into its overflow menu, so the action is found by
  // label rather than by position.
  IconButtonData action(WidgetTester tester, String tooltip) =>
      scaffold(tester).iconActions.firstWhere((item) => item.tooltip == tooltip);

  /// The message bodies as rendered, in list order (oldest first: the list is reversed).
  List<String?> bodies(WidgetTester tester) =>
      tester.widgetList<SelectableText>(find.byType(SelectableText)).map((text) => text.data).toList();

  Future<void> emit(WidgetTester tester, {List<Json>? kernel, List<Json>? logcat}) async {
    if (kernel != null) events.add({'type': 'logs', 'value': {'entries': kernel}});
    if (logcat != null) events.add({'type': 'logcat', 'value': {'entries': logcat, 'reset': true}});
    // List events coalesce their notifications over a short window, so the clock has
    // to pass it before the list rebuilds.
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('log-source')),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  /// Every `logs.logcat.visible` the page negotiated, oldest first.
  List<Map<Object?, Object?>> negotiated() => [
    for (final call in calls)
      if (call.method == 'logs.logcat.visible') (call.arguments as Map).cast<Object?, Object?>(),
  ];

  testWidgets('an empty screen offers neither export nor clear', (tester) async {
    await mount(tester);
    expect(find.text('No logs'), findsOneWidget);
    expect(action(tester, 'Export').onPressed, isNull);
    expect(action(tester, 'Clear Android log').onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one list merges both tails in time order, each row tagged', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    expect(bodies(tester), [
      'inbound connection from 10.0.0.2', // kernel, 1000
      'VelocityTracker: speed rezero info dump', // logcat, 2000
      'lookup failed for example.com', // kernel, 3000
      'BboxFlutterActivity: no such method', // logcat, 4000
    ]);
    // The source tag is the row-level answer to "which log am I reading".
    expect(find.widgetWithText(RecordLabel, 'Kernel'), findsNWidgets(2));
    expect(find.widgetWithText(RecordLabel, 'Android'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the switch isolates one tail and drops the source tags', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    await select(tester, 'Android');
    expect(bodies(tester), [
      'VelocityTracker: speed rezero info dump',
      'BboxFlutterActivity: no such method',
    ]);
    expect(find.widgetWithText(RecordLabel, 'Android'), findsNothing);
    await select(tester, 'Kernel');
    expect(bodies(tester), ['inbound connection from 10.0.0.2', 'lookup failed for example.com']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a level label is a floor over both sources', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value.map((keyword) => keyword.label), ['≥ warn']);
    expect(bodies(tester), [
      'lookup failed for example.com', // kernel warn, 3000
      'BboxFlutterActivity: no such method', // logcat error, 4000
    ]);
    // Tapping the level the floor already sits at stops filtering.
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value, isEmpty);
    expect(bodies(tester), hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a level floor is not a text match on the message', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'info')).onPressed!();
    await tester.pumpAndSettle();
    // The debug line mentions "info"; before the floor it survived an `info` filter.
    expect(bodies(tester), [
      'inbound connection from 10.0.0.2',
      'lookup failed for example.com',
      'BboxFlutterActivity: no such method',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a filtered list starts at the top of its slot', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    // The chip strip already holds the app bar's place; the list used to keep the bar's
    // height as its top padding as well, leaving a blank band above a short result.
    final list = tester.getRect(find.byType(SuperListView));
    final items = find.byType(RecordListItem);
    final top = [
      for (var index = 0; index < items.evaluate().length; index++) tester.getRect(items.at(index)).top,
    ].reduce(math.min);
    expect(top - list.top, lessThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the level action picks a floor and the host records logcat at it', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    IconButtonData levelAction() => action(tester, 'Minimum level');
    expect(levelAction().isSelected, isFalse);
    levelAction().onPressed!();
    await tester.pumpAndSettle();
    // The record's own row is a ListItem too; the sheet's row is the later one.
    await tester.tap(find.widgetWithText(ListItem, 'error').last);
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value.map((keyword) => keyword.label), ['≥ error']);
    expect(bodies(tester), ['BboxFlutterActivity: no such method']);
    expect(levelAction().isSelected, isTrue);
    // The host filters at the source: raising the floor restarts the tail at the new level.
    expect(negotiated().last, {'visible': true, 'level': 'error'});
    final write = calls.lastWhere((call) => call.method == 'preferences.set');
    expect((((write.arguments as Map)['value']) as Map)['logcatLevel'], 'error');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the stored floor applies on open, including the old kernel key', (tester) async {
    readyPreferences = {'logsLevel': 'warn'};
    addTearDown(() => readyPreferences = null);
    await mount(tester);
    expect(negotiated().first, {'visible': true, 'level': 'warn'});
    await emit(tester, kernel: _kernel, logcat: _logcat);
    expect(bodies(tester), ['lookup failed for example.com', 'BboxFlutterActivity: no such method']);
    expect(scaffold(tester).keywords!.value.map((keyword) => keyword.label), ['≥ warn']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear only ever clears the Android ring', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    await select(tester, 'Kernel');
    // The kernel's file is the diagnostics export's source; the screen never truncates it.
    expect(action(tester, 'Clear Android log').onPressed, isNull);
    await select(tester, 'All');
    action(tester, 'Clear Android log').onPressed!();
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'logs.logcat.clear'), hasLength(1));
    expect(calls.where((call) => call.method == 'logs.clear'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('export names the tail each line came from', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    action(tester, 'Export').onPressed!();
    await tester.pumpAndSettle();
    final lines = exported!.split('\n').where((line) => line.isNotEmpty).toList();
    expect(lines, hasLength(4));
    expect(lines[0], contains('[kernel] [info] INFO[0001] inbound connection'));
    expect(lines[1], contains('[android] [debug] VelocityTracker'));
    expect(lines[3], contains('[android] [error] BboxFlutterActivity'));
    expect(messages, ['Exported']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('export reports success and failure, and stays quiet on cancel', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    for (final result in [true, false]) {
      messages.clear();
      saveResult = result;
      action(tester, 'Export').onPressed!();
      await tester.pumpAndSettle();
      expect(messages, [result ? 'Exported' : 'Export failed']);
    }
    messages.clear();
    saveResult = null;
    action(tester, 'Export').onPressed!();
    await tester.pumpAndSettle();
    expect(messages, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('export prevents reentry and reports platform errors without losing records', (tester) async {
    await mount(tester);
    pendingSave = Completer<Object?>();
    await emit(tester, kernel: _kernel, logcat: _logcat);
    final export = action(tester, 'Export').onPressed!;
    export(); export();
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'document.save'), hasLength(1));
    expect(action(tester, 'Export').onPressed, isNull);
    pendingSave!.complete(null);
    await tester.pumpAndSettle();
    expect(messages, isEmpty);
    expect(action(tester, 'Export').onPressed, isNotNull);
    pendingSave = null;
    saveResult = PlatformException(code: 'failed', message: 'Cannot write document');
    action(tester, 'Export').onPressed!();
    await tester.pumpAndSettle();
    expect(messages, ['Cannot write document']);
    expect(bodies(tester), hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a burst of log events shares one rebuild', (tester) async {
    await mount(tester);
    var notified = 0;
    box.addListener(() => notified++);
    Json line(int id) => {'id': id, 'level': 'info', 'message': 'INFO[0001] core: line $id'};
    events.add({'type': 'logs', 'value': {'reset': false, 'firstId': 1, 'entries': [line(1)]}});
    events.add({'type': 'logs', 'value': {'reset': false, 'firstId': 1, 'entries': [line(2)]}});
    await tester.pumpAndSettle();
    expect(box.logs.map((entry) => entry['id']), [1, 2]);
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(notified, 1);
    expect(bodies(tester), unorderedEquals(['line 1', 'line 2']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('each tail keeps a fixed window however long it runs', (tester) async {
    await mount(tester);
    final many = [
      for (var id = 1; id <= BoxController.maxLogLength + 88; id++)
        {'id': id, 'level': 'info', 'message': 'INFO[0000] core: line $id'},
    ];
    events.add({'type': 'logs', 'value': {'entries': many}});
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    expect(box.logs, hasLength(BoxController.maxLogLength));
    // The oldest fell off the front; the newest is still the last line shown.
    expect(box.logs.first['id'], 89);
    expect(box.logs.last['id'], many.length);
    expect(tester.takeException(), isNull);
  });
}
