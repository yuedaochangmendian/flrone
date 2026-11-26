# Host / release-build performance audit

Phase 4 audit of the Kotlin host and Gradle release build. Companion to
`docs/perf-baseline.md` (measurement template) and `docs/perf-bridge-audit.md`
(bridge payload work). This document records **what the build actually does**
plus proposals; behaviour changes are proposals unless a small, safe code
change is noted explicitly.

All numbers below were measured locally on **2026-11-25** at HEAD
`454f2f77` with JDK 21 / Gradle wrapper 8.14.7 / Android SDK 37. Reproduce
with the commands in the "Validation" section.

## 0. Correction to the audit premise

The initial finding was that "release builds are unminified: `grep -rn
'minifyEnabled|shrinkResources' --include=*.kts --include=*.gradle .` finds
nothing, `proguard-rules.pro` unused." **This is wrong.** The release config
lives in `buildSrc/src/main/kotlin/Helpers.kt` — a `.kt` file, not matched by
that grep:

- `setupCommon()` (Helpers.kt:65-69) sets `isMinifyEnabled = true` on the
  `release` build type.
- `setupAppCommon()` (Helpers.kt:102-117) sets `isShrinkResources = true` and
  keeps an env escape hatch `nkmr_minify=0` that disables both.
- `setupApp()` (Helpers.kt:174-180) wires
  `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"),
  file("proguard-rules.pro"))`.

Empirical confirmation: a default `:app:assembleOssRelease` produced
`app/build/outputs/mapping/ossRelease/{mapping,configuration,seeds,usage,resources}.txt`
(R8 output), and the APK's main `classes.dex` is 4.42 MiB (plus an 860 B
`classes2.dex`) vs 19.07 MiB / 4 dex files with `nkmr_minify=0`. So R8 **is** active in all shipped release
APKs, including the `dist/Flrone-4.17.2-pre.6-*` set.

## 1. APK size breakdown

`dist/Flrone-4.17.2-pre.6-arm64-v8a.apk` — **41,762,988 B = 39.83 MiB**
(the signed release artifact). `unzip -l`; "raw" = uncompressed entry size,
"compressed" = bytes stored in the APK.

| Top-level | Compressed | Share | Raw | Entries |
| --- | ---: | ---: | ---: | ---: |
| `lib/` | 31.49 MiB | 79.3% | 83.03 MiB | 6 |
| `resources.arsc` | 4.12 MiB | 10.4% | 4.12 MiB | 1 |
| `classes.dex` | 2.04 MiB | 5.1% | 4.42 MiB | 1 |
| `assets/` | 1.49 MiB | 3.7% | 3.89 MiB | 142 |
| `res/` | 0.57 MiB | 1.4% | 0.78 MiB | 624 |
| `META-INF/` + manifest + metadata | <0.02 MiB | <0.1% | <0.05 MiB | 9 |

Sum of compressed entries 39.73 MiB; the remaining ~0.1 MiB is zip central
directory / alignment.

Largest entries (compressed / raw):

| Entry | Compressed | Raw |
| --- | ---: | ---: |
| `lib/arm64-v8a/libthrone.so` | 22.34 MiB | 62.41 MiB |
| `lib/arm64-v8a/libflutter.so` | 5.15 MiB | 10.82 MiB |
| `resources.arsc` | 4.12 MiB | 4.12 MiB |
| `lib/arm64-v8a/libapp.so` | 3.98 MiB | 9.75 MiB |
| `classes.dex` | 2.04 MiB | 4.42 MiB |
| `assets/sb-dashboard/assets/index-CvdWH0XG.js` | 0.34 MiB | 1.19 MiB |

Takeaways:

- **~79% of the APK is native libraries.** R8 cannot touch these. `libthrone.so`
  alone (Go core + dependencies) is 56% of the APK; `libflutter.so` + AOT
  `libapp.so` add another 23%. These are already stripped by the NDK strip
  task (`Helpers.kt:56-60` pins ndkVersion for exactly this reason).
- `resources.arsc` is stored uncompressed (Android requires it) and is the
  single largest non-native item after minification. It is mostly string
  resources from Material/components; shrinking trims unused entries but the
  file cannot be compressed in-place.
- Java/Kotlin bytecode is only ~2 MiB compressed after R8, so further dex
  tuning has limited headroom compared to native or assets.
- The dashboard JS/CSS/font bundle (`assets/sb-dashboard/`) is ~0.6 MiB
  compressed; not worth chasing relative to the 31 MiB native payload.

## 2. Release build config / what R8 covers

**Config (verified):** both `ossRelease` and `fdroidRelease` are minified and
resource-shrunk by default. `proguard-rules.pro` is wired via `setupApp()`.

**What R8 already does here:**

- **Kotlin host code (all `app/src/main/java`, both Kotlin and Java)** — dead
  code removal and null-check intrinsic stripping (`-assumenosideeffects`
  block, proguard-rules.pro:9-21). `-dontobfuscate` is set
  (proguard-rules.pro:28), so names stay readable for crash triage; shrinking
  alone accounts for the 19.07→4.42 MiB dex drop.
- **Flutter AAR Java embedding** — `classes.jar` inside
  `flutter_release-1.0.aar` contains the host-side Java glue (`GeneratedPluginRegistrant`,
  bridge classes). R8 processes it as normal Java bytecode alongside the
  host. The AAR ships **no `consumer proguard-rules`** (verified: its file
  list has only `R.txt`, `AndroidManifest.xml`, `classes.jar`, assets, jni),
  so there are no AAR-provided keep rules to fold in. `-keep class
  io.flutter.plugins.** { *; }` (proguard-rules.pro:53) is the host's own
  guard for reflectively-loaded plugin classes.
- **JNI / C ABI (libthrone.so, libflutter.so, libapp.so)** — **not touched by
  R8**. Native symbols are not Java symbols; only the Java declarations that
  call them (`io.flrone.core.Core`, `System.loadLibrary("throne")`, JNI_OnLoad
  classes) are visible to R8. Those must be kept and are implicitly reachable
  from the host call sites; no explicit `-keep` exists for them today, which
  works because they are statically referenced.

**Risks / keep rules:**

- `OutboundFactory` instantiates profile types reflectively by class name
  (`Class.forName("io.nekohasekai.sagernet.outbound.types." + className)`), so
  `-keep class io.nekohasekai.sagernet.outbound.types.** { *; }` is required
  and present (proguard-rules.pro:6).
- `-keepattributes SourceFile,LineNumberTable` is required by the seven-day
  crash store (proguard-rules.pro:30).
- Serialization/reflection over Gson models is guarded by field names in
  `Data` classes; review before enabling `-obfuscate` (currently off) — that
  would break Gson unless `@SerializedName` is everywhere. Do not enable
  obfuscation as part of a perf pass.
- `GeneratedPluginRegistrant` reflection guard is present. The app has no
  Flutter plugin AARs anymore (QR scanning is a host activity), so the broad
  rule is conservative but harmless.

**Net:** R8 is already doing the useful work. Adding new keep rules is not
needed for the current build; the only actionable change in this line is
exposing a documented Gradle property to control it (see §6).

## 3. Startup — main-thread work that could be deferred

`SagerNet.onCreate()` (app/src/main/java/io/nekohasekai/sagernet/SagerNet.kt:61-177).
Line numbers are from HEAD `454f2f77`.

Work that runs synchronously on the main thread (with `isMainProcess || isBgProcess`
true, which is the only process today — see §5):

| Line | Work | Deferrable? |
| --- | --- | --- |
| 73-78 | `SettingsJsonStore.directory = ...; ensure()` — file stats / possible seed of settings documents | **No** — must precede the first `DataStore` read; correctness-critical. |
| 80 | `Thread.setDefaultUncaughtExceptionHandler(CrashHandler)` | No (cheap). |
| 83 | `SettingsMapper.installOutboundHooks()` | No (cheap, in-memory). |
| 89 | `FlutterInjector.flutterLoader().startInitialization(this)` | Borderline — heavy native init; already off the critical path of any engine creation but still on the app-start main thread. Flutter recommends calling it in `attachBaseContext`; moving it earlier would not reduce total work, only overlap it. |
| 90 | `ServiceEngineManager.install(this)` | Already lazy prewarm (see below) — cheap here. |
| 97 | `Thread { System.loadLibrary("throne") }.start()` | **Already off-main** (native lib preload on its own thread). Good. |
| 98-101 | `Handler.postDelayed({ ServiceEngineManager.prewarm() }, 3000)` | **Already deferred** 3 s off the startup path. Good. |
| 104 | `FlroneRuntime.install(this)` → `FlroneBridge.install()` | Contains `DartProfileStore.directory`, listener registration, a 1 s ticker, and `scheduleRefresh(immediate=true)` (FlroneBridge.kt:161-189). The immediate refresh reads the profiles document from disk. Could be moved to `runOnDefaultDispatcher` **if** every consumer tolerates a late first catalog, but that is a correctness-sensitive change (ADR 0005 race) — leave alone. |
| 108 | `updateNotificationChannels()` (first call) | Binder call creating 5 channels. Idempotent; repeated at line 151 and on every `onConfigurationChanged` (line 200) — possible redundancy, see §4. |
| 110 | `Widgets.push(this)` | **Already async** (`runOnDefaultDispatcher` → `render`). Good. |
| 113-117 | `Core.setPlatform(...)`, `CoreRuntime.setup(this)` | JNI setup + core runtime init on main. Might be deferrable but touches the start path for tile/boot; risky to move. |
| 126-127 | `DataStore.ensureClashApiSecret()` | Idempotent settings read; small disk I/O. Could move to `runOnDefaultDispatcher` (it only repairs a saved pair), but must still complete before any config build. Low value. |
| 128 | `AutoSelectorRuntime.install()` | In-memory; cheap. |
| 132 | `JavaUtil.handleWebviewDir(this)` | Filesystem work on main. Deferrable, legacy WebView cleanup. Low value. |
| 134-138 | `PackageCache.register/prewarm`, `cleanWebview()` | **Already on `runOnDefaultDispatcher`.** Good. |
| 142-144 | `Theme.apply`, `Theme.applyNightTheme`, `AppLocale.apply` | Needed before first Activity inflation; keep. |
| 145 | `UpdateManager.onAppStart` | Already launches a coroutine + schedules WorkManager (UpdateManager.kt:70-74); cheap on main. |
| 146-152 | `DefaultNetworkListener.start` + **second** `updateNotificationChannels()` | Network listener on `runOnDefaultDispatcher`; the second channel call duplicates line 108 (see §4). |
| 154 | `custom_icon` delete | Already async. Legacy no-op. |
| 159-160 | `SingBoxDashboard.install()` (if enabled) | Already async; unpacks 46 files. Good. |
| 162-163 | `SubscriptionScheduler.schedule`, `Widgets.watchSelection` | Both internally async (WorkManager / receiver registration). Cheap on main. |

**StrictMode coverage (after this audit's change):** before this change only a
`VmPolicy` (leaked SQLite/closables/registrations) was installed in debug.
There was **no `ThreadPolicy`**, so disk reads/writes and network on the main
thread were never flagged. This change adds a `ThreadPolicy` with
`detectDiskReads/detectDiskWrites/detectNetwork` + `penaltyLog()` in
`BuildConfig.DEBUG`, scoped to `isMainProcess`. It uses `penaltyLog()` only —
no `penaltyDeath()` — so it cannot crash unit tests or the app; it logs
violations to logcat. Unit tests do not instantiate `SagerNet`, so no test
impact.

## 4. Notifications — update frequency and redundant rebuilds

Two independent notification owners:

1. **`ServiceNotification`** (`bg/ServiceNotification.kt`, id 1, the VPN/proxy
   foreground notification). `update()` (line 329-331) calls
   `NotificationManagerCompat.notify(notificationId, it.build())` — i.e. a full
   `Notification` rebuild + system call each time. Callers:
   - `postNotificationSpeedUpdate()` (line 81) — from
     `BaseService.publishKernelStats()` (BaseService.kt:378-387), which the
     comment says arrives **once per second** from the Dart `state.stats` feed.
     Gated by `listenPostSpeed` (screen on) and routed to the main dispatcher.
     So up to 1 full rebuild + notify/sec while the screen is on and the tunnel
     is connected.
   - `postNotificationTitle()` (line 129), `refresh()` (line 138),
     `postConnected()` (line 150) — event-driven (connect, profile switch,
     settings change), not periodic.
   - `updateActions()` + `postNotificationTitle()` from
     `applyNotificationSettings()` (BaseService.kt:396-408) — user-triggered.

2. **`CoreForeground`** (`bg/CoreForeground.kt`, id 0x7E57, connection-test /
   subscription foreground promotion). Event-driven only: `acquire()`, `post()`,
   `release()`, `promote()`, `demote()`. No periodic path. `show()` (line 131)
   rebuilds the default notification each time but is called only on state
   transitions; a holder that `post()`s custom content replaces it. No obvious
   redundant rebuild in the periodic sense.

**Observations / proposals (not changed):**

- **1 Hz notification rebuild is Android's normal pattern for speed
  readouts** (FlClash/NekoBox do the same). The cost is one `Notification.build()`
  + one binder call per second, negligible next to the core's 1 Hz status feed.
  No evidence it is a bottleneck. **Proposal only:** if profiling ever shows
  it, throttle identical text (skip `notify()` when the formatted speed string
  is unchanged) — but this must be weighed against the system's expectation
  of a live foreground service.
- **`updateNotificationChannels()` is called 3× at startup** (SagerNet.kt:108,
  151, and again in `onConfigurationChanged` line 200). Each is a binder call
  that creates/overwrites 5 channels. Idempotent, but the second call at 151 is
  redundant with 108 in the same process. **Safe proposal:** drop the call at
  151 (keep the `onConfigurationChanged` one, which handles locale changes to
  channel names). Not changed here — behaviour-neutral but low impact.
- `ServiceNotification.postNotificationSpeedUpdate()` re-renders the title
  template on every tick (line 88, "so a template change reaches the
  notification on this same update"). That is a small string render; fine.

## 5. Process model note

`app/src/main/AndroidManifest.xml` declares **no `android:process` entries** —
everything (UI, `CoreService`, VPN services, tile, widgets) runs in the main
process. `isBgProcess` in `SagerNet.kt:59` is effectively always false today.
This means the `:bg`-scoped comments in several classes are historical, and a
`ThreadPolicy` scoped to `isMainProcess` applies to all in-process service
work too. That is intentional: `penaltyLog()` only reports, and the documented
hot paths (`System.loadLibrary`, `prewarm`, `scheduleRefresh`) are already
off-main.

## 6. Ranked host/build optimizations

Ranked by expected gain / risk / effort for this specific app. Items already
done are listed for context and excluded from the ranking.

| # | Optimization | Expected gain | Risk | Effort | Status |
| --- | --- | ---: | --- | --- | --- |
| 1 | **Keep R8 + resource shrinking on for release (already default)** | 5.95 MiB APK / 12%, dex 19.07→4.42 MiB | Low (keep rules already in place; `-dontobfuscate` keeps crash symbols) | Done | Verified this audit; now exposed via `-PthroneMinify` |
| 2 | **Shrink `libthrone.so` (62.4 MiB raw / 22.3 MiB compressed)** — Go build flags `-ldflags="-s -w"`, drop unused build tags/deps | Up to several MiB compressed; highest-ceiling item overall | Medium (must not strip needed symbols for cgo/JNI; verify with core tests + device) | High (Go/core side) | Proposal — needs core-side work, out of this host line |
| 3 | **Expose a documented minify Gradle property** (replace the magic `nkmr_minify=0`) | No size change; prevents accidental unminified releases | Very low | Done | `-PthroneMinify=false` opts out; default stays on |
| 4 | **Debug StrictMode `ThreadPolicy`** (disk/network, penaltyLog, UI process) | No shipped gain; catches main-thread I/O regressions early | Very low (log only, debug builds) | Done | Added in `SagerNet.kt` |
| 5 | **Drop duplicate `updateNotificationChannels()` at startup** | Negligible CPU (2 fewer binder calls at launch) | Very low | Done as proposal only | Not changed — see §4 |

Not ranked (already done, do not duplicate): bulk bridge payloads, 300 ms
aspect batching, log frames, fixed log ring, native lib stripping, VkLayer
exclusion from the debug engine, deferred engine prewarm, async dashboard
unpack, off-main package prewarm.

## 7. Validation / commands

```bash
# Baseline, default (minified) release — should produce R8 mapping files
source /e/hu/toolchain/env.sh
./gradlew --offline :app:assembleOssRelease --console=plain -q

