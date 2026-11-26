// Screen-off lifecycle driver for the bridge-performance action.
//
// The Go handler's JSON shape is pinned by performance_actions_test.go; this
// file pins the Dart side: "one action per real lifecycle transition" (no bus
// spam on inactive).

import 'dart:async';
import 'dart:ui' show AppLifecycleState;

import 'package:flrone/box.dart';
import 'package:flrone/core/action.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/main.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale, SizedBox;
import 'package:flutter_test/flutter_test.dart';

/// Records every bus invoke and answers the performance methods.
class _PerfBus implements ActionInvoker {
  final calls = <({ActionMethod method, Object? data})>[];
  late final Object? Function(ActionMethod method, Object? data) answer;

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((method: method, data: data));
    return answer(method, data) as T;
  }
}

class _PerfKernel implements KernelControl {
  _PerfKernel(this.bus);
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
  Future<void> reloadService({String reason = 'reload'}) async {}
  @override
  Future<void> stopCoreFromHost() async {}
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
  void dispose() {
    unawaited(_events.close());
  }
}

void main() {
  group('screen-off lifecycle', () {
    testWidgets('only hidden states flip the hint, and repeated states do not resend', (tester) async {
      final bus = _PerfBus();
      bus.answer = (method, data) {
        expect(method, ActionMethod.setScreenOff);
        return true;
      };
      final channel = MethodChannel('test.bridge.perf.lifecycle');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'ready') {
          return {'version': 'test', 'coreVersion': 'test'};
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final box = BoxController(channel: channel, kernelControl: _PerfKernel(bus));
      tester.binding.platformDispatcher.localesTestValue = const [Locale('en')];
      addTearDown(tester.binding.platformDispatcher.clearLocalesTestValue);
      await tester.pumpWidget(BoxApp(controller: box));
      await tester.pumpAndSettle();

      // Test framework starts in resumed; no action is sent until a transition.
      final initial = bus.calls.length;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(bus.calls.length, initial + 1);
      expect(bus.calls.last.data, {'off': true});

      // `inactive` is visible: the hint must stay off, and the bus must stay quiet.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(bus.calls.length, initial + 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pumpAndSettle();
      expect(bus.calls.length, initial + 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(bus.calls.length, initial + 2);
      expect(bus.calls.last.data, {'off': false});

      await tester.pumpWidget(const SizedBox());
    });
  });
}
