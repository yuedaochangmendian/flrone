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
printf '%s\n' "$NOTES"

# The release body is the one place a reader looks, so a Chinese section for the same
# version rides along under a separator (Markdown renders `---` as a rule). Optional: a
# version that has not been translated yet still publishes its English notes.
if [ -f "$CHANGELOG_ZH" ]; then
    ZH_NOTES="$(section "$VERSION" "$CHANGELOG_ZH")"
    if [ -n "${ZH_NOTES//[[:space:]]/}" ]; then
        printf '\n---\n\n## 中文说明\n\n%s\n' "$ZH_NOTES"
    fi
fi