# Unminified via the new property (explicit opt-out)
./gradlew --offline -PthroneMinify=false :app:assembleOssRelease --console=plain -q

# Legacy escape hatch still works
nkmr_minify=0 ./gradlew --offline :app:assembleOssRelease --console=plain -q
```

For a quick per-entry breakdown of any APK (no dependencies, Git Bash):

```bash
./tools/perf/apk-size.sh dist/Flrone-4.17.2-pre.6-arm64-v8a.apk
```

Measured arm64 unsigned APK sizes (`app/build/outputs/apk/oss/release/`):

| Config | APK size | dex |
| --- | ---: | --- |
| Default (minify on) | 41,750,620 B = 39.83 MiB | 4.42 MiB main + 860 B secondary |
| `-PthroneMinify=false` / `nkmr_minify=0` | 48,002,660 B = 45.78 MiB | 19.07 MiB (4 dex) |

Same ~5.95 MiB delta applies to the signed `dist/` artifacts.

## 8. Needs a device to confirm

- StrictMode `ThreadPolicy` findings in a **debug** build: which violations
  appear during cold start / first tunnel start. `penaltyLog()` means logcat
  only — capture with `adb logcat -s StrictMode`. A release build has
  `BuildConfig.DEBUG=false`, so nothing changes there.
- Whether `-PthroneMinify=false` (unminified) actually aids on-device crash
  triage: `-dontobfuscate` already keeps names in minified builds, so the main
  benefit of disabling R8 is unstripped line numbers in cases R8 inlines —
  confirm before relying on it.
- Any proposal in §4/#5 (notification throttling, duplicate channel call)
  should be profiled on device before adopting; no functional gain is claimed.

### Engine creation inside the 3 s prewarm window (tile / boot / always-on start)

`SagerNet.onCreate()` schedules `ServiceEngineManager.prewarm()` at
`mainLooper.postDelayed(..., 3_000)` (SagerNet.kt:103-105). A start triggered
from a QS tile, `BOOT_COMPLETED` / "always-on VPN" restore, or a widget before
that delay elapses calls `ServiceEngineManager.ensureStarted()` on the main
thread **first**, so it pays `System.loadLibrary("throne")` plus
`createAndRunEngine` synchronously — the exact cost the prewarm was meant to
move off the tap path. No code change is made here: moving engine creation
earlier touches the boot/start correctness path (ADR 0005 `DartProfileStore`
readiness, liveness reuse), so this is a device-measurement item only.

To measure on a real device (release build, cold process start, one run with
the start inside the 3 s window and one after):

- Capture `adb logcat -s System.out` / the app's own timing marks around
  `ServiceEngineManager.ensureStarted` and the `service.start` channel call;
  record the main-thread wall time of `createAndRunEngine` and whether a frame
  was dropped (the UI's `frame work` / `ui stall` diagnostic on the speed card).
- Compare tap-to-"Starting" latency and the longest main-thread stall for a
  start at ~0.5–2 s after cold start versus a start >=3.5 s (prewarm already
  finished). The delta is the worst-case jank a tile/boot/always-on start can
  add.
- Note device thermal state and whether `libthrone.so` was already page-cached
  (a second start in the same process is not representative).
- Only if the pre-window stall is material (e.g. >100 ms on a mid-tier device)
  should the trade-off of an earlier/async engine creation be revisited; until
  then the lazy prewarm stays as-is.
