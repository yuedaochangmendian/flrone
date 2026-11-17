// The speed screen's feed, as the host actually delivers it.
//
// The host relays `testSession` events only while `groups.testSession.visible`
// is true (ThroneBoxBridge.setTestSessionVisible), and that flag is set by a
// BoxDataSubscription over BoxData.testSession. The screen used to rely on
// `box.addListener` alone, which reads a field that never changed: a run
// started from the dashboard's Network speed card sat at Ready forever. These
// tests pin the subscription and the verdicts the page honours.
//
// The session arguments are pinned too. `groups.testSession.start` takes
// ProxyEntity ids (`TestSession.resolve` reads them with ProfileManager), and
// the page used to send `dashboard.selectedProfileId`, which the bridge sets to
// the *group* id — the engine resolved no profile, measured nothing, emitted no
// speed snapshot, and the page's spinner never stopped.

import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/services/speed_test_history.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';

/// The node rows `groups.nodes` answers, ids and tags as BboxGroupsWire emits.
const _nodes = <Map<String, Object?>>[
  {'id': 7, 'tag': 'Node A', 'type': 'shadowsocks', 'isSelector': false},
  {'id': 8, 'tag': 'Node B', 'type': 'shadowsocks', 'isSelector': false},
];

/// The catalog's group rows: group 42 selects node 8.
const _groups = <Map<String, Object?>>[
  {
    'id': 42,
    'tag': 'Group',
    'type': 'subscription',
    'selected': 'Node B',
    'selectedId': 8,
    'selectable': true,
    'nodeCount': 2,
    'timeouts': 0,
    'items': <Map<String, Object?>>[],
  },
];

/// One live speed snapshot in the wire shape BboxTestSession.wire emits.
Map<String, dynamic> _snapshot({
  String stage = 'download',
  bool finished = false,
  bool cancelled = false,
  String error = '',
  double dl = 8000000,
  double ul = 3000000,
  double ping = 42,
  int startedAt = 0,
}) => {
  'kind': 2,
  'running': !finished,
  if (startedAt > 0) 'startedAt': startedAt,
  'speed': {
    'profileId': 7,
    'name': 'Node A',
    'stage': stage,
    'dlBps': dl,
    'ulBps': ul,
    'dlBytes': 8000000,
    'ulBytes': 3000000,
    'pingMs': ping,
    'server': 'speed.example',
    'serverCountry': 'US',
    'finished': finished,
    'error': error,
    'cancelled': cancelled,
    'samples': [
      [0, 1000, false],
      [1, 4000000, false],
      [2, dl, false],
      [3, 500000, true],
      [4, ul, true],
    ],
  },
};

/// A session the host closed before any probe answered: no live snapshot, a
/// failure verdict and no results.
Map<String, dynamic> _closed(String failure, {bool cancelled = false}) => {
  'kind': 2,
  'running': false,
  'cancelled': cancelled,
  'failure': failure,
  'speed': null,
};

/// The maps the page wrote through `preferences.set` under the history key.
List<List<dynamic>> _historyWrites(List<MethodCall> calls) => [
  for (final call in calls)
    if (call.method == 'preferences.set')
      if ((json(call.arguments)['value'] as Map?)?[speedTestHistoryKey]
          case final List<dynamic> records)
        records,
];

