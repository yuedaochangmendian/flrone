# Performance baseline (fill-in)

Phase 0 measurement baseline for `com.throneflclash`. **This is a template**:
fill one column per run. Keep the raw captures under `tools/perf/out/<UTC>/`.
Procedures are in [`tools/perf/scenarios.md`](../tools/perf/scenarios.md) and
[`tools/perf/README.md`](../tools/perf/README.md).

**Important:** host numbers (`tools/perf/host-baseline.sh`) and emulator/x86_64
numbers are diagnostics only and must **not** be used as baseline values. All
device rows below require a physical **arm64** device with the same build type
(debug or release), same settings and no thermal throttling. Record ratios in
the "target" column as "<= baseline x N" or an absolute ceiling; leave it blank
until a baseline run has been measured and agreed.

## Run metadata

| Field | Run 1 (baseline) | Run 2 | Run 3 |
| --- | --- | --- | --- |
| Date (UTC) | | | |
| Commit (`git rev-parse --short HEAD`) | | | |
| Device model / `ro.product.model` | | | |
| OS / SDK (`ro.build.version.release` / `ro.build.version.sdk`) | | | |
| ABI (`ro.product.cpu.abi`) — must be arm64-v8a | | | |
| Build type (debug / release) | | | |
| Serial | | | |
| Scenario repetitions | | | |
| Notes (thermal, network, settings) | | | |

## Cold / hot start

| Metric | Unit | Run 1 | Run 2 | Run 3 | Target |
| --- | --- | --- | --- | --- | --- |
| Cold start `TotalTime` (median of 5) | ms | | | | <= baseline x 1.05 |
| Cold start `TotalTime` (max of 5) | ms | | | | <= median x 1.3 |
| Cold start `ThisTime` / `WaitTime` (median) | ms | | | | |
| Cold start PSS after settle (5 s) | MB | | | | <= baseline + 10 MB |
| Hot start `TotalTime` (median of 3+) | ms | | | | <= 50% cold, <= baseline x 1.05 |
| Core-ready time (median of 5) | ms | | | | <= baseline x 1.05 |
| Rule-set-ready time (median of 5) | ms | | | | <= baseline x 1.05 |
| Rules loaded count | count | | | | identical to baseline |

## UI scroll (dashboard / proxies / logs, 30 s each)

| Metric | Unit | Run 1 | Run 2 | Run 3 | Target |
| --- | --- | --- | --- | --- | --- |
| Dashboard p95 frame time | ms | | | | <= 16.7 ms or <= baseline x 1.05 |
| Dashboard janky frames | frames | | | | <= baseline + 10% |
| Proxies p95 frame time | ms | | | | <= 16.7 ms or <= baseline x 1.05 |
| Proxies janky frames | frames | | | | <= baseline + 10% |
| Logs p95 frame time | ms | | | | <= 16.7 ms or <= baseline x 1.05 |
| Logs janky frames | frames | | | | <= baseline + 10% |
| UI-thread CPU (Perfetto) | ms | | | | |
| PSS TOTAL delta after scroll+idle | MB | | | | ~0 (no leak) |

## 1000-connection list

| Metric | Unit | Run 1 | Run 2 | Run 3 | Target |
| --- | --- | --- | --- | --- | --- |
| Rows displayed | count | | | | ~1000 (or documented cap) |
| Time to first frame | ms | | | | <= baseline x 1.1 |
| PSS TOTAL @ 1000 rows | MB | | | | <= baseline + 20 MB |
| Java / native heap @ 1000 rows | MB | | | | |
| Scroll p95 frame time | ms | | | | <= 16.7 ms or <= baseline x 1.1 |
| Binder transactions/s (feed) | tx/s | | | | |

## DEBUG log storm (60 s)

| Metric | Unit | Run 1 | Run 2 | Run 3 | Target |
| --- | --- | --- | --- | --- | --- |
| Log lines recorded in 60 s | lines | | | | record with every row |
| PSS growth (minus idle growth) | MB | | | | <= 25 MB |
| Process CPU % | % | | | | <= baseline x 1.2 at equal volume |
| Log-processing CPU (Perfetto) | ms | | | | |
| Janky-frame ratio | x baseline | | | | <= 2x |
| ANR / OOM / crash | yes/no | | | | no |

