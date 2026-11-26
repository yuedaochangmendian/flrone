// The contract shared by the two Flutter engines (phase 1 of the engine split).
//
// UI engine  : holds a [KernelProxy], which forwards every call over the
//              IsolateNameServer IPC link to the service engine.
// Service engine: holds the real [KernelService] (the FFI driver) and a
//              [KernelHost] that talks to the Android side from that engine.
//
// Keeping the contract here — rather than in box.dart — means neither side
// imports the other's engine. The service engine never imports box.dart, and
// the UI engine never opens libthrone.so.

import 'dart:async';

import 'action.dart';

/// A readable failure for a call made through the engine link.
///
/// One shape for both kinds of failure on purpose; they are not interchangeable:
///
///  * [unanswered] — nothing answered: the link is down, the request timed out
///    or the service engine is still booting. Retry/diagnostic territory; the
///    work may still be running behind the silence.
///  * refused — the kernel answered with a non-zero `ActionResult` code. Final
///    for the call, safe to report to the user ([code] keeps the kernel's
///    number as `core_<n>`, [details] its payload).
class KernelProxyException implements Exception {
  const KernelProxyException(
    this.message, {
    this.unanswered = false,
    this.code,
    this.details,
  });

  /// A refusal built from the wire envelope.
  ///
  /// The code keeps the kernel's own error number, so a report can be matched
  /// to the Go handler; the message prefers the handler's text over a generic
  /// one, and the whole payload rides along for a diagnostic surface.
  factory KernelProxyException.fromActionResult(ActionResult result) {
    final data = result.data;
    final message = switch (data) {
      String text when text.isNotEmpty => text,
      Map map when map['message'] is String => map['message'] as String,
      Map map when map['error'] is String => map['error'] as String,
      null => 'the kernel refused ${result.method}',
      _ => '$data',
    };
    return KernelProxyException(
      message,
      code: 'core_${result.code}',
      details: data,
    );
  }

  final String message;

  /// The request never produced an answer (a transport timeout, a dropped
  /// link, a link that is not up yet) rather than being refused. The start
  /// button keeps its optimistic state for these and lets the heartbeat
  /// recovery converge; a refusal rolls back.
  final bool unanswered;

  /// `core_<n>` when the kernel answered an error code; null when the failure
  /// happened before an answer existed (there is no code to report then).
  final String? code;

  /// The refusal payload (the ActionResult's `data`), when the kernel supplied
  /// one. Kept whole: handlers use it for an explanation, not just a string.
  final Object? details;

  /// The kernel answered and said no: a user-facing failure, not a transport
  /// accident. Mirrors FlClash's answered/`isUnansweredCoreError` split.
  bool get refused => !unanswered;

  @override
  String toString() => code == null
      ? 'KernelProxyException: $message'
      : 'KernelProxyException($code): $message';
}

/// The default budget for one action crossing either the FFI or the IPC bus.
///
/// Both ends need the same number: the UI's [KernelProxy] bounds its wait, and
/// the service engine bounds the FFI call it makes on the UI's behalf. The
/// caller's value travels in the `action` envelope so the second bound cannot
/// silently truncate a longer request (a 40 s route test used to die at 30 s).
const actionTimeout = Duration(seconds: 30);

/// Packs one Action JSON wire plus the caller's budget for the UI→service IPC.
///
/// The `Action` JSON itself is untouched — the Go action contract has no
/// timeout field, so no handler's payload changes. The envelope is a second,
/// transport-level layer: `{action: '<wire>', timeoutMs: N}`. The service still
/// accepts a bare string from an older peer (see [unpackActionEnvelope]).
Map<String, dynamic> packActionEnvelope(String wire, Duration timeout) =>
    <String, dynamic>{'action': wire, 'timeoutMs': timeout.inMilliseconds};

/// Reads an `action` IPC payload into its wire and budget.
///
/// Accepts the legacy bare Action JSON string and the envelope from
/// [packActionEnvelope]. A malformed envelope fails loudly: guessing a wire
/// here would send garbage to the FFI bridge and hang the real caller.
({String wire, Duration timeout}) unpackActionEnvelope(Object? data) {
  if (data is String) return (wire: data, timeout: actionTimeout);
  if (data is Map) {
    final wire = data['action'];
    final raw = data['timeoutMs'];
    if (wire is String &&
        wire.isNotEmpty &&
        raw is num &&
        raw >= 0 &&
        raw.isFinite) {
      return (wire: wire, timeout: Duration(milliseconds: raw.toInt()));
    }
  }
  throw const FormatException('action data must be an Action wire envelope');
}

/// Whether [error] means "the kernel never answered" rather than "refused".
///
/// The distinction drives the start button: an unanswered start stays optimistic
/// (rolling back would show "stopped" while the tunnel is still coming up), an
/// explicit refusal rolls back and reports. One classifier for both boundaries:
/// the engine link ([KernelProxyException]/[TimeoutException]) and the
/// in-process action bus ([ActionException] with `timedOut`).
bool isUnansweredCoreError(Object? error) => switch (error) {
  TimeoutException() => true,
  KernelProxyException(:final unanswered) => unanswered,
  ActionException(:final timedOut) => timedOut,
  _ => false,
};

