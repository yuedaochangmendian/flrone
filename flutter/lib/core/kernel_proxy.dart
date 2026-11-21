// UI-engine side of the engine split (phase 1).
//
// The kernel (FFI driver, worker isolate and platform host) lives in a separate
// service Flutter engine. This class is the *only* thing the UI engine keeps:
// it speaks the small IPC contract in kernel_control.dart over the process-wide
// IsolateNameServer, so the UI never opens libthrone.so and never touches the
// platform channel the service engine owns.
//
// Modelled on Bettbox's `ClashLib` (lib/clash/lib.dart): register a local port,
// discover the peer by name, send a `hello` carrying that port, and demultiplex
// replies by id. Unlike Bettbox the wire here is a plain map with a string id,
// so requests can be correlated without transferring a fresh SendPort per call.

import 'dart:async';
import 'dart:ffi' show NativePort; // SendPort.nativePort for the IPC hello
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'action.dart';
import 'kernel_control.dart';
import 'platform_value.dart';

/// Injectable seams so tests can simulate the peer engine without a second
/// Flutter engine (and without touching the process-wide name server).
typedef PortLookup = SendPort? Function(String name);
typedef PortRegister = void Function(SendPort port, String name);
typedef PortRemove = bool Function(String name);

/// A readable failure for any call made before the service engine answered.
class KernelProxyException implements Exception {
  const KernelProxyException(this.message);
  final String message;
  @override
  String toString() => 'KernelProxyException: $message';
}

class KernelProxy implements KernelControl {
  KernelProxy({
    PortLookup? lookup,
    PortRegister? register,
    PortRemove? remove,
    this.retryDelay = const Duration(seconds: 2),
    this.retryCount = 0,
  })  : _lookup = lookup ?? IsolateNameServer.lookupPortByName,
        _register = register ?? IsolateNameServer.registerPortWithName,
        _remove = remove ?? IsolateNameServer.removePortNameMapping;

  final PortLookup _lookup;
  final PortRegister _register;
  final PortRemove _remove;

  /// Bettbox's `_waitForIpc` cadence: 2s × 3, then give up loudly.
  final Duration retryDelay;
  final int retryCount;

  SendPort? _service;
  ReceivePort? _replies;
  StreamSubscription<dynamic>? _replySub;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<Object?>>{};
  int _nextId = 0;
  bool _connected = false;
  bool _disposed = false;
  String _status = 'Stopped';
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  bool get ffiMode => _connected;

  @override
  bool get remote => true;

  /// The FFI driver is authoritative for the core's lifecycle from the first
  /// Starting until the terminal Stopped. Gating on 'Started' alone let the
  /// channel's 1 Hz dashboard wholesale-replace the driver's Starting state,
  /// flipping the start button's morph target mid-flight (the start jank).
  @override
  bool get active =>
      _connected &&
      (_status == 'Starting' || _status == 'Started' || _status == 'Stopping');

  @override
  ActionInvoker? get attached => _connected ? _actions : null;

  late final ActionInvoker _actions = _ProxyActionBus(this);

  // --- transport ----------------------------------------------------------

