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

  /// When set, the hello reply carries this status (the engine's current
  /// state); when null the reply is the old bare `true`.
  String? helloStatus;

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

      if (method == 'hello') {
        final port = (message['data'] as Map)['port'] as int;
        uiPorts.putIfAbsent(uiPortName(port), () => throw StateError('UI port $port was not registered'));
        final status = helloStatus;
        _reply(id, status == null ? true : <String, dynamic>{'ok': true, 'status': status});
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
