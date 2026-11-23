# Transport invariants (strict full alignment)

Contracts for **section 2 (architecture / data plane)** and **section 5
(performance / transport)** of the FlClash-alignment migration. It is a status
document, not a wish list: every row says where the number or mechanism lives and
whether this tree already holds it.

Legend: **aligned** — enforced in this tree; **partial** — the mechanism exists
but one half is missing, named in the row; **pending** — not in this tree yet;
**excluded** — deliberately not ported (L4).

## L1 — numeric thresholds

Numbers are contracts only if they have one home; a literal repeated in two files
is a bug waiting to drift.

| Contract | Value | Home | Status |
| --- | --- | --- | --- |
| Bulk payload decode threshold | 50 KiB, above it `Isolate.run` | `flutter/lib/box.dart` (`bulkDecodeBytes`) | aligned |
| Host event feed lanes | state 1024 / priority 256 / bulk 256 entries | `app/src/main/java/io/flrone/bridge/EventPump.kt` (`Lane`) | aligned (#237) |
| Host event feed drain | 32 messages or 16 ms, whichever first | `EventPump.kt` (`BATCH_SIZE`, `BATCH_MILLIS`) | aligned (#237) |
| Host event feed starvation guard | one bulk message after 8 consecutive priority ones | `EventPump.kt` (`PRIORITY_BURST`) | aligned (#237) |
| Log batch window / batch cap | 16 ms / 512 lines | `flutter/lib/core/log_batch.dart` (`logBatchWindow`, `maxKernelLogBatchLines`) — shared by both engines | aligned |
| Log ring | 512 rows | `flutter/lib/core/log_batch.dart` (`logRingLimit`), `BoxController.maxLogLength` | aligned |
| Proxies node rows | bulk lane while the screen is open; 50 KiB decides inline vs `Isolate.run` | `ThroneBoxBridge.pushState`, `BoxController.bulkEventTypes` / `_applyGroups` | aligned (wave 2) |
| Process lookup concurrency | 8 in flight, cached paths take no slot | `flutter/lib/box.dart` (`maxConcurrentProcessLookups`), `common/async_gate.dart` | aligned (wave 2) |
| Connections feed ceiling | 1000 rows (the host page is a live session plus its 200-row closed ring) | `BoxController.maxConnectionRows` | aligned (wave 2) |
| UI visibility signal | `ui.visible` on every lifecycle change; hidden skips the 1 s rates sample | `main.dart`, `ThroneBoxBridge` (`uiVisible`) | aligned (wave 2) |
| IPC lag report threshold | 100 ms send→receive | `flutter/lib/core/kernel_proxy.dart` (`_lagReportMs`) | aligned |
| Frame stall / frame work / loop watchdog | 100 ms / 12 ms / 25 ms tick | `flutter/lib/core/frame_watch.dart` | aligned |
| Traffic cadence | 1 Hz core status (`rates` rides along) | `flutter/lib/core/kernel_worker.dart` heartbeat | aligned |
| Traffic window | 30 points, ≥700 ms apart | `flutter/lib/box.dart` (`trafficWindow`, `trafficSampleGap`) | aligned |
| Traffic ledger flush | 5 min (forced on background) | `flutter/lib/services/traffic_stats.dart` (`flushEvery`) | aligned |
| Action timeouts | 30 s default / 2 min start / 1 min stop+reload | `kernel_control.dart` + `kernel_proxy.dart` call sites | aligned |
| Link reconnect | 2 s delay, 5 attempts, then release ownership | `flutter/lib/core/kernel_proxy.dart` | aligned |
| Heartbeat grace / give-up | 12 s after start / 8 s without a good beat | `flutter/lib/core/kernel_worker.dart` | aligned |
| Recovery backoff | 10 s then 30 s | `flutter/lib/core/kernel_service.dart` | aligned |
| Boot-guard freshness / clear threshold | 10 min / 2 consecutive unfinished launches | `flutter/lib/services/boot_guard.dart` | aligned (this PR) |

## L2 — mechanisms

| Mechanism | What it buys | Status |
| --- | --- | --- |
| Two engines: UI engine + headless service engine | Kernel FFI never runs in the frame isolate; a dead UI engine reconnects instead of restarting the core | aligned (ADR 0004 P6) |
| Request/response bus with `{id, method, data}` and one `hello` handshake | Correlation without per-call ports; status resync on every (re)connect | aligned |
| Bulk feed wire (`StandardMessageCodec` bytes) + decode off the UI isolate | A 1500-line logcat batch is one codec message, not 1500 map copies; the Proxies node rows take the same path | aligned (#235 fixed the empty-payload flip; groups rows in wave 2) |
| Log batching in both engines (16 ms / 512) | A start's burst is one IPC message per frame budget, not per line | aligned |
| Control vs bulk priority | Kotlin host event feed: state/priority/bulk lanes, bounded, batched, with a starvation guard; the service-engine→UI IPC port still multiplexes both in one lane | aligned for the host feed (#237); **partial** for the IPC port (listed under "Later") |
| Spill (large result written to a file, path returned) | Keeps a huge result off the wire | **not needed** — the largest UI payload (`groups.visible` node rows, ~107 B/node, 3k nodes ≈ 324 KiB) now decodes on the isolate; no measured UI payload approaches 1 MiB |
| Boot guard (attempt marker → none / skipAutoSetup / clearProfile) | A launch that dies before the UI is up does not repeat itself; a loop forgets the profile | aligned (wave 1) |
| Service auto-start gate | A silent start after a launch that died before the UI came up creates the engine idle instead of auto-starting the tunnel; Dart's marker is mirrored to `documents/boot_guard.json`, the gate wants a fresh `stage: starting` (10 min), and only `quick`/`boot` starts are gated — a user start never is | aligned (wave 4) — `app/src/main/java/io/flrone/bridge/BootGate.kt`, `BaseService.startProxy` |
| Settings/markers document mounted in every process | A service started from a tile/boot (no Flutter attach) reads and writes the same `settings.json`/`markers.json` the UI does, not Room's frozen copy | aligned (wave 3) — `SagerNet.onCreate`; read-modify-write under an OS file lock (`DocumentWriteLock`) |
| Structured refusal across the engine link | A `core_<n>` code and the handler's payload reach the UI through the service-engine envelope, not only in-process | aligned (wave 3) — `coreErrorEnvelope` / `service_entry.dart` |
| FixedList ring | O(1) bounded append, one stable snapshot per batch | aligned (wave 2) — `logs`, `logcat`, `connections` (`flutter/lib/common/fixed_list.dart`) |
| Async gate for process lookups | A fast scroll cannot put every distinct path on the platform channel at once | aligned (wave 2) — limit 8 |
| Foreground gate (`RefreshGate` + `ui.visible`) | Events keep arriving while hidden; rebuilds stop and the 1 s rates snapshot is not built | aligned (wave 2; the attribution poller is a deliberate data-feed exception) |
| Heartbeat + recovery | A lost core is named, restarted with backoff, or given up loudly | aligned |

## L3 — invariants

1. **One writer per datum.** Profiles/groups: Dart (`documents/profiles.json`,
   ADR 0005). Routes: Go (`documents/route_*.json`). Settings: Kotlin's
   `SettingsStore` over `settings.json`/`markers.json` (mounted at application
   start, seeded once from Room's legacy rows), with the Dart UI-only overlay
   disjoint from it (`ui_overlay.dart`, checked by `settings_contract.py`). A
   second writer is a stop-the-line bug, not a refactor (ADR 0006).
2. **No built core config crosses the UI link.** The UI edits the profile
   document; Kotlin reads the same file (`DartProfileStore`) and builds the core
   config from it. Nothing in the UI assembles or forwards a rendered config.
3. **Unanswered is not refused.** `isUnansweredCoreError` is the one classifier
   (`kernel_control.dart`): a timeout / dead link / booting engine keeps the start
   button optimistic, while a non-zero `ActionResult` code is a refusal that
   rolls back and is reported as `core_<n>` with the handler's payload. The FFI
   boundary maps the code into the same `KernelProxyException`; the IPC envelope
   carries `kind: unanswered` only for the unanswered case and now also carries
   `code`/`details` for a refusal (`coreErrorEnvelope`).
4. **Latest request wins; stale replies are dropped.** Action ids are unique per
   engine (`method#nonce#seq`); a timed-out id is removed from the pending map so
   a late reply cannot complete a newer call. Lifecycle recovery is fenced by
   `KernelService._epoch`, selection switches by `_selectionEpoch`, and
   `dashboard.lan.set` carries an explicit revision.
5. **The data plane keeps running while UI work stops.** The core lives in the
   service engine and survives UI-engine death; the UI proxy reconnects and
   resyncs from `hello`. While hidden, `RefreshGate` stops rebuilds without
   dropping events, `ui.visible` stops the 1 s rates snapshot, and the
   attribution poller keeps sampling because the traffic ledger is data work,
   not a frame. A high-frequency feed (logs/logcat/connections) keeps one
   generation-countered snapshot, so a batch costs one rebuild and a no-op
   event costs none.
6. **Startup is attempted once and recorded.** `BootGuard.evaluate` runs before
   any automatic work, `markRunning` only after the UI is really up (`ready` or
   the error screen painted), so a slow start is never recorded as a crash. The
   service engine's own automatic start reads the same marker through its
   mirror (`BootGate`), so the record also covers the silent tile/boot/widget
   starts the UI never drives.

## L4 — explicitly not ported

| Item | Why not |
| --- | --- |
| Single engine (FlClash: core in the UI process) | The sync FFI start would eat frames; ADR 0004 P6 split the engines instead |
| gomobile / generated Java bridge | Deleted; the C ABI (`throne_*`) is the only native contract (ADR 0004 P3) |
| FlClash's `CoreMethod` enum | The wire here is `ActionMethod` + `tools/diagnostics/action_contract.py`; renaming would be a second contract, not alignment |
| Drift / SQLite-backed core database | ADR 0006: pure-file data layer, one writer per file; the kernel has no DB |
| Desktop local-socket / HTTP core IPC | Android-only app; `IsolateNameServer` is the in-process link, and a socket adds a failure state with no caller |
| Spill files | The isolate-decode path covers the measured payloads (largest: Proxies node rows, ~324 KiB at 3k nodes); no 1 MiB UI result exists to spill |

## This wave vs later

- **Wave 1 (`integrate/align-wave1`):** L1 boot-guard numbers; L2 boot guard;
  L3 invariants 3 (typed refusal code/details at the FFI boundary and accepted
  from the IPC envelope) and 6; `isUnansweredCoreError` as the single classifier.
- **Wave 2 (`integrate/align-wave2`):** Proxies node rows on the bulk wire above
  50 KiB; `FixedList` for the three high-frequency feeds; the eight-slot process
  lookup gate; `ui.visible` gating the rates sample; spill closed as not needed
  (measured payloads).
- **Wave 3 (`integrate/align-wave3`):** settings/markers documents mounted at
  `SagerNet.onCreate` in every process and written under an OS file lock;
  structured refusal `code`/`details` on the service-engine envelope;
  `bootGuardRecord` filtered out of both directions of a backup.
- **Wave 4 (service boot gate):** the service engine's 300 ms automatic start is
  gated on Dart's boot marker, mirrored to `documents/boot_guard.json`
  (`BootGate`, written from `ThroneBoxBridge.writePreferences`); a blocked
  silent start (`quick`/`boot`) creates the fresh engine idle and stops the
  service, so nothing claims `Connected` until a deliberate start.
- **Later:** priority lane for control vs bulk on the IPC port; Room C2c
  (profiles/groups/routes entities, `SagerDatabase`, `data.roomSql` — Room is
  still the seed/backup transport for those tables).
