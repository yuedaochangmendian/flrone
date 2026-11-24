#!/usr/bin/env bash
# Apply the self-owned kernel bridge to a Throne checkout.
#
# This is an overlay, not a set of side files. Copying into core/ overwrites any
# upstream file of the same relative path. The overlay owns:
#   core/mobile/   the bridge itself
#                  action.go        the action dispatcher, extended with the FFI entry points
#                  bridge_calls.go  the throne_* C ABI exports
#                  test.go          upstream verbatim, except StartSpeedTest and StartURLTest
#                                   resolving the running box when a TestCurrent request
#                                   arrives with a nil instance (ffiMode: the box is built on
#                                   Dart's side, so the gobind entry has no handle to pass)
#                  instance.go, log.go, context.go, mobile.go
#                                   upstream minus the Xray sidecar (see below)
#                  host_call.go, host_test_hub.go, routetest.go
#                                   upstream plus the JSON host-call surface
#                  Every other file here is new (bridge_runtime.go, dartbridge.go, the
#                  *_actions.go handlers, profiles_doc.go, bridge_symbols.h,
#                  dartbridge/include/).
#   core/internal/ the Xray sidecar removal, in files whose Xray blocks are cut out of a
#                  full copy: rpc/{lifecycle,state,testenv,egress,scan,speedtest,
#                  servicetest,urltest,routetest}, probe/dnstunnel, testenv/testenv,
#                  boxmain/create, elevation/protocol_windows, scan/dns, diagnostics
#   core/main.go   upstream minus the Xray version line and the xray distro registration
#   core/gen/libcore.proto
#                  the desktop RPC contract minus the per-request Xray fields
#   script/build_android.sh  upstream's gomobile invocation, with with_gvisor dropped
#                  (this fork runs sing-tun's own stack; see the file's comment)
#
# The overlay cannot express removals, so core-patch/remove-xray.py deletes the
# trees nothing would compile against any more (internal/xray, internal/xraydns,
# internal/distro/all, mobile/xray.go) and then proves no file under core/ still imports
# xtls/xray-core. It runs AFTER the copy, so an overlay file cannot resurrect them.
#
# gobind's generated Java surface is unchanged in SHAPE: the overlay exports no new
# symbols and renames none, so Mobile, Instance and TestRequest keep the methods and
# fields Kotlin already compiles against. Only StartSpeedTest's behaviour differs —
# gobind binds Mobile.startSpeedTest to it, and in FFI mode Kotlin starts no
# Instance, so the live box is reached through the registry instead of a handle.
#
# What the overlay adds is the throne_* C ABI that Dart's dart:ffi layer and the
# android/core JNI shim call.
#
# A shape change upstream (a renamed field, a new handler signature) does not merge:
# the overlay file wins and the build breaks. When THRONE_CORE_REF moves, diff these
# files against the new checkout before bumping the pin.
set -euo pipefail

THONE_DIR="${1:?usage: apply-core-patch.sh <throne-checkout>}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PYTHON="${PYTHON:-python3}"

test -d "$THONE_DIR/core/mobile" || {
    echo "error: $THONE_DIR does not look like a Throne checkout (no core/mobile)" >&2
    exit 2
}
test -d "$THONE_DIR/script" || {
    echo "error: $THONE_DIR has no script/ directory (the AAR build script lives there)" >&2
    exit 2
}

cp -R "$HERE/core-patch/core/." "$THONE_DIR/core/"
cp -R "$HERE/core-patch/script/." "$THONE_DIR/script/"

# Deletions last: the overlay above must not be able to put the sidecar back.
"$PYTHON" "$HERE/core-patch/remove-xray.py" "$THONE_DIR"

