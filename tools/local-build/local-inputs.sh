#!/usr/bin/env bash
# Prepare every build input `.github/actions/*` prepares, so a full Gradle build
# (and the unit-test job) can run on this machine:
#
#   source tools/local-build/local-env.sh
#   bash tools/local-build/local-inputs.sh          # all inputs
#   bash tools/local-build/local-inputs.sh --check  # verify presence AND content stamps
#   bash tools/local-build/local-inputs.sh --only=flutter,routeprofiles
#   bash tools/local-build/local-inputs.sh --force-core   # rebuild the kernel even if unchanged
#   bash tools/local-build/local-inputs.sh --force        # rebuild everything
#
# The core and Flutter steps are content-keyed: an unchanged overlay/AAR input
# set reuses the built artifacts, a changed one rebuilds them. --check reports
# a stale kernel/AAR, so a release cannot ship bytes from an older overlay.
#
# Steps, mirroring the CI actions:
#   flutter        flutter/build/host/outputs/repo (io.flrone.ui:flutter_release)
#   core           deployment/android-cshared/<abi>/libthrone.so
#   schema         app/src/main/assets/schema/sing-box.json
#   routeprofiles  app/src/main/assets/routeprofiles/srslist.h + profile/
#   dashboard      app/src/main/assets/sb-dashboard/index.html
#
# All remote pulls use the pins the workflows use (THRONE_CORE_REF in
# nb4a.properties, SRS_REF/PROFILE_REF in the routeprofiles action, DASHBOARD_REF
# in the dashboard action), so a local build is the same snapshot CI builds.

set -euo pipefail

cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source tools/local-build/local-env.sh

ROOT="$PWD"
THRONE_DIR="$LOCAL_BUILD_CACHE/Throne-$(sed -n 's/^THRONE_CORE_REF=//p' nb4a.properties | tr -d '\r[:space:]')"
CORE_DEST="$ROOT/deployment/android-cshared"
CORE_STAMP="$CORE_DEST/.input-stamp"
SCHEMA_OUT="$ROOT/app/src/main/assets/schema/sing-box.json"
ROUTE_DEST="$ROOT/app/src/main/assets/routeprofiles"
DASH_DEST="$ROOT/app/src/main/assets/sb-dashboard"
AAR_REPO="$ROOT/flutter/build/host/outputs/repo"
AAR_STAMP="$AAR_REPO/io/flrone/ui/flutter_release/1.0/.input-stamp"

pin_from() { # pin_from <file> <VAR>
    sed -n "s/.*\b$2=\([0-9a-f]\{7,40\}\).*/\1/p" "$1" | head -1
}

say() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# Content hashes, not mtimes: a checkout or a touch must not decide whether the
# shipped native kernel / Flutter AAR is current. Only tracked files are hashed
# (a release builds a committed tag; untracked edits are not part of it).
hash_tracked() { # hash_tracked <path>...
    ( cd "$ROOT" && git ls-files -z --cached --others --exclude-standard -- "$@" | xargs -0 -r sha256sum ) \
        | sha256sum | cut -d' ' -f1
}

core_input_stamp() {
    local ref go_version ndk_version pgo_key
    ref="$(sed -n 's/^THRONE_CORE_REF=//p' nb4a.properties | tr -d '\r[:space:]')"
    go_version="$("$GO" version 2>/dev/null || echo missing)"
    ndk_version="$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties" 2>/dev/null | head -1)"
    pgo_key="${PGO:-off}"
    case "$pgo_key" in
        auto)
            pgo_key="auto:$(sha256sum "$THRONE_DIR/core/cgoentry/default.pgo" 2>/dev/null | cut -d' ' -f1)" ;;
        off|0|"") ;;
        *)
            [ -f "$pgo_key" ] && pgo_key="file:$(sha256sum "$pgo_key" | cut -d' ' -f1)" ;;
    esac
    {
        hash_tracked buildScript/core-patch buildScript/cgoentry buildScript/build-cshared.sh buildScript/apply-core-patch.sh
        printf '%s\n' "core-ref=$ref" "go=$go_version" "ndk=$ANDROID_NDK_HOME" "ndk-rev=$ndk_version" \
            "singbox=${SINGBOX_EXT_VERSION:-default}" "sing=${SING_FORK_VERSION:-default}" \
            "abis=${ABIS:-arm64-v8a,armeabi-v7a,x86_64}" "pgo=$pgo_key"
    } | sha256sum | cut -d' ' -f1
}

