# Real-device kernel resource harness

`tools/perf/kernel-memory.sh` is a **read-only, time-series** sampler for
`com.throneflclash` that runs against a physical Android device. It fills the
gap left by [`perf-baseline.md`](perf-baseline.md): that document fixes *which*
numbers belong in the baseline table, but a single `collect-device.sh` snapshot
cannot show whether a long-running tunnel **leaks**, grows unbounded under
load, or spawns threads over time.

This harness does not add app code, dependencies, or CI jobs. It never starts
or stops the tunnel, force-stops the app, clears data, or uses root/sudo — it
only issues `adb shell` dump commands. **Emulator numbers are diagnostics only
and must never be copied into the arm64 baseline table** (see the emulator
appendix in [`perf-baseline.md`](perf-baseline.md)); a physical **arm64** device
is required for anything that will be compared across builds.

## What it captures

Each sample (at a configurable interval, default 5 s) records a timestamp,
the resolved PID, the package, and four dumps; a failed dump is recorded in
`notes` / `<sample>-errors.txt` instead of aborting the run:

| Dump | Fields used |
| --- | --- |
| `adb shell dumpsys meminfo <pkg>` | `TOTAL PSS`, plus the `Dalvik Heap` (Java), `Native Heap`, `Code` and `Stack` PSS rows. Kept in full in `<sample>-meminfo.txt`; compact rows in `<sample>-pss.txt`. |
| `adb shell cat /proc/<pid>/status` | `VmRSS` (current resident set), `VmHWM` (peak RSS), `Threads`. |
| `adb shell top -b -n 1 -p <pid>` | Process `%CPU` and `RES` (`RES` recorded in the parsed companion, not in the summary). |
| `adb shell top -H -b -n 1 -p <pid>` | Per-thread CPU, for attributing a CPU rise to a thread (e.g. a Go runtime worker) — `<sample>-top-threads.txt`. |

Output goes to `tools/perf/out/<UTC>/kernel-<label>/` (gitignored): numbered
`<sample>-*.txt` files, a `capture.txt` manifest (device, ABI, package,
settings), a compact `<sample>-parsed.txt`, and `summary.tsv`.

## Usage

```bash
bash tools/perf/kernel-memory.sh --label stopped-1h --samples 60 --interval 5
bash tools/perf/kernel-memory.sh --label under-load --samples 0 --interval 10  # until Ctrl-C
```

Options: `--label NAME` (default `run`), `--samples N` (default 60; **0 =
until Ctrl-C**, each sample flushed to `summary.tsv` immediately), `--interval
SEC` (positive integer, default 5), `--package com.throneflclash`. The script
requires `adb` on `PATH` and **exactly one** device in `device` state; with
zero or several it exits with a clear message. There is intentionally no
`--serial` option — disconnect extra devices. The `--package` value is
restricted to Android package-name characters and the label is sanitized to a
single path component, so neither can inject a path or shell payload. Use
`--help` for the full synopsis.

The PID is resolved afresh each sample (`pidof`, with a `ps -A` fallback), so
an app restart during a run does not silently sample a stale process; a
missing PID is recorded in `notes` for that sample. If the device ABI is not
`arm64-v8a`, the script prints a warning — such a run is diagnostics only.

## Why PSS / RSS / Threads / CPU are the trustworthy proxies

The app's **Memory panel is not a Go heap readout**. Its `nativePss` number
comes from `dumpsys meminfo`'s `Native Heap` PSS row, which is the whole
process's privatePages+proportional-share accounting for native allocations —
Flutter engine, Dart VM, native libraries and the c-shared Go kernel all share
it. Android does not expose a per-runtime Go heap size to a shell dump, so
`nativePss` must not be interpreted as "Go heap in use" and cannot prove a Go
leak; a rising `nativePss` may be Dart image cache, a rule-set mmap, or Go
buffers. Conversely a stable `nativePss` does not prove Go heap stability.

