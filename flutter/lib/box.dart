import 'dart:async';
import 'dart:isolate';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'capabilities.dart';
import 'common/async_gate.dart';
import 'common/fixed_list.dart';
import 'common/ip_quality_cache.dart';
import 'common/log_level.dart';
import 'common/refresh_gate.dart';
import 'core/action.dart';
import 'core/kernel_control.dart';
import 'core/kernel_service.dart';
import 'core/kernel_worker.dart';
import 'core/log_batch.dart';
import 'core/platform_value.dart';
import 'core/throne_kernel.dart';
import 'data/rule_set_catalog.dart' show RuleSetCatalogSource, readRuleSetCatalogText;
import 'data/route_profiles_source.dart';
import 'data/profile_store_source.dart'
    show ProfileStoreSource, MapRoomProfileReader, decodeAppliedProfiles;
import 'data/profile_document_status.dart' show ProfileDocumentStatus;
import 'data/profile_store.dart' show profilesMigratedKey, SqliteRoomProfileReader;
import 'data/data_layer.dart' show DataLayer;
import 'services/ui_overlay.dart' show mergeSettings, splitSettings, uiOnlyKeys;
import 'services/webdav_account.dart' show WebDavAccountStore;
import 'services/webdav_client.dart' show WebDavChecker, defaultWebDavCheck;
// ADR 0005 phase 4: the WebDAV file protocol and the THRN codec are Dart-owned.
// Only the byte conversion (Room export / staged restore) still crosses the
// channel; the typed `webdavUpload`/`webdavRead` facades use these services.
import 'services/backup_webdav.dart'
    show
        WebDavBackupFactory,
        WebDavBackupTransport,
        WebDavUploadResult,
        defaultWebDavBackupFactory,
        partProfiles,
        partRoutes,
        partSettings;
import 'services/backup_store.dart' show thrnDecode;
import 'services/backup_profile_names.dart' show previewProfileNames;
import 'services/backup_write.dart'
    show BackupEnvironment, BackupEnvironmentFactory, createBackup, restoreBackup;
import 'services/room_snapshot_host.dart' show RoomSnapshotHost, tolerantBase64Decode;
import 'dart:convert' show base64Encode;

part 'box_api.dart';

typedef Json = Map<String, dynamic>;

/// StandardMessageCodec yields `_Map<Object?, Object?>` for native maps, and nested maps keep
/// that shape, so the two boundaries (`call` and the event stream) normalize the whole tree.
/// Everything downstream is already normalized, which is why [json] and [rows] only cast: doing
/// it again here copied the entire startup payload a second time.
Json json(Object? value) {
  if (value is Json) return value;
  // A map from somewhere that did not go through the boundary (a test, a raw channel reply):
  // normalize rather than drop it.
  if (value is Map) {
    final normalized = normalizePlatformValue(value);
    if (normalized is Json) return normalized;
  }
  return <String, dynamic>{};
}

/// Bulk feeds (`logs`, `logcat`, `connections`, `groups`) arrive as one codec payload instead
/// of a map per row — see `ThroneBoxBridge.emitBulk` / `BulkWire`.
///
/// Above this size the decode moves to a background isolate (FlClash's
/// `coreIsolateDecodeBytes`): it is work proportional to the payload, and the UI isolate is
/// where frames are built. The isolate runs in this engine's group, so a pause it provokes is
/// the same group GC any allocation here would risk — the win is that the CPU work is not on
/// the frame thread.
///
/// `groups` is on this list only while the Proxies screen is open (the host sends counts as a
/// plain map otherwise): node rows are ~134 B each, the largest payload the bridge carries, and
/// they are why no further spill exists — above this threshold they already leave the frame
/// thread, and no other UI payload is bigger.
const bulkDecodeBytes = 50 * 1024;

/// The bulk feeds [BoxController] decodes off the channel's map path.
const bulkEventTypes = {'logs', 'logcat', 'connections', 'groups'};

/// Decodes one bulk payload. Top level and primitive-in/out so `Isolate.run` can carry it.
Object? decodeBulkPayload(Uint8List bytes) =>
    const StandardMessageCodec().decodeMessage(ByteData.sublistView(bytes));

/// [decodeBulkPayload] on a background isolate.
///
/// The wrapper is top level on purpose: a closure written inside a method or a test body drags
/// its enclosing scope context along, and `Isolate.run` rejects the message when that context
/// holds anything unsendable (a controller, a Future) — the isolate-offload lesson from the
/// config-build work, now enforced by the shape of this call.
Future<Object?> decodeBulkPayloadIsolated(Uint8List bytes) =>
    Isolate.run(() => decodeBulkPayload(bytes));

/// The rows of a channel list, with the same one-copy rule as [json].
List<Json> rows(Object? value) {
  if (value is! List) return <Json>[];
  final out = <Json>[];
  for (final item in value) {
    if (item is Json) {
      out.add(item);
    } else if (item is Map) {
      final normalized = normalizePlatformValue(item);
      if (normalized is Json) out.add(normalized);
    }
  }
  return out;
}

enum BoxAspect { state, appearance, traffic, memory, connections, logs, logcat, testSession, ruleSetsStatus }
enum BoxData { memory, logs, logcat, testSession }

/// A single event flowing from the backend / core to the UI, mirroring Bettbox's
/// `ClashMessage` bus: one typed stream instead of several ad-hoc controllers. A listener
/// subscribes to the subset it cares about with `where((event) => event is X)`.
sealed class BoxEvent {
  const BoxEvent();
}

/// A banner / snackbar message: backend `error`/`openUrl`, the non-popup branch of a
/// subscription report, and UI-initiated notices.
class BoxMessageEvent extends BoxEvent {
  const BoxMessageEvent(this.text);
  final String text;
}

/// A subscription update's change window that should open the report dialog.
class SubscriptionReportEvent extends BoxEvent {
  const SubscriptionReportEvent(this.report);
  final Json report;
}

/// An external intent (share / import) is waiting to be drained.
class IntentAvailableEvent extends BoxEvent {
  const IntentAvailableEvent();
}

/// The embedded browser (OAuth and friends) completed a callback.
class BrowserCompleteEvent extends BoxEvent {
  const BrowserCompleteEvent(this.payload);
  final Json payload;
}

/// One attribution delta from the host's traffic poller (hosts / nodes / rules / apps).
class BoxTrafficDeltaEvent extends BoxEvent {
  const BoxTrafficDeltaEvent(this.payload);
  final Json payload;
}

/// Pluggable event bus, one-way from backend to UI.
class BoxEventBus {
  final _controller = StreamController<BoxEvent>.broadcast();
  Stream<BoxEvent> get stream => _controller.stream;
  bool _closed = false;
  void emit(BoxEvent event) {
    if (_closed) return;
    _controller.add(event);
  }
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}

/// The UI engine's controller. It doubles as the UI-side [KernelHost] so the
/// in-process `KernelService` can be driven directly in tests; in production
/// the kernel runs in the service engine and [kernel] is a [KernelProxy].
class BoxController extends ChangeNotifier implements KernelHost {
  BoxController({
    MethodChannel? channel,
    Stream<dynamic>? events,
    KernelControl? kernelControl,
    WebDavChecker? webDavChecker,
    WebDavBackupFactory? webDavBackupFactory,
    BackupEnvironmentFactory? backupEnvironmentFactory,
    Future<dynamic> Function(String scope)? backupCreator,
    Future<List<String>> Function(dynamic backup, String scope, String strategy)?
        backupRestorer,
    Future<ProfileDocumentStatus> Function()? profileDocumentStatusFn,
    Future<String> Function()? repairProfileDocumentFn,
    Future<Json> Function()? profileDocumentKotlinViewFn,
  })  : _channel = channel ?? const MethodChannel('io.flrone/box'),
        // EventChannel uses the same codec as MethodChannel, so its payloads
        // arrive as `_Map<Object?, Object?>` too.
        _events = (events ?? const EventChannel('io.flrone/events').receiveBroadcastStream())
            .map<dynamic>(normalizePlatformValue),
        // WebDAV connectivity is pure HTTP now (data-authority phase 1). Injectable
        // so widget tests exercise the page without opening a socket.
        webDavCheck = webDavChecker ?? defaultWebDavCheck,
        // ADR 0005 phase 4: the WebDAV backup transport is Dart-owned. Inject the
        // service factory so widget tests need no HTTP server or Room.
        webDavBackup = webDavBackupFactory ?? defaultWebDavBackupFactory,
        // ADR 0005 phase 4: the backup write path is Dart-owned. The environment
        // factory resolves the Room path and host facts; tests inject a synthetic
        // one so they need no device or native sqlite. Null means "resolve from
        // data.path on this controller" (see BackupApi.resolveEnvironment).
        backupEnvironment = backupEnvironmentFactory,
        backupCreateFn = backupCreator,
        backupRestoreFn = backupRestorer,
        // Diagnostics seams: tests inject a fake document status/repair without
        // touching the real filesystem or Room.
        profileDocumentStatusFn = profileDocumentStatusFn,
        repairProfileDocumentFn = repairProfileDocumentFn,
        profileDocumentKotlinViewFn = profileDocumentKotlinViewFn {
    // In-process by default: a widget test (and the service engine itself) gets
    // the local driver. Production passes a KernelProxy explicitly in main().
    kernel = kernelControl ?? KernelService(this);
  }

  final MethodChannel _channel;
  final Stream<dynamic> _events;
  /// Runs the WebDAV connectivity probe in pure Dart. See `services/webdav_client.dart`.
  final WebDavChecker webDavCheck;
  /// Builds the WebDAV backup service for the current account (ADR 0005 phase 4).
  final WebDavBackupFactory webDavBackup;
  /// Resolves the host facts the Dart backup writer needs (ADR 0005 phase 4).
  /// Null means resolve from `data.path` on this controller.
  final BackupEnvironmentFactory? backupEnvironment;
  /// Test seams for the two backup write operations; null uses the Dart
  /// implementation in `box_api.dart` (ADR 0005 phase 4).
  final Future<dynamic> Function(String scope)? backupCreateFn;
  final Future<List<String>> Function(dynamic backup, String scope, String strategy)?
      backupRestoreFn;
  /// Test seams for the configuration-document diagnostics; null uses the real
  /// document store (see [profileDocumentStatus] / [repairProfileDocument]).
  final Future<ProfileDocumentStatus> Function()? profileDocumentStatusFn;
  final Future<String> Function()? repairProfileDocumentFn;
  /// Test seam for [profileDocumentKotlinView]; null reads the host's own view.
  final Future<Json> Function()? profileDocumentKotlinViewFn;

