import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../box.dart';
import '../capabilities.dart';
import '../components/connectivity/connectivity_store.dart';

/// The single [BoxController] the app already owns (created in `main`).
///
/// It is injected with `overrideWithValue` at the root; reading it without
/// that override is a programming error, not a fallback. The pilot only ever
/// *reads* this provider — writes keep going through the controller's own API
/// (`context.box.*`), so Riverpod never becomes a second writer to reconcile.
final boxControllerProvider =
    Provider<BoxController>((ref) => throw UnimplementedError('overridden in main'));

/// Exposes the process-wide [ConnectivityStore] singleton.
///
/// The store is already a [ChangeNotifier] and the single source of truth for
/// probe state. A plain [Provider] is used deliberately over
/// `ChangeNotifierProvider`: Riverpod disposes a `ChangeNotifierProvider`'s
/// notifier when its scope goes away, which would kill this app-wide singleton.
/// Consumers `ref.watch` this provider for the instance, and subscribe to the
/// store's own notifications with a `ListenableBuilder`/`AnimatedBuilder` so
/// rebuilds come from the store itself — there is no second copy to keep in
/// sync and nothing is ever written back to Riverpod.
final connectivityStoreProvider = Provider<ConnectivityStore>((ref) {
  return ConnectivityStore.instance;
});

/// One-way notification bridge from the app-owned [BoxController] into Riverpod.
///
/// [BoxController] is a [ChangeNotifier], but a plain [Provider] does not
/// rebuild when its value notifies. We deliberately do **not** turn
/// `boxControllerProvider` into a `ChangeNotifierProvider`: Riverpod owns and
/// disposes that notifier, while the controller is owned (and disposed) by
/// `BoxApp`. Instead this tiny notifier only forwards `stateChanges` — the
/// aspect that covers settings and preferences — so derived providers can
/// re-read fresh values from the controller. It holds no data of its own: the
/// bridge is a notification, never a second source of truth, and nothing is
/// ever written back through it.
final boxStateChangesProvider = ChangeNotifierProvider<ChangeNotifier>((ref) {
  final box = ref.watch(boxControllerProvider);
  return _BoxStateChangesBridge(box.stateChanges);
});

class _BoxStateChangesBridge extends ChangeNotifier {
  _BoxStateChangesBridge(this._source) {
    _source.addListener(_onChanged);
  }

  final Listenable _source;

  void _onChanged() => notifyListeners();

  // ChangeNotifierProvider calls dispose() on its notifier; remove our source
  // subscription there. Never dispose the source — the controller owns itself.
  @override
  void dispose() {
    _source.removeListener(_onChanged);
    super.dispose();
  }
}

/// The merged settings map, read fresh from [BoxController] on every rebuild.
///
/// The controller recomputes `settings` as `mergeSettings(host, preferences)`
/// on each read (ADR 0005 phase 2), so a cached whole-map copy would mask a
/// fresh host snapshot. Watching [boxStateChangesProvider] invalidates this
/// provider whenever settings/preferences change; the value itself is always
/// re-read from the controller. Writes stay on `context.box.setSetting()`.
final settingsProvider = Provider<Json>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider).settings;
});

/// The preferences overlay, read fresh from [BoxController] on every rebuild.
///
/// Same one-way bridge and no-cache rule as [settingsProvider]. Appearance
/// reads this instead of `context.box.preferences`; writes stay on
/// `context.box.setPreference(s)`.
final preferencesProvider = Provider<Json>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider).preferences;
});

/// The service mode string (`vpn` / `proxy`), the one setting several pages
/// read to decide whether a proxy-only row applies.
///
/// `settings` is a freshly merged map on every read, so a consumer watching the
/// whole map rebuilt whenever *any* setting changed. Extracting just this
/// string lets Riverpod's value comparison skip unrelated edits. Every
/// assignment to the host settings snapshot or the preferences overlay in
/// `box.dart` notifies [BoxAspect.state], so the state-aspect bridge is enough:
/// traffic/log/test-session ticks never rebuild this provider's dependents.
final serviceModeProvider = Provider<String>(
    (ref) => _readStateField(ref, (b) => b.settings['serviceMode'] as String? ?? 'vpn'));

