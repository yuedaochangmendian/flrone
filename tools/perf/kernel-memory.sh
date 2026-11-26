#!/usr/bin/env bash
# Time-series capture of kernel/process resource proxies for com.throneflclash.
#
# Usage:
#   bash tools/perf/kernel-memory.sh [--label NAME] [--samples N] [--interval SEC] [--package PKG]
#
# Read-only: this script NEVER starts/stops the tunnel, force-stops the app,
# clears data or uses root/sudo. It only runs `adb shell` dumps. A physical
# arm64 device is required for numbers that go into docs/perf-baseline.md;
# emulator numbers are diagnostics only (see docs/perf-kernel.md).
#
# Requires `adb` and exactly one device in `device` state. Each sample captures:
#   dumpsys meminfo <pkg>       -> Java/Native/Code/Stack/TOTAL PSS rows
#   cat /proc/<pid>/status      -> VmRSS, VmHWM, Threads
#   top -b -n 1 -p <pid>        -> process CPU/RES
#   top -H -b -n 1 -p <pid>     -> per-thread CPU
# A failing command is recorded in notes / <sample>-errors.txt; it never aborts
# the run. Output: tools/perf/out/<UTC>/kernel-<label>/.

set -uo pipefail

usage() {
    cat <<'EOF'
Usage: bash tools/perf/kernel-memory.sh [options]

Read-only, device-gated kernel resource sampler. Does not start or stop the
tunnel and does not need root. Requires exactly one device in `adb devices`
with state `device`; a physical arm64 device is required for baseline numbers.

Options:
  --label NAME     Output subdirectory name (default: run; sanitized).
  --samples N      Samples to take; 0 = until Ctrl-C (default: 60).
  --interval SEC   Positive integer seconds between samples (default: 5).
  --package PKG    Android package to sample (default: com.throneflclash).
  -h, --help       Show this help and exit.

Output: tools/perf/out/<UTC>/kernel-<label>/summary.tsv + numbered .txt files.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
info() { printf '[kernel-memory] %s\n' "$*"; }

# --- argument parsing --------------------------------------------------------
LABEL="run"
SAMPLES=60
INTERVAL=5
PKG="com.throneflclash"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --label)
            [ "$#" -ge 2 ] || die "--label requires a value"
            LABEL="$2"; shift 2 ;;
        --label=*)
            LABEL="${1#*=}"; shift ;;
        --samples)
            [ "$#" -ge 2 ] || die "--samples requires a value"
            SAMPLES="$2"; shift 2 ;;
        --samples=*)
            SAMPLES="${1#*=}"; shift ;;
        --interval)
            [ "$#" -ge 2 ] || die "--interval requires a value"
            INTERVAL="$2"; shift 2 ;;
        --interval=*)
            INTERVAL="${1#*=}"; shift ;;
        --package)
            [ "$#" -ge 2 ] || die "--package requires a value"
            PKG="$2"; shift 2 ;;
        --package=*)
            PKG="${1#*=}"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "unknown option '$1' (try --help)" ;;
    esac
done