  /// P14: the host-backed backup I/O (Android, where dart:ffi cannot load
  /// SQLite): the container SQL transport and the settings/markers document
  /// ops (ADR 0006 stage C2c2a removed the live-Room row pump). Created lazily
  /// from this controller's channel; a single stateless instance serves all
  /// backups. Tests inject their own into create/restore.
  RoomSnapshotHost? _roomSnapshotHost;
  RoomSnapshotHost get roomSnapshotHost => _roomSnapshotHost ??= RoomSnapshotHost(
        call: (method, [args]) => call(
          method,
          args is Map ? Map<String, dynamic>.from(args) : null,
        ),
      );

  /// Exposed so `box_api` can resolve the concrete type from the factory. The
  /// account read is asynchronous since S10: the password is a Keystore
  /// envelope and opening it crosses the `io.flrone/secure` channel.
  Future<WebDavBackupTransport?> newWebDavBackup() async =>
      webDavBackup(await webDavAccount.read(), appVersion: version);
  /// The WebDAV account is a value in the preferences document, owned by Dart
  /// (ADR 0005 phase 1). Reads consult [preferences]; writes go through the
  /// existing `preferences.set` channel, which the host mirrors to Room for the
  /// phase-4 container codec.
  late final WebDavAccountStore webDavAccount = WebDavAccountStore(
    readPreferences: () => preferences,
    writePreferences: (values) async {
      // Go through the raw channel, not setPreferences(): the account form shows
      // a save error when the write fails, so the exception must propagate (the
      // old webdav.set did). setPreferences swallows errors into report().
      preferences = json(await preferencesSet(values));
      _notify([BoxAspect.state, BoxAspect.appearance]);
    },
  );
  /// Unified event bus (Bettbox `ClashMessage`-style): the single one-way stream between
  /// backend and UI. Consumers subscribe to the slice they need with `where((event) => event is X)`.
  /// The derived streams are cached so repeated access yields the same broadcast stream, the
  /// way `StreamController.stream` did.
  final eventBus = BoxEventBus();
  Stream<T> _eventsOf<T extends BoxEvent>() => eventBus.stream.where((event) => event is T).cast<T>();
  late final Stream<String> messages = _eventsOf<BoxMessageEvent>().map((event) => event.text);
  late final Stream<Json> subscriptionReports = _eventsOf<SubscriptionReportEvent>().map((event) => event.report);
  late final Stream<Json> browserEvents = _eventsOf<BrowserCompleteEvent>().map((event) => event.payload);
  late final Stream<Json> trafficDeltas = _eventsOf<BoxTrafficDeltaEvent>().map((event) => event.payload);
  late final Stream<IntentAvailableEvent> intents = _eventsOf<IntentAvailableEvent>();
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _kernelEvents;
  int _kernelLogId = 0;
  int _nextLogSeq = 1;
  /// Kernel lines arrive one IPC message at a time. Appending to the public
  /// list per line copied the whole 512-row window for every line and handed
  /// the UI a new identity mid-start; this buffer lets one short timer merge a
  /// burst (and its notification) into one list replacement.
  static const kernelLogBatchWindow = logBatchWindow;
  final _pendingKernelLogs = <Json>[];
  Timer? _kernelLogTimer;
  /// In production a KernelProxy that talks to the service engine; tests and the
  /// service engine itself get an in-process KernelService.
  late KernelControl kernel;

  /// Test seam: replace the proxy with an in-process [KernelService] bound to
  /// this controller and attach the fake kernel/worker. The old tests used to
  /// call `box.kernel.debugAttach(k, w)`; this is the same seam at the
  /// controller level, since [kernel] is now the engine-agnostic control face.
  @visibleForTesting
  KernelService debugAttach(ThroneKernel attached, KernelWorker worker) {
    final service = KernelService(this);
    kernel = service;
    service.debugAttach(attached, worker);
    return service;
  }
  final _revisions = List<int>.filled(BoxAspect.values.length, 0);
  final _stateChanges = ChangeNotifier();
  final _dataOwners = <BoxData, Set<Object>>{};
  // More than one ProxiesPage can be alive at once (the dock tab and a nested
  // sheet opened from the dashboard). A plain bool lets the nested page's
  // dispose switch off the rows the still-mounted tab is reading.
  final _groupOwners = <Object>{};
  Listenable get stateChanges => _stateChanges;
  @override
  Json dashboard = {};
  // ADR 0005 phase 2: the host snapshot holds only the authoritative (Room/Throne)
  // rows and the host-derived keys. `settings` is recomputed on every read as
  // mergeSettings(host, preferences), so the UI-only overlay (Dart-owned) and the
  // service keys (Kotlin-owned) can never overwrite each other, and a fresh host
  // snapshot is never masked by a stale cached whole-map merge.
  Json _hostSettings = {};
  Json get settings => mergeSettings(_hostSettings, preferences);
  set settings(Json value) => _hostSettings = value;
  Json preferences = {}, rates = {};

  /// Dashboard fields the FFI driver owns while it runs the core. In that mode the service
  /// side has no box of its own: its meter has no TrafficUpdater and its status is the
  /// service's, so both report zeros. Letting those land on the dashboard flipped every
  /// figure between the two sources once a second.
  static const driverOwnedDashboard = {
    'status', 'startedAt', 'uploadTotal', 'downloadTotal', 'connections', 'memory', 'goroutines',
    'trafficAvailable',
  };

  /// [incoming] with the driver's own fields kept from [current] when [channelIsStale]:
  /// the service side has no box in FFI mode, so its copy of these is a row of zeros.
  /// Everything else — the mode, the selected profile, the system proxy — still comes from
  /// the channel, which is the side that persists it.
  static Json mergeDashboard(Json current, Json incoming, {required bool channelIsStale}) {
    if (!channelIsStale) return incoming;
    final merged = Map<String, dynamic>.of(incoming);
    for (final key in driverOwnedDashboard) {
      if (current.containsKey(key)) merged[key] = current[key];
    }
    return merged;
  }

  /// A driver dashboard event over the channel-owned map. The service engine's
  /// wire carries only its live fields — its host snapshot is empty
  /// (`ServiceBridgeClient.dashboard`), so `selectedProfileId`, `mode` and the
  /// rest are simply absent from the map. Wholesale replacement (the old
  /// `return incoming`) erased the channel-owned keys on every driver event:
  /// with both feeds at 1 Hz the card's route stamp changed on every other
  /// event, `_syncRoute` saw a route change for a second, and the egress probe
  /// re-ran forever — the IP flicker. Only the driver's own fields move here.
  static Json mergeDriverDashboard(Json current, Json incoming) {
    final merged = Map<String, dynamic>.of(current);
    for (final key in driverOwnedDashboard) {
      if (incoming.containsKey(key)) merged[key] = incoming[key];
    }
    return merged;
  }

  /// Test hook: pretend the FFI driver owns the core, so the arbitration between the two
  /// sources can be exercised without the library. Null asks the driver.
  @visibleForTesting
  bool? debugDriverActive;
  bool get _driverActive => debugDriverActive ?? kernel.active;

  BoxCapabilities capabilities = BoxCapabilities.empty;
  Json memory = {}, lan = {};
  @override
  List<Json> profiles = [];
  List<Json> groups = [];
  // The three high-frequency feeds. A burst arrives as batches, and each batch
  // used to replace the field with a freshly built list (slice of the old tail
  // plus the new rows); a FixedList appends into one buffer and hands the pages
  // a snapshot whose identity is stable until the next mutation. Only this
  // controller writes them; the getters keep the read surface pages already use.
  final _logs = FixedList<Json>(capacity: maxLogLength);
  final _logcat = FixedList<Json>(capacity: maxLogLength);
  // The host replaces the connections page whole (it bounds its closed ring at
  // 200), so there is nothing to append to; the FixedList still earns its keep
  // as the one read contract here, and its cap is only a ceiling against a
  // pathological live count — retaining the newest rows.
  final _connections = FixedList<Json>(capacity: maxConnectionRows);
  List<Json> get logs => _logs.list;
  List<Json> get logcat => _logcat.list;
  List<Json> get connections => _connections.list;
  Json testSession = {};
  /// Last rule-set update reported by the kernel worker. Wire shape
  /// `{updated: int, error: String, at: epochMs}`; empty until the first
  /// automatic update, which is the only one this build runs. Sent under
  /// [BoxAspect.ruleSetsStatus] so only the routing caption watches it.
  Json ruleSetsStatus = {};
  /// Live subscription queue state by group id (0 idle / 1 queued / 2 running), pushed by
  /// `subscriptionState` events. The profile page ORs this into its own spinner set so a
  /// refresh stays "updating" for the whole download, not just the enqueue round-trip.
  final Map<int, int> subscriptionStates = {};
  String? defaultLogLevel;

  /// The minimum level the host records for the Android logcat ring, or null for all levels.
  /// It travels with the subscription and the host filters at the source (`logcat … *:W`), so
  /// a raised level also stops the 1500-entry tail evicting useful lines under noise.
  String? logcatLevel;
  final uploadHistory = <double>[];
  final downloadHistory = <double>[];
  /// Bettbox keeps a 30 point window sampled once a second, so the chart spans half a minute.
  static const trafficWindow = 30;
  static const trafficSampleGap = Duration(milliseconds: 700);
  DateTime? _lastSample;

  // Speed-pipeline diagnostics for the card's long-press panel. The card can
  // only distinguish "no sample" (`--`) from a measured zero; these counters
  // say which stage of the kernel → IPC → controller path is silent.
  int driverEventCount = 0;
  int driverRateCount = 0;
  DateTime? lastDriverEventAt;
  DateTime? lastDriverRateAt;
  Json? lastDriverDashboard;