What *is* directly comparable between builds is the process-level signal the
OS exposes:

- **PSS TOTAL** — proportional-set size across all heaps; the best proxy for
  "how much RAM does the whole process actually consume". Compare the *delta*
  between the first and last sample under the same scenario.
- **RSS / VmHWM** — resident set and its high-water mark (from the kernel's
  own `/proc` status), which catch growth that PSS accounting can mask through
  shared pages; `VmHWM` is the peak over the process lifetime.
- **Threads** — from `/proc/<pid>/status`; thread-count growth under a fixed
  scenario is a strong leak/goroutine-pool warning even when memory looks flat.
- **CPU%** — process total and per-thread (`top -H`); distinguishes a leak
  (memory grows, CPU flat) from a busy-loop or log storm (CPU grows).

Because these are OS-level numbers they are valid on a device without adding
any instrumentation to the app. The follow-up **core actions `runtimeMemory`
and `forceGC`** (announced, not yet available) will expose Go's own heap
statistics (`runtime.MemStats` / `runtime.ReadMemStats`) and allow forcing a GC
before a reading, giving an accurate Go-side leak test. **This harness does not
depend on those actions**; until they land, PSS/RSS/Threads/CPU deltas are the
honest, comparable signal, and any Go-specific conclusion should be flagged as
inferred rather than measured.

## Recommended scenarios

Run each on the same physical arm64 device, same build type (debug or release
— never mix), same settings, no thermal throttling; repeat 3+ times and record
the commit/ABI in `capture.txt`. Start the harness **after** the app is in the
state under test (it does not drive the app).

1. **Stopped / no tunnel** — app foreground, no proxy connection. Sample
   ~10 min (`--samples 120 --interval 5`). Expect PSS/RSS/threads flat; this is
   the idle control that subtracts background drift from the other two runs.
2. **Connected idle** — tunnel connected, no traffic, 10 min. Same sampling.
   Compare idle-delta vs stopped-delta: a rise here is core/rule-set or a
   keep-alive leak, not traffic buffering.
3. **100 Mbps for 5 min** — with the tunnel carrying ~100 Mbps (iperf3 or a
   large download as in [`scenarios.md`](../tools/perf/scenarios.md)), sample
   at a shorter interval (`--samples 60 --interval 5`). Watch for PSS/RSS growth
   that does not plateau, rising thread count, and CPU at equal throughput.
   Take the `collect-device.sh` snapshot while the transfer is still live.

## Reading `summary.tsv`

Columns: `sample`, `elapsed_s`, `rss_kb`, `pss_kb`, `threads`, `cpu_pct`,
`notes`, then `delta_rss_kb`, `delta_pss_kb`, `delta_threads`, `delta_cpu_pct`
— each delta is relative to sample 1 of the same run, so a flat process shows
~0 throughout. `NA` means the dump failed or the field was absent; read
`notes` and `<sample>-errors.txt` before drawing conclusions.

- **Leak signature:** `delta_pss_kb` and `delta_rss_kb` rise monotonically and
  do not return to baseline after the load stops.
- **Thread leak:** `delta_threads` climbs under a fixed scenario while memory
  is flat — inspect `top-H` for the new thread names.
- **Busy loop / log storm:** `cpu_pct` high or rising with flat memory — use
  `<sample>-top-threads.txt` to attribute it.
- **Companion files:** `<sample>-parsed.txt` holds RSS/HWM/threads/CPU and the
  individual Java/Native/Code/Stack PSS rows; `<sample>-pss.txt` holds just the
  PSS rows. Use these to decide *which* heap grew when TOTAL PSS moves.

A number is only a regression if it repeats across 3+ runs at the same build
type and the device was not thermally throttled. Copy absolute values and
deltas (with units) into a new column of [`perf-baseline.md`](perf-baseline.md),
and keep the `out/<UTC>/` directory as raw evidence.
