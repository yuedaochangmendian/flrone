#!/usr/bin/env bash
# Publish v<VERSION_NAME> idempotently, riding out GitHub API 5xx.
#
# The release workflow used to call `gh release create` once. Two consecutive
# runs (2026-11-04) died on runner-side 502/500 *after* the APKs were built and
# signed, leaving a half-finished release. This script:
#   * retries every mutating API call three times with a backoff
#   * reuses an existing release/draft instead of refusing the tag
#   * publishes an existing draft (the local-API fallback path)
#   * refuses to upload built assets onto a tag that points at another commit
#     unless the caller explicitly opts into a recovery with --allow-target-mismatch
#   * fails loudly but keeps dist/ as a workflow artifact for manual recovery
#
# See docs/release-runbook.md for the manual path.
set -euo pipefail

ALLOW_TARGET_MISMATCH="${ALLOW_TARGET_MISMATCH:-false}"
for arg in "$@"; do
    case "$arg" in
        --allow-target-mismatch) ALLOW_TARGET_MISMATCH=true ;;
        *) echo "::error::unknown argument: $arg" >&2; exit 2 ;;
    esac
done

: "${TAG:?TAG is required}"
: "${VERSION_NAME:?VERSION_NAME is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
TARGET_SHA="${TARGET_SHA:-$GITHUB_SHA}"

NOTES="${RUNNER_TEMP:-/tmp}/release.md"
NOTES_VERSION="${NOTES_VERSION:-$VERSION_NAME}"
{
    if [ "${PRERELEASE:-false}" = "true" ]; then
        echo "> **Preview build for testing only.** This GitHub prerelease does not replace the stable release and carries no \`throne-update.json\`. Install manually from Releases."
        echo
    fi
    bash buildScript/release_notes.sh "$NOTES_VERSION"
    # Provenance: pin the exact commit these bytes were built from. Cheap (one
    # line), and it lets a later audit tell a reused tag from the build it
    # actually carries. The changelog itself stays authoritative for content.
    printf '\n---\n\nBuilt from commit `%s`.\n' "$TARGET_SHA"
} > "$NOTES"

retry() {
    local attempt
    for attempt in 1 2 3; do
        if "$@"; then
            return 0
        fi
        if [ "$attempt" -lt 3 ]; then
            echo "::warning::attempt $attempt failed ($1); retrying in 15s"
            sleep 15
        fi
    done
    return 1
}

fail_with_artifacts() {
    echo "::error::the GitHub release API failed three times; dist/ is preserved as a workflow artifact."
    echo "         Re-run this workflow, or follow docs/release-runbook.md to publish locally."
    exit 1
}

# Preview builds stay off releases/latest: the in-app updater follows that
# alias, and a preview must never displace the current stable update manifest.
PRERELEASE_FLAG=()
if [ "${PRERELEASE:-false}" = "true" ]; then
    PRERELEASE_FLAG=(--prerelease)
fi

