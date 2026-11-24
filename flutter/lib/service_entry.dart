// Service-engine entry point (phase 1 of the engine split).
//
// A second Flutter engine runs this entry point. It owns the FFI kernel, the
// in-process worker (kernel_worker.dart, Bettbox-style: no worker isolate for
// the kernel's own bookkeeping) and the platform channel. The UI engine only
// sees a [KernelProxy] (kernel_proxy.dart) speaking the small map IPC defined in
// kernel_control.dart over IsolateNameServer.
//
// Two isolates, one engine — and why:
//
// The Android embedder merges the platform and UI task runners
// (`flutter::Settings::merged_platform_ui_thread` defaults to `kEnabled`,
// common/settings.h), so a `FlutterEngine` constructed on the main thread runs
// *its* Dart isolates on the main thread too — the same thread the UI engine
// builds frames on. The kernel's boot is two synchronous FFI calls
// (`ThroneCore.create` + `start`, 365 ms measured: service 6, config 37,
// instance 169, start 159), so running `KernelService.startService` from this
// entrypoint froze the UI for the whole start. That was the start-only jank the
// card kept showing, and it explained the probes' silence: no `slow event` (the
// UI's own handlers were idle), no `frame work` (no frame could begin), no
// `ipc lag` (the sender was the busy side — nothing was in flight, so nothing
// arrived late). `ui stall 303ms` at `last=rates`, bracketing `core started in
// 365ms`, was the shared thread.
//
// So:
//   * this root isolate stays on the platform thread and owns only the
//     `io.flrone/service` MethodChannel and EventChannel — the embedding answers
//     channels on the platform thread (`DartExecutor` asserts it). It forwards
//     every host command to the worker and runs the worker's `host.call`s here.
//   * [kernelWorker] runs on its own VM thread (a spawned isolate is not merged),
//     where `KernelService`, the FFI driver and the UI-facing IPC port live. It
//     keeps this engine's isolate group, so the kernel's heap and GC stay
//     separate from the UI engine's — the reason the engine is standalone
//     (`ServiceEngineManager`).
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
import 'core/log_batch.dart';
import 'core/platform_value.dart';
import 'core/throne_kernel.dart';

/// The service engine's root isolate: the platform channel, and nothing else.
///
/// Every kernel operation is forwarded to [kernelWorker]. Commands that arrive
/// before the worker said hello are queued: `ServiceBridge.startKernel` only
/// retries on a thrown `MissingPluginException`, so a silently dropped command
/// (a tile/boot start racing the worker's spawn) would surface as a tunnel that
/// never came up.
@pragma('vm:entry-point')
Future<void> serviceMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('io.flrone/service');
  final inbox = ReceivePort();
  SendPort? worker;
  final queued = <Map<String, dynamic>>[];

  void send(Map<String, dynamic> command) {
    final port = worker;
    if (port == null) {
      queued.add(command);
      return;
    }
    port.send(command);
  }

  inbox.listen((raw) {
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    switch (message['kind']) {
      case 'ready':
        final port = message['port'];
        if (port is! SendPort) return;
        worker = port;
        for (final command in queued) {
          port.send(command);
        }
        queued.clear();
      case 'host':
        // The worker's door to the platform. Answering here (and not there) is
        // what keeps this channel on the platform thread the embedding expects.
        final method = message['method'];
        if (method is! String) return;
        final arguments = message['args'];
        _serveHostCall(
          method,
          arguments is Map<String, dynamic> ? arguments : null,
          message['id'],
          () => worker,
        );
    }
  });

  // Host-pushed events for this engine: the Wi-Fi monitor and IPC reconnect
  // hints. The UI engine's channel handlers cannot serve these — the monitor
  // belongs to the process, not to the UI engine.
  channel.setMethodCallHandler((call) async {
    int? revision() => call.arguments is Map
        ? ((call.arguments as Map)['revision'] as num?)?.toInt()
        : null;
    switch (call.method) {
      case 'reconnectIpc':
        // The service port stays registered for the life of the kernel isolate;
        // the UI reconnects by looking it up, so there is nothing to rebuild.
        debugPrint('serviceMain: reconnectIpc');
      case 'reload':
        send(<String, dynamic>{'kind': 'command', 'method': 'reload'});
      case 'serviceStop':
        // The revision is the one in force when the STOP command arrived; a start
        // that landed after it claims a higher one and this stop is stale
        // (FlClash's notifyStopped commandRevision contract).
        send(<String, dynamic>{
          'kind': 'command',
          'method': 'serviceStop',
          'revision': revision(),
        });
      case 'startKernel':
        send(<String, dynamic>{
          'kind': 'command',
          'method': 'startKernel',
          'revision': revision(),
        });
    }
    return null;
  });
  const EventChannel('io.flrone/service/events')
      .receiveBroadcastStream()
      .listen((raw) {
    final event = normalizePlatformValue(raw);
    if (event is Map && event['type'] == 'wifi.state') {
      send(<String, dynamic>{'kind': 'command', 'method': 'wifi.state'});
    }
  }, onError: (Object error) {
    debugPrint('serviceMain: service event stream error: $error');
  });

  try {
    await Isolate.spawn<List<Object?>>(
      kernelWorker,
      <Object?>[inbox.sendPort, args],
      debugName: 'kernel',
    );
  } catch (error) {
    debugPrint('serviceMain: kernel worker spawn failed: $error');
  }
}

