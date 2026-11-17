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

/// `core.log.prev`: a different file, fetched on demand, never merged into 全部.
final _previous = <Json>[
  {'id': 900, 'level': 'warn', 'message': 'WARN[0001] previous session warning', 'receivedAt': 500},
  {'id': 901, 'level': 'error', 'message': 'ERROR[0002] previous session failure', 'receivedAt': 600},
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
  Object? readySettings;

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
        final settings = <String, Object?>{'logLevel': 'info'};
        if (readySettings is Map) settings.addAll((readySettings as Map).cast<String, Object?>());
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'preferences': ?readyPreferences,
          'settings': settings,
        };
      }
      if (call.method == 'settings.set') {
        // The host answers with the whole settings document.
        final arguments = call.arguments as Map;
        return {'logLevel': arguments['value']};
      }
      if (call.method == 'preferences.set') {
        // The host answers with the merged document; the page only needs the write recorded.
        return ((call.arguments as Map)['value'] as Map).cast<String, Object?>();
      }
      if (call.method == 'logs.previous') {
        return {'entries': _previous, 'reset': true};
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

  testWidgets('a level label sets the recording level and leaves the rows alone', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    // The rows already recorded stay: the level decides what is written from now on.
    expect(bodies(tester), hasLength(4));
    expect(scaffold(tester).keywords!.value, isEmpty);
    final write = calls.lastWhere((call) => call.method == 'settings.set');
    expect((write.arguments as Map)['key'], 'logLevel');
    expect((write.arguments as Map)['value'], 'warn');
    expect(negotiated().last, {'visible': true, 'level': 'warn'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('a level label is not a keyword filter', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'info')).onPressed!();
    await tester.pumpAndSettle();
    // The reported bug was the badge turning its own text into search text; it must not.
    expect(scaffold(tester).keywords!.value.where((keyword) => keyword.onDeleted != null), isEmpty);
    expect(bodies(tester), hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows start at the top of the list slot', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    // The chip strip already holds the app bar's place; the list must not add that height
    // again as padding (it used to leave a blank band above a short result).
    final list = tester.getRect(find.byType(SuperListView));
    final items = find.byType(RecordListItem);
    final top = [
      for (var index = 0; index < items.evaluate().length; index++) tester.getRect(items.at(index)).top,
    ].reduce(math.min);
    expect(top - list.top, lessThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the level action picks the recording level for both tails', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    action(tester, 'Recording level').onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Changing it restarts the service to apply the core setting'), findsOneWidget);
    // The sheet offers the core's whole scale, panic included.
    expect(find.widgetWithText(ListItem, 'panic'), findsOneWidget);
    // The record's own row is a ListItem too; the sheet's row is the later one.
    await tester.tap(find.widgetWithText(ListItem, 'error').last);
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value, isEmpty);
    expect(bodies(tester), hasLength(4));
    final write = calls.lastWhere((call) => call.method == 'settings.set');
    expect((write.arguments as Map)['value'], 'error');
    expect(negotiated().last, {'visible': true, 'level': 'error'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('the stored setting applies on open and syncs the ring', (tester) async {
    readySettings = {'logLevel': 'warn'};
    addTearDown(() => readySettings = null);
    await mount(tester);
    // The ring follows the kernel setting instead of keeping a separate level.
    expect(negotiated().first, {'visible': true, 'level': 'warn'});
    await emit(tester, kernel: _kernel, logcat: _logcat);
    expect(bodies(tester), hasLength(4));
    expect(scaffold(tester).keywords!.value, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the previous session is read once', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    await select(tester, 'Previous session');
    // The archive is fetched on demand, not with the live subscriptions.
    expect(calls.where((call) => call.method == 'logs.previous'), hasLength(1));
    expect(bodies(tester), ['previous session warning', 'previous session failure']);
    // Switching away and back does not re-parse the file.
    await select(tester, 'Kernel');
    await select(tester, 'Previous session');
    expect(calls.where((call) => call.method == 'logs.previous'), hasLength(1));
    expect(bodies(tester), hasLength(2));
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
