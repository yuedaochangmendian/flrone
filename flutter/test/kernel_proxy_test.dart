// The UI-engine proxy is testable without a second Flutter engine: inject the
// three IsolateNameServer seams and stand in for the service engine with a
// ReceivePort that speaks the small map IPC from kernel_control.dart.

import 'dart:isolate';

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/core/kernel_proxy.dart';
import 'package:flrone/core/platform_value.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake service engine: one ReceivePort for UI→service requests, and a map of
/// named UI ports (populated through the injected `register` seam) it replies on.
class FakeService {
  final requests = ReceivePort();
  final uiPorts = <String, SendPort>{};
  final seen = <Map<String, dynamic>>[];

  /// Called with each request map; returns the `result` value, or throws to
  /// send an `{error: ...}` envelope.
  Future<dynamic> Function(Map<String, dynamic> request)? onRequest;

  void Function(Map<String, dynamic> event)? onEvent;

  /// When true the fake stops answering requests (but still owns the port).
  /// Simulates an engine that stopped draining its port without vanishing.
  bool dropReplies = false;

  /// When set, the hello reply carries this status (the engine's current
  /// state); when null the reply omits the `status` key.
  String? helloStatus;

  /// Carried on the hello reply as `driverReady` (the engine's real FFI-attach
  /// state). Defaults to true — the historical `ffiMode == connected` world.
  bool helloDriverReady = true;

  late final KernelProxy proxy;

  FakeService() {
    proxy = KernelProxy(
      lookup: (name) => name == servicePortName ? requests.sendPort : null,
      register: (port, name) => uiPorts[name] = port,
      remove: (name) {
        uiPorts.remove(name);
        return true;
      },
      retryDelay: Duration.zero,
      retryCount: 0,
    );
    requests.listen((raw) async {
      final message = normalizePlatformValue(raw);
      if (message is! Map<String, dynamic>) return;
      seen.add(message);
      final id = message['id'] as String?;
      final method = message['method'] as String?;
      if (id == null || method == null) return;
      if (dropReplies && method != 'hello') return;

      if (method == 'hello') {
        final port = (message['data'] as Map)['port'] as int;
        uiPorts.putIfAbsent(uiPortName(port), () => throw StateError('UI port $port was not registered'));
        final status = helloStatus;
        _reply(id, <String, dynamic>{
          'ok': true,
          'status': ?status,
          'driverReady': helloDriverReady,
        });
        return;
      }
      try {
        final result = await onRequest?.call(message);
        _reply(id, result);
      } catch (error) {
        _replyError(id, error);
      }
    });
  }

  void _reply(String id, dynamic result) {
    _send(<String, dynamic>{
      'id': id,
      'result': <String, dynamic>{'result': result},
    });
  }

  void _replyError(String id, Object error) {
    _send(<String, dynamic>{
      'id': id,
      'result': <String, dynamic>{'error': '$error'},
    });
  }

  void _send(Object? message) {
    for (final port in uiPorts.values) {
      port.send(message);
    }
  }

  /// Pushes an event to the UI engine (service→UI `{'type':'event',...}`).
  void pushEvent(Map<String, dynamic> event) {
    _send(<String, dynamic>{'type': 'event', 'value': event});
  }