/// Runs one [KernelHost.call] for the worker and ships the answer back.
///
/// The reply is `{kind: hostResult, id, result}` or `... error`, the same
/// request/response shape the UI's proxy uses, so timeouts stay observable.
void _serveHostCall(
  String method,
  Map<String, dynamic>? arguments,
  Object? id,
  SendPort? Function() worker,
) {
  // A reply that never leaves this isolate leaves the kernel waiting on its
  // timeout, so a synchronous codec failure answers like an async one.
  void answer(Object? result, Object? error) => worker()?.send(<String, dynamic>{
    'kind': 'hostResult',
    'id': id,
    if (error == null) 'result': result else 'error': '$error',
  });
  try {
    const MethodChannel('io.flrone/service')
        .invokeMethod<dynamic>(method, arguments)
        .then<void>(
      (result) => answer(result, null),
      onError: (Object error) => answer(null, error),
    );
  } catch (error) {
    answer(null, error);
  }
}

/// The kernel isolate: [KernelService], the FFI driver, and the UI's port.
@pragma('vm:entry-point')
Future<void> kernelWorker(List<Object?> message) async {
  final root = message[0] as SendPort;
  final args = (message[1] as List).cast<String>();
  // The root's commands and its answers to this isolate's `host.call`s share one
  // port: both are addressed to this isolate, and one inbound queue keeps their
  // order relative to the kernel's own work.
  final commandPort = ReceivePort();

  // The kernel's log tail: encoded lines wait for a screen to watch them. Declared here so
  // the UI's `kernelLogsVisible` request (handled below) and the tail's own listener share
  // one state.
  final pendingLogs = <String>[];
  final kernelRing = <String>[];
  var kernelLogsWanted = false;

  // TODO(phase2): interpret `quick`/`boot` and auto-start the core here. Phase 1
  // only records them; the UI still drives start/stop explicitly.
  final quick = args.contains('quick');
  final boot = args.contains('boot');
  debugPrint('kernelWorker: ready (quick=$quick boot=$boot)');

  final host = KernelWorkerHost(root);
  final eventsToUi = StreamController<Map<String, dynamic>>.broadcast();
  final service = KernelService(
    host,
    sink: eventsToUi.add,
  );

  /// The host must not assume the driver is engaged just because this engine
  /// exists: `KernelService.initialize()` returns silently when libthrone.so is
  /// absent, leaving a connected notification with no core. Push the *real*
  /// attach state (`ffiMode == _kernel != null`) to `BboxKernel.ffiMode` on the
  /// host. Best effort — a channel failure here must not abort engine startup;
  /// the hello handshake also carries this fact for the UI proxy.
  Future<void> pushDriverReady() async {
    // ServiceBridge.attach() installs the host's MethodChannel handler on the
    // Kotlin side just after this engine is created; it can still be in flight
    // while initialize() runs here. Retry briefly so the fact is not lost to
    // that race (a missing handler surfaces as MissingPluginException).
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await host.call('driver.ready', <String, dynamic>{'ready': service.driverReady});
        return;
      } catch (error) {
        if (attempt == 4) {
          debugPrint('kernelWorker: driver.ready push failed: $error');
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  // The UI talks to this isolate directly: it resolves the name this port is
  // registered under, so kernel events pay no forwarding hop and `sentAt` is
  // stamped by the isolate that owns the kernel's clock.
  final servicePort = ReceivePort();
  IsolateNameServer.registerPortWithName(servicePort.sendPort, servicePortName);
  root.send(<String, dynamic>{'kind': 'ready', 'port': commandPort.sendPort});

  SendPort? uiPort;

  /// Sends a message to the most recently greeted UI engine, if any.
  ///
  /// Every envelope is stamped: the UI measures receive-time minus `sentAt` and
  /// reports a large lag, which is the only window that covers the transport's
  /// deserialization on the receiving isolate — work no Dart callback timer can
  /// see (a 200 ms freeze that was neither an event handler nor a frame).
  void deliver(Object? message) {
    final port = uiPort;
    if (port == null) return;
    final stamped = message is Map<String, dynamic>
        ? (message
          ..['sentAt'] = DateTime.now().millisecondsSinceEpoch)
        : message;
    try {
      port.send(stamped);
    } catch (error) {
      debugPrint('kernelWorker: failed to send to UI: $error');
    }
  }

  // Forward every kernel event to the UI as `{type:'event',value:<event>}`.
  // Installed once; `deliver` is a no-op until a UI engine says hello. The last
  // dashboard is kept so a late hello can resync the UI with it.
  Map<String, dynamic>? lastDashboard;
  final eventSub = eventsToUi.stream.listen((event) {
    if (event['type'] == 'dashboard' && event['value'] is Map<String, dynamic>) {
      lastDashboard = event['value'] as Map<String, dynamic>;
    }
    deliver(<String, dynamic>{'type': 'event', 'value': event});
  });

  // Resolve the UI's port from the native port number carried by `hello`.
  // Both engines share the process-wide IsolateNameServer.
  SendPort? resolveUi(int nativePort) =>
      IsolateNameServer.lookupPortByName(uiPortName(nativePort));

  // Host commands forwarded by the root isolate (its channel is the only door
  // the host has: start/stop/reload and the Wi-Fi monitor).
  commandPort.listen((raw) {
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    if (message['kind'] == 'hostResult') {
      host.complete(message);
      return;
    }
    if (message['kind'] != 'command') return;
    final revision = (message['revision'] as num?)?.toInt();
    switch (message['method']) {
      case 'reload':
        unawaited(service.reloadService(reason: 'host reload').catchError(
          (Object error) => debugPrint('kernelWorker: host reload failed: $error'),
        ));
      case 'serviceStop':
        unawaited(service.stopCoreFromHost(revision: revision).catchError(
          (Object error) => debugPrint('kernelWorker: host stop failed: $error'),
        ));
      case 'startKernel':
        unawaited(service.startService(revision: revision).catchError((Object error) {
          debugPrint('kernelWorker: host start failed: $error');
          deliver(<String, dynamic>{
            'type': 'event',
            'value': <String, dynamic>{'type': 'error', 'value': '$error'},
          });
        }));
      case 'wifi.state':
        unawaited(service.updateWifiState().catchError((Object error) {
          debugPrint('kernelWorker: wifi.state failed: $error');
        }));
    }
  });

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
          // link (kernel_proxy reads `status` and `driverReady` off this map).
          // `driverReady` is the real FFI-attach state: a stale proxy must
          // release driver arbitration when a fresh engine has no driver.
          // The last dashboard rides along: events emitted before this hello
          // (an auto-start that already ran) had no port to reach.
          result = <String, dynamic>{
            'ok': true,
            'status': service.statusWire,
            'driverReady': service.driverReady,
            'dashboard': ?lastDashboard,
          };
        case 'start':
          await service.startService();
          result = true;
        case 'stop':
          await service.stopService();
          result = true;
        case 'stopCore':
          await service.stopCoreFromHost();
          result = true;
        case 'reload':
          final reason =
              (data is Map<String, dynamic> ? data['reason'] : null) as String?;
          await service.reloadService(reason: reason ?? 'reload');
          result = true;
        case 'updateWifiState':
          await service.updateWifiState();
          result = true;
        // The manual "Update resources" rule-set half (KernelProxy). A refusal
        // (no running instance) leaves this `case` as the ordinary error
        // envelope below, so the UI rebuilds the same typed exception.
        case 'updateRuleSets':
          result = await service.updateRuleSets();
        case 'kernelLogsVisible':
          // A screen opened: replay the ring as one snapshot (reset) and stream from here.
          // A screen closed: keep filling the ring, send nothing.
          kernelLogsWanted =
              (data is Map<String, dynamic> ? data['visible'] : null) == true;
          if (kernelLogsWanted) {
            deliver(<String, dynamic>{
              'type': 'event',
              'value': <String, dynamic>{
                'type': 'kernelLogs',
                'value': <String, dynamic>{
                  'payload': kernelRing.join('\n'),
                  'reset': true,
                },
              },
            });
          }
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
        default:
          throw UnsupportedError('unknown kernel IPC method: $method');
      }
    } catch (e) {
      error = e;
    }
    final envelope = <String, dynamic>{'id': id};
    if (error == null) {
      envelope['result'] = result;
    } else {
      // One envelope for every failure shape: `kind: unanswered` when nothing
      // answered (the UI keeps the start button optimistic), the kernel's
      // `core_<n>` code plus the handler's payload when the core refused. A
      // string alone could not carry that split — an older peer sent a bare
      // `kind: 'failed'`, which the proxy still reads as a refusal.
      envelope.addAll(coreErrorEnvelope(error));
    }
    deliver(<String, dynamic>{'id': id, 'result': envelope});
  });

  // Best-effort: attach the FFI driver on engine start. When the library is
  // absent the service stays in channel mode and every control request simply
  // falls through to the host, so the app remains usable.
  try {
    await service.initialize();
  } catch (error) {
    debugPrint('kernelWorker: kernel driver unavailable: $error');
  }
  // Report the outcome to the host so BboxKernel.ffiMode reflects a real FFI
  // attach, not the engine's existence (the two only match when libthrone.so
  // loaded and a worker was spawned).
  await pushDriverReady();
  // ...and to the UI over IPC. A hello handled before initialize() finished
  // stored driverReady=false as authoritative; without this push the proxy
  // would stay in channel mode for the life of the link, writing selection and
  // mode changes to the channel while this isolate drives the core over FFI.
  deliver(<String, dynamic>{
    'type': 'event',
    'value': <String, dynamic>{
      'type': 'driverReady',
      'value': service.driverReady,
    },
  });

  // The service engine owns the tunnel: a start requested by the UI, a tile, a
  // widget, always-on VPN or the boot receiver all arrive here with no other
  // Dart side to drive the core. Bring it up from the persisted selection. The
  // short delay lets BaseService finish registering the VpnService before the
  // kernel asks for its tun. A pre-warm engine ([ServiceEngineManager.ARG_PREWARM])
  // must stay idle — its real start arrives later over IPC/startKernel.
  if (!args.contains('prewarm')) {
    Future<void>.delayed(const Duration(milliseconds: 300), () async {
      try {
        await service.startService();
      } catch (error) {
        debugPrint('kernelWorker: automatic start failed: $error');
        deliver(<String, dynamic>{
          'type': 'event',
          'value': <String, dynamic>{'type': 'error', 'value': '$error'},
        });
      }
    });
  }

  // The UI engine can no longer open the native logs port itself; forward kernel
  // log lines as IPC events so the log screen keeps working.
  //
  // Lines travel as ONE encoded string per batch (`receivedAt\tlevel\tmessage`
  // joined by newlines), not as a list of maps: a map per line is copied key by key
  // across the isolate boundary, and a start emits hundreds of them at once. The UI
  // splits the payload in a single pass, which is also the only decode it needs.
  //
  // And nothing crosses at all while no screen is watching ([setKernelLogsVisible]):
  // the ring below keeps the tail, so opening the log screen replays it — a start's
  // burst costs the UI isolate nothing until somebody looks.
  Timer? logTimer;
  void flushLogs() {
    logTimer = null;
    if (pendingLogs.isEmpty) return;
    final payload = pendingLogs.join('\n');
    pendingLogs.clear();
    deliver(<String, dynamic>{
      'type': 'event',
      'value': <String, dynamic>{
        'type': 'kernelLogs',
        'value': <String, dynamic>{'payload': payload, 'reset': false},
      },
    });
  }

  /// One line of the wire: the arrival instant, the level word and the text, with the
  /// text flattened so a stray newline cannot split a record.
  String encodeKernelLine(Map<String, dynamic> line) =>
      '${DateTime.now().millisecondsSinceEpoch}'
      '\t${line['level'] ?? ''}'
      '\t${(line['message']?.toString() ?? '').replaceAll('\n', ' ')}';

  final attached = service.attached;
  StreamSubscription<dynamic>? logSub;
  if (attached is ThroneKernel) {
    logSub = attached.logs.listen((line) {
      final encoded = encodeKernelLine(line);
      kernelRing.add(encoded);
      if (kernelRing.length > logRingLimit) {
        kernelRing.removeRange(0, kernelRing.length - logRingLimit);
      }
      if (!kernelLogsWanted) return;
      pendingLogs.add(encoded);
      if (pendingLogs.length >= maxKernelLogBatchLines) {
        logTimer?.cancel();
        flushLogs();
      } else {
        logTimer ??= Timer(logBatchWindow, flushLogs);
      }
    }, onError: (error) {
      debugPrint('kernelWorker: kernel log stream error: $error');
    });
  }

  // kernelWorker runs for the lifetime of the app; keep the subscriptions live.
  // (Retained in locals so the analyzer does not flag them as unused.)
  assert(() {
    debugPrint('kernelWorker: subscriptions ${eventSub.isPaused} / ${logSub != null}');
    return true;
  }());
}

