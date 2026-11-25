#!/usr/bin/env bash
# Build the next vX.Y.Z-pre.N prerelease locally with the release key and, with
# --publish, upload it to GitHub.
#
#   source tools/local-build/local-env.sh
#   bash tools/local-build/local-release.sh            # build + package into dist/
#   bash tools/local-build/local-release.sh --publish  # also create the GitHub prerelease
#
# Prereleases no longer run on GitHub: the automatic release workflow was
# removed, so this script is the prerelease path. Stable releases still run in
# CI (stable-release.yml), which calls ci.yml as its gate.
#
# Signing: the same key the released APKs were signed with, so a preview built
# here installs over an earlier release. Point LOCAL_SIGNING_KEYSTORE at the
# keystore (or set SIGNING_KEYSTORE_B64 yourself) and LOCAL_SIGNING_PASS_FILE at
# the file holding `STORE_PASS=...`, or set LOCAL_SIGNING_STORE_PASS. A different
# key is a signature conflict on every installed device, so the script refuses
# to guess one.
#
# Build number: N = the highest existing vX.Y.Z-pre.N tag + 1, read from GitHub.
# A failed lookup aborts instead of guessing: a reused tag would clobber an
# already published APK.
#
# Options:
#   --publish        create/update the GitHub prerelease (default: build only)
#   --build N        override the preview number (re-running an unpublished build)
#   --allow-dirty    build from a dirty tree (build only, never with --publish)
#   -h, --help       this text

set -euo pipefail

cd "$(dirname "$0")/../.."
# shellcheck disable=SC1091
source tools/local-build/local-env.sh

REPO="${LOCAL_RELEASE_REPO:-yuedaochangmendian/throne-flclash-ui}"
PUBLISH=false
ALLOW_DIRTY=false
BUILD_OVERRIDE=""

say() { echo "==> $*"; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --publish) PUBLISH=true ;;
        --allow-dirty) ALLOW_DIRTY=true ;;
        --build)
            [ $# -ge 2 ] || die "--build needs a value: --build N"
            BUILD_OVERRIDE="$2"
            shift
            ;;
        --build=*) BUILD_OVERRIDE="${1#--build=}" ;;
        -h|--help)
            awk 'NR==1{next} /^#/{sub(/^# ?/, ""); print; next} {exit}' "$0"
            exit 0
            ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

# gh does not read git's proxy configuration; reuse the build proxy.
if [ -n "${LOCAL_BUILD_PROXY:-}" ]; then
    export HTTPS_PROXY="http://$LOCAL_BUILD_PROXY" HTTP_PROXY="http://$LOCAL_BUILD_PROXY"
fi

# --- prerequisites -----------------------------------------------------------

command -v gh >/dev/null || die "gh is required (release upload and tag lookup)"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated (gh auth login)"

bash tools/local-build/local-inputs.sh --check >/dev/null \
    || die "build inputs are missing; run: bash tools/local-build/local-inputs.sh"

if [ "$ALLOW_DIRTY" != true ] && [ -n "$(git status --porcelain)" ]; then
    die "the working tree has uncommitted changes; commit them first (or pass --allow-dirty)"
fi
# --allow-dirty is for looking at a build, not for publishing one: the APK would
# contain files the tag does not.
if [ "$ALLOW_DIRTY" = true ] && [ "$PUBLISH" = true ]; then
    die "--allow-dirty cannot be combined with --publish (the release must match its commit)"
fi

SHA="$(git rev-parse HEAD)"
DECLARED="$(sed -n 's/^VERSION_NAME=//p' nb4a.properties | tr -d '\r[:space:]')"
VERSION_CODE="$(sed -n 's/^VERSION_CODE=//p' nb4a.properties | tr -d '\r[:space:]')"
test -n "$DECLARED" || die "VERSION_NAME is missing in nb4a.properties"
test -n "$VERSION_CODE" || die "VERSION_CODE is missing in nb4a.properties"

# --- preview number ----------------------------------------------------------

if [ -n "$BUILD_OVERRIDE" ]; then
    N="$BUILD_OVERRIDE"
    say "preview number from --build: $N"