  void close() {
    requests.close();
    proxy.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('requests correlate with their replies by id', () async {
    final service = FakeService();
    addTearDown(service.close);
    service.onRequest = (request) async {
      switch (request['method']) {
        case 'start':
          return 'started';
        case 'stop':
          return 'stopped';
        case 'setMode':
          return (request['data'] as Map)['mode'];
        default:
          return null;
      }
    };

    await service.proxy.connect();
    await service.proxy.startService();
    await service.proxy.setMode('global');
    await service.proxy.stopService();

    // The hello handshake ran first, then three distinct requests; each reply
    // completed exactly its own Future (no cross-talk, no dropped requests).
    expect(service.seen.map((m) => m['method']).toList(), [
      'hello', 'start', 'setMode', 'stop',
    ]);
    expect(
      service.seen.where((m) => m['method'] == 'setMode').single['data'],
      {'mode': 'global'},
    );
  });

  test('service errors surface as readable exceptions', () async {
    final service = FakeService();
    addTearDown(service.close);
    service.onRequest = (request) async {
      if (request['method'] == 'start') {
        throw StateError('vpn refused');
      }
      return null;
    };

    await service.proxy.connect();
    await expectLater(
      service.proxy.startService(),
      throwsA(isA<KernelProxyException>().having(
        (e) => e.message,
        'message',
        contains('vpn refused'),
      )),
    );
  });

  test('a completed start is not repeated but a recovery start still is', () async {
    final service = FakeService();
    addTearDown(service.close);
    service.helloStatus = 'Started';

    await service.proxy.connect();
    await service.proxy.startService();

    expect(
      service.seen.where((m) => m['method'] == 'start'),
      isEmpty,
      reason: 'the attach hello already reported a completed engine-owned start',
    );

    service.pushEvent({
      'type': 'dashboard',
      'value': {'status': 'Stopped'},
    });
    await pumpEventQueue();
    await service.proxy.startService();
    expect(
      service.seen.where((m) => m['method'] == 'start'),
      hasLength(1),
      reason: 'a later user start still reaches the engine',
    );

    service.pushEvent({
      'type': 'dashboard',
      'value': {'status': 'Starting'},
    });
    await pumpEventQueue();
    await service.proxy.startService();
    expect(
      service.seen.where((m) => m['method'] == 'start'),
      hasLength(2),
      reason: 'Starting also means a lost core, so a manual start must pass',
    );
  });

  test('events are forwarded to the UI as a broadcast stream', () async {
    final service = FakeService();
    addTearDown(service.close);
    await service.proxy.connect();

    final events = <Map<String, dynamic>>[];
    final sub = service.proxy.events.listen(events.add);
    addTearDown(sub.cancel);

    service.pushEvent(<String, dynamic>{
      'type': 'dashboard',
      'value': <String, dynamic>{'status': 'Started'},
    });
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single['type'], 'dashboard');
    expect((events.single['value'] as Map)['status'], 'Started');
    // A Started dashboard makes the proxy report the tunnel active.
    expect(service.proxy.active, isTrue);
  });

  test('every call fails loudly when the service engine is absent', () async {
    // No port is ever published under servicePortName.
    final proxy = KernelProxy(
      lookup: (_) => null,
      register: (_, _) {},
      remove: (_) => true,
      retryDelay: Duration.zero,
      retryCount: 0,
    );
    addTearDown(proxy.dispose);

    await expectLater(
      proxy.connect(),
      throwsA(isA<KernelProxyException>().having(
        (e) => e.message,
        'message',
        contains('not available'),
      )),
    );
    // Never silently succeeds: a start on an unconnected proxy throws too.
    await expectLater(proxy.startService(), throwsA(isA<KernelProxyException>()));
    expect(proxy.attached, isNull);
  });

  test('the action bus forwards the Action JSON wire', () async {
    final service = FakeService();
    addTearDown(service.close);
    Object? received;
    service.onRequest = (request) async {
      if (request['method'] == 'action') {
        received = request['data'];
        return {'nodes': [1, 2]};
      }
      return null;
    };

    await service.proxy.connect();
    final result = await service.proxy.attached!.invoke<Object?>(
      ActionMethod.groupNodes,
    );

    expect(received, isA<String>());
    final wire = received as String;
    final action = decodeWire(wire);
    expect(action['method'], ActionMethod.groupNodes.name);
    expect(action['id'], isNotEmpty);
    expect(result, {'nodes': [1, 2]});
  });

  test('a disposed proxy unregisters its port and closes the stream', () async {
    final service = FakeService();
    final portsBefore = service.uiPorts.length;
    await service.proxy.connect();
    expect(service.uiPorts.length, greaterThan(portsBefore));

    service.proxy.dispose();
    expect(service.uiPorts, isEmpty);
    expect(service.proxy.ffiMode, isFalse);
  });

