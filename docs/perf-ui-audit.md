# UI rebuild audit (Phase 3 — static, no device profiling)

Scope: how `BoxController` notifications fan out to Riverpod/`InheritedModel`
consumers, which widgets rebuild for which `BoxAspect`, the top rebuild
hotspots, and the narrow fixes landed in this round. All line numbers refer to
the tree at this phase; they are static facts, not measurements. Frequency
figures are the documented cadences of the feeds (`docs/perf-bridge-audit.md`,
`box.dart` comments), not device samples — see "Needs device numbers" below.

## 1. Notification model (why the fan-out is broad)

`BoxController` has two broadcast paths:

- `super.notifyListeners()` (`box.dart:663`) fires on **every** aspect via
  `_notify` / `_dispatch`. `BoxScope` (`box.dart:1960-1968`) listens to it and
  rebuilds its `InheritedModel` with a fresh revision vector. Any widget using
  `context.box` (default aspect `state`) or `context.watchBox(aspect)` depends on
  that model and rebuilds when its aspect's revision moves.
- `_stateChanges` (`box.dart:322,328,662`) fires only when the `state` aspect is
  present. This is the source bridged into Riverpod.

Riverpod bridges (`flutter/lib/providers/box_providers.dart`):

- `boxStateChangesProvider` (`:42`) forwards `_stateChanges` only — this is what
  `watchBoxState()` (`:168`, `:176`) subscribes to. Despite its name, a
  `watchBoxState()` consumer rebuilds only on `state`, **not** on
  traffic/logs/testSession.
- `boxChangesProvider` (`:125`) forwards *all* aspects. `_readField` (`:178`)
  re-evaluates every field provider on every aspect; Riverpod's `==` comparison
  then decides whether a dependent rebuilds.
- Field providers re-read fresh from the controller; collections (`dashboard`,
  `rates`, `testSession`, …) are **replaced wholesale** by `box.dart`, so their
  identity changes on each push and Riverpod treats them as changed even when
  the rendered scalars are unchanged. This is the root of the 1 Hz rebuilds
  fixed below.

## 2. Aspect → source → consumer map

`_notify` / `_dispatch` sources (`flutter/lib/box.dart`):

| Aspect | Source (`file:line`) | Cadence | Riverpod field provider(s) | `watchBoxState()` consumers |
| --- | --- | --- | --- | --- |
| `state` | dashboard non-counter fields `:1502`; lan `:891,903,917`; settings/preferences `:1295,1571`; groups `_applyGroups` `:1833`; many write APIs `:1214,1252,1266,1314,1323,1330,1346,1368` | event-driven, bursts on connect/switch | `settingsProvider`, `preferencesProvider`, `dashboardProvider`, `configurationsProvider`, `groupsProvider`, `runningProvider`, `remoteProvider`, `transitioningProvider`, `selectedConfigurationIdProvider`, `selectedProfileProvider`, `capabilitiesProvider`, `applyRequiredProvider`, LAN/capability getters (`box_providers.dart:65-86,206-286,309-325`) | all 23 `watchBoxState()` sites (see §4) |
| `traffic` | dashboard counters-only `:1502`; `rates` `:1592`; `memory` branch `:1476` (counter-only memory) | ~1 Hz while core runs | `trafficProvider` (`:286`), `dashboardProvider`, `memoryProvider` | none directly — **but `dashboardProvider` consumers rebuild** |
| `memory` | `case 'memory'` `:1472-1476` | sampler-driven (page-visible subscription) | `memoryProvider` (`:257`) | none |
| `connections` | `_applyConnections` `:1799` (also bulk `:1783`) | 300 ms batched, page-visible | `connectionsProvider` (`:246`) | none |
| `logs` | `_applyLogs` `:1749,1875,1891,1925` (bulk `:1787`) | ~16 ms batches, 300 ms coalesced | `logsProvider` (`:247`) | none |
| `logcat` | `_applyLogcat` `:1908` (bulk `:1789`) | batched | `logcatProvider` (`:248`), `appLogsHiddenProvider` (`:251`) | none |
| `testSession` | `case 'testSession'` `:1560` | ~200 ms during a test | `testSessionProvider` (`:253`) | none directly |
| `ruleSetsStatus` | `case 'ruleSets'` `:1565` | one-shot post-start | `ruleSetsProvider` (`:256`) | none |
| `appearance` | `:281,1295,1571,1576` (`systemAccent`) | event-driven | `preferencesProvider` | none directly |

