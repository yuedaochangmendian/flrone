#!/usr/bin/env bash
# Apply the self-owned kernel bridge to a Throne checkout.
#
# This is an overlay, not a set of side files. Copying into core/mobile/ overwrites
# any upstream file of the same name, and three are replaced today:
#   action.go        the action dispatcher, extended with the FFI entry points
#   bridge_calls.go  the throne_* C ABI exports
#   test.go          upstream verbatim, except StartSpeedTest and StartURLTest resolving
#                    the running box when a TestCurrent request arrives with a nil
#                    instance (ffiMode: the box is built on Dart's side, so the gobind
#                    entry has no handle to pass)
# Every other file here is new (bridge_runtime.go, dartbridge.go, the
# *_actions.go handlers, profiles_doc.go, bridge_symbols.h, dartbridge/include/).
#
# One file outside that directory is replaced too:
#   script/build_android.sh  upstream's gomobile invocation, with with_gvisor dropped
#                    (this fork runs sing-tun's own stack; see the file's comment)
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

test -d "$THONE_DIR/core/mobile" || {
    echo "error: $THONE_DIR does not look like a Throne checkout (no core/mobile)" >&2
    exit 2
}
test -d "$THONE_DIR/script" || {
    echo "error: $THONE_DIR has no script/ directory (the AAR build script lives there)" >&2
    exit 2
}

cp -R "$HERE/core-patch/core/mobile/." "$THONE_DIR/core/mobile/"
cp -R "$HERE/core-patch/script/." "$THONE_DIR/script/"

# The kernel itself: ThroneCore's pinned sing-box lacks VLESS encryption, XHTTP
# and mKCP; the public fork carries the same Throneproj base (so the TUN/router
# additions stay) plus those three protocols, built from the v1.15.0-ext.2 tag.
# The existing Throneproj replace line is rewritten in place; a checkout without
# one gets the line appended. GOSUMDB=off is required because the fork tag is not
# in sum.golang.org yet; go.mod/go.sum are tidied here so the later go build and
# go test run against a complete module graph.
SINGBOX_EXT_VERSION="${SINGBOX_EXT_VERSION:-v1.15.0-ext.2}"
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
(
    cd "$THONE_DIR/core"
    GOSUMDB=off GOFLAGS=-mod=mod go mod tidy
)
echo "patched $THONE_DIR/core/go.mod: sing-box => yuedaochangmendian/sing-box-ext ${SINGBOX_EXT_VERSION}"

echo "patched $THONE_DIR/core/mobile: overlaid action.go, bridge_calls.go, test.go;"
echo "        added bridge_runtime.go, dartbridge.go, profiles_doc.go, *_actions.go,"
echo "        bridge_symbols.h, dartbridge/include/"
echo "patched $THONE_DIR/script: overlaid build_android.sh (sing-tun stacks only, no with_gvisor)"
