// What the speed screen says when a run ended without measuring anything.
//
// `BboxTestSessions.wire` carries the reason twice: the session's `failure` is
// the coarse TestFailure enum (`EMPTY`, `BUSY`, `UNREACHABLE`, `CORE_DIED`,
// `NONE`), and each row's `error` holds the engine's own text
// (`TestSession.notMeasured` prefixes it). The screen read only the enum, so a
// run the engine aborted with "instance is not running" printed the generic
// "The test did not finish", and a session the host tore down printed
// "Cancelled" because `finish` marks those `cancelled` too.
//
// The host also relays the model every 400 ms
// (`ThroneBoxBridge.setTestSessionVisible`), while `SpeedTestRunner` reports the
// live snapshot just before the result that writes the row's text — so the
// verdict can reach the page one tick before its reason does. That race is
// covered here too: the page picks the row up rather than settling on the
// generic sentence.

import 'dart:async';

import 'package:flrone/main.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/errors.dart';
import 'support/fake_session_kernel.dart';

/// One session the host closed before any probe answered, in the shape
/// BboxTestSessions.wire emits: no live speed snapshot, a failure verdict, and
/// the rows the engine reported against.
Map<String, dynamic> _closed(
  String failure, {
  bool cancelled = false,
  String rowError = '',
}) => {
  'kind': 2,
  'running': false,
  'cancelled': cancelled,
  'failure': failure,
  'speed': null,
  if (rowError.isNotEmpty)
    'rows': [
      {
        'id': 0,
        'phase': 'DONE',
        'latency': 0,
        'error': rowError,
        'dlSpeed': '',
        'ulSpeed': '',
        'country': '',
        'ip': '',
        'ok': false,
        'failed': false,
        'aborted': true,
      },
    ],
};

/// A session whose live frame already says the run failed, before the row that
/// names why is written.
Map<String, dynamic> _errorFrame({String rowError = ''}) => {
  'kind': 2,
  'running': false,
  'failure': 'NONE',
  'speed': {
    'profileId': 0,
    'name': '',
    'stage': 'error',
    'dlBps': 0,
    'ulBps': 0,
    'pingMs': 0,
    'finished': true,
    'error': '',
    'cancelled': false,
    'samples': <List<dynamic>>[],
  },
  if (rowError.isNotEmpty)
    'rows': [
      {
        'id': 0,
        'phase': 'DONE',
        'error': rowError,
        'ok': false,
        'failed': false,
        'aborted': true,
      },
    ],
};

/// Boots BoxApp over a channel that answers `ready` and the session start, and
/// opens the speed screen. [stored] seeds the preferences the page reads.
Future<({List<MethodCall> calls, StreamController<dynamic> events})> _boot(
  WidgetTester tester, {
  required String channelName,
  int startReply = 1,
  Map<String, Object?> stored = const {},
}) async {
  tester.view.physicalSize = const Size(360, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final events = StreamController<dynamic>.broadcast();
  final channel = MethodChannel(channelName);
  final calls = <MethodCall>[];
  final preferences = <String, Object?>{'locale': 'en', ...stored};
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, (call) async {
    calls.add(call);
    if (call.method == 'ready') {
      return {
        'version': 'test',
        'coreVersion': 'test',
        'dashboard': {'status': 'Started'},
        'preferences': preferences,
      };
    }
    if (call.method == 'preferences.set') {
      preferences.addAll(json(call.arguments)['value'] as Map<String, Object?>);
      return preferences;
    }
    return null;
  });
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  // P4a: the session controls ride the action bus (see fake_session_kernel.dart).
  final controller = BoxController(channel: channel, events: events.stream);
  attachSessionBus(controller, calls, startReply: startReply > 0);
  await tester.pumpWidget(BoxApp(controller: controller));
  await tester.pumpAndSettle();
  return (calls: calls, events: events);
}

