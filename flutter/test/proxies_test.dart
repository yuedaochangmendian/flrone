import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/pages/proxies.dart';
import 'package:flrone/pages/test_panel.dart';
import 'package:flrone/widgets.dart';
import 'package:flrone/components/proxy_card.dart';
import 'package:flrone/components/proxy_list.dart';
import 'package:flrone/components/speed_gauge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_session_kernel.dart';

void main() {
  testWidgets(
    'the list style draws the selected configuration without its group header',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.proxy-list');
      final preferences = <String, dynamic>{
        'locale': 'en',
        'proxyLayout': 'List',
      };
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': preferences,
            'dashboard': {'status': 'Started', 'selectedProfileId': 1},
          };
        }
        if (call.method == 'preferences.set') {
          preferences.addAll(json((call.arguments as Map)['value']));
          return preferences;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      events.add({
        'type': 'groups',
        'value': [
          {
            'id': 1,
            'tag': 'Large group',
            'type': 'Selector',
            'selectable': true,
            'selected': 'Node 150',
            'selectedId': 151,
            'items': [
              for (var index = 0; index < 200; index++)
                {'id': index + 1, 'tag': 'Node $index', 'type': 'Direct'},
            ],
          },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();
      // The list style, and no group header: the group IS the configuration
      // the Profiles screen selected, so its name is not repeated on screen.
      expect(find.byType(ProxyListView), findsOneWidget);
      expect(find.text('Large group'), findsNothing);
      // Rows are built lazily: only what fits the viewport exists.
      expect(
        find.byType(ProxyNodeCard).evaluate().length,
        inInclusiveRange(1, 40),
      );
      expect(
        find.descendant(
          of: find.byType(ProxyNodeCard),
          matching: find.text('Node 150'),
        ),
        findsNothing,
      );
      // The group's test action floats over the page now that the header that
      // used to carry it is gone.
      await tester.tap(find.byTooltip('Test latency'));
      await tester.pumpAndSettle();
      expect(
        (calls.lastWhere((call) => call.method == 'groups.test').arguments
            as Map)['tag'],
        'Large group',
      );
      // Moving the configuration moves the page.
      events.add({
        'type': 'dashboard',
        'value': {'status': 'Started', 'selectedProfileId': 2},
      });
      await tester.pumpAndSettle();
      expect(find.byType(ProxyNodeCard), findsNothing);
      events.add({
        'type': 'dashboard',
        'value': {'status': 'Started', 'selectedProfileId': 1},
      });
      await tester.pumpAndSettle();
      expect(find.byType(ProxyNodeCard), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('automatic groups cannot send manual selection commands', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.automatic');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'ready'
              ? {
                  'version': 'test',
                  'coreVersion': 'test',
                  'dashboard': {'status': 'Started', 'selectedProfileId': 1},
                }
              : null;
        });
    final box = BoxController(channel: channel, events: events.stream);
    await tester.pumpWidget(BoxApp(controller: box));
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Auto',
          'selected': 'Node A',
          'selectable': false,
          'items': [
            {'tag': 'Node A', 'type': 'Shadowsocks', 'delay': 10},
            {'tag': 'Node B', 'type': 'Shadowsocks', 'delay': 20},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Node B'));
    await tester.pumpAndSettle();
    expect(calls.where((call) => call.method == 'groups.select'), isEmpty);
    expect(find.byType(ProxiesPage), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets(
    'the group action tests the selected configuration and the page follows the selection',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.group-toolbar');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'ready'
                ? {
                    'version': 'test',
                    'coreVersion': 'test',
                    'dashboard': {'status': 'Started', 'selectedProfileId': 1},
                  }
                : null;
          });
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      events.add({
        'type': 'groups',
        'value': [
          for (final (id, tag) in [(1, 'Group A'), (2, 'Group B')])
            {
              'id': id,
              'tag': tag,
              'selected': 'Node $tag',
              'selectedId': id * 10,
              'selectable': true,
              'items': [
                {'id': id * 10, 'tag': 'Node $tag', 'type': 'direct'},
              ],
            },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();
      // One screen, one configuration: only the selected profile's nodes,
      // and neither group's name is drawn.
      expect(find.text('Node Group A'), findsOneWidget);
      expect(find.text('Node Group B'), findsNothing);
      expect(find.text('Group A'), findsNothing);
      expect(find.text('Group B'), findsNothing);
      await tester.tap(find.byTooltip('Test latency'));
      await tester.pumpAndSettle();
      final first =
          calls.lastWhere((call) => call.method == 'groups.test').arguments
              as Map;
      expect(first['tag'], 'Group A');
      expect(first['profileIds'], [10]);
      // Moving the selection moves the page (and the action).
      events.add({
        'type': 'dashboard',
        'value': {'status': 'Started', 'selectedProfileId': 2},
      });
      await tester.pumpAndSettle();
      expect(find.text('Node Group B'), findsOneWidget);
      expect(find.text('Node Group A'), findsNothing);
      await tester.tap(find.byTooltip('Test latency'));
      await tester.pumpAndSettle();
      final second =
          calls.lastWhere((call) => call.method == 'groups.test').arguments
              as Map;
      expect(second['tag'], 'Group B');
      expect(second['profileIds'], [20]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('nodes select and test while the service is stopped', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-stopped');
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return call.method == 'ready'
              ? {
                  'version': 'test',
                  'coreVersion': 'test',
                  'dashboard': {'status': 'Stopped', 'selectedProfileId': 1},
                  'preferences': {'locale': 'en'},
                }
              : null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Group A',
          'selected': 'Node A',
          // The host marks the group holding the selected member; a payload
          // with ids but no marker is treated as a stale generation.
          'selectedId': 10,
          'selectable': true,
          'items': [
            {
              'id': 10,
              'tag': 'Node A',
              'type': 'Shadowsocks',
              'delay': 12,
              'testedAt': 1,
            },
            {
              'id': 11,
              'tag': 'Node B',
              'type': 'Shadowsocks',
              'delay': 34,
              'testedAt': 1,
            },
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Node B'));
    await tester.pumpAndSettle();
    expect(
      (calls.lastWhere((call) => call.method == 'groups.select').arguments
          as Map)['tag'],
      'Node B',
    );

    // Tapping the selected node's body must not start a test; only the delay
    // figure has the test action.
    final nodeACard = find.byWidgetPredicate(
      (widget) => widget is ProxyNodeCard && widget.node['tag'] == 'Node A',
    );
    final testsBeforeBodyTap = calls
        .where((call) => call.method == 'groups.test')
        .length;
    await tester.tap(
      find.descendant(of: nodeACard, matching: find.text('Shadowsocks')),
    );
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'groups.test').length,
      testsBeforeBodyTap,
    );

    // The completed-delay target shrinks to its 48px minimum instead of
    // stretching across the rest of the card row.
    final nodeADelay = find.descendant(
      of: nodeACard,
      matching: find.byKey(const ValueKey('delay')),
    );
    expect(tester.getSize(nodeADelay).width, lessThanOrEqualTo(60));
    final selectsBeforeDelayTap = calls
        .where((call) => call.method == 'groups.select')
        .length;
    await tester.tap(nodeADelay);
    await tester.pumpAndSettle();
    expect(
      calls.where((call) => call.method == 'groups.select').length,
      selectsBeforeDelayTap,
    );
    final test =
        calls.lastWhere((call) => call.method == 'groups.test').arguments
            as Map;
    expect(test['tag'], 'Node A');
    expect(test['profileIds'], [10]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets(
    'the selected node is located in the lazy grid and survives group updates',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.proxy-locate');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            channel,
            (call) async => call.method == 'ready'
                ? {
                    'version': 'test',
                    'coreVersion': 'test',
                    'dashboard': {'status': 'Started', 'selectedProfileId': 2},
                    'preferences': {'locale': 'en'},
                  }
                : null,
          );
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      Json group(String tag, int id, int count, int selected) => {
        'id': id,
        'tag': tag,
        'selected': '$tag node $selected',
        'selectedId': id * 1000 + selected,
        'selectable': true,
        'items': [
          for (var index = 0; index < count; index++)
            {'id': id * 1000 + index, 'tag': '$tag node $index', 'type': 'direct'},
        ],
      };
      final groups = [group('Group A', 1, 1, 0), group('Group B', 2, 200, 150)];
      events.add({'type': 'groups', 'value': groups});
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();
      // Only the selected configuration's group is on the page.
      expect(find.text('Group A node 0'), findsNothing);
      expect(find.text('Group B node 150'), findsNothing);
      await tester.tap(find.byTooltip('Scroll to selected'));
      await tester.pumpAndSettle();
      expect(find.text('Group B node 150').hitTestable(), findsOneWidget);
      // A catalog refresh that adds another group must not move the page away
      // from the configuration the selection names.
      events.add({
        'type': 'groups',
        'value': [group('New group', 3, 1, 0), ...groups],
      });
      await tester.pumpAndSettle();
      expect(find.text('Group B node 150').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets(
    'clicking a node delay shows the running spinner until the test completes',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.proxy-delay-animation');
      final testDone = Completer<dynamic>();
      var tested = false;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started', 'selectedProfileId': 1},
            'preferences': {'locale': 'en'},
          };
        }
        if (call.method == 'groups.test') {
          tested = true;
          return testDone.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
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
            'items': [
              {
                'id': 10,
                'tag': 'Node A',
                'type': 'direct',
                'delay': 12,
                'testedAt': 1,
              },
              {
                'id': 11,
                'tag': 'Node B',
                'type': 'direct',
                'delay': 30,
                'testedAt': 1,
              },
            ],
          },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();
      events.add({
        'type': 'testSession',
        'value': {
          'kind': 0,
          'running': false,
          'startedAt': 1,
          'rows': [
            {'id': 10, 'phase': 'DONE'},
            {'id': 11, 'phase': 'DONE'},
          ],
        },
      });
      await tester.pump();

      await tester.tap(find.text('12 ms'));
      await tester.pump();
      expect(tested, isTrue);
      expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
      final currentSessionStartedAt = DateTime.now().millisecondsSinceEpoch;
      events.add({
        'type': 'testSession',
        'value': {
          'kind': 0,
          'running': true,
          'startedAt': currentSessionStartedAt,
          'rows': [
            {'id': 10, 'phase': 'TESTING'},
            {'id': 11, 'phase': 'QUEUED'},
          ],
        },
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
      // A single-node action does not turn its siblings into a test queue.
      expect(
        find.byKey(const ValueKey('glyph:ProxyTestPhase.queued')),
        findsNothing,
      );
      expect(find.text('30 ms'), findsOneWidget);

      testDone.complete(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // The node action owns its spinner: even if the shared session feed still
      // carries a TESTING row, completing groups.test must clear this card.
      expect(find.byKey(const ValueKey('proxy-test-running')), findsNothing);

      // Result persistence arrives as a catalog update. The proxy page must
      // rebuild on that event without requiring another node selection.
      events.add({
        'type': 'groups',
        'value': [
          {
            'id': 1,
            'tag': 'Group A',
            'selected': 'Node A',
            'selectedId': 10,
            'selectable': true,
            'items': [
              {
                'id': 10,
                'tag': 'Node A',
                'type': 'direct',
                'delay': 42,
                'testedAt': 2,
              },
              {
                'id': 11,
                'tag': 'Node B',
                'type': 'direct',
                'delay': 30,
                'testedAt': 1,
              },
            ],
          },
        ],
      });
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('42 ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets('a failing delay test clears its spinner', (tester) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-delay-failure');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Started', 'selectedProfileId': 1},
          'preferences': {'locale': 'en'},
        };
      }
      if (call.method == 'groups.test') {
        throw PlatformException(code: 'failed', message: 'test failed');
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
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
          'items': [
            {
              'id': 10,
              'tag': 'Node A',
              'type': 'direct',
              'delay': 12,
              'testedAt': 1,
            },
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('12 ms'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('proxy-test-running')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the node speed test panel hides IP check, test kind and scope', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-speed-only');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'ready'
          ? {
              'version': 'test',
              'coreVersion': 'test',
              'dashboard': {'status': 'Started', 'selectedProfileId': 1},
              'preferences': {'locale': 'en'},
            }
          : null,
    );
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    openPage(
      tester.element(find.byType(HomePage)),
      const TestPanelPage(
        speedOnly: true,
        profileIds: [10],
        initialSpeedMode: 0,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Speed test'), findsOneWidget);
    expect(find.text('Speed test mode'), findsOneWidget);
    expect(find.text('Test kind'), findsNothing);
    expect(find.text('IP check'), findsNothing);
    expect(find.text('Scope'), findsNothing);
    events.add({
      'type': 'testSession',
      'value': {
        'kind': 2,
        'running': false,
        'speed': {
          'profileId': 10,
          'name': 'Node A',
          'stage': 'Complete',
          'dlBps': 8000000,
          'ulBps': 3000000,
          'pingMs': 42,
          'samples': [
            [0, 3000000, false],
            [1, 8000000, false],
            [2, 3000000, true],
          ],
        },
      },
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Last speed test'), findsOneWidget);
    // The panel draws the speed screen's own curve widget, so a batch run and a
    // single run share one chart instead of two lookalikes.
    final curve = tester.widget<SpeedCurves>(
      find.byKey(const ValueKey('speed-curve')),
    );
    expect(curve.download.any((value) => value > 0), isTrue);
    expect(curve.upload.any((value) => value > 0), isTrue);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets(
    'dedicated speed page starts the native session and renders its snapshot',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.speed-page');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started', 'profile': {'id': 7}, 'selectedProfileId': 7},
            'preferences': {'locale': 'en'},
          };
        }
        if (call.method == 'groups.testSession.visible') return null;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final box = BoxController(channel: channel, events: events.stream);
      attachSessionBus(box, calls);
      await tester.pumpWidget(BoxApp(controller: box));
      await tester.pumpAndSettle();
      openPage(
        tester.element(find.byType(HomePage)),
        const SpeedTestPage(outbound: 'Node A'),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start'));
      // The gauge spins while the run is live, so settle on frames rather than
      // waiting for animations to stop.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The run goes through Throne's own test session, as a speed run.
      final start = calls.lastWhere(
        (call) => call.method == 'groups.testSession.start',
      );
      final args = json(start.arguments);
      expect(args['kind'], 2, reason: 'TestSpec.KIND_SPEED');
      expect(args['profileIds'], isNotEmpty);

      // The session's speed snapshot drives the tiles.
      events.add({
        'type': 'testSession',
        'value': {
          'running': false,
          'speed': {
            'name': 'Node A',
            'stage': 'complete',
            'dlBps': 8000000,
            'ulBps': 3000000,
            'pingMs': 42,
            'server': 'speed.example',
            'serverCountry': 'US',
            'finished': true,
            'samples': [
              [0, 1000, false],
              [1, 4000000, false],
              [2, 8000000, false],
              [3, 500000, true],
              [4, 3000000, true],
            ],
          },
        },
      });
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView).last, const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(find.text('8.00 Mbps'), findsOneWidget);
      expect(find.text('3.00 Mbps'), findsOneWidget);
      expect(find.text('42 ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  testWidgets(
    'home speed page runs the session without a named node',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.speed-page-home');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        if (call.method == 'ready') {
          return {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': 'Started', 'profile': {'id': 7}, 'selectedProfileId': 7},
            'preferences': {'locale': 'en'},
          };
        }
        if (call.method == 'groups.testSession.visible') return null;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final box = BoxController(channel: channel, events: events.stream);
      attachSessionBus(box, calls);
      await tester.pumpWidget(
        BoxApp(controller: box),
      );
      await tester.pumpAndSettle();
      openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start'));
      // The gauge spins while the run is live, so settle on frames rather than
      // waiting for animations to stop.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // No outbound was named, so the session measures the started profile.
      final start = calls.lastWhere(
        (call) => call.method == 'groups.testSession.start',
      );
      final args = json(start.arguments);
      expect(args['kind'], 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );

  // spins, the rows still waiting show the clock. The batch marks every id in
  // one set so the action can be awaited once, and reading that set as "this
  // node is running" painted the whole group as spinning and made the session
  // rows unreachable.
  testWidgets('a group delay test spins only the node under test', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.group-queue');
    final testDone = Completer<Object?>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'ready') {
            return {
              'version': 'test',
              'coreVersion': 'test',
              'dashboard': {'status': 'Started', 'selectedProfileId': 1},
              'preferences': {'locale': 'en'},
            };
          }
          if (call.method == 'groups.test') return testDone.future;
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
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
          'items': [
            {'id': 10, 'tag': 'Node A', 'type': 'direct', 'delay': 12, 'testedAt': 1},
            {'id': 11, 'tag': 'Node B', 'type': 'direct', 'delay': 30, 'testedAt': 1},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Test latency').first);
    await tester.pump();
    // Rows have not arrived: the whole batch reads as queued, not running.
    expect(find.byKey(const ValueKey('proxy-test-running')), findsNothing);
    expect(
      find.byKey(const ValueKey('glyph:ProxyTestPhase.queued')),
      findsNWidgets(2),
    );

    events.add({
      'type': 'testSession',
      'value': {
        'kind': 0,
        'running': true,
        'startedAt': DateTime.now().millisecondsSinceEpoch,
        'rows': [
          {'id': 10, 'phase': 'TESTING'},
          {'id': 11, 'phase': 'QUEUED'},
        ],
      },
    });
    await tester.pump();
    // One spinner for the node under test, one clock for the one waiting.
    expect(find.byKey(const ValueKey('proxy-test-running')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('glyph:ProxyTestPhase.queued')),
      findsOneWidget,
    );

    testDone.complete(null);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the single-node container shows its nodes without a group tab', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-single');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en'},
          'dashboard': {'status': 'Started', 'selectedProfileId': 3},
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 3,
          'tag': 'Default',
          'type': 'group',
          'selectable': true,
          // The single-node container: the page must not render it as a group.
          'single': true,
          'selected': 'Node A',
          'selectedId': 11,
          'items': [
            {'id': 11, 'tag': 'Node A', 'type': 'vmess', 'delay': 40},
            {'id': 12, 'tag': 'Node B', 'type': 'ss', 'delay': 0},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();

    expect(find.text('Node A'), findsOneWidget);
    expect(find.byType(ProxyNodeCard), findsWidgets);
    // No group tab or header: the container's name is not on screen at all.
    expect(find.text('Default'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets('the selected configuration is the only one the page shows', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-correspond');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'preferences': {'locale': 'en'},
          'dashboard': {'status': 'Started', 'selectedProfileId': 1},
        };
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Profile A',
          'type': 'group',
          'selectable': true,
          'selected': 'Node A',
          'selectedId': 11,
          'items': [
            {'id': 11, 'tag': 'Node A', 'type': 'vmess', 'delay': 40},
          ],
        },
        {
          'id': 2,
          'tag': 'Profile B',
          'type': 'group',
          'selectable': true,
          'selected': '',
          'selectedId': 0,
          'items': [
            {'id': 21, 'tag': 'Node B', 'type': 'ss', 'delay': 0},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();

    // The page is the selected configuration, not a list of all of them: no
    // profile names, and only the selected profile's nodes.
    expect(find.text('Profile A'), findsNothing);
    expect(find.text('Profile B'), findsNothing);
    expect(find.text('Node A'), findsOneWidget);
    expect(find.text('Node B'), findsNothing);
    // Switching the configuration switches the nodes.
    events.add({
      'type': 'dashboard',
      'value': {'status': 'Started', 'selectedProfileId': 2},
    });
    await tester.pumpAndSettle();
    expect(find.text('Node B'), findsOneWidget);
    expect(find.text('Node A'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  nodeMemoryTests();
}

// The per-configuration node memory: a node picked in one configuration comes
// back when the user returns to it. The host has a single global selection slot
// and gives a switched-to configuration its group's first member, so without
// this memory an A -> B -> A trip forgets what A was using.
void nodeMemoryTests() {
  testWidgets('each configuration remembers the node it was left on', (
    tester,
  ) async {
    reportFlutterErrors();
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final events = StreamController<dynamic>.broadcast();
    const channel = MethodChannel('test.proxy-node-memory');
    final calls = <MethodCall>[];
    // The host echoes the merged map back and the client's preferences ARE that
    // reply, so the mock has to behave like it or the memory never lands.
    final preferences = <String, dynamic>{'locale': 'en'};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'ready') {
            return {
              'version': 'test',
              'coreVersion': 'test',
              'preferences': preferences,
              'dashboard': {'status': 'Stopped', 'selectedProfileId': 1},
            };
          }
          if (call.method == 'preferences.set') {
            preferences.addAll(json((call.arguments as Map)['value']));
            return preferences;
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await tester.pumpWidget(
      BoxApp(
        controller: BoxController(channel: channel, events: events.stream),
      ),
    );
    await tester.pumpAndSettle();
    events.add({
      'type': 'groups',
      'value': [
        {
          'id': 1,
          'tag': 'Profile A',
          'selected': 'A1',
          'selectedId': 11,
          'selectable': true,
          'items': [
            {'id': 11, 'tag': 'A1', 'type': 'direct'},
            {'id': 12, 'tag': 'A2', 'type': 'direct'},
          ],
        },
        {
          'id': 2,
          'tag': 'Profile B',
          'selected': 'B1',
          'selectedId': 21,
          'selectable': true,
          'items': [
            {'id': 21, 'tag': 'B1', 'type': 'direct'},
            {'id': 22, 'tag': 'B2', 'type': 'direct'},
          ],
        },
      ],
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('Proxies').last);
    await tester.pumpAndSettle();

    // Pick A2 in configuration A.
    await tester.tap(find.text('A2'));
    await tester.pumpAndSettle();
    expect(
      (calls.lastWhere((call) => call.method == 'groups.select').arguments
          as Map)['tag'],
      'A2',
    );

    // Switch to B and pick B2 there.
    events.add({
      'type': 'dashboard',
      'value': {'status': 'Stopped', 'selectedProfileId': 2},
    });
    await tester.pumpAndSettle();
    await tester.tap(find.text('B2'));
    await tester.pumpAndSettle();
    expect(
      (calls.lastWhere((call) => call.method == 'groups.select').arguments
          as Map)['tag'],
      'B2',
    );

    // Back to A: the node it was left on is re-issued, not the group's first.
    events.add({
      'type': 'dashboard',
      'value': {'status': 'Stopped', 'selectedProfileId': 1},
    });
    await tester.pumpAndSettle();
    expect(
      (calls.lastWhere((call) => call.method == 'groups.select').arguments
          as Map)['tag'],
      'A2',
    );

    // And B still remembers its own.
    events.add({
      'type': 'dashboard',
      'value': {'status': 'Stopped', 'selectedProfileId': 2},
    });
    await tester.pumpAndSettle();
    expect(
      (calls.lastWhere((call) => call.method == 'groups.select').arguments
          as Map)['tag'],
      'B2',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await events.close();
  });

  testWidgets(
    'a node selected outside this page survives a reopen instead of being '
    'replayed over by the remembered entry',
    (tester) async {
      reportFlutterErrors();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<dynamic>.broadcast();
      const channel = MethodChannel('test.proxy-selection-survives');
      final calls = <MethodCall>[];
      // The stale entry of an earlier pick: the node page selected A2 since.
      final preferences = <String, dynamic>{
        'locale': 'en',
        'proxySelected': {
          'local:1': {'group': 'A', 'id': 11, 'tag': 'A1'},
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
            'dashboard': {'status': 'Stopped', 'selectedProfileId': 1},
          };
        }
        if (call.method == 'preferences.set') {
          preferences.addAll(json((call.arguments as Map)['value']));
          return preferences;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await tester.pumpWidget(
        BoxApp(
          controller: BoxController(channel: channel, events: events.stream),
        ),
      );
      await tester.pumpAndSettle();
      events.add({
        'type': 'groups',
        'value': [
          {
            'id': 1,
            'tag': 'A',
            'selected': 'A2',
            'selectedId': 12,
            'selectable': true,
            'items': [
              {'id': 11, 'tag': 'A1', 'type': 'direct'},
              {'id': 12, 'tag': 'A2', 'type': 'direct'},
            ],
          },
        ],
      });
      await tester.pumpAndSettle();
      await tester.tap(find.text('Proxies').last);
      await tester.pumpAndSettle();

      // The host's selection is A2, which only the old memory disagrees with.
      // The page must trust the native choice and refresh the memory, not
      // re-issue A1 (that replay is what made the choice look lost after a
      // restart).
      expect(
        calls.where((call) => call.method == 'groups.select'),
        isEmpty,
        reason: 'the native selection is newer than the remembered entry',
      );
      expect(
        (preferences['proxySelected'] as Map)['local:1']['id'],
        12,
        reason: 'the memory follows the selection made elsewhere',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await events.close();
    },
  );
}
