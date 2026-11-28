#!/usr/bin/env bash
# Build the kernel as a plain c-shared library, without gomobile/gobind.
#
#   bash buildScript/build-cshared.sh <throne-checkout> [dest]
#
# The checkout must already carry the bridge overlay (apply-core-patch.sh).
# The cgoentry wrapper is copied into <checkout>/core/cgoentry; Go requires
# exactly one main package for -buildmode=c-shared while the bridge lives in
# the library package ThroneCore/mobile.
#
# Output: <dest>/<abi>/libthrone.so (plus the generated header), three ABIs by
# default. This is the foundation for the strict Bettbox bridge; the gomobile
# AAR remains the shipped path until the Kotlin host stops importing gobind.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
THRONE_DIR="${1:?usage: build-cshared.sh <throne-checkout> [dest]}"
DEST="${2:-$ROOT/deployment/android-cshared}"

test -d "$THRONE_DIR/core/mobile" || {
    echo "error: $THRONE_DIR does not look like a Throne checkout (no core/mobile)" >&2
    exit 2
}
test -d "$THRONE_DIR/core/cgoentry" || mkdir -p "$THRONE_DIR/core/cgoentry"
cp "$HERE/cgoentry/main.go" "$THRONE_DIR/core/cgoentry/main.go"

NDK="${ANDROID_NDK_HOME:-${ANDROID_HOME:-$HOME/Android/Sdk}/ndk/28.2.13676358}"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/windows-x86_64/bin"
if [ ! -d "$TOOLCHAIN" ]; then
    TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin"
fi
test -d "$TOOLCHAIN" || {
    echo "error: NDK toolchain not found under $NDK (set ANDROID_NDK_HOME)" >&2
    exit 2
}

GO="${GO:-go}"
command -v "$GO" >/dev/null 2>&1 || {
    echo "error: go not found (set GO or PATH; core/go.mod requires go 1.26+)" >&2
    exit 2
}

# Mirrors script/build_android.sh, minus with_gvisor (this fork runs sing-tun's
# own stacks only). The linkname flags are required by sing-box on Go 1.27.
TAGS="with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_openconnect,with_naive_outbound,badlinkname,tfogo_checklinkname0"

cd "$THRONE_DIR/core"
VERSION_SINGBOX="$("$GO" list -m -f '{{.Version}}' github.com/sagernet/sing-box)"
# -s -w strips the ELF symbol table and DWARF (smaller .so) but does NOT break Go
# pprof: runtime/pprof resolves function names from the runtime's embedded function
# table (pclntab), which the linker always keeps. What is lost is native tooling
# (gdb/addr2line on the ELF); Go CPU/heap/goroutine profiles keep full symbols.
# Keep -s -w — the debug-gated diagnostics.profile action (profile_actions.go) still
# yields readable profiles on a device.
LDFLAGS="-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=${VERSION_SINGBOX} -X runtime.godebugDefault=multipathtcp=0"

# PGO is opt-in and never on by default: an unrepresentative profile can make
# the core slower, and profiling a desktop host does not model the Android proxy
# workload. PGO=auto picks core/cgoentry/default.pgo when it exists; PGO=<path>
# uses an explicit profile. The capture/measure procedure lives in
# docs/perf-kernel.md; a profile is only worth committing after an arm64
# throughput/CPU comparison, which this build cannot make by itself.
PGO_FLAGS=()
case "${PGO:-off}" in
    off|0|"") ;;
    auto)
        if [ -f "$THRONE_DIR/core/cgoentry/default.pgo" ]; then
            PGO_FLAGS=(-pgo=auto)
            echo "PGO=auto: using core/cgoentry/default.pgo"
        else
            echo "warning: PGO=auto requested but core/cgoentry/default.pgo is missing; building without PGO" >&2
        fi
        ;;
    *)
        PGO_FLAGS=(-pgo="$PGO")
        echo "PGO: using profile $PGO"
        ;;
esac

build_abi() {
    local abi="$1" goarch="$2" cc="$3" extra="${4:-}"
    local out="$DEST/$abi"
    local ldflags="$LDFLAGS"
    # Android 15+ devices may use 16 KB pages; the two 64-bit ABIs must carry
    # LOAD align 0x4000. Pass it explicitly instead of relying on the linker's
    # default, and verify it in the CI action.
    case "$goarch" in
        arm64|amd64) ldflags="$ldflags -extldflags=-Wl,-z,max-page-size=16384" ;;
    esac
    mkdir -p "$out"
    echo "building $abi ($goarch${extra:+ $extra})"
    env GOOS=android GOARCH="$goarch" GOARM="${extra#GOARM=}" CGO_ENABLED=1 GOTOOLCHAIN=local \
        CC="$TOOLCHAIN/$cc" \
        "$GO" build -buildmode=c-shared -trimpath -tags "$TAGS" -ldflags "$ldflags" \
        "${PGO_FLAGS[@]}" \
        -o "$out/libthrone.so" ./cgoentry
}

ABIS="${ABIS:-arm64-v8a,armeabi-v7a,x86_64}"
CORE_JOBS="${CORE_JOBS:-1}"
case "$CORE_JOBS" in
    ''|*[!0-9]*) echo "error: CORE_JOBS must be a positive integer" >&2; exit 2 ;;
esac
[ "$CORE_JOBS" -ge 1 ] || { echo "error: CORE_JOBS must be at least 1" >&2; exit 2; }

build_requested_abi() {
    local abi="$1"
    case "$abi" in
        arm64-v8a) build_abi "$abi" arm64 aarch64-linux-android24-clang ;;
        armeabi-v7a) build_abi "$abi" arm armv7a-linux-androideabi24-clang GOARM=7 ;;
        x86_64) build_abi "$abi" amd64 x86_64-linux-android24-clang ;;
        *) echo "error: unknown ABI $abi" >&2; return 2 ;;
    esac
}

IFS=',' read -r -a requested <<< "$ABIS"
if [ "$CORE_JOBS" -le 1 ]; then
    for abi in "${requested[@]}"; do
        build_requested_abi "$abi" || exit $?
    done
else
    # Each ABI is an independent cgo build with its own GOARCH cache. Parallel
    # jobs shorten wall time but multiply peak memory, so this is opt-in
    # (CORE_JOBS=3 on a workstation, leave 1 in constrained CI containers).
    pids=()
    for abi in "${requested[@]}"; do
        build_requested_abi "$abi" &
        pids+=("$!")
    done
    status=0
    for pid in "${pids[@]}"; do
        wait "$pid" || status=1
    done
    [ "$status" -eq 0 ] || exit 1
fi

echo "built c-shared kernel from $THRONE_DIR into $DEST"
