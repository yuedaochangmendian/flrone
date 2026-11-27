// The Dart-driven kernel lifecycle (the FFI path): Dart owns the core through
// dart:ffi — build the config over the slim channel, start/stop/reload the
// Instance directly, and stream the status back as the channel-shaped events the
// UI already consumes. Every operation falls back to the method channel when the
// rebuilt core is absent (ThroneKernel.isAvailable == false).
//
// The FFI itself is owned by the service engine's main isolate (kernel_worker.dart,
// the Bettbox model). The UI engine never opens libthrone.so for kernel calls:
// status arrives as a pushed "status" event on the Go message port, and worker
// failures become UI events.

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'action.dart';
import 'kernel_control.dart';
import 'kernel_memory.dart';
import 'kernel_worker.dart';
import 'platform_value.dart';
import 'throne_kernel.dart';

/// Drives the core through dart:ffi instead of the Android service.
///
/// On: Dart opens `libthrone.so` and owns the Instance lifecycle — start, stop,
/// reload and the status snapshot all cross the C ABI directly, and the bridge
/// is told to stand aside for the control plane only.
///
/// The driver still stands down on its own when the rebuilt core is absent from
/// the build (`ThroneKernel.isAvailable == false`): it returns before it asks
/// the bridge to yield, so `BaseService` keeps starting `ProxyInstance` through
/// gomobile and every control call takes its channel branch. Flipping this off
/// hands the core back to the service without deleting the driver.
const bool kFfiDriverEnabled = true;

class KernelService implements KernelControl, ActionInvoker {
  /// In-process driver: it *is* the kernel side, so it never waits for a proxy.
  @override
  bool get remote => false;

  /// [host] is the only door to the platform (Android duties and display-only
  /// snapshots). The UI engine passes `BoxController`; the service engine passes
  /// `ServiceBridgeClient`, which owns its own MethodChannel.
  ///
  /// [sink] is where channel-shaped events go. In the service engine it writes
  /// to the UI over IPC; when absent (the in-process default and the tests) a
  /// local broadcast controller is used so [events] keeps working.
  KernelService(
    this.host, {
    KernelEventSink? sink,
    DateTime Function()? clock,
    Future<KernelMemoryStats> Function()? memoryStatsReader,
  })  : _ownsEvents = sink == null,
        _clock = clock,
        _memoryStatsReader = memoryStatsReader {
    _eventSink = sink ?? _localEvents.add;
  }

  final KernelHost host;
  late final KernelEventSink _eventSink;
  final bool _ownsEvents;
  final StreamController<Map<String, dynamic>> _localEvents =
      StreamController<Map<String, dynamic>>.broadcast();

  /// The in-process driver is already local; connecting is a no-op.
  @override
  Future<void> connect({Duration timeout = Duration.zero}) async {}

  /// Channel-shaped events (`{type, value}`) the BoxController feeds to _onEvent.
  /// Live only when no external sink was injected.
  @override
  Stream<Map<String, dynamic>> get events => _localEvents.stream;

  ThroneKernel? _kernel;
  KernelWorker? _worker;
  int? _instanceHandle;
  StreamSubscription<WorkerEvent>? _workerSub;
  StreamSubscription<BridgeEvent>? _statusSub;
  DateTime? _startedAt;

  /// Desired process-wide hints. A command can arrive before the FFI bridge is
  /// attached (a boot/doze notification racing engine creation); remembering
  /// the last value here and re-applying it in [_attach] keeps it from being
  /// lost. Both apply paths swallow failures — a hint is best effort. The
  /// "seen" flags distinguish "no command yet" from an explicit false, which
  /// must also be replayed if it preceded attach.
  bool _dozeWanted = false;
  bool _dozeSeen = false;
  bool _logStreamWanted = false;
  bool _logStreamSeen = false;

  /// The in-flight lifecycle transition.
  ///
  /// One value instead of a `_starting`/`_stopping` pair: the driver serialises
  /// its lifecycle ops, so the two can never both be set, and the type says so.
  /// [KernelPhase] folds this together with the instance facts below into the
  /// single readiness answer every reader uses.
  _Transition _transition = _Transition.idle;
  bool get _starting => _transition == _Transition.starting;

  /// An automatic restart is in its backoff/retry window. Orthogonal to
  /// [_transition]: the recovery wraps a reload that itself starts and stops.
  bool _recovering = false;

  /// The last cumulative traffic counters and when they were read, so the rate
  /// can be derived from the totals instead of `Status()`'s per-call deltas.
  /// The deltas are consumed by whoever calls `Status()` first; the totals are
  /// not, and an idle tunnel still reads 0 because the totals do not move.
  int _lastUpTotal = 0;
  int _lastDownTotal = 0;
  int _lastRateAt = 0;

  void _resetRateBaseline() {
    _lastUpTotal = 0;
    _lastDownTotal = 0;
    _lastRateAt = 0;
  }

  /// The platform channel has no timeout of its own, and the lifecycle chain is
  /// serial: a `host.call` that never settles would strand every queued op
  /// behind it forever (the UI's own timeout only frees the button). Every host
  /// call on the start/stop path is therefore bounded; for the ordinary ones the
  /// UI safety net is longer, so the op's own error is what the user sees
  /// ([_hostStartTimeout] is the deliberate exception, documented below).
  static const _hostOpTimeout = Duration(seconds: 30);
  static const _hostStopTimeout = Duration(seconds: 15);

  /// `service.start` gets its own, generous ceiling: the host answers it once the VpnService
  /// exists, and on a first start that includes the Android VPN consent dialog, which the user
  /// paces (it can sit open for far longer than [_hostOpTimeout]). A driver-side timeout here
  /// would tear down a start the user is still answering. The UI's own 35 s net treats its
  /// timeout as "the kernel did not answer yet" and keeps the optimistic shape, so a slow
  /// consent still converges from the dashboard event instead of showing a failure.
  static const _hostStartTimeout = Duration(minutes: 5);

  /// Set when the worker reports the core lost, until a start holds or a stop
  /// acknowledges it. A lost core leaves `_instanceHandle` pointing at the dead
  /// instance on purpose — the recovery path reads it — so `active` alone says
  /// "running" when the truth is "dead": the start guard consults this flag to
  /// let a user's manual start through during the recovery backoff instead of
  /// silently swallowing it (and dissolving the recovery with a no-op epoch).
  bool _instanceLost = false;

  /// Bumped by every effective core lifecycle transition (a start that builds
  /// an instance, a stop that closes one). Guarded no-ops do not count, so a
  /// swallowed command cannot make a delayed recovery think the user moved.
  int _epoch = 0;

  /// Lifecycle commands (start/stop/reload) run one at a time through this
  /// chain: a reload or stop that arrives while a start is still unwinding
  /// waits for it instead of tearing down the instance that start is about to
  /// produce. Each queued op re-validates the world when it runs, so a stop
  /// that landed behind a start still wins, and a reload behind a stop does
  /// not pull the tunnel back up.
  Future<void>? _lifecycle;
  /// A start call already owns the lifecycle queue. A second caller (the
  /// service engine's 300 ms auto-start and the UI's explicit start are the
  /// normal pair) waits for the same work instead of queuing a redundant
  /// config build and a second terminal dashboard event.
  Future<void>? _startRequest;

  bool _disposed = false;
  Future<void>? _init;
  bool _statsInFlight = false;

