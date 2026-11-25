import 'dart:async';
import 'dart:math' as math;
import 'package:flrone/components/record.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/logs.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Two tails with interleaved timestamps, so every assertion is also an ordering check.
/// The screen shows each line as it was written: the core's own level prefix is part of
/// the text now that a row has no badge to repeat it.
final _kernel = <Json>[
  {'id': 1, 'level': 'info', 'message': 'INFO[0001] inbound connection from 10.0.0.2', 'receivedAt': 1000},
  {'id': 2, 'level': 'warn', 'message': 'WARN[0002] lookup failed for example.com', 'receivedAt': 3000},
];
final _logcat = <Json>[
  {'id': 1, 'level': 'debug', 'message': 'VelocityTracker: speed rezero info dump', 'receivedAt': 2000},
  {'id': 2, 'level': 'error', 'message': 'FlroneActivity: no such method', 'receivedAt': 4000},
];

void main() {
  late StreamController<dynamic> events;
  late BoxController box;
  String? exported;
  final calls = <MethodCall>[];
  final messages = <String>[];
  Object? saveResult = true;
  Object? clearThrow;
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
      if (call.method == 'document.save') {
        exported = json(call.arguments)['content'] as String;
        if (saveResult is PlatformException) throw saveResult!;
        return pendingSave == null ? saveResult : await pendingSave!.future;
      }
      if (call.method == 'logs.clear' || call.method == 'logs.logcat.clear') {
        if (clearThrow != null) throw clearThrow!;
        return true;
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

  /// Every `logs.logcat.visible` the page negotiated, oldest first.
  List<Map<Object?, Object?>> negotiated() => [
    for (final call in calls)
      if (call.method == 'logs.logcat.visible') (call.arguments as Map).cast<Object?, Object?>(),
  ];

  testWidgets('an empty screen offers neither export nor clear', (tester) async {
    await mount(tester);
    expect(find.text('No logs'), findsOneWidget);
    expect(action(tester, 'Export').onPressed, isNull);
    expect(action(tester, 'Clear all logs').onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('one list merges both tails in time order and tags each level', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    // Every line as written, oldest first; nothing is re-shaped for the screen.
    expect(bodies(tester), [
      'INFO[0001] inbound connection from 10.0.0.2',
      'VelocityTracker: speed rezero info dump',
      'WARN[0002] lookup failed for example.com',
      'FlroneActivity: no such method',
    ]);
    // The level is a tag again, so a scanning reader can spot error/trace rows.
    expect(find.byType(RecordLabel), findsNWidgets(4));
    for (final level in ['info', 'debug', 'warn', 'error']) {
      expect(find.text(level), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('log-source')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search keeps the raw text of either tail', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    scaffold(tester).searchState!.onSearch('example');
    await tester.pumpAndSettle();
    expect(bodies(tester), ['WARN[0002] lookup failed for example.com']);
    scaffold(tester).searchState!.onSearch('flroneactivity');
    await tester.pumpAndSettle();
    expect(bodies(tester), ['FlroneActivity: no such method']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('rows start below the floating bar without a blank band', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    // The keyword strip is a horizontal ListView too; the log rows live in the vertical one.
    final rows = find.byWidgetPredicate(
        (widget) => widget is ListView && widget.scrollDirection == Axis.vertical);
    final list = tester.getRect(rows);
    final page = tester.getRect(find.byType(Scaffold).first);
    final topInset = tester.element(rows).contentTopPadding;
    // The list viewport starts below the floating bar, not under it.
    expect(topInset, greaterThan(0));
    expect(list.top, greaterThanOrEqualTo(page.top + topInset - 0.5));
    final items = find.byType(RecordListItem);
    final top = [
      for (var index = 0; index < items.evaluate().length; index++) tester.getRect(items.at(index)).top,
    ].reduce(math.min);
    // No second gap between the list viewport and its first row.
    expect(top - list.top, lessThan(0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('closing lifecycle logs keeps the rest of the app tail', (tester) async {
    await mount(tester);
    const lifecycle = '[lifecycle] ui frame gap ~200ms';
    await emit(tester, kernel: _kernel, logcat: [
      ..._logcat,
      {'id': 9, 'level': 'info', 'message': lifecycle, 'receivedAt': 2500},
    ]);
    expect(bodies(tester), contains(lifecycle));

    action(tester, 'Close lifecycle logs').onPressed!();
    await tester.pumpAndSettle();
    expect(bodies(tester), isNot(contains(lifecycle)),
        reason: 'the lifecycle diagnostic is filtered out');
    expect(bodies(tester), contains('FlroneActivity: no such method'),
        reason: 'the rest of the app/UI tail keeps running');
    expect(bodies(tester), contains('INFO[0001] inbound connection from 10.0.0.2'),
        reason: 'the kernel tail is untouched');

    action(tester, 'Show lifecycle logs').onPressed!();
    await tester.pumpAndSettle();
    expect(bodies(tester), contains(lifecycle));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long tail is lazy instead of shrink-wrapped', (tester) async {
    await mount(tester);
    final many = <Json>[
      for (var index = 0; index < 60; index++)
        {'id': index, 'level': 'info', 'message': 'line $index', 'receivedAt': 1000 + index},
    ];
    await emit(tester, logcat: many);
    final list = tester.widget<ListView>(find.byWidgetPredicate(
        (widget) => widget is ListView && widget.scrollDirection == Axis.vertical));
    expect(list.shrinkWrap, isFalse,
        reason: 'past the threshold the list must lay out only visible rows');
    expect(find.byType(RecordListItem).evaluate().length, lessThan(60),
        reason: 'a shrink-wrapped list would have built every row');
    expect(tester.takeException(), isNull);
  });

  testWidgets('the level action picks the recording level for both tails', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    action(tester, 'Recording level').onPressed!();
    await tester.pumpAndSettle();
    expect(find.text('Changing it restarts the service to apply the core setting'), findsOneWidget);
    // The sheet offers the core's whole scale plus the client-side silent level.
    expect(find.widgetWithText(ListItem, 'panic'), findsOneWidget);
    expect(find.widgetWithText(ListItem, 'silent'), findsOneWidget);
    // The record's own row is a ListItem too; the sheet's row is the later one.
    await tester.tap(find.widgetWithText(ListItem, 'error').last);
    await tester.pumpAndSettle();
    expect(bodies(tester), hasLength(4));
    final write = calls.lastWhere((call) => call.method == 'settings.set');
    expect((write.arguments as Map)['value'], 'error');
    expect(negotiated().last, {'visible': true, 'level': 'error'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('silent writes the core\'s quietest level and tails logcat at S', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    action(tester, 'Recording level').onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ListItem, 'silent').last);
    await tester.pumpAndSettle();
    // The core has no `silent`, so the setting carries its quietest accepted value...
    final write = calls.lastWhere((call) => call.method == 'settings.set');
    expect((write.arguments as Map)['value'], 'panic');
    // ...while logcat and this process's own kernel filter record nothing at all.
    final level = calls.lastWhere((call) => call.method == 'preferences.set');
    expect((level.arguments as Map)['value'], {'logcatLevel': 'silent'});
    expect(negotiated().last, {'visible': true, 'level': 'silent'});
    expect(tester.takeException(), isNull);
  });

  testWidgets('the stored recording level applies on open and syncs the ring', (tester) async {
    readySettings = {'logLevel': 'warn'};
    addTearDown(() => readySettings = null);
    await mount(tester);
    // The ring follows the kernel setting instead of keeping a separate level.
    expect(negotiated().first, {'visible': true, 'level': 'warn'});
    await emit(tester, kernel: _kernel, logcat: _logcat);
    expect(bodies(tester), hasLength(4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stored silent level survives a restart without rewriting the setting', (tester) async {
    readyPreferences = {'logcatLevel': 'silent'};
    addTearDown(() => readyPreferences = null);
    await mount(tester);
    // The host setting says `panic` (what silent is written as); the recording level does not.
    expect(negotiated().first, {'visible': true, 'level': 'silent'});
    expect(calls.where((call) => call.method == 'settings.set'), isEmpty);
    action(tester, 'Recording level').onPressed!();
    await tester.pumpAndSettle();
    // Re-picking the same level is a no-op: no setting write, no restart.
    await tester.tap(find.widgetWithText(ListItem, 'silent').last);
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'settings.set'), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear empties both tails after confirmation', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel);
    // The kernel tail alone is enough to offer the clear action now.
    expect(action(tester, 'Clear all logs').onPressed, isNotNull);
    await emit(tester, logcat: _logcat);
    action(tester, 'Clear all logs').onPressed!();
    await tester.pumpAndSettle();
    // Irreversible: nothing is cleared until the confirmation is accepted.
    expect(calls.where((call) => call.method == 'logs.clear'), isEmpty);
    expect(calls.where((call) => call.method == 'logs.logcat.clear'), isEmpty);
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'logs.clear'), hasLength(1));
    expect(calls.where((call) => call.method == 'logs.logcat.clear'), hasLength(1));
    // Both tails report empty afterwards; the screen must dispose the reversed list
    // without a null-check crash and offer the empty state again.
    await emit(tester, kernel: const [], logcat: const []);
    expect(find.text('No logs'), findsOneWidget);
    expect(action(tester, 'Clear all logs').onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear reports a host refusal and keeps the rows on screen', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel);
    clearThrow = PlatformException(code: 'busy', message: 'Core busy');
    addTearDown(() => clearThrow = null);
    action(tester, 'Clear all logs').onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pump(const Duration(milliseconds: 50));
    // The failure is reported to the host (the app's own error surface) and
    // the rows stay on screen rather than being silently discarded.
    expect(messages, contains('Core busy'));
    expect(bodies(tester), isNotEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('clear drops this process\'s FFI kernel rows too', (tester) async {
    await mount(tester);
    await emit(tester, kernel: [
      {'id': 0x10000002, 'level': 'error', 'message': 'ERROR[0002] kernel row', 'receivedAt': 2000},
    ]);
    expect(box.logs, isNotEmpty);
    action(tester, 'Clear all logs').onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();
    // The channel reset keeps high-id kernel rows by design; the clear operation must
    // remove them itself or the kernel tail would survive "Clear all logs".
    expect(box.logs.where((entry) => (entry['id'] as num? ?? 0) >= 0x10000000), isEmpty);
    expect(find.text('No logs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long tail can be cleared without a list crash', (tester) async {
    await mount(tester);
    final many = [
      for (var id = 1; id <= 400; id++)
        {'id': id, 'level': id % 7 == 0 ? 'error' : 'info', 'message': 'INFO[0000] core: line $id', 'receivedAt': 1000 + id},
    ];
    final manyCat = [
      for (var id = 1; id <= 400; id++)
        {'id': id, 'level': id % 5 == 0 ? 'warn' : 'debug', 'message': 'Flrone: line $id', 'receivedAt': 1000 + id},
    ];
    await emit(tester, kernel: many, logcat: manyCat);
    expect(bodies(tester), isNotEmpty);
    action(tester, 'Clear all logs').onPressed!();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Clear'));
    await tester.pumpAndSettle();
    await emit(tester, kernel: const [], logcat: const []);
    expect(find.text('No logs'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the newest line is visible when the list opens at the end', (tester) async {
    await mount(tester);
    final many = [
      for (var id = 1; id <= 120; id++)
        {'id': id, 'level': 'info', 'message': 'INFO[0000] core: line $id', 'receivedAt': 1000 + id},
    ];
    await emit(tester, kernel: many);
    expect(find.text('INFO[0000] core: line 120'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping and dragging a row does not throw', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    final body = find.byType(SelectableText).first;
    await tester.tap(body);
    await tester.pumpAndSettle();
    await tester.drag(
      find.byWidgetPredicate(
          (widget) => widget is ListView && widget.scrollDirection == Axis.vertical),
      const Offset(0, 120),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('export writes the merged stream, one line per row', (tester) async {
    await mount(tester);
    await emit(tester, kernel: _kernel, logcat: _logcat);
    action(tester, 'Export').onPressed!();
    await tester.pumpAndSettle();
    final lines = exported!.split('\n').where((line) => line.isNotEmpty).toList();
    expect(lines, hasLength(4));
    expect(lines[0], matches(RegExp(r'^\d{2}:\d{2}:\d{2}\.\d{3} INFO\[0001\] inbound connection')));
    expect(lines[1], contains('VelocityTracker'));
    expect(lines[3], contains('FlroneActivity'));
    // The tail is no longer named: the merged stream is what the screen showed.
    expect(exported, isNot(contains('[kernel]')));
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
    expect(bodies(tester), unorderedEquals(['INFO[0001] core: line 1', 'INFO[0001] core: line 2']));
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