/// Boots BoxApp over a channel that answers `ready`, the node rows and the
/// session start, and opens the speed screen.
///
/// `preferences.set` merges into the preferences the bridge answers with, the
/// way the host does: the page reads the history back out of that map, so a
/// mock that dropped the key would hide a duplicate record.
Future<({List<MethodCall> calls, StreamController<dynamic> events})> _boot(
  WidgetTester tester, {
  required String channelName,
  int startReply = 1,
  bool withGroups = false,
  String dashboardStatus = 'Started',
  void Function(MethodCall call)? onCall,
}) async {
  tester.view.physicalSize = const Size(360, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final events = StreamController<dynamic>.broadcast();
  final channel = MethodChannel(channelName);
  final calls = <MethodCall>[];
  final preferences = <String, Object?>{'locale': 'en'};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    onCall?.call(call);
    if (call.method == 'ready') {
      return {
        'version': 'test',
        'coreVersion': 'test',
        'dashboard': {
          'status': dashboardStatus,
          // The bridge sets this to the *group* id; the page must not send it.
          'selectedProfileId': 42,
        },
        if (withGroups) 'groups': _groups,
        'preferences': preferences,
      };
    }
    if (call.method == 'groups.nodes') return {'nodes': _nodes};
    if (call.method == 'groups.testSession.start') return startReply > 0;
    if (call.method == 'groups.testSession.visible') return null;
    if (call.method == 'preferences.set') {
      preferences.addAll(json(call.arguments)['value'] as Map<String, Object?>);
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
  return (calls: calls, events: events);
}

void main() {
  testWidgets(
    'opening the screen subscribes to the session feed and a relayed snapshot '
    'reaches the gauge and the tiles',
    (tester) async {
      reportFlutterErrors();
      final harness = await _boot(tester, channelName: 'test.speed-feed');
      // Opened the way the dashboard's Network speed card opens it.
      openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
      await tester.pumpAndSettle();

      // The page asks the host to relay the session feed. Without this call the
      // rest of this test could never pass, because the host emits nothing.
      final visible = harness.calls
          .where((call) => call.method == 'groups.testSession.visible')
          .map((call) => json(call.arguments))
          .toList();
      expect(visible, isNotEmpty);
      expect(visible.last['visible'], isTrue);

      // A run started from here, then a snapshot relayed on the feed. This is
      // the path the dashboard's card takes; before the subscription the same
      // snapshot never arrived and the gauge stayed at Ready.
      await tester.tap(find.text('Start'));
      await tester.pump();
      // The gauge spins while the run is live, so settle on frames rather than
      // waiting for animations to stop.
      await tester.pump(const Duration(milliseconds: 400));

      harness.events.add({'type': 'testSession', 'value': _snapshot()});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The stage caption and the live rate, from the same snapshot.
      expect(find.text('Download'), findsWidgets);
      expect(find.text('8.0'), findsOneWidget);
      expect(find.text('Mbps'), findsOneWidget);

      // The finished snapshot settles the run on its own numbers.
      harness.events.add({
        'type': 'testSession',
        'value': _snapshot(
          stage: 'complete',
          finished: true,
          dl: 8000000,
          ul: 3000000,
        ),
      });
      await tester.pumpAndSettle();
      expect(find.text('Complete'), findsOneWidget);
      await tester.drag(find.byType(ListView).last, const Offset(0, -420));
      await tester.pumpAndSettle();
      expect(find.text('8.00 Mbps'), findsOneWidget);
      expect(find.text('3.00 Mbps'), findsOneWidget);
      expect(find.text('42 ms'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await harness.events.close();
    },
  );

  testWidgets('a refused start shows the already-running verdict and Start '
      'stays usable', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-feed-busy',
      startReply: 0,
    );
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      harness.calls.where((call) => call.method == 'groups.testSession.start'),
      hasLength(1),
    );
    expect(
      find.text('A speed test is already running'),
      findsOneWidget,
      reason: 'the false reply is a verdict, not a failure',
    );
    // The refusal left the page idle, so the button is Start again, not Stop,
    // and it can be pressed once more without the spinner having stuck.
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    await tester.tap(find.text('Start'));
    await tester.pump();
    expect(
      harness.calls.where((call) => call.method == 'groups.testSession.start'),
      hasLength(2),
      reason: 'a refused run does not lock the screen',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('the screen shows only the figures the kernel measures', (
    tester,
  ) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-feed-honest',
    );
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();

    // No run yet, so nothing measured: the page must not advertise knobs the
    // kernel never reads (provider, protocol, duration, connection count) nor
    // figures the native run never produces (jitter, loaded latency, RPM).
    expect(find.text('Run settings'), findsNothing);
    expect(find.text('Jitter'), findsNothing);
    expect(find.text('Loaded latency'), findsNothing);
    expect(find.text('RPM'), findsNothing);

    await tester.drag(find.byType(ListView).last, const Offset(0, -420));
    await tester.pumpAndSettle();
    expect(find.text('Delay'), findsWidgets);
    expect(find.text('Download'), findsWidgets);
    expect(find.text('Upload'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a named node is measured by its own id, never the group id', (
    tester,
  ) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-args',
      withGroups: true,
    );
    // The node card names the node: its tag resolves through groups.nodes.
    openPage(
      tester.element(find.byType(HomePage)),
      const SpeedTestPage(outbound: 'Node A'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final args = json(
      harness.calls
          .lastWhere((call) => call.method == 'groups.testSession.start')
          .arguments,
    );
    expect(args['kind'], 2, reason: 'TestSpec.KIND_SPEED');
    expect(args['profileIds'], [7], reason: 'the node id, not the group id 42');
    expect(args['testCurrent'], isFalse);
    expect(args['speedMode'], -1, reason: 'both directions follow the setting');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('without a named node the group selection is the measurement', (
    tester,
  ) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-args-group',
      withGroups: true,
    );
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final args = json(
      harness.calls
          .lastWhere((call) => call.method == 'groups.testSession.start')
          .arguments,
    );
    expect(args['profileIds'], [8], reason: 'group 42 selects node 8');
    expect(args['testCurrent'], isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('with no node at all the run measures the live connection', (
    tester,
  ) async {
    reportFlutterErrors();
    // No groups and no node rows: nothing names a profile, so the page asks for
    // a test-current run — upstream's startCurrent(KIND_SPEED) (F6), which
    // resolves the running profile on the host side. The dashboard's id rides
    // along only as the row key (TestSessionClient ignores it for this mode).
    final harness = await _boot(tester, channelName: 'test.speed-args-current');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final args = json(
      harness.calls
          .lastWhere((call) => call.method == 'groups.testSession.start')
          .arguments,
    );
    expect(args['testCurrent'], isTrue);
    expect(args['kind'], 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a download-only run sends speed mode 1', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-mode-download',
      withGroups: true,
    );
    // The node card's Download entry: download only, no upload.
    openPage(
      tester.element(find.byType(HomePage)),
      const SpeedTestPage(outbound: 'Node A', download: true, upload: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final args = json(
      harness.calls
          .lastWhere((call) => call.method == 'groups.testSession.start')
          .arguments,
    );
    expect(args['speedMode'], 1, reason: 'TestUiState.SPEED_MODE_DOWNLOAD');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('an upload-only run sends speed mode 2', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-mode-upload',
      withGroups: true,
    );
    // The Upload entry: upload only.
    openPage(
      tester.element(find.byType(HomePage)),
      const SpeedTestPage(outbound: 'Node A', download: false),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final args = json(
      harness.calls
          .lastWhere((call) => call.method == 'groups.testSession.start')
          .arguments,
    );
    expect(args['speedMode'], 2, reason: 'TestUiState.SPEED_MODE_UPLOAD');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('restarting ignores the previous run replayed on the feed and '
      'records no duplicate history', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-restart',
      withGroups: true,
    );
    openPage(
      tester.element(find.byType(HomePage)),
      const SpeedTestPage(outbound: 'Node A'),
    );
    await tester.pumpAndSettle();

    // TestSessionModel stamps startedAt with the wall clock when the session is
    // created. Stamped after this run began, so the guard reads it as its own.
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final first = DateTime.now().millisecondsSinceEpoch;
    harness.events.add({
      'type': 'testSession',
      'value': _snapshot(
        stage: 'complete',
        finished: true,
        startedAt: first,
      ),
    });
    await tester.pumpAndSettle();
    expect(find.text('Complete'), findsOneWidget);
    expect(_historyWrites(harness.calls), hasLength(1));
    expect(_historyWrites(harness.calls).last, hasLength(1));

    // Test again. The host replays the last session when the feed subscribes,
    // so the finished wire stamped [first] arrives again; it belongs to the run
    // that just ended and must change nothing.
    await tester.tap(find.text('Test again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Stop'), findsOneWidget, reason: 'the new run follows');
    harness.events.add({
      'type': 'testSession',
      'value': _snapshot(stage: 'complete', finished: true, startedAt: first),
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.text('Stop'),
      findsOneWidget,
      reason: 'the replayed finished wire does not end the new run',
    );
    expect(
      _historyWrites(harness.calls),
      hasLength(1),
      reason: 'no record for a run nobody measured',
    );

    // This run's own wire, stamped after it began, still applies.
    final second = first + 1;
    harness.events.add({
      'type': 'testSession',
      'value': _snapshot(stage: 'download', startedAt: second),
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('8.0'), findsOneWidget);
    harness.events.add({
      'type': 'testSession',
      'value': _snapshot(stage: 'complete', finished: true, startedAt: second),
    });
    await tester.pumpAndSettle();
    expect(find.text('Complete'), findsOneWidget);
    expect(_historyWrites(harness.calls), hasLength(2));
    expect(_historyWrites(harness.calls).last, hasLength(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a session that ends with no snapshot stops the spinner and '
      'shows why', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-empty');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Stop'), findsOneWidget);

    // Nothing to measure: no live snapshot, running false, failure EMPTY.
    harness.events.add({'type': 'testSession', 'value': _closed('EMPTY')});
    await tester.pumpAndSettle();
    expect(
      find.text('Stop'),
      findsNothing,
      reason: 'the run is over; the spinner must not stay up',
    );
    expect(find.text('Test again'), findsOneWidget);
    expect(find.text('Nothing to test'), findsOneWidget);
    expect(_historyWrites(harness.calls), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a failed or cancelled stage writes no history', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-failure');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    harness.events.add({
      'type': 'testSession',
      'value': _snapshot(
        stage: 'error',
        finished: true,
        error: 'timeout',
      ),
    });
    await tester.pumpAndSettle();
    expect(find.text('The test timed out'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    expect(
      _historyWrites(harness.calls),
      isEmpty,
      reason: 'a run with no measurement is not a record',
    );

    // Test again, then a stopped run: the engine reports stage cancelled.
    await tester.tap(find.text('Test again'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    harness.events.add({
      'type': 'testSession',
      'value': _snapshot(
        stage: 'cancelled',
        finished: true,
        cancelled: true,
        error: 'test aborted',
      ),
    });
    await tester.pumpAndSettle();
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    expect(_historyWrites(harness.calls), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('the card stops saying "core stopped" once the core starts', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-live',
      dashboardStatus: 'Stopped',
    );
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    // Opened while the core was down: the route row says so.
    expect(find.text('Core stopped'), findsOneWidget);

    // The core starts with the sheet still open; the card must follow the box, not the
    // status it read once in _load.
    harness.events.add({'type': 'dashboard', 'value': {'status': 'Started'}});
    await tester.pumpAndSettle();
    expect(find.text('Core stopped'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });
}
