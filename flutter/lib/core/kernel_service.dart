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
  KernelService(this.host, {KernelEventSink? sink})
      : _ownsEvents = sink == null {
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
  bool _starting = false;
  bool _stopping = false;
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
  /// call on the start/stop path is therefore bounded; the UI safety net is
  /// longer than these so the op's own error is what the user sees.
  static const _hostOpTimeout = Duration(seconds: 30);
  static const _hostStopTimeout = Duration(seconds: 15);

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

  bool _disposed = false;
  Future<void>? _init;
  bool _statsInFlight = false;

  /// Automatic restarts spent on the current incident; reset by a run that holds.
  int _recoveryAttempts = 0;

  /// How many restarts a single incident may spend before the failure is shown
  /// instead of retried. Three covers a transient network blip; more than that
  /// is a core that will not stay up.
  static const _maxRecoveries = 3;

  /// True when the rebuilt core is present and the FFI path drives it.
  @override
  bool get active => _kernel != null && _instanceHandle != null;

  /// The dashboard-style status of the core this engine drives. The `hello`
  /// handshake answers with it so a (re)connecting UI resyncs its view instead
  /// of trusting the last event of a previous link. A lost core reports
  /// 'Starting': a recovery is pending, and saying 'Stopped' here opened the
  /// arbitration window that let the channel resurrect 'Started'.
  String get statusWire => _stopping
      ? 'Stopping'
      : (_starting
          ? 'Starting'
          : (active ? (_instanceLost ? 'Starting' : 'Started') : 'Stopped'));

  /// True once the FFI path is engaged (the channel handlers step aside).
  @override
  bool get ffiMode => _kernel != null;

  /// The in-process/service driver is authoritative exactly when attached —
  /// the same condition as [ffiMode], reported on the hello wire and pushed to
  /// the host so `BboxKernel.ffiMode` tracks a real FFI attach rather than
  /// engine existence.
  @override
  bool get driverReady => _kernel != null;

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
    Duration timeout = const Duration(seconds: 30),
  }) {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('the kernel action bus is not attached; start the VPN first');
    }
    return kernel.invoke<T>(method, data: data, timeout: timeout);
  }

  /// Runs an already-encoded Action JSON string (the UI engine's IPC wire)
  /// through the attached kernel's FFI bridge.
  Future<dynamic> invokeActionWire(String wire) {
    final kernel = _kernel;
    if (kernel == null) {
      throw StateError('the kernel action bus is not attached; start the VPN first');
    }
    return kernel.invokeWire(wire);
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
    _statusSub = kernel.events
        .where((event) => event['method'] == 'status')
        .listen(_onKernelStatus, onError: report);
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
    if (_kernel == null) {
      // A reused-engine start (startKernel from the host) can land before this
      // entrypoint's one-shot initialize() finished. Await it instead of
      // dropping the start on the floor.
      try {
        await initialize();
      } catch (_) {
        return; // no driver: the host start path owns the world
      }
      if (_kernel == null) return;
    }
    note('start: user asked for the tunnel');
    // A start the user asked for is a fresh incident, whatever the last one cost.
    _recoveryAttempts = 0;
    await _enqueue(() => _startCore(bringUpService: true));
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

  /// Rebuilds the config and restarts the core in place (the foreground service stays).
  /// Only restarts if the core is actually running — a stopped service must not be pulled
  /// up by a stale selection-change or mode-switch event, and a start still unwinding
  /// finishes first, so the check below sees its real outcome.
  /// The coreConfig the running instance was started with. A rebuild that
  /// produces the exact same config (a reload with nothing changed, a second
  /// start racing the first) must not pay the stop/start round — FlClash's
  /// `inputsApplied()` skip, at the strongest level: the built output itself.
  String? _lastAppliedConfig;

  /// up by a stale selection-change or mode-switch event, and a start still unwinding
  /// finishes first, so the check below sees its real outcome.
  @override
  Future<void> reloadService({String reason = 'reload', bool Function()? skipIf}) async {
    if (_kernel == null) return;
    note('reload: $reason');
    await _enqueue(() async {
      // A newer trigger owns the rebuild (FlClash's RunIntentArbiter semantics):
      // a queued reload whose world has moved on must not stop/start from it.
      if (skipIf?.call() ?? false) return;
      if (!active) return;
      // Build first and compare: when the rebuild would produce the config
      // already running, stopping the core is pure jank.
      final built = asStringKeyedMap(
        await host.call('config.build', configBuildArgs()).timeout(_hostOpTimeout),
        context: 'config.build',
      );
      final coreConfig = built['coreConfig'] as String? ?? '';
      if (coreConfig.isNotEmpty && coreConfig == _lastAppliedConfig) {
        note('reload skipped: the built config is unchanged');
        _emitDashboard('Started');
        return;
      }
      await _stopCore(clearRunning: false);
      await _startCore(prebuilt: built);
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

  /// Asks the core whether the running config needs Wi-Fi state, and turns the Android
  /// monitor on or off accordingly. Both halves matter: an unnecessary monitor keeps a
  /// ConnectivityManager callback alive, and a missing one silently drops every rule
  /// scoped to an SSID.
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
        final failures = '${result['error'] ?? ''}';
        if (failures.isEmpty) {
          note('rule-sets: ${result['updated']} downloaded and cached');
          return;
        }
        note('rule-sets: ${result['updated']} fetched; failed: $failures');
      } catch (error) {
        note('rule-sets: update stopped: $error');
        return;
      }
    }
  }

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

  Future<void> _startCore({bool bringUpService = false, Map<String, dynamic>? prebuilt}) async {
    if (_kernel == null || _starting || _disposed) return;
    final worker = _worker;
    if (worker == null) {
      // Nothing can start without the engine; confirm the world is stopped so
      // a status that never reaches a terminal state cannot stick.
      _emitDashboard('Stopped');
      return;
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
      return;
    }
    _starting = true;
    _epoch++;
    _emitDashboard('Starting');
    final beganAt = DateTime.now();
    final clock = Stopwatch()..start();
    var serviceMs = 0;
    var configMs = 0;
    try {
      // The native DB owns the selection (DataStore.selectedProxy). The Flutter
      // preference store holds UI settings only, so mining it for an id used to
      // send 0 here and fail every start with "profile 0 is gone". A reload that
      // already built its config passes it in [prebuilt] and skips the channel.
      final build = prebuilt == null
          ? host
              .call('config.build', configBuildArgs())
              .timeout(_hostOpTimeout)
              .whenComplete(() => configMs = clock.elapsedMilliseconds)
          : Future<dynamic>.value(prebuilt);
      // Android's half runs alongside the build above: in ffiMode the service owns the
      // VpnService the core asks for a tun, and nothing in the config depends on it.
      final serviceUp = bringUpService
          ? host.call('service.start')
              .timeout(_hostOpTimeout)
              .whenComplete(() => serviceMs = clock.elapsedMilliseconds)
          : null;
      // Both are already in flight. Await the service half first: when Android refuses
      // the VPN (no permission, always-on conflict) there is no reason to make the
      // user sit through a slow xray/config build before seeing the error. The build
      // is still awaited below on the success path, and observed here on failure so
      // its resources are released rather than completing unobserved.
      if (serviceUp != null) {
        try {
          await serviceUp;
        } catch (error) {
          unawaited(() async {
            try {
              await build;
            } catch (buildError) {
              note('config.build after a failed service start: $buildError');
            }
          }());
          rethrow;
        }
      }
      // The channel reply is a `Map<String, dynamic>` after BoxController.call
      // normalizes it. Use a checked conversion so a future codec change fails
      // with a readable message instead of a bare type-cast exception.
      final built = prebuilt ?? asStringKeyedMap(await build, context: 'config.build');
      final readyMs = clock.elapsedMilliseconds;
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
      _resetRateBaseline();
      // Split by phase: the total alone cannot say whether the next second should be spent on
      // Android's service, on the config build, or inside the core's own start.
      final phases = [
        if (bringUpService) 'service $serviceMs',
        'config $configMs',
        'instance ${instanceMs - readyMs}',
        'start ${startMs - instanceMs}',
      ].join(', ');
      note('core started in ${DateTime.now().difference(beganAt).inMilliseconds}ms ($phases)');
      _emitDashboard('Started');
      // What the service used to write right after proxy.init(). Running a chain is not only the
      // box's business: ProfileManager.runningUses refuses to delete a node a running config still
      // uses, and RouteManager.runningRouteId decides whether a group's routing change needs a
      // reload. Both read the store, so the facts are reported here once the start held — after
      // the screen has been told the tunnel is up, since it reads none of them, and the two guards
      // above are only consulted when the user edits a profile or a route.
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
    } catch (error) {
      note('core start FAILED: $error');
      report(error);
      // Release the instance that may have been partially started so the next
      // createInstance does not silently orphan it inside the worker.
      try { await worker.stop(); } catch (_) { /* Already stopped or never started. */ }
      _instanceHandle = null;
      // A failed start leaves nothing running, and a reload that kept the old facts
      // would otherwise describe a core that is not there.
      await _clearRunning();
      // In ffiMode BaseService announces `Connected` as soon as the service starts
      // (startProxy), before any core exists. A failed build must not leave the
      // notification, tile and VPN icon claiming a tunnel that is not there — and
      // with `active == false` the watchdog will not recover it. Stop the service
      // too, in the same order as stopService(). Best effort: a channel failure
      // here must not hide the original start error.
      try {
        await host.call('service.stop').timeout(_hostStopTimeout);
      } catch (stopError) {
        note('core start FAILED: could not stop the service: $stopError');
      }
      _emitDashboard('Stopped');
    } finally {
      _starting = false;
    }
  }

  Future<void> _stopCore({bool clearRunning = true}) async {
    // The transition flag first: the two host calls below can take seconds, and
    // a hello arriving in that window must report 'Stopping'. Clearing the
    // handle first left statusWire saying 'Stopped' while the core ran on.
    _stopping = true;
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
    if (clearRunning) {
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
      _stopping = false;
      _emitDashboard('Stopped');
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
      _stopping = false;
      // Every stop path ends in a terminal event. A host stop (tile /
      // notification / widget) reaches only this function — without the event
      // its 'Stopping' was the last word the UI ever heard, and the
      // driver-owned arbitration kept every later channel 'Stopped' masked.
      _emitDashboard('Stopped');
    }
  }

  // --- operations ---------------------------------------------------------

  /// Outbound mode (rule/global/direct): persist, then rebuild the routing config.
  @override
  Future<void> setMode(String mode) async {
    if (_kernel == null) return;
    await host.call('state.setMode', {'mode': mode});
    await reloadService(reason: 'outbound mode -> $mode');
    _emitDashboard(null, mode: mode);
  }

  /// Bumped by every profile/group selection; a queued rebuild that lost the
  /// race to a newer one stands down instead of rebuilding a mid-state world.
  int _selectionEpoch = 0;

  /// A profile/group selection already persisted by the channel; the core follows.
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
      await reloadService(reason: 'heartbeat lost, attempt ${attempt + 1}');
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
      _stopping ? 'Stopping' : (_starting ? 'Starting' : 'Started'),
      snapshot: snapshot,
    );
  }

  /// Emits the dashboard wire (the shape ThroneBoxBridge.dashboardWire produces),
  /// carrying the last known static fields and overriding the live numbers.
  void _emitDashboard(String? status, {Map<String, int>? snapshot, String? mode}) {
    if (_disposed) return;
    final previous = host.dashboard;
    final profiles = host.profiles;
    final selectedId = _selectedProfileId();
    String name = previous['selectedProfileName'] as String? ?? '';
    for (final row in profiles) {
      if (row['id'] == selectedId) {
        name = row['name'] as String? ?? name;
        break;
      }
    }
    final effectiveStatus = status ?? previous['status'] ?? 'Stopped';
    // Clear startedAt when stopped so the dashboard does not show a stale timer.
    final startedAt = effectiveStatus == 'Stopped' || effectiveStatus == 'Idle'
        ? 0
        : (_startedAt?.millisecondsSinceEpoch ?? (previous['startedAt'] as num?)?.toInt() ?? 0);
    _emitEvent({
      'type': 'dashboard',
      'value': {
        ...previous,
        'status': effectiveStatus,
        // The selected group id is channel-owned (BboxCatalog.selectedGroupId).
        // Re-emitting a copy of `previous` here could overwrite a fresh channel
        // dashboard that arrived while a long reload was in flight, leaving the
        // Proxies screen filtered to the previous configuration. `...previous`
        // already carries the authoritative value.
        'selectedProfileName': name,
        'modes': previous['modes'] ?? ['rule', 'global', 'direct'],
        'mode': mode ?? previous['mode'] ?? 'rule',
        'startedAt': startedAt,
        'uploadTotal': snapshot?['uplinkTotal'] ?? previous['uploadTotal'] ?? 0,
        'downloadTotal': snapshot?['downlinkTotal'] ?? previous['downloadTotal'] ?? 0,
        'connections': (snapshot?['connectionsIn'] ?? 0) + (snapshot?['connectionsOut'] ?? 0),
        'memory': snapshot?['memory'] ?? previous['memory'] ?? 0,
        'goroutines': snapshot?['goroutines'] ?? previous['goroutines'] ?? 0,
        // Forwarded for the speed card's diagnostic panel: whether the core
        // actually has a traffic manager counting (0 on a core that reports
        // none, e.g. an old libthrone.so — distinct from "no traffic").
        'trafficAvailable': snapshot?['trafficAvailable'] ?? (previous['trafficAvailable'] as num?)?.toInt() ?? 0,
      },
    });
  }

  /// Display-only: B-box's dashboard id is the selected *group* id, matching the
  /// ids in `box.profiles`. It is not a proxy entity id and must never be sent to
  /// `config.build` — the native side resolves that from DataStore.selectedProxy.
  int _selectedProfileId() => dashboardSelectedId(host.dashboard);

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

/// The dashboard's selected id is a *group* id (B-box's profile card), used only
/// for display and for looking the name up in `box.profiles`.
int dashboardSelectedId(Map<String, dynamic> dashboard) =>
    (dashboard['selectedProfileId'] as num?)?.toInt() ?? -1;