  /// The last event type this controller applied, for the loop-stall line
  /// ("last=dashboard"): a block outside the handler stopwatches still needs
  /// the event that preceded it.
  String lastEventType = '-';

  /// Whether the FFI driver owns the core for this UI (the channel's rates are
  /// discarded while it does).
  bool get driverActive => _driverActive;

  /// The values behind the speed card, for its long-press diagnostic.
  Json get speedDiagnostics => {
    'driverActive': driverActive,
    'kernelConnected': kernel.ffiMode,
    // Connected is not enough: a `connect()` that completes without installing
    // the event listener drops every driver event on the broadcast floor while
    // `active` still reports true (the exact bug this panel was built for).
    'eventsAttached': _kernelEvents != null,
    'events': driverEventCount,
    'lastEventAgo': lastDriverEventAt == null
        ? -1
        : DateTime.now().difference(lastDriverEventAt!).inSeconds,
    'rateEvents': driverRateCount,
    'lastRateAgo': lastDriverRateAt == null
        ? -1
        : DateTime.now().difference(lastDriverRateAt!).inSeconds,
    'rates': rates,
    'uploadTotal': lastDriverDashboard?['uploadTotal'],
    'downloadTotal': lastDriverDashboard?['downloadTotal'],
    'memory': lastDriverDashboard?['memory'],
    'goroutines': lastDriverDashboard?['goroutines'],
    // The three fields that separate "box not running" from "no connections"
    // from "traffic manager not counting" — the diagnosis the rates alone
    // cannot make.
    'status': lastDriverDashboard?['status'],
    'connections': lastDriverDashboard?['connections'],
    'trafficAvailable': lastDriverDashboard?['trafficAvailable'],
    // The one readiness answer (idle/starting/running/stopping/lost/recovering):
    // the panel used to infer it from the three booleans this map already had.
    'kernelPhase': kernel.kernelPhase.name,
  };

  /// Appends the current rates to the two sparkline windows, dropping the oldest point.
  void _sampleTraffic() {
    uploadHistory.add((rates['upload'] as num? ?? 0).toDouble());
    downloadHistory.add((rates['download'] as num? ?? 0).toDouble());
    if (uploadHistory.length > trafficWindow) uploadHistory.removeAt(0);
    if (downloadHistory.length > trafficWindow) downloadHistory.removeAt(0);
  }
  String version = '', coreVersion = '';
  /// The upstream commit the core was built from (`BuildConfig.THRONE_CORE_REF`).
  String coreRef = '';
  /// The ref shortened for a subtitle; empty when the host did not send one.
  String get coreRefShort => coreRef.length > 7 ? coreRef.substring(0, 7) : coreRef;
  int systemAccentColor = 0xff007aff;
  int sampleRevision = 0;
  bool _disposed = false;
  bool ready = false;
  bool lanChanging = false;
  bool serviceSettingsChanging = false;
  String? startupError;
  final pendingIntents = <String>[];
  String? applyRequired;
  /// Launcher icons by package name, as raw PNG bytes.
  ///
  /// These are outside `imageCache`'s budget (that one counts decoded frames), so without a
  /// ceiling every package the access-control screen ever showed stayed resident for the life of
  /// the process — hundreds of icon-sized buffers on a long-lived install. Cleared on a memory
  /// trim below, and bounded here so it cannot outgrow the icon budget in the first place; a
  /// cleared entry is simply re-fetched the next time a row needs it.
  static const maxCachedAppIcons = 96;
  final appIcons = <String, Future<Uint8List?>>{};
  /// Connection process paths -> {package,label,icon}, one row avatar per distinct path.
  /// Bounded oldest-first like `appIcons`; a path identifies one install (its directory
  /// changes on update), so the lookup is repeated only when a genuinely new path appears.
  static const maxCachedProcesses = 128;
  final processInfo = <String, Future<Json>>{};

  /// FlClash's `maxConcurrentProcessLookups`: the connections page asks for one
  /// `apps.process` round trip per visible row from `build`, so a fast scroll
  /// used to put every distinct path on the channel at once. The gate holds the
  /// platform thread's queue at eight; a cached path never reaches it.
  static const maxConcurrentProcessLookups = 8;
  final _processGate = AsyncGate(limit: maxConcurrentProcessLookups);
  final _profileStats = <int, Future<Json>>{};

  /// The route profile list's single entry point. Room's file is the only
  /// source; ADR 0005 phase 3 removed the `routes.list` channel fallback, so a
  /// missing/invalid file raises [RouteProfilesUnavailable] instead of showing
  /// a stale snapshot. The kernel's action bus (`routeList`) is the authoritative
  /// read for the routing UI; this SQLite path is the data-plane slice.
  /// A transiently failed attach gets a fresh retry budget on resume; the
  /// connection is closed with the controller, not with a page.
  RouteProfilesSource? _routeProfiles;
  RouteProfilesSource get routeProfiles => _routeProfiles ??= RouteProfilesSource(
        resolvePath: () => dataPath(),
      );

  /// ADR 0005 final stage: the Dart-owned profiles/groups document. Kotlin reads
  /// the same file directly (DartProfileStore.kt) to build the core config; this
  /// source owns the one-time Room -> JSON migration and is the write authority
  /// behind `profiles.applyDocument`. The migration runs once at startup after
  /// `data.path` is available; reads before then fall back to the catalog the
  /// host already pushed on `ready`.
  late final ProfileStoreSource profileStore = ProfileStoreSource(
    resolvePath: () => dataPath(),
    markerRead: () async => preferences[profilesMigratedKey] == true,
    markerWrite: () => setPreference(profilesMigratedKey, true).then((_) {}),
    openRoom: () async {
      final layer = await DataLayer.attach(resolvePath: () => dataPath(), readOnly: true);
      if (layer == null) return null;
      _migrationRoomLayer = layer;
      return SqliteRoomProfileReader(layer.queryable);
    },
    // Android cannot dlopen the platform SQLite (libsqlite3.so is absent from
    // AOSP images and libsqlite.so is not in public.libraries.txt), so
    // `openRoom` answers null on a stock device. `data.legacyRows` is the
    // host's raw, read-only read of the retired database (ADR 0006 stage
    // C2c2a — no Room): the same column shape, only while `profiles.json` is
    // absent, and all-empty lists on a fresh install.
    readRoomRows: () async {
      final reply = json(await call('data.legacyRows'));
      final profiles = reply['profiles'];
      final groups = reply['groups'];
      if (profiles is! List || groups is! List) return null;
      return MapRoomProfileReader(
        [for (final row in profiles) Map<String, Object?>.from(json(row))],
        [for (final row in groups) Map<String, Object?>.from(json(row))],
      );
    },
  );
  DataLayer? _migrationRoomLayer;

  /// The rule-set catalog reader (`routes.ruleSets`'s replacement, ADR 0005
  /// phase 3). It parses `<filesDir>/routeprofiles/srslist.h` via the `data.path`
  /// fact; no FFI driver, no channel handler, no second writer.
  late final RuleSetCatalogSource ruleSets = RuleSetCatalogSource(
    readText: () => readRuleSetCatalogText(() => dataPath()),
  );

  late final ipQualities = IpQualityCache(
    read: (ip) => call('dashboard.qualityCache.get', {'ip': ip}),
    write: (ip, record) async { await call('dashboard.qualityCache.put', {'ip': ip, 'value': record}); },
    onCacheError: (error) => debugPrint('IP quality cache: ${describe(error)}'),
  );

  /// Bettbox's `maxLogLength`: the log tail keeps a fixed window, so a long-running
  /// service cannot grow the list without bound however long the screen stays open.
  static const maxLogLength = logRingLimit;

  /// The connections feed's ceiling. The page is a live session's rows plus the
  /// host's closed ring (200), so this never trims in practice; it only stops a
  /// pathological connection count from growing the list without bound.
  static const maxConnectionRows = 1000;

  /// The high-frequency list events whose notifications are worth merging: a burst of
  /// these arriving inside one [batchWindow] rebuilds the UI once instead of once each.
  static const _batchedTypes = {'logs', 'logcat', 'connections'};
  static const batchWindow = Duration(milliseconds: 300);
  final _pendingAspects = <BoxAspect>{};
  Timer? _batchTimer;

  /// Coalesces repeated bridge round-trips (visibility toggles, refreshes) and
  /// gates high-frequency rebuilds while the app is backgrounded. Both are the
  /// pure-Dart parts of Bettbox's refresh/performance work; neither changes the
  /// data the Kotlin side pushes, only when the UI reacts to it.
  final RefreshGate refreshGate = RefreshGate();
  static const _deferrableAspects = <BoxAspect>{
    BoxAspect.traffic, BoxAspect.connections, BoxAspect.logs,
    BoxAspect.logcat, BoxAspect.memory, BoxAspect.testSession,
  };
  final _deferredAspects = <BoxAspect>{};

  /// Replays aspects that arrived while the app was hidden. Called on resume so
  /// the first frame back shows current data instead of a stale dashboard.
  void resumeRefreshes() {
    refreshGate.setForeground(true);
    // A cold start can race the host's first `data.path` answer; if the
    // SQLite attach failed transiently, coming back to the app is the natural
    // moment to try again. A healthy connection is not touched.
    _routeProfiles?.retryFailed();
    if (_deferredAspects.isEmpty) return;
    final aspects = _deferredAspects.toList();
    _deferredAspects.clear();
    _notify(aspects);
  }

  /// Stops tick-driven rebuilds while hidden. Data still lands in the fields.
  void suspendRefreshes() => refreshGate.setForeground(false);

  /// Tells the host whether the UI can be seen.
  ///
  /// FlClash polls its dashboard only while the window is visible. Here the
  /// bridge's 1 s ticker keeps looping either way, but while hidden it skips the
  /// rates/dashboard snapshot: there is no frame to draw it in, and the first
  /// tick after resume pushes a fresh sample. Fire-and-forget on purpose — a
  /// lifecycle callback must not wait on a channel round trip, and the host
  /// defaults to visible, so a lost call costs one ignored sample at most.
  void setUiVisible(bool visible) {
    unawaited(call('ui.visible', {'visible': visible}).catchError((Object _) {}));
  }