flutter_input_stamp() {
    local flutter_version
    # `flutter --version` costs several seconds (it may touch the SDK). The
    # cached version JSON carries the same framework revision/channel; fall
    # back to the command only when the SDK was installed without it.
    flutter_version="$(sha256sum "$(dirname "$FLUTTER_BIN")/cache/flutter.version.json" 2>/dev/null | cut -d' ' -f1)"
    if [ -z "$flutter_version" ]; then
        flutter_version="$("$FLUTTER_BIN" --version 2>/dev/null | head -1)"
    fi
    {
        hash_tracked flutter/lib flutter/assets flutter/shaders flutter/android \
            flutter/pubspec.yaml flutter/pubspec.lock flutter/analysis_options.yaml \
            flutter/flclash-manifest.json
        printf '%s\n' "flutter=$flutter_version" "aar=release-no-debug-no-profile"
    } | sha256sum | cut -d' ' -f1
}

core_libs_present() {
    for abi in arm64-v8a armeabi-v7a x86_64; do
        [ -s "$CORE_DEST/$abi/libthrone.so" ] || return 1
    done
}

aar_present() {
    [ -d "$AAR_REPO/io/flrone/ui" ]
}

# --- steps --------------------------------------------------------------------

step_flutter() {
    local stamp
    stamp="$(flutter_input_stamp)"
    if [ "${FORCE_FLUTTER:-false}" != true ] && aar_present && [ -f "$AAR_STAMP" ] \
        && [ "$(cat "$AAR_STAMP")" = "$stamp" ]; then
        say "Flutter AAR inputs unchanged ($stamp); reusing $AAR_REPO"
        return
    fi
    say "Flutter AAR ($("$FLUTTER_BIN" --version 2>/dev/null | head -1))"
    ( cd flutter && "$FLUTTER_BIN" pub get && "$FLUTTER_BIN" build aar --no-debug --no-profile )
    aar_present || die "flutter build aar produced no io.flrone.ui artifact"
    printf '%s\n' "$stamp" > "$AAR_STAMP"
}

step_core() {
    local ref stamp
    ref="$(sed -n 's/^THRONE_CORE_REF=//p' nb4a.properties | tr -d '\r[:space:]')"
    test -n "$ref" || die "THRONE_CORE_REF missing in nb4a.properties"
    stamp="$(core_input_stamp)"
    if [ "${FORCE_CORE:-false}" != true ] && core_libs_present && [ -f "$CORE_STAMP" ] \
        && [ "$(cat "$CORE_STAMP")" = "$stamp" ]; then
        say "core inputs unchanged ($stamp); reusing $CORE_DEST"
        return
    fi

    if [ ! -d "$THRONE_DIR/core/mobile" ]; then
        say "Throne checkout at $ref (codeload tarball, no git history needed)"
        mkdir -p "$LOCAL_BUILD_CACHE"
        local tmp
        tmp="$(mktemp -d)"
        local_build_curl "https://codeload.github.com/throneproj/Throne/tar.gz/$ref" -o "$tmp/throne.tgz"
        mkdir -p "$THRONE_DIR"
        tar -xzf "$tmp/throne.tgz" --strip-components=1 -C "$THRONE_DIR"
        rm -rf "$tmp"
    else
        say "Throne checkout reused: $THRONE_DIR"
    fi

    say "Applying the core bridge overlay"
    bash buildScript/apply-core-patch.sh "$THRONE_DIR"

    say "Building the c-shared kernel (3 ABIs)"
    DEST="$CORE_DEST" bash buildScript/build-cshared.sh "$THRONE_DIR"

    core_libs_present || die "the c-shared build left a missing ABI under $CORE_DEST"
    printf '%s\n' "$stamp" > "$CORE_STAMP"
}

step_schema() {
    test -d "$THRONE_DIR/core" || die "run the core step first (no checkout at $THRONE_DIR)"
    say "Generating the sing-box schema"
    local tags
    tags="$(sed -n 's/^TAGS="\(.*\)"$/\1/p' "$THRONE_DIR/script/build_android.sh")"
    test -n "$tags" || die "TAGS= not found in $THRONE_DIR/script/build_android.sh"
    mkdir -p "$(dirname "$SCHEMA_OUT")"
    ( cd "$THRONE_DIR/core" && CGO_ENABLED=0 go run -trimpath -ldflags=-checklinkname=0 \
        -tags "$tags,with_purego" ./cmd/schemagen -o "$SCHEMA_OUT" )
    test -s "$SCHEMA_OUT" || die "schemagen produced no $SCHEMA_OUT"
}