// ---------------------------------------------------------------------------
// P12: page-layer providers.
//
// Every provider below is a *read* of the app-owned [BoxController]. The
// controller stays the single source of truth and the only writer; writes
// remain on `context.box.*`. A plain `Provider` (never a
// `ChangeNotifierProvider`) is used for the controller itself so Riverpod can
// never dispose it — the app owns the controller's lifetime.
//
// Each field provider watches a one-way [boxAspectsChangesProvider] for only
// the aspects that can change it, then re-reads fresh from the controller.
// Riverpod's built-in value comparison rebuilds only dependents whose field
// actually changed (collections replaced wholesale by the controller, scalars
// and derived getters by ==). This is the same shape as the settings/preferences
// bridge above — a notification, never a second source of truth, and nothing
// is written back through Riverpod. `boxChangesProvider` (all aspects) remains
// for compatibility; new field providers must not use it.
// ---------------------------------------------------------------------------

/// Aspect sets each field provider listens to.
///
/// Every field knows exactly which aspects can change it (`box.dart` dispatch
/// sites). Keeping the map here makes the fan-out explicit and the bridge
/// subscription cheap: a traffic tick no longer re-evaluates 23 unrelated
/// selectors. `dashboard` changes under `state` or `traffic` — a counter-only
/// push is traffic-only, a mode/selection change carries both. `memory` is a
/// separate aspect (`case 'memory'`), not part of the dashboard dispatch.
const _stateAspects = <BoxAspect>{BoxAspect.state};
const _trafficAspects = <BoxAspect>{BoxAspect.traffic};
const _dashboardAspects = <BoxAspect>{BoxAspect.state, BoxAspect.traffic};
const _connectionsAspects = <BoxAspect>{BoxAspect.connections};
const _logsAspects = <BoxAspect>{BoxAspect.logs};
const _logcatAspects = <BoxAspect>{BoxAspect.logcat};
const _testSessionAspects = <BoxAspect>{BoxAspect.testSession};
const _memoryAspects = <BoxAspect>{BoxAspect.memory};
const _ruleSetsAspects = <BoxAspect>{BoxAspect.ruleSetsStatus};
const _appearanceAspects = <BoxAspect>{BoxAspect.appearance};

/// One-way notification bridge for an arbitrary set of [BoxAspect]s.
///
/// Family parameter is the aspect set itself; the controller's `changesFor`
/// is idempotent, so the same set resolves to the same cached [Listenable].
/// Holding the bridge in a ChangeNotifierProvider is safe: Riverpod disposes
/// the *bridge*, whose disposal only detaches the listener. The controller is
/// never disposed by Riverpod.
final boxAspectsChangesProvider =
    ChangeNotifierProvider.family<ChangeNotifier, Set<BoxAspect>>((ref, aspects) {
  final box = ref.watch(boxControllerProvider);
  return _BoxAspectBridge(box.changesFor(aspects));
});

class _BoxAspectBridge extends ChangeNotifier {
  _BoxAspectBridge(this._source) {
    _source.addListener(_onChanged);
  }

  final Listenable _source;

  void _onChanged() => notifyListeners();

  @override
  void dispose() {
    _source.removeListener(_onChanged);
    super.dispose();
  }
}

/// Kept for compatibility with callers that used the all-aspect bridge.
/// New code should watch [boxAspectsChangesProvider] with the exact aspect set.
final boxChangesProvider = ChangeNotifierProvider<ChangeNotifier>((ref) {
  final box = ref.watch(boxControllerProvider);
  return _BoxAspectBridge(box);
});

/// The controller, rebuilt on the same `state` aspect the old
/// `context.box` (`BoxScope.of(aspect: state)`) subscribed to.
///
/// Pages that used `context.box` for a mix of state fields watch this provider:
/// it re-reads the same injected controller but re-evaluates whenever the
/// controller's `stateChanges` fires, exactly like the InheritedModel did.
/// Writes still go through the controller, never through Riverpod.
final boxStateProvider = Provider<BoxController>((ref) {
  ref.watch(boxStateChangesProvider);
  return ref.watch(boxControllerProvider);
});

