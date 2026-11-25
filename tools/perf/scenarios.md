# Fixed performance scenarios

All commands are Git Bash / adb from the repository root. Substitute `<serial>`
with the device serial when more than one device is online (`adb -s <serial>`).
`PKG=com.throneflclash`, launcher activity `io.flrone.flutter.FlroneActivity`
(from `app/src/main/AndroidManifest.xml`). Keep the device on a charger, in
airplane mode unless the scenario needs network, with the same screen brightness
and no thermal throttling; run each scenario 3+ times (cold start 5 times).

Define once per shell (Git Bash):

```bash
PKG=com.throneflclash
ACT=com.throneflclash/io.flrone.flutter.FlroneActivity
adb() { command adb "$@"; }   # add: -s <serial> after `adb` when needed
```

For every scenario, capture a trace where indicated and always finish with
`collect-device.sh` while the relevant state is still on screen. Use a fresh
output directory per iteration (the script timestamps them automatically) and
record the iteration number next to it.

---

## 1. Cold start x5

**Preparation** (once before the five runs): force-stop the app, wait 2 s, and
make sure no proxy connection is active (start-up work should be deterministic).

```bash
adb shell am force-stop "$PKG"; sleep 2
```

**Each iteration:**

```bash
adb shell am force-stop "$PKG"; sleep 2
adb shell am start -W -S "$ACT"        # -S = force stop first; -W = wait for launch
# When the first frame is visible, note the wall time from `adb logcat -b events -d`
# (am_proc_start / am_activity_launch_time events).
```

`am start -W` prints `ThisTime`, `TotalTime`, `WaitTime` (ms). Record all three;
`TotalTime` is the cold-start number.

**Metrics:** TotalTime/ThisTime/WaitTime (ms) per iteration (all 5), median and
max; `gfxinfo.txt` startup frame time; `cpuinfo.txt` load right after launch;
`logcat-events.txt` launch timestamps; PSS TOTAL from `meminfo.txt` after the
home screen settles (~5 s).

**Pass criteria:** median TotalTime <= baseline median x 1.05 (no regression);
max <= median x 1.3 (no flaky outlier); PSS after settle <= baseline + 10 MB;
no increase in startup stack traces in logcat.

## 2. Hot start

Bring the app to background without killing its process, then relaunch:

```bash
adb shell input keyevent KEYCODE_HOME; sleep 2
adb shell am start -W "$ACT"           # no -S: existing process resumed
```

**Metrics:** ThisTime/TotalTime/WaitTime (ms), 3+ iterations median; PSS from
`meminfo.txt` (should be close to the cold-start settled value); events log
showing no `am_proc_start` (proves the process was not killed).

**Pass criteria:** TotalTime <= 50% of cold-start TotalTime (process really
reused) and <= baseline hot median x 1.05.

## 3. Scroll: dashboard / proxies / logs (30 s each)

**Preparation:** connect the tunnel so connections are populated (start a proxy
node from the dashboard). For the logs screen, set the recording level to
`debug` first (see scenario 5) so there is content to scroll. Open each page and
scroll continuously for 30 s:

```bash
# Three separate 30 s runs; capture gfxinfo between pages to attribute frames.
adb shell input touchscreen swipe 540 1600 540 400 120   # repeat for 30 s
bash tools/perf/collect-device.sh <serial>              # after each page
```

If `input swipe` feels too mechanical, use `adb shell input touchscreen swipe`
in a loop (`for i in $(seq 1 40); do ...; sleep 0.6; done`). Keep the gesture
count identical across runs.

**Metrics:** from `gfxinfo.txt` — 50th/90th/95th percentile frame time (ms),
Janky frames, frames >16 ms, total frames rendered in 30 s; `cpuinfo.txt`
process CPU %; PSS TOTAL delta vs idle; Perfetto slice CPU ms for the UI thread
if a trace was taken (start `perfetto.cfg` before the scroll).