  /// Routes an event's aspects through the visibility gate.
  void _dispatch(Iterable<BoxAspect> aspects, bool batched) {
    if (!refreshGate.shouldRebuild && aspects.every(_deferrableAspects.contains)) {
      _deferredAspects.addAll(aspects);
      return;
    }
    if (batched) {
      _notifyBatched(aspects);
    } else {
      _notify(aspects);
    }
  }

  void _notify(Iterable<BoxAspect> aspects) {
    if (_disposed) return;
    for (final aspect in aspects) { _revisions[aspect.index]++; }
    if (aspects.contains(BoxAspect.state)) _stateChanges.notifyListeners();
    super.notifyListeners();
  }

  /// Applies the state now so reads are never stale, but holds the rebuild until the
  /// window closes — the Bettbox pending-buffer pattern, taken at the notify step.
  void _notifyBatched(Iterable<BoxAspect> aspects) {
    if (_disposed) return;
    _pendingAspects.addAll(aspects);
    _batchTimer ??= Timer(batchWindow, _flushBatch);
  }

  void _flushBatch() {
    _batchTimer = null;
    if (_disposed || _pendingAspects.isEmpty) return;
    final aspects = _pendingAspects.toList();
    _pendingAspects.clear();
    _notify(aspects);
  }

  // Preserve explicit notifications for callers that mutate several fields.
  @override void notifyListeners() => _notify(BoxAspect.values);

  void setDataVisible(BoxData data, Object owner, bool visible) {
    if (_disposed) return;
    final owners = _dataOwners.putIfAbsent(data, () => <Object>{});
    final wasVisible = owners.isNotEmpty;
    if (visible) { owners.add(owner); } else { owners.remove(owner); }
    if (ready && wasVisible != owners.isNotEmpty) _syncData(data);
  }

  /// Ref-counted counterpart for the group rows, so closing one of several
  /// live Proxies pages cannot turn off the visibility the others rely on.
  void setGroupsVisible(Object owner, bool visible) {
    if (_disposed) return;
    final wasVisible = _groupOwners.isNotEmpty;
    if (visible) { _groupOwners.add(owner); } else { _groupOwners.remove(owner); }
    if (ready && wasVisible != _groupOwners.isNotEmpty) {
      unawaited(act('groups.visible', {'visible': _groupOwners.isNotEmpty}));
    }
  }

  void _syncData(BoxData data) {
    // Must stay synchronous: BoxDataSubscription's demand contract expects one
    // bridge call per visibility change, and its tests assert the exact order.
    // The debouncer is for user-driven bursts (see BoxController.debouncer),
    // not for this negotiated subscription state.
    unawaited(act(switch (data) {
      BoxData.memory => 'dashboard.memory.visible',
      BoxData.logcat => 'logs.logcat.visible',
      BoxData.testSession => 'groups.testSession.visible',
      _ => 'logs.visible',
    }, {
      'visible': _dataOwners[data]?.isNotEmpty == true,
      // The level the ring records at is part of the subscription: the host passes it to
      // logcat as a filter spec, so opening the screen has to carry it too.
      if (data == BoxData.logcat) 'level': logcatLevel,
    }));
    // The kernel's tail is a separate producer (the service engine's worker isolate); tell
    // it whether anybody is looking, so an unopened log screen costs the UI isolate nothing.
    if (data == BoxData.logs) {
      unawaited(kernel.setKernelLogsVisible(_dataOwners[data]?.isNotEmpty == true).catchError((Object _) {}));
    }
  }

  /// Raises (or clears) the level the host records for logcat and restarts its tail when a
  /// screen is watching one. The host filters at the source, so a new level means a new read.
  Future<void> setLogcatLevel(String? level) async {
    logcatLevel = level;
    await setPreference('logcatLevel', level ?? '');
    if (ready && _dataOwners[BoxData.logcat]?.isNotEmpty == true) {
      await act('logs.logcat.visible', {'visible': true, 'level': level});
    }
  }

  /// One profile-stats read through the profile duty boundary (the counts are
  /// derived from the Dart-owned document and the current route's rules).
  Future<Json> _readProfileStats(int id) async =>
      json(await profilePlatform('stats', {'id': id}));

  Future<Json> profileStats(int id) {
    final cached = _profileStats[id];
    if (cached != null) return cached;
    // Single flight, and a failure is evicted rather than cached: only a 'profiles' event
    // clears this map, so a stored failed future would answer every later read of the card
    // with the same error and it would show '—' until the next profile refresh.
    final completer = Completer<Json>();
    final future = completer.future;
    _profileStats[id] = future;
    unawaited(_readProfileStats(id).then(completer.complete, onError: (Object error, StackTrace stack) {
      if (identical(_profileStats[id], future)) _profileStats.remove(id);
      completer.completeError(error, stack);
    }));
    return future;
  }

  Future<Uint8List?> appIcon(String package) {
    // Oldest-first eviction: insertion order is the closest thing this map has to an LRU, and
    // the screen scrolls forward, so the entries dropped are the ones least likely to be asked
    // for again. A re-fetch is one channel round trip and the icon decodes from bytes anyway.
    if (appIcons.length >= maxCachedAppIcons && !appIcons.containsKey(package)) {
      appIcons.remove(appIcons.keys.first);
    }
    return appIcons.putIfAbsent(package, () async {
      try { return await call('apps.icon', {'package': package}) as Uint8List?; }
      catch (_) { return null; }
    });
  }

  Future<Json> processInfoFor(String path) {
    if (processInfo.length >= maxCachedProcesses && !processInfo.containsKey(path)) {
      processInfo.remove(processInfo.keys.first);
    }
    return processInfo.putIfAbsent(path, () async {
      try { return json(await _processGate.run(() => call('apps.process', {'path': path}))); }
      catch (_) { return <String, dynamic>{}; }
    });
  }

  bool get remote => dashboard['remote'] != null;
  bool get running => remote
      ? dashboard['remoteConnected'] == true
      : dashboard['status'] == 'Started';
  bool get transitioning => ['Starting', 'Stopping'].contains(dashboard['status']);
  int get selectedProfileId => (dashboard['selectedProfileId'] as num?)?.toInt() ?? -1;

  /// The host's route version: moves whenever anything that decides where traffic exits
  /// changed (selection, mode, route profile, reload, service state). A probe records the
  /// version it started under and discards an answer stamped with a different one; null on a
  /// wire from a host that predates the stamp, where the caller falls back to no gate.
  int? get routeVersion => (dashboard['routeVersion'] as num?)?.toInt();
  Json? get selectedProfile {
    for (final profile in profiles) {
      if (profile['id'] == selectedProfileId) return profile;
    }
    return null;
  }

  /// The preference holding the profile last picked on the profiles screen.
  /// Written there, restored by [_restoreSelectionOnce] when a session starts
  /// with nothing selected (a restore, a picked node-container left behind by
  /// the node page, or a host whose setting was cleared).
  static const lastProfileKey = 'lastProfileId';

  bool _dashboardSeen = false;
  bool _selectionRestored = false;
  int _selectionRestoreAttempts = 0;

  /// Restores the remembered profile choice once per session. Runs from the
  /// profiles and dashboard events, which can arrive in either order: it waits
  /// for a dashboard that actually carries `selectedProfileId`, then acts when
  /// the host reports no selection (a restore, a cleared setting) or only the
  /// single-node container — a mode the node page left as the current
  /// configuration, not a profile the user picked. The remembered id must
  /// still exist in the catalog.
  void _restoreSelectionOnce() {
    // A remote profile owns the selection while it runs; the local memory must
    // not switch (and reload) the local configuration underneath it.
    if (_selectionRestored || !_dashboardSeen || remote) return;
    // The Profiles screen reopened in its node mode: the single-node container
    // is the mode the user left, not a leftover to correct. Leaving node mode
    // restores the remembered profile there.
    if ((preferences['profilesMode'] as num?)?.toInt() == 1) {
      _selectionRestored = true;
      return;
    }
    final saved = (preferences[lastProfileKey] as num?)?.toInt() ?? 0;
    if (saved <= 0) {
      _selectionRestored = true;
      return;
    }
    // The catalog has not arrived yet: profiles is empty, not "the id is gone".
    if (profiles.isEmpty) return;
    if (profiles.every((profile) => (profile['id'] as num?)?.toInt() != saved)) {
      _selectionRestored = true;
      return;
    }
    _selectionRestored = true;
    final current = selectedProfileId;
    if (current > 0 && !_isSingleNodeContainer(current)) return;
    unawaited(() async {
      final ok = await _selectProfileQuietly(saved);
      // A transient failure (channel busy, engine restarting) leaves the door
      // open for a later event; a hard refusal is not retried forever.
      if (!ok && _selectionRestoreAttempts < 3) {
        _selectionRestoreAttempts++;
        _selectionRestored = false;
      }
    }());
  }

  bool _isSingleNodeContainer(int id) => profiles.any(
    (profile) => (profile['id'] as num?)?.toInt() == id && profile['single'] == true,
  );