/// Watch the injected controller with the old `context.box` rebuild semantics.
///
/// Watching [boxStateChangesProvider] subscribes the consumer to the bridge's
/// notifications (a `ChangeNotifierProvider` rebuilds its watchers whenever
/// the notifier fires), so the consumer rebuilds on every `state` event. The
/// controller itself is read fresh from [boxControllerProvider] and is never
/// copied or written back. This is preferred over watching [boxStateProvider]
/// directly: a plain `Provider` returning the *same* controller instance
/// compares equal and therefore would not rebuild its dependents.
extension BoxStateWatch on WidgetRef {
  BoxController watchBoxState() {
    watch(boxStateChangesProvider);
    return read(boxControllerProvider);
  }
}

/// [Ref] form of [BoxStateWatchon WidgetRef] for `ConsumerState` subclasses.
extension BoxStateWatchRef on Ref {
  BoxController watchBoxState() {
    watch(boxStateChangesProvider);
    return read(boxControllerProvider);
  }
}

/// Re-evaluate [select] fresh from the injected controller whenever one of
/// [aspects] changes.
///
/// A field only cares about the aspects that can write it. A traffic tick
/// re-evaluates only the traffic/dashboard providers instead of all 23 field
/// selectors. Value equality is preserved: collections compare by identity
/// (the controller replaces them on each matching event), scalars and derived
/// getters by `==`; an unchanged field does not rebuild its dependents.
T _readField<T>(
  Ref ref,
  Set<BoxAspect> aspects,
  T Function(BoxController box) select,
) {
  ref.watch(boxAspectsChangesProvider(aspects));
  return select(ref.watch(boxControllerProvider));
}

/// State-only shorthand. LAN getters read `lan` + dashboard fields that the
/// controller only changes under [BoxAspect.state]; a freshly-allocated list
/// getter must not re-evaluate on traffic/log ticks and compare unequal.
T _readStateField<T>(Ref ref, T Function(BoxController box) select) =>
    _readField(ref, _stateAspects, select);

/// Shared state fields, each read fresh from the controller on notification.
final dashboardProvider = Provider<Json>(
    (ref) => _readField(ref, _dashboardAspects, (b) => b.dashboard));

/// The dashboard fields the page layout and the mode card render, without the
/// counters the map carries every second (traffic totals, rates, memory).
///
/// `dashboard` is replaced on every traffic tick, so watching it directly
/// rebuilt the whole dashboard column and the mode card about once a second
/// for values none of them show. Every field here is a primitive, so the
/// record compares structurally and consumers rebuild only on a real change.
typedef DashboardLayout = ({
  String modes,
  String mode,
  bool systemProxy,
  String remote,
  String deprecated,
});

final dashboardLayoutProvider = Provider<DashboardLayout>((ref) {
  final dash = ref.watch(dashboardProvider);
  final modes = <String>[
    for (final mode in (dash['modes'] as List? ?? const []))
      if (mode is String) mode,
  ];
  return (
    modes: modes.join('\u0000'),
    mode: (dash['mode'] as String? ?? '').toLowerCase(),
    systemProxy: dash['systemProxyAvailable'] == true,
    remote: dash['remote']?.toString() ?? '',
    deprecated: [
      for (final note in rows(dash['deprecated']))
        '${note['message']}|${note['url'] ?? ''}',
    ].join('\u0000'),
  );
});

