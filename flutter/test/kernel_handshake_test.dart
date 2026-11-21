// The kernel is owned exclusively by the service Flutter engine (`KernelService`):
// there is no UI-engine handle to hand over and no host-adopted core to take back.
// These tests drive KernelService in FFI mode with a fake worker and a mock channel,
// so the start / fail / lifecycle / status sequence runs without a native library.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_service.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A kernel that only answers the status stream the driver subscribes to. The
/// driver never reads `ffi`, `logs` or `openReply` in these paths.
class FakeKernel implements ThroneKernel {
  final statuses = StreamController<BridgeEvent>.broadcast();

  @override
  Stream<BridgeEvent> get events => statuses.stream;

  @override
  Stream<BridgeEvent> get logs => Stream<BridgeEvent>.empty();

  @override
  ThroneFFI get ffi => throw UnimplementedError('the driver never reads ffi');

  @override
  ReplyPort openReply() =>
      throw UnimplementedError('the driver never opens a reply port');

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) => throw UnimplementedError('the kernel under test never invokes an action');

  @override
  Future<dynamic> invokeWire(String wire) =>
      throw UnimplementedError('the kernel under test never invokes an action');

  @override
  Map<String, dynamic> get lastSpeedTestState => const {};

  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();

  @override
  void dispose() {}

  void emitStatus(Map<String, int> data) {
    statuses.add(<String, dynamic>{'method': 'status', 'data': data});
  }

  void close() => statuses.close();
}

/// A worker whose `createInstance` can be told to fail, so the start-failure
/// path is reachable without a real instance handle.
class FakeWorker implements KernelWorker {
  final _events = StreamController<WorkerEvent>.broadcast();

  bool failCreate = false;
  final calls = <String>[];

  @override
  Stream<WorkerEvent> get events => _events.stream;

  @override
  Future<int> createInstance(Map<String, dynamic> built) async {
    calls.add('createInstance');
    if (failCreate) throw StateError('the kernel refused the config');
    return 1;
  }

  @override
  Future<void> start() async => calls.add('start');

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> setHeartbeat(bool enabled) async => calls.add('setHeartbeat');

  @override
  Future<bool> needWifiState() async => false;

  @override
  Future<void> updateWifiState() async {}

  @override
  Future<Map<String, dynamic>?> updateRuleSets() async => null;

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _events.close();
  }

  /// Reports the core lost, the way a stalled heartbeat would.
  void lose() {
    _events.add(<String, dynamic>{'type': 'lost'});
  }
}

/// A worker whose [start] hangs until the test releases it, so a second
/// lifecycle command can land while the first one is still unwinding.
class GatedWorker extends FakeWorker {
  final startGate = Completer<void>();

  @override
  Future<void> start() async {
    calls.add('start');
    await startGate.future;
  }
}

/// One mock channel per test (the handlers are global per channel name).
class ChannelLog {
  ChannelLog(this.name);

  final String name;
  late final MethodChannel channel = MethodChannel(name);
  late BoxController box;
  final calls = <String>[];

  void install(Future<dynamic> Function(MethodCall call) handler) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return handler(call);
    });
    box = BoxController(channel: channel);
  }

  void tearDown() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, null);
    box.dispose();
  }
}

