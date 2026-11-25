#!/usr/bin/env bash
# Host-only wall-clock baseline for Flutter static analysis and targeted tests.
# No device, no emulator, no app changes. Uses the CI-pinned Flutter SDK.
#
# Usage:
#   bash tools/perf/host-baseline.sh
#   FLUTTER_BIN=/path/to/flutter bash tools/perf/host-baseline.sh
#
# Results land in tools/perf/out/host/<UTC timestamp>/ as separate .txt files
# (stdout, stderr, wall time, SDK version, commit). Timings here are diagnostics
# only — they are NOT representative of on-device performance and must not be
# entered into the device baseline table in docs/perf-baseline.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT_ROOT="$SCRIPT_DIR/out/host"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$OUT_ROOT/$STAMP"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '[host-baseline] %s\n' "$*"; }

# Documented pinned toolchain path; override with FLUTTER_BIN if installed elsewhere.
FLUTTER_BIN="${FLUTTER_BIN:-/e/hu/toolchain/flutter-3.50.0/bin/flutter}"
if [ ! -x "$FLUTTER_BIN" ]; then
    die "Flutter SDK not found at $FLUTTER_BIN. Install the CI pin (3.50.0) or set FLUTTER_BIN."
fi
[ -d "$REPO_ROOT/flutter" ] || die "flutter/ module not found under $REPO_ROOT."
command -v git >/dev/null 2>&1 || die "git not found on PATH."

mkdir -p "$OUT_DIR"
info "sdk=$FLUTTER_BIN output=$OUT_DIR"

"$FLUTTER_BIN" --version >"$OUT_DIR/flutter-version.txt" 2>&1 || true
git -C "$REPO_ROOT" rev-parse HEAD >"$OUT_DIR/commit.txt" 2>&1 || true
date -u '+started_utc=%Y-%m-%dT%H:%M:%SZ' >"$OUT_DIR/meta.txt"

# Time a command, capturing its output separately; never abort on a failing lint/test.
timed() {
    local name="$1"; shift
    local start end rc
    start="$(date +%s%N)"
    set +e
    "$@" >"$OUT_DIR/$name.stdout.txt" 2>"$OUT_DIR/$name.stderr.txt"
    rc=$?
    set -e
    end="$(date +%s%N)"
    local ms=$(( (end - start) / 1000000 ))
    printf '%s wall_ms=%s exit=%s\n' "$name" "$ms" "$rc" | tee -a "$OUT_DIR/timings.txt"
    return 0
}

cd "$REPO_ROOT/flutter"

info "flutter analyze --fatal-infos"
timed analyze "$FLUTTER_BIN" analyze --fatal-infos

# Targeted tests exercising the hot data paths (bulk feeds, logs, connections,
# dashboard cards, DNS/IP caches, rule sets). Keep this list fixed across runs.
TEST_TARGETS=(
    test/box_test.dart
    test/bridge_log_frame_test.dart
    test/connections_test.dart
    test/dashboard_cards_test.dart
    test/dashboard_editor_test.dart
    test/fixed_list_test.dart
    test/ip_quality_cache_test.dart
    test/ip_quality_test.dart
    test/log_level_test.dart
    test/logs_test.dart
    test/rule_set_catalog_test.dart
)

info "flutter test (${#TEST_TARGETS[@]} targeted files)"
timed test "$FLUTTER_BIN" test "${TEST_TARGETS[@]}"

date -u '+finished_utc=%Y-%m-%dT%H:%M:%SZ' >>"$OUT_DIR/meta.txt"
info "done: $OUT_DIR/timings.txt"