**Pass criteria:** 95th percentile frame time <= 16.7 ms (60 Hz) or <= baseline
x 1.05; Janky frames <= baseline + 10% ; no growth in PSS after repeated scrolls
(memory leak check: 30 s scroll then 30 s idle, PSS should return near start).

## 4. 1000-connection list

**How to populate:** connect the tunnel and generate many concurrent flows. A
reliable recipe is 1000 short TCP connects through the proxy to a local server
on the host, or 20 parallel iperf3 sessions with 50 streams each; keep the
connections open so they appear in the connections page. Alternatively, load a
saved 1000-connection capture if the test harness provides one. Record exactly
how the load was generated in the baseline table notes.

```bash
# Example: host-side generator through the tunnel's HTTP proxy (adapt port/host)
for i in $(seq 1 1000); do
  curl -sS --max-time 30 -x http://127.0.0.1:<mixed-port> \
    "http://<host-ip>:<test-port>/?id=$i" -o /dev/null &
  [ $((i % 50)) -eq 0 ] && wait
done; wait
```

Keep >1000 rows visible in the connections page, then:

```bash
bash tools/perf/collect-device.sh <serial>
```

**Metrics:** count of rows actually displayed (confirm ~1000, not a truncated
list); PSS TOTAL and Java/native heap (MB); `cpuinfo.txt`; time to first frame
after opening the page (stopwatch or Perfetto `am_activity_launch_time`);
scroll 95th percentile frame time from `gfxinfo.txt`; Perfetto binder
transactions/s for the connections feed.

**Pass criteria:** first-frame time <= baseline x 1.1; PSS <= baseline + 20 MB
at 1000 rows; scrolling 95th percentile <= 16.7 ms (or <= baseline x 1.1);
row count exact (no silent cap below 1000 unless documented as a product limit).

## 5. DEBUG log storm (60 s)

**Enable the debug level in-app:** Tools -> Logcat page -> filter/recording-level
button -> select `debug`. This writes `logLevel=debug` to the core setting and
`logcatLevel=debug` to preferences, restarting the service so the kernel emits
debug lines (see `flutter/lib/pages/logs.dart` `_chooseLevel`). Verify with:

```bash
adb shell "ps -A | grep logcat"        # tail filter should be *:D or looser
```

Then let the device run for 60 s under a normal browsing/proxy load, and capture:

```bash
sleep 60
bash tools/perf/collect-device.sh <serial>
# Optional: count lines captured by the app's log ring via the UI or a trace slice
```

Restore the previous level afterwards (same menu, e.g. `info`).

**Metrics:** log lines recorded in 60 s (from the app's Logs/Logcat screen count
or redacted export); PSS TOTAL and Java heap growth during the storm; `cpuinfo.txt`
process CPU %; gfxinfo jank if the log screen is open; Perfetto CPU ms for the
log-processing isolate/thread; binder transactions/s.

**Pass criteria:** no OOM and no ANR during 60 s; PSS growth <= 25 MB after
subtracting the baseline idle growth; CPU % <= baseline x 1.2 at equal log
volume; UI remains responsive (no janky frame ratio > 2x baseline). Document the
log volume with the numbers — CPU per 1000 lines is a useful derived metric.

## 6. 100 Mbps download through the tunnel (5 min)

**Prerequisites:** iperf3 on host and device (`adb push iperf3 /data/local/tmp/iperf3;
adb shell chmod +x /data/local/tmp/iperf3`), or a large file on a host HTTP
server for the fallback. Start `iperf3 -s` on the host, connect the app's tunnel,
and confirm traffic flows through it (dashboard traffic graph climbs).

```bash
# Host (terminal 1):
iperf3 -s
# Device (terminal 2), 5 minutes through the tunnel; -R reverses if needed:
adb shell /data/local/tmp/iperf3 -c <host-ip> -p 5201 -t 300 -b 100M -i 10
# Fallback (large file, measure bytes/time):
# curl -x http://127.0.0.1:<mixed-port> -o /dev/null -w '%{speed_download}\n' \
#   http://<host-ip>:8000/large.bin
```