# The kernel itself: ThroneCore's pinned sing-box lacks VLESS encryption, XHTTP
# and mKCP; the public fork carries the same Throneproj base (so the TUN/router
# additions stay) plus those transports and REALITY authentication, built from the
# v1.15.0-ext.8 tag. The existing Throneproj replace line is rewritten in place; a
# checkout without one gets the line appended. The fork tag is not in sum.golang.org
# yet, so GONOSUMDB scopes the checksum bypass to it; upstream modules stay verified.
# go.mod/go.sum are tidied here so the later go build and go test see a complete graph.
SINGBOX_EXT_VERSION="${SINGBOX_EXT_VERSION:-v1.15.0-ext.8}"
# The fork also replaces sagernet/sing with its own Throneproj fork (the pin's is
# the unrelated shtorm-7 one). A replace in a dependency's go.mod is ignored, so it
# has to be repeated here: the shtorm-7 fork predates the Notice logger, the mmap
# matchers and sing-tun's PacketOffload, and the kernel does not compile against it.
# Keep this version equal to the replace line in sing-box-ext's own go.mod.
SING_FORK_VERSION="${SING_FORK_VERSION:-v0.9.4-0.20261113121621-2ce66de7d09b}"
CORE_GO_MOD="$THONE_DIR/core/go.mod"
test -f "$CORE_GO_MOD" || {
    echo "error: $THONE_DIR/core/go.mod is missing" >&2
    exit 2
}
if grep -q '^replace github.com/sagernet/sing-box =>' "$CORE_GO_MOD"; then
    sed -i "s#^replace github.com/sagernet/sing-box =>.*#replace github.com/sagernet/sing-box => github.com/yuedaochangmendian/sing-box-ext ${SINGBOX_EXT_VERSION}#" "$CORE_GO_MOD"
else
    printf '\nreplace github.com/sagernet/sing-box => github.com/yuedaochangmendian/sing-box-ext %s\n' "$SINGBOX_EXT_VERSION" >>"$CORE_GO_MOD"
fi
if grep -q '^replace github.com/sagernet/sing =>' "$CORE_GO_MOD"; then
    sed -i "s#^replace github.com/sagernet/sing =>.*#replace github.com/sagernet/sing => github.com/throneproj/sing ${SING_FORK_VERSION}#" "$CORE_GO_MOD"
else
    printf '\nreplace github.com/sagernet/sing => github.com/throneproj/sing %s\n' "$SING_FORK_VERSION" >>"$CORE_GO_MOD"
fi
(
    cd "$THONE_DIR/core"
    # Keep sumdb verification for upstream modules; only the self-owned fork tag is
    # not in sum.golang.org. The proxy can be briefly unavailable after a new tag.
    for attempt in 1 2 3; do
        if GONOSUMDB='github.com/yuedaochangmendian/*' GOFLAGS=-mod=mod go mod tidy; then
            break
        fi
        if [ "$attempt" = "3" ]; then
            echo "error: go mod tidy failed three times" >&2
            exit 1
        fi
        sleep 5
    done
)
echo "patched $THONE_DIR/core/go.mod: sing-box => yuedaochangmendian/sing-box-ext ${SINGBOX_EXT_VERSION};"
echo "        sing => throneproj/sing ${SING_FORK_VERSION} (the replace the fork declares for itself)"

echo "patched $THONE_DIR/core/mobile: overlaid action.go, bridge_calls.go, test.go,"
echo "        instance.go, log.go, context.go, mobile.go, host_call.go, host_test_hub.go,"
echo "        routetest.go; added bridge_runtime.go, dartbridge.go, profiles_doc.go,"
echo "        *_actions.go, bridge_symbols.h, dartbridge/include/"
echo "patched $THONE_DIR/core: Xray sidecar removed (internal/xray, internal/xraydns,"
echo "        internal/distro/all, mobile/xray.go); main.go, gen/libcore.proto and the"
echo "        internal packages that started or tracked it overlaid without it"
echo "patched $THONE_DIR/script: overlaid build_android.sh (sing-tun stacks only, no with_gvisor)"
