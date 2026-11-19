import 'dart:async';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'capabilities.dart';
import 'common/config_guard.dart';
import 'common/ip_quality_cache.dart';
import 'common/log_level.dart';
import 'common/refresh_gate.dart';
import 'common/throttle.dart';
import 'core/action.dart';
import 'core/kernel_control.dart';
import 'core/kernel_service.dart';
import 'core/kernel_worker.dart';
import 'core/platform_value.dart';
import 'core/throne_kernel.dart';
import 'data/rule_set_catalog.dart' show RuleSetCatalogSource, readRuleSetCatalogText;
import 'data/route_profiles_source.dart';
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
import 'services/backup_profile_names.dart' show profileNamesFromContainer;
import 'dart:convert' show base64Decode, base64Encode;

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

enum BoxAspect { state, appearance, traffic, memory, connections, logs, logcat, testSession }
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
        webDavBackup = webDavBackupFactory ?? defaultWebDavBackupFactory {
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

  /// Exposed so `box_api` can resolve the concrete type from the factory.
  WebDavBackupTransport? newWebDavBackup() =>
      webDavBackup(webDavAccount.read(), appVersion: version);
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
  late final Stream<IntentAvailableEvent> intents = _eventsOf<IntentAvailableEvent>();
  StreamSubscription<dynamic>? _subscription;
  StreamSubscription<Map<String, dynamic>>? _kernelEvents;
  int _kernelLogId = 0;
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
  };

  /// [incoming] with the driver's own fields kept from [current] when [channelIsStale]:
  /// the service side has no box in FFI mode, so its copy of these is a row of zeros.
  /// Everything else — the mode, the selected profile, the system proxy — still comes from
  /// the channel, which is the side that persists it. The driver's own events are never
  /// merged: they are the values the merge is protecting.
  static Json mergeDashboard(Json current, Json incoming, {required bool channelIsStale}) {
    if (!channelIsStale) return incoming;
    final merged = Map<String, dynamic>.of(incoming);
    for (final key in driverOwnedDashboard) {
      if (current.containsKey(key)) merged[key] = current[key];
    }
    return merged;
  }

  /// Test hook: pretend the FFI driver owns the core, so the arbitration between the two
  /// sources can be exercised without the library. Null asks the driver.
  @visibleForTesting
  bool? debugDriverActive;
  bool get _driverActive => debugDriverActive ?? kernel.active;

  BoxCapabilities capabilities = BoxCapabilities.empty;
  Json toolState = {}, inbox = {}, ping = {};
  Json terminal = {};
  Json memory = {}, lan = {};
  List<Json> transfers = [], usbDevices = [];
  @override
  List<Json> profiles = [];
  List<Json> groups = [], connections = [], logs = [], logcat = [];
  Json testSession = {};
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
  static const maxLogLength = 512;

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

  /// One profile-stats read: the kernel's Room query when the driver is attached, else the
  /// channel. A failed kernel read falls back to the channel, which answers the same rows
  /// through ProfileManager — a room_db.go failure (missing file, WAL lock, decode) must not
  /// blank the card while a working reader exists.
  Future<Json> _readProfileStats(int id) async {
    final k = kernel.attached;
    if (k != null) {
      try {
        return json(await k.invoke<Object?>(ActionMethod.profileStats, data: {'id': id}));
      } catch (_) {
        // Read-only fallback; the channel arm below is the same read.
      }
    }
    return json(await call('profiles.stats', {'id': id}));
  }

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

  bool get remote => dashboard['remote'] != null;
  bool get running => remote
      ? dashboard['remoteConnected'] == true
      : dashboard['status'] == 'Started';
  bool get transitioning => ['Starting', 'Stopping'].contains(dashboard['status']);
  int get selectedProfileId => (dashboard['selectedProfileId'] as num?)?.toInt() ?? -1;
  Json? get selectedProfile {
    for (final profile in profiles) {
      if (profile['id'] == selectedProfileId) return profile;
    }
    return null;
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
    // The kernel now lives in the service Flutter engine. The UI engine only
    // resolves its port and subscribes to the forwarded event stream; it never
    // opens libthrone.so or the native logs port itself.
    await _kernelEvents?.cancel();
    _kernelEvents = null;
    try {
      await kernel.connect();
      _attachKernelEvents();
    } catch (error) {
      // The kernel service engine is optional (unit tests, an engine that has
      // not started yet, or a platform that did not spawn it). Everything but
      // the kernel runs on the channel, so this is not a startup error — only
      // a kernel call would report the unavailable service.
      notifyListeners();
    }
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
      toolState = json(result['tools']);
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
  /// Split out so a late reconnect installs the same listener [initialize] would.
  void _attachKernelEvents() {
    _kernelEvents = kernel.events.listen((event) {
      // Log lines are a service-engine concern; the UI only renders them.
      if (event['type'] == 'kernelLog') {
        _onKernelLog(json(event['value']));
        return;
      }
      _onEvent(event, fromDriver: true);
    }, onError: report);
  }

  /// The dashboard says the tunnel is up but the proxy is not attached yet.
  /// Cheap to retry: a failed lookup means the engine is still booting.
  Future<void> _reconnectKernel() async {
    if (!kernel.remote || kernel.ffiMode) return;
    try {
      await kernel.connect();
      await _kernelEvents?.cancel();
      _attachKernelEvents();
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
  static String describe(Object error) => error is PlatformException
      ? error.message ?? error.code : error.toString();

  /// [event] from the driver's own status feed, as opposed to the channel.
  @visibleForTesting
  void handleEvent(dynamic event, {bool fromDriver = false}) => _onEvent(event, fromDriver: fromDriver);

  void _onEvent(dynamic event, {bool fromDriver = false}) {
    if (_disposed) return;
    final item = json(event);
    final value = item['value'];
    // The driver's feed is the truth while it runs the core; the channel's dashboard and
    // rates then carry the service meter's zeros and must not overwrite it.
    final channelIsStale = _driverActive && !fromDriver;
    var aspects = const [BoxAspect.state];
    switch (item['type']) {
      case 'tools': toolState = json(value);
      case 'inbox': inbox = json(value);
      case 'ping': ping = json(value);
      case 'transfers': transfers = rows(value);
      case 'usbDevices': usbDevices = rows(value);
      case 'terminal': terminal = json(value);
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
        return;
      case 'browserComplete': eventBus.emit(BrowserCompleteEvent(json(value))); return;
      case 'dashboard':
        final nextDashboard = mergeDashboard(dashboard, json(value), channelIsStale: channelIsStale);
        if (const DeepCollectionEquality().equals(dashboard, nextDashboard)) return;
        const counters = {'memory', 'goroutines', 'uploadTotal', 'downloadTotal', 'connections'};
        Json state(Json data) => Map.fromEntries(data.entries.where((entry) => !counters.contains(entry.key)));
        aspects = const DeepCollectionEquality().equals(state(dashboard), state(nextDashboard))
          ? const [BoxAspect.traffic] : const [BoxAspect.state, BoxAspect.traffic];
        final wasRunning = running;
        dashboard = nextDashboard;
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
      case 'profiles': _profileStats.clear(); profiles = rows(value);
      case 'groups': groups = rows(value);
      case 'connections':
        connections = rows(value);
        aspects = const [BoxAspect.connections];
      case 'logs':
        final logState = json(value);
        final entries = rows(logState['entries']);
        // Channel and kernel logs share this list but not an id space: the channel numbers
        // from 1, the kernel from _kernelLogIdBase. Reading "the newest id" off the tail
        // therefore compared the two: after a handover back to the channel every new
        // channel entry looked older than the kernel ids and was dropped, and a channel
        // reset replaced the list wholesale, wiping the kernel's lines. Keep the channel
        // delta relative to the channel entries only and leave the kernel ones in place.
        final channel = logs.where((entry) => !_isKernelLog(entry)).toList();
        final kernel = logs.where(_isKernelLog).toList();
        int? idOf(Json entry) => (entry['id'] as num?)?.toInt();
        if (logState['reset'] == false) {
          final firstId = (logState['firstId'] as num?)?.toInt();
          final retained = firstId == null
              ? <Json>[]
              : channel.where((entry) => (idOf(entry) ?? -1) >= firstId).toList();
          final lastId = channel.isEmpty ? -1 : (idOf(channel.last) ?? -1);
          logs = [
            ...retained,
            ...entries.where((entry) => (idOf(entry) ?? -1) > lastId),
            ...kernel,
          ];
        } else {
          logs = [...entries, ...kernel];
        }
        if (logs.length > maxLogLength) logs = logs.sublist(logs.length - maxLogLength);
        defaultLogLevel = logState['defaultLogLevel'] as String?;
        aspects = const [BoxAspect.logs];
      case 'logcat':
        final logState = json(value);
        final entries = rows(logState['entries']);
        if (logState['reset'] == false) {
          final firstId = (logState['firstId'] as num?)?.toInt();
          final retained = firstId == null ? <Json>[] : logcat.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) >= firstId);
          final lastId = logcat.isEmpty ? -1 : ((logcat.last['id'] as num?)?.toInt() ?? -1);
          logcat = [...retained, ...entries.where((entry) => ((entry['id'] as num?)?.toInt() ?? -1) > lastId)];
        } else {
          logcat = entries;
        }
        if (logcat.length > maxLogLength) logcat = logcat.sublist(logcat.length - maxLogLength);
        aspects = const [BoxAspect.logcat];
      case 'testSession': testSession = json(value); aspects = const [BoxAspect.testSession];
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
        unawaited(kernel.stopCoreFromHost());
        return;
      case 'wifi.state':
        // The Android monitor saw the SSID/BSSID change (BboxKernel.onWifiChanged); the core
        // that owns the routing rules is Dart's, so the re-read happens here.
        unawaited(kernel.updateWifiState());
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

  void _onKernelLog(Json data) {
    if (_disposed) return;
    logs = [...logs, {
      'id': _kernelLogIdBase + _kernelLogId++,
      // The FFI port carries sing-box's numeric log.Level; normalise it here so the row,
      // its badge and every level filter see the same word the channel path sends.
      'level': logLevelName(data['level']),
      'message': data['message'],
      'receivedAt': DateTime.now().millisecondsSinceEpoch,
    }];
    if (logs.length > maxLogLength) logs = logs.sublist(logs.length - maxLogLength);
    _notifyBatched(const [BoxAspect.logs]);
  }

  @override
  void dispose() {
    _disposed = true;
    _batchTimer?.cancel();
    refreshGate.dispose();
    _subscription?.cancel();
    _kernelEvents?.cancel();
    _routeProfiles?.dispose();
    _routeProfiles = null;
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
