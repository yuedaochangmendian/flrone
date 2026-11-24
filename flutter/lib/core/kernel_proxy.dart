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

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'action.dart';
import 'kernel_control.dart';
import 'platform_value.dart';

/// Injectable seams so tests can simulate the peer engine without a second
/// Flutter engine (and without touching the process-wide name server).
typedef PortLookup = SendPort? Function(String name);
typedef PortRegister = void Function(SendPort port, String name);
typedef PortRemove = bool Function(String name);

// KernelProxyException lives in kernel_control.dart with the rest of the
// contract, so box_api can classify a failure without importing this file.
class KernelProxy implements KernelControl {
  KernelProxy({
    PortLookup? lookup,
    PortRegister? register,
    PortRemove? remove,
    this.retryDelay = const Duration(seconds: 2),
    this.retryCount = 0,
    this.reconnectDelay = const Duration(seconds: 2),
    this.requestTimeoutOverride,
  })  : _lookup = lookup ?? IsolateNameServer.lookupPortByName,
        _register = register ?? IsolateNameServer.registerPortWithName,
        _remove = remove ?? IsolateNameServer.removePortNameMapping;

  final PortLookup _lookup;
  final PortRegister _register;
  final PortRemove _remove;

  /// Bettbox's `_waitForIpc` cadence: 2s × 3, then give up loudly.
  final Duration retryDelay;
  final int retryCount;

  /// Delay between reconnects after a link timeout. Injectable so tests drive
  /// the sticky window (and the give-up limit) without real seconds.
  final Duration reconnectDelay;

  /// When set, replaces every request's timeout. A test drops it to
  /// milliseconds to simulate a service engine that stopped draining its port.
  @visibleForTesting
  Duration? requestTimeoutOverride;

  /// Receives a one-line diagnostic from the transport (a message that spent
  /// too long on the wire/decode). Wired by `main.dart` to the app log.
  void Function(String text)? diagnose;

  /// Transport lag above this is reported. The receiving isolate deserializes
  /// the message before any callback runs, so a big payload shows up as lag,
  /// not as a slow event handler.
  static const _lagReportMs = 100;

  SendPort? _service;
  ReceivePort? _replies;
  StreamSubscription<dynamic>? _replySub;
  final _events = StreamController<Map<String, dynamic>>.broadcast();
  final _pending = <String, Completer<Object?>>{};
  int _nextId = 0;

  /// Action ids must be unique even when two calls land in the same microsecond (or two UI
  /// engines act at once): the service demuxes a single pending map by id, so a collision would
  /// strand the first caller until its timeout. A monotonic counter plus a per-engine nonce
  /// cannot collide.
  int _actionSeq = 0;
  final String _actionNonce = DateTime.now().microsecondsSinceEpoch.toRadixString(36);

  /// The id of one action on the wire: unique within this engine and across engines.
  String nextActionId(String method) => '$method#$_actionNonce#${_actionSeq++}';
  bool _connected = false;
  bool _disposed = false;

  /// A [connect] is in flight: the host is creating or booting the service
  /// engine. That window is [KernelPhase.engineStarting] — an engine phase, not
  /// "idle" — so the diagnostics and the start path can name what they wait for.
  bool _connecting = false;
  String _status = 'Stopped';

  /// The core's start instant, as the dashboard events carried it. The card's
  /// clock reads [uptime] instead of subtracting from the wall clock, so a
  /// clock jump cannot make the run time negative or jump backwards.
  int? _startedAt;
  Timer? _reconnectTimer;
  int _reconnectAttempts = 0;

  /// The transport link went down (a request timed out) and a reconnect is
  /// pending. Sticky driver ownership spans this window: the service engine
  /// may have been recreated with the kernel still attached, so the channel's
  /// 1 Hz dashboard must not take over the core while we re-resolve its port.
  bool _linkDown = false;

  /// The service engine's last reported FFI state (`KernelService.ffiMode`,
  /// i.e. `_kernel != null`). Reported by `hello`, and kept through a link
  /// outage until a new `hello` contradicts it (or the reconnect is given up).
  /// An older peer that omits the field leaves the last value untouched.
  bool _driverReady = false;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  /// True while the driver owns the core, including the reconnect window.
  /// Routing kernel operations back to the channel while the link is merely
  /// down would let it write selection/mode behind a still-running driver.
  @override
  bool get ffiMode => _driverReady && (_connected || _linkDown);

  @override
  bool get remote => true;

  @override
  bool get driverReady => _driverReady;

  /// The last status this proxy believes the core is in. Exposed for the
  /// diagnostic panel and for tests that pin the transitional 'Starting' state
  /// after a link timeout (the status is otherwise only observable through
  /// [active] and emitted dashboard events).
  String get statusWire => _status;

  /// The FFI driver is authoritative for the core's lifecycle from the first
  /// Starting until the terminal Stopped. Gating on 'Started' alone let the
  /// channel's 1 Hz dashboard wholesale-replace the driver's Starting state,
  /// flipping the start button's morph target mid-flight (the start jank).
  /// The status gate also ends ownership on a user stop; a plain Stopped
  /// dashboard from the driver therefore hands the channel back authority.
  @override
  bool get active =>
      ffiMode &&
      (_status == 'Starting' || _status == 'Started' || _status == 'Stopping');

