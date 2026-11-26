// The FFI driver's dashboard event is a *slice*, not a snapshot: it owns the
// live counters and status, while mode / selection / profile names belong to
// the channel. The service engine's host snapshot is permanently empty, so
// copying it (or padding it with defaults) fabricated values nobody measured.
//
// These tests pin the emitter at its source (KernelService with an injected
// event sink), then walk the resulting event through the real BoxController
// merge to prove a channel-owned value cannot be overwritten.

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

class _Kernel implements ThroneKernel {
  @override
  Stream<BridgeEvent> get events => const Stream.empty();

  @override
  Stream<BridgeEvent> get logs => const Stream.empty();

  @override
  ThroneFFI get ffi => throw UnimplementedError('not used');

  @override
  ReplyPort openReply() => throw UnimplementedError('not used');

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async => true as T;

  @override
  Future<dynamic> invokeWire(String wire, {Duration timeout = actionTimeout}) =>
      throw UnimplementedError('not used');

  @override
  Map<String, dynamic> get lastSpeedTestState => const {};

  @override
  Stream<Map<String, dynamic>> get speedTestStates => const Stream.empty();

  @override
  void dispose() {}
}

class _Worker implements KernelWorker {
  @override
  Stream<WorkerEvent> get events => const Stream.empty();

  @override
  Future<int> createInstance(Map<String, dynamic> built) async => 1;

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

/// A host that *does* have a populated snapshot: the emitter must still not
/// copy any of it into its own wire (the service engine's host is empty, but a
/// reader should not be able to mistake the event for a full snapshot either).
class _Host implements KernelHost {
  @override
  Map<String, dynamic> dashboard = <String, dynamic>{
    'status': 'Stopped',
    'mode': 'global',
    'modes': ['direct'],
    'selectedProfileId': 7,
    'selectedProfileName': 'Channel profile',
    'remoteConnected': true,
  };

  @override
  List<Map<String, dynamic>> get configurations => <Map<String, dynamic>>[
    {'id': 7, 'name': 'Channel group'},
  ];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the driver emits only its owned fields, with no fabricated defaults', () async {
    final events = <Map<String, dynamic>>[];
    final service = KernelService(_Host(), sink: events.add);
    addTearDown(service.dispose);
    service.debugAttach(_Kernel(), _Worker());
    // No core handle, so reloadService returns early; the trailing event is
    // still emitted so the channel sees the driver's state after the selection.
    await service.onSelectionChanged();

    final dashboards = events
        .where((event) => event['type'] == 'dashboard')
        .map((event) => event['value'] as Map<String, dynamic>)
        .toList();
    expect(dashboards, isNotEmpty);
    for (final value in dashboards) {
      expect(value.keys.where((key) => !BoxController.driverOwnedDashboard.contains(key)),
          isEmpty,
          reason: 'driver event $value leaked a channel-owned field');
      expect(value['status'], isNotEmpty);
      expect(value['startedAt'], isA<int>());
      // A snapshot with no connection counters must not invent a zero that
      // would mask the channel's real count in the merge.
      expect(value.containsKey('connections'), isFalse);
    }
  });

  test('a dashboard event from the driver cannot overwrite channel mode/name', () async {
    const channel = MethodChannel('test.kernel-dashboard-emitter');
    final events = StreamController<dynamic>.broadcast();
    final box = BoxController(channel: channel, events: events.stream);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => <String, dynamic>{
      'version': 'test',
      'coreVersion': 'test',
      'dashboard': <String, dynamic>{'status': 'Stopped'},
    });
    addTearDown(() async {
      box.dispose();
      await events.close();
      messenger.setMockMethodCallHandler(channel, null);
    });
    await box.initialize();

    // This is the channel-owned side, as the host's 1 Hz wire delivers it.
    box.handleEvent(<String, dynamic>{
      'type': 'dashboard',
      'value': <String, dynamic>{
        'status': 'Started',
        'mode': 'global',
        'modes': ['rule', 'global', 'direct'],
        'selectedProfileId': 7,
        'selectedProfileName': 'Channel profile',
        'connections': 9,
      },
    });

    final emitted = <Map<String, dynamic>>[];
    final service = KernelService(_Host(), sink: emitted.add);
    addTearDown(service.dispose);
    service.debugAttach(_Kernel(), _Worker());
    await service.onSelectionChanged();
    final value = emitted
        .where((event) => event['type'] == 'dashboard')
        .map((event) => event['value'] as Map<String, dynamic>)
        .last;

    box.handleEvent(<String, dynamic>{'type': 'dashboard', 'value': value}, fromDriver: true);

    expect(box.dashboard['mode'], 'global');
    expect(box.dashboard['selectedProfileName'], 'Channel profile');
    expect(box.dashboard['selectedProfileId'], 7);
    expect(box.dashboard['status'], value['status']);
    expect(box.dashboard['connections'], 9,
        reason: 'no connection counters in the driver event -> keep the channel count');
  });
}
