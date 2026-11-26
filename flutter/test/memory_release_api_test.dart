// The "release memory" contract has two independent halves: the host action is
// ART + decoded-image trim only, the core action is the Go GC. A caller of the
// host action alone must not claim the Go heap was collected. This file pins the
// Dart-side names and the wire names so a rename cannot silently drift from the
// bridge handler (Flutter's analyzer does not check MethodChannel strings).

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Bus implements ActionInvoker {
  final calls = <({ActionMethod method, Object? data})>[];
  Object? reply = true;

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((method: method, data: data));
    return reply as T;
  }
}

class _Control implements KernelControl {
  _Control(this.bus);
  final ActionInvoker bus;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  @override
  ActionInvoker? get attached => bus;
  @override
  Stream<Map<String, dynamic>> get events => _events.stream;
  @override
  Future<void> connect({Duration timeout = Duration.zero}) async {}
  @override
  Future<void> setKernelLogsVisible(bool visible) async {}
  @override
  Future<Map<String, dynamic>> updateRuleSets() async => const {'updated': 0, 'error': ''};
  @override
  KernelPhase get kernelPhase => KernelPhase.idle;
  @override
  Duration? get uptime => null;
  @override
  bool get remote => false;
  @override
  Future<void> initialize() async {}
  @override
  Future<void> startService() async {}
  @override
  Future<void> stopService() async {}
  @override
  Future<void> reloadService({String reason = 'reload', bool Function()? skipIf, bool force = false}) async {}
  @override
  Future<void> stopCoreFromHost({int? revision}) async {}
  @override
  Future<void> updateWifiState() async {}
  @override
  Future<void> setMode(String mode) async {}
  @override
  Future<void> onSelectionChanged() async {}
  @override
  bool get active => false;
  @override
  bool get ffiMode => true;
  @override
  bool get driverReady => true;
  @override
  void dispose() => _events.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('dashboardTrimArtMemory calls the ART-only host wire', () async {
    const channel = MethodChannel('test.memory-release.api');
    final methods = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final box = BoxController(channel: channel, kernelControl: _Control(_Bus()));
    addTearDown(box.dispose);

    expect(await box.dashboardTrimArtMemory(), isTrue);
    expect(methods, ['dashboard.releaseMemory'],
        reason: 'the wire name is fixed by the bridge handler even though the Dart API is ART-specific');
  });

  test('forceGc goes to the core action bus with the full flag', () async {
    final bus = _Bus();
    final box = BoxController(
      channel: const MethodChannel('test.memory-release.gc'),
      kernelControl: _Control(bus),
    );
    addTearDown(box.dispose);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('test.memory-release.gc'), (_) async => null);
    addTearDown(() => messenger.setMockMethodCallHandler(const MethodChannel('test.memory-release.gc'), null));

    expect(await box.forceGc(full: true), isTrue);
    expect(bus.calls.single.method, ActionMethod.forceGC);
    expect(bus.calls.single.data, {'full': true},
        reason: 'the user-facing release asks for the full trim; the flag is required by the Go handler');
  });
}
