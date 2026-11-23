// ADR 0005 phase 3 acceptance: the route list and the current-route selection
// live on the action bus (Go is the sole document writer), and switching the
// current route must be followed by a config build that reads the new set.
// With no FFI driver the error must be visible, never a stale channel answer.
//
// The fake kernel stands in for the Go dispatcher; the fake method channel
// stands in for the host's `state.setCurrentRoute` / `config.build` arms.
//
// The bus is attached on demand: opening Routing before the tunnel is up is a
// normal state (the prewarmed service engine opens the FFI driver without a
// box), so a route read must connect and then run — never ask for a VPN start.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/box.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_route_kernel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('route list and current route come from the action bus', (tester) async {
    const channel = MethodChannel('test.routes-bus');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final hostCalls = <String>[];
    int hostSelected = 0;

    messenger.setMockMethodCallHandler(channel, (call) async {
      hostCalls.add(call.method);
      switch (call.method) {
        case 'ready':
          return {
            'version': 'test',
            'coreVersion': 'test',
            'preferences': {'locale': 'en'},
            'dashboard': {'status': 'Stopped'},
          };
        case 'data.documents':
          // The one-time Room -> JSON seed still runs on attach (ADR 0002
          // phase 3c upgrade path); it is not a route read.
          return {'seeded': true};
        case 'state.setCurrentRoute':
          hostSelected = ((call.arguments as Map?)?['id'] as num?)?.toInt() ?? 0;
          return {'id': hostSelected};
        case 'config.build':
          // The host resolves the selected route itself; no id is sent.
          expect(((call.arguments as Map?) ?? const {})['id'], isNull);
          return {'coreConfig': '{}'};
        case 'service.reload':
          return null;
        default:
          return null;
      }
    });

    final busCalls = <ActionMethod>[];
    Map<String, Object?> currentWire() => {
          'currentId': hostSelected == 0 ? 1 : hostSelected,
          'profiles': [
            {'id': 1, 'name': 'Default', 'current': hostSelected == 0},
            {'id': 2, 'name': 'Alternate', 'current': hostSelected == 2},
          ],
        };

    final box = BoxController(channel: channel, events: Stream<dynamic>.empty());
    addTearDown(box.dispose);
    box.debugAttach(
      FakeRouteKernel((method, data) {
        busCalls.add(method);
        switch (method) {
          case ActionMethod.getRouteProfiles:
            return currentWire();
          case ActionMethod.setCurrentRoute:
            // The bare Go action only moves the document marker; a UI tap goes
            // through the host pair instead, so this must not be reached.
            fail('the bare setCurrentRoute action must not be used by the UI');
          default:
            return null;
        }
      }),
      NoopKernelWorker(),
    );

    // The bus answers the list; no routes.list channel arm is consulted.
    final list = await box.routeList();
    expect(busCalls, contains(ActionMethod.getRouteProfiles));
    expect(hostCalls, isNot(contains('routes.list')));
    expect((list as Map)['profiles'], hasLength(2));

    // A UI selection takes the host path, then a config build reads the new set.
    await box.routeSetCurrentHost(2);
    expect(hostSelected, 2, reason: 'the host writes the settings row the build reads');
    await box.call('config.build');
    expect(hostCalls, contains('config.build'));
    expect(hostCalls, contains('state.setCurrentRoute'));
    expect(busCalls, isNot(contains(ActionMethod.setCurrentRoute)),
        reason: 'the bare action would leave the authoritative Room row stale');
  });

  testWidgets('the route store attaches on demand without starting the tunnel', (tester) async {
    const channel = MethodChannel('test.routes-attach');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final hostCalls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      hostCalls.add(call.method);
      if (call.method == 'routes.list') fail('routes.list channel fallback must be gone');
      if (call.method == 'service.start') fail('routing must not start the tunnel');
      return null;
    });

    final bus = _RecordingBus();
    final kernel = _AttachOnConnectKernel(() => bus);
    final box = BoxController(
      channel: channel,
      events: Stream<dynamic>.empty(),
      kernelControl: kernel,
    );
    addTearDown(box.dispose);

    // Before any connect there is no bus; the call attaches one first.
    expect(box.kernel.attached, isNull);
    final list = await box.routeList();

    expect(kernel.connectCalls, 1, reason: 'the read attached the bus itself');
    expect(kernel.lastConnectTimeout, BoxController.kernelAttachTimeout,
        reason: 'the on-demand attach waits for the engine prewarm window');
    expect(kernel.startCalls, 0, reason: 'attaching is not starting the box');
    expect((list as Map)['profiles'], hasLength(1));
    expect(bus.calls, contains(ActionMethod.getRouteProfiles));
    expect(hostCalls, isNot(contains('service.start')));
  });

  testWidgets('an engine that never appears answers a retryable typed error', (tester) async {
    const channel = MethodChannel('test.routes-noengine');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final hostCalls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      hostCalls.add(call.method);
      return null;
    });

    // The engine is still booting: connect throws, and nothing ever attaches.
    final kernel = _AttachOnConnectKernel(null)
      ..connectError = const KernelProxyException(
        'the kernel service engine is not available',
        unanswered: true,
      );
    final box = BoxController(
      channel: channel,
      events: Stream<dynamic>.empty(),
      kernelControl: kernel,
    );
    addTearDown(box.dispose);

    Object? caught;
    try {
      await box.routeList();
    } catch (error) {
      caught = error;
    }

    // Typed and retryable — not a bare StateError, and not a demand to start
    // the VPN, which routing never needed.
    expect(caught, isA<KernelProxyException>());
    final refusal = caught! as KernelProxyException;
    expect(refusal.unanswered, isTrue,
        reason: 'the engine was not reachable; the caller may retry');

    // What the routing screen shows: the sentence, without a class prefix.
    final text = BoxController.describe(refusal);
    expect(text, contains('Try routing again'));
    expect(text.toLowerCase(), isNot(contains('vpn')));
    expect(text, isNot(contains('StateError')));
    expect(text, isNot(contains('Bad state')));
    expect(text, isNot(contains('KernelProxyException')));
    expect(hostCalls, isNot(contains('service.start')));
  });

  test('an already attached bus is used without connecting', () async {
    final bus = _RecordingBus();
    final kernel = _AttachOnConnectKernel(null)..attachedBus = bus;
    final box = BoxController(
      channel: const MethodChannel('test.routes-attached'),
      events: Stream<dynamic>.empty(),
      kernelControl: kernel,
    );
    addTearDown(box.dispose);

    final list = await box.routeList();

    expect(kernel.connectCalls, 0, reason: 'a live bus is not re-attached');
    expect(bus.calls, contains(ActionMethod.getRouteProfiles));
    expect((list as Map)['profiles'], hasLength(1));
  });

  test('no FFI driver: routeList surfaces a clear error, never a channel fallback', () async {
    const channel = MethodChannel('test.routes-noffi');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'routes.list') {
        fail('routes.list channel fallback must be gone');
      }
      return null;
    });

    final box = BoxController(channel: channel, events: Stream<dynamic>.empty());
    addTearDown(box.dispose);
    // No debugAttach: the in-process driver has no attached kernel, so the
    // on-demand attach cannot produce a bus and the call must say so.

    await expectLater(
      box.routeList(),
      throwsA(isA<KernelProxyException>().having(
        (error) => error.message,
        'message',
        contains('Try routing again'),
      )),
    );
    expect(calls, isNot(contains('routes.list')));
  });
}