  /// The UI side of the readiness answer: the link's own state until the
  /// service engine answers, then the status it reported (the `hello` resyncs
  /// it on every reconnect). A dropped link is `lost`, not `idle`: the core
  /// may still be running behind it; a connect in flight is `engineStarting`.
  @override
  KernelPhase get kernelPhase {
    if (_service == null || !_connected) {
      if (_connecting) return KernelPhase.engineStarting;
      return _linkDown ? KernelPhase.lost : KernelPhase.idle;
    }
    return switch (_status) {
      'Starting' => KernelPhase.starting,
      'Stopping' => KernelPhase.stopping,
      'Started' => KernelPhase.running,
      _ => KernelPhase.idle,
    };
  }

  /// The UI side's run time: computed from the `startedAt` the dashboard events
  /// carried, never from a local baseline, so a suspended ticker resumes at the
  /// right figure and a clock jump cannot make it negative.
  @override
  Duration? get uptime {
    final startedAt = _startedAt;
    if (startedAt == null || startedAt <= 0) return null;
    final elapsed = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(startedAt),
    );
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// Releases driver ownership at the sticky limit or on an explicit stop.
  /// [emitStopped] publishes a synthetic terminal dashboard so box.dart's
  /// snapshot does not keep showing the 'Starting' the outage announced —
  /// without it the channel's stale 'Started' could resurrect after handover.
  void _releaseOwnership({bool emitStopped = false}) {
    _driverReady = false;
    _linkDown = false;
    _status = 'Stopped';
    if (emitStopped) {
      _startedAt = null;
      _events.add(<String, dynamic>{
        'type': 'dashboard',
        'value': <String, dynamic>{'status': 'Stopped'},
      });
    }
  }

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
    _connecting = true;
    try {
      await _connectLink(timeout);
    } finally {
      _connecting = false;
    }
  }

  Future<void> _connectLink(Duration timeout) async {
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
        unanswered: true,
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
    _linkDown = false;
    if (reply is Map<String, dynamic>) {
      if (reply['status'] is String) _status = reply['status'] as String;
      // A new hello is authoritative: a fresh engine that lost the driver must
      // release ownership even if the previous link still believed it was up.
      // A peer that omits the field is treated as having no driver: the unsafe
      // direction for a flag that suppresses the channel would be to claim FFI
      // arbitration over a core nothing behind it drives. The engine re-pushes
      // the real fact over IPC once initialize() completes.
      _driverReady = reply['driverReady'] == true;
      // Events emitted before this hello had no port to reach (an auto-start
      // that already ran); the greeting carries the last dashboard so the UI
      // does not wait for the next 1 Hz sample.
      final dashboard = reply['dashboard'];
      if (dashboard is Map<String, dynamic>) {
        _trackStatus(<String, dynamic>{
          'type': 'dashboard',
          'value': dashboard,
        });
        _events.add(<String, dynamic>{
          'type': 'dashboard',
          'value': dashboard,
        });
      }
    }
    _reconnectAttempts = 0;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  /// A timed-out request usually means the service engine was destroyed (the
  /// process may still be alive). The port vanishes with it; retry the lookup
  /// a few times so the UI recovers by itself instead of staying frozen.
  static const _maxReconnectAttempts = 5;

  void _scheduleReconnect() {
    if (_disposed || _reconnectTimer != null) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      // Sticky ownership has a ceiling: a service engine that never answers
      // again must not mask the channel forever. Release, publish a terminal
      // dashboard so the UI's status snapshot agrees, and reopen arbitration.
      _releaseOwnership(emitStopped: true);
      return;
    }
    _reconnectTimer = Timer(reconnectDelay, () async {
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

  @override
  Future<void> setKernelLogsVisible(bool visible) => _request<dynamic>(
    'kernelLogsVisible',
    <String, dynamic>{'visible': visible},
  ).then((_) {}, onError: (Object _) {});

  void _onReply(dynamic raw) {
    if (_disposed) return;
    final message = normalizePlatformValue(raw);
    if (message is! Map<String, dynamic>) return;
    final sentAt = (message['sentAt'] as num?)?.toInt();
    if (sentAt != null && diagnose != null) {
      final lag = DateTime.now().millisecondsSinceEpoch - sentAt;
      if (lag > _lagReportMs) {
        final type = message['type'] == 'event'
            ? 'event:${(message['value'] is Map ? (message['value'] as Map)['type'] : null)}'
            : 'reply:${message['id']}';
        diagnose?.call('ipc lag ${lag}ms ($type)');
      }
    }
    if (message['type'] == 'event') {
      final value = message['value'];
      if (value is Map<String, dynamic>) {
        // The service engine pushes its real FFI-attach fact after initialize();
        // a hello handled earlier may have stored driverReady=false, but the
        // attach can still complete afterwards. Without this the proxy would
        // stay in channel mode for the life of the link.
        if (value['type'] == 'driverReady') {
          _driverReady = value['value'] == true;
          return;
        }
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
      final code = envelope['code'];
      completer.completeError(
        KernelProxyException(
          '$error',
          // The envelope names a timeout from the service engine's side; the
          // type is lost in the string, so the kind rides along explicitly.
          unanswered: envelope['kind'] == 'unanswered',
          // A peer that learned to carry a refusal's code (and payload) keeps
          // them typed here; an older peer sends neither and the message text
          // is the whole record.
          code: code is String && code.isNotEmpty ? code : null,
          details: envelope['details'],
        ),
      );
    } else {
      completer.complete(envelope['result']);
    }
  }

  void _trackStatus(Map<String, dynamic> event) {
    if (event['type'] != 'dashboard') return;
    final value = event['value'];
    if (value is Map<String, dynamic>) {
      _status = value['status'] as String? ?? 'Stopped';
      _startedAt = (value['startedAt'] as num?)?.toInt() ?? _startedAt;
    }
  }

  Future<T> _request<T>(
    String method,
    dynamic data, {
    Duration timeout = const Duration(seconds: 30),
    // A long-running action (a 40 s route test) is not evidence the link died:
    // its caller asked for the time, so a timeout must not mark the engine down.
    bool markLinkDown = true,
  }) async {
    timeout = requestTimeoutOverride ?? timeout;
    final service = _service;
    if (service == null || !_connected && method != 'hello') {
      throw KernelProxyException(
        'the kernel service is not connected; call connect() first',
        unanswered: true,
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
        KernelProxyException(
          'could not reach the kernel service: $error',
          unanswered: true,
        ),
      );
    }
    return completer.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      if (!markLinkDown) {
        throw KernelProxyException(
          'the kernel service did not answer "$method" within '
          '${timeout.inSeconds}s',
          unanswered: true,
        );
      }
      // The engine stopped draining its port without any other signal. Mark the
      // link down regardless of a name-server hit: the new engine may have
      // re-registered the same name while this request still targets the dead
      // SendPort. A reconnect schedule re-resolves it.
      //
      // Keep driver ownership through the outage: 'Starting' is the transitional
      // state that holds `active` (and therefore box.dart's arbitration) while
      // the service engine is re-appearing — exactly the window the channel's
      // 1 Hz dashboard used to steal with its 'Started'. The hello on reconnect
      // resyncs the real status; giving up releases ownership (see
      // [_scheduleReconnect]).
      _connected = false;
      _service = null;
      _linkDown = true;
      _status = 'Starting';
      _scheduleReconnect();
      throw KernelProxyException(
        'the kernel service did not answer "$method" within '
        '${timeout.inSeconds}s',
        unanswered: true,
      );
    }).then((value) => value as T);
  }

  // --- KernelControl ------------------------------------------------------

  @override
  // A start builds the config and waits for the tun; two minutes is the same
  // budget the in-process driver takes.
  Future<void> startService() {
    // A service-engine auto-start (tile, widget, boot, or the 300 ms start
    // after `service.start`) may have completed before the UI attaches. Its
    // hello status is authoritative: asking again only publishes a second
    // terminal `Started`. `Starting` must still cross the link: it is also the
    // status of a lost core, where a manual start has to rebuild the instance
    // (the engine collapses a concurrent second start onto the first).
    if (_connected && _status == 'Started') {
      return Future<void>.value();
    }
    return _request<void>('start', null, timeout: const Duration(minutes: 2));
  }
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
  Future<void> stopCoreFromHost() =>
      _request<void>('stopCore', null, timeout: const Duration(seconds: 30));
  @override
  Future<void> updateWifiState() =>
      _request<void>('updateWifiState', null, timeout: const Duration(seconds: 30));

  /// The manual rule-set refetch (the routing screen's "Update resources").
  ///
  /// The core fetches every remote set synchronously, so a slow mirror is a
  /// long *working* call rather than a dropped link: the budget is minutes and a
  /// timeout must not mark the engine down ([markLinkDown] off), exactly like
  /// the long route test. The service engine answers a refusal (no running
  /// instance) through the ordinary error envelope, which rebuilds here as a
  /// [KernelProxyException] with the same message.
  @override
  Future<Map<String, dynamic>> updateRuleSets() async {
    final answer = await _request<dynamic>(
      'updateRuleSets',
      null,
      timeout: const Duration(minutes: 3),
      markLinkDown: false,
    );
    if (answer is! Map) {
      throw const KernelProxyException('the kernel service answered no rule-set result');
    }
    return <String, dynamic>{
      for (final entry in answer.entries) '${entry.key}': entry.value,
    };
  }

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
    _linkDown = false;
    _driverReady = false;
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
    final id = proxy.nextActionId(method.name);
    final action = Action(id: id, method: method, data: data).encode();
    // The caller's budget is honoured (a route test asks for 40 s), and an
    // action timeout is the action's problem, not a dead link.
    final result = await proxy._request<dynamic>(
      'action',
      action,
      timeout: timeout,
      markLinkDown: false,
    );
    return result as T;
  }
}
