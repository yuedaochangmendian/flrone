// Two alignment rules of the kernel driver, both about *not* doing work that is not needed:
//
//   A15 — a start (a relaunch, a silent boot/tile start) whose build inputs are unchanged
//         reuses the config the previous start applied, and still starts the core.
//   S4  — a reload whose freshly built config cannot come up restores the previously
//         accepted config exactly once, instead of leaving the tunnel down.
//
// The host is a mock channel here (the same harness the handshake tests use): the persisted
// record lives on that side, so the clear-before-push / write-after-start rules are checked
// against the calls the driver actually makes.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/core/kernel_service.dart';
import 'package:flrone/core/kernel_worker.dart';
import 'package:flrone/core/throne_ffi.dart';
import 'package:flrone/core/throne_kernel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only answers the status stream the driver subscribes to.
class FakeKernel implements ThroneKernel {
  FakeKernel([this.events = const Stream.empty()]);

  @override
  final Stream<BridgeEvent> events;

  @override
  Stream<BridgeEvent> get logs => const Stream.empty();

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
  Future<dynamic> invokeWire(String wire, {Duration timeout = actionTimeout}) =>
      throw UnimplementedError('the kernel under test never invokes an action');

  @override
  Map<String, dynamic> get lastSpeedTestState => const {};

  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();

  @override
  void dispose() {}
}

/// Records every instance it was asked to create — that map is the config the core runs — and
/// can refuse a chosen one so the reload's failure path is reachable.
class RecordingWorker implements KernelWorker {
  RecordingWorker(this.sequence);

  final List<String> sequence;
  final built = <Map<String, dynamic>>[];
  final calls = <String>[];

  /// Refuse creation when this returns true for the handed build.
  bool Function(Map<String, dynamic> built)? refuse;

  @override
  Stream<WorkerEvent> get events => const Stream.empty();

  @override
  Future<int> createInstance(Map<String, dynamic> built) async {
    calls.add('createInstance');
    sequence.add('createInstance');
    this.built.add(built);
    if (refuse?.call(built) ?? false) throw StateError('the kernel refused the config');
    return built.length;
  }

  @override
  Future<void> start() async {
    calls.add('start');
    sequence.add('start');
  }

  @override
  Future<void> stop() async => calls.add('stop');

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

  /// The configs this worker's core was actually given, as coreConfig strings.
  List<String> get applied => built.map((config) => config['coreConfig'] as String).toList();
}

/// The host side: a mock channel plus the persisted record the real `AppliedConfigStore`
/// would hold, so the driver's clear/store calls are observable in order.
class Host {
  Host(this.name, this.sequence);

  final String name;
  final List<String> sequence;
  late final MethodChannel channel = MethodChannel(name);
  late final BoxController box;

  /// The record `config.appliedGet` serves.
  String? storedFingerprint;
  Map<String, dynamic>? storedOptions;

  /// The inputs' stamp `config.fingerprint` reports.
  String fingerprint = 'fp-1';

  /// The builds this host would produce, in order; the last one repeats.
  final builds = <Map<String, dynamic>>[];

  int buildCount = 0;

  Map<String, dynamic> buildFor(int index) => builds[index.clamp(0, builds.length - 1)];

