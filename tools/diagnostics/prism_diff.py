#!/usr/bin/env python3
"""Inventory and diff helper for the vendored Prism UI layer.

`docs/prism-upstream.md` records where `flutter/lib/ui` came from and states the
policy: the layer is **owned by this project**, there is no drift gate and no
requirement to keep a file byte-identical to upstream. This script is the tool
that policy implies — a reproducible answer to "what differs from the recorded
baseline" for the next upstream sync, without failing anything.

    python tools/diagnostics/prism_diff.py --record
        Write tools/prism_baseline.json: the current `flutter/lib/ui` tree with
        its upstream baseline commit and a sha256 per file. Run this after
        syncing from upstream (or after an intentional restructure).

    python tools/diagnostics/prism_diff.py
        Compare the working tree with the recorded baseline and print the
        added / removed / changed files. Always exits 0 (the layer is owned).

    python tools/diagnostics/prism_diff.py --json
        The same report as JSON (for a PR comment or a sync log).

    python tools/diagnostics/prism_diff.py --strict
        Exit 1 when anything differs. Off by default; here for a maintainer who
        wants a one-off check, never as a CI gate.

The baseline commit is read from docs/prism-upstream.md ("Last synced from"),
so recording cannot silently name a different commit than the provenance note.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI_DIR = ROOT / "flutter" / "lib" / "ui"
DOC = ROOT / "docs" / "prism-upstream.md"
BASELINE = ROOT / "tools" / "prism_baseline.json"


def baseline_commit() -> str:
    """The upstream commit the provenance note says the tree was synced from."""
    text = DOC.read_text(encoding="utf-8")
    match = re.search(r"Last synced from \| `([0-9a-f]{7,40})`", text)
    if not match:
        raise SystemExit("docs/prism-upstream.md has no 'Last synced from' commit")
    return match.group(1)


def tree_hashes() -> dict[str, str]:
    hashes: dict[str, str] = {}
    for path in sorted(UI_DIR.rglob("*.dart")):
        rel = path.relative_to(UI_DIR).as_posix()
        hashes[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    return hashes


def record() -> None:
    payload = {"commit": baseline_commit(), "files": tree_hashes()}
    # newline="\n": the manifest is a repository file (the tree is LF). The
    # default would write CRLF on Windows and the next checkout would report it
    # modified for nothing.
    with open(BASELINE, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print(f"recorded {len(payload['files'])} files at {payload['commit']}")
    print(f"-> {BASELINE.relative_to(ROOT).as_posix()}")


def diff() -> dict:
    if not BASELINE.is_file():
        raise SystemExit(
            "tools/prism_baseline.json is missing; run with --record first"
        )
    baseline = json.loads(BASELINE.read_text(encoding="utf-8"))
    recorded: dict[str, str] = baseline.get("files", {})
    current = tree_hashes()
    return {
        "commit": baseline.get("commit", ""),
        "added": sorted(current.keys() - recorded.keys()),
        "removed": sorted(recorded.keys() - current.keys()),
        "changed": sorted(
            name
            for name in current.keys() & recorded.keys()
            if current[name] != recorded[name]
        ),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--record", action="store_true", help="write the baseline")
    parser.add_argument("--json", action="store_true", help="print JSON")
    parser.add_argument(
        "--strict",
        action="store_true",
        help="exit 1 when the tree differs (off by default; never a CI gate)",
    )
    args = parser.parse_args()

    if args.record:
        record()
        return 0

    report = diff()
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"baseline commit: {report['commit']}")
        for key in ("added", "removed", "changed"):
            names = report[key]
            print(f"{key}: {len(names)}")
            for name in names:
                print(f"  {name}")

    differs = any(report[key] for key in ("added", "removed", "changed"))
    if differs and args.strict:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
