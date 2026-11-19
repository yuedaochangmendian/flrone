// The in-process owner of the FFI view of the kernel.
//
// Before this, every kernel operation used Isolate.run: a fresh DynamicLibrary,
// a fresh ThroneFFI and a fresh object graph per call, stitched together only
// by the process-global handle table. Status polling did that once a second and
// leaked a StatusMessage handle each time.
//
// The FFI then moved into a dedicated worker isolate driven by command messages
// over ports. That isolation bought little once the service engine became the
// sole kernel owner: the engine already owns the process lifetime, the Go
// message port and the Android platform channel (Bettbox keeps its kernel in the
// service isolate too). The worker is now a plain local object living in that
// engine's main isolate — no second isolate, no port hops, no command enum.
// The FFI is opened exactly once here, the Instance wrapper is
// retained (so its finalizer cannot collect it out from under the caller) and
// temporary wrappers are released explicitly. The heartbeat calls one aggregate
// status snapshot; the Go side pushes the same snapshot to the UI message port.
// "Core lost" detections travel back on the events stream, as before.

import 'dart:async';
import 'dart:ffi';

import 'kernel_heartbeat.dart';
import 'platform_value.dart';
import 'throne_ffi.dart';

/// Events from the worker: `{'type': 'lost'}` or `{'type': 'error', ...}`.
typedef WorkerEvent = Map<String, dynamic>;

/// How long a fresh start may go without a status before a miss counts. The
/// box is still opening its tun and loading rule sets in that window.
const heartbeatGrace = Duration(seconds: 12);

/// How long the status must stay unreadable *after* a good beat to call the
/// core lost. A single slow read under load is not a lost core.
const heartbeatGiveUpAfter = Duration(seconds: 8);

/// The kernel driver's interface. The service engine talks to this, never to
/// the FFI wrappers directly, so tests can substitute a fake without loading
/// `libthrone.so`.
abstract class KernelWorker {
  /// Returns the worker that owns the FFI in the *calling* (service engine)
  /// isolate. The Future-returning shape is kept so call sites don't change.
  static Future<KernelWorker> spawn() async => _LocalKernelWorker();

  Stream<WorkerEvent> get events;

  /// Builds StartOptions, creates the Instance and releases the options handle.
  Future<int> createInstance(Map<String, dynamic> built);

  Future<void> start();

  /// Closes the Instance and releases its handle (the only release path).
  Future<void> stop();

  Future<void> setHeartbeat(bool enabled);

  /// Whether the running config asks for Wi-Fi state at all (a Wi-Fi-scoped route,
  /// DNS or rule set). Asked after the start, when there is an instance to ask.
  Future<bool> needWifiState();

  /// Tells the core to re-read the platform's SSID/BSSID (the Kotlin side reads it).
  Future<void> updateWifiState();

  /// Fetches the remote rule-sets that a deferred start left empty. Returns the
  /// core's count and error text; null when there is no instance.
  Future<Map<String, dynamic>?> updateRuleSets();

  Future<Map<String, dynamic>> warpRegister(
    String tunnelType,
    Map<String, dynamic> params,
  );

  Future<void> dispose();
}

/// Same-isolate implementation of [KernelWorker]. There is no second isolate:
/// the object is constructed and used inside the service engine, and the FFI
/// library is opened once here. Every method still returns a Future so the
/// driver code is unchanged from the port-driven version.
class _LocalKernelWorker implements KernelWorker {
  _LocalKernelWorker() {
    ffi = ThroneFFI(DynamicLibrary.open('libthrone.so'));
    ffi.throne_Mobile_setLogSink();
    // The core answers a status only once its box is up, and a start can take a
    // few seconds (tun, rule sets, xray assets) before that. Counting raw misses
    // turned a slow start into three "lost" beats, and the recovery then closed
    // the box it had just opened: the service restarted every few seconds and
    // never stayed up. A miss now only counts once the start has had its grace
    // period and the last good beat is older than [heartbeatGiveUpAfter].
    heartbeat = Timer.periodic(const Duration(seconds: 1), _onHeartbeat);
  }

  late final ThroneFFI ffi;
  final _events = StreamController<WorkerEvent>.broadcast();

  @override
  Stream<WorkerEvent> get events => _events.stream;

  ThroneInstance? _instance;
  final heartbeatPolicy = KernelHeartbeatPolicy();
  late final Timer heartbeat;
  bool _disposed = false;

