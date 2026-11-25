// The Dart-side runtime for the self-owned kernel bridge.
//
// Dart controls the kernel directly: `DynamicLibrary.open('libthrone.so')` exposes
// the throne_* C ABI (bindings generated in `thone_ffi.dart`), and kernel events
// arrive on a ReceivePort the Go side posts JSON to (log lines travel as one
// binary frame per batch) — the bettbox message-port pattern. The method channel stays for Android duties only (VpnService,
// notifications, the platform databases); kernel calls route here whenever the
// rebuilt core is present.
//
// Until the AAR is rebuilt with `buildScript/core-patch`, the symbols are absent
// and `isAvailable` reports false — the BoxController keeps the channel path.

import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'action.dart';
import 'bridge_log_frame.dart';
import 'bridge_metrics.dart';
import 'kernel_control.dart';
import 'throne_ffi.dart';

/// One JSON event posted by the Go side (`sendEvent` / `postTo`).
typedef BridgeEvent = Map<String, dynamic>;

class ThroneKernel implements ActionInvoker {
  ThroneKernel._(this.ffi, this._port, this._replyPort) {
    ffi.throne_init_dart_api(NativeApi.initializeApiDLData);
    ffi.throne_attach_message_port(_port.sendPort.nativePort);
    _port.listen((raw) {
      // Logs arrive as one binary frame per pump drain (see
      // bridge_log_frame.dart); every other event is still JSON.
      final lines = decodeBridgeLogFrame(raw);
      if (lines != null) {
        // Metrics are off in production: the length read and record call are
        // the whole added cost, and record() early-returns on a bool check.
        if (BridgeMetrics.enabled) {
          BridgeMetrics.record(
            'logFrame',
            raw is Uint8List ? raw.length : 0,
          );
        }
        for (final line in lines) {
          _events.add(<String, dynamic>{
            'method': 'log',
            'data': <String, dynamic>{'level': line.level, 'message': line.message},
          });
        }
        return;
      }
      // Time the JSON decode only while metrics are enabled; the wire kind is
      // unknown until the map is decoded, so measure first and record after.
      // The disabled path is a plain call — no closure, no Stopwatch.
      late final Map<String, dynamic>? event;
      var decodeMicros = 0;
      if (BridgeMetrics.enabled) {
        final measured = BridgeMetrics.measure(() => decodeBridgeEvent(raw));
        event = measured.$1;
        decodeMicros = measured.$2;
        BridgeMetrics.recordJsonEvent(raw, event, decodeMicros: decodeMicros);
      } else {
        event = decodeBridgeEvent(raw);
      }
      if (event == null) return;
      _events.add(event);
      // Phase 3a: the kernel pushes speed-test progress every 200 ms instead of
      // answering a poll. Keep the last frame so a screen opened mid-run can
      // paint immediately, and expose the stream for the live updates.
      if (event['method'] == 'speedTest' && event['data'] is Map) {
        final frame = Map<String, dynamic>.from(event['data'] as Map);
        _lastSpeedTestState = frame;
        _speedTestStates.add(frame);
      }
    });
    // Action results arrive on a dedicated port: the C ABI takes a reply port
    // per call, and keeping one long-lived reply port avoids allocating an
    // isolate port for every request. Results are demuxed by their echoed id.
    _replyPort.listen((raw) {
      final result = ActionResult.decode(raw);
      if (result == null || result.id.isEmpty) return;
      final completer = _pending.remove(result.id);
      if (completer == null || completer.isCompleted) return;
      if (result.isError) {
        // One error shape for the whole boundary: the refusal carries the
        // kernel's code (`core_<n>`) and its payload, so a caller can tell a
        // refused action from a silent transport exactly as it can across IPC.
        completer.completeError(KernelProxyException.fromActionResult(result));
      } else {
        completer.complete(result.data);
      }
    });
  }

  int _nextId = 0;
  final Map<String, Completer<Object?>> _pending = {};
  final ReceivePort _replyPort;
  final _speedTestStates = StreamController<Map<String, dynamic>>.broadcast();
  Map<String, dynamic> _lastSpeedTestState = const {};

  /// The newest pushed speed-test frame, `{}` before any run. A screen that
  /// opens mid-test paints from this instead of issuing a query.
  Map<String, dynamic> get lastSpeedTestState => _lastSpeedTestState;

