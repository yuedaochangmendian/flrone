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
class KernelProxyException implements Exception {
  const KernelProxyException(this.message, {this.unanswered = false});

  final String message;

  /// The request never produced an answer (a transport timeout, a dropped
  /// link, a link that is not up yet) rather than being refused. The start
  /// button keeps its optimistic state for these and lets the heartbeat
  /// recovery converge; a refusal rolls back.
  final bool unanswered;

  @override
  String toString() => 'KernelProxyException: $message';
}

/// Whether [error] means "the kernel never answered" rather than "refused".
///
/// The distinction drives the start button: an unanswered start stays optimistic
/// (rolling back would show "stopped" while the tunnel is still coming up), an
/// explicit refusal rolls back and reports.
bool kernelUnanswered(Object error) =>
    error is TimeoutException ||
    (error is KernelProxyException && error.unanswered);

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
  List<Map<String, dynamic>> get profiles;
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
  /// `BboxKernel.ffiMode` on a real attach instead of engine existence.
  bool get driverReady;

  /// The action bus. Never null while the proxy is connected: a failed action
  /// reports itself as an error rather than silently falling back.
  ActionInvoker? get attached;

  /// Channel-shaped events from the kernel (`dashboard`, `rates`, `error`, ...).
  Stream<Map<String, dynamic>> get events;

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
