// The kernel isolate's door to the platform.
//
// Flutter's Android embedder answers platform channels on the platform thread
// (`DartExecutor` asserts it) and, since `merged_platform_ui_thread` defaults to
// enabled, runs every engine's Dart on that same thread. The kernel's boot is
// two synchronous FFI calls, so it froze the UI for the whole start; the service
// engine therefore keeps its root isolate for the channel and runs the kernel in
// a spawned isolate instead. These tests pin the port protocol between the two:
// the envelope shape, the late-reply rule, and — through a real `serviceMain` —
// the whole path from a host command on the root, over the worker, to the UI's
// IPC handshake.

import 'dart:ffi' show NativePort; // SendPort.nativePort for the IPC hello
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flrone/core/kernel_control.dart';
import 'package:flrone/service_entry.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KernelWorkerHost', () {
    late ReceivePort outbox;
    late KernelWorkerHost host;

    setUp(() {
      outbox = ReceivePort();
      host = KernelWorkerHost(outbox.sendPort);
    });
    tearDown(() => outbox.close());

    test('a host call is one {kind:host} envelope, answered by its id', () async {
      final request = host.call('config.build', <String, dynamic>{'flags': <String>[]});
      final envelope = await outbox.first as Map<String, dynamic>;
      expect(envelope['kind'], 'host');
      expect(envelope['method'], 'config.build');
      expect(envelope['args'], <String, dynamic>{'flags': <String>[]});
      expect(envelope['id'], isA<int>());
      host.complete(<String, dynamic>{
        'kind': 'hostResult',
        'id': envelope['id'],
        'result': <String, dynamic>{'ok': 1},
      });
      expect(await request, <String, dynamic>{'ok': 1});
    });

    test('an error reply fails the call instead of leaving it pending', () async {
      final request = host.call('service.start');
      final envelope = await outbox.first as Map<String, dynamic>;
      host.complete(<String, dynamic>{
        'kind': 'hostResult',
        'id': envelope['id'],
        'error': 'boom',
      });
      await expectLater(
        request,
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('boom'))),
      );
    });

    test('a reply nobody waits for is ignored', () {
      expect(
        () => host.complete(<String, dynamic>{'kind': 'hostResult', 'id': 999, 'result': 1}),
        returnsNormally,
      );
    });
  });

  group('serviceMain', () {
    test('the root serves host calls and the worker answers the UI hello', () async {
      const channel = MethodChannel('io.flrone/service');
      final methods = <String>[];
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      // A prewarm entrypoint: no automatic tunnel start, so the handshake is the
      // only traffic this test has to reason about.
      await serviceMain(const <String>['prewarm']);

      // The worker registers the IPC port once it is up; poll like the proxy does.
      SendPort? service;
      for (var attempt = 0; attempt < 100 && service == null; attempt++) {
        service = IsolateNameServer.lookupPortByName(servicePortName);
        if (service == null) await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(service, isNotNull, reason: 'the kernel worker never registered "$servicePortName"');

      final ui = ReceivePort();
      addTearDown(ui.close);
      // The handshake resolves the UI's port by name (the wire carries the native
      // port number), exactly as KernelProxy.connect registers it before hello.
      final uiName = uiPortName(ui.sendPort.nativePort);
      IsolateNameServer.registerPortWithName(ui.sendPort, uiName);
      addTearDown(() => IsolateNameServer.removePortNameMapping(uiName));
      service!.send(<String, dynamic>{
        'id': 'hello-1',
        'method': 'hello',
        'data': <String, dynamic>{'port': ui.sendPort.nativePort},
      });
      Map<String, dynamic>? reply;
      await for (final raw in ui.timeout(const Duration(seconds: 10))) {
        if (raw is Map && raw['id'] == 'hello-1') {
          reply = Map<String, dynamic>.from(raw);
          break;
        }
      }
      expect(reply, isNotNull, reason: 'the worker never answered hello');
      // The wire carries the request envelope (`{id, result|error}`) under
      // `result`, one level above the method's own payload.
      final envelope = reply!['result'] as Map<String, dynamic>;
      final result = envelope['result'] as Map<String, dynamic>;
      expect(result['ok'], true);
      expect(result['status'], 'Stopped');
      // No libthrone.so on the test host: the handshake must report the real
      // attach state, not the engine's existence.
      expect(result['driverReady'], false);
      // ...and the worker reached the platform through the root isolate's channel.
      expect(methods, contains('driver.ready'));
    });
  });
}
