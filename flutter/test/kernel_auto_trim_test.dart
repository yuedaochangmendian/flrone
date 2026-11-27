// Automatic Go-heap trim policy on KernelService. The service engine is the
// sole kernel owner, so it — not the display-only memory panel — decides when
// to hand idle heap back to the OS. No new actions, no platform changes.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/core/kernel_memory.dart';
import 'package:flrone/core/kernel_service.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

/// A bus that records calls and can fail forceGC on demand.
class _BusKernel implements ThroneKernel {
  final calls = <ActionMethod>[];
  final List<Object?> payloads = <Object?>[];
  bool failGc = false;
  Object? memoryReply;

  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  Stream<BridgeEvent> get logs => const Stream.empty();

  @override
  ThroneFFI get ffi => throw UnimplementedError('not used in these tests');

  @override
  ReplyPort openReply() => throw UnimplementedError('not used in these tests');

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(method);
    payloads.add(data);
    if (method == ActionMethod.forceGC && failGc) {
      throw StateError('forceGC failed');
    }
    if (method == ActionMethod.runtimeMemory) return memoryReply as T;
    return true as T;
  }

  @override
  Future<dynamic> invokeWire(String wire, {Duration timeout = actionTimeout}) =>
      throw UnimplementedError('not used in these tests');

  @override
  Map<String, dynamic> get lastSpeedTestState => const {};

  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();

  @override
  void dispose() {}
}

class _Host implements KernelHost {
  final notes = <String>[];
  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) async {
    if (method == 'log.note') notes.add('${args?['text']}');
    return null;
  }

  @override
  Map<String, dynamic> get dashboard => const {};
  @override
  List<Map<String, dynamic>> get configurations => const [];
}

class _Worker implements KernelWorker {
  final stopped = Completer<void>();
  @override
  Stream<WorkerEvent> get events => const Stream.empty();
  @override
  Future<int> createInstance(Map<String, dynamic> built) async => 0;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {
    if (!stopped.isCompleted) stopped.complete();
  }
  @override
  Future<void> setHeartbeat(bool enabled) async {}
  @override
  Future<bool> needWifiState() async => false;
  @override
  Future<void> updateWifiState() async {}
  @override
  Future<Map<String, dynamic>?> updateRuleSets() async => null;
  @override
  Future<void> dispose() async {}
}

KernelMemoryStats _stats({required int heapInuse, required int heapIdle}) =>
    KernelMemoryStats(
      rss: 0,
      heapAlloc: 0,
      heapSys: 0,
      heapInuse: heapInuse,
      heapIdle: heapIdle,
      stackInuse: 0,
      runtimeOther: 0,
      numGC: 0,
      goroutines: 0,
    );

/// Builds a service with a controllable clock and stats reader.
({KernelService service, _BusKernel kernel, _Host host, DateTime Function() clock})
    _service({
  DateTime Function()? clock,
  Future<KernelMemoryStats> Function()? stats,
}) {
  final now = clock ?? () => DateTime.fromMillisecondsSinceEpoch(0);
  final kernel = _BusKernel();
  final host = _Host();
  final service = KernelService(
    host,
    clock: now,
    memoryStatsReader: stats,
  );
  service.debugAttach(kernel, _Worker());
  return (service: service, kernel: kernel, host: host, clock: now);
}

void main() {
  group('KernelService automatic Go-heap trim', () {
    test('high water + idle share triggers exactly one full trim', () async {
      var time = DateTime.fromMillisecondsSinceEpoch(1000);
      final env = _service(
        clock: () => time,
        stats: () async => _stats(
          heapInuse: 300 * 1024 * 1024,
          heapIdle: 300 * 1024 * 1024,
        ),
      );
      expect(await env.service.debugAutoTrim('periodic'), isTrue);
      expect(env.kernel.calls, <ActionMethod>[ActionMethod.forceGC]);
      expect(env.kernel.payloads.single, {'full': true});
      expect(env.host.notes, contains('auto memory trim (periodic): full Go GC'));
    });

    test('cooldown suppresses a second trim until it expires', () async {
      var time = DateTime.fromMillisecondsSinceEpoch(1000);
      final env = _service(
        clock: () => time,
        stats: () async => _stats(
          heapInuse: 300 * 1024 * 1024,
          heapIdle: 300 * 1024 * 1024,
        ),
      );
      expect(await env.service.debugAutoTrim('periodic'), isTrue);
      expect(await env.service.debugAutoTrim('periodic'), isFalse);
      expect(env.kernel.calls, hasLength(1));

      // Advance to just under the cooldown: still suppressed.
      time = time.add(const Duration(seconds: 59));
      expect(await env.service.debugAutoTrim('periodic'), isFalse);
      expect(env.kernel.calls, hasLength(1));

      // Cooldown reached: the next crossing trims again.
      time = time.add(const Duration(seconds: 1));
      expect(await env.service.debugAutoTrim('periodic'), isTrue);
      expect(env.kernel.calls, hasLength(2));
    });

    test('low RSS / tight heap does nothing', () async {
      final env = _service(
        stats: () async => _stats(
          heapInuse: 540 * 1024 * 1024,
          heapIdle: 60 * 1024 * 1024,
        ),
      );
      expect(await env.service.debugAutoTrim('periodic'), isFalse);
      expect(env.kernel.calls, isEmpty);
    });

    test('a failed forceGc is swallowed and does not start a cooldown', () async {
      var time = DateTime.fromMillisecondsSinceEpoch(1000);
      final env = _service(
        clock: () => time,
        stats: () async => _stats(
          heapInuse: 300 * 1024 * 1024,
          heapIdle: 300 * 1024 * 1024,
        ),
      );
      env.kernel.failGc = true;
      expect(await env.service.debugAutoTrim('stop'), isFalse);
      expect(env.kernel.calls, <ActionMethod>[ActionMethod.forceGC]);
      expect(env.host.notes, contains(contains('auto memory trim (stop) failed')));

      // No cooldown was recorded on failure: the next attempt still runs.
      env.kernel.failGc = false;
      expect(await env.service.debugAutoTrim('stop'), isTrue);
      expect(env.kernel.calls, hasLength(2));
    });

    test('no kernel attached is a no-op', () async {
      final host = _Host();
      final service = KernelService(host);
      // No debugAttach: no action bus, so nothing can be trimmed.
      expect(await service.debugAutoTrim('stop'), isFalse);
      expect(await service.debugAutoTrim('periodic'), isFalse);
      service.dispose();
    });

    test('a terminal stop triggers one full trim through the lifecycle', () async {
      var time = DateTime.fromMillisecondsSinceEpoch(1000);
      final env = _service(clock: () => time);
      // A real bus reply for runtimeMemory isn't needed: the stop path is
      // unconditional and does not read stats.
      await env.service.stopService();
      // stopCore's trigger is fire-and-forget; let its microtasks finish.
      await Future<void>.delayed(Duration.zero);
      expect(env.kernel.calls, <ActionMethod>[ActionMethod.forceGC]);
      expect(env.kernel.payloads.single, {'full': true});
    });

    test('a no-op reload with no running instance does not trim', () async {
      final env = _service();
      // No instance: reloadService stands down before _stopCore, so there is
      // nothing to reclaim. A real reload that stops an instance does trim,
      // but the cooldown caps it at once per minute.
      await env.service.reloadService(reason: 'test');
      await Future<void>.delayed(Duration.zero);
      expect(env.kernel.calls, isEmpty);
    });
  });
}