  test('the hello reply resyncs the proxy status from the engine', () async {
    final service = FakeService();
    addTearDown(service.close);
    service.helloStatus = 'Started';

    await service.proxy.connect();

    // No dashboard event needed: the engine answers the handshake with its
    // current state, so a (re)connect cannot trust the last event of a
    // previous link — the stale-`active` bug this pins.
    expect(service.proxy.active, isTrue);
    // An older peer answers the bare `true`; the status then stays 'Stopped'
    // until an event arrives (covered by the broadcast test above).
  });

  test('hello reconnects when the service port appears after a retry', () async {
    final service = FakeService();
    addTearDown(service.close);
    var lookups = 0;
    // The service engine starts slightly after the UI: the first two lookups
    // miss, the third finds the port — the Bettbox `_waitForIpc` cadence.
    final proxy = KernelProxy(
      lookup: (name) {
        lookups++;
        return lookups >= 3 && name == servicePortName
            ? service.requests.sendPort
            : null;
      },
      register: (port, name) => service.uiPorts[name] = port,
      remove: (name) {
        service.uiPorts.remove(name);
        return true;
      },
      retryDelay: Duration.zero,
      retryCount: 3,
    );
    addTearDown(proxy.dispose);

    await proxy.connect();

    expect(lookups, 3);
    expect(proxy.ffiMode, isTrue);
    // The hello reached the service and carried the UI's native port.
    expect(
      service.seen.where((m) => m['method'] == 'hello'),
      hasLength(1),
    );
  });

  test('timeout keeps sticky ownership with a Starting status', () async {
    // A request that times out means the engine stopped draining its port. The
    // link is down but the core may still be running in that engine; the channel
    // must not reclaim the dashboard in the gap before a reconnect resyncs.
    final service = FakeService();
    addTearDown(service.close);
    service.helloStatus = 'Started';
    await service.proxy.connect();
    expect(service.proxy.active, isTrue);
    expect(service.proxy.driverReady, isTrue);

    // Shorten the request timeout only after the hello succeeded, so the
    // handshake itself is unaffected.
    service.proxy.requestTimeoutOverride = const Duration(milliseconds: 10);
    service.dropReplies = true;
    await expectLater(
      service.proxy.setMode('global'),
      throwsA(isA<KernelProxyException>()),
    );

    // Sticky: ffiMode/active stay true and the status is the transitional
    // 'Starting', holding box.dart's arbitration through the outage.
    expect(service.proxy.ffiMode, isTrue);
    expect(service.proxy.active, isTrue);
    expect(service.proxy.statusWire, 'Starting');
  });

  test('reconnect hello with driverReady=false releases ownership', () async {
    // The service engine was recreated without the FFI driver attached. Its
    // hello answers driverReady=false, so a stale proxy must hand arbitration
    // back to the channel instead of masking it forever.
    final service = FakeService();
    addTearDown(service.close);
    service.helloStatus = 'Started';
    await service.proxy.connect();

    service.proxy.requestTimeoutOverride = const Duration(milliseconds: 10);
    service.dropReplies = true;
    await expectLater(
      service.proxy.setMode('global'),
      throwsA(isA<KernelProxyException>()),
    );
    expect(service.proxy.active, isTrue, reason: 'sticky through the outage');

    // The replacement engine has no driver: it answers the reconnect hello
    // with driverReady=false. Drive the reconnect directly (the timer seam is
    // unnecessary here) by restoring replies and reconnecting.
    service.dropReplies = false;
    service.helloDriverReady = false;
    service.helloStatus = 'Stopped';
    await service.proxy.connect();

    expect(service.proxy.ffiMode, isFalse);
    expect(service.proxy.active, isFalse);
    expect(service.proxy.driverReady, isFalse);
    expect(service.proxy.statusWire, 'Stopped');
  });

