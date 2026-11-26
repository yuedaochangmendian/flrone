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

# The three remote inputs must use the SAME immutable SHAs CI and local builds
# use. Fetching a moving branch head made the F-Droid APK bundle a different
# snapshot than every other build of the same tag. The pins live in the composite
# actions; parse them with the same `pin_from` logic tools/local-build/local-inputs.sh
# uses (POSIX sed, no bash-only features) so there is a single source of truth.
pin_from() { # pin_from <file> <VAR>
    sed -n "s/.*\b$2=\([0-9a-f]\{7,40\}\).*/\1/p" "$1" | head -1
}
die() { echo "error: $*" >&2; exit 1; }

ROUTE_ACTION=".github/actions/routeprofiles/action.yml"
SRS_REF=$(pin_from "$ROUTE_ACTION" SRS_REF)
PROFILE_REF=$(pin_from "$ROUTE_ACTION" PROFILE_REF)
[ -n "$SRS_REF" ] && [ -n "$PROFILE_REF" ] \
    || die "SRS_REF/PROFILE_REF missing in $ROUTE_ACTION"

# Bundle the throneproj/routeprofiles snapshot (same as .github/actions/routeprofiles).
ROUTES="$PWD/app/src/main/assets/routeprofiles"
rm -rf "$ROUTES"
mkdir -p "$ROUTES/profile"
curl -fsSL --retry 3 -o "$ROUTES/srslist.h" \
    "https://raw.githubusercontent.com/throneproj/routeprofiles/$SRS_REF/srslist.h"
test -s "$ROUTES/srslist.h" || die "srslist.h is missing or empty"
curl -fsSL --retry 3 "https://codeload.github.com/throneproj/routeprofiles/tar.gz/$PROFILE_REF" \
    | tar -xz --strip-components=1 -C "$ROUTES/profile"

# Bundle the sing-box dashboard (same as .github/actions/sing-box-dashboard).
DASH_ACTION=".github/actions/sing-box-dashboard/action.yml"
DASHBOARD_REF=$(pin_from "$DASH_ACTION" DASHBOARD_REF)
[ -n "$DASHBOARD_REF" ] || die "DASHBOARD_REF missing in $DASH_ACTION"
DASHBOARD="$PWD/app/src/main/assets/sb-dashboard"
rm -rf "$DASHBOARD"
mkdir -p "$DASHBOARD"
curl -fsSL --retry 3 "https://codeload.github.com/SagerNet/sing-box-dashboard/tar.gz/$DASHBOARD_REF" \
    | tar -xz --strip-components=1 -C "$DASHBOARD"
# aapt silently drops dot files and "_"-prefixed directories without failing the
# build, so remove/forbid them here just like the dashboard CI action does.
find "$DASHBOARD" -type f -name '.*' -delete
if [ -n "$(find "$DASHBOARD" -type d -name '_*')" ]; then
    die "the dashboard has _-prefixed directories the APK would lack"
fi
test -s "$DASHBOARD/index.html" || die "the dashboard has no index.html"
python3 buildScript/dashboard_css.py "$DASHBOARD"
python3 buildScript/dashboard_slim.py "$DASHBOARD"

# F-Droid builds stable tags: the same versionCode as the GitHub release (VERSION_CODE * 1000 + 999).
grep -q '^throne.build=' gradle.properties || printf '\nthrone.build=999\n' >> gradle.properties
