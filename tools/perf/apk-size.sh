#!/usr/bin/env bash
# Print per-entry APK size breakdown (compressed bytes) using only unzip + awk.
# Git Bash / Linux / macOS, no Python or other dependencies.
#   ./tools/perf/apk-size.sh [path/to/app.apk]
# Defaults to the newest ossRelease arm64 APK under app/build/outputs.
set -euo pipefail

apk="${1:-}"
if [ -z "$apk" ]; then
  apk="$(ls -t app/build/outputs/apk/oss/release/*arm64*.apk 2>/dev/null | head -1 || true)"
  if [ -z "$apk" ]; then
    echo "no APK given and no ossRelease arm64 APK found" >&2
    exit 1
  fi
fi
[ -f "$apk" ] || { echo "not a file: $apk" >&2; exit 1; }

echo "APK: $apk ($(wc -c < "$apk" | tr -d ' ') bytes)"
echo
printf '%-26s %12s %8s %8s\n' "TOP-LEVEL" "COMPRESSED" "SHARE" "ENTRIES"
# unzip -l emits: "  Length  Date  Time  Name". Use column 1 (uncompressed) and
# sum per top-level dir; compressed bytes come from unzip -v. We use `unzip -v`
# for accurate compressed sizes: "  Length  Method   Size  Cmpr  Date  Time  CRC-32  Name".
unzip -v "$apk" | awk '
  /^----/ { next }
  /^ *Length/ { next }
  NF >= 8 {
    raw=$1; comp=$3; name=$8;
    if (name == "" || comp !~ /^[0-9]+$/) next;
    split(name, parts, "/");
    top = (length(parts) > 1 || name ~ /\//) ? parts[1] : name;
    c[top] += comp; n[top]++; total += comp;
  }
  END {
    for (k in c) printf "%-26s %12d %7.1f%% %8d\n", k, c[k], (total? c[k]*100/total : 0), n[k];
  }
' | sort -k2 -nr

echo
echo "Top 15 largest entries (compressed):"
unzip -v "$apk" | awk '
  /^----/ { next }
  NF >= 8 { print $3, $8 }
' | sort -nr | head -15 | awk '{ printf "%10d  %s\n", $1, $2 }'