  test('reconnect hello with driverReady=true resyncs a real driver', () async {
    final service = FakeService();
    addTearDown(service.close);
    service.helloStatus = 'Started';
    await service.proxy.connect();

    service.proxy.requestTimeoutOverride = const Duration(milliseconds: 10);
    service.dropReplies = true;
    await expectLater(
      service.proxy.setMode('global'),
      throwsA(isA<KernelProxyException>()),
    );
    expect(service.proxy.statusWire, 'Starting');

    // Reconnect to the same engine still driving the core: a fresh hello
    // resyncs the real status ('Started') instead of the transitional one.
    service.dropReplies = false;
    service.helloStatus = 'Started';
    service.helloDriverReady = true;
    await service.proxy.connect();

    expect(service.proxy.ffiMode, isTrue);
    expect(service.proxy.active, isTrue);
    expect(service.proxy.statusWire, 'Started');
  });

  test('exhausted reconnect attempts release ownership terminally', () async {
    // Sticky ownership is bounded: give up after the reconnect cap and publish
    // a synthetic Stopped dashboard so the UI snapshot agrees with handover.
    final service = FakeService();
    addTearDown(service.close);
    service.helloStatus = 'Started';
    final proxy = KernelProxy(
      lookup: (name) => name == servicePortName ? service.requests.sendPort : null,
      register: (port, name) => service.uiPorts[name] = port,
      remove: (name) {
        service.uiPorts.remove(name);
        return true;
      },
      retryDelay: Duration.zero,
      retryCount: 0,
      reconnectDelay: Duration.zero,
    );
    addTearDown(proxy.dispose);
    // Rebind the fake's hello to this proxy's registered port (the FakeService's
    // own proxy is unused here; both share the same port map).
    await proxy.connect();

    proxy.requestTimeoutOverride = const Duration(milliseconds: 10);

    // Subscribe before the failure path can start. The give-up publishes the
    // synthetic Stopped from a zero-delay retry chain, and a listener attached
    // afterwards could miss it entirely (that race failed this test on CI).
    final stoppedDashboard = proxy.events.firstWhere(
      (event) =>
          event['type'] == 'dashboard' &&
          (event['value'] as Map<String, dynamic>)['status'] == 'Stopped',
    );

    service.dropReplies = true;
    await expectLater(
      proxy.setMode('global'),
      throwsA(isA<KernelProxyException>()),
    );
    expect(proxy.active, isTrue);

    // Each reconnect attempt re-sends hello (which the fake still answers), so
    // it would succeed and reset the attempt counter. Make hello fail too by
    // dropping every message, forcing the retry chain to exhaust.
    service.requests.close();
    // Await the terminal event instead of polling `active`: the broadcast
    // delivery and the poll loop's timers race, and the loop can exit on the
    // state flip before the event has been delivered (also seen on CI).
    await stoppedDashboard.timeout(const Duration(seconds: 5));

    expect(proxy.active, isFalse, reason: 'the sticky limit releases ownership');
    expect(proxy.ffiMode, isFalse);
    expect(proxy.statusWire, 'Stopped');
  });

  test('the driver stays authoritative through Starting and Stopping', () async {
    // `active` gates the dashboard arbitration: while it was 'Started'-only the
    // channel's 1 Hz dashboard wholesale-replaced the driver's Starting state
    // and flipped the start button's morph target mid-flight.
    final service = FakeService();
    addTearDown(service.close);
    service.helloStatus = 'Started';
    await service.proxy.connect();
    expect(service.proxy.active, isTrue);

    service.pushEvent({
      'type': 'dashboard',
      'value': {'status': 'Starting'},
    });
    await pumpEventQueue();
    expect(service.proxy.active, isTrue, reason: 'Starting keeps driver ownership');

    service.pushEvent({
      'type': 'dashboard',
      'value': {'status': 'Stopping'},
    });
    await pumpEventQueue();
    expect(service.proxy.active, isTrue, reason: 'Stopping keeps driver ownership');

    service.pushEvent({
      'type': 'dashboard',
      'value': {'status': 'Stopped'},
    });
    await pumpEventQueue();
    expect(service.proxy.active, isFalse);
  });
}

Map<String, dynamic> decodeWire(String raw) {
  // Local decode avoids importing dart:convert just for one assertion.
  final decoded = ActionResult.decode(raw);
  return <String, dynamic>{
    'method': decoded?.method ?? '',
    'id': decoded?.id ?? '',
  };
}