Start a 300 s Perfetto trace (edit `duration_ms: 300000` in a copy of
`perfetto.cfg`) if CPU profiling is needed. Capture device state at minute 5
while the transfer is still running:

```bash
bash tools/perf/collect-device.sh <serial>
```

**Metrics:** achieved throughput (Mbps, from iperf3 final report); `dumpsys
meminfo` PSS/native heap (check for buffer bloat/leak); `cpuinfo.txt` process
CPU %; Perfetto CPU ms for tunnel threads; bytes sent/received from the app's
dashboard traffic counters; device temperature if available (`adb shell dumpsys
batterystats` or `cat /sys/class/thermal/thermal_zone*/temp`).

**Pass criteria:** sustained throughput >= 90 Mbps (>= 90% of target) at 5 min
(no decay); PSS growth over 5 min <= 20 MB; CPU % <= baseline x 1.1 at equal
throughput; no thermal-throttle collapse (throughput at 5 min >= 90% of the
first-minute average).

## 7. DNS: 1000 queries through the tunnel

**How to generate:** with the tunnel connected and DNS hijack/fake-ip route
active (check the dashboard shows DNS queries), issue exactly 1000 unique lookups
from the device through the tunnel. `dig` may be unavailable; a small shell loop
over `nslookup` or an on-device `aosp` DNS probe works. Unique names avoid cache
hits (append an index subdomain).

```bash
adb shell 'for i in $(seq 1 1000); do
  nslookup "q$i.test.example" 127.0.0.1 >/dev/null 2>&1 || true
  [ $((i % 100)) -eq 0 ] && echo "$i queries"
done'
bash tools/perf/collect-device.sh <serial>
```

If `127.0.0.1` is not the local DNS listener, use the DNS server address shown in
the app's connection/DNS panel. Confirm via the UI that ~1000 queries were
counted (cache misses, not hits).

**Metrics:** DNS queries counted by the app (target 1000); elapsed wall time (s)
and queries/s; PSS TOTAL/heap after the burst; `cpuinfo.txt` CPU %; Perfetto CPU
ms for DNS worker threads; logcat event timestamps for start/end.

**Pass criteria:** >= 990 of 1000 queries reach the tunnel resolver (allow small
timeout noise); queries/s >= baseline x 0.95; PSS growth <= 10 MB; no crash/ANR.

## 8. Rule-set load / core start

**Preparation:** install a representative rule set (from the app's rule-set
screen) and have a config with it selected. Force-stop the app so core start is
cold. Optionally start a trace with `perfetto.cfg` adjusted to `duration_ms:
30000`.

```bash
adb shell am force-stop "$PKG"; sleep 2
adb shell am start -W -S "$ACT"
# Observe the time from launch to "core started / rules ready" in the UI or logcat
# (kernel startup and rule-set load events), then:
bash tools/perf/collect-device.sh <serial>
```

Repeat 5 times if the measurement is noisy (rule download from cache only — do
not mix network download time into core-start time).

**Metrics:** time to core-ready (ms) and to rule-set-ready (ms) from logcat
timestamps or stopwatch; `TotalTime` from `am start -W`; PSS TOTAL after ready;
`cpuinfo.txt` CPU %; Perfetto slices for profile parse/rule compile; number of
rules loaded (from the UI/status line).

**Pass criteria:** core-ready median <= baseline x 1.05; rule-set-ready median
<= baseline x 1.05; rules count identical before/after (no silent drop); PSS
after ready <= baseline + 10 MB.

---

## General notes

- Always record with the same build type (debug vs release) — debug builds are
  slower and have higher PSS; never mix them in one comparison column.
- `collect-device.sh` force-stops the app after the meminfo capture. If you need
  the live state (1000-row list, log storm), take the gfxinfo/cpuinfo numbers
  from that same capture and do not rely on the post-force-stop app state.
- For table entry, copy the numeric values (with units) into
  `docs/perf-baseline.md`, one column per run, and keep the `out/<timestamp>/`
  directory as the raw evidence.