else
    say "reading existing v$DECLARED-pre.* tags from GitHub"
    TAGS="$(gh api --paginate "repos/$REPO/git/matching-refs/tags/v$DECLARED-pre." \
        --jq '.[].ref')" \
        || die "could not list preview tags; refusing to guess N (retry when the API is reachable)"
    LAST="$(printf '%s\n' "$TAGS" |
        sed -n "s#.*/v$DECLARED-pre\.\([0-9]\{1,\}\)\$#\1#p" | sort -n | tail -1)"
    N=$(( ${LAST:-0} + 1 ))
fi
[ "$N" -ge 1 ] && [ "$N" -le 998 ] || die "preview number $N is out of range 1..998"
TAG="v$DECLARED-pre.$N"

# --- signing -----------------------------------------------------------------

KEYSTORE="${LOCAL_SIGNING_KEYSTORE:-/e/tmp/2026-11-01-18-33-32/throne-release.keystore}"
PASS_FILE="${LOCAL_SIGNING_PASS_FILE:-/e/tmp/2026-11-01-18-33-32/dist/throne-release-signing-backup-2026-11-02.txt}"
ALIAS="${LOCAL_SIGNING_KEY_ALIAS:-throne-release}"

[ -f "$KEYSTORE" ] || die "release keystore not found: $KEYSTORE (set LOCAL_SIGNING_KEYSTORE)"

if [ -n "${LOCAL_SIGNING_STORE_PASS:-}" ]; then
    STORE_PASS="$LOCAL_SIGNING_STORE_PASS"
elif [ -f "$PASS_FILE" ]; then
    STORE_PASS="$(sed -n 's/^STORE_PASS=//p' "$PASS_FILE" | head -1)"
else
    die "no store password: set LOCAL_SIGNING_STORE_PASS or LOCAL_SIGNING_PASS_FILE"
fi
[ -n "$STORE_PASS" ] || die "the store password file has no STORE_PASS= line"

SIGNING_KEYSTORE_B64="$(base64 -w 0 "$KEYSTORE")"
SIGNING_STORE_PASSWORD="$STORE_PASS"
SIGNING_KEY_ALIAS="$ALIAS"
SIGNING_KEY_PASSWORD="${LOCAL_SIGNING_KEY_PASS:-$STORE_PASS}"
UPDATE_SIGNER_SHA256="$("$JAVA_HOME/bin/keytool" -exportcert -keystore "$KEYSTORE" \
    -storepass "$STORE_PASS" -alias "$ALIAS" | sha256sum | cut -d' ' -f1)"
export SIGNING_KEYSTORE_B64 SIGNING_STORE_PASSWORD SIGNING_KEY_ALIAS SIGNING_KEY_PASSWORD UPDATE_SIGNER_SHA256

say "building $TAG (versionCode $(( VERSION_CODE * 1000 + N )), commit ${SHA:0:12})"
say "signing certificate SHA-256 $UPDATE_SIGNER_SHA256"

# --- build and package -------------------------------------------------------

THRONE_CHANNEL=preview THRONE_BUILD="$N" ./gradlew --stacktrace app:assembleOssRelease

rm -rf "$PWD/dist"
mkdir -p "$PWD/dist"
"$PYTHON" buildScript/release_assets.py app/build/outputs/apk/oss/release "$PWD/dist" preview

say "packaged:"
ls -1 "$PWD/dist"

# --- publish -----------------------------------------------------------------

if [ "$PUBLISH" != true ]; then
    echo
    say "built only. To upload: bash tools/local-build/local-release.sh --build=$N --publish"
    exit 0
fi

# The tag must point at a commit that is already on main: a release built from
# an unpushed or feature-branch commit would be unreproducible for everyone else.
status="$(gh api "repos/$REPO/compare/main...$SHA" -q .status 2>/dev/null || true)"
case "$status" in
    identical|behind) ;;
    ahead|diverged)
        die "commit $SHA is not on main ($status); merge it before publishing a prerelease" ;;
    *)
        die "could not verify that $SHA is on main (compare status: ${status:-unknown})" ;;
esac

say "publishing $TAG"
GH_TOKEN="${GH_TOKEN:-$(gh auth token)}" \
GH_REPO="$REPO" \
VERSION_NAME="$DECLARED-pre.$N" \
NOTES_VERSION="$DECLARED" \
TAG="$TAG" \
PRERELEASE=true \
TARGET_SHA="$SHA" \
GITHUB_SHA="$SHA" \
    bash buildScript/publish_release.sh

say "done: $TAG (prerelease, releases/latest untouched)"