  void _onHeartbeat(Timer _) {
    if (_disposed) return;
    final current = _instance;
    if (!heartbeatPolicy.enabled || current == null) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final snapshot = throneStatusSnapshot(ffi, current.handle);
      // The numbers were unreadable this second. That is not the same as a dead
      // core: reading the traffic counters races a busy box, and a panic there
      // used to end the snapshot and, with it, a tunnel that was carrying traffic
      // all along. Ask the cheap question — is the box still started — before
      // counting a miss, and only a box that really stopped counts as lost.
      final lost = heartbeatPolicy.observe(
        nowMs: now,
        snapshotReadable: snapshot != null,
        instanceAlive: ffi.throne_Instance_alive(current.handle) != 0,
        grace: heartbeatGrace,
        giveUpAfter: heartbeatGiveUpAfter,
      );
      if (lost) {
        _events.add(<String, dynamic>{
          'type': 'lost',
          'error': throneLastError(ffi),
        });
      }
    } catch (error) {
      // A failing FFI read is a warning, not a lost core: the next beat retries.
      // The event type keeps the worker's error channel alive for any listener;
      // the driver only reacts to 'lost'.
      _events.add(<String, dynamic>{'type': 'error', 'error': error.toString()});
    }
  }

  /// Closes and releases the current instance, if any. The only release path.
  void _releaseInstance() {
    final current = _instance;
    _instance = null;
    if (current == null) return;
    try {
      current.close();
    } finally {
      current.release();
    }
  }

  @override
  Future<int> createInstance(Map<String, dynamic> built) async {
    final config = asStringKeyedMap(built, context: 'createInstance payload');
    // Release any previous instance before creating a new one to prevent orphans.
    _releaseInstance();
    final options = _startOptions(ffi, config);
    try {
      final created = ThroneMobile.newInstance(ffi, options.handle);
      if (created == null) {
        throw StateError('the kernel refused to create an instance');
      }
      _instance = created;
      heartbeatPolicy.prepare();
      return created.handle;
    } finally {
      options.release();
    }
  }

  @override
  Future<void> start() async {
    final current = _instance;
    if (current == null) throw StateError('no kernel instance to start');
    current.start();
    // The clock for the heartbeat starts here, not at the process start:
    // the grace period exists for the box this call just opened.
    heartbeatPolicy.start(DateTime.now().millisecondsSinceEpoch);
  }

  @override
  Future<void> stop() async {
    heartbeatPolicy.stop();
    _releaseInstance();
  }

  @override
  Future<void> setHeartbeat(bool enabled) async {
    heartbeatPolicy.setEnabled(enabled, DateTime.now().millisecondsSinceEpoch);
  }

  @override
  Future<bool> needWifiState() async {
    final current = _instance;
    return current != null && current.needWIFIState();
  }

  @override
  Future<void> updateWifiState() async {
    _instance?.updateWIFIState();
  }

  @override
  Future<Map<String, dynamic>?> updateRuleSets() async {
    final result = _instance?.updateRuleSets();
    if (result == null) return null;
    try {
      return <String, dynamic>{
        'updated': result.getUpdated(),
        'error': result.getError(),
      };
    } finally {
      result.release();
    }
  }

  @override
  Future<Map<String, dynamic>> warpRegister(
    String tunnelType,
    Map<String, dynamic> params,
  ) async =>
      _warpRegister(ffi, tunnelType, params);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    heartbeatPolicy.stop();
    heartbeat.cancel();
    // Release any still-running instance so the native handle is not orphaned.
    _releaseInstance();
    await _events.close();
  }
}

/// Assembles StartOptions from the native `config.build` payload.
ThroneStartOptions _startOptions(ThroneFFI ffi, Map<String, dynamic> built) {
  final options = ThroneStartOptions.create(ffi);
  options.setCoreConfig(built['coreConfig'] as String? ?? '');
  options.setNeedXray(built['needXray'] as bool? ?? false);
  options.setXrayConfig(built['xrayConfig'] as String? ?? '');
  options.setXrayOutboundDNSStrategy(built['xrayDnsStrategy'] as String? ?? '');
  // A channel reply can carry a List<Object?> here; cast<String>() would build
  // a view that throws on the first non-string element while iterating.
  final rawFull = built['xrayFullConfigs'];
  final full = rawFull is List ? rawFull.whereType<String>().toList() : <String>[];
  for (final config in full) {
    options.addXrayFullConfig(config);
  }
  // BoxInstance.toStartOptions: the idle window must outlast the probe interval.
  final intervalSec = built['autoSelectorIntervalSec'] as int? ?? 0;
  if (intervalSec > 0 && (built['needXray'] == true || full.isNotEmpty)) {
    options.setXrayLazyStart(true);
    options.setXrayIdleSeconds(intervalSec * 2 > 120 ? intervalSec * 2 : 120);
    options.setXrayFullIdleSeconds(0);
  }
  return options;
}

Map<String, dynamic> _warpRegister(
  ThroneFFI ffi,
  String tunnelType,
  Map<String, dynamic> params,
) {
  final request = ThroneWarpRegisterRequest.create(ffi);
  ThroneWarpIdentity? identity;
  ThroneStringIterator? iterator;
  try {
    request.setTunnelType(tunnelType);
    request.setProxy((params['proxy'] as String?) ?? '');
    for (final host in (params['hosts'] as List? ?? const [])) {
      request.addAPIHost(host.toString());
    }
    identity = ThroneMobile.warpRegister(ffi, request.handle);
    if (identity == null) throw StateError('warp: the kernel returned no identity');
    final reserved = identity.getReserved();
    final identityMap = <String, dynamic>{
      'deviceId': identity.getDeviceID(),
      'token': identity.getToken(),
      'license': identity.getLicense(),
      'ipv4': identity.getIPv4(),
      'ipv6': identity.getIPv6(),
      'privateKey': identity.getPrivateKey(),
      'peerPublicKey': identity.getPeerPublicKey(),
      'endpoint': identity.getEndpoint(),
      'reserved': reserved.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList(),
    };
    String? packetsError;
    var packets = <String>[];
    if (params['mode'] == 'amnezia') {
      try {
        iterator = ThroneMobile.genQuicSignature(ffi, 'www.cloudflare.com');
        packets = iterator?.toList() ?? [];
        if (packets.isEmpty || packets.length > 5 || packets.any((p) => p.isEmpty)) {
          packetsError = 'the core returned an invalid QUIC signature';
        }
      } catch (error) {
        packetsError = error.toString();
      }
    }
    return <String, dynamic>{
      'identity': identityMap,
      'packets': packets,
      'packetsError': packetsError,
    };
  } finally {
    iterator?.release();
    identity?.release();
    request.release();
  }
}

extension on ThroneStringIterator {
  List<String> toList() {
    final out = <String>[];
    while (hasNext()) {
      out.add(next());
    }
    return out;
  }
}