/// Historical name for [isUnansweredCoreError], kept because the start/stop
/// paths read it as a domain question rather than an error-type test.
bool kernelUnanswered(Object error) => isUnansweredCoreError(error);

/// The error half of the engine-link reply envelope, built from one thrown
/// error: exactly what [KernelProxyException] needs to be rebuilt on the UI
/// side, and nothing a receiver could not decode.
///
///  * `error` — the message. A [KernelProxyException] contributes its own text
///    (the kernel handler's explanation) rather than a `toString` prefix, so the
///    UI reports the same sentence the service engine had.
///  * `kind: 'unanswered'` — only when [isUnansweredCoreError] says nothing
///    answered. The absence of `kind` therefore means a refusal, and an older
///    peer's `'failed'` reads the same way (the proxy never compares to it).
///  * `code` — the kernel's `core_<n>` when a refusal carried one. A call with
///    no answer has no code to report.
///  * `details` — the refusal payload, kept whole only when it is JSON-ish
///    ([_isIpcSafe]); a value the isolate codec could choke on is dropped
///    rather than turning a diagnosable failure into a transport error.
///
/// One helper for the whole boundary: the service engine calls it to send, the
/// tests assert its map, and [KernelProxyException] already knows how to read
/// the result back ([KernelProxy] rebuilds the exception from these fields).
Map<String, dynamic> coreErrorEnvelope(Object error) {
  final refusal = error is KernelProxyException ? error : null;
  final details = refusal?.details;
  final code = refusal?.code;
  return <String, dynamic>{
    'error': refusal?.message ?? '$error',
    if (isUnansweredCoreError(error)) 'kind': 'unanswered',
    // An empty code is no code: the proxy drops it on the way back, so do not
    // put it on the wire either.
    if (code != null && code.isNotEmpty) 'code': code,
    if (details != null && _isIpcSafe(details)) 'details': details,
  };
}

/// Whether [value] survives the port/JSON codec untouched: null, a scalar, or a
/// list/map of those. A `Map` whose keys are not strings is not JSON-ish, and a
/// custom object (a `DateTime`, a sealed result type) would either fail the
/// JSON encoder or lose its type; both are dropped rather than sent.
bool _isIpcSafe(Object? value) {
  if (value == null || value is String || value is bool || value is num) {
    return true;
  }
  if (value is List) return value.every(_isIpcSafe);
  if (value is Map) {
    return value.entries.every((entry) => entry.key is String && _isIpcSafe(entry.value));
  }
  return false;
}

/// The action-bus surface of the kernel, independent of where it runs.
///
/// [ThroneKernel] implements this in the service engine (FFI directly). The
/// UI engine gets [ProxyActionBus] from kernel_proxy.dart, which sends the very
/// same `Action` JSON over IPC instead of calling `throne_invoke_action`.
abstract class ActionInvoker {
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = const Duration(seconds: 30),
  });
}

/// Everything the kernel driver asks of its host process.
///
/// The UI-side implementation is `BoxController` itself: `call` is the channel
/// bridge and `dashboard`/`profiles` are its cached snapshots. The service-side
/// implementation is `ServiceBridgeClient` in service_entry.dart, which owns a
/// MethodChannel in the service engine and keeps a local snapshot of the two
/// display-only getters.
abstract class KernelHost {
  Future<dynamic> call(String method, [Map<String, dynamic>? args]);

  /// Display-only: the name shown on dashboard events for the selected group.
  Map<String, dynamic> get dashboard;

  /// Display-only: the group rows `dashboard['selectedProfileId']` indexes into.
  List<Map<String, dynamic>> get configurations;
}

/// A sink for the channel-shaped events (`{type, value}`) the kernel emits.
///
/// The service engine injects a sink that writes to the UI over IPC; tests
/// inject one that collects into a list. A [KernelService] with no sink keeps
/// a local broadcast stream so it can still be driven in-process (the default
/// `BoxController` path and the handshake tests).
typedef KernelEventSink = void Function(Map<String, dynamic> event);

/// Where the core is in its lifecycle, as one value.
///
/// `starting` and `stopping` are mutually exclusive by construction (the driver
/// serialises its lifecycle ops), which the old pair of booleans only stated in
/// comments. `lost` is an instance fact that can coexist with `starting`: a
/// restart is in flight but the previous instance is still gone.
enum KernelPhase {
  /// No instance and no transition in flight.
  idle,

  /// The host is creating or booting the service engine: the UI is waiting for
  /// the port/`hello`, not for the core. Naming it makes the prewarm/first-start
  /// wait explicit instead of an anonymous "not connected" window.
  engineStarting,

  /// A start is building the config or creating the instance.
  starting,

  /// The instance exists and is started.
  running,

