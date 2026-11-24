import 'dart:async';
import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
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

  test('ruleSets event sets state and notifies watchers', () {
    var notified = 0;
    box.addListener(() => notified++);

    box.handleEvent({
      'type': 'ruleSets',
      'value': {'updated': 5, 'error': '', 'at': 1700000000000},
    });
    expect(box.ruleSetsStatus['updated'], 5);
    expect(box.ruleSetsStatus['error'], '');
    expect(box.ruleSetsStatus['at'], 1700000000000);
    expect(notified, 1, reason: 'a ruleSets event dispatches its own aspect');

    // A later attempt replaces the whole status, including the error text.
    box.handleEvent({
      'type': 'ruleSets',
      'value': {'updated': 2, 'error': 'timeout', 'at': 1700000060000},
    });
    expect(box.ruleSetsStatus['updated'], 2);
    expect(box.ruleSetsStatus['error'], 'timeout');
    expect(notified, 2);
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

  /// A bulk feed's wire shape: one StandardMessageCodec message in a byte array
  /// (`ThroneBoxBridge.emitBulk` / `BulkWire`).
  Uint8List codecBytes(Object? value) {
    final data = const StandardMessageCodec().encodeMessage(value)!;
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  testWidgets('a bulk feed arrives encoded and lands in the same state', (tester) async {
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
    final bulkBox = BoxController(channel: channel, events: events.stream, kernelControl: kernel);
    addTearDown(bulkBox.dispose);
    await bulkBox.initialize();

    kernel.emit({
      'type': 'connections',
      'value': codecBytes([
        {'id': '1', 'network': 'tcp', 'uploadTotal': 10},
      ]),
    });
    kernel.emit({
      'type': 'logcat',
      'value': codecBytes({
        'entries': [
          {'id': 1, 'level': 'info', 'message': 'first'},
          {'id': 2, 'level': 'warn', 'message': 'second'},
        ],
        'reset': true,
      }),
    });
    await tester.pump();
    await tester.pump(BoxController.batchWindow + const Duration(milliseconds: 1));
    expect(bulkBox.connections.single['id'], '1');
    expect(bulkBox.logcat.map((entry) => entry['message']), ['first', 'second']);
    expect(bulkBox.logcat.map((entry) => entry['seq']), [1, 2]);
  });

  // Lets the bulk lane's queued decode run: `_enqueueBulk` chains on a Future, so the field
  // is settled one event-loop turn after `handleEvent`, not inside it.
  Future<void> bulkSettled() => Future<void>.delayed(const Duration(milliseconds: 1));

  // The Proxies screen's node rows ride the bulk lane while it is open; every other screen
  // gets the counts-only map on the ordinary path. Both must land in the same field.
  test('encoded group rows land in groups', () async {
    box.handleEvent({
      'type': 'groups',
      'value': codecBytes([
        {
          'id': 7,
          'tag': 'Primary',
          'nodeCount': 2,
          'items': [
            {'id': 70, 'tag': '香港 01', 'type': 'vless', 'delay': 40, 'testedAt': 1},
            {'id': 71, 'tag': '东京 01', 'type': 'shadowsocks', 'delay': 0, 'testedAt': 0},
          ],
        },
      ]),
    });
    await bulkSettled();

    expect(box.groups, hasLength(1));
    expect(box.groups.single['tag'], 'Primary');
    expect((box.groups.single['items'] as List).map((node) => node['id']), [70, 71]);
  });

  test('the counts-only group map still applies', () {
    box.handleEvent({
      'type': 'groups',
      'value': [
        {'id': 7, 'tag': 'Primary', 'nodeCount': 3, 'items': <Object?>[]},
      ],
    });

    expect(box.groups.single['nodeCount'], 3);
    expect(box.groups.single['items'], isEmpty);
  });

  test('rows, then counts, then rows again each apply', () async {
    final rows = [
      {
        'id': 7,
        'tag': 'Primary',
        'nodeCount': 1,
        'items': [
          {'id': 70, 'tag': '香港 01', 'type': 'vless', 'delay': 40, 'testedAt': 1},
        ],
      },
    ];
    final counts = [
      {'id': 7, 'tag': 'Primary', 'nodeCount': 1, 'items': <Object?>[]},
    ];

    // Proxies opens: rows on the bulk lane.
    box.handleEvent({'type': 'groups', 'value': codecBytes(rows)});
    await bulkSettled();
    expect(box.groups.single['items'], hasLength(1), reason: 'rows arrived');

    // It closes: the host switches back to the counts map on the priority lane.
    // The rows are kept while the count still describes them, so returning to
    // the tab cannot paint an empty "No results" frame.
    box.handleEvent({'type': 'groups', 'value': counts});
    expect(box.groups.single['items'], hasLength(1),
        reason: 'a counts-only frame keeps rows whose nodeCount is unchanged');

    // A changed count has no valid rows to keep: wait for the bulk frame.
    box.handleEvent({
      'type': 'groups',
      'value': [
        {'id': 7, 'tag': 'Primary', 'nodeCount': 2, 'items': <Object?>[]},
      ],
    });
    expect(box.groups.single['items'], isEmpty,
        reason: 'a changed nodeCount drops the stale rows');

    // Reopening sends rows again; the lane mix must not leave the screen on counts.
    box.handleEvent({'type': 'groups', 'value': codecBytes(rows)});
    await bulkSettled();
    expect(box.groups.single['items'], hasLength(1));
  });

  test('a node-row payload above the threshold survives the isolate hop', () async {
    // 800 nodes ≈ 85 KiB on the wire, the shape a large catalog produces for the Proxies
    // screen; decoded with the same top-level function `_enqueueBulk` awaits for it.
    final value = [
      for (var group = 0; group < 20; group++)
        {
          'id': group,
          'tag': 'group $group',
          'nodeCount': 40,
          'items': [
            for (var node = 0; node < 40; node++)
              {
                'id': group * 1000 + node,
                'tag': 'node $group/$node',
                'type': 'vless',
                'delay': 40,
                'testedAt': 1793030400000,
              },
          ],
        },
    ];
    final bytes = codecBytes(value);
    expect(bytes.length, greaterThan(bulkDecodeBytes));

    final decoded = await decodeBulkPayloadIsolated(bytes) as List;
    expect(decoded, equals(decodeBulkPayload(bytes)));
    expect((decoded.last as Map)['items'], hasLength(40));
  });

  test('a payload above the threshold decodes in another isolate', () async {
    // The same expression BoxController uses for a large batch: the codec and typed-data
    // payload must survive the isolate hop (the widget-test clock cannot drive this branch).
    final value = {
      'entries': [
        for (var id = 0; id < 2000; id++) {'id': id, 'level': 'info', 'message': 'line $id'},
      ],
      'reset': true,
    };
    final bytes = codecBytes(value);
    expect(bytes.length, greaterThan(bulkDecodeBytes));
    final decoded = await decodeBulkPayloadIsolated(bytes) as Map;
    expect(decoded['entries'], hasLength(2000));
    expect((decoded['entries'] as List).last['message'], 'line 1999');
  });

  test('a malformed bulk frame is dropped with one diagnostic', () async {
    final messages = <String>[];
    final sub = box.messages.listen(messages.add);
    addTearDown(sub.cancel);
    // 0xFF is not a StandardMessageCodec type: the decode throws "Message corrupted".
    box.handleEvent({'type': 'connections', 'value': Uint8List.fromList([0xFF])});
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(box.connections, isEmpty);
    expect(messages, hasLength(1));
    expect(messages.single, contains('connections payload dropped'));
    // The same feed's next bad frame is not reported again.
    box.handleEvent({'type': 'connections', 'value': Uint8List.fromList([0xFF])});
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(messages, hasLength(1));
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

  test('the startup attach retries once behind the engine prewarm window', () async {
    // A launch that beats the host's prewarm has no bus at initialize (the host
    // creates the engine 3 s after Application.onCreate). The background retry
    // attaches, so Routing normally opens onto a ready bus — and attaching is
    // not starting: nothing on this path may start the tunnel.
    messenger.setMockMethodCallHandler(channel,
        (_) async => {'version': 'test', 'coreVersion': 'test', 'dashboard': {'status': 'Stopped'}});
    BoxController.kernelAttachRetryDelay = Duration.zero;
    addTearDown(() => BoxController.kernelAttachRetryDelay = const Duration(seconds: 3));
    final bus = _FakeBus();
    final kernel = _FakeKernel(remote: true);
    kernel.connectBehavior = () async {
      // The prewarmed engine answers from the second attempt on.
      if (kernel.connectCalls > 1) kernel.attachedBus = bus;
    };
    final warm = BoxController(channel: channel, events: events.stream, kernelControl: kernel);
    addTearDown(warm.dispose);

    await warm.initialize();
    expect(kernel.attached, isNull, reason: 'the first attempt ran before the prewarm');

    // The zero delay stands in for the real prewarm wait.
    await pumpEventQueue();

    expect(kernel.connectCalls, 2, reason: 'exactly one retry');
    expect(kernel.attached, same(bus));
    expect(kernel.startCalls, 0, reason: 'attaching must never start the tunnel');
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

  group('the manual resource update', () {
    /// One controller over a scripted kernel; the host channel stays silent.
    Future<(BoxController, _FakeKernel)> resources({bool running = true}) async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final kernel = _FakeKernel();
      final controller = BoxController(
        channel: channel,
        events: events.stream,
        kernelControl: kernel,
      );
      addTearDown(controller.dispose);
      controller.handleEvent({
        'type': 'dashboard',
        'value': {'status': running ? 'Started' : 'Stopped'},
      });
      return (controller, kernel);
    }

    test('refreshes the rule sets while the core runs', () async {
      final (controller, kernel) = await resources();
      kernel.updateRuleSetsBehavior = () async => {'updated': 4, 'error': ''};

      final report = await controller.updateResources();

      expect(kernel.updateRuleSetsCalls, 1);
      expect(report.ruleSetsUpdated, 4);
      expect(report.ruleSetsSkipped, isFalse);
      expect(report.clean, isTrue);
    });

    test('skips the rule sets with the tunnel stopped', () async {
      final (controller, kernel) = await resources(running: false);

      final report = await controller.updateResources();

      expect(kernel.updateRuleSetsCalls, 0, reason: 'no instance: the work is skipped, not refused');
      expect(report.ruleSetsSkipped, isTrue);
      expect(report.ruleSetsUpdated, 0);
      expect(report.clean, isTrue, reason: 'a skip is not a failure');
    });

    test('keeps the per-item failures of the core answer', () async {
      final (controller, kernel) = await resources();
      kernel.updateRuleSetsBehavior =
          () async => {'updated': 1, 'error': 'ruleset-a: timeout'};

      final report = await controller.updateResources();

      expect(report.ruleSetsUpdated, 1);
      expect(report.ruleSetsError, 'ruleset-a: timeout');
      expect(report.clean, isFalse);
    });

    test('a failed call is reported instead of thrown', () async {
      final (controller, kernel) = await resources();
      kernel.updateRuleSetsBehavior = () async =>
          throw const KernelProxyException('The core is not running; start the tunnel before updating rule sets.');

      final report = await controller.updateResources();

      expect(report.ruleSetsFailure, contains('start the tunnel'));
      expect(report.ruleSetsUpdated, 0);
      expect(report.clean, isFalse);
    });

    test('the fold ignores a malformed answer instead of throwing', () {
      final report = foldResourceUpdate(
        coreRunning: true,
        ruleSets: const {'updated': 2},
      );

      expect(report.ruleSetsUpdated, 2);
      expect(report.ruleSetsError, '');
      expect(report.clean, isTrue);
    });
  });
}

/// A transport-level fake: [connect] is scriptable so the "engine still
/// booting" window can be simulated; events arrive through [emit].
class _FakeKernel implements KernelControl {
  _FakeKernel({this.remote = false});

  final _controller = StreamController<Map<String, dynamic>>.broadcast();
  Future<void> Function()? connectBehavior;

  /// How many times [connect] ran, so the startup warm-up's one retry is
  /// observable.
  int connectCalls = 0;

  /// How many times [startService] ran: attaching must never start the box.
  int startCalls = 0;

  /// The bus a successful connect publishes (the proxy's `attached`).
  ActionInvoker? attachedBus;

  void emit(Map<String, dynamic> event) => _controller.add(event);

  @override
  Future<void> connect({Duration timeout = Duration.zero}) async {
    connectCalls++;
    final behavior = connectBehavior;
    if (behavior != null) await behavior();
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<void> startService() async {
    startCalls++;
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

  /// The manual rule-set refetch a resource update asks for; a test scripts the
  /// answer (or throws) to drive the failure split.
  Future<Map<String, dynamic>> Function()? updateRuleSetsBehavior;
  int updateRuleSetsCalls = 0;
  @override
  Future<Map<String, dynamic>> updateRuleSets() async {
    updateRuleSetsCalls++;
    final behavior = updateRuleSetsBehavior;
    if (behavior != null) return behavior();
    return const {'updated': 0, 'error': ''};
  }
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
  final bool remote;
  @override
  ActionInvoker? get attached => attachedBus;
  @override
  Stream<Map<String, dynamic>> get events => _controller.stream;
  @override
  void dispose() {
    _controller.close();
  }
}

/// An action bus that answers the route list and nothing else.
class _FakeBus implements ActionInvoker {
  final calls = <ActionMethod>[];

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(method);
    final Object? answer = method == ActionMethod.getRouteProfiles
        ? {
            'currentId': 1,
            'profiles': [
              {'id': 1, 'name': 'Default', 'current': true},
            ],
          }
        : null;
    return answer as T;
  }
}
