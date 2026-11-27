"""Idempotence gate for the self-owned kernel binding surface.

``bindgen.py`` owns six checked-in artifacts: the two ``bridge_symbols.h`` copies,
``bridge_calls.go``, ``bridge_runtime.go``, ``dartbridge.go`` and
``throne_ffi.dart``. Regenerating them is a three-step pipeline:

    bindgen.py --emit all  ->  gofmt  ->  prune_exports.py  ->  gofmt

This script runs that pipeline entirely inside a temporary directory and compares
each result byte-for-byte with the checked-in file. Any difference is a failure:
an edited generator whose outputs were not regenerated, or an edited output whose
generator was not updated. Both are how the P2b/P3 runtime migrations drifted
(``emit_go_runtime()`` still called 12 legacy typed C callbacks the JNI table no
longer populates while the checked-in runtime used only the 4-slot facade).

Usage (from anywhere)::

    python3 tools/diagnostics/bindgen_check.py
    python3 tools/diagnostics/bindgen_check.py --go-src /path/to/Throne/core/mobile

``--go-src`` is the patched Throne core's ``core/mobile`` Go sources (the
``--go-src`` of bindgen.py). It is required because two generated bodies
(``registerInstance`` in NewInstance and gobind field-vs-method resolution for
RuleSetUpdateResult) depend on the real Go source. In CI the throne-core action
clones the pinned tree to ``$(dirname $GITHUB_WORKSPACE)/Throne``, so the default
finds it there. Locally pass the path explicitly, or place a checkout at
``../Throne/core/mobile`` relative to this repository.

Everything is read-only with respect to the repository; only the temp dir is
written. Exit code 0 when all six artifacts match, 1 on drift or a setup error.
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
BINDGEN = ROOT / "tools" / "bindgen" / "bindgen.py"
PRUNE = ROOT / "tools" / "bindgen" / "prune_exports.py"
LIVE = ROOT / "tools" / "bindgen" / "live_exports.txt"
PATCH = ROOT / "buildScript" / "core-patch" / "core" / "mobile"

# (generated name in the bindgen out dir, checked-in path) pairs. The header is
# emitted once and copied to both consumers; prune_exports.py asserts the two
# checked-in copies are identical, so we generate one and compare both.
OUTPUTS = [
    ("bridge_symbols.h", PATCH / "bridge_symbols.h"),
    ("bridge_symbols.h", ROOT / "android" / "core" / "src" / "main" / "cpp" / "bridge_symbols.h"),
    ("bridge_calls.go", PATCH / "bridge_calls.go"),
    ("bridge_runtime.go", PATCH / "bridge_runtime.go"),
    ("dartbridge.go", PATCH / "dartbridge.go"),
    ("throne_ffi.dart", ROOT / "flutter" / "lib" / "core" / "throne_ffi.dart"),
]
GO_FILES = ("bridge_calls.go", "bridge_runtime.go", "dartbridge.go")

# prune_exports.py expects this repository layout under --root.
PRUNE_DIRS = (
    "tools/bindgen",
    "buildScript/core-patch/core/mobile",
    "android/core/src/main/cpp",
    "flutter/lib/core",
)


def default_go_src() -> Path | None:
    """Find the patched Throne tree CI uses, or a local sibling checkout."""
    # GitHub Actions: throne-core checks out to $(dirname $GITHUB_WORKSPACE)/Throne,
    # which is exactly ROOT.parent here.
    candidates = [ROOT.parent / "Throne" / "core" / "mobile"]
    for p in candidates:
        if (p / "mobile.go").is_file():
            return p
    return None


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, shell=False, **kwargs)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--go-src", type=Path, default=None,
                    help="patched Throne core/mobile Go sources (see module docstring)")
    args = ap.parse_args()

    go_src = (args.go_src or default_go_src())
    if go_src is None or not go_src.is_dir():
        print("FAIL: bindgen --go-src not found: pass --go-src /path/to/Throne/core/mobile",
              file=sys.stderr)
        return 1
    go_src = go_src.resolve()
    for tool in (BINDGEN, PRUNE, LIVE):
        if not tool.is_file():
            print(f"FAIL: missing tool: {tool}", file=sys.stderr)
            return 1
    gofmt = shutil.which("gofmt")
    if not gofmt:
        print("FAIL: gofmt not on PATH; an unformatted regeneration cannot be compared",
              file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="bindgen-check-") as tmp_name:
        tmp = Path(tmp_name)
        gen = tmp / "gen"
        for d in PRUNE_DIRS:
            (tmp / d).mkdir(parents=True, exist_ok=True)
        shutil.copy(LIVE, tmp / "tools" / "bindgen" / "live_exports.txt")

        r = run([sys.executable, str(BINDGEN), "--emit", "all",
                 "--out", str(gen), "--go-src", str(go_src)])
        if r.returncode:
            print(f"FAIL: bindgen.py exited {r.returncode}", file=sys.stderr)
            print(r.stdout, file=sys.stderr)
            print(r.stderr, file=sys.stderr)
            return 1
        for name in GO_FILES:
            r = run([gofmt, "-w", str(gen / name)])
            if r.returncode:
                print(f"FAIL: gofmt {name}: {r.stderr}", file=sys.stderr)
                return 1

        # Stage the generated artifacts into the layout prune_exports.py expects.
        staged: dict[str, Path] = {}
        for name, checked in OUTPUTS:
            dst = tmp / checked.relative_to(ROOT)
            shutil.copy(gen / name, dst)
            staged[str(checked)] = dst

        r = run([sys.executable, str(PRUNE), "--root", str(tmp)])
        if r.returncode:
            print(f"FAIL: prune_exports.py exited {r.returncode}", file=sys.stderr)
            print(r.stdout, file=sys.stderr)
            print(r.stderr, file=sys.stderr)
            return 1
        # Pruning drops export blocks and leaves extra blank lines; the checked-in
        # Go files are gofmt'd after pruning, so mirror that here.
        for checked in (PATCH / "bridge_calls.go", PATCH / "bridge_runtime.go",
                        PATCH / "dartbridge.go"):
            r = run([gofmt, "-w", str(tmp / checked.relative_to(ROOT))])
            if r.returncode:
                print(f"FAIL: post-prune gofmt {checked}: {r.stderr}", file=sys.stderr)
                return 1

        drifted: list[str] = []
        for name, checked in OUTPUTS:
            generated = staged[str(checked)]
            if generated.read_bytes() != checked.read_bytes():
                drifted.append(str(checked.relative_to(ROOT)))
                print(f"DRIFT: {checked.relative_to(ROOT)}")
                diff = run(["diff", "-u", str(generated), str(checked)])
                print("\n".join(diff.stdout.splitlines()[:80]))

    if drifted:
        print(f"\nFAIL: {len(drifted)} generated artifact(s) differ from the checked-in tree: "
              + ", ".join(drifted), file=sys.stderr)
        print("Regenerate with bindgen.py + prune_exports.py (see tools/bindgen/README.md) "
              "and commit the outputs with the generator change.", file=sys.stderr)
        return 1
    print(f"OK: {len(OUTPUTS)} generated artifacts match the checked-in tree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