/// The dashboard fields the status card and the network-takeover row render.
///
/// `dashboard` is replaced on every traffic tick (`box.dart` assigns the whole
/// map), so watching it directly rebuilt both widgets about once a second for
/// counters neither one shows. A record compares structurally, so only a real
/// change to one of these fields notifies.
typedef DashboardStatus = ({String status, int? startedAt, bool systemProxy});
final dashboardStatusProvider = Provider<DashboardStatus>((ref) {
  final dashboard = ref.watch(dashboardProvider);
  return (
    status: dashboard['status']?.toString() ?? '',
    startedAt: (dashboard['startedAt'] as num?)?.toInt(),
    systemProxy: dashboard['systemProxy'] == true,
  );
});
/// The two dashboard scalars the Connections summary card renders, as a record.
///
/// `dashboard` is replaced on every traffic tick (~1 Hz), so watching the whole
/// map rebuilt the card every second even though the connection count and the
/// Started flag rarely move. A record compares structurally, so this notifies
/// only when one of the two values actually changes.
typedef ConnectionSummary = ({int count, bool started});
final connectionSummaryProvider = Provider<ConnectionSummary>((ref) {
  final dashboard = ref.watch(dashboardProvider);
  return (
    count: (dashboard['connections'] as num?)?.toInt() ?? 0,
    started: dashboard['status'] == 'Started',
  );
});

// Field → aspect map (matches the `_notify`/`_dispatch` sites in box.dart):
//   configurations, groups, LAN, capabilities, applyRequired, running/remote/
//   transitioning, selected*, serviceSettingsChanging, version, coreVersion,
//   coreRefShort -> state
//   systemAccentColor -> appearance (the accent event; also co-fired with state
//     on preference writes, which is why the state bridge alone was enough
//     before — both paths are covered here)
//   dashboard -> state + traffic (a counter-only push is traffic-only)
//   rates/sampleRevision -> traffic; memory -> memory; connections ->
//   connections; logs -> logs; logcat -> logcat; testSession -> testSession;
//   ruleSetsStatus -> ruleSetsStatus.
final configurationsProvider = Provider<List<Json>>(
    (ref) => _readField(ref, _stateAspects, (b) => b.configurations));
final groupsProvider = Provider<List<Json>>(
    (ref) => _readField(ref, _stateAspects, (b) => b.groups));
final connectionsProvider = Provider<List<Json>>(
    (ref) => _readField(ref, _connectionsAspects, (b) => b.connections));
final logsProvider = Provider<List<Json>>(
    (ref) => _readField(ref, _logsAspects, (b) => b.logs));
final logcatProvider = Provider<List<Json>>(
    (ref) => _readField(ref, _logcatAspects, (b) => b.logcat));
final testSessionProvider = Provider<Json>(
    (ref) => _readField(ref, _testSessionAspects, (b) => b.testSession));

/// The slice of [testSessionProvider] the Proxies cards actually render.
///
/// A test relay replaces the whole session map about every 200 ms, but a card
/// only reads `running` and its node's row `phase` — progress counters and the
/// speed envelope change without the visible phases moving. The record is a
/// structural `id:phase` summary, so a tick with unchanged phases is a no-op
/// for the page. Nodes' delays still come from `groupsProvider`, never here.
typedef ProxyTestSessionView = ({bool running, String phases});

final proxyTestSessionViewProvider = Provider<ProxyTestSessionView>((ref) =>
    _readField(ref, _testSessionAspects, (b) {
      final session = b.testSession;
      final phases = <String>[
        for (final row in rows(session['rows']))
          if ((row['id'] as num?)?.toInt() case final int id)
            '$id:${row['phase'] ?? ''}',
      ]..sort();
      return (
        running: session['running'] == true,
        phases: phases.join('\u0000'),
      );
    }));
/// Last rule-set update status pushed by the kernel worker. Replaced only on
/// [BoxAspect.ruleSetsStatus], so the routing caption stays out of the 1 Hz ticks.
final ruleSetsProvider = Provider<Json>(
    (ref) => _readField(ref, _ruleSetsAspects, (b) => b.ruleSetsStatus));
final memoryProvider = Provider<Json>(
    (ref) => _readField(ref, _memoryAspects, (b) => b.memory));
final lanProvider = Provider<Json>(
    (ref) => _readStateField(ref, (b) => b.lan));
final capabilitiesProvider = Provider<BoxCapabilities>(
    (ref) => _readField(ref, _stateAspects, (b) => b.capabilities));
