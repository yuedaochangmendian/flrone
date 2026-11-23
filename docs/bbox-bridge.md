# The B-box bridge

> Status 2026-11-19 (P13): current. `Capabilities.kt` is the source of truth for what exists; `tools/diagnostics/channel_audit.py` (wired into CI) enforces the Dart/Kotlin contract on every push. Earlier revisions of this document described an AIDL/SagerConnection service with a `ProxyInstance`/`TrafficLooper` core; none of that exists any more — see "Kernel ownership" below.

The ported interface (`:bboxui`) renders one immutable snapshot and sends every gesture through one object. This document describes the layer in `app/src/main/java/io/flrone/bridge` that assembles that snapshot and dispatches those gestures, and how it relates to the Dart-owned kernel and data.

## Why a bridge at all

The B-box screens (FlClash's) are written against a controller that exposes

* a snapshot — `dashboard`, `groups`, `profiles`, `preferences`, traffic history, logs, connections;
* an action bus — `box.act('mode.set', {...})`, `box.act('service.start')`, `box.act('proxy.select', {...})`;
* change notifications — one flow per aspect, so a screen rebuilds only what changed.

Throne's backend is spread across the preference store (`DataStore`), the profile/group repositories, the routing profile and the kernel service. The bridge gives the screens the first shape: it mirrors the pieces into one immutable `BboxUiState`, publishes change events, and routes actions to the right owner without the UI talking to databases or the VPN service directly.

## Shape (P12)

```
  UI engine (Flutter)                      service engine (headless Flutter)
  ┌────────────────────────────┐           ┌──────────────────────────────────┐
  │ BboxBridge / BboxCatalog   │           │ KernelService + KernelWorker      │
  │ BboxEgress / BboxCommands  │  events   │ ThroneKernel — sole FFI owner     │
  │ ThroneBoxBridge (channels) │◄──────────│ (start/stop/reload, status, tests) │
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
| `BboxBridge.kt` | Mirrors service state (delivered in-process by `BaseService`), the catalog and repo listener callbacks into `BboxUiState`; debounces bursts, ticks run time/memory once a second. |
| `BboxCatalog.kt` | Maps a Throne group to a B-box group and its members to nodes; a subscription group is also a B-box profile card with quota/expiry. Profiles come from the Dart-owned document via `DartProfileStore`, not from a reconstructable `ProfileManager` snapshot. |
| `BboxTrafficMeter.kt` | Turns the kernel's status snapshot into dashboard rates, totals and the two 30-point sparklines (one sample/second). |
| `BboxMode.kt` | The outbound mode switch, implemented as a routing-profile rewrite (see below). |
| `BboxEgress.kt` | Outbound IP / country / organisation, probed through the running mixed inbound or the phone's own connection while stopped; several sources are raced under an 8 s budget and the winner is named on the wire. |
| `BboxCommands.kt` | The write half: start/stop, mode, selection, tests, subscription refresh, delete, open URL. |
| `BboxKernel.kt` | Builds the `StartOptions` payload from the Dart-owned profile document and forwards Android-side duties (VPN fd, Wi-Fi/SSID, reload/stop signals) into the service engine. Holds no kernel handle. |
| `app/.../flutter/ThroneBoxBridge.kt` | The UI engine's channel host: turns the bridge state into `dashboard` / `rates` / `profiles` / `groups` events and the actions into calls the Flutter screens make. |
| `EventPump.kt` | The one outbound queue behind every event the UI engine pushes: `state` (never evicted while there is room), 256-entry `priority` and `bulk` lanes, drained at 32 messages or every 16 ms with one bulk turn after eight priority messages. The bulk lane encodes on the producing thread and only while a listener is attached, so an unwatched feed costs nothing. Pure JVM; `ThroneBoxBridge` supplies the `Handler` adapter. |
| `app/.../flutter/ServiceBridge.kt`, `KernelServiceActions.kt` | The service engine's channel host (~15 kernel methods); the implementation lives once in `KernelServiceActions`. |

## Data mapping (the live snapshot)

| B-box | Source | Note |
| --- | --- | --- |
| `dashboard.status` | `DataStore.serviceState` + the service's `profileName` | `startedAt` is stamped when the state first becomes `Connected`. |
| `dashboard.modes` / `mode` | `BboxMode` (configuration store) | Rule / Global / Direct, see below. |
| `dashboard.groups[]` | Dart profiles document (`DartProfileStore`) | `selected` is `DataStore.selectedProxy`. |
| node `delay` / `testedAt` | the profile document's `latency` / `latencyAt` | Stored in ms. |
| `dashboard.profiles[]` | subscription groups | `traffic` / `expiry` from `groups.sub_metadata_json`. |
| `dashboard.egress` | `BboxEgress` | IP, country, organisation, ASN, family, answering endpoint. |
| `dashboard.memory` | `Runtime` + core `/memory` (`BboxApi.memory`) | `core`/`rss`; `app`/`heapInuse` from the host heap. |
| `dashboard.intranet` | `lanWire` / `lanSet` | Mixed inbound "Allow LAN" and port. |

## Actions

`box.act(...)` / `box.call(...)` names are the channel contract; handlers live in `ThroneBoxBridge.kt` (UI engine) or `ServiceBridge.kt` (service engine) and are audited by `channel_audit.py`. Representative writes:

| Action | Implementation |
| --- | --- |
| `toggleService` | Starts/stops the service; a start with nothing selected is refused. |
| `setMode` | `BboxMode.set` then reload when running. |
| `selectProxy(group, tag)` | Writes `selectedProxy` + `currentProfile` and notifies the kernel so a running box switches instead of restarting. |
| `testNodeAwait` | Starts a `TestSessionClient` session against the specified group/node; results are published back as events. |
| `groups.visible` | `BboxGroupsWire` sends group **counts** only while the Proxies screen is open; `groups.nodes` sends flat node metadata for the outbound pickers. |
| `speedTest.*` | `BboxSpeedTest` runs a Bettbox speed test in the kernel through the running instance's own outbound; query/cancel/servers/outbounds are separate actions. |
| `backup.*` | The create/restore write path is Dart-owned (`services/backup_write.dart`); the host keeps only the read-only SAF/THRN decode (`BboxBackup.open` / `openJson`). On stock Android (no public `libsqlite3.so`, so the Dart ffi path is null) create/restore use three narrow host data-plane methods implemented by `BboxRoomSnapshot`: `data.roomSnapshot` (DAO reads), `data.roomSql` (parameterized SQL Dart authors, host executes on a temp snapshot / Room's own connection), `data.applyRoomSnapshot` (DAO writes in one transaction — routes/settings/markers only). Dart maps/stages rows, is the only writer of profiles.json, and a restore writes profiles/groups there directly (ADR 0006 stage B), passing the restored id sets the selection repair needs. |
| `profiles.platform` | The profile editor's ONE platform duty: `{op, payload}` into `BboxProfileDuty` (parsing/validation, subscription queue, selection settings, auto-selector runtime). Data writes still go through `profiles.applyDocument` into `ProfileStoreSource.apply`; the Dart document is the authority for profiles/groups. `platform_duty_audit.py` holds the op table to the Dart call sites. |
| `data.roomProfiles` | The one-time Room export for the Dart profile document. An Android app cannot dlopen the platform SQLite (`libsqlite3.so` is absent from AOSP, `libsqlite.so` is not public), so Dart's ffi reader cannot open Room; the process that owns Room hands the rows over in the same column shape. |

## Outbound mode

Throne has no `route.final` switch; a route profile's default outbound and rule list decide where traffic goes. `CoreConfigs.buildMain` rewrites the profile it hands to the generator: **Rule** uses it as saved; **Global** drops the rules and defaults to `proxy`; **Direct** defaults to `direct`. The `hijack-dns` rule survives every mode, and the rewrite is on a copy.

## Kernel ownership

The kernel runs in a headless service Flutter engine (`ServiceEngineManager` + `serviceMain`), not in the UI engine and not behind AIDL:

* `KernelService` + `KernelWorker` + `ThroneKernel` (in `flutter/lib/core/`) are the sole FFI owner. The C ABI is `libthrone.so` via `throne_*` exports; `tools/bindgen/live_exports.txt` is the single source of truth (59 live exports), checked three ways by `symbol_audit.py`.
* The UI engine talks to it over `IsolateNameServer` (`KernelProxy`, `{id,method,data}` / `{id,result}` / `{type:'event'}` envelopes). Rebuilding the UI engine just reconnects; it does not restart the kernel.
* Android duties (VPN fd, notifications, widget/tile/shortcuts, Wi-Fi state) are in-process. A stop/reload from a widget or notification signals the service engine through `BboxKernel.onStopWanted` / `onReloadWanted`; there is no host-held FFI handle to close and no "adopt after engine death" path.
* The kernel's status snapshot is the sole source of the notification speed line. `state.stats` publishes it into the same shape the removed service-side traffic looper produced.
* The heartbeat asks `throne_Instance_alive` before counting a miss, so a read that races a closing box cannot trigger a false restart; lifecycle lines go to `core.log` for post-hoc diagnosis.

## The data plane moves to Dart

`flutter/lib/data/` opens `sager_net.db` read-only through the platform's `libsqlite3.so` over `dart:ffi` (`data/sqlite.dart`; no `sqflite` — the AAR cannot register plugins). `data.path` answers the file path and the schema version Room actually opened. Reads that are live today include route profiles (`RouteProfilesSource`) and the profiles/groups document (`ProfileStore`); Room remains the authority for settings/routes and a migration source for profiles. Two gates keep this honest:

* `schema_audit.py` compares Room's `@Database(version=…)` with `roomSchemaVersion` and column-checks DAO SQL against Room's exported schema JSON.
* On Android the ffi reader is normally unavailable (non-public platform library), so essential paths read Room through the host: `data.roomProfiles` for the profile migration. The ffi reader remains for desktop/CI and OEM ROMs that ship the soname; `ProfileStoreSource` uses whichever answers.
* `DataLayer.attach` answers null on any failure (no library/path, unexpected schema) so the caller keeps using the channel — the same contract `ThroneKernel.isAvailable` has for the kernel side.

Room's data tables are opened read-only from Dart; writes go through the document/channel path owned by their phase. Backups and WebDAV are Dart-owned (`services/backup_*`), with `BboxBackup` limited to read-only THRN/SAF decoding. A stock Android app cannot `dlopen` SQLite (`libsqlite3.so` absent from AOSP, `libsqlite.so` not in `public.libraries.txt`), so `Sqlite.open()` is null there; P14 keeps backups working by routing create/restore through `BboxRoomSnapshot`'s DAO reads/writes and a parameterized SQL transport instead of embedding a second SQLite (which would need untestable JNI and contradict ADR 0005's single-writer rule). `room_snapshot_audit.py` holds the host mappers to Dart's desktop column list and forbids raw SQL literals in the Kotlin bridge.

## Removed instead of stubbed (v4.14.0)

The B-box-only screens — `terminal`, `capture.*`, `remote.*`, `reports`, the `stun`/`quality`
tools, `endpoints` (tailscale/openvpn/openconnect/usbip) and `taildrop` — are **deleted**, not
left as `unsupported` fall-throughs: their pages, `box_api` extensions, controller state and
`Capabilities.kt` flags went together (CHANGELOG 4.14.0, "Removed"). `Capabilities` stays the
single source of truth and now advertises only screens this bridge answers.

Wired since the earlier drafts: connections and logs (`BboxApi.connections`, `BboxLogs`), profile import (`addProfile`, scanner/file flows), the per-node probe (`dashboard.probe.*`), backup read/decode (`files.open`), and the kernel speed-test surface.
