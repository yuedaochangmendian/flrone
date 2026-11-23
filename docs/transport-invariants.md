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
| Bulk feed wire (`StandardMessageCodec` bytes) + decode off the UI isolate | A 1500-line logcat batch is one codec message, not 1500 map copies | aligned (#235 fixed the empty-payload flip) |
| Log batching in both engines (16 ms / 512) | A start's burst is one IPC message per frame budget, not per line | aligned |
| Control vs bulk priority | Kotlin host event feed: state/priority/bulk lanes, bounded, batched, with a starvation guard; the service-engine→UI IPC port still multiplexes both in one lane | aligned for the host feed (#237); **partial** for the IPC port (listed under "Later") |
| Spill (large result written to a file, path returned) | Keeps a huge result off the wire | pending — no consumer needs it yet |
| Boot guard (attempt marker → none / skipAutoSetup / clearProfile) | A launch that dies before the UI is up does not repeat itself; a loop forgets the profile | aligned (this PR) |
| FixedList ring | O(1) bounded append | not used — bounded lists are sliced at the append site (`BoxController`) |
| Foreground gate (`RefreshGate`) | Events keep arriving while hidden; rebuilds stop | aligned |
| Heartbeat + recovery | A lost core is named, restarted with backoff, or given up loudly | aligned |

## L3 — invariants

1. **One writer per datum.** Profiles/groups: Dart (`documents/profiles.json`,
   ADR 0005). Routes: Go (`documents/route_*.json`). Settings: Kotlin
   (`SettingsSchema.kt`), with the Dart UI-only overlay disjoint from it
   (`ui_overlay.dart`, checked by `settings_contract.py`). A second writer is a
   stop-the-line bug, not a refactor (ADR 0006).
2. **No built core config crosses the UI link.** The UI edits the profile
   document; Kotlin reads the same file (`DartProfileStore`) and builds the core
   config from it. Nothing in the UI assembles or forwards a rendered config.
3. **Unanswered is not refused.** `isUnansweredCoreError` is the one classifier
   (`kernel_control.dart`): a timeout / dead link / booting engine keeps the start
   button optimistic, while a non-zero `ActionResult` code is a refusal that
   rolls back and is reported as `core_<n>` with the handler's payload. The FFI
   boundary maps the code into the same `KernelProxyException`; the IPC envelope
   carries `kind: unanswered` and, from a peer that supplies them, `code`/`details`.
4. **Latest request wins; stale replies are dropped.** Action ids are unique per
   engine (`method#nonce#seq`); a timed-out id is removed from the pending map so
   a late reply cannot complete a newer call. Lifecycle recovery is fenced by
   `KernelService._epoch`, selection switches by `_selectionEpoch`, and
   `dashboard.lan.set` carries an explicit revision.
5. **The data plane keeps running while UI work stops.** The core lives in the
   service engine and survives UI-engine death; the UI proxy reconnects and
   resyncs from `hello`. While hidden, `RefreshGate` stops rebuilds without
   dropping events.
6. **Startup is attempted once and recorded.** `BootGuard.evaluate` runs before
   any automatic work, `markRunning` only after the UI is really up (`ready` or
   the error screen painted), so a slow start is never recorded as a crash.

## L4 — explicitly not ported

| Item | Why not |
| --- | --- |
| Single engine (FlClash: core in the UI process) | The sync FFI start would eat frames; ADR 0004 P6 split the engines instead |
| gomobile / generated Java bridge | Deleted; the C ABI (`throne_*`) is the only native contract (ADR 0004 P3) |
| FlClash's `CoreMethod` enum | The wire here is `ActionMethod` + `tools/diagnostics/action_contract.py`; renaming would be a second contract, not alignment |
| Drift / SQLite-backed core database | ADR 0006: pure-file data layer, one writer per file; the kernel has no DB |
| Desktop local-socket / HTTP core IPC | Android-only app; `IsolateNameServer` is the in-process link, and a socket adds a failure state with no caller |
| Spill files | Listed as pending above; the sizes here fit the isolate-decode path |

## This wave vs later

- **This wave (PR `feat/align-lifecycle-boot-guard`):** L1 boot-guard numbers;
  L2 boot guard; L3 invariants 3 (typed refusal code/details at the FFI boundary
  and accepted from the IPC envelope) and 6; `isUnansweredCoreError` as the single
  classifier.
- **Later:** priority lane for control vs bulk on the IPC port; structured
  `code`/`details` on the service-engine envelope (the UI already accepts them,
  `service_entry.dart` does not send them yet); gating the service engine's own
  300 ms auto-start, which is where this app's launch-time auto-start actually
  lives (the UI has none, so the boot guard's degraded path currently suppresses
  the remembered profile and the notice rather than a start the UI performs);
  excluding `bootGuardRecord` from the preferences part of backups (today the
  freshness window neutralises a restored marker, but a backup is not the right
  carrier for launch bookkeeping).
