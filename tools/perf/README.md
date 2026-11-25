# Phase 0 performance measurement harness

This directory is a **measurement harness only**. It adds no app code, no
dependencies and no CI jobs. It exists to produce repeatable before/after
numbers for the `com.throneflclash` Flutter + Kotlin + Go client.

The fixed scenarios live in [scenarios.md](scenarios.md); the fill-in result
table lives in [docs/perf-baseline.md](../../docs/perf-baseline.md). Read those
two files before running anything.

## Layout

| File | Purpose |
| --- | --- |
| `collect-device.sh` | One-shot device snapshot (props, meminfo, gfxinfo, logcat events, cpuinfo, profile files). Writes `out/<UTC timestamp>/`. |
| `perfetto.cfg` | Textproto trace config: app + system sched/freq/gfx/binder/SurfaceFlinger. |
| `scenarios.md` | Exact commands and metrics for each fixed scenario. |
| `host-baseline.sh` | Host-only `flutter analyze` / targeted `flutter test` wall times (no device). |
| `apk-size.sh` | Per-entry APK size breakdown (compressed bytes, `unzip -v` + awk only). See `docs/perf-host-audit.md`. |
| `out/` | Generated captures. Do not commit run data; add it to `.gitignore` locally if you want. |

## Prerequisites

- **adb** on `PATH` (e.g. `/e/hu/toolchain/android-sdk/platform-tools/adb`) and
  one authorized device. `adb devices` must list exactly one `device` unless you
  pass a serial explicitly.
- **iperf3** on the host *and* on the device for the bandwidth scenarios
  (`adb push` a static iperf3 binary to `/data/local/tmp/iperf3`, `chmod +x`).
  A large-file download through the tunnel is the fallback if iperf3 is unavailable.
- **perfetto** on the device (system `perfetto` binary on recent Android, or
  push one to `/data/local/tmp/perfetto`) for the trace-based scenarios.
- **Flutter SDK 3.50.0** (the CI pin in `.github/actions/android-build/action.yml`)
  only for `host-baseline.sh`: `/e/hu/toolchain/flutter-3.50.0/bin/flutter`.
  Override with `FLUTTER_BIN=/path/to/flutter` if installed elsewhere.
- An **arm64 device** (not an emulator, not x86_64) for any number that goes in
  the baseline table. Host and emulator numbers are not representative (see
  `docs/perf-baseline.md`).

The scripts are Git Bash / POSIX shell scripts with LF endings. Run them from
the repository root; they resolve paths relative to themselves.

## Running the scripts

### Device snapshot

```bash
bash tools/perf/collect-device.sh                # auto-select the single device
bash tools/perf/collect-device.sh <serial>       # when several devices are online
PKG=com.example.other bash tools/perf/collect-device.sh
```

The script fails early with a clear message if `adb` is missing, no device is
authorized, several devices need disambiguation, or the package is not installed.
It writes to `tools/perf/out/<UTC YYYYmmddTHHMMSSZ>/`:

| File | Meaning |
| --- | --- |
| `device.props.txt` | `ro.product.*` plus SDK/build id; identifies the exact hardware/OS a run belongs to. |
| `meminfo.txt` | `dumpsys meminfo <pkg>`: PSS, Java/native heap, graphics, views. Compare **PSS TOTAL** and **TOTAL RSS**. |
| `gfxinfo.txt` | `dumpsys gfxinfo <pkg>` after `reset`; frame timings and jank counters. Compare 50th/90th/95th percentile frame time and **Janky frames**. |
| `gfxinfo-reset.txt` | Output of the reset call; confirms counters were zeroed at capture start. |
| `force-stop.txt` | Output of the one allowed `am force-stop`; documents the reset. |
| `logcat-events.txt` | `logcat -b events -d` dump (no clearing); AM/WM lifecycle events, useful to line up starts with timestamps. |
| `cpuinfo.txt` | `dumpsys cpuinfo`: per-process CPU load sampled at capture time. |
| `profiles-ls.txt` | Listing of `files/profiles`, or a note that `run-as` is unavailable. |
| `profiles/` | Copies of `files/profiles/*` via `exec-out run-as`, one file per entry (skipped on release builds). |
| `capture.txt` | Timestamp, serial, package, and commands run — paste key lines into the baseline table. |

No app data is cleared. The only state-changing command is `am force-stop`,
used solely to zero gfxinfo counters before the capture; re-launch the app
afterwards to accumulate frames.

### Perfetto trace

```bash
adb push tools/perf/perfetto.cfg /data/local/tmp/perfetto.cfg
# Start the scenario first, then:
adb shell perfetto -c /data/local/tmp/perfetto.cfg -o /data/local/tmp/trace.perfetto-trace --txt
adb pull /data/local/tmp/trace.perfetto-trace tools/perf/out/<run>/trace.perfetto-trace
```

Open the `.perfetto-trace` at <https://ui.perfetto.dev>. The config captures the
`com.throneflclash` app's atrace markers plus system scheduling, CPU/GPU
frequency, gfx/view, binder and SurfaceFlinger events over a 60 s window.
Edit `duration_ms` in the config for longer scenarios (e.g. 300000 for the
5-minute download). If the UI shows "data loss", raise the first buffer's
`size_kb`.

Typical queries in the Perfetto UI SQL console:

```sql
-- CPU time per thread of our process over the trace
SELECT t.name, SUM(s.dur)/1e6 AS cpu_ms
FROM slice s JOIN thread_track tt ON s.track_id=tt.id
JOIN thread t ON tt.utid=t.id
JOIN process p ON t.upid=p.id
WHERE p.name LIKE '%throneflclash%' GROUP BY t.name ORDER BY cpu_ms DESC;
```

### Host-only baseline

```bash
bash tools/perf/host-baseline.sh
FLUTTER_BIN=/custom/flutter bash tools/perf/host-baseline.sh
```

Records wall-clock times for `flutter analyze --fatal-infos` and a fixed set of
targeted tests (`flutter/test`) into `tools/perf/out/host/<UTC timestamp>/`.
**Host timings are diagnostics, not baseline-table numbers.**

## Running a scenario and comparing two runs

1. Pick a scenario in `scenarios.md`. Use the same device, same build type, same
   settings and the same preparation steps both times.
2. Record the git commit (`git rev-parse --short HEAD`), ABI (`getprop
   ro.product.cpu.abi`), and UTC start time next to the run directory.
3. Start the capture (trace if the scenario needs one), execute the scenario,
   then run `collect-device.sh` while the state you care about is still live
   (e.g. leave the 1000-connection list open before the meminfo capture).
4. Copy the scenario's metric values into a new column of
   `docs/perf-baseline.md` (one column per run, e.g. `before` / `after`).
5. Compare **ratios** for time metrics and absolute deltas for memory/bytes.
   A change is only meaningful if it repeats across 3+ runs for start timing
   (5 for cold start) and the device thermal state is comparable — throttle
   first if in doubt. Keep raw captures for audit; never overwrite a run dir.

Suggested pass criteria are listed per scenario; when two runs disagree, the
scenario's "what to record" list is the tie-breaker — compare like for like.
