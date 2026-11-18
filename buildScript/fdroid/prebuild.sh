#!/bin/bash
set -e

# Build deployment/android-cshared/<abi>/libthrone.so and the sing-box schema asset from
# throneproj/Throne at the ref pinned in nb4a.properties (Go + ANDROID_HOME/ANDROID_NDK_HOME
# set), the same as .github/actions/throne-core. No gomobile/gobind.
THRONE_CORE_REF=$(sed -n 's/^THRONE_CORE_REF=//p' nb4a.properties | tr -d '\r[:space:]')
test -n "$THRONE_CORE_REF"
THRONE_DIR="$(cd .. && pwd)/Throne"
rm -rf "$THRONE_DIR"
git init -q "$THRONE_DIR"
git -C "$THRONE_DIR" remote add origin https://github.com/throneproj/Throne
git -C "$THRONE_DIR" fetch -q --depth 1 origin "$THRONE_CORE_REF"
git -C "$THRONE_DIR" checkout -q --detach FETCH_HEAD

bash buildScript/apply-core-patch.sh "$THRONE_DIR"

DEST="$PWD/deployment/android-cshared"
bash buildScript/build-cshared.sh "$THRONE_DIR" "$DEST"

SCHEMA="$PWD/app/src/main/assets/schema/sing-box.json"
mkdir -p "$(dirname "$SCHEMA")"
TAGS=$(sed -n 's/^TAGS="\(.*\)"$/\1/p' "$THRONE_DIR/script/build_android.sh")
test -n "$TAGS"
(cd "$THRONE_DIR/core" && CGO_ENABLED=0 go run -trimpath -ldflags=-checklinkname=0 -tags "$TAGS,with_purego" ./cmd/schemagen -o "$SCHEMA")

# Bundle the throneproj/routeprofiles snapshot (same as .github/actions/routeprofiles).
ROUTES="$PWD/app/src/main/assets/routeprofiles"
rm -rf "$ROUTES"
mkdir -p "$ROUTES/profile"
curl -fsSL --retry 3 -o "$ROUTES/srslist.h" https://raw.githubusercontent.com/throneproj/routeprofiles/rule-set/srslist.h
test -s "$ROUTES/srslist.h"
curl -fsSL --retry 3 https://codeload.github.com/throneproj/routeprofiles/tar.gz/refs/heads/profile \
  | tar -xz --strip-components=1 -C "$ROUTES/profile"

# Bundle the sing-box dashboard (same as .github/actions/sing-box-dashboard).
DASHBOARD="$PWD/app/src/main/assets/sb-dashboard"
rm -rf "$DASHBOARD"
mkdir -p "$DASHBOARD"
curl -fsSL --retry 3 https://codeload.github.com/SagerNet/sing-box-dashboard/tar.gz/refs/heads/gh-pages \
  | tar -xz --strip-components=1 -C "$DASHBOARD"
find "$DASHBOARD" -type f -name '.*' -delete
test -z "$(find "$DASHBOARD" -type d -name '_*')"
test -s "$DASHBOARD/index.html"
python3 buildScript/dashboard_css.py "$DASHBOARD"

# F-Droid builds stable tags: the same versionCode as the GitHub release (VERSION_CODE * 1000 + 999).
grep -q '^throne.build=' gradle.properties || printf '\nthrone.build=999\n' >> gradle.properties
