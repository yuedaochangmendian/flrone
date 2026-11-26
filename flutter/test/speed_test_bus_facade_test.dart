// SpeedTestApi over the action bus (ADR 0004 P4a).
//
// The five session controls moved off the `io.flrone/box` channel. These tests
// pin the facade's contract with a real attached kernel: the start/sort bool
// verdict survives verbatim, remove returns the host's {"removed": N} map, and
// a kernel failure is reported and folded to false exactly as `act` did (so a
// failed start is never mistaken for a running session on the speed screen).
// `visible` stays a channel subscription and is not exercised here.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers bus actions from a test-provided function and records them.
class _RecordingKernel implements ThroneKernel {
  _RecordingKernel(this.handler);

  final Object? Function(ActionMethod, Object?) handler;
  final calls = <({ActionMethod method, Object? data})>[];

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((method: method, data: data));
    return handler(method, data) as T;
  }

  @override
  Future<dynamic> invokeWire(String wire, {Duration timeout = actionTimeout}) =>
      throw UnimplementedError('unused in facade tests');

  @override
  Map<String, dynamic> get lastSpeedTestState => const {};

  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();

  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  Stream<BridgeEvent> get logs => const Stream.empty();

  @override
  ThroneFFI get ffi => throw UnimplementedError('unused in facade tests');

  @override
  ReplyPort openReply() => throw UnimplementedError('unused in facade tests');

  @override
  void dispose() {}
}

class _Worker implements KernelWorker {
  @override
  Stream<WorkerEvent> get events => const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('unused in facade tests');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late MethodChannel channel;
  late StreamController<dynamic> events;

  setUp(() {
    channel = const MethodChannel('test.session-bus-facade');
    events = StreamController<dynamic>.broadcast();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    events.close();
  });

  /// A box with a bus kernel whose handler records every action it answers.
  ({BoxController box, List<({ActionMethod method, Object? data})> calls}) withKernel(
    Object? Function(ActionMethod, Object?) answer,
  ) {
    final calls = <({ActionMethod method, Object? data})>[];
    final kernel = _RecordingKernel((method, data) {
      calls.add((method: method, data: data));
      return answer(method, data);
    });
    final box = BoxController(channel: channel, events: events.stream);
    box.debugAttach(kernel, _Worker());
    addTearDown(box.dispose);
    return (box: box, calls: calls);
  }

  test('start forwards args and returns the host bool verbatim', () async {
    final h = withKernel(
      (method, _) => method == ActionMethod.speedTestSessionStart ? false : true,
    );
    final args = {'kind': 2, 'profileIds': [7], 'testCurrent': false, 'speedMode': 1};

    expect(await h.box.groupTestSessionStartChecked(args), isFalse,
        reason: 'false is the busy verdict, not a failure');
    expect(h.calls.single.method, ActionMethod.speedTestSessionStart);
    expect(h.calls.single.data, args);
  });

  test('a true verdict and non-bool completions mean success', () async {
    final h = withKernel((_, _) => true);
    expect(await h.box.groupTestSessionStartChecked({'kind': 2}), isTrue);
    expect(await h.box.groupTestSessionStop(), isTrue);
    expect(await h.box.groupTestSessionDismiss(), isTrue);
    // A non-bool answer (e.g. the host's null before P4a) counts as done.
    final h2 = withKernel((_, _) => null);
    expect(await h2.box.groupTestSessionStop(), isTrue);
  });

  test('remove returns the host map unchanged', () async {
    final h = withKernel((_, _) => {'removed': 3});
    expect(await h.box.groupTestSessionRemove([1, 2]), {'removed': 3});
    expect(h.calls.single.data, {'ids': [1, 2]});
  });

  test('a thrown kernel error is folded to false, never a false start', () async {
    final h = withKernel((method, _) {
      if (method == ActionMethod.speedTestSessionStart) {
        throw const ActionException('speedTestSessionStart', 'platform callback unavailable');
      }
      return true;
    });
    expect(await h.box.groupTestSessionStartChecked({'kind': 2}), isFalse);
  });

  test('all five controls use the bus when attached', () async {
    final h = withKernel((_, _) => true);
    await h.box.groupTestSessionStartChecked({'kind': 2});
    await h.box.groupTestSessionStop();
    await h.box.groupTestSessionDismiss();
    await h.box.groupTestSessionSort(42);
    await h.box.groupTestSessionRemove([9]);
    expect(
      h.calls.map((call) => call.method),
      [
        ActionMethod.speedTestSessionStart,
        ActionMethod.speedTestSessionStop,
        ActionMethod.speedTestSessionDismiss,
        ActionMethod.speedTestSessionSort,
        ActionMethod.speedTestSessionRemove,
      ],
    );
    expect(h.calls.last.data, {'ids': [9]});
  });
}
