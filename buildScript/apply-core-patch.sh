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
# Every other file here is new (bridge_runtime.go, dartbridge.go, room_db.go, the
# *_actions.go handlers, bridge_symbols.h, dartbridge/include/).
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
echo "patched $THONE_DIR/core/mobile: overlaid action.go, bridge_calls.go, test.go;"
echo "        added bridge_runtime.go, dartbridge.go, room_db.go, *_actions.go,"
echo "        bridge_symbols.h, dartbridge/include/"
echo "patched $THONE_DIR/script: overlaid build_android.sh (sing-tun stacks only, no with_gvisor)"