  Future<bool> _selectProfileQuietly(int id) async {
    try {
      await call('profiles.platform', {
        'op': 'select',
        'payload': <String, dynamic>{'id': id},
      });
      if (kernel.ffiMode) await kernel.onSelectionChanged();
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  List<String> get lanAddresses => (lan['addresses'] as List? ?? []).whereType<String>().toList();
  bool get canSetLanProxy => !remote && !transitioning && !lanChanging &&
      lan['canToggle'] == true && lan['profileId'] == selectedProfileId;
  List<String> get lanProxyEndpoints => remote || !running || lan['running'] != true ? [] :
      rows(lan['activeBindings']).expand((binding) =>
          (binding['endpoints'] as List? ?? []).whereType<String>()).toSet().toList();

  String? get lanCopyText {
    final addresses = lanAddresses, endpoints = lanProxyEndpoints;
    for (final address in addresses) {
      for (final endpoint in endpoints) {
        if (endpoint.startsWith('$address:') || endpoint.startsWith('[$address]:')) return endpoint;
      }
    }
    return endpoints.isNotEmpty ? endpoints.first : addresses.isNotEmpty ? addresses.first : null;
  }

  Future<void> refreshLan() async {
    try {
      final value = await call('dashboard.lan.refresh');
      if (!_disposed && value is Map) { lan = json(value); _notify([BoxAspect.state]); }
    } catch (error) { report(error); }
  }

  Future<bool> setLanProxy(bool enabled, {int? port, int? profileId, String? revision}) async {
    if (!canSetLanProxy) return false;
    final target = profileId ?? selectedProfileId;
    if (target != selectedProfileId) {
      report(StateError('Selected profile changed; reload it before saving'));
      return false;
    }
    lanChanging = true;
    _notify([BoxAspect.state]);
    try {
      final value = json(await call('dashboard.lan.set', {
        'profileId': target, 'revision': revision ?? lan['revision'], 'enabled': enabled,
        'port': ?port,
      }));
      if (!_disposed && !remote && selectedProfileId == target) lan = value;
      return true;
    } catch (error) {
      report(error);
      if (!_disposed) await refreshLan();
      return false;
    } finally {
      lanChanging = false;
      if (!_disposed) _notify([BoxAspect.state]);
    }
  }

  Future<void> initialize() async {
    startupError = null;
    notifyListeners();
    await _subscription?.cancel();
    _subscription = _events.listen(_onEvent, onError: report);
    // ADR 0005 final stage: Kotlin's parse-only handlers push their result here
    // so Dart (the storage authority) owns the document. Registered before the
    // host can call it; the controller is created before the bridge attaches.
    const MethodChannel('io.flrone/profiles_doc')
        .setMethodCallHandler(_onProfilesDocCall);
    // The kernel now lives in the service Flutter engine. The UI engine only
    // resolves its port and subscribes to the forwarded event stream; it never
    // opens libthrone.so or the native logs port itself.
    //
    // The listener goes in BEFORE the connect. The connect can fail at boot
    // (the service engine is still spinning up) and a later path — the start
    // call's own connect, say — can succeed without passing through here; a
    // connected proxy with no listener then drops every driver event on its
    // broadcast controller while `active` still reports true (the status
    // tracker sees the events). Attaching first makes any connect path safe.
    await _kernelEvents?.cancel();
    _kernelEvents = null;
    _attachKernelEvents();
    try {
      await kernel.connect();
    } catch (error) {
      // The kernel service engine is optional (unit tests, an engine that has
      // not started yet, or a platform that did not spawn it). Everything but
      // the kernel runs on the channel, so this is not a startup error — only
      // a kernel call would report the unavailable service.
      notifyListeners();
    }
    // The action bus (route documents and the rest) attaches before the tunnel
    // starts; a launch that beat the host's engine prewarm gets one background
    // retry so the routing screen normally opens onto a ready bus. Unawaited:
    // nothing here may delay `ready`, and nothing here starts the box.
    if (kernel.remote) unawaited(_warmKernelAttach());
    try {
      final result = json(await call('ready'));
      version = result['version'] as String? ?? '';
      coreVersion = result['coreVersion'] as String? ?? '';
      coreRef = result['coreRef'] as String? ?? '';
      systemAccentColor = (result['systemAccentColor'] as num?)?.toInt() ?? 0xff007aff;
      dashboard = json(result['dashboard']);
      profiles = rows(result['profiles']);
      // `ready` already carries the catalog's group rows and the host baselines
      // them so the pump stays silent; seed them here or the Proxies screen
      // renders its empty state until a visibility toggle or catalog bump.
      if (result['groups'] is List) groups = rows(result['groups']);
      // Order matters: the host snapshot is authoritative for its own keys; the
      // Dart preferences overlay is layered on top by the `settings` getter.
      _hostSettings = json(result['settings']);
      capabilities = BoxCapabilities.parse(result['capabilities']);
      preferences = json(result['preferences']);
      // The log screen keeps the level the host records logcat at here; the kernel side of
      // the same choice is the `logLevel` setting, and the screen syncs this ring to it.
      final storedLogcatLevel = preferences['logcatLevel'];
      logcatLevel = storedLogcatLevel is String && storedLogcatLevel.isNotEmpty ? storedLogcatLevel : null;
      if (result['lan'] is Map) lan = json(result['lan']);
      final intent = result['intent'] as String?;
      if (intent != null) pendingIntents.add(intent);
      // A low-RAM device gets a smaller decoded-image budget than the desktop-sized default.
      imageCache.maximumSizeBytes = (result['lowRam'] == true ? 24 : 50) << 20;
      // An AppRestart-level write or reset from before this attach; a reload does not clear it.
      applyRequired = result['applyRequired'] as String?;
      ready = true;
      // ADR 0002 phase 3c: hand the route documents to the kernel once. The host no-ops
      // when they already exist, so this is safe on every attach; it runs before the first
      // route read because that read now goes to Go, which needs a document to answer from.
      try {
        await dataSeedDocuments();
      } catch (error) {
        // A failed seed is not fatal: the kernel answers an empty set and the routing
        // screen shows the Default profile it creates.
        report(error);
      }
      // ADR 0005 final stage: hand Room's profiles/groups over to the Dart
      // document once. Idempotent; a failure here is not fatal — the host keeps
      // its Room fallback until the document exists, and the next launch retries.
      try {
        final migrated = await profileStore.migrate();
        if (migrated.migrated) {
          debugPrint('profiles document seeded from Room: '
              '${migrated.profileCount} profiles, ${migrated.groupCount} groups');
          unawaited(call('data.refresh'));
        }
      } catch (error) {
        report(error);
      }
      for (final data in _dataOwners.keys) { _syncData(data); }
      // A Proxies page can mount before `ready` completes; its first
      // setGroupsVisible saw ready=false and sent nothing. Re-assert the
      // negotiated state now that the bridge is attached.
      if (_groupOwners.isNotEmpty) {
        unawaited(act('groups.visible', {'visible': true}));
      }
    } catch (error) {
      startupError = describe(error);
    }
    notifyListeners();
  }

  /// Subscribes this UI engine to the kernel events the service engine forwards.
  /// Split out so a late reconnect installs the same listener [initialize]
  /// would. Idempotent: two installs would double-count every event.
  void _attachKernelEvents() {
    if (_kernelEvents != null) return;
    _kernelEvents = kernel.events.listen((event) {
      // Log lines are a service-engine concern; the UI only renders them.
      if (event['type'] == 'kernelLog') {
        _onKernelLog(json(event['value']));
        return;
      }
      if (event['type'] == 'kernelLogs') {
        final value = event['value'];
        if (value is Map) {
          final payload = value['payload'];
          if (payload is String) _onKernelLogsPayload(payload, reset: value['reset'] == true);
          return;
        }
        // The list shape is what older peers sent (and what the handshake tests feed).
        if (value is List) {
          for (final line in value) {
            _onKernelLog(json(line));
          }
        }
        return;
      }
      _onEvent(event, fromDriver: true);
    }, onError: report);
  }

  /// Connects the kernel proxy and guarantees the event listener is installed,
  /// whichever path needed the connection. `serviceStart` used to call
  /// `kernel.connect()` on its own: the connect succeeded as soon as the
  /// service engine was up, but nothing subscribed `kernel.events`, so every
  /// driver event was dropped by the broadcast controller — the speed card
  /// counted zero while the proxy reported an active, started core.
  Future<void> attachKernel({Duration timeout = Duration.zero}) async {
    _attachKernelEvents();
    await kernel.connect(timeout: timeout);
  }

  /// How long an on-demand attach waits for the service engine's port.
  ///
  /// The host prewarms the engine a few seconds after `Application.onCreate`, so
  /// a routing screen opened before that waits the window out instead of
  /// reporting the engine unavailable. Attaching does not start the tunnel:
  /// `KernelProxy.connect` only resolves the port and says hello, and the
  /// prewarmed engine opened the FFI driver on its own.
  static const kernelAttachTimeout = Duration(seconds: 10);

  /// The wait before the startup attach's one retry, behind the prewarm window
  /// (`SagerNet.kt` prewarms 3 s after `Application.onCreate`). A mutable seam
  /// only so a test need not sleep through it.
  @visibleForTesting
  static Duration kernelAttachRetryDelay = const Duration(seconds: 3);

  /// The one startup warm-up chain, so a second `initialize()` cannot stack one.
  Future<void>? _warmAttach;

  /// Attaches the cross-engine action bus in the background, once.
  ///
  /// The route store and the rest of the action-bus surface are usable before
  /// the tunnel starts; they only need the service engine, which the host
  /// prewarms. `initialize` already made the non-blocking first attempt, so this
  /// is the one retry for a launch that beat the prewarm — strictly unawaited,
  /// because the first frame must not wait for an engine, and a failure is not a
  /// startup error (a route call attaches on demand, the start path reconnects).
  /// Never starts the box.
  Future<void> _warmKernelAttach() {
    final pending = _warmAttach;
    if (pending != null) return pending;
    final future = _runKernelWarmup();
    _warmAttach = future;
    return future.whenComplete(() {
      if (identical(_warmAttach, future)) _warmAttach = null;
    });
  }

  Future<void> _runKernelWarmup() async {
    try {
      if (kernel.attached != null || _disposed) return;
      await Future<void>.delayed(kernelAttachRetryDelay);
      if (kernel.attached != null || _disposed) return;
      await attachKernel(timeout: kernelAttachTimeout);
    } catch (_) {
      // Still no engine (or the launch is going away): a route call attaches on
      // demand later, so there is nothing to report at launch.
    }
  }

  /// The dashboard says the tunnel is up but the proxy is not delivering yet:
  /// not connected, or connected by a path that never installed the listener.
  /// Cheap to retry and idempotent: a failed lookup means the engine is still
  /// booting, and the next dashboard change tries again.
  Future<void> _reconnectKernel() async {
    if (_kernelEvents != null && kernel.ffiMode) return;
    try {
      await attachKernel();
    } catch (_) {
      // The next dashboard event retries.
    }
  }

  /// Every method-channel reply is normalized here. Without this, callers that
  /// cast a reply to `Json` fail with
  /// `type '_Map<Object?, Object?>' is not a subtype of type 'Map<String, dynamic>'`.
  @override
  Future<dynamic> call(String method, [Json? args]) async =>
      normalizePlatformValue(await _channel.invokeMethod<dynamic>(method, args));

  /// Kotlin -> Dart write entrypoint (ADR 0005 final stage). Kotlin's profile
  /// platform duties (`profiles.platform` -> BboxProfileDuty) parse and validate
  /// the Throne model, then hand the resulting Room-keyed rows here; Dart, the
  /// storage authority, merges them into the document. The reply carries the
  /// small ack (ids/counters) so Kotlin can fix up its in-memory entities.
  Future<dynamic> _onProfilesDocCall(MethodCall profileCall) async {
    final args = normalizePlatformValue(profileCall.arguments);
    switch (profileCall.method) {
      case 'applyDocument':
        final doc = decodeAppliedProfiles(args);
        if (doc == null) throw ArgumentError('missing document');
        final allocated = await profileStore.apply(doc);
        // The Kotlin write callers already fire their profile/group listeners,
        // which schedule the catalog refresh after this call returns. Do NOT
        // call data.refresh here: on a burst of traffic/test writes that would
        // rebuild the whole catalog once per tick. Reply with a small ack (the
        // old full-document reply made every traffic tick copy a huge map).
        final current = await (await profileStore.store()).document;
        return <String, dynamic>{
          'ok': true,
          'nextProfileId': current.nextProfileId,
          'nextGroupId': current.nextGroupId,
          'profileIds': allocated.profiles.map(
            (client, real) => MapEntry(client.toString(), real),
          ),
          'groupIds': allocated.groups.map(
            (client, real) => MapEntry(client.toString(), real),
          ),
        };
      case 'reMigrateFromRoom':
        // Explicit recovery for a missing/corrupt document after a failed
        // migration. Never done silently: the caller (settings UI / Kotlin)
        // asks for it and Room is only ever read here.
        final result = await profileStore.reMigrate();
        await call('data.refresh');
        return <String, dynamic>{
          'migrated': result.migrated,
          'profileCount': result.profileCount,
          'groupCount': result.groupCount,
        };
      default:
        throw MissingPluginException('unknown profiles_doc method: ${profileCall.method}');
    }
  }

  /// Diagnostics for the in-app "configuration document" section: a forced
  /// re-parse of `<filesDir>/documents/profiles.json`, never a cached snapshot.
  /// The returned sealed type is the only shape the UI sees (see
  /// [ProfileDocumentStatus]).
  Future<ProfileDocumentStatus> profileDocumentStatus() =>
      profileDocumentStatusFn?.call() ?? profileStore.status();

  /// The *host's* view of the same document: the directory Kotlin reads,
  /// whether the file is there, the row counts its parser produced, and the
  /// parse error when it has one. Dart's own status answers from the file it
  /// wrote; a catalog that stays empty while that status looks healthy means
  /// the two sides disagree about the file, and this is the row that says why.
  Future<Json> profileDocumentKotlinView() async =>
      profileDocumentKotlinViewFn?.call() ??
      json(await call('data.profilesView'));

  /// Rebuilds the document from Room via the explicit `reMigrate` path, which
  /// preserves a still-valid document. Refreshes the host catalog and notifies
  /// listeners so every screen re-reads the authoritative document. On failure
  /// the exception propagates for the caller to show.
  Future<String> repairProfileDocument() async {
    final injected = repairProfileDocumentFn;
    if (injected != null) return injected();
    final result = await profileStore.reMigrate();
    await call('data.refresh');
    notifyListeners();
    final doc = await (await profileStore.store()).document;
    // A group is a subscription/config; its profiles are the individual nodes.
    final summary = '${doc.groups.length} 配置 / ${doc.profiles.length} 节点';
    if (result.migrated) return '已从 Room 重建：$summary';
    return '文档有效，未覆盖（$summary）';
  }

  void clearApplyRequired() { applyRequired = null; _notify([BoxAspect.state]); }

  /// Runs a bridge action and reports its reply. A boolean reply is the host's
  /// own verdict (the test-session bus's start answers false when a session is
  /// already running), so it is returned as-is rather than flattened to true.
  /// Any other reply means the call completed without throwing.
  Future<bool> act(String method, [Json? args]) async {
    try {
      final reply = await call(method, args);
      return reply is bool ? reply : true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<bool> setPreference(String key, dynamic value) => setPreferences({key: value});

  Future<bool> setPreferences(Json values) async {
    try {
      preferences = json(await preferencesSet(values));
      _notify([BoxAspect.state, BoxAspect.appearance]);
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<void> setSetting(String key, dynamic value, {bool restart = true, bool autoRestart = false}) async {
    // ADR 0005 phase 2: UI-only keys are Dart-owned; they never touch the channel
    // and never raise a reload/restart badge (there is no service input behind them).
    if (uiOnlyKeys.contains(key)) {
      await setPreference(key, value);
      return;
    }
    if (serviceSettingsChanging || autoRestart && transitioning && !remote) return;
    final restartService = autoRestart && running && !remote;
    if (autoRestart) {
      serviceSettingsChanging = true;
      _notify([BoxAspect.state]);
    }
    try {
      final saved = json(await settingsSet(key, value, restart: restartService));
      if (!_disposed) {
        _hostSettings = saved;
        if (restartService) {
          applyRequired = null;
        } else if (restart && !autoRestart && running && !remote) { applyRequired = 'Restart'; }
        _notify([BoxAspect.state]);
      }
    } catch (error) {
      report(error);
    } finally {
      if (autoRestart) {
        serviceSettingsChanging = false;
        if (!_disposed) _notify([BoxAspect.state]);
      }
    }
  }

  Future<bool> setSettings(Json values, {bool restart = true}) async {
    // Split the batch: overlay keys go to the Dart `preferences` document, the
    // rest to the authoritative channel. Only the authoritative half can carry
    // a restart, so a pure-UI batch never raises the badge.
    final parts = splitSettings(values);
    var ok = true;
    if (parts.overlay.isNotEmpty) ok = await setPreferences(parts.overlay) && ok;
    if (parts.authoritative.isNotEmpty) {
      try {
        _hostSettings = json(await settingsPatch(parts.authoritative));
        if (restart && running && !remote) applyRequired = 'Restart';
        _notify([BoxAspect.state]);
      } catch (error) { report(error); ok = false; }
    }
    return ok;
  }

  /// Returns the listed settings (every Throne setting when [keys] is empty) to their Throne defaults.
  /// Restarting stays on demand: the bridge reloads or raises the restart badge only when a key that
  /// actually changed needs it, and a reset that changed nothing leaves the running core alone.
  /// UI-only keys are dropped from the Dart overlay instead of crossing the channel.
  Future<bool> resetSettings(List<String> keys) async {
    final overlayKeys = keys.where(uiOnlyKeys.contains).toList();
    final authoritativeKeys = keys.where((key) => !uiOnlyKeys.contains(key)).toList();
    var ok = true;
    if (overlayKeys.isNotEmpty) {
      final cleared = <String, dynamic>{for (final key in overlayKeys) key: null};
      ok = await setPreferences(cleared) && ok;
    }
    if (authoritativeKeys.isNotEmpty || keys.isEmpty) {
      // An empty list means "all Throne settings"; the channel still owns that.
      try {
        _hostSettings = json(await settingsReset(authoritativeKeys));
        _notify([BoxAspect.state]);
      } catch (error) { report(error); ok = false; }
    }
    return ok;
  }

  void report(Object error) { if (!_disposed) eventBus.emit(BoxMessageEvent(describe(error))); }

  /// UI-initiated banner message (previously written directly into `messages`).
  void showMessage(String text) { if (!_disposed) eventBus.emit(BoxMessageEvent(text)); }

  /// A user-facing one-liner for [error].
  ///
  /// The engine-link and action-bus exceptions carry a sentence their own code
  /// wrote; the class prefix in front of it ("KernelProxyException: ...") reads
  /// as an internal failure rather than an answer, so it is dropped here. A
  /// refusal keeps the kernel's code for a report, since the text alone cannot
  /// be matched back to the Go handler.
  static String describe(Object error) => switch (error) {
        PlatformException() => error.message ?? error.code,
        KernelProxyException(:final message, :final code) =>
          code == null ? message : '$message ($code)',
        ActionException(:final message) => message,
        _ => error.toString(),
      };

  /// [event] from the driver's own status feed, as opposed to the channel.
  @visibleForTesting
  void handleEvent(dynamic event, {bool fromDriver = false}) => _onEvent(event, fromDriver: fromDriver);

  /// Times one event's synchronous handling. The turn profiler showed the
  /// start freeze sits on the UI isolate (`ui drift` ≈ frame gap); a line here
  /// names the event type when the cost is in the handler rather than in the
  /// rebuild the notification schedules.
  void _onEvent(dynamic event, {bool fromDriver = false}) {
    if (_disposed) return;
    final began = DateTime.now();
    try {
      _applyEvent(event, fromDriver: fromDriver);
    } finally {
      final ms = DateTime.now().difference(began).inMilliseconds;
      if (ms >= 12) _noteSlowEvent(event, ms);
    }
  }

  DateTime? _lastSlowEventNote;

  void _noteSlowEvent(dynamic event, int ms) {
    final now = DateTime.now();
    final last = _lastSlowEventNote;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastSlowEventNote = now;
    final item = event is Map<String, dynamic> ? event : json(event);
    final value = item['value'];
    final size = value is Map
        ? value.length
        : value is List
            ? value.length
            : 0;
    // Enough to tell a small live-fields dashboard from one carrying a catalog;
    // the field list is only built on this slow path.
    final keys = value is Map && value.length > 12
        ? ' keys=${value.keys.take(8).join(',')}'
        : '';
    unawaited(
      call('log.note', {
        'text': 'slow event ${item['type']} ${ms}ms (fields=$size$keys)',
      }).then((_) {}, onError: (_) {}),
    );
  }

  void _applyEvent(dynamic event, {bool fromDriver = false}) {
    if (_disposed) return;
    final item = json(event);
    // Diagnostic breadcrumb for a loop stall that lands outside any handler's
    // stopwatch: FrameWatch reports `ui stall Nms (… last=<type>)`.
    lastEventType = '${item['type']}';
    final value = item['value'];
    final type = lastEventType;
    if (value is Uint8List && bulkEventTypes.contains(type)) {
      // The host encodes on its producing thread and hands over bytes; where they are decoded
      // is this isolate's decision (see [bulkDecodeBytes]). Own a copy before queueing: the
      // codec returns a view into the event's envelope buffer, and the decode runs after this
      // dispatch returns (or on another isolate).
      _enqueueBulk(type, Uint8List.fromList(value));
      return;
    }
    if (fromDriver) {
      driverEventCount++;
      lastDriverEventAt = DateTime.now();
      if (item['type'] == 'dashboard') {
        lastDriverDashboard = json(value);
      } else if (item['type'] == 'rates') {
        driverRateCount++;
        lastDriverRateAt = DateTime.now();
      }
    }
    // The driver's feed is the truth while it runs the core; the channel's dashboard and
    // rates then carry the service meter's zeros and must not overwrite it.
    final channelIsStale = _driverActive && !fromDriver;
    var aspects = const [BoxAspect.state];
    switch (item['type']) {
      case 'memory':
        final nextMemory = json(value);
        if (const DeepCollectionEquality().equals(memory, nextMemory)) return;
        memory = nextMemory;
        aspects = const [BoxAspect.memory];
      case 'lan': lan = json(value);
      // The system is short of memory: ART's gc/trimHeap cannot touch the Dart heap, so the
      // decoded images (the largest thing the UI keeps) are dropped here instead.
      case 'memoryTrim':
        imageCache.clear();
        imageCache.clearLiveImages();
        // Icon bytes are not counted by imageCache; a trim is exactly when they should go.
        appIcons.clear();
        processInfo.clear();
        return;
      case 'browserComplete': eventBus.emit(BrowserCompleteEvent(json(value))); return;
      // The host's traffic poller: one attributed delta per tick (hosts/nodes/rules/apps).
      case 'trafficDeltas': eventBus.emit(BoxTrafficDeltaEvent(json(value))); return;
      case 'dashboard':
        // The two feeds differ in shape: the channel wire is the full map, the
        // driver's carries only its live fields. A driver event merges those
        // over the channel-owned map; a channel event goes through the
        // staleness merge.
        final nextDashboard = fromDriver
            ? mergeDriverDashboard(dashboard, json(value))
            : mergeDashboard(dashboard, json(value), channelIsStale: channelIsStale);
        if (const DeepCollectionEquality().equals(dashboard, nextDashboard)) return;
        const counters = {'memory', 'goroutines', 'uploadTotal', 'downloadTotal', 'connections'};
        Json state(Json data) => Map.fromEntries(data.entries.where((entry) => !counters.contains(entry.key)));
        aspects = const DeepCollectionEquality().equals(state(dashboard), state(nextDashboard))
          ? const [BoxAspect.traffic] : const [BoxAspect.state, BoxAspect.traffic];
        final wasRunning = running;
        dashboard = nextDashboard;
        _dashboardSeen = true;
        // The selection the profiles screen remembered is restored here, from
        // a state event that actually carries `selectedProfileId` (a profiles
        // event alone cannot tell whether the host has a selection).
        _restoreSelectionOnce();
        // The tunnel is up but this UI engine has not attached to the service
        // engine yet (cold UI start, or a UI engine recreated while the core kept
        // running). Attaching is idempotent.
        if (running && !remote) unawaited(_reconnectKernel());
        // Bettbox clears its traffic window and totals when the session ends, so the next start
        // draws a curve of its own instead of continuing the one the previous session left.
        if (wasRunning && !running) {
          uploadHistory.clear();
          downloadHistory.clear();
          rates = {};
          sampleRevision++;
          _lastSample = null;
        }
      case 'profiles':
        _profileStats.clear();
        profiles = rows(value);
        _restoreSelectionOnce();
      case 'groups': _applyGroups(value); return;
      case 'subscriptionState':
        // Queue state of one subscription group (gid -> 0 idle / 1 queued / 2 running).
        // Idle removes the entry; queued/running keep the profile card's spinner alive
        // across the whole download. State is merged into BoxAspect.state so watchers
        // rebuild immediately, without waiting for the (possibly absent) report event.
        final gid = (value['gid'] as num?)?.toInt();
        final state = (value['state'] as num?)?.toInt() ?? 0;
        if (gid == null) return;
        if (state == 0) {
          subscriptionStates.remove(gid);
        } else {
          subscriptionStates[gid] = state;
        }
      case 'connections':
        _applyConnections(value);
        return;
      case 'logs':
        _applyLogs(value);
        return;
      case 'logcat':
        _applyLogcat(value);
        return;
      case 'testSession': testSession = json(value); aspects = const [BoxAspect.testSession];
      case 'ruleSets':
        // Kernel's post-start rule-set update result: {updated, error, at}.
        // A dedicated aspect keeps the caption out of the 1 Hz traffic rebuilds.
        ruleSetsStatus = json(value);
        aspects = const [BoxAspect.ruleSetsStatus];
      case 'settings': _hostSettings = json(value);
      case 'preferences':
        final nextPreferences = json(value);
        if (const DeepCollectionEquality().equals(preferences, nextPreferences)) return;
        preferences = nextPreferences;
        aspects = const [BoxAspect.state, BoxAspect.appearance];
      case 'systemAccent':
        final accent = (value as num?)?.toInt();
        if (accent == null || systemAccentColor == accent) return;
        systemAccentColor = accent;
        aspects = const [BoxAspect.appearance];
      case 'rates':
        // The driver's own status feed carries these numbers while it runs the core; the
        // channel's copy is the service meter's, which has no TrafficUpdater in FFI mode and
        // would alternate with the real rates once a second.
        if (channelIsStale) return;
        rates = json(value);
        // One point per second, whoever pushes it: the channel's tick and the FFI status feed can
        // both report the same second, and a doubled sample would halve the window's span. The
        // revision tracks the append, so the chart's own delta stays one value per increment.
        final now = DateTime.now();
        if (_lastSample == null || now.difference(_lastSample!) >= trafficSampleGap) {
          _lastSample = now;
          _sampleTraffic();
          sampleRevision++;
        }
        aspects = const [BoxAspect.traffic];
      case 'error': eventBus.emit(BoxMessageEvent(value.toString())); return;
      case 'applyRequired': applyRequired = value.toString();
      case 'serviceReload':
        // A widget/tile/notification reload reached the FFI driver (BboxKernel.onReloadWanted).
        unawaited(kernel.reloadService(reason: 'widget/tile/notification reload'));
        return;
      case 'serviceStop':
        // A widget/tile/notification stop in ffiMode: the service is already
        // stopping, so the driver only closes the core it owns.
        unawaited(kernel.stopCoreFromHost().catchError((Object error) {
          report(error);
        }));
        return;
      case 'wifi.state':
        // The Android monitor saw the SSID/BSSID change (BboxKernel.onWifiChanged); the core
        // that owns the routing rules is Dart's, so the re-read happens here.
        unawaited(kernel.updateWifiState().catchError((Object error) {
          report(error);
        }));
        return;
      case 'subscriptionReport':
        // Errors and untitled status lines are snackbars; a popup report opens the change window
        // (SubscriptionReportDialog equivalence) — the app shell listens on the stream.
        final report = json(value);
        if (report['kind'] == 'popup') {
          eventBus.emit(SubscriptionReportEvent(report));
        } else {
          final group = report['groupName']?.toString() ?? '';
          eventBus.emit(BoxMessageEvent(group.isEmpty ? report['text'].toString() : '$group: ${report['text']}'));
        }
        return;
      case 'intentAvailable':
        call('intent.take').then((uri) { if (uri is String) { pendingIntents.add(uri); eventBus.emit(const IntentAvailableEvent()); } }).catchError(report);
        return;
      case 'openUrl':
        // A backend request remains a visible user action in the Flutter UI.
        eventBus.emit(BoxMessageEvent(value.toString()));
        return;
      default: return;
    }
    // A burst of list events shares one rebuild; everything else notifies as it
    // lands. While hidden, high-frequency aspects are held for the resume flush.
    _dispatch(aspects, _batchedTypes.contains(item['type']));
  }

  /// Kernel logs arriving through the FFI message port (dual path: only when
  /// the rebuilt core is present). Same entry shape the channel pushes.
  /// The id uses a high offset to stay clear of the channel's id space;
  /// receivedAt is milliseconds since epoch to match the channel wire format.
  static const _kernelLogIdBase = 0x10000000;

  /// True for a line that came through the FFI port rather than the channel. The two
  /// id spaces overlap unless they are told apart, and the delta merge must only ever
  /// compare channel ids with channel ids.
  static bool _isKernelLog(Json entry) =>
      ((entry['id'] as num?)?.toInt() ?? 0) >= _kernelLogIdBase;

  /// A process-local arrival order shared by the kernel and logcat tails.
  /// Their clocks and id spaces differ, so the merged screen cannot recover
  /// the true write order from either field alone.
  void _stampLogSeq(Iterable<Json> entries) {
    for (final entry in entries) {
      entry.putIfAbsent('seq', () => _nextLogSeq++);
    }
  }

  void _onKernelLog(Json data) {
    if (_disposed) return;
    lastEventType = 'kernelLog';
    final level = logLevelName(data['level']);
    // The recording level the log screen sets is shared by both tails and is the one the
    // reader expects here too (it includes the client-side `silent`, which the host setting
    // cannot express: choosing it writes `panic`). Fall back to the host's `logLevel` for a
    // profile that never opened the screen.
    final floor = logcatLevel ?? _hostSettings['logLevel'] ?? defaultLogLevel;
    // The FFI port does not go through CoreRuntime.appendCoreLog, so this is
    // the first place the recording level can be applied to that path.
    if (floor != null && !logLevelAllowed(level, floor)) return;
    _pendingKernelLogs.add({
      'id': _kernelLogIdBase + _kernelLogId++,
      // The FFI port carries sing-box's numeric log.Level; normalise it here so the row,
      // its badge and every level filter see the same word the channel path sends.
      'level': level,
      'message': data['message'],
      'receivedAt': DateTime.now().millisecondsSinceEpoch,
      'seq': _nextLogSeq++,
    });
    if (_pendingKernelLogs.length > maxKernelLogBatchLines) {
      _pendingKernelLogs.removeRange(
        0,
        _pendingKernelLogs.length - maxKernelLogBatchLines,
      );
    }
    _kernelLogTimer ??= Timer(kernelLogBatchWindow, _flushKernelLogs);
  }

  /// One encoded batch from the service engine: `receivedAt<tab>level<tab>message` lines.
  ///
  /// The service encodes once and sends one string, so a start's log burst costs one copy
  /// across the isolate boundary instead of a map per line. The decode is a single pass
  /// here; [reset] marks the ring snapshot the service replays when the log screen opens,
  /// which replaces the kernel rows and leaves the Android tail alone.
  void _onKernelLogsPayload(String payload, {required bool reset}) {
    if (_disposed) return;
    lastEventType = 'kernelLogs';
    final floor = logcatLevel ?? _hostSettings['logLevel'] ?? defaultLogLevel;
    final rows = <Json>[];
    for (final line in payload.split('\n')) {
      if (line.isEmpty) continue;
      final first = line.indexOf('\t');
      final second = first < 0 ? -1 : line.indexOf('\t', first + 1);
      final at = first < 0 ? 0 : int.tryParse(line.substring(0, first)) ?? 0;
      final level = logLevelName(second < 0 ? '' : line.substring(first + 1, second));
      if (floor != null && !logLevelAllowed(level, floor)) continue;
      rows.add({
        'id': _kernelLogIdBase + _kernelLogId++,
        'level': level,
        'message': second < 0 ? line : line.substring(second + 1),
        'receivedAt': at > 0 ? at : DateTime.now().millisecondsSinceEpoch,
        'seq': _nextLogSeq++,
      });
    }
    if (rows.isEmpty && !reset) return;
    // One pass over the existing window, then append into the result: the old shape filtered
    // the list into a temporary and spread both into a third, i.e. ~5 copies of up to 512 rows
    // per event — during a log burst that is the busiest list in the controller.
    final merged = <Json>[];
    for (final entry in logs) {
      if (reset && _isKernelLog(entry)) continue;
      merged.add(entry);
    }
    merged.addAll(rows);
    _logs.replaceAll(merged);
    _dispatch(const [BoxAspect.logs], true);
  }

  /// Bulk feeds decode in arrival order: an isolate hop is long enough for a later batch to
  /// overtake the one before it, and both log tails are ordered streams.
  Future<void> _bulkQueue = Future<void>.value();

  /// Payload types whose malformed frames were already reported this run, so a persistent
  /// stream problem leaves one line instead of a banner per tick.
  final _bulkFailures = <String>{};

  /// Decodes one encoded bulk payload and applies it — inline below [bulkDecodeBytes], on a
  /// background isolate above it. From `ThroneBoxBridge.emitBulk`.
  void _enqueueBulk(String type, Uint8List bytes) {
    _bulkQueue = _bulkQueue.then((_) async {
      if (_disposed) return;
      Object? value;
      try {
        value = bytes.length < bulkDecodeBytes
            ? decodeBulkPayload(bytes)
            : await decodeBulkPayloadIsolated(bytes);
      } catch (error) {
        // A frame that does not decode is dropped, not surfaced as a bare "Message corrupted":
        // the next tick sends the whole list again, so one bad frame costs one refresh. The try
        // covers the decode alone, so anything caught here is a malformed payload — a bad type
        // byte (FormatException) or a truncated one (RangeError). The diagnostic keeps the first
        // occurrence (and its size) visible in the log page.
        if (_bulkFailures.add(type)) {
          report(FormatException('$type payload dropped (${bytes.length} B): $error'));
        }
        return;
      }
      if (_disposed || value == null) return;
      switch (type) {
        case 'connections':
          _applyConnections(value);
        case 'groups':
          _applyGroups(value);
        case 'logs':
          _applyLogs(value);
        case 'logcat':
          _applyLogcat(value);
      }
    }).catchError(report);
  }

  /// One page of connections, whole. Split out of the event switch so the encoded bulk path
  /// and the map path share exactly one implementation.
  void _applyConnections(Object? value) {
    _connections.replaceAll(rows(value));
    _dispatch(const [BoxAspect.connections], true);
  }

  /// The group rows, whole. Both shapes land here: the counts-only map every other screen
  /// renders, and the encoded node rows the Proxies screen asks for via `groups.visible`.
  ///
  /// Groups are not a batched type, so this notifies like any other state event — the bulk hop
  /// only moves the decode, not the moment the field becomes readable.
  void _applyGroups(Object? value) {
    groups = rows(value);
    _dispatch(const [BoxAspect.state], false);
  }

  /// One batch of the host's own log tail (`core.log`), with the channel/kernel id-space rule.
  void _applyLogs(Object? value) {
    final logState = json(value);
    final entries = rows(logState['entries']);
    _stampLogSeq(entries);
    // Channel and kernel logs share this list but not an id space: the channel numbers from 1,
    // the kernel from _kernelLogIdBase. Reading "the newest id" off the tail therefore compared
    // the two: after a handover back to the channel every new channel entry looked older than
    // the kernel ids and was dropped, and a channel reset replaced the list wholesale, wiping
    // the kernel's lines. Keep the channel delta relative to the channel entries only and leave
    // the kernel ones in place.
    final channel = <Json>[];
    final kernel = <Json>[];
    for (final entry in logs) {
      if (_isKernelLog(entry)) {
        kernel.add(entry);
      } else {
        channel.add(entry);
      }
    }
    int? idOf(Json entry) => (entry['id'] as num?)?.toInt();
    final next = <Json>[];
    if (logState['reset'] == false) {
      final firstId = (logState['firstId'] as num?)?.toInt();
      if (firstId != null) {
        for (final entry in channel) {
          if ((idOf(entry) ?? -1) >= firstId) next.add(entry);
        }
      }
      final lastId = channel.isEmpty ? -1 : (idOf(channel.last) ?? -1);
      for (final entry in entries) {
        if ((idOf(entry) ?? -1) > lastId) next.add(entry);
      }
    } else {
      next.addAll(entries);
    }
    next.addAll(kernel);
    _logs.replaceAll(next);
    defaultLogLevel = logState['defaultLogLevel'] as String?;
    _dispatch(const [BoxAspect.logs], true);
  }

  /// One batch of the Android logcat ring.
  void _applyLogcat(Object? value) {
    final logState = json(value);
    final entries = rows(logState['entries']);
    _stampLogSeq(entries);
    if (logState['reset'] == false) {
      final firstId = (logState['firstId'] as num?)?.toInt();
      final window = logcat;
      final retained = firstId == null ? <Json>[] : window.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) >= firstId);
      final lastId = window.isEmpty ? -1 : ((window.last['id'] as num?)?.toInt() ?? -1);
      _logcat.replaceAll([...retained, ...entries.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) > lastId)]);
    } else {
      _logcat.replaceAll(entries);
    }
    _dispatch(const [BoxAspect.logcat], true);
  }

  void _flushKernelLogs() {
    _kernelLogTimer = null;
    if (_disposed) {
      _pendingKernelLogs.clear();
      return;
    }
    if (_pendingKernelLogs.isEmpty) return;
    final pending = List<Json>.of(_pendingKernelLogs);
    _pendingKernelLogs.clear();
    // The append-only path: the window's retained tail stays in the buffer and
    // only the rows leaving the front move, instead of a new list per batch.
    _logs.appendAll(pending);
    // The public list is current now; the UI notification keeps its existing
    // coalescing window and background gate.
    _dispatch(const [BoxAspect.logs], true);
  }

  @override
  void dispose() {
    _disposed = true;
    _batchTimer?.cancel();
    _kernelLogTimer?.cancel();
    _pendingKernelLogs.clear();
    refreshGate.dispose();
    _subscription?.cancel();
    _kernelEvents?.cancel();
    _routeProfiles?.dispose();
    _routeProfiles = null;
    profileStore.dispose();
    _migrationRoomLayer?.close();
    _migrationRoomLayer = null;
    kernel.dispose();
    eventBus.close();
    _stateChanges.dispose();
    super.dispose();
  }
}

class BoxScope extends StatelessWidget {
  const BoxScope({super.key, required this.controller, required this.child});
  final BoxController controller;
  final Widget child;
  @override Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    child: child,
    builder: (_, child) => _BoxState(controller: controller,
      revisions: List<int>.of(controller._revisions), child: child!),
  );
  static BoxController of(BuildContext context, {BoxAspect aspect = BoxAspect.state}) =>
    InheritedModel.inheritFrom<_BoxState>(context, aspect: aspect)!.controller;
}

class _BoxState extends InheritedModel<BoxAspect> {
  const _BoxState({required this.controller, required this.revisions, required super.child});
  final BoxController controller;
  final List<int> revisions;
  @override bool updateShouldNotify(_BoxState oldWidget) =>
    controller != oldWidget.controller || !listEquals(revisions, oldWidget.revisions);
  @override bool updateShouldNotifyDependent(_BoxState oldWidget, Set<BoxAspect> dependencies) =>
    controller != oldWidget.controller || dependencies.any((aspect) => revisions[aspect.index] != oldWidget.revisions[aspect.index]);
}

extension BoxContext on BuildContext {
  /// Subscribes to *every* aspect. Use only when the widget really reads state that no
  /// single aspect covers; otherwise prefer [watchBox].
  BoxController get box => BoxScope.of(this);

  /// Subscribes to one aspect only.
  ///
  /// This used to call `BoxScope.of(this)` first (whose default aspect is `state`), so every
  /// `watchBox(logs)` also depended on `state` — and `state` is bumped by settings, groups,
  /// profiles, lan, tools and more. Eight of the ten call sites read only their own
  /// aspect's fields and were rebuilding on every one of those events. Need state? Ask for
  /// it (`context.box`) at the call site, so the dependency stays visible.
  BoxController watchBox(BoxAspect aspect) => BoxScope.of(this, aspect: aspect);
}

String bytes(num value) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var size = value.toDouble();
  var unit = 0;
  while (size.abs() >= 1024 && unit < units.length - 1) { size /= 1024; unit++; }
  return '${size.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
