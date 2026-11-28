// Focused tests for the S6 Dart subscription queue/state machine (ADR 0008 S6).
// The injected runner replaces Kotlin/Go entirely: no HTTP, no platform
// channels, no document writes. Each case owns a fresh queue.
//
// Tasks use Completers to hold a job in flight; `_gate()` returns a task that
// suspends until released. The runner simply calls each job's task, recording
// start/finish order. No fake clocks or extra pumps needed.

import 'dart:async';

import 'package:flrone/services/subscription_client.dart';
import 'package:flrone/services/subscription_queue.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder extends SubscriptionQueueListener {
  final List<String> events = <String>[];
  final bool throwOnState;

  _Recorder({this.throwOnState = false});

  @override
  void onState(int gid, int state) {
    events.add('state:$gid:$state');
    if (throwOnState) throw StateError('bad listener $gid:$state');
  }

  @override
  void onReport(int gid, String title, String text, bool popup) {
    events.add('report:$gid:$title:$text:$popup');
  }

  @override
  void onError(int gid, String message) {
    events.add('error:$gid:$message');
  }

  @override
  void onReloadNeeded(int gid) {
    events.add('reload:$gid');
  }
}

/// Runner that calls each job's task and records work order.
class _RecordingRunner {
  final List<int> started = <int>[];
  final List<int> finished = <int>[];

  Future<void> call(SubscriptionJob job) async {
    started.add(job.gid);
    await job.task();
    finished.add(job.gid);
  }
}

/// A task that blocks until [release] is called.
class _Gate {
  final Completer<void> _completer = Completer<void>();
  bool _entered = false;

  Future<void> call() async {
    _entered = true;
    await _completer.future;
  }

  bool get entered => _entered;
  void release() => _completer.complete();
}

Future<void> _yield() => Future<void>.microtask(() {});