  void install() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      sequence.add(call.method);
      switch (call.method) {
        case 'config.build':
          final built = buildFor(buildCount);
          buildCount++;
          return built;
        case 'config.fingerprint':
          return fingerprint;
        case 'config.appliedGet':
          if (storedFingerprint == null || storedOptions == null) return null;
          return <String, dynamic>{
            'fingerprint': storedFingerprint,
            'options': storedOptions,
          };
        case 'config.appliedSet':
          final args = call.arguments as Map;
          storedFingerprint = args['fingerprint'] as String;
          storedOptions = Map<String, dynamic>.from(args['options'] as Map);
          return null;
        case 'config.appliedClear':
          storedFingerprint = null;
          storedOptions = null;
          return null;
        default:
          return null;
      }
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

Map<String, dynamic> build(String coreConfig) => <String, dynamic>{
      'coreConfig': coreConfig,
      'involvedProfileIds': <int>[1],
      'routeId': 0,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('A15: the accepted build is reused while the inputs hold', () {
    test('a relaunch with an unchanged fingerprint skips config.build', () async {
      final sequence = <String>[];
      final host = Host('test.applied.reuse', sequence)..builds.add(build('{"a":1}'));
      host.install();
      addTearDown(host.tearDown);

      final first = KernelService(host.box);
      addTearDown(first.dispose);
      first.debugAttach(FakeKernel(), RecordingWorker(sequence));
      await first.startService();
      expect(host.buildCount, 1);
      expect(host.storedFingerprint, 'fp-1',
          reason: 'the accepted build must be recorded after worker.start()');

      // A relaunch: same host record, a fresh driver.
      final second = KernelService(host.box);
      addTearDown(second.dispose);
      final worker = RecordingWorker(sequence);
      second.debugAttach(FakeKernel(), worker);
      await second.startService();

      expect(host.buildCount, 1, reason: 'the unchanged inputs must not be rebuilt');
      expect(worker.applied, ['{"a":1}'],
          reason: 'the recorded build is what the core is given');
      expect(second.active, isTrue,
          reason: 'A15 skips the build, never the start');
    });

    test('a changed fingerprint rebuilds', () async {
      final sequence = <String>[];
      final host = Host('test.applied.mismatch', sequence)
        ..builds.addAll([build('{"a":1}'), build('{"a":2}')]);
      host.install();
      addTearDown(host.tearDown);

      final first = KernelService(host.box);
      addTearDown(first.dispose);
      first.debugAttach(FakeKernel(), RecordingWorker(sequence));
      await first.startService();

      host.fingerprint = 'fp-2';
      final second = KernelService(host.box);
      addTearDown(second.dispose);
      final worker = RecordingWorker(sequence);
      second.debugAttach(FakeKernel(), worker);
      await second.startService();

      expect(host.buildCount, 2, reason: 'moved inputs must be rebuilt');
      expect(worker.applied, ['{"a":2}']);
      expect(host.storedFingerprint, 'fp-2',
          reason: 'the record follows the fingerprint it was built from');
    });

    test('an incomplete record is never handed to the core', () async {
      final sequence = <String>[];
      final host = Host('test.applied.incomplete', sequence)..builds.add(build('{"a":1}'));
      host.install();
      addTearDown(host.tearDown);
      // Matching stamp, but the stored build lost the profile ids (an older writer, a truncation).
      host.storedFingerprint = 'fp-1';
      host.storedOptions = <String, dynamic>{'coreConfig': '{"stale":1}'};

      final service = KernelService(host.box);
      addTearDown(service.dispose);
      final worker = RecordingWorker(sequence);
      service.debugAttach(FakeKernel(), worker);
      await service.startService();

      expect(host.buildCount, 1);
      expect(worker.applied, ['{"a":1}']);
    });

    test('a cleared record is not reused', () async {
      final sequence = <String>[];
      final host = Host('test.applied.cleared', sequence)
        ..builds.addAll([build('{"a":1}'), build('{"a":2}')]);
      host.install();
      addTearDown(host.tearDown);

      final first = KernelService(host.box);
      addTearDown(first.dispose);
      first.debugAttach(FakeKernel(), RecordingWorker(sequence));
      await first.startService();
      expect(host.storedOptions, isNotNull);

      // What a failed start leaves behind: the record was cleared before the push.
      host.storedFingerprint = null;
      host.storedOptions = null;

      final second = KernelService(host.box);
      addTearDown(second.dispose);
      final worker = RecordingWorker(sequence);
      second.debugAttach(FakeKernel(), worker);
      await second.startService();

      expect(host.buildCount, 2);
      expect(worker.applied, ['{"a":2}']);
    });

    test('the record is cleared before the config is pushed, never after a failure', () async {
      final sequence = <String>[];
      final host = Host('test.applied.failed-start', sequence)..builds.add(build('{"a":1}'));
      host.install();
      addTearDown(host.tearDown);

      final service = KernelService(host.box);
      addTearDown(service.dispose);
      final worker = RecordingWorker(sequence)..refuse = (_) => true;
      service.debugAttach(FakeKernel(), worker);
      await service.startService();

      expect(sequence.indexOf('config.appliedClear'),
          lessThan(sequence.indexOf('createInstance')),
          reason: 'a start that dies must not leave a record claiming its config');
      expect(sequence, isNot(contains('config.appliedSet')));
      expect(host.storedFingerprint, isNull);
      expect(service.active, isFalse);
    });
  });

  group('S4: a failed reload restores the previously accepted config', () {
    test('the retry uses the previous map, exactly once', () async {
      final sequence = <String>[];
      final host = Host('test.reload.restore', sequence)
        ..builds.addAll([build('{"a":1}'), build('{"a":2}'), build('{"a":3}')]);
      host.install();
      addTearDown(host.tearDown);

      final service = KernelService(host.box);
      addTearDown(service.dispose);
      final worker = RecordingWorker(sequence);
      final messages = <String>[];
      final applyFailures = <Map<String, dynamic>>[];
      final sub = service.events.listen((event) {
        if (event['type'] == 'error') messages.add(event['value'].toString());
        if (event['type'] == 'applyFailed') applyFailures.add(event);
      });
      addTearDown(sub.cancel);
      service.debugAttach(FakeKernel(), worker);
      await service.startService();
      expect(worker.applied, ['{"a":1}']);

      // The new build is refused by the core; the old one still starts.
      worker.refuse = (config) => config['coreConfig'] == '{"a":2}';
      await service.reloadService(reason: 'test');

      expect(worker.built.map((config) => config['coreConfig']),
          ['{"a":1}', '{"a":2}', '{"a":1}'],
          reason: 'one attempt at the new config, then the previous one');
      expect(service.active, isTrue);
      // The restore notice is the last thing the op emits: let the broadcast stream deliver it.
      await pumpEventQueue();
      expect(messages.any((message) => message.contains('previous')), isTrue,
          reason: 'the user must be told the previous config is back');
      // A fallback that keeps a tunnel up looks like a completed reload to the caller,
      // so the unapplied change needs its own signal for the UI's manual badge.
      expect(applyFailures, hasLength(1),
          reason: 'the fallback must tell the UI the change is still pending');
      expect(applyFailures.single['value'],
          containsPair('reason', contains('previous')));
    });

    test('a first start that fails is not retried', () async {
      final sequence = <String>[];
      final host = Host('test.reload.no-previous', sequence)..builds.add(build('{"a":1}'));
      host.install();
      addTearDown(host.tearDown);

      final service = KernelService(host.box);
      addTearDown(service.dispose);
      final worker = RecordingWorker(sequence)..refuse = (_) => true;
      final messages = <String>[];
      final sub = service.events.listen((event) {
        if (event['type'] == 'error') messages.add(event['value'].toString());
      });
      addTearDown(sub.cancel);
      service.debugAttach(FakeKernel(), worker);
      await service.startService();

      expect(worker.calls.where((call) => call == 'createInstance').length, 1,
          reason: 'nothing was ever accepted, so there is nothing to restore');
      expect(messages.any((message) => message.contains('previous')), isFalse);
      expect(service.debugLastAcceptedBuild, isNull);
    });

    test('a user stop drops the accepted config', () async {
      final sequence = <String>[];
      final host = Host('test.reload.stopped', sequence)..builds.add(build('{"a":1}'));
      host.install();
      addTearDown(host.tearDown);

      final service = KernelService(host.box);
      addTearDown(service.dispose);
      service.debugAttach(FakeKernel(), RecordingWorker(sequence));
      await service.startService();
      expect(service.debugLastAcceptedBuild, isNotNull);

      await service.stopService();
      expect(service.debugLastAcceptedBuild, isNull,
          reason: 'a later reload must not resurrect a config the user stopped');
    });
  });

  group('the persisted build is only reusable when it is complete', () {
    test('coreConfig and the profiles are required, the retired routeId is not', () {
      final complete = build('{"a":1}');
      expect(isCompleteAppliedOptions(complete), isTrue);
      expect(isCompleteAppliedOptions(Map<String, dynamic>.from(complete)..remove('coreConfig')), isFalse);
      expect(isCompleteAppliedOptions(Map<String, dynamic>.from(complete)..['coreConfig'] = ''), isFalse);
      expect(isCompleteAppliedOptions(Map<String, dynamic>.from(complete)..remove('routeId')), isTrue,
          reason: 'current config.build replies carry no routeId; requiring it disabled A15 reuse');
      expect(isCompleteAppliedOptions(Map<String, dynamic>.from(complete)..['involvedProfileIds'] = 'x'), isFalse);
    });
  });

  group('Go message-port events reach the UI engine', () {
    test('a vpnStatus push becomes a channel-shaped event', () async {
      final controller = StreamController<BridgeEvent>.broadcast();
      addTearDown(controller.close);
      final sequence = <String>[];
      final host = Host('test.kernel.vpn-push', sequence)..builds.add(build('{"a":1}'));
      host.install();
      addTearDown(host.tearDown);

      final service = KernelService(host.box);
      addTearDown(service.dispose);
      final seen = <Map<String, dynamic>>[];
      final sub = service.events.listen(seen.add);
      addTearDown(sub.cancel);
      service.debugAttach(FakeKernel(controller.stream), RecordingWorker(sequence));

      const statuses = [
        {'tag': 'office', 'state': 'needs_input', 'challenge': {'id': 'c1', 'kind': 'credentials'}},
      ];
      controller.add({'method': 'vpnStatus', 'data': statuses});
      await pumpEventQueue();
      expect(seen.where((event) => event['type'] == 'vpnStatus'), [
        {'type': 'vpnStatus', 'value': statuses},
      ]);
    });

    test('connection rows and attribution deltas become channel-shaped events', () async {
      final controller = StreamController<BridgeEvent>.broadcast();
      addTearDown(controller.close);
      final sequence = <String>[];
      final host = Host('test.kernel.connections-push', sequence)..builds.add(build('{"a":1}'));
      host.install();
      addTearDown(host.tearDown);

      final service = KernelService(host.box);
      addTearDown(service.dispose);
      final seen = <Map<String, dynamic>>[];
      final sub = service.events.listen(seen.add);
      addTearDown(sub.cancel);
      service.debugAttach(FakeKernel(controller.stream), RecordingWorker(sequence));

      const rows = [
        {'id': 'a', 'destination': 'example.com:443', 'closedAt': 0},
      ];
      const deltas = {'totalUp': 10, 'totalDown': 20, 'proxyUp': 10, 'proxyDown': 20};
      controller.add({'method': 'connections', 'data': rows});
      controller.add({'method': 'trafficDeltas', 'data': deltas});
      await pumpEventQueue();
      expect(seen.where((event) => event['type'] == 'connections'), [
        {'type': 'connections', 'value': rows},
      ]);
      expect(seen.where((event) => event['type'] == 'trafficDeltas'), [
        {'type': 'trafficDeltas', 'value': deltas},
      ]);
    });
  });
}