Future<dynamic> defaultReply(MethodCall call) async {
  switch (call.method) {
    case 'config.build':
      return <String, dynamic>{};
    default:
      return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('start failure takes the service down with the core', () {
    test('a refused instance stops the foreground service', () async {
      final log = ChannelLog('test.handshake.failed-core');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker()..failCreate = true;
      final service = KernelService(log.box);
      final dashboards = <String>[];
      final sub = service.events.listen((event) {
        if (event['type'] == 'dashboard') {
          dashboards.add((event['value'] as Map)['status'] as String? ?? '');
        }
      });
      addTearDown(sub.cancel);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      await service.startService();
      // `_events` is an async broadcast controller: the final dashboard event
      // is queued, not yet delivered, when startService() returns.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(log.calls, contains('service.start'));
      expect(log.calls, contains('config.build'));
      expect(
        log.calls.where((method) => method == 'service.stop'),
        hasLength(1),
        reason: 'ffiMode announces Connected before any core exists; a failed '
            'build must take the service down with it',
      );
      expect(dashboards, isNotEmpty);
      expect(dashboards.last, 'Stopped');
      expect(service.active, isFalse);
    });

    test('a refused VPN does not wait for a slow config build', () async {
      final log = ChannelLog('test.handshake.refused-vpn');
      final configGate = Completer<Map<String, dynamic>>();
      log.install((call) async {
        if (call.method == 'service.start') {
          throw PlatformException(code: 'vpn_refused');
        }
        if (call.method == 'config.build') return configGate.future;
        return null;
      });
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
        if (!configGate.isCompleted) {
          configGate.complete(<String, dynamic>{});
        }
      });

      await service.startService();

      expect(configGate.isCompleted, isFalse,
          reason: 'the start failed before the slow build was awaited');
      expect(log.calls, contains('service.stop'));
      expect(service.active, isFalse);
    });
  });

  group('lifecycle serialization', () {
    test('a reload behind an unwinding start restarts the live instance',
        () async {
      final log = ChannelLog('test.handshake.reload-behind-start');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = GatedWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      final startDone = service.startService();
      final reloadDone = service.reloadService(reason: 'test');
      worker.startGate.complete();
      await startDone;
      await reloadDone;

      expect(
        worker.calls,
        // start (gated), heartbeat on — then the queued reload tears the live
        // instance down and starts a fresh one, instead of silently closing
        // the instance the start was still bringing up.
        [
          'createInstance', 'start', 'setHeartbeat', //
          'setHeartbeat', 'stop', //
          'createInstance', 'start', 'setHeartbeat',
        ],
      );
      expect(service.active, isTrue,
          reason: 'the reload must leave a running core behind');
    });

    test('a stop behind an unwinding start takes the tunnel down', () async {
      final log = ChannelLog('test.handshake.stop-behind-start');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = GatedWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      final startDone = service.startService();
      final stopDone = service.stopService();
      worker.startGate.complete();
      await startDone;
      await stopDone;

      expect(worker.calls, [
        'createInstance', 'start', 'setHeartbeat', //
        'setHeartbeat', 'stop',
      ]);
      expect(log.calls, contains('service.stop'));
      expect(service.active, isFalse);
    });

    test('a second start while the core runs does not orphan the instance',
        () async {
      final log = ChannelLog('test.handshake.double-start');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      await service.startService();
      await service.startService();

      expect(
        worker.calls.where((call) => call == 'createInstance'),
        hasLength(1),
        reason: 'overwriting the handle would leak the live instance',
      );
      expect(service.active, isTrue);
    });

    test('a lost core is rebuilt without the user asking', () async {
      final log = ChannelLog('test.handshake.lost-rebuild');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      await service.startService();
      worker.lose();
      // The recovery runs on attempt 0 without a backoff; give the queue a
      // beat to tear the dead core down and start a fresh one.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(worker.calls, [
        'createInstance', 'start', 'setHeartbeat', //
        'setHeartbeat', 'stop', //
        'createInstance', 'start', 'setHeartbeat',
      ]);
      expect(service.active, isTrue);
    });

    test('a manual start during the recovery backoff rebuilds, not swallows',
        () async {
      final log = ChannelLog('test.handshake.lost-manual-start');
      log.install(defaultReply);
      addTearDown(log.tearDown);
      KernelService.recoveryBackoffOverride = const Duration(milliseconds: 50);
      addTearDown(() => KernelService.recoveryBackoffOverride = Duration.zero);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      await service.startService();
      worker.lose(); // attempt 0: rebuilt immediately
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(service.active, isTrue);

      // Second loss inside the same incident reaches the backoff window.
      worker.lose();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // The user sees the tunnel down and taps start while the recovery
      // sleeps. The stale handle must not read as "already running".
      await service.startService();

      // The recovery wakes, sees the user's start (a newer epoch), dissolves.
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        worker.calls.where((call) => call == 'createInstance'),
        hasLength(3),
        reason: 'the manual start must build its own instance',
      );
      expect(service.active, isTrue);
    });

    test('a second start while the first is unwinding does not orphan',
        () async {
      final log = ChannelLog('test.handshake.queued-double-start');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = GatedWorker();
      final service = KernelService(log.box);
      final dashboards = <String>[];
      final sub = service.events.listen((event) {
        if (event['type'] == 'dashboard') {
          dashboards.add((event['value'] as Map)['status'] as String? ?? '');
        }
      });
      addTearDown(sub.cancel);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      // The first start hangs in worker.start(); the second is queued behind
      // it, so by the time it runs the guard is the only thing that can stop
      // a second createInstance from overwriting the live handle.
      final first = service.startService();
      final second = service.startService();
      worker.startGate.complete();
      await first;
      await second;

      expect(
        worker.calls.where((call) => call == 'createInstance'),
        hasLength(1),
        reason: 'the queued start must be a no-op, not an orphaning overwrite',
      );
      expect(
        log.calls.where((call) => call == 'service.start'),
        hasLength(1),
        reason: 'the second start must wait for the first instead of starting again',
      );
      await pumpEventQueue();
      expect(
        dashboards.where((status) => status == 'Started'),
        hasLength(1),
        reason: 'one user start must publish one terminal Started dashboard',
      );
      expect(service.active, isTrue);
    });

    test('a reload while stopped does not pull the tunnel up', () async {
      final log = ChannelLog('test.handshake.reload-stopped');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      await service.reloadService(reason: 'stale selection change');

      expect(worker.calls, isEmpty);
      expect(log.calls, isNot(contains('service.start')));
    });
  });

  group('driver-ready wire', () {
    test('statusWire and driverReady reflect the attached driver', () async {
      final log = ChannelLog('test.handshake.driver-ready');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      // Attached but not running: the FFI path is engaged, so a hello must
      // report driverReady=true even though the core is still Stopped.
      expect(service.driverReady, isTrue);
      expect(service.ffiMode, isTrue);
      expect(service.statusWire, 'Stopped');

      await service.startService();
      expect(service.statusWire, 'Started');
      expect(service.driverReady, isTrue);
    });

    test('a service with no driver reports driverReady=false', () async {
      final log = ChannelLog('test.handshake.no-driver');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      // No debugAttach: ThroneKernel.isAvailable is irrelevant to the wire
      // fact — with no kernel attached, ffiMode/driverReady are both false.
      final service = KernelService(log.box);
      addTearDown(service.dispose);

      expect(service.ffiMode, isFalse);
      expect(service.driverReady, isFalse);
      expect(service.statusWire, 'Stopped');
    });
  });

  group('status publishing', () {
    test('an in-flight state.stats call is not overlapped by the next beat',
        () async {
      final log = ChannelLog('test.handshake.stats');
      final statsGate = Completer<Map<String, dynamic>>();
      var statsCalls = 0;
      log.install((call) async {
        if (call.method == 'state.stats') {
          statsCalls++;
          return statsGate.future;
        }
        return null;
      });
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
        if (!statsGate.isCompleted) statsGate.complete(<String, dynamic>{});
      });

      kernel.emitStatus(<String, int>{'uplink': 1});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      kernel.emitStatus(<String, int>{'uplink': 2});
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(statsCalls, 1,
          reason: 'the second snapshot is dropped while the first is in flight');
      statsGate.complete(<String, dynamic>{});
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });

    test('an unreadable snapshot does not publish a zero rate', () async {
      final log = ChannelLog('test.handshake.alive');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      final rates = <Map<String, dynamic>>[];
      final subscription = service.events
          .where((event) => event['type'] == 'rates')
          .listen((event) => rates.add(event['value'] as Map<String, dynamic>));
      addTearDown(subscription.cancel);

      kernel.emitStatus(<String, int>{'uplink': 4096, 'downlink': 8192});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(rates, hasLength(1));
      expect(rates.single['upload'], 4096);

      // The heartbeat answers this when the counters could not be read.
      kernel.emitStatus(<String, int>{'alive': 1});
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(rates, hasLength(1),
          reason: 'a missed sample must not look like 0 B/s');

      // A snapshot with the rate keys but `trafficAvailable: 0` is a real
      // reading whose flag is advisory: it still publishes its values (a core
      // that never sets the flag used to leave the card at 0 all session).
      kernel.emitStatus(<String, int>{
        'uplink': 0,
        'downlink': 0,
        'trafficAvailable': 0,
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(rates, hasLength(2));
      expect(rates.last['upload'], 0);
    });

    test('the rate comes from the cumulative totals, not the consumed deltas',
        () async {
      final log = ChannelLog('test.handshake.totals');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      final rates = <Map<String, dynamic>>[];
      final subscription = service.events
          .where((event) => event['type'] == 'rates')
          .listen((event) => rates.add(event['value'] as Map<String, dynamic>));
      addTearDown(subscription.cancel);

      // The first total only seeds the baseline.
      kernel.emitStatus(<String, int>{
        'uplink': 0,
        'downlink': 0,
        'uplinkTotal': 1000,
        'downlinkTotal': 2000,
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(rates, hasLength(1));
      expect(rates.single['upload'], 0);

      // The deltas stay 0 (another reader consumed them); the totals moved.
      kernel.emitStatus(<String, int>{
        'uplink': 0,
        'downlink': 0,
        'uplinkTotal': 3000,
        'downlinkTotal': 6000,
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(rates, hasLength(2));
      expect(rates.last['upload'], greaterThan(0));
      expect(rates.last['download'], greaterThan(0));
    });
  });

  group('host stop', () {
    test('a host stop closes the core without bouncing the service', () async {
      final log = ChannelLog('test.handle.host-stop');
      log.install(defaultReply);
      addTearDown(log.tearDown);

      final kernel = FakeKernel();
      final worker = FakeWorker();
      final service = KernelService(log.box);
      service.debugAttach(kernel, worker);
      addTearDown(() {
        service.dispose();
        kernel.close();
      });

      await service.startService();
      final events = <Map<String, dynamic>>[];
      final sub = service.events.listen(events.add);
      addTearDown(sub.cancel);
      final serviceStops = log.calls.where((m) => m == 'service.stop').length;
      await service.stopCoreFromHost();
      expect(log.calls.where((m) => m == 'service.stop'),
          hasLength(serviceStops),
          reason: 'the service is already stopping; calling service.stop again '
              'would bounce the stopRunner this event answers');
      expect(service.active, isFalse);
      expect(worker.calls, contains('stop'));
      // The broadcast stream delivers asynchronously: the terminal event is
      // queued before the await returns and must be drained before asserting.
      await pumpEventQueue();
      final statuses = events
          .where((e) => e['type'] == 'dashboard')
          .map((e) => (e['value'] as Map)['status'])
          .toList();
      expect(statuses.last, 'Stopped',
          reason: 'a host stop must publish the terminal state; without it the '
              "UI's last word is 'Stopping' and the driver-owned arbitration "
              'masks every later channel Stopped');
    });
  });
}
