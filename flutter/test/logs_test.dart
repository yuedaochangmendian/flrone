import 'dart:async';
import 'dart:math' as math;
import 'package:flrone/components/record.dart';
import 'package:flrone/main.dart';
import 'package:flrone/pages/logs.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

final _records = <Json>[
  {'id': 1, 'level': 'info', 'message': 'INFO[0001] inbound/tun[tun-in]: inbound connection from 10.0.0.2:51234'},
  {'id': 2, 'level': 'warn', 'message': 'WARN[0002] dns: lookup failed for example.com'},
  {'id': 3, 'level': 'error', 'message': 'ERROR[0003] outbound/vless[proxy]: dial failed'},
];

void main() {
  late StreamController<dynamic> events;
  late BoxController box;
  String? exported;
  final calls = <MethodCall>[];
  final messages = <String>[];
  Object? saveResult = true;
  Completer<Object?>? pendingSave;

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
        return {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}};
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
  IconButtonData exportAction(WidgetTester tester) =>
      scaffold(tester).iconActions.firstWhere((item) => item.tooltip == 'Export');

  /// The message bodies as rendered: the parsed text, not the raw core line.
  List<String?> bodies(WidgetTester tester) =>
      tester.widgetList<SelectableText>(find.byType(SelectableText)).map((text) => text.data).toList();

  Future<void> emit(WidgetTester tester, [List<Json>? records]) async {
    events.add({'type': 'logs', 'value': {'entries': records ?? _records}});
    // List events coalesce their notifications over a short window, so the clock has
    // to pass it before the list rebuilds.
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
  }

  testWidgets('an empty log shows the empty state and offers no export', (tester) async {
    await mount(tester);
    expect(find.text('No logs'), findsOneWidget);
    expect(exportAction(tester).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('records show the subsystem beside the message instead of the raw line', (tester) async {
    await mount(tester);
    await emit(tester);
    expect(bodies(tester), unorderedEquals([
      'inbound connection from 10.0.0.2:51234',
      'lookup failed for example.com',
      'dial failed',
    ]));
    expect(find.text('inbound/tun  ·  tun-in'), findsOneWidget);
    expect(find.text('outbound/vless  ·  proxy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a record\'s tone follows its level', (tester) async {
    await mount(tester);
    await emit(tester);
    final tones = {for (final label in tester.widgetList<RecordLabel>(find.byType(RecordLabel))) label.label: label.tone};
    expect(tones, {'info': RecordTone.neutral, 'warn': RecordTone.warning, 'error': RecordTone.error});
  });

  testWidgets('a level label is a floor: it keeps that level and above', (tester) async {
    await mount(tester);
    await emit(tester);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value.map((keyword) => keyword.label), ['≥ warn']);
    expect(bodies(tester), ['lookup failed for example.com', 'dial failed']);
    // Tapping the level the floor already sits at stops filtering.
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value, isEmpty);
    expect(bodies(tester), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a level filter is not a text match on the message', (tester) async {
    await mount(tester);
    // The reported bug: a debug line whose message mentions "info" survived an `info`
    // filter, because the level badge added the word to the search text.
    await emit(tester, [
      {'id': 1, 'level': 'debug', 'message': 'DEBUG[0001] viewInfo=DecorView info dump'},
      {'id': 2, 'level': 'info', 'message': 'INFO[0002] inbound connection'},
      {'id': 3, 'level': 'error', 'message': 'ERROR[0003] dial failed'},
    ]);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'info')).onPressed!();
    await tester.pumpAndSettle();
    expect(bodies(tester), ['inbound connection', 'dial failed']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a filtered list starts at the top of its slot', (tester) async {
    await mount(tester);
    await emit(tester);
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

  testWidgets('the level action picks a floor, shows it and persists it', (tester) async {
    await mount(tester);
    await emit(tester);
    IconButtonData levelAction() => scaffold(tester).iconActions.firstWhere((item) => item.tooltip == 'Minimum level');
    expect(levelAction().isSelected, isFalse);
    levelAction().onPressed!();
    await tester.pumpAndSettle();
    // The record's own row is a ListItem too; the sheet's row is the later one.
    await tester.tap(find.widgetWithText(ListItem, 'error').last);
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value.map((keyword) => keyword.label), ['≥ error']);
    expect(bodies(tester), ['dial failed']);
    expect(levelAction().isSelected, isTrue);
    final write = calls.lastWhere((call) => call.method == 'preferences.set');
    expect((((write.arguments as Map)['value']) as Map)['logsLevel'], 'error');
    expect(tester.takeException(), isNull);
  });

  testWidgets('removing the filter chip brings the other levels back', (tester) async {
    await mount(tester);
    await emit(tester);
    tester.widget<RecordLabel>(find.widgetWithText(RecordLabel, 'warn')).onPressed!();
    await tester.pumpAndSettle();
    // The floor keeps warning and above, so the error record stays.
    expect(bodies(tester), ['lookup failed for example.com', 'dial failed']);
    scaffold(tester).keywords!.value.single.onDeleted!();
    await tester.pumpAndSettle();
    expect(scaffold(tester).keywords!.value, isEmpty);
    expect(bodies(tester), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  for (final result in [true, false, null]) {
    testWidgets('export reports success, failure and cancellation: $result', (tester) async {
      await mount(tester);
      await emit(tester);
      saveResult = result;
      exportAction(tester).onPressed!();
      await tester.pumpAndSettle();
      expect(exported!.split('\n').where((line) => line.isNotEmpty), [
        for (final record in _records) '— [${record['level']}] ${record['message']}',
      ]);
      expect(messages, result == null ? isEmpty : [result ? 'Exported' : 'Export failed']);
      expect(exportAction(tester).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('export prevents reentry and reports platform errors without losing records', (tester) async {
    await mount(tester);
    pendingSave = Completer<Object?>();
    await emit(tester);
    final export = exportAction(tester).onPressed!;
    export(); export();
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'document.save'), hasLength(1));
    expect(exportAction(tester).onPressed, isNull);
    pendingSave!.complete(null);
    await tester.pumpAndSettle();
    expect(messages, isEmpty);
    expect(exportAction(tester).onPressed, isNotNull);
    pendingSave = null;
    saveResult = PlatformException(code: 'failed', message: 'Cannot write document');
    exportAction(tester).onPressed!();
    await tester.pumpAndSettle();
    expect(messages, ['Cannot write document']);
    expect(box.logs, hasLength(_records.length));
    expect(exportAction(tester).onPressed, isNotNull);
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
    // The state is current as soon as the events land.
    expect(box.logs.map((entry) => entry['id']), [1, 2]);
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 50));
    await tester.pumpAndSettle();
    // Two events, one rebuild: the burst shared a single notification.
    expect(notified, 1);
    expect(bodies(tester), unorderedEquals(['line 1', 'line 2']));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the log tail keeps a fixed window however long it runs', (tester) async {
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
