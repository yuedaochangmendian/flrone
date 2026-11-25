// ADR 0002 phase 3 acceptance: the one global rule table lives on the action
// bus (Go is the sole document writer). With no FFI driver the error must be
// visible, never a stale channel answer.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the global rule table attaches on demand without starting the tunnel', (tester) async {
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

    expect(box.kernel.attached, isNull);
    final rules = await box.routeGlobalRules();

    expect(kernel.connectCalls, 1, reason: 'the read attached the bus itself');
    expect(kernel.lastConnectTimeout, BoxController.kernelAttachTimeout,
        reason: 'the on-demand attach waits for the engine prewarm window');
    expect(kernel.startCalls, 0, reason: 'attaching is not starting the box');
    expect((rules as Map)['rules'], hasLength(1));
    expect(bus.calls, contains(ActionMethod.getGlobalRules));
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
      await box.routeGlobalRules();
    } catch (error) {
      caught = error;
    }

    expect(caught, isA<KernelProxyException>());
    final refusal = caught! as KernelProxyException;
    expect(refusal.unanswered, isTrue,
        reason: 'the engine was not reachable; the caller may retry');

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

    final rules = await box.routeGlobalRules();

    expect(kernel.connectCalls, 0, reason: 'a live bus is not re-attached');
    expect(bus.calls, contains(ActionMethod.getGlobalRules));
    expect((rules as Map)['rules'], hasLength(1));
  });

  test('no FFI driver: routeGlobalRules surfaces a clear error, never a channel fallback', () async {
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

    await expectLater(
      box.routeGlobalRules(),
      throwsA(isA<KernelProxyException>().having(
        (error) => error.message,
        'message',
        contains('Try routing again'),
      )),
    );
    expect(calls, isNot(contains('routes.list')));
  });
}

/// Answers the global rule actions and records what it was asked.
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
      ActionMethod.getGlobalRules => {
          'rules': [
            {'id': 1, 'name': 'Default', 'action': 'route'},
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

  final ActionInvoker? Function()? _busFactory;
  ActionInvoker? attachedBus;
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

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('the route tests never ${invocation.memberName}');
}