  // --- automatic Go-heap trim ---------------------------------------------
  //
  // The Go runtime is process-wide and the action bus owns its heap. Only the
  // service engine (the sole kernel owner) may drive it; the memory panel is
  // display-only. Two triggers, both full trims and both best effort:
  //   • the core stops/disconnects — its heap is idle, so return it to the OS;
  //   • the periodic check sees a high-water runtime heap with a meaningful
  //     idle share — reclaim it before the process RSS grows further.
  // No user toggle (doze is automatic), no new action, no platform changes.

  /// Injected clock so tests can advance the cooldown without real seconds.
  final DateTime Function()? _clock;
  DateTime get _now => (_clock ?? DateTime.now)();

  /// Injected stats reader so tests can drive the policy without the action bus.
  final Future<KernelMemoryStats> Function()? _memoryStatsReader;

  DateTime? _lastAutoTrimAt;
  DateTime? _lastAutoTrimCheckAt;
  /// Guards against overlapping checks (an action bus reply can be slow).
  bool _autoTrimInFlight = false;

  /// Reads the Go heap through the same action bus everything else uses. The
  /// action works with no running instance, but the bus must still be attached.
  Future<KernelMemoryStats> _runtimeMemory() {
    final reader = _memoryStatsReader;
    if (reader != null) return reader();
    final kernel = _kernel;
    if (kernel == null) throw StateError('the kernel action bus is not attached');
    return kernel
        .invoke<Object?>(ActionMethod.runtimeMemory)
        .then(KernelMemoryStats.fromJson);
  }

  /// Test-only seam for the automatic trim policy. The real triggers are the
  /// 1 Hz status feed and a core stop; tests drive the policy directly so a
  /// clock/cooldown scenario needs no timers or real seconds.
  @visibleForTesting
  Future<bool> debugAutoTrim(String reason) => _autoTrimGoHeap(reason);

  /// Returns whether a full trim was actually performed.
  ///
  /// Never throws into a lifecycle caller: every failure takes the note path.
  /// [reason] is only a breadcrumb; it does not change the trim level. The
  /// periodic trigger pre-checks the high-water predicate; the stop trigger
  /// trims unconditionally (the idle heap is known to be reclaimable).
  Future<bool> _autoTrimGoHeap(String reason) async {
    if (_disposed || _kernel == null) return false;
    final last = _lastAutoTrimAt;
    if (last != null && _now.difference(last) < kAutoTrimCooldown) return false;
    try {
      if (reason == 'periodic' && !shouldTrimGoHeap(await _runtimeMemory())) {
        return false;
      }
      if (!await forceGc(full: true)) return false;
      _lastAutoTrimAt = _now;
      note('auto memory trim ($reason): full Go GC');
      return true;
    } catch (error) {
      note('auto memory trim ($reason) failed: $error');
      return false;
    }
  }

  /// Fire-and-forget wrapper for lifecycle/event callers: a trim must never
  /// block or await a stop/reload, and overlapping checks are dropped.
  void _requestAutoTrim(String reason) {
    if (_disposed || _kernel == null || _autoTrimInFlight) return;
    _autoTrimInFlight = true;
    unawaited(_autoTrimGoHeap(reason).whenComplete(() {
      _autoTrimInFlight = false;
    }));
  }

  /// Piggybacks the 1 Hz status feed, throttled to [kAutoTrimCooldown] so at
  /// most one stats read per cooldown window. A failed check is retried on the
  /// next tick (no timestamp is recorded until a trim actually happens).
  void _maybeCheckMemory() {
    if (_disposed || _kernel == null || !active) return;
    final last = _lastAutoTrimCheckAt;
    if (last != null && _now.difference(last) < kAutoTrimCooldown) return;
    _lastAutoTrimCheckAt = _now;
    _requestAutoTrim('periodic');
  }

  /// Automatic restarts spent on the current incident; reset by a run that holds.
  int _recoveryAttempts = 0;

  /// How many restarts a single incident may spend before the failure is shown
  /// instead of retried. Three covers a transient network blip; more than that
  /// is a core that will not stay up.
  static const _maxRecoveries = 3;

  /// True when the rebuilt core is present and the FFI path drives it.
  @override
  bool get active => _kernel != null && _instanceHandle != null;

  /// Test-only: what a reload would fall back to right now (S4). A user stop clears it, so a
  /// later failure has nothing to restore.
  @visibleForTesting
  Map<String, dynamic>? get debugLastAcceptedBuild => _lastAcceptedBuild;

  /// The dashboard-style status of the core this engine drives. The `hello`
  /// handshake answers with it so a (re)connecting UI resyncs its view instead
  /// of trusting the last event of a previous link. A lost core reports
  /// 'Starting': a recovery is pending, and saying 'Stopped' here opened the
  /// arbitration window that let the channel resurrect 'Started'.
  String get statusWire => switch (_transition) {
    _Transition.stopping => 'Stopping',
    _Transition.starting => 'Starting',
    // A lost core reports 'Starting': a recovery is pending, and saying
    // 'Stopped' here opened the arbitration window that let the channel
    // resurrect 'Started'.
    _Transition.idle => active
        ? (_instanceLost ? 'Starting' : 'Started')
        : 'Stopped',
  };

  /// The single readiness answer: recovery → transition → instance fact.
  @override
  KernelPhase get kernelPhase {
    if (_recovering) return KernelPhase.recovering;
    return switch (_transition) {
      _Transition.starting => KernelPhase.starting,
      _Transition.stopping => KernelPhase.stopping,
      _Transition.idle => _instanceLost
          ? KernelPhase.lost
          : (active ? KernelPhase.running : KernelPhase.idle),
    };
  }

  /// True once the FFI path is engaged (the channel handlers step aside).
  @override
  bool get ffiMode => _kernel != null;

  /// The in-process/service driver is authoritative exactly when attached —
  /// the same condition as [ffiMode], reported on the hello wire and pushed to
  /// the host so `FlroneKernel.ffiMode` tracks a real FFI attach rather than
  /// engine existence.
  @override
  bool get driverReady => _kernel != null;

  /// The core's own run time. A wall-clock jump cannot drift it into a negative
  /// or backwards figure the way `now - startedAt` would.
  @override
  Duration? get uptime {
    final startedAt = _startedAt;
    if (startedAt == null || !active) return null;
    final elapsed = DateTime.now().difference(startedAt);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  /// The attached kernel, for callers that speak the action bus directly.
  ///
  /// Null when no driver is attached — the same condition as `ffiMode`. Callers ask for this
  /// rather than `ThroneKernel.ensure()`, so a test that substitutes a fake through
  /// [debugAttach] exercises the same code path as the app.
  @override
  ThroneKernel? get attached => _kernel;

  @override
  Future<T> invoke<T>(
    ActionMethod method, {
    Object? data,
    Duration timeout = actionTimeout,
  }) {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('the kernel action bus is not attached; start the VPN first');
    }
    return kernel.invoke<T>(method, data: data, timeout: timeout);
  }

