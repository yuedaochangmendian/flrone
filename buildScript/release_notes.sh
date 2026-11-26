#!/bin/bash
set -euo pipefail

USAGE="usage: release_notes.sh <version>"
VERSION="${1:?$USAGE}"
VERSION="${VERSION#v}"
CHANGELOG="$(dirname "$0")/../CHANGELOG.md"
CHANGELOG_ZH="$(dirname "$0")/../CHANGELOG.zh-CN.md"

# The `#### <version>` block of one changelog file, without its heading.
section() {
    awk -v version="$1" '
        { sub(/\r$/, "") }
        /^#### / {
            if (found) exit
            heading = substr($0, 6)
            gsub(/^[ \t]+|[ \t]+$/, "", heading)
            found = heading == version
            next
        }
        found && (started || NF) { started = 1; print }
    ' "$2"
}

NOTES="$(section "$VERSION" "$CHANGELOG")"

if [ -z "${NOTES//[[:space:]]/}" ]; then
    echo "CHANGELOG.md has no notes for $VERSION; add a '#### $VERSION' section at the top." >&2
    exit 1
fi
# The release body follows the README's language navigation ("简体中文 · English").
# Link to the changelog files rather than in-page anchors: GitHub strips `id` on
# HTML elements, so an anchor has nothing reliable to point at. `<details>` and
# `<summary>` are on GitHub's allowlist and keep their inner Markdown when the
# content is separated by blank lines; the updater reads the changelog files at
# the tag directly, so it never has to parse this HTML.
CHANGELOG_URL="https://github.com/yuedaochangmendian/throne-flclash-ui/blob/main/CHANGELOG.md"
CHANGELOG_ZH_URL="https://github.com/yuedaochangmendian/throne-flclash-ui/blob/main/CHANGELOG.zh-CN.md"

# Both languages start folded: the body is a version summary, not a wall of
# text, and the summary line names the language. The updater does not read this
# HTML — it selects the version's section from the changelog files at the tag.
printf 'Other languages: [简体中文](%s) · [English](%s)\n\n' "$CHANGELOG_ZH_URL" "$CHANGELOG_URL"
printf '<details>\n<summary>English</summary>\n\n%s\n\n</details>\n' "$NOTES"

# A version that has not been translated yet still publishes its English notes.
if [ -f "$CHANGELOG_ZH" ]; then
    ZH_NOTES="$(section "$VERSION" "$CHANGELOG_ZH")"
    if [ -n "${ZH_NOTES//[[:space:]]/}" ]; then
        printf '\n<details>\n<summary>简体中文</summary>\n\n%s\n\n</details>\n' "$ZH_NOTES"
    fi
fi
