#!/usr/bin/env bash
# Local full-build environment for flrone.
#
#   source tools/local-build/local-env.sh
#   bash tools/local-build/local-inputs.sh      # prepare every build input CI prepares
#   bash tools/local-build/local-release.sh     # signed preview APKs (uploads by default; --build-only to skip)
#   ./gradlew app:testOssDebugUnitTest app:assembleOssDebug
#
# This complements /e/hu/toolchain/env.sh (the shared machine toolchain) with the
# two things a full local build needs and the generic env does not pin:
#   * the Flutter SDK version CI builds the module with, and
#   * the NDK/Go/Gradle settings the c-shared kernel and the Gradle build expect.
#
# Every path is a toolchain alias (E:/hu/toolchain/...), so the environment moves
# with the toolchain rather than with this checkout. Override any variable before
# sourcing to use a different install.

LOCAL_BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- toolchain locations -----------------------------------------------------
: "${JAVA_HOME:=/e/hu/toolchain/jdk21}"
: "${ANDROID_HOME:=/e/hu/toolchain/android-sdk}"
: "${ANDROID_SDK_ROOT:=$ANDROID_HOME}"
: "${ANDROID_NDK_HOME:=$ANDROID_HOME/ndk/28.2.13676358}"
: "${GRADLE_USER_HOME:=E:/hu/toolchain/gradle-home}"
: "${LOCAL_BUILD_CACHE:=E:/hu/Temp/local-build-cache}"

# Flutter: CI pins a version in .github/actions/android-build/action.yml. Prefer a
# versioned local SDK when one is installed, then the shared toolchain alias.
CI_FLUTTER_VERSION="$(sed -n "s/.*flutter-version: '\([^']*\)'.*/\1/p" \
    "$LOCAL_BUILD_ROOT/.github/actions/android-build/action.yml" | head -1)"

if [ -z "${FLUTTER_BIN:-}" ]; then
    if [ -n "$CI_FLUTTER_VERSION" ] && [ -x "/e/hu/toolchain/flutter-$CI_FLUTTER_VERSION/bin/flutter" ]; then
        FLUTTER_BIN="/e/hu/toolchain/flutter-$CI_FLUTTER_VERSION/bin/flutter"
    elif [ -x "/e/hu/toolchain/flutter/bin/flutter" ]; then
        FLUTTER_BIN="/e/hu/toolchain/flutter/bin/flutter"
    else
        FLUTTER_BIN="$(command -v flutter || true)"
    fi
fi

export JAVA_HOME ANDROID_HOME ANDROID_SDK_ROOT ANDROID_NDK_HOME GRADLE_USER_HOME
export FLUTTER_BIN LOCAL_BUILD_CACHE

# Go: core/go.mod requires Go >= 1.26 while the shared toolchain alias may be older,
# and build-cshared.sh runs with GOTOOLCHAIN=local (a cross build must not switch
# toolchains mid-run). Prefer a 1.26+ install when one is present.
if [ -z "${GO:-}" ]; then
    # CI builds the kernel with the version pinned in .github/actions/throne-core
    # (1.27.0). Match it: 1.26 trips cgo's link-flag check on cronet-go's
    # `-l:libcronet.a`, and build-cshared.sh runs with GOTOOLCHAIN=local.
    for candidate in /e/hu/toolchain/go-1.27/bin/go /e/hu/toolchain/go-1.26/bin/go /e/hu/toolchain/go/bin/go; do
        if [ -x "$candidate" ]; then
            GO="$candidate"
            break
        fi
    done
fi
if [ -z "${GO:-}" ]; then
    echo "error: go not found (install Go 1.26+ and/or set GO)" >&2
    return 1 2>/dev/null || exit 1
fi
export GO

# Go module proxy: proxy.golang.org is not reachable from every network this repo
# is built on (the Gradle build already goes through Aliyun mirrors in
# repositories.gradle.kts). goproxy.cn serves the same modules.
: "${GOPROXY:=https://goproxy.cn,direct}"
export GOPROXY

# Python for the dashboard/patch helpers (stdlib only). On Windows `python3` is
# usually a Microsoft Store stub that exits 49, so prefer a working `python`.
if [ -z "${PYTHON:-}" ]; then
    if python3 -c 'pass' >/dev/null 2>&1; then
        PYTHON=python3
    else
        PYTHON=python
    fi
fi
export PYTHON

# Keep the pinned tools first so `go`, `flutter` and adb resolve to them.
# ~/go/bin stays reachable for gomobile/gobind (the AAR path only).
export PATH="$(dirname "$FLUTTER_BIN"):$(dirname "$GO"):/c/Users/ljlgg/go/bin:$ANDROID_HOME/platform-tools:$PATH"

# Optional proxy for the snapshot downloads (routeprofiles, dashboard, kernel
# tarball). Gradle's own proxy lives in $GRADLE_USER_HOME/gradle.properties.
: "${LOCAL_BUILD_PROXY:=127.0.0.1:7890}"

# curl with the proxy and a retry, used by local-inputs.sh.
local_build_curl() {
    HTTPS_PROXY="http://$LOCAL_BUILD_PROXY" HTTP_PROXY="http://$LOCAL_BUILD_PROXY" \
        curl -fsSL --retry 3 --max-time 600 "$@"
}

# Warn (do not fail) when the Flutter in use is not the one CI builds with: the
# AAR is then not byte-identical to a release artifact, which is fine for local
# verification but not for shipping.
_local_flutter_version="$("$FLUTTER_BIN" --version 2>/dev/null | head -1 || true)"
if [ -n "$CI_FLUTTER_VERSION" ] && ! printf '%s' "$_local_flutter_version" | grep -q " $CI_FLUTTER_VERSION "; then
    echo "warning: local Flutter is not the CI pin." >&2
    echo "         CI:    $CI_FLUTTER_VERSION" >&2
    echo "         local: ${_local_flutter_version:-missing}" >&2
    echo "         Install /e/hu/toolchain/flutter-$CI_FLUTTER_VERSION for identical artifacts." >&2
fi

echo "local build env ready:"
echo "  root     $LOCAL_BUILD_ROOT"
echo "  java     $JAVA_HOME"
echo "  sdk      $ANDROID_HOME"
echo "  ndk      $ANDROID_NDK_HOME"
echo "  gradle   $GRADLE_USER_HOME"
echo "  go       $("$GO" version 2>/dev/null || echo missing) ($GO)"
echo "  flutter  ${_local_flutter_version:-missing} ($FLUTTER_BIN)"
echo "  cache    $LOCAL_BUILD_CACHE"