Key consumer sites for the high-frequency providers:

- `dashboardProvider`: `components/connections_panel.dart:20` (now narrowed),
  plus the derived `dashboardStatusProvider`, `dashboardLayoutProvider`,
  `runningProvider`, `remoteProvider`, `transitioningProvider`,
  `selectedConfigurationIdProvider`, `selectedProfileProvider`,
  `connectionSummaryProvider` (all in `box_providers.dart:203-270`).
- `trafficProvider`: `pages/dashboard.dart:390` (`_SpeedTile` ×2).
- `testSessionProvider`: `pages/proxies.dart:641`, `pages/test_panel.dart:187`,
  `pages/speed_test.dart:330` (via `ref.read` + local `setState`).
- `connectionsProvider`: `components/connections_panel.dart:24`,
  `pages/connections.dart:500`.
- `logsProvider` / `logcatProvider`: `pages/logs.dart:90,150-151,284-285` via
  `ref.read` + `ref.listen` (not a rebuild subscriber for the tail rows).

## 3. Top 5 rebuild hotspots (ranked)

Ranking combines cadence × subtree size × whether the fields actually change.
Frequencies are documented feed cadences, not device measurements.

1. **`ConnectionsPanel`** (`components/connections_panel.dart:17`) — consumed
   `dashboardProvider` + `connectionsProvider`; the dashboard map is replaced
   on every traffic tick (~1 Hz), so the card rebuilt every second while
   rendering only two scalars (`connections`, `status`). Highest value
   narrow-conversion target: small but always on the dashboard, and the
   rebuild was provably unnecessary on counter-only ticks. **Fixed this round**
   via `connectionSummaryProvider`.

2. **`_SpeedTile` ×2** (`pages/dashboard.dart:383-445`) — watches
   `trafficProvider` + `boxControllerProvider` at ~1 Hz. Unlike #1 this is a
   *real* 1 Hz rebuild: the tile renders the rate and the running total that
   move every tick. Two tiles × a `LineChart` with a `RepaintBoundary`
   (`dashboard.dart:411`, `line_chart.dart:65`) already isolate paint; the
   rebuild itself is required. Listed because it is the most-visible 1 Hz
   rebuild and the place a device trace should be taken first to confirm the
   boundaries are working.

3. **`ProxiesPage.build`** (`pages/proxies.dart:639-641`) — watches
   `testSessionProvider` (~200 ms during a batch test) plus `watchBoxState()`
   (`state`). Every session relay rebuilds the whole page, re-indexes
   `_sessionRowsById` (already O(n) once per build, a prior fix) and rebuilds
   the visible grid. It is large and animated, so this is the highest-risk
   hotspot on a test run; no structural change landed this round because the
   session rows genuinely change per relay and narrowing further would require
   splitting the page (out of scope). Device numbers needed.

4. **`TestPanelPage.build`** (`pages/test_panel.dart:184-187`) — same pattern:
   `testSessionProvider` (~200 ms) + `watchBoxState()` (`state`). It renders
   live progress from the session map, so most rebuilds carry new data. The
   `watchBoxState()` here is redundant for rendering (`box` is used only inside
   callbacks; every callback reads `ref.read(boxControllerProvider)`), but
   removing it is behavior-preserving only if no hidden dependency exists —
   left for a follow-up with test coverage, not landed in this round.

5. **`StatusPanel`** (`components/status_panel.dart:645-653`) — already watches
   five *narrow* record/scalar providers, so a traffic tick that leaves
   status/remote/profile unchanged does not rebuild it. It still holds its own
   `stateChanges` listener for route sync (`status_panel.dart:170-175`), but
   that schedules work rather than rebuilding. Listed as the "already fixed"
   baseline: it is the model the other rebuilds should be nudged toward.

## 4. Single-aspect call sites that could narrow

All 23 `watchBoxState()` sites subscribe to the whole `state` bridge. Those
that read only one or two fields are candidates for an existing or new narrow
provider (the field providers in `box_providers.dart` already expose most of
them):

- `components/connectivity/connectivity_page.dart:113` — read only
  `settings['serviceMode']`. **Fixed this round** via `serviceModeProvider`.
- `pages/settings_pages.dart:32` (`InboundPage`) — `settings['serviceMode']`
  and `dashboard['systemProxyAvailable']`; the latter is already in
  `dashboardLayoutProvider.systemProxy`. Replaceable by
  `serviceModeProvider` + `dashboardLayoutProvider.select(...)`.