  /// Resolves the service engine's port and performs the `hello` handshake.
  ///
  /// Idempotent: a second call while connected is a no-op. On failure every
  /// later call throws [KernelProxyException] rather than pretending success.
  @override
  Future<void> connect({Duration timeout = Duration.zero}) async {
    if (_connected) return;
    if (_disposed) throw const KernelProxyException('the proxy is disposed');
    final deadline = timeout > Duration.zero ? DateTime.now().add(timeout) : null;
    SendPort? found;
    var attempt = 0;
    while (true) {
      found = _lookup(servicePortName);
      if (found != null) break;
      final expired = deadline != null
          ? !DateTime.now().isBefore(deadline)
          : attempt >= retryCount;
      if (expired) break;
      attempt++;
      await Future<void>.delayed(
        deadline != null ? const Duration(milliseconds: 400) : retryDelay,
      );
    }
    if (found == null) {
      throw KernelProxyException(
        'the kernel service engine is not available (no "$servicePortName" port '
        'after ${deadline != null ? '${timeout.inSeconds}s' : '$retryCount retries'})',
      );
    }
    _service = found;
    _replies ??= ReceivePort();
    final replies = _replies!;
    // The wire carries the *native* port number, so make it resolvable by the
    // peer through the same name server. Register before sending `hello`.
    _register(replies.sendPort, uiPortName(replies.sendPort.nativePort));
    _replySub ??= replies.listen(_onReply, onError: (error) {
      if (!_disposed) _events.add({'type': 'error', 'value': error.toString()});
    });
    // A failure here leaves `_connected` false, so all calls keep throwing.
    // The reply marks the link up and carries the engine's current status so a
    // (re)connect resyncs `_status` instead of trusting the last event of a
    // previous link (which left `active` stale-true across a reconnect).
    final reply = await _request<Object?>('hello', <String, dynamic>{
      'port': replies.sendPort.nativePort,
    });
    _connected = true;
    if (reply is Map<String, dynamic> && reply['status'] is String) {
      _status = reply['status'] as String;
    }
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// A timed-out request usually means the service engine was destroyed (the
  /// process may still be alive). The port vanishes with it; retry the lookup
  /// a few times so the UI recovers by itself instead of staying frozen.
  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null || _reconnectAttempts >= 5) return;
    _reconnectTimer = Timer(const Duration(seconds: 2), () async {
      _reconnectTimer = null;
      if (_disposed) return;
      _reconnectAttempts++;
      try {
        await connect();
      } catch (_) {
        _scheduleReconnect();
      }
    });
  }

  @override
  Future<void> initialize() => connect();

  void _onReply(dynamic raw) {
    if (_disposed) return;
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    if (message['type'] == 'event') {
      final value = message['value'];
      if (value is Map<String, dynamic>) {
        _trackStatus(value);
        _events.add(value);
      }
      return;
    }
    final id = message['id'] as String?;
    if (id == null) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    final envelope = message['result'];
    if (envelope is! Map<String, dynamic>) {
      completer.completeError(
        const KernelProxyException('malformed reply from the kernel service'),
      );
      return;
    }
    final error = envelope['error'];
    if (error != null) {
      completer.completeError(KernelProxyException('$error'));
    } else {
      completer.complete(envelope['result']);
    }
  }

  void _trackStatus(Map<String, dynamic> event) {
    if (event['type'] != 'dashboard') return;
    final value = event['value'];
    if (value is Map<String, dynamic>) {
      _status = value['status'] as String? ?? 'Stopped';
    }
  }

  Future<T> _request<T>(
    String method,
    dynamic data, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final service = _service;
    if (service == null || !_connected && method != 'hello') {
      throw KernelProxyException(
        'the kernel service is not connected; call connect() first',
      );
    }
    final id = '$method#${_nextId++}';
    final completer = Completer<Object?>();
    _pending[id] = completer;
    try {
      service.send(<String, dynamic>{'id': id, 'method': method, 'data': data});
    } catch (error) {
      _pending.remove(id);
      completer.completeError(
        KernelProxyException('could not reach the kernel service: $error'),
      );
    }
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      // The engine stopped draining its port without any other signal. Mark the
      // link down regardless of a name-server hit: the new engine may have
      // re-registered the same name while this request still targets the dead
      // SendPort. A reconnect schedule re-resolves it.
      _connected = false;
      _service = null;
      _scheduleReconnect();
      throw KernelProxyException(
        'the kernel service did not answer "$method" within '
        '${timeout.inSeconds}s',
      );
    }).then((value) => value as T);
  }

  // --- KernelControl ------------------------------------------------------

  @override
  // A start builds the config, fetches missing Xray assets and waits for the
  // tun; two minutes is the same budget the in-process driver takes.
  Future<void> startService() =>
      _request<void>('start', null, timeout: const Duration(minutes: 2));
  @override
  Future<void> stopService() =>
      _request<void>('stop', null, timeout: const Duration(minutes: 1));
  @override
  Future<void> setMode(String mode) =>
      _request<void>('setMode', <String, dynamic>{'mode': mode});
  @override
  Future<void> onSelectionChanged() => _request<void>('onSelectionChanged', null);

  /// Settings/profile edits ask the service engine to rebuild the core. The
  /// in-process driver did this locally; across engines it is one request.
  @override
  Future<void> reloadService({String reason = 'reload'}) => _request<void>(
        'reload',
        <String, dynamic>{'reason': reason},
        timeout: const Duration(minutes: 1),
      );
  @override
  Future<void> stopCoreFromHost() async {}
  @override
  Future<void> updateWifiState() async {}

  @override
  void dispose() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _disposed = true;
    final replies = _replies;
    if (replies != null) {
      _remove(uiPortName(replies.sendPort.nativePort));
      // A peer registering under the service name by us is not ours to remove;
      // only the per-UI reply mapping is unregistered here.
    }
    unawaited(_replySub?.cancel());
    _replySub = null;
    _replies?.close();
    _replies = null;
    _service = null;
    _connected = false;
    final error = const KernelProxyException('the kernel proxy was disposed');
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    unawaited(_events.close());
  }
}

/// The action bus over IPC. The `data` of an `action` request is the exact
/// `Action` JSON string `throne_invoke_action` would receive in-process, so the
/// service engine can hand it straight to its FFI bridge.
class _ProxyActionBus implements ActionInvoker {
  const _ProxyActionBus(this.proxy);
  final KernelProxy proxy;

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final id = '${method.name}#${DateTime.now().microsecondsSinceEpoch}';
    final action = Action(id: id, method: method, data: data).encode();
    final result = await proxy._request<dynamic>('action', action);
    return result as T;
  }
}
