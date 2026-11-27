# The B-box bridge

> Status 2026-11-19 (P13): current. `Capabilities.kt` is the source of truth for what exists; `tools/diagnostics/channel_audit.py` (wired into CI) enforces the Dart/Kotlin contract on every push. Earlier revisions of this document described an AIDL/SagerConnection service with a `ProxyInstance`/`TrafficLooper` core; none of that exists any more — see "Kernel ownership" below.

The ported interface (`:bboxui`) renders one immutable snapshot and sends every gesture through one object. This document describes the layer in `app/src/main/java/io/flrone/bridge` that assembles that snapshot and dispatches those gestures, and how it relates to the Dart-owned kernel and data.

## Why a bridge at all

The B-box screens (FlClash's) are written against a controller that exposes

* a snapshot — `dashboard`, `groups`, `profiles`, `preferences`, traffic history, logs, connections;
* an action bus — `box.act('mode.set', {...})`, `box.act('service.start')`, `box.act('proxy.select', {...})`;
* change notifications — one flow per aspect, so a screen rebuilds only what changed.

Throne's backend is spread across the preference store (`DataStore`), the profile/group repositories, the routing profile and the kernel service. The bridge gives the screens the first shape: it mirrors the pieces into one immutable `FlroneUiState`, publishes change events, and routes actions to the right owner without the UI talking to databases or the VPN service directly.

## Shape (P12)

```
  UI engine (Flutter)                      service engine (headless Flutter)
  ┌────────────────────────────┐           ┌──────────────────────────────────┐
  │ FlroneBridge / FlroneCatalog   │           │ KernelService + KernelWorker      │
  │ FlroneEgress / FlroneCommands  │  events   │ ThroneKernel — sole FFI owner     │
  │ FlronePlatformBridge (channels) │◄──────────│ (start/stop/reload, status, tests) │
  └─────────────┬──────────────┘           └──────────────────────────────────┘
                │ io.flrone/box channel                 ▲ io.flrone/service
                ▼                                       │ (in-process RPC)
  Android platform: VpnService fd, notifications, SAF, PackageManager, Logcat,
  prefs/data.path, profile/route documents
```

* `Capabilities.kt` is the single manifest of which channels/actions are wired.
* `channel_audit.py` cross-checks every Dart call against a Kotlin `when (call.method)` handler and every Kotlin `emit` against a Dart consumer; dynamic sites are gated by an explicit allowlist.

| File | Role |
| --- | --- |
| `FlroneBridge.kt` | Mirrors service state (delivered in-process by `BaseService`), the catalog and repo listener callbacks into `FlroneUiState`; debounces bursts, ticks run time/memory once a second. |
| `FlroneCatalog.kt` | Maps a Throne group to a B-box group and its members to nodes; a subscription group is also a B-box profile card with quota/expiry. Profiles come from the Dart-owned document via `DartProfileStore`, not from a reconstructable `ProfileManager` snapshot. |
| `FlroneTrafficMeter.kt` | Turns the kernel's status snapshot into dashboard rates, totals and the two 30-point sparklines (one sample/second). |
| `FlroneMode.kt` | The outbound mode switch, implemented as a routing-profile rewrite (see below). |
| `FlroneEgress.kt` | Outbound IP / country / organisation, probed through the running mixed inbound or the phone's own connection while stopped; several sources are raced under an 8 s budget and the winner is named on the wire. |
| `FlroneCommands.kt` | The write half: start/stop, mode, selection, tests, subscription refresh, delete, open URL. |
| `FlroneKernel.kt` | Builds the `StartOptions` payload from the Dart-owned profile document and forwards Android-side duties (VPN fd, Wi-Fi/SSID, reload/stop signals) into the service engine. Holds no kernel handle. |
| `app/.../flutter/FlronePlatformBridge.kt` | The UI engine's channel host: turns the bridge state into `dashboard` / `rates` / `profiles` / `groups` events and the actions into calls the Flutter screens make. |
| `EventPump.kt` | The one outbound queue behind every event the UI engine pushes: `state` (never evicted while there is room), 256-entry `priority` and `bulk` lanes, drained at 32 messages or every 16 ms with one bulk turn after eight priority messages. The bulk lane encodes on the producing thread and only while a listener is attached, so an unwatched feed costs nothing. Pure JVM; `FlronePlatformBridge` supplies the `Handler` adapter. |
| `app/.../flutter/ServiceBridge.kt`, `KernelServiceActions.kt` | The service engine's channel host (~15 kernel methods); the implementation lives once in `KernelServiceActions`. |

## Data mapping (the live snapshot)

| B-box | Source | Note |
| --- | --- | --- |
| `dashboard.status` | `DataStore.serviceState` + the service's `profileName` | `startedAt` is stamped when the state first becomes `Connected`. |
| `dashboard.modes` / `mode` | `FlroneMode` (configuration store) | Rule / Global / Direct, see below. |
| `dashboard.groups[]` | Dart profiles document (`DartProfileStore`) | `selected` is `DataStore.selectedProxy`. |
| node `delay` / `testedAt` | the profile document's `latency` / `latencyAt` | Stored in ms. |
| `dashboard.profiles[]` | subscription groups | `traffic` / `expiry` from `groups.sub_metadata_json`. |
| `dashboard.egress` | `FlroneEgress` | IP, country, organisation, ASN, family, answering endpoint. |
| `dashboard.memory` | `Runtime` + core `/memory` (`FlroneApi.memory`) | `core`/`rss`; `app`/`heapInuse` from the host heap. |
| `dashboard.intranet` | `lanWire` / `lanSet` | Mixed inbound "Allow LAN" and port. |

## Actions

`box.act(...)` / `box.call(...)` names are the channel contract; handlers live in `FlronePlatformBridge.kt` (UI engine) or `ServiceBridge.kt` (service engine) and are audited by `channel_audit.py`. Representative writes:

| Action | Implementation |
| --- | --- |
| `toggleService` | Starts/stops the service; a start with nothing selected is refused. |
| `setMode` | `FlroneMode.set` then reload when running. |
| `selectProxy(group, tag)` | Writes `selectedProxy` + `currentProfile` and notifies the kernel so a running box switches instead of restarting. |
| `testNodeAwait` | Starts a `TestSessionClient` session against the specified group/node; results are published back as events. |
| `groups.visible` | `FlroneGroupsWire` sends group **counts** every other screen renders and, **only while the Proxies screen is open**, the node rows — that larger shape rides the bulk lane, so the UI decodes it inline or on an isolate above 50 KiB (`bulkDecodeBytes`). The outbound picker's flat node metadata is no longer a channel: the Go `groupNodes` action reads the Dart-owned `profiles.json` (ADR 0004 P4). |
| `ui.visible` | The UI lifecycle observer tells the bridge whether a frame can be drawn; while hidden the 1 s rates tick skips its dashboard snapshot. The traffic attribution poller is deliberately not gated: it feeds the ledger, not a frame. |
| `speedTest.*` | `FlroneSpeedTest` runs a Bettbox speed test in the kernel through the running instance's own outbound; query/cancel/servers/outbounds are separate actions. |
| `backup.*` | The create/restore write path is Dart-owned (`services/backup_write.dart`); the host keeps only the read-only SAF/THRN decode (`FlroneBackup.open` / `openJson`). On stock Android (no public `libsqlite3.so`, so the Dart ffi path is null) create/restore use narrow host data-plane methods implemented by `FlroneRoomSnapshot`: `backup.container` (parameterized SQL Dart authors, host executes on the backup's own container file — ADR 0006 stage C2c1 retired `data.roomSql` and its `openRoom`; only files in the app's own storage are opened, `sager_net.db`, the documents directory and the rule-set catalog are refused), `settings.snapshot`/`markers.snapshot` (the live documents the export carries) and `settings.restore`/`markers.restore` (the merge + whole-set replace, including the selection repair). ADR 0006 stage C2c2a removed the live-Room half: profiles/groups come from Dart's `profiles.json`, routes from the kernel's route documents, settings/markers from their documents. Dart maps/stages rows and is the only writer of profiles.json. |
| `profiles.platform` | The profile editor's ONE platform duty: `{op, payload}` into `FlroneProfileDuty` (parsing/validation, subscription queue, selection settings, auto-selector runtime). Data writes still go through `profiles.applyDocument` into `ProfileStoreSource.apply`; the Dart document is the authority for profiles/groups. `platform_duty_audit.py` holds the op table to the Dart call sites. |

The one-time `data.legacyRows` read was removed with the legacy seed chain
(`LegacyRoomReader`, the Dart migration and `reMigrateFromRoom`): a missing
`profiles.json` is now an empty document, and a `.thrbackup` restore is the
supported way to bring old data back.

## Outbound mode

Throne has no `route.final` switch; a route profile's default outbound and rule list decide where traffic goes. `CoreConfigs.buildMain` rewrites the profile it hands to the generator: **Rule** uses it as saved; **Global** drops the rules and defaults to `proxy`; **Direct** defaults to `direct`. The `hijack-dns` rule survives every mode, and the rewrite is on a copy.

## Kernel ownership

The kernel runs in a headless service Flutter engine (`ServiceEngineManager` + `serviceMain`), not in the UI engine and not behind AIDL:

* `KernelService` + `KernelWorker` + `ThroneKernel` (in `flutter/lib/core/`) are the sole FFI owner. The C ABI is `libthrone.so` via `throne_*` exports; `tools/bindgen/live_exports.txt` is the single source of truth (59 live exports), checked three ways by `symbol_audit.py`.
* The UI engine talks to it over `IsolateNameServer` (`KernelProxy`, `{id,method,data}` / `{id,result}` / `{type:'event'}` envelopes). Rebuilding the UI engine just reconnects; it does not restart the kernel.
* Android duties (VPN fd, notifications, widget/tile/shortcuts, Wi-Fi state) are in-process. A stop/reload from a widget or notification signals the service engine through `FlroneKernel.onStopWanted` / `onReloadWanted`; there is no host-held FFI handle to close and no "adopt after engine death" path.
* The kernel's status snapshot is the sole source of the notification speed line. `state.stats` publishes it into the same shape the removed service-side traffic looper produced.
* The heartbeat asks `throne_Instance_alive` before counting a miss, so a read that races a closing box cannot trigger a false restart; lifecycle lines go to `core.log` for post-hoc diagnosis.

## The data plane moves to Dart

`data/sqlite.dart` is the platform SQLite over `dart:ffi` (no `sqflite` — the AAR cannot register plugins), and after ADR 0006 stage C2c2b2 its only caller is the backup writer (THRN container transport on desktop/CI). `data.path` still answers the app's database path as a *location fact* (Dart derives `files/documents` from it), but nothing opens a live database through it: the live stores are `SettingsJsonStore` (settings/markers), the kernel's Go route documents, and `profiles.json` (ADR 0006).

The retired `sager_net.db` has **no reader in the app any more**. The one-time
`LegacyRoomReader` / `data.legacyRows` seed chain (profiles and settings
documents) was removed in v4.17.x: a missing document is simply an empty
document, and restoring a `.thrbackup` is the supported migration path for an
old install. The UI settings documents (`ui_settings.json`/`preferences.json`)
were retired in this change: they were only ever seeded from SharedPreferences and
merged with prefs winning, so they were a dead duplicate of SharedPreferences.
`HostFactsStore` now owns the single Kotlin-written host facts document
(`host_facts.json`); it never touches the old database.

Backups and WebDAV are Dart-owned (`services/backup_*`), with `FlroneBackup` limited to read-only THRN/SAF decoding. P14 keeps backups working through the parameterized SQL transport and the settings/markers document ops — no live-Room op and no second SQLite (which would need untestable JNI and contradict ADR 0005's single-writer rule). `legacy_reader_audit.py` now pins the retirement: no Room residue, no legacy seed or UI-document chain, and the removed symbols fail the build if they return.

## Removed instead of stubbed (v4.14.0)

The B-box-only screens — `terminal`, `capture.*`, `remote.*`, `reports`, the `stun`/`quality`
tools, `endpoints` (tailscale/openvpn/openconnect/usbip) and `taildrop` — are **deleted**, not
left as `unsupported` fall-throughs: their pages, `box_api` extensions, controller state and
`Capabilities.kt` flags went together (CHANGELOG 4.14.0, "Removed"). `Capabilities` stays the
single source of truth and now advertises only screens this bridge answers.

Wired since the earlier drafts: connections and logs (`FlroneApi.connections`, `FlroneLogs`), profile import (`addProfile`, scanner/file flows), the per-node probe (`dashboard.probe.*`), backup read/decode (`files.open`), and the kernel speed-test surface.
