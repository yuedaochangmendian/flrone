#!/usr/bin/env bash
# Prepare every build input `.github/actions/*` prepares, so a full Gradle build
# (and the unit-test job) can run on this machine:
#
#   source buildScript/local-env.sh
#   bash buildScript/local-inputs.sh              # all inputs
#   bash buildScript/local-inputs.sh --check      # only verify what exists
#   bash buildScript/local-inputs.sh --only=flutter,routeprofiles
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

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source buildScript/local-env.sh

ROOT="$PWD"
THRONE_DIR="$LOCAL_BUILD_CACHE/Throne-$(sed -n 's/^THRONE_CORE_REF=//p' nb4a.properties | tr -d '\r[:space:]')"
CORE_DEST="$ROOT/deployment/android-cshared"
SCHEMA_OUT="$ROOT/app/src/main/assets/schema/sing-box.json"
ROUTE_DEST="$ROOT/app/src/main/assets/routeprofiles"
DASH_DEST="$ROOT/app/src/main/assets/sb-dashboard"

pin_from() { # pin_from <file> <VAR>
    sed -n "s/.*\b$2=\([0-9a-f]\{7,40\}\).*/\1/p" "$1" | head -1
}

say() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

# --- steps --------------------------------------------------------------------

step_flutter() {
    say "Flutter AAR ($("$FLUTTER_BIN" --version 2>/dev/null | head -1))"
    ( cd flutter && "$FLUTTER_BIN" pub get && "$FLUTTER_BIN" build aar --no-debug --no-profile )
    test -d flutter/build/host/outputs/repo/io/flrone/ui \
        || die "flutter build aar produced no io.flrone.ui artifact"
}

step_core() {
    local ref
    ref="$(sed -n 's/^THRONE_CORE_REF=//p' nb4a.properties | tr -d '\r[:space:]')"
    test -n "$ref" || die "THRONE_CORE_REF missing in nb4a.properties"

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

    for abi in arm64-v8a armeabi-v7a x86_64; do
        test -s "$CORE_DEST/$abi/libthrone.so" || die "missing $CORE_DEST/$abi/libthrone.so"
    done
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

    check_dir flutter/build/host/outputs/repo
    check_dir "$CORE_DEST"
    for abi in arm64-v8a armeabi-v7a x86_64; do check_file "$CORE_DEST/$abi/libthrone.so"; done
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
for arg in "$@"; do
    case "$arg" in
        --check) MODE=check ;;
        --only=*) ONLY="${arg#--only=}" ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
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