  /// A stop is closing the instance.
  stopping,

  /// The instance disappeared without the user asking; a restart is pending.
  lost,

  /// The automatic restart is in its backoff/retry window.
  recovering,
}

/// The public face of the kernel that `BoxController` and its API extensions
/// actually use. Implemented by both [KernelService] (service engine) and
/// `KernelProxy` (UI engine).
abstract class KernelControl {
  /// Establishes the transport. A no-op for the in-process driver; for the UI
  /// proxy this resolves the service engine's port and sends `hello`.
  ///
  /// A non-zero [timeout] makes the proxy wait for the service engine to appear
  /// (the Android service starts it right after `service.start`); the default
  /// keeps the initial attach non-blocking.
  Future<void> connect({Duration timeout = Duration.zero}) async {}

  /// Attaches the driver without starting the tunnel.
  Future<void> initialize();

  Future<void> startService();
  Future<void> stopService();
  Future<void> reloadService({String reason = 'reload'});

  /// A stop that arrived from the platform (widget/tile/notification); the
  /// platform is already stopping, so only the core is closed.
  Future<void> stopCoreFromHost();

  /// The Android Wi-Fi monitor saw a new SSID/BSSID.
  Future<void> updateWifiState();

  /// Fetches the running config's remote rule-sets on demand — the manual half
  /// of the deferred-start retry (`KernelService._updateRuleSetsAfterStart` is
  /// the automatic one). Answer: `{updated, error}`, the core's own count and
  /// failure text, exactly as the worker reports them.
  ///
  /// Only a live instance can refetch them: with no instance there is nothing
  /// for the core to update, so the control answers a typed refusal
  /// ([KernelProxyException]) instead of a misleading zero. The automatic path
  /// treats a missing instance as "nothing to do"; this one is user-initiated,
  /// so it must say why nothing happened.
  Future<Map<String, dynamic>> updateRuleSets();

  Future<void> setMode(String mode);
  Future<void> onSelectionChanged();

  /// True when the kernel owns the tun, not the platform service.
  bool get active;

  /// The single readiness answer for this control.
  ///
  /// The driver used to be described by four independent booleans (starting,
  /// stopping, recovering, instance-lost) that every reader combined on its
  /// own — the status text, the start guard and the diagnostics each had a
  /// slightly different read. [KernelPhase] is the one derivation; the
  /// in-process driver overrides it, and a control that does not track
  /// transitions (a test double, the UI proxy before it connects) answers
  /// [KernelPhase.idle].
  KernelPhase get kernelPhase => KernelPhase.idle;

  /// True when this control talks to a separate service engine (the UI proxy).
  /// The in-process driver used by tests and the service engine itself answers
  /// false, so a start there must not wait for a port that will never appear.
  bool get remote => false;

  /// Elapsed time since the core started, or null when it is not running.
  ///
  /// The card's clock reads this instead of subtracting `startedAt` from the
  /// wall clock: a system-clock jump or a suspended ticker cannot drift it. The
  /// in-process driver answers from its own start instant; the proxy from the
  /// `startedAt` its dashboard events carried.
  Duration? get uptime => null;

  /// True when the FFI driver is engaged (channel handlers step aside).
  bool get ffiMode;

  /// True when the service engine actually attached the FFI driver (its
  /// `KernelService.ffiMode`, i.e. `_kernel != null`). Sticky across a proxy's
  /// reconnect window so the UI keeps driver arbitration while the service
  /// engine is re-appearing; the service engine's own control answers its
  /// live value. The host uses the pushed form of this fact to gate
  /// `FlroneKernel.ffiMode` on a real attach instead of engine existence.
  bool get driverReady;

  /// The action bus. Never null while the proxy is connected: a failed action
  /// reports itself as an error rather than silently falling back.
  ActionInvoker? get attached;

  /// Channel-shaped events from the kernel (`dashboard`, `rates`, `error`, ...).
  Stream<Map<String, dynamic>> get events;

  /// Tells the service engine whether a screen is watching the kernel's tail.
  ///
  /// While nobody is, the service keeps a bounded ring and sends nothing: a start's log
  /// burst (hundreds of lines) would otherwise cross into the UI isolate and allocate rows
  /// no visible page renders. Turning it back on replays the ring, so opening the log screen
  /// after a start still shows what happened. The in-process driver has no UI-side tail to
  /// gate, so the default is a no-op.
  Future<void> setKernelLogsVisible(bool visible) async {}

  void dispose();
}

/// The named port the service engine registers so a UI engine can find it.
const String servicePortName = 'flrone.service';

/// The per-UI-engine name used to resolve the native port sent in `hello`.
///
/// `hello.data.port` is an `int` (the contract's wire shape), and Dart has no
/// public way to turn a native port number back into a [SendPort]. Both engines
/// share the process-wide [IsolateNameServer], so the UI registers its receive
/// port under a name derived from that number and the service looks it up.
String uiPortName(int nativePort) => 'flrone.ui.$nativePort';
