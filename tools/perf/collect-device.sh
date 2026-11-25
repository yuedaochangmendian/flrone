#!/usr/bin/env bash
# One-shot device snapshot for a throne-flclash-ui performance run.
#
# Usage:
#   bash tools/perf/collect-device.sh                 # device discovery, then snapshot
#   bash tools/perf/collect-device.sh <serial>        # explicit adb serial (when >1 device)
#   PKG=com.example.other bash tools/perf/collect-device.sh
#
# Creates tools/perf/out/<UTC timestamp>/ and writes plain-text capture files there.
# The only state-changing adb command is `am force-stop` (used solely to reset gfxinfo
# frame counters before the gfxinfo capture); no app data is cleared or modified.
# Safe to run while the app is in any state.

set -euo pipefail

PKG="${PKG:-com.throneflclash}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_ROOT="$SCRIPT_DIR/out"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$OUT_ROOT/$STAMP"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '[collect-device] %s\n' "$*"; }

command -v adb >/dev/null 2>&1 || die "adb not found on PATH (install Android platform-tools, e.g. /e/hu/toolchain/android-sdk/platform-tools)."

# --- device selection --------------------------------------------------------
SERIAL="${1:-${ANDROID_SERIAL:-}}"
if [ -n "$SERIAL" ]; then
    ADB=(adb -s "$SERIAL")
else
    ADB=(adb)
fi

DEVICES="$("${ADB[@]}" devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1}')"
if [ -z "$DEVICES" ]; then
    die "no authorized device found. Connect a device, accept the USB debugging prompt, and check 'adb devices'."
fi
if [ -z "$SERIAL" ]; then
    COUNT="$(printf '%s\n' "$DEVICES" | wc -l | tr -d ' ')"
    if [ "$COUNT" -gt 1 ]; then
        die "multiple devices online; pass a serial explicitly: bash tools/perf/collect-device.sh <serial>. Devices: $(printf '%s' "$DEVICES" | tr '\n' ' ')"
    fi
    SERIAL="$DEVICES"
    ADB=(adb -s "$SERIAL")
fi

# --- package check -----------------------------------------------------------
if ! "${ADB[@]}" shell pm path "$PKG" >/dev/null 2>&1; then
    die "package '$PKG' is not installed on device $SERIAL. Install the build under test first."
fi

mkdir -p "$OUT_DIR"
info "device=$SERIAL package=$PKG output=$OUT_DIR"

# --- captures (none are destructive) ----------------------------------------
info "device properties"
{
    for prop in ro.product.model ro.product.brand ro.product.manufacturer ro.product.device \
                ro.product.name ro.product.board ro.product.cpu.abi ro.product.cpu.abilist \
                ro.build.version.release ro.build.version.sdk ro.build.display.id; do
        printf '%s=%s\n' "$prop" "$("${ADB[@]}" shell getprop "$prop" 2>/dev/null | tr -d '\r')"
    done
} >"$OUT_DIR/device.props.txt" || true

info "dumpsys meminfo (before force-stop)"
"${ADB[@]}" shell dumpsys meminfo "$PKG" >"$OUT_DIR/meminfo.txt" 2>&1 || true

# gfxinfo counters are cumulative; force-stop first so the numbers describe only
# the run that follows. This is the single allowed state-changing command.
info "reset gfxinfo frame counters via am force-stop"
"${ADB[@]}" shell am force-stop "$PKG" >"$OUT_DIR/force-stop.txt" 2>&1 || true
sleep 1
"${ADB[@]}" shell dumpsys gfxinfo "$PKG" reset >"$OUT_DIR/gfxinfo-reset.txt" 2>&1 || true

info "dumpsys gfxinfo (post-reset; re-launch the app to accumulate frames)"
"${ADB[@]}" shell dumpsys gfxinfo "$PKG" >"$OUT_DIR/gfxinfo.txt" 2>&1 || true

info "logcat events buffer (dump only, no clearing)"
"${ADB[@]}" logcat -b events -d >"$OUT_DIR/logcat-events.txt" 2>&1 || true

info "dumpsys cpuinfo"
"${ADB[@]}" shell dumpsys cpuinfo >"$OUT_DIR/cpuinfo.txt" 2>&1 || true

# --- app-private profile files (best effort) --------------------------------
# run-as works only for debuggable builds; on release builds it fails, and we
# record that fact instead of aborting the whole capture.
info "app-private profile files (best effort, debuggable builds only)"
PROFILE_DIR="$OUT_DIR/profiles"
ran_as=false
if "${ADB[@]}" shell run-as "$PKG" ls files/profiles >"$OUT_DIR/profiles-ls.txt" 2>&1; then
    ran_as=true
    mkdir -p "$PROFILE_DIR"
    # Pull each entry individually via exec-out; guard every file so a single
    # unreadable entry cannot abort the run. Only files/profiles is touched.
    while IFS= read -r entry; do
        entry="$(printf '%s' "$entry" | tr -d '\r')"
        [ -n "$entry" ] || continue
        safe="$(printf '%s' "$entry" | tr '/\\' '__')"
        case "$safe" in .|..) continue;; esac
        "${ADB[@]}" exec-out run-as "$PKG" cat "files/profiles/$entry" >"$PROFILE_DIR/$safe" 2>"$PROFILE_DIR/$safe.err" || true
    done <"$OUT_DIR/profiles-ls.txt"
else
    printf 'run-as unavailable (release build or app not debuggable); profile files not collected.\n' \
        >"$OUT_DIR/profiles-ls.txt"
fi
if [ "$ran_as" = false ]; then
    info "run-as unavailable; skipped profile pull (see profiles-ls.txt)"
fi

# --- manifest ---------------------------------------------------------------
{
    printf 'capture_utc=%s\n' "$STAMP"
    printf 'device_serial=%s\n' "$SERIAL"
    printf 'package=%s\n' "$PKG"
    printf 'adb=%s\n' "$(command -v adb)"
    printf 'profile_files_collected=%s\n' "$ran_as"
    printf 'commands: getprop, dumpsys meminfo, am force-stop, dumpsys gfxinfo reset/dump, logcat -b events -d, dumpsys cpuinfo, run-as ls files/profiles\n'
} >"$OUT_DIR/capture.txt"

info "done: $OUT_DIR"