/// Answers the route actions and records what it was asked.
class _RecordingBus implements ActionInvoker {
  final calls = <ActionMethod>[];

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(method);
    final Object? answer = switch (method) {
      ActionMethod.getRouteProfiles => {
          'currentId': 1,
          'profiles': [
            {'id': 1, 'name': 'Default', 'current': true},
          ],
        },
      _ => null,
    };
    return answer as T;
  }
}

/// A transport fake whose [connect] is when the bus appears — exactly the UI
/// proxy against the service engine, where connecting resolves the port and
/// says hello. [startService] is counted so a test can prove it is never called.
class _AttachOnConnectKernel implements KernelControl {
  _AttachOnConnectKernel(this._busFactory);

  /// Builds the bus a successful connect publishes; null means "never attaches".
  final ActionInvoker? Function()? _busFactory;

  /// Pre-populated for the already-attached case.
  ActionInvoker? attachedBus;

  /// When set, [connect] throws it instead of attaching.
  Object? connectError;

  int connectCalls = 0;
  int startCalls = 0;
  Duration? lastConnectTimeout;

  final _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  ActionInvoker? get attached => attachedBus;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  Future<void> connect({Duration timeout = Duration.zero}) async {
    connectCalls++;
    lastConnectTimeout = timeout;
    final error = connectError;
    if (error != null) throw error;
    attachedBus ??= _busFactory?.call();
  }

  @override
  Future<void> startService() async {
    startCalls++;
  }

  @override
  void dispose() {
    unawaited(_events.close());
  }

  // Everything else (lifecycle, phase, streams) is out of this test's path.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the route tests never ${invocation.memberName}');
}
