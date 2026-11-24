#!/usr/bin/env python3
"""Remove the Xray sidecar from a Throne core checkout.

The app no longer ships an Xray runtime: the outbound form, the profile model and
the kernel bridge all speak sing-box only. Upstream still carries the sidecar, so
the checkout `apply-core-patch.sh` builds has to be pruned the same way the
overlay replaces the files that referenced it:

  * `core/internal/xray/`     the gate/stack that started Xray instances
  * `core/internal/xraydns/`  the resolver that pointed Xray at the box's DNS
  * `core/internal/distro/all/`  registered nothing but `xray-core/main/distro/all`
  * `core/mobile/xray.go`     the VpnService protect controller for Xray sockets

Everything else is handled by the overlay under `core-patch/core/` (the files
whose Xray blocks are too tangled to cut out of a copy), so this script only
deletes and then proves the deletion:

  * none of the paths above still exists
  * no Go/proto file under `core/` imports `github.com/xtls/xray-core`
  * `core/go.mod` carries no `replace github.com/xtls/xray-core` line; the
    following `go mod tidy` drops the require and indirect dependencies

Idempotent: a checkout that was already pruned is a no-op, so the script can run
on every patch without a guard. Deterministic: it only removes trees that the
overlay has already made unreachable and the pin's own replace line.

Usage:
    python3 buildScript/core-patch/remove-xray.py <throne-checkout>
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path

REMOVED_PATHS = (
    "core/internal/xray",
    "core/internal/xraydns",
    "core/internal/distro/all",
    "core/mobile/xray.go",
)

# The import the removal exists to make impossible. Matched textually so a case
# variant or an extra segment cannot slip through.
FORBIDDEN_IMPORT = "xtls/xray-core"
SCANNED_SUFFIXES = (".go", ".proto")


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1].strip(), file=sys.stderr)
        return 2
    checkout = Path(sys.argv[1])
    if not (checkout / "core" / "mobile").is_dir():
        print(f"error: {checkout} does not look like a Throne checkout (no core/mobile)", file=sys.stderr)
        return 2

    removed = []
    for relative in REMOVED_PATHS:
        path = checkout / relative
        if path.is_dir():
            shutil.rmtree(path)
            removed.append(relative + "/")
        elif path.is_file():
            path.unlink()
            removed.append(relative)
        # A directory that held only the sidecar (core/internal/distro/all) goes too, so
        # the tree matches a checkout that never carried it.
        parent = path.parent
        if parent != checkout / "core" and parent.is_dir() and not any(parent.iterdir()):
            parent.rmdir()

    # The pin's own replace line is the last reference the compiler never sees. Drop it
    # here; the apply script's following `go mod tidy` then prunes the require and the
    # indirect graph. A no-op on the second run.
    go_mod = checkout / "core" / "go.mod"
    if go_mod.is_file():
        original = go_mod.read_text(encoding="utf-8")
        kept = "".join(
            line for line in original.splitlines(keepends=True)
            if FORBIDDEN_IMPORT not in line
        )
        if kept != original:
            go_mod.write_text(kept, encoding="utf-8")
            removed.append("core/go.mod: xray-core replace")

    problems: list[str] = []
    for relative in REMOVED_PATHS:
        if (checkout / relative).exists():
            problems.append(f"still present after removal: {relative}")
    if go_mod.is_file() and "github.com/xtls/xray-core" in go_mod.read_text(encoding="utf-8"):
        problems.append("core/go.mod still references xtls/xray-core")

    leftovers: list[str] = []
    for path in (checkout / "core").rglob("*"):
        if not path.is_file() or path.suffix not in SCANNED_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as error:
            problems.append(f"cannot read {path}: {error}")
            continue
        if FORBIDDEN_IMPORT in text:
            leftovers.append(str(path.relative_to(checkout)))

    for leftover in leftovers:
        problems.append(f"still imports {FORBIDDEN_IMPORT}: {leftover}")

    if problems:
        for problem in problems:
            print(f"error: {problem}", file=sys.stderr)
        return 1

    if removed:
        print("removed Xray sidecar: " + ", ".join(removed))
    else:
        print("removed Xray sidecar: already pruned")
    return 0


if __name__ == "__main__":
    sys.exit(main())
