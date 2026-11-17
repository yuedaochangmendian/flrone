#!/bin/bash
set -e

# Android AAR of core/mobile via the sagernet gomobile fork (gomobile + gobind on PATH, JDK 17,
# ANDROID_HOME/ANDROID_NDK_HOME set). No protoc step: core/mobile does not import gen.
#
# Fork overlay (buildScript/apply-core-patch.sh): upstream also builds with_gvisor, which compiles
# sing-tun's gVisor and mixed stacks into the AAR. This fork's TUN inbound leaves `stack` unset, so
# sing-tun's own "go" stack is what runs, and the JNI/Android side never selects gvisor or mixed;
# keeping them only bloated libthrone.so (the largest item in the APK). The tag stays off so the
# binary carries sing-tun's go and system stacks only. Re-add `with_gvisor` here if a stack picker
# is ever exposed.
TAGS="with_quic,with_wireguard,with_utls,with_clash_api,with_openvpn,with_openconnect,with_naive_outbound,badlinkname,tfogo_checklinkname0"
TARGET="android/arm64,android/arm,android/amd64"
DEST=${DEST:-$PWD/deployment/android}

mkdir -p "$DEST"

#### Go: core/mobile -> ThroneCore.aar ####
pushd core
VERSION_SINGBOX=$(go list -m -f '{{.Version}}' github.com/sagernet/sing-box)
gomobile bind -v -o "$DEST/ThroneCore.aar" -target "$TARGET" -androidapi 24 -javapkg=io.throneproj -libname=throne -trimpath \
  -ldflags "-s -w -checklinkname=0 -X github.com/sagernet/sing-box/constant.Version=${VERSION_SINGBOX} -X runtime.godebugDefault=multipathtcp=0" \
  -tags "$TAGS" ./mobile
popd
