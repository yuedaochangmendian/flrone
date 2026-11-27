// The outbound picker's node catalog is the largest bridge payload. Once a
// non-empty rows snapshot has been read it is returned from the client cache
// until the profiles/groups state aspect moves (host push or explicit write
// invalidation). Empty results are never cached so the pre-migration fallback
// can still recover.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Kernel implements ThroneKernel {
  _Kernel(this.answer);

  final List<Json> Function() answer;
  int calls = 0;

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    expect(method, ActionMethod.groupNodes);
    calls++;
    return {'nodes': answer()} as T;
  }

  @override
  Future<dynamic> invokeWire(String wire, {Duration timeout = actionTimeout}) =>
      throw UnimplementedError();
  @override
  Map<String, dynamic> get lastSpeedTestState => const {};
  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();
  @override
  Stream<BridgeEvent> get events => const Stream.empty();
  @override
  Stream<BridgeEvent> get logs => const Stream.empty();
  @override
  ThroneFFI get ffi => throw UnimplementedError();
  @override
  ReplyPort openReply() => throw UnimplementedError();
  @override
  void dispose() {}
}

class _Worker implements KernelWorker {
  @override
  Stream<WorkerEvent> get events => const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.group-nodes-cache');
  late StreamController<dynamic> events;
  late List<Json> busAnswer;
  late List<Json> channelAnswer;
  late int channelCalls;
  late _Kernel kernel;
  late BoxController box;

  setUp(() async {
    events = StreamController<dynamic>.broadcast();
    busAnswer = <Json>[{'id': 1, 'tag': 'node'}];
    channelAnswer = <Json>[{'id': 9, 'tag': 'fallback'}];
    channelCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'groups.nodes') {
        channelCalls++;
        return {'nodes': channelAnswer};
      }
      if (call.method == 'data.broadcast') return null;
      return null;
    });
    kernel = _Kernel(() => busAnswer);
    box = BoxController(channel: channel, events: events.stream);
    box.debugAttach(kernel, _Worker());
    // initialize attaches the event listener used by the state-aspect test.
    // Its other channel work is harmless with the stubs registered above.
    await box.initialize();
    // `ready` may seed the picker cache from the channel snapshot; every test
    // below starts from a clean cache with its own answer sequence.
    box.invalidateGroupNodesCache();
  });

  tearDown(() {
    box.dispose();
    events.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('repeats the last non-empty rows without another bridge call', () async {
    final first = await box.groupNodes();
    expect(first, busAnswer);
    expect(kernel.calls, 1);
    expect(channelCalls, 0);

    final second = await box.groupNodes();
    expect(second, same(first));
    expect(kernel.calls, 1, reason: 'cache hit must not cross the bus again');
    expect(channelCalls, 0);
  });

  test('a state-aspect change invalidates the cache', () async {
    await box.groupNodes();
    // Simulate the host pushing new profiles into the controller: the
    // `profiles` event dispatches BoxAspect.state, which is the invalidation
    // signal the cache keys on.
    busAnswer = <Json>[{'id': 2, 'tag': 'node-2'}];
    events.add(<String, dynamic>{'type': 'profiles', 'value': <dynamic>[]});
    await pumpEventQueue();

    final next = await box.groupNodes();
    expect(next, busAnswer);
    expect(kernel.calls, 2);
  });

  test('an explicit invalidation re-reads the bus', () async {
    await box.groupNodes();
    busAnswer = <Json>[{'id': 3, 'tag': 'node-3'}];
    box.invalidateGroupNodesCache();
    final next = await box.groupNodes();
    expect(next, busAnswer);
    expect(kernel.calls, 2);
  });

  test('an empty bus answer falls back to the channel', () async {
    busAnswer = <Json>[];
    final first = await box.groupNodes();
    expect(first, channelAnswer);
    expect(channelCalls, 1);
  });

  test('an empty result from both sources is never cached', () async {
    busAnswer = <Json>[];
    channelAnswer = <Json>[];
    final first = await box.groupNodes();
    expect(first, isEmpty);
    expect(channelCalls, 1);

    // A fresh non-empty answer must be re-read, not shadowed by an empty cache.
    channelAnswer = <Json>[{'id': 10, 'tag': 'fresh'}];
    final second = await box.groupNodes();
    expect(second, channelAnswer);
    expect(channelCalls, 2, reason: 'empty results must never be cached');
  });
}

Future<void> pumpEventQueue() => Future<void>.delayed(Duration.zero);
