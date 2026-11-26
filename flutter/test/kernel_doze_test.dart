// Doze and log-stream desired-state behaviour on KernelService.
//
// Both hints can arrive before the FFI bridge is attached (a boot doze
// notification, an early log toggle). KernelService must remember the last
// value and re-apply it on attach, so the command is not lost. The setDoze wire
// name and payload are pinned by action_contract.py on the Go side.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/core/kernel_service.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';
import 'package:flutter_test/flutter_test.dart';

class _Record {
  _Record(this.method, this.data);
  final ActionMethod method;
  final Object? data;
}

/// Records every bus action; the status stream is empty so attaching is quiet.
class _RecordingKernel implements ThroneKernel {
  final calls = <_Record>[];
  final Completer<void> firstLog;
  bool attached = false;

  _RecordingKernel({Completer<void>? firstLog})
      : firstLog = firstLog ?? Completer<void>();

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
    calls.add(_Record(method, data));
    if (method == ActionMethod.setLogStream && !firstLog.isCompleted) {
      firstLog.complete();
    }
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
  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) async => null;
  @override
  Map<String, dynamic> get dashboard => const {};
  @override
  List<Map<String, dynamic>> get configurations => const [];
}

class _Worker implements KernelWorker {
  @override
  Stream<WorkerEvent> get events => const Stream.empty();
  @override
  Future<int> createInstance(Map<String, dynamic> built) async => 0;
  @override
  Future<void> start() async {}
  @override
  Future<void> stop() async {}
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

void main() {
  test('setDoze stores the value and invokes the wire when attached', () async {
    final kernel = _RecordingKernel();
    final service = KernelService(_Host());
    service.debugAttach(kernel, _Worker());

    expect(await service.setDoze(true), isTrue);
    expect(kernel.calls, hasLength(1));
    expect(kernel.calls.first.method, ActionMethod.setDoze);
    expect(kernel.calls.first.data, {'enabled': true});

    expect(await service.setDoze(false), isTrue);
    expect(kernel.calls, hasLength(2));
    expect(kernel.calls.last.data, {'enabled': false});
  });

  test('setDoze before attach is re-applied on attach', () async {
    final kernel = _RecordingKernel();
    final service = KernelService(_Host());

    // No FFI bridge yet: the action cannot be invoked, but the desire is kept.
    expect(await service.setDoze(true), isFalse);
    expect(kernel.calls, isEmpty);

    service.debugAttach(kernel, _Worker());
    // _attach re-applies asynchronously; give the microtask queue a turn.
    await Future<void>.delayed(Duration.zero);
    expect(kernel.calls, hasLength(1));
    expect(kernel.calls.first.method, ActionMethod.setDoze);
    expect(kernel.calls.first.data, {'enabled': true});
  });

  test('log-stream desire survives a pre-attach toggle', () async {
    final kernel = _RecordingKernel();
    final service = KernelService(_Host());

    expect(await service.setLogStream(true), isFalse);
    expect(kernel.calls, isEmpty);

    service.debugAttach(kernel, _Worker());
    await Future<void>.delayed(Duration.zero);
    expect(kernel.calls, hasLength(1));
    expect(kernel.calls.first.method, ActionMethod.setLogStream);
    expect(kernel.calls.first.data, {'enabled': true});
  });

  test('only the last doze desire is re-applied on attach', () async {
    final kernel = _RecordingKernel();
    final service = KernelService(_Host());

    await service.setDoze(true);
    await service.setDoze(false); // window closed again before attach
    service.debugAttach(kernel, _Worker());
    await Future<void>.delayed(Duration.zero);
    // An explicit false that preceded attach must still be replayed (a
    // doze command was seen), but only once and with the final value.
    expect(kernel.calls, hasLength(1));
    expect(kernel.calls.first.method, ActionMethod.setDoze);
    expect(kernel.calls.first.data, {'enabled': false});
  });
}