# Validate numeric arguments (no bc, no external numeric tools).
[[ "$SAMPLES" =~ ^[0-9]+$ ]] || die "--samples must be a non-negative integer (got '$SAMPLES')"
[[ "$INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "--interval must be a positive integer number of seconds (got '$INTERVAL')"

# --package is interpolated into `adb shell` commands: allow only Android
# package-name characters so it cannot become a shell/path payload on device.
PKG_RE='^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$'
[[ "$PKG" =~ $PKG_RE ]] || die "invalid --package '$PKG': expected an Android package name (letters, digits, dots, underscores only)."

# The label becomes a single directory component; replace everything outside
# [A-Za-z0-9._-] so it cannot inject separators or traversal into the path.
SAFE_LABEL="$(printf '%s' "$LABEL" | tr -c 'A-Za-z0-9._-' '_')"
# Strip any leading dots so the component can never be "." / ".." / hidden.
SAFE_LABEL="$(printf '%s' "$SAFE_LABEL" | sed 's/^\.*//')"
[ -n "$SAFE_LABEL" ] || SAFE_LABEL="run"

# --- device gate -------------------------------------------------------------
command -v adb >/dev/null 2>&1 || die "adb not found on PATH (install Android platform-tools, e.g. /e/hu/toolchain/android-sdk/platform-tools)."

DEVICES="$(adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')"
# shellcheck disable=SC2086  # serials contain no spaces; count/words are intentional
set -- $DEVICES
COUNT=$#
if [ "$COUNT" -ne 1 ]; then
    if [ "$COUNT" -eq 0 ]; then
        die "no device in 'device' state found. Connect one physical arm64 device, accept the USB debugging prompt, and check 'adb devices'."
    fi
    die "expected exactly one device in 'device' state, found $COUNT: $DEVICES. Disconnect the extras (this script has no --serial option)."
fi
SERIAL="$1"
ADB=(adb -s "$SERIAL")

getprop_val() {
    "${ADB[@]}" shell getprop "$1" 2>/dev/null | tr -d '\r' | awk 'NF {print; exit}'
}
MODEL="$(getprop_val ro.product.model)"
ABI="$(getprop_val ro.product.cpu.abi)"
[ -n "$MODEL" ] || MODEL="NA"
[ -n "$ABI" ] || ABI="NA"

# --- output setup ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="$SCRIPT_DIR/out"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$OUT_ROOT/$STAMP/kernel-$SAFE_LABEL"
mkdir -p "$OUT_DIR" || die "cannot create output directory: $OUT_DIR"
SUMMARY="$OUT_DIR/summary.tsv"
printf 'sample\telapsed_s\trss_kb\tpss_kb\tthreads\tcpu_pct\tnotes\tdelta_rss_kb\tdelta_pss_kb\tdelta_threads\tdelta_cpu_pct\n' >"$SUMMARY" || die "cannot write $SUMMARY"
{
    printf 'capture_utc=%s\n' "$STAMP"
    printf 'device_serial=%s\n' "$SERIAL"
    printf 'device_model=%s\n' "$MODEL"
    printf 'device_abi=%s\n' "$ABI"
    printf 'package=%s\n' "$PKG"
    printf 'label=%s\n' "$SAFE_LABEL"
    printf 'samples=%s\n' "$SAMPLES"
    printf 'interval_s=%s\n' "$INTERVAL"
    printf 'commands: dumpsys meminfo <pkg>; cat /proc/<pid>/status; top -b -n 1 -p <pid>; top -H -b -n 1 -p <pid>\n'
} >"$OUT_DIR/capture.txt" || die "cannot write $OUT_DIR/capture.txt"

info "device=$SERIAL model=$MODEL abi=$ABI package=$PKG output=$OUT_DIR"
if [ "$ABI" != "arm64-v8a" ]; then
    info "WARNING: ABI is '$ABI', not arm64-v8a. Treat this run as diagnostics only (docs/perf-baseline.md)."
fi

# Helpers ---------------------------------------------------------------------
# Read a key from a parsed .txt file; empty when absent.
val_of() { awk -F= -v k="$1" '$1==k {print $2; exit}' "$2" 2>/dev/null; }

# Integer/decimal delta against the first sample; NA if either side is absent.
delta() {
    if [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]] && [[ "$2" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", a - b }'
    else
        printf 'NA'
    fi
}

I=0
trap 'printf "\n"; info "interrupted after $I samples; partial summary: $SUMMARY"; exit 130' INT
trap 'info "terminated after $I samples; summary: $SUMMARY"; exit 143' TERM

START_EPOCH="$(date +%s)"
BASE_RSS=""; BASE_PSS=""; BASE_THREADS=""; BASE_CPU=""

# --- sampling loop -----------------------------------------------------------
while :; do
    I=$((I + 1))
    N="$(printf '%04d' "$I")"
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    EPOCH="$(date +%s)"
    ELAPSED=$((EPOCH - START_EPOCH))
    notes=""

    # Resolve PID per sample: the app may be restarted between samples.
    PID_RAW="$("${ADB[@]}" shell pidof "$PKG" 2>/dev/null | tr -d '\r' | tr ' ' '\n' | awk 'NF {print $1; exit}')"
    if ! [[ "$PID_RAW" =~ ^[0-9]+$ ]]; then
        # Fallback for toybox builds without pidof: last field of `ps -A` is
        # the process name. PKG is validated to contain no shell metacharacters.
        PID_RAW="$("${ADB[@]}" shell ps -A 2>/dev/null | tr -d '\r' |
            awk -v pkg="$PKG" '$NF==pkg {print $1; exit}')"
    fi
    PID=""
    if [[ "$PID_RAW" =~ ^[0-9]+$ ]]; then
        PID="$PID_RAW"
    else
        notes="${notes}pid_unavailable "
    fi

    {
        printf 'sample=%s\n' "$I"
        printf 'timestamp_utc=%s\n' "$TS"
        printf 'epoch_s=%s\n' "$EPOCH"
        printf 'elapsed_s=%s\n' "$ELAPSED"
        printf 'pid=%s\n' "${PID:-NA}"
        printf 'package=%s\n' "$PKG"
        printf 'serial=%s\n' "$SERIAL"
    } >"$OUT_DIR/${N}-meta.txt"

    # 1. meminfo: keep the whole dump so every PSS row is available for audit.
    MF="$OUT_DIR/${N}-meminfo.txt"
    if "${ADB[@]}" shell dumpsys meminfo "$PKG" >"$MF" 2>&1; then
        [ -s "$MF" ] || notes="${notes}meminfo_empty "
    else
        notes="${notes}meminfo_failed "
    fi

    # 2. /proc/<pid>/status: VmRSS, VmHWM, Threads.
    STF="$OUT_DIR/${N}-status.txt"
    if [ -n "$PID" ]; then
        if "${ADB[@]}" shell cat "/proc/$PID/status" >"$STF" 2>&1; then
            [ -s "$STF" ] || notes="${notes}status_empty "
        else
            notes="${notes}status_failed "
        fi
    else
        printf 'pid unavailable; /proc/<pid>/status not captured\n' >"$STF"
    fi

    # 3. process-level top (CPU %).
    TOPF="$OUT_DIR/${N}-top.txt"
    if [ -n "$PID" ]; then
        if "${ADB[@]}" shell top -b -n 1 -p "$PID" >"$TOPF" 2>&1; then
            [ -s "$TOPF" ] || notes="${notes}top_empty "
        else
            notes="${notes}top_failed "
        fi
    else
        printf 'pid unavailable; top -b not captured\n' >"$TOPF"
    fi

    # 4. thread-level top (per-thread CPU).
    HTF="$OUT_DIR/${N}-top-threads.txt"
    if [ -n "$PID" ]; then
        if "${ADB[@]}" shell top -H -b -n 1 -p "$PID" >"$HTF" 2>&1; then
            [ -s "$HTF" ] || notes="${notes}top_threads_empty "
        else
            notes="${notes}top_threads_failed "
        fi
    else
        printf 'pid unavailable; top -H not captured\n' >"$HTF"
    fi

    # --- parse the PSS rows into a compact companion file -------------------
    PSF="$OUT_DIR/${N}-pss.txt"
    awk '
        function firstnum(s,   m) {
            if (match(s, /[0-9][0-9,]*/)) {
                m=substr(s, RSTART, RLENGTH); gsub(/,/, "", m); return m
            }
            return "NA"
        }
        BEGIN { java="NA"; native="NA"; code="NA"; stack="NA"; total="NA" }
        {
            line=$0; sub(/\r$/, "", line)
            if (line ~ /TOTAL[ \t]+PSS:/) {
                s=line; sub(/^.*PSS:[ \t]*/, "", s)
                total=firstnum(s)
                next
            }
            t=line; sub(/^[ \t]+/, "", t)
            if (t ~ /^Native[ \t]+Heap/) {
                sub(/^[^0-9]*/, "", t); native=firstnum(t); next
            }
            if (t ~ /^Dalvik[ \t]+Heap/) {
                sub(/^[^0-9]*/, "", t); java=firstnum(t); next
            }
            if (t ~ /^Code([ \t]|$)/) {
                sub(/^[^0-9]*/, "", t); code=firstnum(t); next
            }
            if (t ~ /^Stack([ \t]|$)/) {
                sub(/^[^0-9]*/, "", t); stack=firstnum(t); next
            }
            if (t ~ /^TOTAL([ \t]|$)/) {
                sub(/^TOTAL[ \t]+/, "", t)
                if (total == "NA") total=firstnum(t)
                next
            }
        }
        END {
            printf "java_pss_kb=%s\n", java
            printf "native_pss_kb=%s\n", native
            printf "code_pss_kb=%s\n", code
            printf "stack_pss_kb=%s\n", stack
            printf "total_pss_kb=%s\n", total
        }
    ' "$MF" >"$PSF"

    PSS_TOTAL="$(val_of total_pss_kb "$PSF")"
    [ -n "$PSS_TOTAL" ] || PSS_TOTAL="NA"

    # --- parse RSS / HWM / Threads from /proc status -------------------------
    RSS_RAW="$(awk '$1=="VmRSS:" {print $2; exit}' "$STF" 2>/dev/null)"
    HWM_RAW="$(awk '$1=="VmHWM:" {print $2; exit}' "$STF" 2>/dev/null)"
    THREADS_RAW="$(awk '$1=="Threads:" {print $2; exit}' "$STF" 2>/dev/null)"
    RSS="$(printf '%s' "$RSS_RAW" | tr -cd '0-9')"
    HWM="$(printf '%s' "$HWM_RAW" | tr -cd '0-9')"
    THREADS="$(printf '%s' "$THREADS_RAW" | tr -cd '0-9')"
    [ -n "$RSS" ] || RSS="NA"
    [ -n "$HWM" ] || HWM="NA"
    [ -n "$THREADS" ] || THREADS="NA"
    if [ -s "$STF" ] && [ "$RSS" = "NA" ]; then notes="${notes}rss_unparsed "; fi
    if [ -s "$STF" ] && [ "$THREADS" = "NA" ]; then notes="${notes}threads_unparsed "; fi

    # --- parse process CPU % (and RES) from top ------------------------------
    # Emit into a temp file, then read the two values back (RES is not needed
    # in summary.tsv but is recorded in the per-sample parsed companion).
    TOP_PARSED="$OUT_DIR/${N}-top-parsed.txt"
    awk -v pid="$PID" '
        $1=="PID" {
            for (i=1; i<=NF; i++) {
                if ($i ~ /CPU/) cpu=i
                if ($i == "RES") res=i
            }
            next
        }
        $1==pid {
            v="NA"
            if (cpu > 0 && cpu <= NF) {
                v=$cpu; gsub(/[^0-9.]/, "", v)
                if (v == "") v="NA"
            }
            printf "cpu_pct=%s\n", v
            r="NA"
            if (res > 0 && res <= NF) {
                r=$res
                if (r ~ /[kK]$/) { sub(/[kK]$/, "", r); r=r+0 }
                else if (r ~ /[mM]$/) { sub(/[mM]$/, "", r); r=(r+0)*1024 }
                else if (r ~ /[gG]$/) { sub(/[gG]$/, "", r); r=(r+0)*1048576 }
            }
            printf "top_res_kb=%s\n", r
            exit
        }
    ' "$TOPF" >"$TOP_PARSED"
    CPU="$(val_of cpu_pct "$TOP_PARSED")"
    TOP_RES="$(val_of top_res_kb "$TOP_PARSED")"
    [ -n "$CPU" ] || CPU="NA"
    [ -n "$TOP_RES" ] || TOP_RES="NA"
    if [ -s "$TOPF" ] && [ "$CPU" = "NA" ]; then notes="${notes}cpu_unparsed "; fi

    # --- compact parsed companion + error log -------------------------------
    {
        printf 'timestamp_utc=%s\n' "$TS"
        printf 'elapsed_s=%s\n' "$ELAPSED"
        printf 'pid=%s\n' "${PID:-NA}"
        printf 'package=%s\n' "$PKG"
        printf 'rss_kb=%s\n' "$RSS"
        printf 'hwm_kb=%s\n' "$HWM"
        printf 'threads=%s\n' "$THREADS"
        printf 'top_res_kb=%s\n' "$TOP_RES"
        printf 'cpu_pct=%s\n' "$CPU"
        printf 'java_pss_kb=%s\n' "$(val_of java_pss_kb "$PSF")"
        printf 'native_pss_kb=%s\n' "$(val_of native_pss_kb "$PSF")"
        printf 'code_pss_kb=%s\n' "$(val_of code_pss_kb "$PSF")"
        printf 'stack_pss_kb=%s\n' "$(val_of stack_pss_kb "$PSF")"
        printf 'total_pss_kb=%s\n' "$PSS_TOTAL"
    } >"$OUT_DIR/${N}-parsed.txt"

    notes="${notes% }"
    printf '%s\n' "$notes" >"$OUT_DIR/${N}-errors.txt"

    # --- deltas relative to sample 1 (appended per sample, so always flushed) -
    if [ "$I" -eq 1 ]; then
        BASE_RSS="$RSS"; BASE_PSS="$PSS_TOTAL"; BASE_THREADS="$THREADS"; BASE_CPU="$CPU"
    fi
    DRSS="$(delta "$RSS" "$BASE_RSS")"
    DPSS="$(delta "$PSS_TOTAL" "$BASE_PSS")"
    DTHREADS="$(delta "$THREADS" "$BASE_THREADS")"
    DCPU="$(delta "$CPU" "$BASE_CPU")"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$I" "$ELAPSED" "$RSS" "$PSS_TOTAL" "$THREADS" "$CPU" "$notes" \
        "$DRSS" "$DPSS" "$DTHREADS" "$DCPU" >>"$SUMMARY"

    if [ "$SAMPLES" -gt 0 ] && [ "$I" -ge "$SAMPLES" ]; then
        info "done: $I samples -> $OUT_DIR"
        break
    fi
    sleep "$INTERVAL"
done