/// Starts a run and leaves the screen following it.
Future<void> _startRun(WidgetTester tester) async {
  await tester.tap(find.text('Start'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets('a closed session shows the row\'s own reason, not the generic '
      'sentence', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-error-row');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await _startRun(tester);
    expect(find.text('Stop'), findsOneWidget);

    // The kernel's verdict: running:false, speed:null, failure NONE — the enum
    // says nothing — while the row the engine reported against carries the cause.
    harness.events.add({
      'type': 'testSession',
      'value': _closed(
        'NONE',
        rowError: 'aborted: instance is not running',
      ),
    });
    await tester.pumpAndSettle();

    expect(
      find.text('aborted: instance is not running'),
      findsOneWidget,
      reason: 'the engine named the cause; the screen must print it',
    );
    expect(find.text('The test did not finish'), findsNothing);
    expect(find.text('Stop'), findsNothing);
    expect(find.text('Test again'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('an unreachable core says so instead of "Cancelled"', (
    tester,
  ) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-error-unreach');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await _startRun(tester);

    // TestSessionClient.finish marks a torn-down session cancelled as well; the
    // verdict, not the flag, is what happened.
    harness.events.add({
      'type': 'testSession',
      'value': _closed('UNREACHABLE', cancelled: true),
    });
    await tester.pumpAndSettle();

    expect(find.text('The core service is unreachable'), findsOneWidget);
    expect(find.text('Cancelled'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a core that died says so instead of "Cancelled"', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-error-died');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await _startRun(tester);

    harness.events.add({
      'type': 'testSession',
      'value': _closed('CORE_DIED', cancelled: true),
    });
    await tester.pumpAndSettle();

    expect(find.text('The core service died'), findsOneWidget);
    expect(find.text('Cancelled'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a stop the user asked for still reads "Cancelled", not the '
      'engine\'s abort noise', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-error-stop');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await _startRun(tester);

    // A stop reports every remaining profile as aborted with the bare marker;
    // "test aborted" names no cause and must not replace the page's verdict.
    harness.events.add({
      'type': 'testSession',
      'value': _closed('NONE', cancelled: true, rowError: 'test aborted'),
    });
    await tester.pumpAndSettle();

    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.text('test aborted'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a reason that arrives one relay tick after the verdict is '
      'picked up', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-error-race');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await _startRun(tester);

    // SpeedTestRunner reports the live snapshot (stage error) before the result
    // that writes the row's text, so the first wire has the verdict but not why.
    harness.events.add({'type': 'testSession', 'value': _errorFrame()});
    await tester.pumpAndSettle();
    expect(find.text('The test did not finish'), findsOneWidget);

    // The next relay carries the row. The page stopped following, so it reads
    // the box's session once more instead of settling on the generic sentence.
    harness.events.add({
      'type': 'testSession',
      'value': _errorFrame(rowError: 'aborted: instance is not running'),
    });
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(
      find.text('aborted: instance is not running'),
      findsOneWidget,
      reason: 'the late row replaces the generic sentence',
    );
    expect(find.text('The test did not finish'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('a refused start while a session is held is the busy verdict; a '
      'refused start after a closed one is not', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-error-start',
      startReply: 0,
    );
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();

    // The host holds a running speed session, so the false reply is its verdict.
    harness.events.add({
      'type': 'testSession',
      'value': {'kind': 2, 'running': true, 'failure': 'NONE', 'speed': null},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('A speed test is already running'), findsOneWidget);

    // The box now holds a *closed* session: a refused start cannot mean "already
    // running" there, so the screen reports the failure instead of blaming a
    // session that is not running.
    harness.events.add({
      'type': 'testSession',
      'value': {'kind': 2, 'running': false, 'failure': 'NONE', 'speed': null},
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Start'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('A speed test is already running'), findsNothing);
    expect(find.text('Start failed'), findsOneWidget);
    // The screen stays idle and usable either way.
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  // The settings dialog used to persist provider, protocol, duration and
  // connection count, and nothing read them: the native tester takes none of
  // those (Mobile.startSpeedTest carries the directions and a timeout). What the
  // dialog edits now is the direction, and it must land on the wire.
  testWidgets('the stored direction reaches the session start', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(
      tester,
      channelName: 'test.speed-direction',
      stored: {'speedTestDirection': 'upload'},
    );
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await _startRun(tester);
    final args = json(
      harness.calls
          .lastWhere((call) => call.method == 'groups.testSession.start')
          .arguments,
    );
    expect(
      args['speedMode'],
      2,
      reason: 'TestUiState.SPEED_MODE_UPLOAD, from the stored direction',
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });

  testWidgets('no stored direction follows the Testing setting', (tester) async {
    reportFlutterErrors();
    final harness = await _boot(tester, channelName: 'test.speed-direction-both');
    openPage(tester.element(find.byType(HomePage)), const SpeedTestPage());
    await tester.pumpAndSettle();
    await _startRun(tester);
    final args = json(
      harness.calls
          .lastWhere((call) => call.method == 'groups.testSession.start')
          .arguments,
    );
    expect(args['speedMode'], -1, reason: 'both directions, from the settings');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await harness.events.close();
  });
}
