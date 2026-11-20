// Regressions for three runtime UI issues: the start toggle losing its accent
// colour, the Proxies/Configuration screens disagreeing during a switch, and a
// configuration forgetting the node that was selected in it.

import 'dart:async';

import 'package:flrone/components/start_toggle.dart';
import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/test_app.dart';

void main() {
  Color? morphColor(WidgetTester tester) {
    for (final paint in tester.widgetList<CustomPaint>(
      find.byType(CustomPaint),
    )) {
      final painter = paint.painter;
      if (painter.runtimeType.toString().contains('MorphPainter')) {
        return (painter as dynamic).color as Color?;
      }
    }
    return null;
  }

  testWidgets('StartToggle fades to the accent when enabled flips', (
    tester,
  ) async {
    Widget toggle(bool enabled) => TestApp(
          child: Material(
            type: MaterialType.transparency,
            child: Center(
              child: StartToggle(
                size: 88,
                enabled: enabled,
                running: false,
                suspended: false,
                onTap: () {},
              ),
            ),
          ),
        );

    await tester.pumpWidget(toggle(false));
    await tester.pumpAndSettle();
    final disabledColor = morphColor(tester);
    expect(disabledColor, isNotNull);

    await tester.pumpWidget(toggle(true));
    // The flip must be a real transition: a frame mid-flight holds a colour
    // between the grey inset and the primary fill (the old keyed tween was
    // recreated at its end value and jumped straight there).
    await tester.pump(const Duration(milliseconds: 75));
    final midColor = morphColor(tester);
    await tester.pumpAndSettle();
    final enabledColor = morphColor(tester);

    expect(
      enabledColor,
      isNot(disabledColor),
      reason: 'enabling must repaint the morph with the primary fill',
    );
    expect(midColor, isNot(disabledColor));
    expect(midColor, isNot(enabledColor));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ready seeds groups so the Proxies screen opens with rows', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.ready-groups');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en'},
          'dashboard': {'status': 'Started', 'selectedProfileId': 1},
          'groups': [
            {
              'id': 1,
              'tag': 'Group A',
              'selected': 'Node A',
              'selectedId': 10,
              'selectable': true,
              'nodeCount': 1,
              'items': [
                {'id': 10, 'tag': 'Node A', 'type': 'Direct'},
              ],
            },
          ],
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    // The controller must hold the rows before any later groups event.
    expect(box.groups, hasLength(1));
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    expect(find.text('Node A'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('a stale generation does not widen to the previous groups', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.stale-groups');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': {'locale': 'en'},
            'dashboard': {'status': 'Started', 'selectedProfileId': 2},
          }
        : null);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    // The dashboard already names configuration 2, but the only group rows
    // available are still configuration 1's. Widening to them is the bug; the
    // screen must show its honest empty state instead.
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Old group',
          'selected': 'Old node',
          'selectedId': 0,
          'selectable': true,
          'nodeCount': 1,
          'items': [
            {'id': 1, 'tag': 'Old node', 'type': 'Direct'},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    expect(find.text('Old node'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('switching a configuration restores its remembered node', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.restore-node');
    final calls = <MethodCall>[];
    final preferences = <String, dynamic>{
      'locale': 'en',
      'proxySelected': {
        'local:1': {'group': 'Group A', 'id': 11, 'tag': 'Node B'},
      },
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': preferences,
          'dashboard': {'status': 'Started', 'selectedProfileId': 2},
        };
      }
      if (call.method == 'preferences.set') {
        preferences.addAll(json((call.arguments as Map)['value']));
        return preferences;
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    // A groups payload for configuration 1 whose live selection is Node A,
    // while the memory says Node B. Switching back to 1 must replay Node B.
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Group A',
          'selected': 'Node A',
          'selectedId': 10,
          'selectable': true,
          'nodeCount': 2,
          'items': [
            {'id': 10, 'tag': 'Node A', 'type': 'Direct'},
            {'id': 11, 'tag': 'Node B', 'type': 'Direct'},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    // Enter configuration 1: the restore fires once for this entry.
    events.add({
      'type': 'dashboard',
      'value': {'status': 'Started', 'selectedProfileId': 1},
    });
    await tester.pumpAndSettle();
    final selects = calls.where((call) => call.method == 'groups.select').toList();
    expect(selects, isNotEmpty, reason: 'remembered node must be replayed');
    final args = selects.last.arguments as Map;
    expect(args['group'], 'Group A');
    expect(args['tag'], 'Node B');
    expect(args['nodeId'], 11);
    // A second frame on the same configuration must not reload again.
    final before = selects.length;
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'groups.select').length,
      before,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('a remembered node no longer present is ignored', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.stale-node');
    final calls = <MethodCall>[];
    final preferences = <String, dynamic>{
      'locale': 'en',
      'proxySelected': {
        'local:1': {'group': 'Group A', 'id': 99, 'tag': 'Gone'},
      },
    };
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'ready'
          ? {
              'version': 'test',
              'coreVersion': 'test',
              'preferences': preferences,
              'dashboard': {'status': 'Started', 'selectedProfileId': 1},
            }
          : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Group A',
          'selected': 'Node A',
          'selectedId': 10,
          'selectable': true,
          'nodeCount': 1,
          'items': [
            {'id': 10, 'tag': 'Node A', 'type': 'Direct'},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'groups.select'),
      isEmpty,
      reason: 'groupSelect reports success even on a native no-op; guard first',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });
}