step_routeprofiles() {
    local action=".github/actions/routeprofiles/action.yml"
    local srs profile
    srs="$(pin_from "$action" SRS_REF)"
    profile="$(pin_from "$action" PROFILE_REF)"
    test -n "$srs" && test -n "$profile" || die "SRS_REF/PROFILE_REF missing in $action"

    say "routeprofiles snapshot (srslist $srs, profile $profile)"
    rm -rf "$ROUTE_DEST"
    mkdir -p "$ROUTE_DEST/profile"
    local_build_curl "https://raw.githubusercontent.com/throneproj/routeprofiles/$srs/srslist.h" \
        -o "$ROUTE_DEST/srslist.h"
    test -s "$ROUTE_DEST/srslist.h" || die "srslist.h is missing or empty"
    local tmp
    tmp="$(mktemp -d)"
    local_build_curl "https://codeload.github.com/throneproj/routeprofiles/tar.gz/$profile" -o "$tmp/profile.tgz"
    tar -xzf "$tmp/profile.tgz" --strip-components=1 -C "$ROUTE_DEST/profile"
    rm -rf "$tmp"
}

step_dashboard() {
    local action=".github/actions/sing-box-dashboard/action.yml"
    local ref
    ref="$(pin_from "$action" DASHBOARD_REF)"
    test -n "$ref" || die "DASHBOARD_REF missing in $action"

    say "sing-box dashboard snapshot ($ref)"
    rm -rf "$DASH_DEST"
    mkdir -p "$DASH_DEST"
    local tmp
    tmp="$(mktemp -d)"
    local_build_curl "https://codeload.github.com/SagerNet/sing-box-dashboard/tar.gz/$ref" -o "$tmp/dashboard.tgz"
    tar -xzf "$tmp/dashboard.tgz" --strip-components=1 -C "$DASH_DEST"
    rm -rf "$tmp"
    # aapt drops dot files and `_`-prefixed directories without failing the build.
    find "$DASH_DEST" -type f -name '.*' -delete
    if [ -n "$(find "$DASH_DEST" -type d -name '_*')" ]; then
        die "the dashboard has _-prefixed directories the APK would lack"
    fi
    test -s "$DASH_DEST/index.html" || die "the dashboard has no index.html"
    "$PYTHON" buildScript/dashboard_css.py "$DASH_DEST"
    "$PYTHON" buildScript/dashboard_slim.py "$DASH_DEST"
}

# --- check --------------------------------------------------------------------

check_all() {
    local missing=0
    check_file() { if [ ! -s "$1" ]; then echo "missing: $1"; missing=1; fi; }
    check_dir() { if [ ! -d "$1" ]; then echo "missing: $1"; missing=1; fi; }
    check_stamp() { # check_stamp <stamp-file> <expected> <label> <hint>
        if [ ! -f "$1" ] || [ "$(cat "$1")" != "$2" ]; then
            echo "stale: $3 (run: bash tools/local-build/local-inputs.sh $4)"
            missing=1
        fi
    }

    if aar_present; then
        check_stamp "$AAR_STAMP" "$(flutter_input_stamp)" "flutter AAR" "--only=flutter"
    else
        check_dir flutter/build/host/outputs/repo
    fi
    if core_libs_present; then
        check_stamp "$CORE_STAMP" "$(core_input_stamp)" "core kernel" "--only=core"
    else
        check_dir "$CORE_DEST"
        for abi in arm64-v8a armeabi-v7a x86_64; do check_file "$CORE_DEST/$abi/libthrone.so"; done
    fi
    check_file "$SCHEMA_OUT"
    check_file "$ROUTE_DEST/srslist.h"
    check_dir "$DASH_DEST"
    check_file "$DASH_DEST/index.html"

    if [ "$missing" = 0 ]; then
        echo "all build inputs present"
    else
        return 1
    fi
}

# --- dispatch ----------------------------------------------------------------

ONLY=""
MODE=all
FORCE_CORE=false
FORCE_FLUTTER=false
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        --only=*) ONLY="${arg#--only=}" ;;
        --force) FORCE_CORE=true; FORCE_FLUTTER=true ;;
        --force-core) FORCE_CORE=true ;;
        --force-flutter) FORCE_FLUTTER=true ;;
        -h|--help)
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "unknown argument: $arg" ;;
    esac
done

if [ "$MODE" = check ]; then
    check_all
    exit $?
fi

wanted() { # wanted <step>
    [ -z "$ONLY" ] && return 0
    case ",$ONLY," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

# core must precede schema; the rest are independent.
if wanted core; then step_core; fi
if wanted schema; then step_schema; fi
if wanted flutter; then step_flutter; fi
if wanted routeprofiles; then step_routeprofiles; fi
if wanted dashboard; then step_dashboard; fi

echo
say "inputs ready"
# A partial run (--only) is expected to leave other inputs absent, so only the
# full run asserts that every input is present.
if [ -z "$ONLY" ]; then check_all; fi