  /// Runs an already-encoded Action JSON string (the UI engine's IPC wire)
  /// through the attached kernel's FFI bridge.
  ///
  /// [timeout] is the UI caller's budget, carried over the IPC envelope: the
  /// service engine must not cut a long action short at its own default.
  Future<dynamic> invokeActionWire(String wire, {Duration timeout = actionTimeout}) {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('the kernel action bus is not attached; start the VPN first');
    }
    return kernel.invokeWire(wire, timeout: timeout);
  }

  // --- lifecycle ----------------------------------------------------------

  /// Test-only: reaches the state [initialize] would leave after a successful
  /// attach without a native library or a worker. The tests pass signature-level
  /// fakes; only channel calls and the worker's lifecycle methods are exercised.
  void debugAttach(ThroneKernel kernel, KernelWorker worker) => _attach(kernel, worker);

  /// Wires the worker's event stream and the kernel's status feed to this
  /// driver. Both entry points — [initialize] and the tests' [debugAttach] —
  /// subscribe the same way, so they cannot drift apart.
  void _attach(ThroneKernel kernel, KernelWorker worker) {
    _kernel = kernel;
    _worker = worker;
    _workerSub = worker.events.listen(_onWorkerEvent, onError: report);
    // The Go side pushes a "status" event for every aggregate snapshot; the
    // worker heartbeat triggers it and uses the return value to detect loss.
    // VPN sign-in statuses, the connection feed and its attribution deltas are
    // other Go pushes: convert their {"method","data"} envelope into the
    // channel-shaped {"type","value"} event BoxController and the UI engine
    // consume. The connection feed exists because the UI no longer polls the
    // core's Clash API (see connections_actions.go).
    _statusSub = kernel.events.listen((event) {
      switch (event['method']) {
        case 'status':
          _onKernelStatus(event);
        case 'vpnStatus':
          _emitEvent({'type': 'vpnStatus', 'value': event['data']});
        case 'connections':
        case 'trafficDeltas':
          _emitEvent({'type': event['method'], 'value': event['data']});
      }
    }, onError: report);
    // Re-apply persisted hints after attach so a command that landed before
    // the bridge existed (boot doze, early log-stream toggle) is not lost.
    // Failures are swallowed by the setters' own guards; an attach must never
    // fail because a hint could not be delivered.
    unawaited(_applyDesiredHints());
  }

  /// Applies the remembered doze/log-stream values to the freshly attached
  /// kernel. Each action is best effort; neither failure may cancel the other.
  Future<void> _applyDesiredHints() async {
    if (_dozeSeen) {
      try {
        await setDoze(_dozeWanted);
      } catch (error) {
        report(error);
      }
    }
    if (_logStreamSeen) {
      try {
        await setLogStream(_logStreamWanted);
      } catch (error) {
        report(error);
      }
    }
  }

  /// Drops both subscriptions and the worker after a failed start-up. A worker
  /// that never came up is disposed on a best-effort basis: there is nothing
  /// left to tear down when it never attached.
  Future<void> _detach() async {
    await _workerSub?.cancel();
    await _statusSub?.cancel();
    _workerSub = null;
    _statusSub = null;
    final worker = _worker;
    _worker = null;
    _kernel = null;
    if (worker == null) return;
    try {
      await worker.dispose();
    } catch (_) {
      // The worker never came up; nothing to tear down.
    }
  }

  @override
  Future<void> initialize() => _init ??= _doInitialize();

  Future<void> _doInitialize() async {
    // Bridge mode: no FFI library is opened, no worker is created, and the
    // bridge is never told to stand aside. Everything below belongs to the
    // FFI driver and must stay out of the way when it is switched off.
    if (!kFfiDriverEnabled) return;
    if (_kernel != null) return;
    // Nothing to drive when the rebuilt core is absent: leave the bridge in
    // charge rather than ask it to stand aside for a library that is not there.
    if (!ThroneKernel.isAvailable) return;
    try {
      // The service engine is the sole kernel owner; the host set ffiMode=true
      // when it created this engine, so there is no bridge mode to announce and
      // no service-side box to hand over. Open the ABI and create the worker in
      // this isolate.
      final kernel = ThroneKernel.ensure();
      if (kernel == null) return;
      try {
        _attach(kernel, await KernelWorker.spawn());
      } catch (_) {
        // Without a worker there is no driver; detach so a later initialize()
        // can try again instead of treating a half-attached kernel as live.
        await _detach();
        rethrow;
      }
    } finally {
      // A failed or absent init must not poison the memo: a later
      // initialize() retries (the detach above leaves a clean world).
      if (_kernel == null) _init = null;
    }
  }

  /// Serializes one lifecycle op behind everything already queued. The chain
  /// itself never throws: ops report their own failures, and a failed op must
  /// not strand the ones behind it.
  Future<void> _enqueue(Future<void> Function() op) {
    final previous = _lifecycle;
    Future<void> run() async {
      if (previous != null) {
        try {
          await previous;
        } catch (_) {
          // The chain never fails its awaiters; the op below decides what a
          // failed predecessor means for the current world.
        }
      }
      if (_disposed || _kernel == null) return;
      await op();
    }
    final future = run();
    _lifecycle = future;
    // Keep an observed copy so a rejected op never surfaces as an unhandled
    // async error; callers that await get the real outcome.
    unawaited(future.catchError((Object _) {}));
    return future;
  }

  /// Starts the foreground service (Android duty) and the core itself.
  ///
  /// The two only meet when the core asks the platform for a tun, so they run at the same
  /// time: Android creating the service and Dart building the config have nothing to say to
  /// each other. Sequenced, the whole service bring-up (a process start, a notification, a
  /// VpnService instance) sat in front of a config build that then ran alone, and the user
  /// waited for the sum instead of the larger of the two.
  /// The highest command revision a start has claimed. A host stop carrying a
  /// lower one was commanded before that start and must not kill it.
  int _commandRevision = 0;

  @override
  Future<void> startService({int? revision}) async {
    if (revision != null && revision > _commandRevision) _commandRevision = revision;
    final pending = _startRequest;
    if (pending != null) {
      note('start: a start is already in progress');
      await pending;
      return;
    }
    final future = _startServiceOnce();
    _startRequest = future;
    try {
      await future;
    } finally {
      if (identical(_startRequest, future)) _startRequest = null;
    }
  }

  Future<void> _startServiceOnce() async {
    if (_kernel == null) {
      // A reused-engine start (startKernel from the host) can land before this
      // entrypoint's one-shot initialize() finished. Await it instead of
      // dropping the start on the floor.
      try {
        await initialize();
      } catch (error) {
        // The driver was meant to attach (the rebuilt core is in this build) and could not:
        // nothing will ever open a core, so this start is answered as a stop instead of
        // leaving the Android service waiting for a report that cannot come.
        await _noDriver(error);
        return;
      }
      // No driver at all (the rebuilt core is absent from this build): the channel path owns
      // the world here, exactly as [kFfiDriverEnabled] documents. Nothing is reported — a
      // driver that never existed has no business announcing state.
      if (_kernel == null) return;
    }
    note('start: user asked for the tunnel');
    // A start the user asked for is a fresh incident, whatever the last one cost.
    _recoveryAttempts = 0;
    await _enqueue(() => _startCore(bringUpService: true));
  }

  /// A start whose driver failed to attach: nothing will open a core.
  ///
  /// The Android service is already up (it was asked for first) and it is waiting for
  /// `state.markRunning` — the report that ends its `Connecting` state. That report cannot come,
  /// so the service is taken down here instead of lingering as a foreground notification and a
  /// VPN icon for a tunnel that does not exist.
  Future<void> _noDriver(Object error) async {
    note('start: the kernel driver did not attach ($error)');
    report(error);
    await _clearRunning();
    try {
      await host.call('service.stop').timeout(_hostStopTimeout);
    } catch (stopError) {
      note('start: no driver, and the service did not stop: $stopError');
    }
    _emitDashboard('Stopped');
  }

  @override
  Future<void> stopService() async {
    if (_kernel == null) return;
    note('stop: user asked to stop');
    await _enqueue(() async {
      await _stopCore();
      // The core is down either way and _stopCore has already published the
      // terminal state; the channel failure still propagates so callers see
      // the service stop failed (the pre-serialization behavior their bool
      // checks rely on).
      Object? serviceFailure;
      try {
        await host.call('service.stop').timeout(_hostStopTimeout);
      } catch (error) {
        note('stop: $error');
        serviceFailure = error;
      }
      if (serviceFailure != null) throw serviceFailure;
    });
  }

  /// A non-Dart stop (widget/tile/notification) reached the driver through the
  /// host event. The service is already stopping, so only the core is closed —
  /// calling `service.stop` again would bounce the stopRunner we are answering.
  @override
  Future<void> stopCoreFromHost({int? revision}) async {
    if (_kernel == null) return;
    if (revision != null && revision < _commandRevision) {
      // A stale stop: the start that claimed this revision ran after the stop
      // was commanded. Killing it now would flip a fresh tunnel back off.
      note('stop: ignoring a stale host stop (revision $revision < $_commandRevision)');
      return;
    }
    note('stop: host asked the driver to close the core');
    await _enqueue(() => _stopCore());
  }

  /// The coreConfig the running instance was started with. A rebuild that
  /// produces the exact same config (a reload with nothing changed, a second
  /// start racing the first) must not pay the stop/start round — FlClash's
  /// `inputsApplied()` skip, at the strongest level: the built output itself.
  String? _lastAppliedConfig;

  /// The whole built map the last successful start applied — `coreConfig`, the involved
  /// profiles and the route. A reload that cannot start its fresh build restores this
  /// one (see [reloadService]); a user stop drops it.
  Map<String, dynamic>? _lastAcceptedBuild;

  /// Rebuilds the config and restarts the core in place (the foreground service stays).
  /// Only restarts if the core is actually running — a stopped service must not be pulled
  /// up by a stale selection-change or mode-switch event, and a start still unwinding
  /// finishes first, so the check below sees its real outcome.
  /// [force] bypasses the identical-config skip. Recovery is the caller that
  /// needs it: a core that died without any setting change must be rebuilt, and
  /// the skip would otherwise answer "Started" over a dead instance.
  @override
  Future<void> reloadService({
    String reason = 'reload',
    bool Function()? skipIf,
    bool force = false,
  }) async {
    if (_kernel == null) return;
    note('reload: $reason');
    await _enqueue(() async {
      // A newer trigger owns the rebuild (FlClash's RunIntentArbiter semantics):
      // a queued reload whose world has moved on must not stop/start from it.
      if (skipIf?.call() ?? false) return;
      if (!active) return;
      // The stamp is sampled *before* the build: an edit that lands mid-reload then misses on
      // the next launch instead of pairing this config with a newer stamp (A15).
      final fingerprint = await _appliedFingerprint();
      // Build first and compare: when the rebuild would produce the config
      // already running, stopping the core is pure jank.
      final built = asStringKeyedMap(
        await host.call('config.build', configBuildArgs()).timeout(_hostOpTimeout),
        context: 'config.build',
      );
      final coreConfig = built['coreConfig'] as String? ?? '';
      if (!force && coreConfig.isNotEmpty && coreConfig == _lastAppliedConfig) {
        note('reload skipped: the built config is unchanged');
        _emitDashboard('Started');
        return;
      }
      // What the last accepted start applied, before the core goes down: a fresh build that
      // cannot come up falls back to it exactly once (see below).
      final previous = _lastAcceptedBuild;
      await _stopCore(clearRunning: false);
      // The retry is for a *rebuild* only (never a user stop, never a first start): a reload
      // whose new config is refused by the core leaves nothing running, and the config that
      // was working a moment ago is still in hand. The service is kept up for that attempt —
      // taking it down would remove the VpnService the retried core needs.
      final started = await _startCore(
        prebuilt: built,
        fingerprint: fingerprint,
        stopServiceOnFailure: previous == null,
      );
      if (started) return;
      if (previous == null) return;
      note('reload: the rebuilt config did not start; restoring the previous one');
      if (await _startCore(prebuilt: previous)) {
        report('The new config did not start. The previously applied config was restored.');
        // The fallback keeps a tunnel up, so the caller sees a completed reload while the
        // change it asked for is still unapplied. Say so on the event pipe: the UI raises
        // the manual apply badge again (the auto-apply path would otherwise leave the
        // running config silently stale).
        _emitEvent({
          'type': 'applyFailed',
          'value': {'reason': 'the new config did not start; the previous one was restored'},
        });
      }
      // A restore that fails too leaves the start-failure behaviour in place: the service is
      // down, the last error was reported, and the dashboard says Stopped.
    });
  }

  /// Persists the running-config facts for the code that reads them off the store
  /// (`ProfileManager.runningUses`, `RouteManager.runningRouteId`). The values come
  /// straight from `config.build`, so this never re-derives what the native side
  /// already computed. A failure is a breadcrumb, not a failed start: the tunnel
  /// works without them, the two guards above just go quiet.
  Future<void> _markRunning(Map<String, dynamic> built) async {
    final raw = built['involvedProfileIds'];
    final ids = raw is List
        ? raw.whereType<num>().map((value) => value.toInt()).toList()
        : <int>[];
    final routeId = (built['routeId'] as num?)?.toInt() ?? 0;
    try {
      await host.call('state.markRunning', {'involvedProfileIds': ids, 'routeId': routeId})
          .timeout(_hostStopTimeout);
    } catch (error) {
      note('running state: $error');
    }
  }

  Future<void> _clearRunning() async {
    try {
      await host.call('state.clearRunning').timeout(_hostStopTimeout);
    } catch (error) {
      note('running state: $error');
    }
  }

  // --- the last accepted config (A15) --------------------------------------

  /// The stamp of everything `config.build` reads, from the host: the profile/settings/route
  /// documents' sizes and mtimes plus the selected profile and route. Null when the host cannot
  /// answer (an older bridge, a test host) — which just means "build as before".
  Future<String?> _appliedFingerprint() async {
    try {
      final value = await host.call('config.fingerprint').timeout(_hostStopTimeout);
      return value is String && value.isNotEmpty ? value : null;
    } catch (error) {
      note('applied config: no fingerprint: $error');
      return null;
    }
  }

  /// The build recorded under [fingerprint], or null when there is none, it belongs to other
  /// inputs, or it is too incomplete to hand to `createInstance`.
  Future<Map<String, dynamic>?> _acceptedOptions(String fingerprint) async {
    try {
      final raw = await host.call('config.appliedGet').timeout(_hostStopTimeout);
      if (raw == null) return null;
      final record = asStringKeyedMap(raw, context: 'config.appliedGet');
      if (record['fingerprint'] != fingerprint) return null;
      final options = asStringKeyedMap(record['options'], context: 'config.appliedOptions');
      if (!isCompleteAppliedOptions(options)) {
        note('applied config: the stored options are incomplete; rebuilding');
        return null;
      }
      note('applied config: the inputs are unchanged; reusing the accepted build');
      return options;
    } catch (error) {
      note('applied config: no record: $error');
      return null;
    }
  }

  /// Clears the persisted record before a new config is pushed (FlClash's rule: a start that
  /// dies half way must not leave a record claiming a config it never applied).
  Future<void> _clearApplied() async {
    try {
      await host.call('config.appliedClear').timeout(_hostStopTimeout);
    } catch (error) {
      note('applied config: the record was not cleared: $error');
    }
  }

  /// Writes the record — only ever called after `worker.start()` succeeded.
  Future<void> _storeApplied(String fingerprint, Map<String, dynamic> options) async {
    try {
      await host.call(
        'config.appliedSet',
        {'fingerprint': fingerprint, 'options': options},
      ).timeout(_hostStopTimeout);
    } catch (error) {
      note('applied config: the record was not written: $error');
    }
  }

  /// The rule-set update result the core already reports, surfaced as a UI
  /// status event. Wire: `{type:'ruleSets', value:{updated, error, at}}` —
  /// `at` is milliseconds since epoch, stamped where the attempt completes.
  /// Carried by the same worker→UI event pipe as dashboard/rates, so no new
  /// channel method or per-rule-set listing API is involved.
  void _emitRuleSets(int updated, String error) {
    _emitEvent({
      'type': 'ruleSets',
      'value': {
        'updated': updated,
        'error': error,
        'at': DateTime.now().millisecondsSinceEpoch,
      },
    });
  }

  /// DeferredRuleSets' retry schedule (15 s, 60 s, 300 s): every set starts
  /// empty, and the core's updater only retries on its 24 h interval after a
  /// failed first fetch. Runs until one round succeeds or the instance changes.
  Future<void> _updateRuleSetsAfterStart(KernelWorker worker) async {
    const pauses = [
      Duration(seconds: 15),
      Duration(seconds: 60),
      Duration(seconds: 300),
    ];
    final startedHandle = _instanceHandle;
    for (var round = 0; round < pauses.length; round++) {
      await Future<void>.delayed(pauses[round]);
      if (_instanceHandle != startedHandle || startedHandle == null) return;
      try {
        final result = await worker.updateRuleSets();
        if (result == null) return;
        final updated = (result['updated'] as num?)?.toInt() ?? 0;
        final failures = '${result['error'] ?? ''}';
        _emitRuleSets(updated, failures);
        if (failures.isEmpty) {
          note('rule-sets: $updated downloaded and cached');
          return;
        }
        note('rule-sets: $updated fetched; failed: $failures');
      } catch (error) {
        _emitRuleSets(0, '$error');
        note('rule-sets: update stopped: $error');
        return;
      }
    }
  }

  /// Asks the core whether the running config needs Wi-Fi state, and turns the Android
  /// monitor on or off accordingly. Both halves matter: an unnecessary monitor keeps a
  /// ConnectivityManager callback alive, and a missing one silently drops every rule
  /// scoped to an SSID.
  Future<void> _watchWifiRules(KernelWorker worker) async {
    var needed = false;
    try {
      needed = await worker.needWifiState();
    } catch (error) {
      note('wifi rules: $error');
    }
    try {
      await host.call('wifi.watch', {'enabled': needed}).timeout(_hostStopTimeout);
    } catch (error) {
      note('wifi rules: $error');
    }
  }

  /// An SSID/BSSID change announced by the Android monitor; the core re-reads the
  /// platform's state through the same `CorePlatform` implementation as always.
  @override
  Future<void> updateWifiState() async {
    final worker = _worker;
    if (worker == null || !active) return;
    try {
      await worker.updateWifiState();
    } catch (error) {
      note('wifi state: $error');
    }
  }

  /// The manual "Update resources" rule-set half: fetches the running config's
  /// remote sets now instead of waiting for the core's 24 h interval.
  ///
  /// [updateRuleSets] is public on the control contract because a user can ask
  /// for it (the routing screen's action); the automatic retry after a deferred
  /// start is [_updateRuleSetsAfterStart], which calls the worker directly so a
  /// stop mid-retry cannot resurrect the update.
  ///
  /// A user-initiated call with no instance is a refusal, not a no-op: nothing
  /// was updated and the caller must be able to say why. The result also
  /// becomes the `ruleSets` status event, so the routing settings caption
  /// reflects this run rather than the last automatic one.
  @override
  Future<Map<String, dynamic>> updateRuleSets() async {
    final worker = _worker;
    if (worker == null || _instanceHandle == null || _instanceLost) {
      throw const KernelProxyException(
        'The core is not running; start the tunnel before updating rule sets.',
      );
    }
    final result = await worker.updateRuleSets();
    if (result == null) {
      throw const KernelProxyException(
        'The core has no instance to update rule sets for.',
      );
    }
    final updated = (result['updated'] as num?)?.toInt() ?? 0;
    final error = '${result['error'] ?? ''}';
    _emitRuleSets(updated, error);
    note(
      error.isEmpty
          ? 'rule-sets: $updated downloaded and cached (manual update)'
          : 'rule-sets: $updated fetched; failed: $error (manual update)',
    );
    return <String, dynamic>{'updated': updated, 'error': error};
  }

  /// Starts the core. Returns whether this call left a running instance behind: a reload uses
  /// the answer to decide whether its freshly built config held (S4's restore rule).
  ///
  /// [prebuilt] is a map a reload already built; [fingerprint] is the stamp of the build inputs
  /// sampled before that build (A15). [stopServiceOnFailure] is off for the first attempt of a
  /// reload: that attempt may be followed by a restore, which needs the service still up.
  Future<bool> _startCore({
    bool bringUpService = false,
    Map<String, dynamic>? prebuilt,
    String? fingerprint,
    bool stopServiceOnFailure = true,
  }) async {
    if (_kernel == null || _starting || _disposed) return false;
    final worker = _worker;
    if (worker == null) {
      // Nothing can start without the engine; confirm the world is stopped so
      // a status that never reaches a terminal state cannot stick.
      _emitDashboard('Stopped');
      return false;
    }
    // A start requested while a core already runs (double tap, a queued second
    // start) must not overwrite `_instanceHandle` and orphan the live instance
    // inside the worker — the old one would never be closed. A lost core
    // leaves the handle pointing at a dead instance, so `active` alone would
    // swallow a user's manual start during the recovery backoff; the lost
    // flag tells the two apart.
    if (active && !_instanceLost) {
      note('start: the core is already running');
      // Re-affirm the terminal state: a queued start must not leave the UI
      // waiting on a 'Starting' that this call will never produce.
      _emitDashboard('Started');
      return true;
    }
    _transition = _Transition.starting;
    _epoch++;
    _emitDashboard('Starting');
    final beganAt = DateTime.now();
    final clock = Stopwatch()..start();
    var serviceMs = 0;
    var configMs = 0;
    var reused = false;
    try {
      // A15: before paying for a build, ask whether the inputs produce the config already
      // applied. The persisted record is trusted only when the stamp still matches and the
      // stored options are complete enough to hand to `createInstance`; anything else falls
      // through to a real build. A reload hands its own [prebuilt]/[fingerprint] instead.
      Map<String, dynamic>? recorded;
      if (prebuilt == null) {
        fingerprint ??= await _appliedFingerprint();
        if (fingerprint != null) recorded = await _acceptedOptions(fingerprint);
        reused = recorded != null;
      }
      // The native DB owns the selection (DataStore.selectedProxy). The Flutter
      // preference store holds UI settings only, so mining it for an id used to
      // send 0 here and fail every start with "profile 0 is gone". A reload that
      // already built its config passes it in [prebuilt] and skips the channel.
      final Future<dynamic>? build = prebuilt == null && recorded == null
          ? host
              .call('config.build', configBuildArgs())
              .timeout(_hostOpTimeout)
              .whenComplete(() => configMs = clock.elapsedMilliseconds)
          : null;
      // Android's half runs alongside the build above: in ffiMode the service owns the
      // VpnService the core asks for a tun, and nothing in the config depends on it.
      final serviceUp = bringUpService
          ? host.call('service.start')
              .timeout(_hostStartTimeout)
              .whenComplete(() => serviceMs = clock.elapsedMilliseconds)
          : null;
      // Both are already in flight. Await the service half first: when Android refuses
      // the VPN (no permission, always-on conflict) there is no reason to make the
      // user sit through a slow config build before seeing the error. The build
      // is still awaited below on the success path, and observed here on failure so
      // its resources are released rather than completing unobserved.
      if (serviceUp != null) {
        try {
          await serviceUp;
        } catch (error) {
          if (build != null) {
            unawaited(() async {
              try {
                await build;
              } catch (buildError) {
                note('config.build after a failed service start: $buildError');
              }
            }());
          }
          rethrow;
        }
      }
      // The channel reply is a `Map<String, dynamic>` after BoxController.call
      // normalizes it. Use a checked conversion so a future codec change fails
      // with a readable message instead of a bare type-cast exception.
      final built = prebuilt ??
          recorded ??
          asStringKeyedMap(await build, context: 'config.build');
      final readyMs = clock.elapsedMilliseconds;
      // FlClash's clear-before-push: the record must never describe a config that did not
      // start. Written again only after worker.start() below succeeded.
      if (fingerprint != null && !reused) await _clearApplied();
      final handle = await worker.createInstance(built);
      _instanceHandle = handle;
      final instanceMs = clock.elapsedMilliseconds;
      await worker.start();
      // The start held: whatever the worker reported lost before is replaced
      // by a core that is answering again.
      _instanceLost = false;
      await worker.setHeartbeat(true);
      final startMs = clock.elapsedMilliseconds;
      _startedAt = DateTime.now();
      _lastAppliedConfig = built['coreConfig'] as String? ?? _lastAppliedConfig;
      _lastAcceptedBuild = built;
      _resetRateBaseline();
      // Split by phase: the total alone cannot say whether the next second should be spent on
      // Android's service, on the config build, or inside the core's own start.
      final phases = [
        if (bringUpService) 'service $serviceMs',
        if (reused) 'config reused' else 'config $configMs',
        'instance ${instanceMs - readyMs}',
        'start ${startMs - instanceMs}',
      ].join(', ');
      note('core started in ${DateTime.now().difference(beganAt).inMilliseconds}ms ($phases)');
      _emitDashboard('Started');
      // The accepted config, now that the start held (A15's second rule). The stamp is the one
      // sampled before the build, so inputs that moved meanwhile miss on the next launch.
      if (fingerprint != null && !reused) await _storeApplied(fingerprint, built);
      // What the service used to write right after proxy.init(). Running a chain is not only the
      // box's business: ProfileManager.runningUses refuses to delete a node a running config still
      // uses, and RouteManager.runningRouteId decides whether a group's routing change needs a
      // reload. Both read the store, so the facts are reported here once the start held — after
      // the screen has been told the tunnel is up, since it reads none of them, and the two guards
      // above are only consulted when the user edits a profile or a route.
      // It is also what makes the Android service Connected (`state.markRunning`): the service
      // announces `Connecting` while it prepares and never claims a tunnel on its own.
      await _markRunning(built);
      // Wi-Fi-scoped routes, DNS and rule sets need the core re-read whenever the SSID
      // changes. The monitor is Android's (it owns the callback); whether one is needed at
      // all is the core's answer, so ask the box that just started.
      await _watchWifiRules(worker);
      // The config was built without waiting for its remote rule-sets (the
      // deferred start the user consented to). Fetch them now that the box is
      // up, the way DeferredRuleSets.afterStart does on the service path.
      if (built['deferRuleSets'] == true) {
        unawaited(_updateRuleSetsAfterStart(worker));
      }
      return true;
    } catch (error) {
      note('core start FAILED: $error');
      report(error);
      // Release the instance that may have been partially started so the next
      // createInstance does not silently orphan it inside the worker.
      try { await worker.stop(); } catch (_) { /* Already stopped or never started. */ }
      _instanceHandle = null;
      // A failed start leaves nothing running, and a reload that kept the old facts
      // would otherwise describe a core that is not there. This also takes a service
      // still waiting for `state.markRunning` down to Stopped (the host side of it).
      await _clearRunning();
      // The service must not keep a notification and a VPN icon for a tunnel that is not
      // there — and with `active == false` the watchdog will not recover it. A reload that
      // may still restore the previous config skips this: the retry needs the VpnService.
      if (stopServiceOnFailure) {
        // Same order as stopService(). Best effort: a channel failure here must not hide
        // the original start error.
        try {
          await host.call('service.stop').timeout(_hostStopTimeout);
        } catch (stopError) {
          note('core start FAILED: could not stop the service: $stopError');
        }
      }
      _emitDashboard('Stopped');
      return false;
    } finally {
      _transition = _Transition.idle;
    }
  }

  Future<void> _stopCore({bool clearRunning = true}) async {
    // The transition first: the two host calls below can take seconds, and a
    // hello arriving in that window must report 'Stopping'. Clearing the handle
    // first left statusWire saying 'Stopped' while the core ran on.
    _transition = _Transition.stopping;
    final handle = _instanceHandle;
    _instanceHandle = null;
    _startedAt = null;
    _resetRateBaseline();
    // A stop acknowledges a loss even when the lost instance never gets to be
    // closed: the world is going down either way, so a pending recovery is
    // moot and an epoch bump here (a real transition) is what the delayed
    // recovery's staleness check reads.
    _instanceLost = false;
    // A reload keeps the facts: the next start writes them again a moment later, and the gap is
    // not a stop the user asked for. The Wi-Fi monitor follows the same rule — it is useless
    // without a box, and rebuilding it on every reload would drop a change that lands between.
    // The same distinction decides the restore fallback (S4): only a reload keeps the previous
    // config around; after a user stop there is nothing to fall back to.
    if (clearRunning) {
      _lastAcceptedBuild = null;
      await _clearRunning();
      try {
        await host.call('wifi.watch', {'enabled': false}).timeout(_hostStopTimeout);
      } catch (error) {
        note('wifi rules: $error');
      }
    }
    final worker = _worker;
    if (handle == null || worker == null) {
      // Nothing to close; still confirm the terminal state so a 'Starting'
      // left by an earlier op cannot stick (a stop answers the whole world).
      _transition = _Transition.idle;
      _emitDashboard('Stopped');
      // The old instance is gone: hand its idle heap back once. Cooldown-capped.
      _requestAutoTrim('stop');
      return;
    }
    _epoch++;
    _emitDashboard('Stopping');
    try {
      await worker.setHeartbeat(false);
      await worker.stop();
    } catch (error) {
      report(error);
    } finally {
      _transition = _Transition.idle;
      // Every stop path ends in a terminal event. A host stop (tile /
      // notification / widget) reaches only this function — without the event
      // its 'Stopping' was the last word the UI ever heard, and the
      // driver-owned arbitration kept every later channel 'Stopped' masked.
      _emitDashboard('Stopped');
      // Fire-and-forget: a trim must never hold up the stop/reload queue.
      // The instance was just closed, so its heap is idle now; a reload's
      // cooldown window naturally suppresses a redundant trim on the reload's
      // own stop if one just ran.
      _requestAutoTrim('stop');
    }
  }

  // --- operations ---------------------------------------------------------

  /// Outbound mode (rule/global/direct): persist, then rebuild the routing config.
  @override
  Future<void> setMode(String mode) async {
    if (_kernel == null) return;
    await host.call('state.setMode', {'mode': mode});
    // The mode is channel-owned: state.setMode persists it and refreshes the
    // host's dashboard wire (scheduleRefresh). Emitting it here duplicated that
    // channel value on the driver slice, where the merge deliberately drops it.
    await reloadService(reason: 'outbound mode -> $mode');
  }

  /// Runs the Go GC. [full] adds `debug.FreeOSMemory()`; false is the light
  /// collection for ordinary pressure. It is required and forwarded verbatim —
  /// the Go handler refuses a missing flag. Process-wide, so this works with or
  /// without a running instance — but only while the action bus is attached.
  /// The host trim on the same path is a separate call; one failing must not
  /// stop the other.
  Future<bool> forceGc({required bool full}) async {
    final kernel = _kernel;
    if (kernel == null) return false;
    final reply = await kernel.invoke<Object?>(
      ActionMethod.forceGC,
      data: {'full': full},
    );
    return reply is bool ? reply : true;
  }

  /// Device doze hint from the Android host (PowerManager idle + screen off).
  /// Unlike setScreenOff (a UI-lifecycle backgrounding hint), this really does
  /// pause/wake the running instance's periodic work. The desired value is
  /// remembered so a command arriving before FFI attach is re-applied there,
  /// and so a kernel started while dozing comes up paused (Go persists it).
  Future<bool> setDoze(bool enabled) async {
    _dozeWanted = enabled;
    _dozeSeen = true;
    final kernel = _kernel;
    if (kernel == null) return false;
    final reply = await kernel.invoke<Object?>(
      ActionMethod.setDoze,
      data: {'enabled': enabled},
    );
    return reply is bool ? reply : true;
  }

  /// Gates the Go log sink's verbose levels. The sink always forwards
  /// warn/error/fatal/panic; this only controls the lower levels. Like [setDoze],
  /// the desired value survives an early (pre-attach) call via [_attach].
  Future<bool> setLogStream(bool enabled) async {
    _logStreamWanted = enabled;
    _logStreamSeen = true;
    final kernel = _kernel;
    if (kernel == null) return false;
    final reply = await kernel.invoke<Object?>(
      ActionMethod.setLogStream,
      data: {'enabled': enabled},
    );
    return reply is bool ? reply : true;
  }

  /// Bumped by every profile/group selection; a queued rebuild that lost the
  /// race to a newer one stands down instead of rebuilding a mid-state world.
  int _selectionEpoch = 0;

  /// A profile/group selection already persisted by the channel; the core follows.
  /// In-process there is no UI-facing kernel tail to gate: the service engine's worker
  /// isolate owns the forwarding (and its own ring), so the demand signal ends here.
  @override
  Future<void> setKernelLogsVisible(bool visible) async {}

  @override
  Future<void> onSelectionChanged() async {
    if (_kernel == null) return;
    final epoch = ++_selectionEpoch;
    await reloadService(
      reason: 'profile selection changed',
      skipIf: () => epoch != _selectionEpoch,
    );
    _emitDashboard(null);
  }

  // --- events --------------------------------------------------------------

  void _onKernelStatus(BridgeEvent event) {
    final data = event['data'];
    if (data is! Map) return;
    final snapshot = <String, int>{};
    for (final entry in data.entries) {
      final value = (entry.value as num?)?.toInt();
      if (value != null) snapshot[entry.key.toString()] = value;
    }
    // `throne_status_snapshot` answers `{"alive":1}` when the counters could
    // not be read (a box closing under the read). That is a missed sample, not
    // a zero rate: emitting it made the speed card jump to 0 for one tick.
    if (!snapshot.containsKey('uplink') && !snapshot.containsKey('downlink')) {
      return;
    }
    // The `uplink`/`downlink` fields are per-call deltas: `Status()` advances
    // its own baseline, so any other reader of the same instance steals this
    // reader's bytes. The cumulative totals are not destructive, so derive the
    // rate from them and keep the deltas only as the fallback for a core that
    // does not report totals.
    final now = DateTime.now().millisecondsSinceEpoch;
    final upTotal = snapshot['uplinkTotal'];
    final downTotal = snapshot['downlinkTotal'];
    if (upTotal != null && downTotal != null) {
      final elapsed = now - _lastRateAt;
      if (_lastRateAt > 0 &&
          elapsed > 0 &&
          upTotal >= _lastUpTotal &&
          downTotal >= _lastDownTotal) {
        snapshot['uplink'] = ((upTotal - _lastUpTotal) * 1000 / elapsed).round();
        snapshot['downlink'] =
            ((downTotal - _lastDownTotal) * 1000 / elapsed).round();
      }
      _lastUpTotal = upTotal;
      _lastDownTotal = downTotal;
      _lastRateAt = now;
    }
    // `trafficAvailable` used to gate this event. A core whose snapshot never
    // sets the flag (a stale libthrone.so, or a read that raced the box) left
    // the speed card and the notification at 0 for the whole session. The
    // keys above are the real availability signal: an unreadable snapshot has
    // neither, and an idle tunnel reports real zeros.
    _emitStatus(snapshot);
    _publishStats(snapshot);
    // The status feed is the only 1 Hz pulse in the service engine. Sample the
    // Go heap here (throttled internally) so a sustained high-water crossing
    // can trigger a full trim without a second timer or a new action.
    _maybeCheckMemory();
  }

  /// The notification's speed line and the widget read the service's own counters, and in
  /// FFI mode nothing on that side polls the core — `TrafficLooper` needs a ProxyInstance.
  /// Push the same snapshot it would have produced; the screen-off rule is already handled
  /// on the Kotlin side by `listenPostSpeed`.
  void _publishStats(Map<String, int> snapshot) {
    // One status snapshot per second, but a busy main thread can leave a channel
    // call in flight for longer. Drop the overlap instead of piling up replies
    // that would all describe an older second anyway.
    if (_disposed || _statsInFlight) return;
    _statsInFlight = true;
    unawaited(() async {
      try {
        await host.call('state.stats', {
          'txRate': snapshot['uplink'] ?? 0,
          'rxRate': snapshot['downlink'] ?? 0,
          'txTotal': snapshot['uplinkTotal'] ?? 0,
          'rxTotal': snapshot['downlinkTotal'] ?? 0,
        });
      } catch (_) {
        // A notification that cannot be updated is not a reason to lose the status stream.
      } finally {
        _statsInFlight = false;
      }
    }());
  }

  void _onWorkerEvent(WorkerEvent event) {
    if (event['type'] != 'lost') return;
    final reason = event['error'];
    report(StateError(reason is String && reason.isNotEmpty
        ? 'the kernel stopped responding: $reason'
        : 'the kernel stopped responding'));
    _instanceLost = true;
    // A lost core is a pending recovery, not a terminal state: say 'Starting'
    // so the driver keeps dashboard ownership while the Android side still
    // believes the service is Connected. A 'Stopped' here opened the
    // arbitration window and let the channel resurrect 'Started'.
    _emitDashboard('Starting');
    _recoverOnce();
  }

  /// Restarts a lost core with a growing delay, and stops after
  /// [_maxRecoveries] attempts in a row. A core that dies, comes back and dies
  /// again seconds later is not fixed by another restart: looping forever only
  /// hides the failure, so the last attempt is reported and left alone.
  Future<void> _recoverOnce() async {
    if (_recovering) return;
    // A run that held for a while is a new incident, not a repeat of the last one.
    final ranFor = _startedAt == null ? null : DateTime.now().difference(_startedAt!);
    if (ranFor != null && ranFor >= const Duration(minutes: 1)) _recoveryAttempts = 0;
    if (_recoveryAttempts >= _maxRecoveries) {
      report(StateError(
          'the kernel cannot stay up; automatic recovery stopped after $_maxRecoveries attempts'));
      // The world ends here: without a terminal event the UI would keep
      // showing the 'Starting' the loss announced.
      _emitDashboard('Stopped');
      return;
    }
    _recovering = true;
    final attempt = _recoveryAttempts;
    _recoveryAttempts++;
    // The world when the core was lost: if any lifecycle command runs while the
    // backoff sleeps (the user stopped, or stopped and restarted), the epoch no
    // longer matches and this recovery stands down instead of reloading a
    // tunnel the user just brought up.
    final epochAtLoss = _epoch;
    try {
      if (attempt > 0) {
        _emitDashboard('Starting');
        await Future<void>.delayed(recoveryBackoff(attempt));
        if (!active) return; // the user stopped it while waiting
        if (_epoch != epochAtLoss) return; // ...or stopped and restarted it
      }
      // force: the core is gone whatever the config says; the identical-config
      // skip would otherwise report "Started" over the dead instance.
      await reloadService(
        reason: 'heartbeat lost, attempt ${attempt + 1}',
        force: true,
      );
      if (active) report('the kernel was restarted automatically');
    } catch (error) {
      report(error);
    } finally {
      _recovering = false;
    }
  }

  /// The 10s first backoff and 30s second one. [recoveryBackoffOverride] lets
  /// widget tests exercise the backoff window without real seconds.
  static Duration recoveryBackoff(int attempt) =>
      recoveryBackoffOverride != Duration.zero
          ? recoveryBackoffOverride
          : (attempt == 1 ? const Duration(seconds: 10) : const Duration(seconds: 30));

  /// Test-only: when non-zero, replaces the recovery backoff entirely.
  @visibleForTesting
  static Duration recoveryBackoffOverride = Duration.zero;

  void _emitStatus(Map<String, int> snapshot, {bool rates = true}) {
    if (_disposed) return;
    if (rates) {
      _emitEvent({
        'type': 'rates',
        'value': {
          'upload': snapshot['uplink'] ?? 0,
          'download': snapshot['downlink'] ?? 0,
        },
      });
    }
    _emitDashboard(
      switch (_transition) {
        _Transition.stopping => 'Stopping',
        _Transition.starting => 'Starting',
        _Transition.idle => 'Started',
      },
      snapshot: snapshot,
    );
  }

  /// Emits the *driver-owned slice* of the dashboard wire — never a whole snapshot.
  ///
  /// In the service engine the host snapshot is permanently empty
  /// (`KernelWorkerHost.dashboard` / `.configurations`): the channel owns the mode,
  /// the selection and the rest, and [BoxController.mergeDriverDashboard] keeps only
  /// [driverOwnedDashboard] keys from this event. Copying the empty host map — or
  /// padding `modes`/`mode`/`selectedProfileName` with fabricated defaults — made the
  /// wire *look* like an authoritative snapshot and invited future readers to trust
  /// values the driver does not own. Emit only the live fields the driver measures;
  /// everything else comes from the channel as before.
  void _emitDashboard(String? status, {Map<String, int>? snapshot}) {
    if (_disposed) return;
    // A null status means "recompute from the driver's own state", not "Stopped":
    // this is the same answer `statusWire` gives the `hello` handshake, so a
    // selection-change event cannot lie about a running core.
    final effectiveStatus = status ?? statusWire;
    // Clear startedAt when stopped so the dashboard does not show a stale timer.
    final startedAt = effectiveStatus == 'Stopped' || effectiveStatus == 'Idle'
        ? 0
        : _startedAt?.millisecondsSinceEpoch ?? 0;
    // `connections` is derived from the core's status counters only when the
    // snapshot actually carries them. An absent pair must leave the key out so
    // mergeDriverDashboard cannot overwrite the channel's real count with a 0.
    final inCount = snapshot?['connectionsIn'] as num?;
    final outCount = snapshot?['connectionsOut'] as num?;
    final int? connections = inCount != null || outCount != null
        ? ((inCount ?? 0) + (outCount ?? 0)).toInt()
        : null;
    final value = <String, dynamic>{
      'status': effectiveStatus,
      'startedAt': startedAt,
      'uploadTotal': snapshot?['uplinkTotal'] ?? 0,
      'downloadTotal': snapshot?['downlinkTotal'] ?? 0,
      ...(connections == null ? const <String, dynamic>{} : {'connections': connections}),
      'memory': snapshot?['memory'] ?? 0,
      'goroutines': snapshot?['goroutines'] ?? 0,
      // Forwarded for the speed card's diagnostic panel: whether the core
      // actually has a traffic manager counting (0 on a core that reports
      // none, e.g. an old libthrone.so — distinct from "no traffic").
      'trafficAvailable': snapshot?['trafficAvailable'] ?? 0,
    };
    _emitEvent({'type': 'dashboard', 'value': value});
  }

  /// Single exit for every emitted event: local stream in tests / the
  /// in-process driver, injected IPC sink in the service engine.
  void _emitEvent(Map<String, dynamic> event) {
    if (_disposed) return;
    _eventSink(event);
  }

  void report(Object error) {
    if (_disposed) return;
    _emitEvent({'type': 'error', 'value': error.toString()});
  }

  /// Writes one lifecycle breadcrumb into the core log — the same file the log
  /// screen shows. A core that closes on its own leaves no trace of who asked
  /// for it, which is exactly what a start/restart loop is made of; these lines
  /// name the caller and the reason.
  void note(String text) {
    if (_disposed) return;
    unawaited(() async {
      try {
        await host.call('log.note', {'text': text});
      } catch (_) {
        // Diagnostics must never be the reason a lifecycle step fails.
      }
    }());
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_workerSub?.cancel());
    unawaited(_statusSub?.cancel());
    final worker = _worker;
    _worker = null;
    if (worker != null) {
      // dispose() races the ops still unwinding in the queue: a worker disposed
      // early can fail a late command. That failure is expected here — catch it
      // so `unawaited` never surfaces it.
      unawaited(worker.dispose().catchError((Object _) {}));
    }
    if (_ownsEvents) unawaited(_localEvents.close());
    _kernel?.dispose();
    _kernel = null;
    _instanceHandle = null;
  }
}