/// The kernel isolate's door to the platform.
///
/// The `io.flrone/service` channel lives in the root isolate (the embedding only
/// answers channels on the platform thread), so every host call is one port
/// message there and back. The request/response shape matches the UI's IPC, so
/// the callers' timeouts and failure classification behave as before.
class KernelWorkerHost implements KernelHost {
  KernelWorkerHost(this._root);

  final SendPort _root;
  final Map<int, Completer<dynamic>> _pending = <int, Completer<dynamic>>{};
  int _nextId = 0;

  @override
  Map<String, dynamic> dashboard = <String, dynamic>{};

  @override
  List<Map<String, dynamic>> configurations = const <Map<String, dynamic>>[];

  @override
  Future<dynamic> call(String method, [Map<String, dynamic>? args]) {
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    try {
      _root.send(<String, dynamic>{
        'kind': 'host',
        'id': id,
        'method': method,
        'args': args,
      });
    } catch (error) {
      _pending.remove(id);
      completer.completeError(StateError('the host is gone: $error'));
    }
    return completer.future;
  }

  /// Answers one [call]. A reply for a request that already timed out is dropped.
  void complete(Map<String, dynamic> message) {
    final id = (message['id'] as num?)?.toInt();
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final error = message['error'];
    if (error != null) {
      completer.completeError(StateError('$error'));
    } else {
      completer.complete(message['result']);
    }
  }
}
