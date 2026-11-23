// The rules-only re-apply path (FlClash's `applyProfileDebounce`,
// providers/actions/profiles.dart:180-183). The host sends `configChanged` when a
// refresh re-pointed only the running config's content — it checked that the
// profile and route a build resolves are still the running ones — and every other
// case (a profile or route switch, a stopped service) keeps the `applyRequired`
// badge. These tests drive the BoxController side with a fake event stream and a
// fake kernel, so the debounce, the collapse and the failure surfaces are all
// observable without a service.

import 'dart:async';

import 'package:flrone/box.dart';
import 'package:flrone/core/kernel_control.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeKernel implements KernelControl {
  int reloads = 0;
  String? lastReason;

  /// The error a reload throws; null means it completed (a skip reads the same).
  Object? failWith;

  @override
  Future<void> reloadService({String reason = 'reload'}) async {
    reloads++;
    lastReason = reason;
    final error = failWith;
    if (error != null) throw error;
  }

  @override
  Future<void> connect({Duration timeout = Duration.zero}) async {}
  @override
  Future<void> initialize() async {}
  @override
  Future<void> startService() async {}
  @override
  Future<void> stopService() async {}
  @override
  Future<void> stopCoreFromHost() async {}
  @override
  Future<void> setKernelLogsVisible(bool visible) async {}
  @override
  Future<void> updateWifiState() async {}
  @override
  Future<Map<String, dynamic>> updateRuleSets() async => const {'updated': 0, 'error': ''};
  @override
  Future<void> setMode(String mode) async {}
  @override
  Future<void> onSelectionChanged() async {}
  @override
  bool get active => false;
  @override
  KernelPhase get kernelPhase => KernelPhase.idle;
  @override
  bool get remote => false;
  @override
  Duration? get uptime => null;
  @override
  bool get ffiMode => true;
  @override
  bool get driverReady => true;
  @override
  ActionInvoker? get attached => null;
  @override
  Stream<Map<String, dynamic>> get events => const Stream.empty();
  @override
  void dispose() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.autoapply');
  late StreamController<dynamic> events;
  late _FakeKernel kernel;
  late BoxController box;
  var disposed = false;
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void serve(String status) {
    messenger.setMockMethodCallHandler(channel, (call) async => call.method == 'ready'
        ? {
            'version': 'test',
            'coreVersion': 'test',
            'dashboard': {'status': status},
          }
        : <String, dynamic>{});
  }

  setUp(() {
    disposed = false;
    events = StreamController<dynamic>.broadcast();
    kernel = _FakeKernel();
    box = BoxController(channel: channel, events: events.stream, kernelControl: kernel);
    serve('Started');
  });

  tearDown(() async {
    if (!disposed) box.dispose();
    await events.close();
    messenger.setMockMethodCallHandler(channel, null);
  });

  Future<void> ready() async {
    await box.initialize();
    expect(box.running, isTrue, reason: 'the scenarios start from a running tunnel');
  }

  void change() => events.add({'type': 'configChanged', 'value': {'gid': 1}});

  testWidgets('a rules-only change reloads once, after the debounce', (tester) async {
    await ready();
    change();
    await tester.pump();

    // Inside the window nothing is applied and no badge is raised: the refresh is
    // still arriving and the running config serves until the reload.
    await tester.pump(const Duration(seconds: 1));
    expect(kernel.reloads, 0);
    expect(box.applyRequired, isNull);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(kernel.reloads, 1);
    expect(kernel.lastReason, contains('refresh'));
    expect(box.applyRequired, isNull);
  });

  testWidgets('a burst of changes collapses into one reload at its end', (tester) async {
    await ready();
    for (var i = 0; i < 4; i++) {
      change();
      await tester.pump(const Duration(milliseconds: 700));
    }
    // 2.8 s after the first report, but only 700 ms after the last: the window
    // keeps moving, so nothing has been reloaded yet.
    expect(kernel.reloads, 0);

    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    expect(kernel.reloads, 1, reason: 'one reload for the whole burst');
  });

  testWidgets('a profile switch keeps the manual badge and never auto-reloads', (tester) async {
    await ready();
    events.add({'type': 'applyRequired', 'value': 'Reload'});
    await tester.pump();
    expect(box.applyRequired, 'Reload');

    await tester.pump(const Duration(seconds: 5));
    expect(kernel.reloads, 0);
    expect(box.applyRequired, 'Reload');
  });

  testWidgets('a switch inside the window cancels the queued reload', (tester) async {
    await ready();
    change();
    await tester.pump(const Duration(milliseconds: 500));
    events.add({'type': 'applyRequired', 'value': 'Reload'});
    await tester.pump(const Duration(seconds: 3));

    // The switch is what a build resolves now; the queued reload would apply a
    // config the user has already moved past.
    expect(kernel.reloads, 0);
    expect(box.applyRequired, 'Reload');
  });

  testWidgets('a stopped service never reloads', (tester) async {
    serve('Stopped');
    await box.initialize();
    expect(box.running, isFalse);

    change();
    await tester.pump(const Duration(seconds: 3));
    expect(kernel.reloads, 0);
    expect(box.applyRequired, isNull);
  });

  testWidgets('a stop inside the window cancels the queued reload', (tester) async {
    await ready();
    change();
    await tester.pump(const Duration(milliseconds: 500));
    events.add({'type': 'dashboard', 'value': {'status': 'Stopped'}});
    await tester.pump(const Duration(seconds: 3));

    expect(box.running, isFalse);
    expect(kernel.reloads, 0, reason: 'the next start builds the changed config anyway');
  });

  testWidgets('a change during a start is applied once the tunnel reports Started', (tester) async {
    serve('Starting');
    await box.initialize();
    expect(box.running, isFalse);
    expect(box.transitioning, isTrue);

    // The start may have read the documents before this change landed.
    change();
    await tester.pump(const Duration(seconds: 3));
    expect(kernel.reloads, 0);

    events.add({'type': 'dashboard', 'value': {'status': 'Started'}});
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(kernel.reloads, 0, reason: 'the window starts when the tunnel is up');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(kernel.reloads, 1);
  });

  testWidgets('a change during a start that fails is dropped', (tester) async {
    serve('Starting');
    await box.initialize();
    change();
    await tester.pump(const Duration(seconds: 3));

    events.add({'type': 'dashboard', 'value': {'status': 'Stopped'}});
    await tester.pump(const Duration(seconds: 3));
    expect(kernel.reloads, 0);
    expect(box.applyRequired, isNull, reason: 'nothing is running to badge');
  });

  testWidgets('disposing cancels a queued reload', (tester) async {
    await ready();
    change();
    await tester.pump(const Duration(milliseconds: 500));
    box.dispose();
    disposed = true;

    await tester.pump(const Duration(seconds: 3));
    expect(kernel.reloads, 0);
  });

  testWidgets('a failed reload surfaces the manual badge again', (tester) async {
    kernel.failWith = const KernelProxyException('the core refused the config');
    await ready();
    change();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(kernel.reloads, 1);
    expect(box.applyRequired, 'Reload', reason: 'the change is still unapplied');
    expect(box.running, isTrue);
  });

  testWidgets('a reload that fell back to the previous config raises the badge', (tester) async {
    await ready();
    events.add({'type': 'applyFailed', 'value': {'reason': 'the previous one was restored'}});
    await tester.pump();

    // KernelService.reloadService emitted it after the fallback kept the old
    // config running: the tunnel is up, the new rules are not.
    expect(box.applyRequired, 'Reload');
    expect(kernel.reloads, 0);
  });

  testWidgets('a successful auto-apply clears a stale Reload badge', (tester) async {
    await ready();
    box.applyRequired = 'Reload';
    change();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(kernel.reloads, 1);
    expect(box.applyRequired, isNull, reason: 'the reload applied what the badge was about');
  });

  testWidgets('a successful auto-apply keeps a Restart badge', (tester) async {
    await ready();
    box.applyRequired = 'Restart';
    change();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(kernel.reloads, 1);
    expect(box.applyRequired, 'Restart', reason: 'a process-level change outranks a reload');
  });
}