- `pages/settings_pages.dart:72` (`TunPage`) — only `settings['allowBypass']`;
  use `settingsProvider.select((s) => s['allowBypass'])`.
- `pages/settings_pages.dart:103` (`DnsPage`) — only
  `settings['useDnsObject']`; same `.select` pattern.
- `pages/settings.dart:149` (`_NotificationButtons`) — only
  `settingsProvider['notificationActions']` (already watched narrowly on the
  next line); the `watchBoxState()` call is redundant for rendering.
- `pages/speed_test.dart:786` — only `box.running`; replaceable by
  `runningProvider`.
- `pages/test_panel.dart:186` — `box` used only in callbacks that
  `ref.read`; replaceable by `ref.read(boxControllerProvider)` (no watch).
- `pages/configuration.dart:75` — only `box.remote` in the empty-state branch;
  replaceable by `remoteProvider`.
- `pages/network_toolbox.dart:36` — calls `watchBoxState()` only to force a
  rebuild so a setting changed inside a sheet updates the page; the one field
  it tracks (`speedTestMode`) already has its own consumer
  (`_SimpleDownloadRow`, `:224-234`). The broad watch is redundant.

Sites that legitimately need a mix of state fields were left alone:
`appearance.dart:19,96,155,213`; `backup.dart:391`;
`configuration_details.dart:130`; `configurations.dart:406,872`;
`settings_pages.dart:171,250,329`; `settings.dart:86`.

## 5. Fixes landed this round (behavior-preserving)

1. **`connectionSummaryProvider`** (`box_providers.dart`, new record provider)
   + `ConnectionsPanel` conversion. Before: rebuild on every `dashboard`
   replacement (~1 Hz), even when `connections`/`status` did not move. After:
   rebuild only when one of those two scalars changes. The structural record
   compares by value, so a rates-only tick is a no-op. The connections list
   watch is unchanged.
2. **`serviceModeProvider`** (`box_providers.dart`, new state-aspect scalar)
   + `ConnectivityPage` conversion. Before: `watchBoxState()` rebuilt the page
   on every `state` event just to read one setting. After: a scalar provider
   fed by the state bridge rebuilds only when that one string changes. The
   value is moved out of the `AnimatedBuilder` callback into `build`, so store
   notifications still rebuild the page without a mid-build `ref.watch`.
3. **`RepaintBoundary` around `SpeedGauge`** (`pages/speed_test.dart`, around
   the gauge at `:863`). The gauge runs two tickers (needle chase + connecting
   sweep, `speed_gauge.dart:200-230`) that repaint at animation rate while a
   test is connecting. It is a fixed-size circle with no child sharing its
   paint, and its parent panel rebuilds on every ~200 ms session relay. The
   boundary confines those repaints to the gauge's own layer so an animation
   frame cannot dirty the surrounding labels, buttons and outbound card. No
   layout, timing or value behavior changes.

`box.dart` was not touched; neither were the pages/fields another agent is
editing (`core/throne_kernel.dart`, `core/action.dart`, Go files).

## 6. Test coverage

`flutter/test/rebuild_isolation_test.dart` mounts a broad `dashboardProvider`
consumer and the new narrow `connectionSummaryProvider` consumer side by side
over one injected `BoxController`, with build counters *inside* each consumer
(a `ConsumerWidget` rebuilds itself, so a parent wrapper counter would miss
the provider-driven rebuild):

- a rates-only dashboard event rebuilds the broad consumer but not the narrow
  one;
- a real `connections`/`status` change rebuilds both.

Existing tests for the touched files were also run (see the validation report
in the final message).

## 7. Needs device numbers to confirm

All of the above is static. The following require the physical arm64 capture
defined in `docs/perf-baseline.md` (explicitly out of scope this phase):

- Whether the removed 1 Hz `ConnectionsPanel` rebuild caused measurable jank
  or only wasted CPU — compare dashboard idle p95 frame time and UI-thread CPU
  before/after.
- Whether the `SpeedGauge` boundary reduces dirty-region area in a real
  session relay, and whether it adds a layer that outweighs the saving on a
  low-end GPU.
- Actual cadence and burst size of `testSession` and `connections` feeds on a
  device; the ~200 ms / 300 ms figures are code-level cadences.
- Whether `ProxiesPage` / `TestPanelPage` session rebuilds exceed the 16.7 ms
  frame budget with a few hundred nodes. If they do, the next step is a
  per-group or per-row `Selector`, which is a page restructure and should be
  driven by that trace.