final applyRequiredProvider = Provider<String?>(
    (ref) => _readField(ref, _stateAspects, (b) => b.applyRequired));

/// Derived connection state, computed from the fresh dashboard snapshot.
/// These read dashboard fields, but `box.dart` only changes them under
/// [BoxAspect.state] (a traffic-only dashboard push leaves them untouched).
final runningProvider = Provider<bool>(
    (ref) => _readStateField(ref, (b) => b.running));
final remoteProvider = Provider<bool>(
    (ref) => _readStateField(ref, (b) => b.remote));
final transitioningProvider = Provider<bool>(
    (ref) => _readStateField(ref, (b) => b.transitioning));
final serviceSettingsChangingProvider = Provider<bool>(
    (ref) => _readStateField(ref, (b) => b.serviceSettingsChanging));

/// The selected profile id, derived from the dashboard (state-only fields).
final selectedConfigurationIdProvider = Provider<int>(
    (ref) => _readStateField(ref, (b) => b.selectedConfigurationId));

/// The selected profile row, derived from the fresh profiles + dashboard.
final selectedProfileProvider = Provider<Json?>(
    (ref) => _readStateField(ref, (b) => b.selectedConfiguration));

/// Version / core identity strings, populated on `ready`.
final versionProvider = Provider<String>(
    (ref) => _readStateField(ref, (b) => b.version));
final coreVersionProvider = Provider<String>(
    (ref) => _readStateField(ref, (b) => b.coreVersion));
final coreRefShortProvider = Provider<String>(
    (ref) => _readStateField(ref, (b) => b.coreRefShort));
/// The accent event changes this under `appearance`; preference writes also
/// notify `state`+`appearance`, so listening to appearance alone covers both.
final systemAccentColorProvider = Provider<int>(
    (ref) => _readField(ref, _appearanceAspects, (b) => b.systemAccentColor));

/// Traffic snapshot: the histories are mutated in place, so the revision is
/// part of the value (a record, so it has structural equality) to make
/// Riverpod's comparison notice new samples.
typedef TrafficSnapshot = ({Json rates, Json dashboard, int revision});

final trafficProvider = Provider<TrafficSnapshot>((ref) =>
    _readField(ref, _trafficAspects, (b) =>
        (rates: b.rates, dashboard: b.dashboard, revision: b.sampleRevision)));

// ---------------------------------------------------------------------------
// P14-B: component-layer derived providers.
//
// Components used `context.box` (the `state` aspect) for a handful of derived
// getters that had no field provider of their own. Each provider below is a
// read of the app-owned [BoxController] through the same one-way bridge as the
// page-layer providers — no data is copied into Riverpod and nothing is ever
// written back. They exist so a component can `ref.watch` the exact value it
// renders instead of subscribing to every state change via `watchBoxState()`.
// ---------------------------------------------------------------------------

/// Derived LAN getters (all from the `state` aspect `lan` + dashboard fields).
///
/// These use the state-aspect bridge rather than the all-aspect one: every
/// input (`lan`, `remote`, `running`, `selectedConfigurationId`, `lanChanging`)
/// changes only under [BoxAspect.state], and the list getters allocate a fresh
/// list on each evaluation. Listening to the all-aspect bridge would therefore
/// rebuild every consumer on each traffic/log tick while it renders nothing
/// new. The state bridge carries the same controller notification, so no update
/// is lost.
final lanAddressesProvider = Provider<List<String>>((ref) => _readStateField(ref, (b) => b.lanAddresses));
final lanCopyTextProvider = Provider<String?>((ref) => _readStateField(ref, (b) => b.lanCopyText));
final lanProxyEndpointsProvider = Provider<List<String>>((ref) => _readStateField(ref, (b) => b.lanProxyEndpoints));
final canSetLanProxyProvider = Provider<bool>((ref) => _readStateField(ref, (b) => b.canSetLanProxy));
final lanChangingProvider = Provider<bool>((ref) => _readStateField(ref, (b) => b.lanChanging));
