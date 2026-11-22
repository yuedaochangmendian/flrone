import 'dart:async';
import 'package:flrone/box.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.box');
  late StreamController<dynamic> events;
  late BoxController box;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    events = StreamController<dynamic>.broadcast();
    box = BoxController(channel: channel, events: events.stream);
  });
  tearDown(() async { box.dispose(); await events.close(); messenger.setMockMethodCallHandler(channel, null); });

  test('native startup failure is recoverable', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'startup', message: 'configuration error');
    });
    await box.initialize();
    expect(box.ready, false);
    expect(box.startupError, 'configuration error');
    messenger.setMockMethodCallHandler(channel, (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    expect(box.ready, true);
    expect(box.startupError, null);
  });

  test('service state comes from the active core', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    expect(box.running, false);
    events.add({'type': 'dashboard', 'value': {'remote': 'server', 'remoteConnected': true, 'status': 'Stopped', 'modes': ['rule']}});
    await Future<void>.delayed(Duration.zero);
    expect(box.running, true);
    expect(box.dashboard['modes'], ['rule']);
    events.add({'type': 'dashboard', 'value': {'status': 'Stopped', 'modes': []}});
    await Future<void>.delayed(Duration.zero);
    expect(box.running, false);
    expect(box.dashboard['modes'], isEmpty);
  });

  testWidgets('FFI kernel logs use sing-box levels and the recording floor', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'settings': {'logLevel': 'warn'},
        };
      }
      return <String, dynamic>{};
    });
    final kernel = _FakeKernel();
    final logBox = BoxController(
      channel: channel,
      events: events.stream,
      kernelControl: kernel,
    );
    addTearDown(logBox.dispose);
    await logBox.initialize();

    kernel.emit({
      'type': 'kernelLog',
      'value': {'level': 5, 'message': 'debug line'},
    });
    kernel.emit({
      'type': 'kernelLog',
      'value': {'level': 2, 'message': 'error line'},
    });
    await tester.idle();
    await tester.pump(
      BoxController.kernelLogBatchWindow + const Duration(milliseconds: 1),
    );

    expect(logBox.logs, hasLength(1));
    expect(logBox.logs.single['level'], 'error');
    expect(logBox.logs.single['message'], 'error line');
    expect(logBox.logs.single['seq'], 1);
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 1));
  });

  testWidgets('a kernel log burst is merged once and keeps the newest window', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
        };
      }
      return <String, dynamic>{};
    });
    final kernel = _FakeKernel();
    final logBox = BoxController(
      channel: channel,
      events: events.stream,
      kernelControl: kernel,
    );
    addTearDown(logBox.dispose);
    await logBox.initialize();
    var notified = 0;
    logBox.addListener(() => notified++);

    final total = BoxController.maxLogLength + 50;
    for (var i = 0; i < total; i++) {
      kernel.emit({
        'type': 'kernelLog',
        'value': {'level': 2, 'message': 'line $i'},
      });
    }
    await tester.idle();
    await tester.pump(
      BoxController.kernelLogBatchWindow + const Duration(milliseconds: 1),
    );

    expect(logBox.logs, hasLength(BoxController.maxLogLength));
    expect(logBox.logs.first['message'], 'line 50');
    expect(logBox.logs.last['message'], 'line ${total - 1}');
    expect(
      logBox.logs.map((entry) => (entry['seq'] as num).toInt()),
      orderedEquals([
        for (var i = 0; i < BoxController.maxLogLength; i++) 51 + i,
      ]),
    );
    expect(notified, 0, reason: 'the public notification still waits for its batch window');

    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 1));
    expect(notified, 1);
  });

  testWidgets('a batched kernel log event keeps every line in arrival order', (
    tester,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'settings': {'logLevel': 'warn'},
        };
      }
      return <String, dynamic>{};
    });
    final kernel = _FakeKernel();
    final logBox = BoxController(
      channel: channel,
      events: events.stream,
      kernelControl: kernel,
    );
    addTearDown(logBox.dispose);
    await logBox.initialize();

    kernel.emit({
      'type': 'kernelLogs',
      'value': [
        {'level': 2, 'message': 'first'},
        {'level': 2, 'message': 'second'},
      ],
    });
    await tester.idle();
    await tester.pump(
      BoxController.kernelLogBatchWindow + const Duration(milliseconds: 1),
    );

    expect(
      logBox.logs.map((entry) => entry['message']),
      orderedEquals(['first', 'second']),
    );
    expect(
      logBox.logs.map((entry) => (entry['seq'] as num).toInt()),
      orderedEquals([1, 2]),
    );
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 1));
  });

  testWidgets('a byte payload decodes in one pass and a reset replaces the kernel tail', (tester) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {
          'version': 'test',
          'coreVersion': 'test',
          'dashboard': {'status': 'Stopped'},
          'settings': {'logLevel': 'warn'},
        };
      }
      return <String, dynamic>{};
    });
    final kernel = _FakeKernel();
    final logBox = BoxController(
      channel: channel,
      events: events.stream,
      kernelControl: kernel,
    );
    addTearDown(logBox.dispose);
    await logBox.initialize();

    // The service engine's wire: one string, `receivedAt \t level \t message` per line.
    kernel.emit({
      'type': 'kernelLogs',
      'value': {'payload': '1000\tinfo\tinfo is below the floor\n2000\terror\tfirst', 'reset': false},
    });
    await tester.idle();
    expect(logBox.logs.map((entry) => entry['message']), ['first']);
    // The worker's arrival instant rides the payload instead of being re-stamped here.
    expect(logBox.logs.single['receivedAt'], 2000);

    kernel.emit({
      'type': 'kernelLogs',
      'value': {'payload': '3000\terror\tsecond', 'reset': true},
    });
    await tester.idle();
    // A reset is the ring snapshot the service replays when the log screen opens.
    expect(logBox.logs.map((entry) => entry['message']), ['second']);
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 1));
  });

  test('command errors are visible and never become successful actions', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'core', message: 'automatic group'));
    final error = box.messages.first;
    expect(await box.act('groups.select', {'group': 'auto', 'tag': 'node'}), false);
    expect(await error, 'automatic group');
  });

  test('service setting changes wait for the native restart and ignore repeated edits', () async {
    box.dashboard = {'status': 'Started'};
    box.settings = {'allowBypass': false};
    box.applyRequired = 'Restart';
    final reply = Completer<Json>();
    final edits = <Json>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'settings.set');
      edits.add(json(call.arguments));
      return reply.future;
    });
    final saving = box.setSetting('allowBypass', true, autoRestart: true);
    await Future<void>.delayed(Duration.zero);
    expect(box.serviceSettingsChanging, true);
    expect(box.settings['allowBypass'], false);
    expect(box.applyRequired, 'Restart');
    await box.setSetting('autoRedirect', true, autoRestart: true);
    expect(edits, [{'key': 'allowBypass', 'value': true, 'restart': true}]);
    reply.complete({'allowBypass': true});
    await saving;
    expect(box.serviceSettingsChanging, false);
    expect(box.settings['allowBypass'], true);
    expect(box.applyRequired, null);
  });

  for (final dashboard in <Json>[
    {'status': 'Stopped'},
    {'status': 'Started', 'remote': 'Server', 'remoteConnected': true},
    {'status': 'Stopped', 'remote': 'Server', 'remoteConnected': false},
  ]) {
    test('service settings only persist while stopped or remote: $dashboard', () async {
      box.dashboard = dashboard;
      final edits = <Json>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'settings.set');
        edits.add(json(call.arguments));
        return {'allowBypass': true};
      });
      await box.setSetting('allowBypass', true, autoRestart: true);
      expect(edits, [{'key': 'allowBypass', 'value': true}]);
      expect(box.settings['allowBypass'], true);
      expect(box.applyRequired, null);
    });
  }

  test('service settings cannot change during a local start or stop', () async {
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async { calls.add(call.method); return {}; });
    for (final status in ['Starting', 'Stopping']) {
      box.dashboard = {'status': status};
      await box.setSetting('allowBypass', true, autoRestart: true);
    }
    expect(calls, isEmpty);
    expect(box.serviceSettingsChanging, false);
  });

  test('failed automatic restart reports the error and keeps the recovered native settings', () async {
    final reply = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'ready') {
        return {'version': 'test', 'coreVersion': 'test',
        'dashboard': {'status': 'Started'}, 'settings': {'allowBypass': false}};
      }
      expect(call.method, 'settings.set');
      events.add({'type': 'settings', 'value': {'allowBypass': true}});
      await reply.future;
      events.add({'type': 'settings', 'value': {'allowBypass': false}});
      throw PlatformException(code: 'box_error', message: 'Startup failed');
    });
    await box.initialize();
    box.applyRequired = 'Restart';
    final error = box.messages.first;
    final saving = box.setSetting('allowBypass', true, autoRestart: true);
    await Future<void>.delayed(Duration.zero);
    expect(box.settings['allowBypass'], true);
    expect(box.serviceSettingsChanging, true);
    reply.complete();
    await saving;
    await Future<void>.delayed(Duration.zero);
    expect(await error, 'Startup failed');
    expect(box.settings['allowBypass'], false);
    expect(box.serviceSettingsChanging, false);
    expect(box.applyRequired, 'Restart');
  });

  test('core and access settings retain their existing apply behavior', () async {
    box.dashboard = {'status': 'Started'};
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(json(call.arguments).containsKey('restart'), false);
      return {'oomKillerEnabled': true};
    });
    await box.setSetting('oomKillerEnabled', true);
    expect(box.applyRequired, 'Restart');
    box.clearApplyRequired();
    await box.setSetting('disableDeprecatedWarnings', true, restart: false);
    expect(box.applyRequired, null);
    await box.setSettings({'perAppEnabled': true});
    expect(box.applyRequired, 'Restart');
  });

  test('imports received before the home route mounts stay queued', () async {
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'intent.take'
      ? 'sing-box://import-remote-profile?url=https%3A%2F%2Fexample.org%2Fconfig.json'
      : {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    events.add({'type': 'intentAvailable', 'value': true});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(box.pendingIntents.single, startsWith('sing-box://'));
  });

  group('event bus', () {
    void wire({Object? intake}) {
      messenger.setMockMethodCallHandler(channel, (call) async => switch (call.method) {
        'ready' => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}},
        'intent.take' => intake,
        _ => <String, dynamic>{},
      });
    }

    test('the derived slices are cached rather than rebuilt on every read', () {
      expect(identical(box.messages, box.messages), true);
      expect(identical(box.subscriptionReports, box.subscriptionReports), true);
      expect(identical(box.browserEvents, box.browserEvents), true);
      expect(identical(box.intents, box.intents), true);
    });

    test('each event reaches only its own slice', () async {
      wire(intake: 'sing-box://import-remote-profile?url=https%3A%2F%2Fexample.org');
      await box.initialize();
      final messages = <String>[];
      final reports = <Json>[];
      final browsers = <Json>[];
      final intents = <IntentAvailableEvent>[];
      box.messages.listen(messages.add);
      box.subscriptionReports.listen(reports.add);
      box.browserEvents.listen(browsers.add);
      box.intents.listen(intents.add);

      events.add({'type': 'subscriptionReport', 'value': {'kind': 'popup', 'groupName': 'Sub', 'text': 'Updated'}});
      events.add({'type': 'browserComplete', 'value': {'url': 'https://example.org/callback'}});
      events.add({'type': 'intentAvailable', 'value': true});
      events.add({'type': 'error', 'value': 'boom'});
      await pumpEventQueue();

      expect(reports, [{'kind': 'popup', 'groupName': 'Sub', 'text': 'Updated'}]);
      expect(browsers, [{'url': 'https://example.org/callback'}]);
      expect(intents, hasLength(1));
      expect(messages, ['boom']);
    });

    test('a subscription report without a popup becomes a banner, prefixed by its group', () async {
      wire();
      await box.initialize();
      final messages = <String>[];
      final reports = <Json>[];
      box.messages.listen(messages.add);
      box.subscriptionReports.listen(reports.add);

      events.add({'type': 'subscriptionReport', 'value': {'kind': 'status', 'groupName': 'Sub', 'text': 'Updated 3 nodes'}});
      events.add({'type': 'subscriptionReport', 'value': {'kind': 'error', 'text': 'Update failed'}});
      await pumpEventQueue();

      expect(messages, ['Sub: Updated 3 nodes', 'Update failed']);
      expect(reports, isEmpty);
    });

    test('a UI notice goes to the banner stream without touching the backend', () async {
      final banner = box.messages.first;
      box.showMessage('copied');
      expect(await banner, 'copied');
    });

    test('an intent the backend cannot supply is not announced', () async {
      wire();
      await box.initialize();
      final intents = <IntentAvailableEvent>[];
      box.intents.listen(intents.add);

      events.add({'type': 'intentAvailable', 'value': true});
      await pumpEventQueue();

      expect(intents, isEmpty);
      expect(box.pendingIntents, isEmpty);
    });

    test('closing the controller ends every slice', () async {
      final local = BoxController(channel: channel, events: events.stream);
      final ended = Future.wait([
        local.messages.toList(),
        local.subscriptionReports.toList(),
        local.browserEvents.toList(),
        local.intents.toList(),
      ]);
      local.dispose();

      expect(await ended, [[], [], [], []]);
    });
  });

  test('the service dashboard never overwrites the driver\'s numbers', () {
    final driver = <String, dynamic>{
      'status': 'Started', 'startedAt': 1000, 'uploadTotal': 4096, 'downloadTotal': 8192,
      'connections': 7, 'memory': 64, 'goroutines': 12, 'mode': 'rule', 'selectedProfileName': 'A',
    };
    final service = <String, dynamic>{
      'status': 'Stopped', 'startedAt': 0, 'uploadTotal': 0, 'downloadTotal': 0,
      'connections': 0, 'memory': 0, 'goroutines': 0, 'mode': 'global', 'selectedProfileName': 'B',
    };
    final merged = BoxController.mergeDashboard(driver, service, channelIsStale: true);
    expect(merged['status'], 'Started');
    expect(merged['uploadTotal'], 4096);
    expect(merged['connections'], 7);
    // The channel still owns what it persists: the mode and the selected profile.
    expect(merged['mode'], 'global');
    expect(merged['selectedProfileName'], 'B');
    // A fresh channel copy is used as-is, and nothing is copied.
    expect(BoxController.mergeDashboard(driver, service, channelIsStale: false), same(service));
  });

  test('the driver\'s own dashboard is never merged away', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    box.debugDriverActive = true;

    box.handleEvent({'type': 'dashboard', 'value': {'status': 'Started', 'uploadTotal': 4096, 'mode': 'rule'}}, fromDriver: true);
    expect(box.dashboard['status'], 'Started');
    expect(box.dashboard['uploadTotal'], 4096);

    // A second later the service reports its own zeros. They must not land, or every figure
    // on the home cards stops moving — which is what merging both sources did.
    box.handleEvent({'type': 'dashboard', 'value': {'status': 'Stopped', 'uploadTotal': 0, 'mode': 'global'}});
    expect(box.dashboard['status'], 'Started');
    expect(box.dashboard['uploadTotal'], 4096);
    expect(box.dashboard['mode'], 'global');

    box.handleEvent({'type': 'rates', 'value': {'upload': 0, 'download': 0}});
    expect(box.rates, isEmpty);
    box.handleEvent({'type': 'rates', 'value': {'upload': 1024, 'download': 2048}}, fromDriver: true);
    expect(box.rates['upload'], 1024);
  });

  test('a driver dashboard event keeps the channel-owned selection and mode', () async {
    // The service engine's wire carries only its live fields (its host
    // snapshot is empty — ServiceBridgeClient.dashboard). Wholesale
    // replacement made selectedProfileId/mode flap between the two 1 Hz feeds:
    // the card's route stamp changed every other event and the egress probe
    // re-ran forever (the IP flicker).
    messenger.setMockMethodCallHandler(channel,
        (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    await box.initialize();
    box.debugDriverActive = true;

    box.handleEvent({'type': 'dashboard', 'value': {
      'status': 'Stopped', 'selectedProfileId': 7, 'mode': 'global',
    }});
    box.handleEvent({'type': 'dashboard', 'value': {
      'status': 'Started', 'startedAt': 1234, 'uploadTotal': 10,
    }}, fromDriver: true);
    expect(box.dashboard['status'], 'Started');
    expect(box.dashboard['startedAt'], 1234);
    expect(box.dashboard['uploadTotal'], 10);
    expect(box.dashboard['selectedProfileId'], 7,
        reason: 'the selection is channel-owned and must survive driver events');
    expect(box.dashboard['mode'], 'global',
        reason: 'the mode is channel-owned and must survive driver events');
  });

  test('a late kernel connect cannot leave driver events undelivered', () async {
    // The dead speed card: a connect that succeeded outside initialize (the
    // start call's own connect) left a live proxy with no event listener —
    // every driver event was dropped by the broadcast controller while
    // `active` still reported true. The listener must already exist when the
    // first connect fails, and attachKernel must deliver from any late connect.
    messenger.setMockMethodCallHandler(channel,
        (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    final kernel = _FakeKernel()
      ..connectBehavior = () async => throw StateError('the engine is still booting');
    final recovered = BoxController(channel: channel, events: events.stream, kernelControl: kernel);
    addTearDown(recovered.dispose);
    await recovered.initialize();
    expect(recovered.speedDiagnostics['eventsAttached'], isTrue,
        reason: 'the listener must be installed even when the first connect fails');

    // The start path connects later; every driver event must be delivered.
    kernel.connectBehavior = null;
    await recovered.attachKernel();
    kernel.emit({'type': 'rates', 'value': {'upload': 1024, 'download': 2048}});
    await Future<void>.delayed(Duration.zero);
    expect(recovered.speedDiagnostics['events'], 1);
    expect(recovered.rates['upload'], 1024);
  });

  test('an unanswered start rethrows; a refusal answers false', () async {
    messenger.setMockMethodCallHandler(channel, (_) async =>
        {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    final kernel = _FakeKernel();
    final box = BoxController(
      channel: channel,
      events: events.stream,
      kernelControl: kernel,
    );
    addTearDown(box.dispose);
    await box.initialize();

    // No answer: the start card keeps its optimistic shape and the heartbeat
    // recovery converges, so the failure must reach it as a throw.
    kernel.startBehavior = () async => throw const KernelProxyException(
      'the kernel service did not answer "start"',
      unanswered: true,
    );
    await expectLater(
      box.serviceStart(),
      throwsA(isA<KernelProxyException>()),
      reason: 'an unanswered start must not be flattened into a refusal',
    );

    // A refusal keeps the old contract: reported, answered false, rolled back.
    kernel.startBehavior = () async =>
        throw const KernelProxyException('the profile is gone');
    expect(await box.serviceStart(), isFalse);
  });
}

/// A transport-level fake: [connect] is scriptable so the "engine still
/// booting" window can be simulated; events arrive through [emit].
class _FakeKernel implements KernelControl {
  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  Future<void> Function()? connectBehavior;

  void emit(Map<String, dynamic> event) => _controller.add(event);

  @override
  Future<void> connect({Duration timeout = Duration.zero}) async {
    final behavior = connectBehavior;
    if (behavior != null) await behavior();
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> startService() async {
    final behavior = startBehavior;
    if (behavior != null) await behavior();
  }

  /// Scriptable start failure, for the answered/unanswered split.
  Future<void> Function()? startBehavior;
  @override
  Future<void> stopService() async {}
  @override
  Future<void> setKernelLogsVisible(bool visible) async {}
  @override
  Future<void> reloadService({String reason = 'reload'}) async {}
  @override
  Future<void> stopCoreFromHost() async {}
  @override
  Future<void> updateWifiState() async {}
  @override
  Future<void> setMode(String mode) async {}
  @override
  Future<void> onSelectionChanged() async {}

  @override
  bool get active => false;
  @override
  KernelPhase get kernelPhase => KernelPhase.idle;
  @override
  Duration? get uptime => null;
  @override
  bool get ffiMode => true;
  @override
  bool get driverReady => true;
  @override
  bool get remote => false;
  @override
  ActionInvoker? get attached => null;
  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;
  @override
  void dispose() {
    _controller.close();
  }
}