void main() {
  test('single-flight: jobs run FIFO, one at a time', () async {
    final runner = _RecordingRunner();
    final queue = SubscriptionQueue(runner: runner.call);
    final gates = <_Gate>[for (var i = 0; i < 3; i++) _Gate()];
    for (var i = 0; i < 3; i++) {
      queue.refreshGroup(i + 1, foreground: false, task: gates[i].call);
    }
    expect(runner.started, <int>[1]); // first job running synchronously
    expect(gates[0].entered, isTrue);
    expect(gates[1].entered, isFalse);
    gates[0].release();
    await _yield();
    expect(runner.started, <int>[1, 2]);
    expect(gates[1].entered, isTrue);
    gates[1].release();
    await _yield();
    gates[2].release();
    await queue.awaitIdle();
    expect(runner.started, <int>[1, 2, 3]);
    expect(runner.finished, <int>[1, 2, 3]);
  });

  test('per-gid dedupe: a queued or running gid is not enqueued twice', () async {
    final gate = _Gate();
    final runner = _RecordingRunner();
    final queue = SubscriptionQueue(runner: runner.call);
    expect(queue.refreshGroup(7, foreground: false, task: gate.call), isTrue);
    expect(queue.refreshGroup(7, foreground: false), isFalse);
    expect(runner.started, <int>[7]);
    gate.release();
    await queue.awaitIdle();
    // Once idle the gid is free again.
    expect(queue.refreshGroup(7, foreground: false), isTrue);
    await queue.awaitIdle();
  });

  test('batch refusal: concurrent batch errors with gid -1 and skips duplicates', () async {
    final gate1 = _Gate();
    final gate2 = _Gate();
    final runner = _RecordingRunner();
    final recorder = _Recorder();
    final queue = SubscriptionQueue(runner: runner.call);
    queue.register(recorder);

    expect(
      queue.refreshAll(const <int>[1, 2, 2], foreground: false, task: (gid) {
        return (gid == 1 ? gate1 : gate2).call();
      }),
      isTrue,
    );
    expect(queue.pendingGids, <int>{1, 2});
    expect(runner.started, <int>[1]);

    recorder.events.clear();
    expect(queue.refreshAll(const <int>[3, 4]), isFalse);
    expect(recorder.events, contains('error:-1:Batch refresh already running'));

    gate1.release();
    await _yield();
    expect(runner.started, <int>[1, 2]);
    gate2.release();
    await queue.awaitIdle();
    expect(queue.pendingBatch, 0);
    expect(queue.refreshAll(const <int>[3], foreground: false), isTrue);
    await queue.awaitIdle();
  });

  test('state/report order: queued, running, reports, idle per job', () async {
    final recorder = _Recorder();
    final queue = SubscriptionQueue();
    queue.register(recorder);
    queue.refreshGroup(
      5,
      task: () async {
        queue.report(5, 'Changes', '3 nodes', true);
        queue.reloadNeeded(5);
      },
    );
    await queue.awaitIdle();
    expect(recorder.events, <String>[
      'state:5:1', // queued
      'state:5:2', // running
      'report:5:Changes:3 nodes:true',
      'reload:5',
      'state:5:0', // idle
    ]);
  });

  test('awaitIdle spans URL-test follow-up and survives a failed test', () async {
    final testGate = _Gate();
    final followGate = _Gate();
    final runner = _RecordingRunner();
    final queue = SubscriptionQueue(runner: runner.call);

    queue.requestUrlTest(9, urlTest: testGate.call, followUp: followGate.call);
    expect(queue.outstanding, 1);
    var idle = false;
    queue.awaitIdle().then((_) => idle = true);
    await _yield();
    expect(idle, isFalse);

    testGate.release();
    await _yield();
    expect(runner.started, <int>[subscriptionNoGid]);
    expect(idle, isFalse); // follow-up still running

    followGate.release();
    await queue.awaitIdle();
    expect(idle, isTrue);
  });

  test('awaitIdle completes immediately when already idle', () async {
    final queue = SubscriptionQueue();
    var completed = false;
    queue.awaitIdle().then((_) => completed = true);
    await _yield();
    expect(completed, isTrue);
  });

  test('replay: a new listener sees running/queued state of pending groups', () async {
    final gate = _Gate();
    final runner = _RecordingRunner();
    final queue = SubscriptionQueue(runner: runner.call);
    queue.refreshGroup(11, foreground: false, task: gate.call); // running
    queue.refreshGroup(12, foreground: false); // queued
    final replayed = _Recorder();
    queue.register(replayed);
    expect(replayed.events, <String>['state:11:2', 'state:12:1']);

    // A second registration does not replay again.
    replayed.events.clear();
    queue.register(replayed);
    expect(replayed.events, isEmpty);
    gate.release();
    await queue.awaitIdle();
  });

  test('listener isolation: a throwing listener does not block others', () async {
    final errors = <Object>[];
    final bad = _Recorder(throwOnState: true);
    final good = _Recorder();
    final queue = SubscriptionQueue(
      onListenerError: (error, stack) => errors.add(error),
    );
    queue.register(bad);
    queue.register(good);
    queue.refreshGroup(3, foreground: false);
    await queue.awaitIdle();
    expect(good.events, <String>['state:3:1', 'state:3:2', 'state:3:0']);
    expect(bad.events, <String>['state:3:1', 'state:3:2', 'state:3:0']);
    expect(errors, hasLength(3));
    expect(errors.first, isA<StateError>());
  });

  test('foreground callback counts match job foreground flags', () async {
    var acquired = 0;
    var released = 0;
    final gate = _Gate();
    final runner = _RecordingRunner();
    final queue = SubscriptionQueue(
      runner: runner.call,
      onForegroundAcquire: () => acquired++,
      onForegroundRelease: () => released++,
    );
    queue.refreshGroup(1, task: gate.call); // foreground
    queue.refreshGroup(2, foreground: false); // background
    expect(acquired, 1);
    expect(released, 0);
    gate.release();
    await queue.awaitIdle();
    expect(acquired, 1);
    expect(released, 1);
  });

  test('task failure is isolated and reported only for foreground jobs', () async {
    final errors = <Object>[];
    final recorder = _Recorder();
    final queue = SubscriptionQueue(
      onListenerError: (error, stack) => errors.add(error),
    );
    queue.register(recorder);
    queue.refreshGroup(
      1,
      foreground: false,
      task: () async => throw StateError('background boom'),
    );
    await queue.awaitIdle();
    expect(recorder.events.where((e) => e.startsWith('error:')), isEmpty);
    expect(errors, isEmpty);

    queue.refreshGroup(
      2,
      task: () async => throw StateError('foreground boom'),
    );
    await queue.awaitIdle();
    expect(
      recorder.events.any((e) => e.startsWith('error:2:Subscription task failed:')),
      isTrue,
    );
    expect(errors, hasLength(1));
  });

  test('SubscriptionClient maps events to wire shapes and replays state', () async {
    final gate = _Gate();
    final runner = _RecordingRunner();
    final queue = SubscriptionQueue(runner: runner.call);
    final client = SubscriptionClient(queue)
      ..groupNameOf = (gid) => 'Group $gid';
    final reports = <SubscriptionReportEvent>[];
    final states = <Map<String, dynamic>>[];
    final reportSub = client.reports.listen(reports.add);
    final stateSub = client.stateEvents.listen((e) => states.add(e.toWire()));
    addTearDown(() async {
      await reportSub.cancel();
      await stateSub.cancel();
      await client.close();
    });

    client.attach();
    queue.refreshGroup(42, foreground: false, task: gate.call);
    await _yield(); // broadcast streams deliver asynchronously
    await _yield(); // second event (running) needs its own delivery turn
    // States are synchronous: queued then running at enqueue time.
    expect(client.states, <int, int>{42: 2});
    expect(states, <Map<String, dynamic>>[
      <String, dynamic>{'gid': 42, 'state': 1},
      <String, dynamic>{'gid': 42, 'state': 2},
    ]);
    gate.release();
    await queue.awaitIdle();
    expect(client.states, isEmpty);
    expect(states.last, <String, dynamic>{'gid': 42, 'state': 0});

    // A fresh client attaches mid-flight: register-time replay rebuilds it.
    final lateQueue = SubscriptionQueue(runner: runner.call);
    final lateClient = SubscriptionClient(lateQueue);
    final lateGate = _Gate();
    lateQueue.refreshGroup(8, foreground: false, task: lateGate.call);
    lateQueue.refreshGroup(9, foreground: false);
    lateClient.attach(); // replay sees running/queued snapshot
    expect(lateClient.states, <int, int>{8: 2, 9: 1});
    await lateClient.close();
    lateGate.release();
    await lateQueue.awaitIdle();

    queue.report(42, 'Title', 'body', false);
    queue.emitError(-1, 'oops');
    queue.reloadNeeded(42);
    await _yield();
    await _yield();
    await _yield(); // broadcast stream delivers one event per microtask turn
    expect(reports.map((r) => r.kind), <String>['status', 'error', 'reload']);
    // BoxController consumes toWire() maps; verify the subset it reads.
    expect(
      reports.map((r) => r.toWire()),
      <Map<String, dynamic>>[
        <String, dynamic>{'kind': 'status', 'text': 'body'},
        <String, dynamic>{'kind': 'error', 'groupName': '', 'text': 'oops'},
        <String, dynamic>{'kind': 'reload', 'groupName': 'Group 42', 'text': ''},
      ],
    );
  });
}
