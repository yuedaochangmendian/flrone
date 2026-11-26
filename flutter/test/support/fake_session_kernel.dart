// A kernel attached to a BoxController that records bus actions as MethodCalls.
//
// ADR 0004 P4a moved the five test-session controls off the `io.flrone/box`
// channel onto the JSON action bus. The speed-screen tests still inspect the
// arguments a start was sent with (profile ids, direction, ...); this fake
// replays each bus action into the same `List<MethodCall>` the harness already
// collects from the channel, so those assertions keep testing the real facade.

import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';
import 'package:flutter/services.dart';

import 'package:flrone/box.dart';

/// Maps a session ActionMethod to the channel name its pre-bus arm used.
String sessionWireName(ActionMethod method) => switch (method) {
  ActionMethod.speedTestSessionStart => 'groups.testSession.start',
  ActionMethod.speedTestSessionStop => 'groups.testSession.stop',
  ActionMethod.speedTestSessionDismiss => 'groups.testSession.dismiss',
  ActionMethod.speedTestSessionSort => 'groups.testSession.sort',
  ActionMethod.speedTestSessionRemove => 'groups.testSession.remove',
  ActionMethod.groupNodes => 'groups.nodes',
  ActionMethod.speedTestOutbounds => 'speedTest.outbounds',
  _ => 'groups.testSession.visible',
};

/// Records every bus action as a [MethodCall] in [calls], and answers start/sort
/// with [startReply] > 0 (the same bool verdict the old channel arm returned).
/// [nodes] is the catalog `groupNodes` payload (the speed screen resolves a
/// named node's id from it once the kernel is attached).
class FakeSessionKernel implements ThroneKernel {
  FakeSessionKernel(this.calls, {this.startReply = true, this.nodes = const []});

  final List<MethodCall> calls;

  /// The verdict for start and sort; a false value exercises the "busy" branch.
  bool startReply;

  /// Rows the `groupNodes` bus action answers, as `{'nodes': [...]}`.
  final List<Map<String, Object?>> nodes;

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(MethodCall(sessionWireName(method), data));
    if (method == ActionMethod.groupNodes) {
      return {'nodes': nodes} as T;
    }
    if (method == ActionMethod.speedTestOutbounds) {
      return {'outbounds': <String>[]} as T;
    }
    if (method == ActionMethod.speedTestSessionRemove) {
      return {'removed': 0} as T;
    }
    if (method == ActionMethod.speedTestSessionStart ||
        method == ActionMethod.speedTestSessionSort) {
      return startReply as T;
    }
    return true as T;
  }

  @override
  Future<dynamic> invokeWire(String wire, {Duration timeout = actionTimeout}) =>
      throw UnimplementedError('session tests never invoke a raw action wire');

  @override
  Map<String, dynamic> get lastSpeedTestState => const {};

  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();

  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  Stream<BridgeEvent> get logs => const Stream.empty();

  @override
  ThroneFFI get ffi => throw UnimplementedError('sessions never touch ffi');

  @override
  ReplyPort openReply() =>
      throw UnimplementedError('sessions never open a reply port');

  @override
  void dispose() {}
}

/// A worker that answers no events; a session test drives the bus only.
class NoopSessionWorker implements KernelWorker {
  @override
  Stream<WorkerEvent> get events => const Stream.empty();

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('session tests do not drive the worker');
}

/// Attaches a [FakeSessionKernel] to [box], recording its actions into [calls].
void attachSessionBus(
  BoxController box,
  List<MethodCall> calls, {
  bool startReply = true,
  List<Map<String, Object?>> nodes = const [],
}) {
  box.debugAttach(
    FakeSessionKernel(calls, startReply: startReply, nodes: nodes),
    NoopSessionWorker(),
  );
}