  /// Every pushed speed-test frame (`{"method":"speedTest","data":{...}}`).
  Stream<Map<String, dynamic>> get speedTestStates => _speedTestStates.stream;

  /// Invoke one kernel action and wait for the result correlated by id.
  ///
  /// [timeout] bounds the wait even if the kernel never answers; on expiry the
  /// pending entry is removed so a late reply cannot complete a dead Future.
  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) {
    final id = '${method.name}#${_nextId++}';
    return _invokeWire(
      id,
      Action(id: id, method: method, data: data).encode(),
      method.name,
      timeout,
    );
  }

  /// Invokes an already-encoded Action JSON string — the exact wire the UI
  /// engine forwards across IPC. The reply still correlates by the id embedded
  /// in [wire], so the service engine needs no knowledge of the Action codec.
  Future<dynamic> invokeWire(String wire) {
    final decoded = ActionResult.decode(wire);
    final id = decoded?.id ?? '';
    if (id.isEmpty) {
      throw const FormatException('action wire has no id');
    }
    return _invokeWire(id, wire, decoded?.method ?? 'action', const Duration(seconds: 30));
  }

  Future<T> _invokeWire<T>(
    String id,
    String wire,
    String method,
    Duration timeout,
  ) {
    final completer = Completer<Object?>();
    _pending[id] = completer;
    final payload = wire.toNativeUtf8();
    try {
      ffi.throne_invoke_action(payload, _replyPort.sendPort.nativePort);
    } catch (_) {
      // A synchronous FFI throw (missing symbol, null port) never posts a reply, so the
      // entry would sit in _pending forever: one dead entry per failed call. Drop it and
      // rethrow; the caller already sees the exception.
      _pending.remove(id);
      rethrow;
    } finally {
      malloc.free(payload);
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw ActionException(method, 'timed out after ${timeout.inSeconds}s', timedOut: true);
      },
    ).then((value) => value as T);
  }

  static ThroneKernel? _instance;
  static bool? _available;

  /// True when the rebuilt core (with the throne_* C ABI) is present.
  static bool get isAvailable {
    if (_available != null) return _available!;
    try {
      final lib = DynamicLibrary.open('libthrone.so');
      lib.lookup('throne_Mobile_setup');
      _available = true;
    } catch (_) {
      _available = false;
    }
    return _available!;
  }

  /// Opens the library and wires the message port. No-op when unavailable.
  static ThroneKernel? ensure() {
    if (_instance != null) return _instance;
    if (!isAvailable) return null;
    final lib = DynamicLibrary.open('libthrone.so');
    _instance = ThroneKernel._(ThroneFFI(lib), ReceivePort(), ReceivePort());
    return _instance;
  }

  final ThroneFFI ffi;
  final ReceivePort _port;
  final _events = StreamController<BridgeEvent>.broadcast();

  /// Every JSON event the kernel posts (logs, test results, ...).
  Stream<BridgeEvent> get events => _events.stream;

  /// Log lines: `{level, message}` per event (LogSink replacement).
  Stream<BridgeEvent> get logs =>
      events.where((e) => e['method'] == 'log').map((e) => Map<String, dynamic>.from(e['data'] as Map));

  /// Per-call reply port (the URLTest/IPTest/SpeedTest handler replacement):
  /// pass [nativePort] where the C ABI takes a handler port and read replies
  /// from [stream] until `*Done` arrives.
  ReplyPort openReply() => ReplyPort._();

  void dispose() {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const ActionException('dispose', 'kernel disposed'));
      }
    }
    _pending.clear();
    _port.close();
    _replyPort.close();
    _speedTestStates.close();
    _events.close();
    _instance = null;
  }
}

/// A temporary ReceivePort used as the reply address of one async call.
class ReplyPort {
  ReplyPort._() : _port = ReceivePort() {
    _sub = _port.listen((raw) {
      final event = decodeBridgeEvent(raw);
      if (event != null) _controller.add(event);
    });
  }

  final ReceivePort _port;
  final _controller = StreamController<BridgeEvent>.broadcast();
  late final StreamSubscription<dynamic> _sub;

  /// The C `int64_t` port value the C ABI expects.
  int get nativePort => _port.sendPort.nativePort;

  Stream<BridgeEvent> get stream => _controller.stream;

  void close() {
    _sub.cancel();
    _port.close();
    _controller.close();
  }
}