if gh release view "$TAG" --json id > /dev/null 2>&1; then
    echo "release $TAG already exists: uploading assets instead of recreating the tag"
    # Reuse is only correct for the same release. Without this check a rerun that asks for a
    # different channel would upload the new artifacts onto a release that says otherwise —
    # the "preview silently marked stable" failure. Compare before uploading anything.
    EXISTING="$(gh release view "$TAG" --json isPrerelease,targetCommitish \
        --jq '"\(.isPrerelease) \(.targetCommitish)"' 2> /dev/null || echo "")"
    if [ -z "$EXISTING" ]; then
        echo "::error::could not read $TAG's channel/target; refusing to upload blind."
        exit 1
    fi
    EXISTING_PRERELEASE="${EXISTING%% *}"
    EXISTING_TARGET="${EXISTING#* }"
    if [ "$EXISTING_PRERELEASE" != "${PRERELEASE:-false}" ]; then
        echo "::error::$TAG exists with prerelease=$EXISTING_PRERELEASE but this run wants"
        echo "         prerelease=${PRERELEASE:-false}. Delete the release and re-run, or publish"
        echo "         under a new version."
        exit 1
    fi
    if [ "$EXISTING_TARGET" != "$TARGET_SHA" ]; then
        # No readable target (empty) is treated the same as a different one: we
        # cannot prove the tag points at the commit these bytes were built from.
        # The tag would keep pointing at another commit while these assets claim
        # to come from TARGET_SHA: a release falsely attributed to a commit that
        # did not build them. Refuse by default; an explicit recovery flag is
        # the only way through, so it is always a deliberate decision.
        if [ "$ALLOW_TARGET_MISMATCH" != "true" ]; then
            echo "::error::$TAG points at $EXISTING_TARGET, not $TARGET_SHA; refusing to upload assets onto a tag for another commit."
            echo "         To override deliberately, re-run with --allow-target-mismatch (or ALLOW_TARGET_MISMATCH=true)."
            echo "         Deleting the release/tag and publishing at $TARGET_SHA is the safer fix."
            exit 1
        fi
        echo "::warning::$TAG points at $EXISTING_TARGET, not $TARGET_SHA; uploading anyway because --allow-target-mismatch was passed"
    fi
    retry gh release upload "$TAG" dist/* --clobber || fail_with_artifacts
    if [ "$(gh release view "$TAG" --json isDraft --jq '.isDraft' 2> /dev/null || echo false)" = "true" ]; then
        retry gh release edit "$TAG" --draft=false || fail_with_artifacts
    fi
else
    if [ "${GITHUB_REF_TYPE:-}" = "tag" ]; then
        # The tag already exists in the repository; do not pass --target.
        retry gh release create "$TAG" dist/* --title "$TAG" --notes-file "$NOTES" \
            "${PRERELEASE_FLAG[@]}" || fail_with_artifacts
    else
        retry gh release create "$TAG" dist/* --target "$TARGET_SHA" \
            --title "$TAG" --notes-file "$NOTES" "${PRERELEASE_FLAG[@]}" || fail_with_artifacts
    fi
fi

echo "published $TAG"

# A preview is a build to test, not an archive: keep only the latest preview of
# the CURRENT version line so it does not accumulate every build. Pruning every
# prerelease would silently delete the previews of other vX.Y.Z lines (and any
# future prerelease that is not a -pre.N build); stable releases are never
# prereleases, but the version-prefix filter also keeps them untouched by
# construction. Cross-line cleanup is opt-in via PRUNE_ALL_PREVIEWS=true.
if [ "${PRERELEASE:-false}" = "true" ]; then
    BASE_VERSION="${VERSION_NAME%%-pre.*}"
    PRUNE_PREFIX="v${BASE_VERSION}-pre."
    if [ "${PRUNE_ALL_PREVIEWS:-false}" = "true" ]; then
        PRUNE_EXPR="[.[] | select(.isPrerelease and .tagName != \"$TAG\")] | .[].tagName"
    else
        PRUNE_EXPR="[.[] | select(.isPrerelease and (.tagName | startswith(\"$PRUNE_PREFIX\")) and .tagName != \"$TAG\")] | .[].tagName"
    fi
    if ! OLD_PREVIEWS="$(gh release list --limit 100 --json tagName,isPrerelease \
        --jq "$PRUNE_EXPR" 2> /dev/null)"; then
        echo "::warning::could not list releases; older previews were not pruned"
    else
        for old in $OLD_PREVIEWS; do
            echo "pruning older preview $old"
            retry gh release delete "$old" --yes --cleanup-tag \
                || echo "::warning::could not prune $old"
        done
    fi
fi

gh release view "$TAG" --json tagName,isDraft,isPrerelease,assets \
    --jq '{tag: .tagName, draft: .isDraft, prerelease: .isPrerelease, assets: [.assets[].name]}'