/// The `config.build` payload: deliberately no `id`. The native bridge resolves
/// the selected ProxyEntity from DataStore.selectedProxy; neither the Flutter
/// UI preferences (appearance settings only) nor the dashboard's group id is a
/// proxy entity id. Sending a guessed 0 used to fail with "profile 0 is gone".
Map<String, dynamic> configBuildArgs() => <String, dynamic>{};

/// Whether a persisted built map carries everything `createInstance` reads (A15).
///
/// A record written by an older build — or one truncated by a crash — must never be handed to
/// the core: the start would fail on a missing key with a config nobody can inspect.
/// `coreConfig` is essential, and the profile ids plus the route are what `state.markRunning`
/// reports after the start.
bool isCompleteAppliedOptions(Map<String, dynamic> options) {
  final coreConfig = options['coreConfig'];
  return coreConfig is String &&
      coreConfig.isNotEmpty &&
      options['involvedProfileIds'] is List &&
      options['routeId'] is num;
}

/// The dashboard's selected id is a *group* id (B-box's profile card), used only
/// for display and for looking the name up in `box.configurations`.
int dashboardSelectedId(Map<String, dynamic> dashboard) =>
    (dashboard['selectedProfileId'] as num?)?.toInt() ?? -1;

/// The driver's in-flight lifecycle transition.
///
/// Private on purpose: [KernelPhase] is the public, single readiness answer.
enum _Transition { idle, starting, stopping }
