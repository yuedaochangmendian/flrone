import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/common/async_gate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.process-gate');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late StreamController<dynamic> events;
  late BoxController box;

  setUp(() {
    events = StreamController<dynamic>.broadcast();
    box = BoxController(channel: channel, events: events.stream);
  });
  tearDown(() async {
    box.dispose();
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> flush([int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('process lookups keep at most eight in flight and all of them settle', () async {
    var inFlight = 0, peak = 0, calls = 0;
    final held = <String, Completer<Object?>>{};
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'apps.process') return null;
      calls++;
      inFlight++;
      if (inFlight > peak) peak = inFlight;
      final path = (call.arguments as Map)['path'] as String;
      final done = Completer<Object?>();
      held[path] = done;
      await done.future;
      inFlight--;
      return {'package': 'pkg', 'label': path};
    });

    final futures = [for (var i = 0; i < 20; i++) box.processInfoFor('/proc/$i')];
    await flush();
    expect(calls, BoxController.maxConcurrentProcessLookups,
        reason: 'only the gate limit reaches the channel');
    expect(peak, BoxController.maxConcurrentProcessLookups);
    expect(held, hasLength(8));

    // A cached path answers from the map and must not consume one of the held slots.
    final cached = box.processInfoFor('/proc/0');
    await flush();
    expect(calls, 8, reason: 'a cached lookup is not a channel round trip');

    var released = 0;
    while (released < 20) {
      final open = held.values.where((done) => !done.isCompleted).toList();
      expect(open, isNotEmpty, reason: 'the queue must keep draining');
      for (final done in open) {
        done.complete(null);
        released++;
      }
      await flush();
      expect(peak, lessThanOrEqualTo(BoxController.maxConcurrentProcessLookups));
    }

    final replies = await Future.wait([...futures, cached]);
    expect(replies, hasLength(21));
    expect(replies.every((reply) => reply['package'] == 'pkg'), isTrue);
    expect(calls, 20, reason: 'released slots started each queued path exactly once');
  });

  test('the gate releases a slot when a task throws', () async {
    final gate = AsyncGate(limit: 1);
    var started = 0;
    final failed = gate.run<void>(() async {
      started++;
      throw StateError('boom');
    });
    await expectLater(failed, throwsStateError);
    await gate.run<void>(() async => started++);
    expect(started, 2, reason: 'the failed task returned its slot to the queue');
    expect(gate.inFlight, 0);
    expect(gate.waiting, 0);
  });

  test('the gate hands a freed slot to the oldest waiter', () async {
    final gate = AsyncGate(limit: 2);
    final order = <int>[];
    final held = <Completer<void>>[];
    Future<void> task(int id) => gate.run<void>(() async {
          order.add(id);
          final wait = Completer<void>();
          held.add(wait);
          await wait.future;
        });

    final tasks = [for (var i = 0; i < 4; i++) task(i)];
    await flush();
    expect(order, [0, 1]);
    expect(gate.inFlight, 2);
    expect(gate.waiting, 2);

    held[0].complete();
    await flush();
    expect(order, [0, 1, 2], reason: 'FIFO: the oldest waiter takes the freed slot');
    held[1].complete();
    await flush();
    expect(order, [0, 1, 2, 3]);
    for (final wait in held.skip(2)) {
      wait.complete();
    }
    await Future.wait(tasks);
    expect(gate.inFlight, 0);
    expect(gate.waiting, 0);
  });
}