## Tunnel bandwidth (100 Mbps target, 5 min)

| Metric | Unit | Run 1 | Run 2 | Run 3 | Target |
| --- | --- | --- | --- | --- | --- |
| Throughput at 1 min | Mbps | | | | >= 90 Mbps |
| Throughput at 5 min | Mbps | | | | >= 90 Mbps, >= 90% of 1 min |
| Process CPU % | % | | | | <= baseline x 1.1 |
| PSS growth over 5 min | MB | | | | <= 20 MB |
| Bytes sent/received (dashboard) | MB | | | | consistent with iperf3 |
| Device temperature (if available) | C | | | | |

## DNS (1000 queries)

| Metric | Unit | Run 1 | Run 2 | Run 3 | Target |
| --- | --- | --- | --- | --- | --- |
| Queries reaching tunnel resolver | count | | | | >= 990 / 1000 |
| Elapsed time | s | | | | |
| Queries/s | q/s | | | | >= baseline x 0.95 |
| PSS growth after burst | MB | | | | <= 10 MB |
| Process CPU % | % | | | | |
| Crash / ANR | yes/no | | | | no |

## Host-only diagnostics (not a device baseline)

From `bash tools/perf/host-baseline.sh`; useful to spot host toolchain changes
but never compare against device numbers.

| Metric | Unit | Run 1 | Run 2 | Run 3 | Target |
| --- | --- | --- | --- | --- | --- |
| `flutter analyze --fatal-infos` wall time | s | | | | n/a |
| Targeted `flutter test` wall time | s | | | | n/a |
| Flutter SDK version | version | | | | CI pin 3.50.0 |

## Filling a row

For each scenario, take numbers from `tools/perf/out/<timestamp>/`:

- `am start -W` output -> start timings; `logcat-events.txt` -> lifecycle timestamps.
- `gfxinfo.txt` -> frame percentile/jank rows; `meminfo.txt` -> PSS/heap rows.
- `cpuinfo.txt` -> CPU %; Perfetto trace -> CPU ms/binder tx rows.
- `device.props.txt` + `capture.txt` -> run metadata (transfer to the table header).

Write absolute values with units; compute ratios only when comparing two runs.
If a metric could not be measured, write `n/m` with a reason rather than 0.

## Appendix: emulator smoke run (2026-11-25, not a baseline)

This run only proves the harness works end-to-end and gives an emulator reference
for future smoke comparisons. **Do not copy these numbers into the arm64 table.**

| Field | Value |
| --- | --- |
| Device | `sdk_phone64_x86_64`, API 35, 1080x2340 @440 (AEHD emulator) |
| Build | Flrone 4.17.2-pre.6, x86_64, release (commit `b04616d4`) |
| Cold start TotalTime (n=5) | 762, 864, 1066, 797, 825 ms; median 825, max 1066 |
| Hot start TotalTime (n=3) | 135, 130, 102 ms; median 130 |
| PSS after settle | 149.5 MiB (cold) / 154.4 MiB (hot) |
| Dashboard 30 s scroll | SurfaceFlinger frame interval p50 46.50 ms, p95 216.38 ms, p99 307.67 ms; present latency p50 18.49 ms; janky 126/126 |
| Crashes | none (`logcat -b crash` empty, no `E/flutter`) |
| Harness capture | `tools/perf/out/20261125T110229Z/` (10 files) |

Notes:

- `dumpsys gfxinfo` reports **0 frames** for this app: Flutter renders through a
  SurfaceView, so HWUI frame counters are empty. Frame data above comes from
  `dumpsys SurfaceFlinger --latency '<SurfaceView layer>'`; keep using that on
  emulator smoke runs.
- The emulator renders with a software GPU, so 100% jank is expected and says
  nothing about a device. Use it only to catch functional regressions.
- `collect-device.sh` worked; `run-as` was refused because the release APK is not
  debuggable, so the app-private profile pull was skipped. The pprof marker
  (`files/profile.enable`) therefore cannot be created on a release build with
  `run-as`; it needs a debuggable build or a build-tag-gated measurement build.
