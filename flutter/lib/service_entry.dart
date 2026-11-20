// Service-engine entry point (phase 1 of the engine split).
//
// A second Flutter engine runs this entry point. It owns the FFI kernel, the
// in-process worker (kernel_worker.dart, Bettbox-style: no worker isolate) and
// the platform channel. The UI engine only sees a [KernelProxy]
// (kernel_proxy.dart) speaking the small map IPC defined in kernel_control.dart
// over IsolateNameServer.
//
// Modelled on Bettbox's `_service` / `_handleMainIpc` (lib/main.dart): register
// a named port, answer requests, and forward kernel events to the UI's port.

import 'dart:async';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'core/kernel_control.dart';
import 'core/kernel_service.dart';
import 'core/platform_value.dart';
import 'core/throne_kernel.dart';

@pragma('vm:entry-point')
Future<void> serviceMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // TODO(phase2): interpret `quick`/`boot` and auto-start the core here. Phase 1
  // only records them; the UI still drives start/stop explicitly.
  final quick = args.contains('quick');
  final boot = args.contains('boot');
  debugPrint('serviceMain: ready (quick=$quick boot=$boot)');

  final host = ServiceBridgeClient();
  final eventsToUi = StreamController<Map<String, dynamic>>.broadcast();
  final service = KernelService(
    host,
    sink: eventsToUi.add,
  );

  final servicePort = ReceivePort();
  IsolateNameServer.registerPortWithName(servicePort.sendPort, servicePortName);

  SendPort? uiPort;

  /// Sends a message to the most recently greeted UI engine, if any.
  void deliver(Object? message) {
    final port = uiPort;
    if (port == null) return;
    try {
      port.send(message);
    } catch (error) {
      debugPrint('serviceMain: failed to send to UI: $error');
    }
  }

  // Forward every kernel event to the UI as `{type:'event',value:<event>}`.
  // Installed once; `deliver` is a no-op until a UI engine says hello.
  final eventSub = eventsToUi.stream.listen((event) {
    deliver(<String, dynamic>{'type': 'event', 'value': event});
  });

  // Resolve the UI's port from the native port number carried by `hello`.
  // Both engines share the process-wide IsolateNameServer.
  SendPort? resolveUi(int nativePort) =>
      IsolateNameServer.lookupPortByName(uiPortName(nativePort));

  servicePort.listen((raw) async {
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    final id = message['id'] as String?;
    final method = message['method'] as String?;
    final data = message['data'];
    if (id == null || method == null) return;

    Object? result;
    Object? error;
    try {
      switch (method) {
        case 'hello':
          final port =
              (data is Map<String, dynamic> ? data['port'] : null) as num?;
          if (port == null) throw const FormatException('hello is missing port');
          final resolved = resolveUi(port.toInt());
          if (resolved == null) {
            throw StateError('the UI port was not registered for $port');
          }
          uiPort = resolved;
          // The reply carries the engine's current status so a (re)connecting
          // proxy resyncs instead of trusting the last event of a previous
          // link (kernel_proxy reads `status` off this map).
          result = <String, dynamic>{'ok': true, 'status': service.statusWire};
        case 'start':
          await service.startService();
          result = true;
        case 'stop':
          await service.stopService();
          result = true;
        case 'reload':
          final reason =
              (data is Map<String, dynamic> ? data['reason'] : null) as String?;
          await service.reloadService(reason: reason ?? 'reload');
          result = true;
        case 'action':
          if (data is! String) {
            throw const FormatException('action data must be an Action JSON string');
          }
          result = await service.invokeActionWire(data);
        case 'setMode':
          final mode =
              (data is Map<String, dynamic> ? data['mode'] : null) as String?;
          if (mode == null) throw const FormatException('setMode is missing mode');
          await service.setMode(mode);
          result = true;
        case 'onSelectionChanged':
          await service.onSelectionChanged();
          result = true;
        case 'warpRegister':
          final tunnelType =
              (data is Map<String, dynamic> ? data['tunnelType'] : null)
                  as String?;
          if (tunnelType == null) {
            throw const FormatException('warpRegister is missing tunnelType');
          }
          result = await service.warpRegister(tunnelType);
        default:
          throw UnsupportedError('unknown kernel IPC method: $method');
      }
    } catch (e) {
      error = e;
    }
    deliver(<String, dynamic>{
      'id': id,
      'result': <String, dynamic>{
        'id': id,
        if (error == null) 'result': result else 'error': '$error',
      },
    });
  });

  // Host-pushed events for this engine: the Wi-Fi monitor and IPC reconnect
  // hints. The UI engine's channel handlers cannot serve these — the monitor
  // belongs to the process, not to the UI engine.
  const MethodChannel('io.flrone/service').setMethodCallHandler((call) async {
    switch (call.method) {
      case 'reconnectIpc':
        // The service port stays registered for the life of this engine; the UI
        // reconnects by looking it up, so there is nothing to rebuild here.
        debugPrint('serviceMain: reconnectIpc');
      case 'reload':
        unawaited(service.reloadService(reason: 'host reload').catchError(
          (Object error) => debugPrint('serviceMain: host reload failed: $error'),
        ));
      case 'serviceStop':
        unawaited(service.stopCoreFromHost().catchError(
          (Object error) => debugPrint('serviceMain: host stop failed: $error'),
        ));
      case 'startKernel':
        // The host reused an engine that was already running (silent start after a
        // previous session); serviceMain's one-shot auto-start has already run.
        unawaited(service.startService().catchError((Object error) {
          debugPrint('serviceMain: host start failed: $error');
          deliver(<String, dynamic>{
            'type': 'event',
            'value': <String, dynamic>{'type': 'error', 'value': '$error'},
          });
        }));
    }
    return null;
  });
  const EventChannel('io.flrone/service/events')
      .receiveBroadcastStream()
      .listen((raw) {
    final event = normalizePlatformValue(raw);
    if (event is Map && event['type'] == 'wifi.state') {
      unawaited(service.updateWifiState().catchError((Object error) {
        debugPrint('serviceMain: wifi.state failed: $error');
      }));
    }
  }, onError: (Object error) {
    debugPrint('serviceMain: service event stream error: $error');
  });

  // Best-effort: attach the FFI driver on engine start. When the library is
  // absent the service stays in channel mode and every control request simply
  // falls through to the host, so the app remains usable.
  try {
    await service.initialize();
  } catch (error) {
    debugPrint('serviceMain: kernel driver unavailable: $error');
  }

  // The service engine owns the tunnel: a start requested by the UI, a tile,
  // a widget, always-on VPN or the boot receiver all arrive here with no other
  // Dart side to drive the core. Bring it up from the persisted selection. The
  // short delay lets BaseService finish registering the VpnService before the
  // kernel asks for its tun.
  Future<void>.delayed(const Duration(milliseconds: 300), () async {
    try {
      await service.startService();
    } catch (error) {
      debugPrint('serviceMain: automatic start failed: $error');
      deliver(<String, dynamic>{
        'type': 'event',
        'value': <String, dynamic>{'type': 'error', 'value': '$error'},
      });
    }
  });

  // The UI engine can no longer open the native logs port itself; forward each
  // kernel log line as an IPC event so the log screen keeps working.
  final attached = service.attached;
  StreamSubscription<dynamic>? logSub;
  if (attached is ThroneKernel) {
    logSub = attached.logs.listen((line) {
      deliver(<String, dynamic>{
        'type': 'event',
        'value': <String, dynamic>{'type': 'kernelLog', 'value': line},
      });
    }, onError: (error) {
      debugPrint('serviceMain: kernel log stream error: $error');
    });
  }

  // serviceMain runs for the lifetime of the app; keep the subscriptions live.
  // (Retained in locals so the analyzer does not flag them as unused.)
  assert(() {
    debugPrint('serviceMain: subscriptions ${eventSub.isPaused} / ${logSub != null}');
    return true;
  }());
}

/// The service engine's [KernelHost]. A MethodChannel in this engine handles
/// the Android duties; the two getters are display-only snapshots.
///
/// TODO(phase2): populate [dashboard] and [profiles] from the platform side
/// (or forward them from the UI in `hello`) so the kernel's emitted dashboard
/// events carry the selected group name. Today they stay empty, which means
/// kernel events use empty static fields until the channel dashboard arrives.
class ServiceBridgeClient implements KernelHost {
  final MethodChannel _channel = const MethodChannel('io.flrone/service');

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) =>
      _channel.invokeMethod<dynamic>(method, args);

  @override
  Map<String, dynamic> dashboard = <String, dynamic>{};

  @override
  List<Map<String, dynamic>> profiles = const <Map<String, dynamic>>[];
}
