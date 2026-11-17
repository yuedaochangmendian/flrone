"""Guards the core bridge patch against upstream drift.

`buildScript/apply-core-patch.sh` is a **silent overlay**: it copies
`buildScript/core-patch/core/mobile/` over `core/mobile/` in a Throneproj/Throne
checkout, and any file of the same name is replaced. When `THRONE_CORE_REF` moves,
an upstream rename (a field, a function, a handler signature) does not merge and
does not warn — the overlay wins, the Go build fails somewhere unrelated, or worse,
a binding compiles against a symbol that no longer means what the patch assumes.

This audit runs where the pinned checkout exists (the core CI step, right after
patching) and checks the assumptions that would otherwise fail silently:

1. **Upstream anchors** — the files the overlay only *adds beside* (`mobile.go`,
   `log.go`, `instance.go`) still declare what the overlay and the Kotlin host call.
   This is where an upstream rename shows up first.
2. **Overlay invariants** — the replaced files still carry the pieces this fork
   depends on (`actionHandlers` registry, both gobind test entry points and the
   FFI-mode `resolveTestCurrent` resolution from the delay-test fix), and the AAR
   build script builds sing-tun's own stacks only (no `with_gvisor`).
3. **Generated files** — every file the generator owns still starts with its
   `DO NOT EDIT` banner; a hand-edit or a stale copy is a real mis-binding risk.
4. **Pin** — when the checkout's `.git/HEAD` is a detached sha, it must be the
   `THRONE_CORE_REF` the app pins (read from `nb4a.properties` or the environment).

Run from the repository root (or in CI, where `THRONE_DIR` points at the checkout):

    python3 tools/diagnostics/core_patch_audit.py [--checkout PATH] [--ref SHA]
    python3 tools/diagnostics/core_patch_audit.py --self-test

Exit codes: 0 clean, 1 a check failed, 2 the checkout is missing (run it only
where the core is checked out — a skip must not look like a pass).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
OVERLAY = REPO / "buildScript" / "core-patch" / "core" / "mobile"
SCRIPT_OVERLAY = REPO / "buildScript" / "core-patch" / "script"

# Files the overlay adds beside upstream's own; renamed symbols here break the
# overlay's callers and the gobind surface Kotlin compiles against.
UPSTREAM_ANCHORS = {
    "mobile.go": [
        "type SetupOptions struct",
        "func Setup(options *SetupOptions) error",
        "func Version() string",
    ],
    "log.go": [
        "type LogSink interface",
        "func SetLogSink(sink LogSink)",
    ],
    "instance.go": [
        "type Instance struct",
        "func NewInstance(platform PlatformInterface, options *StartOptions)",
        "func (i *Instance) Start() error",
        "func (i *Instance) Close() error",
    ],
}

# Files the overlay replaces or owns; these are the fork's own invariants.
OVERLAY_ANCHORS = {
    "action.go": [
        "var actionHandlers = map[Method]actionHandler{}",
    ],
    "test.go": [
        "func StartURLTest(",
        "func StartSpeedTest(",
        # The delay-test fix: a TestCurrent request with a nil instance resolves the
        # registered box (FFI mode builds it on Dart's side, so gobind has no handle).
        "func resolveTestCurrent(",
    ],
}

# Generator-owned files and the banner each must still carry.
GENERATED = {
    "bridge_calls.go": "tools/bindgen/bindgen.py",
    "bridge_runtime.go": "tools/bindgen/bindgen.py",
    "dartbridge.go": "tools/bindgen/bindgen.py",
    "bridge_symbols.h": "tools/bindgen/bindgen.py",
    "settings_schema.go": "tools/gen_settings_schema.py",
}


def pinned_ref() -> str | None:
    ref = os.environ.get("THRONE_CORE_REF", "").strip()
    if ref:
        return ref
    metadata = REPO / "nb4a.properties"
    if not metadata.is_file():
        return None
    for line in metadata.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("THRONE_CORE_REF="):
            return line.split("=", 1)[1].strip() or None
    return None


def checkout_head(checkout: Path) -> str | None:
    """The checkout's HEAD when it is a detached commit; None for a branch (unknowable here)."""
    head = checkout / ".git" / "HEAD"
    if not head.is_file():
        return None
    text = head.read_text(encoding="utf-8", errors="replace").strip()
    return text if re.fullmatch(r"[0-9a-f]{40}", text) else None


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def audit(
    checkout: Path,
    overlay: Path,
    ref: str | None,
    script_overlay: Path | None = None,
) -> list[str]:
    problems: list[str] = []

    if not (checkout / "core" / "mobile").is_dir():
        return [f"{checkout} does not look like a Throne checkout (no core/mobile)"]
    if not overlay.is_dir():
        return [f"overlay directory not found: {overlay}"]

    for name, anchors in UPSTREAM_ANCHORS.items():
        path = checkout / "core" / "mobile" / name
        if not path.is_file():
            problems.append(f"upstream file missing: core/mobile/{name}")
            continue
        text = read(path)
        for anchor in anchors:
            if anchor not in text:
                problems.append(f"core/mobile/{name} no longer declares `{anchor}` — the overlay assumes it")

    for name, anchors in OVERLAY_ANCHORS.items():
        path = overlay / name
        if not path.is_file():
            problems.append(f"overlay file missing: {name}")
            continue
        text = read(path)
        for anchor in anchors:
            if anchor not in text:
                problems.append(f"overlay {name} lost `{anchor}`")

    for name, generator in GENERATED.items():
        path = overlay / name
        if not path.is_file():
            problems.append(f"generated file missing from the overlay: {name}")
            continue
        first = read(path).splitlines()[:2]
        head = " ".join(first)
        if "DO NOT EDIT" not in head or generator not in head:
            problems.append(f"{name} is not the {generator} output (banner missing or stale)")

    # The overlay also replaces the AAR build script: this fork builds sing-tun's own
    # stacks (go/system) only, so with_gvisor must be gone from the tag list.
    script = (script_overlay or SCRIPT_OVERLAY) / "build_android.sh"
    if not script.is_file():
        problems.append("overlay is missing script/build_android.sh")
    else:
        tags = next(
            (line for line in read(script).splitlines() if line.startswith("TAGS=")),
            "",
        )
        if not tags:
            problems.append("overlay script/build_android.sh has no TAGS= line")
        elif "with_gvisor" in tags:
            problems.append("overlay script/build_android.sh still builds with_gvisor")
    checkout_script = checkout / "script" / "build_android.sh"
    if checkout_script.is_file():
        tags = next(
            (line for line in read(checkout_script).splitlines() if line.startswith("TAGS=")),
            "",
        )
        if "with_gvisor" in tags:
            problems.append(
                "the patched checkout still builds with_gvisor; "
                "apply-core-patch.sh did not overwrite script/build_android.sh"
            )

    if ref is not None:
        head = checkout_head(checkout)
        if head is not None and head != ref:
            problems.append(f"checkout is at {head}, but the app pins {ref} (THRONE_CORE_REF)")

    return problems


def self_test() -> int:
    ref = "48273be2870fd2c81059628ff2cc439ac711808e"
    failures: list[str] = []

    def fresh(root: Path) -> tuple[Path, Path]:
        checkout = root / "Throne"
        mobile = checkout / "core" / "mobile"
        mobile.mkdir(parents=True, exist_ok=True)
        (checkout / ".git").mkdir(exist_ok=True)
        (checkout / ".git" / "HEAD").write_text(ref + "\n", encoding="utf-8")
        for name, anchors in UPSTREAM_ANCHORS.items():
            (mobile / name).write_text("\n".join(anchors) + "\n", encoding="utf-8")
        # The real checkout carries script/build_android.sh; the synthetic one copies the
        # overlay's version so the "patched checkout builds no gvisor" check sees a file.
        (checkout / "script").mkdir(exist_ok=True)
        script_overlay = root / "script"
        if script_overlay.exists():
            shutil.rmtree(script_overlay)
        shutil.copytree(SCRIPT_OVERLAY, script_overlay)
        shutil.copyfile(script_overlay / "build_android.sh", checkout / "script" / "build_android.sh")
        overlay = root / "overlay"
        if overlay.exists():
            shutil.rmtree(overlay)
        shutil.copytree(OVERLAY, overlay)
        return checkout, overlay

    def expect(root: Path, label: str, should_fail: bool, mutate) -> None:
        checkout, overlay = fresh(root)
        mutate(checkout, overlay)
        problems = audit(checkout, overlay, ref, overlay.parent / "script")
        if should_fail and not problems:
            failures.append(f"{label}: expected a failure, audit passed")
        if not should_fail and problems:
            failures.append(f"{label}: expected a pass, got {problems}")

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        expect(root, "clean tree", False, lambda checkout, overlay: None)

        def break_overlay_piece(checkout: Path, overlay: Path) -> None:
            path = overlay / "test.go"
            path.write_text(read(path).replace("func resolveTestCurrent(", "func gone("), encoding="utf-8")

        expect(root, "missing overlay anchor", True, break_overlay_piece)

        def break_upstream_anchor(checkout: Path, overlay: Path) -> None:
            path = checkout / "core" / "mobile" / "log.go"
            path.write_text(read(path).replace("func SetLogSink(sink LogSink)", "func setLogSink(sink LogSink)"), encoding="utf-8")

        expect(root, "renamed upstream anchor", True, break_upstream_anchor)

        def strip_banner(checkout: Path, overlay: Path) -> None:
            path = overlay / "bridge_calls.go"
            path.write_text("package mobile\n", encoding="utf-8")

        expect(root, "generated banner removed", True, strip_banner)

        def wrong_pin(checkout: Path, overlay: Path) -> None:
            (checkout / ".git" / "HEAD").write_text("0" * 40 + "\n", encoding="utf-8")

        expect(root, "pin mismatch", True, wrong_pin)

        def overlay_keeps_gvisor(checkout: Path, overlay: Path) -> None:
            path = overlay.parent / "script" / "build_android.sh"
            path.write_text(
                read(path).replace('TAGS="', 'TAGS="with_gvisor,'),
                encoding="utf-8",
            )

        expect(root, "overlay still builds gvisor", True, overlay_keeps_gvisor)

        def checkout_keeps_gvisor(checkout: Path, overlay: Path) -> None:
            path = checkout / "script" / "build_android.sh"
            path.write_text(
                read(path).replace('TAGS="', 'TAGS="with_gvisor,'),
                encoding="utf-8",
            )

        expect(root, "patched checkout still builds gvisor", True, checkout_keeps_gvisor)

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("core_patch_audit self-test: OK (7 cases)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--checkout", type=Path, help="the pinned Throne checkout (default: $THRONE_DIR or ../Throne)")
    parser.add_argument("--overlay", type=Path, default=OVERLAY, help="the patch overlay directory")
    parser.add_argument("--ref", default=None, help="the pinned commit (default: $THRONE_CORE_REF or nb4a.properties)")
    parser.add_argument("--self-test", action="store_true", help="exercise the checks against synthetic trees")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    checkout = args.checkout or (Path(os.environ["THRONE_DIR"]) if os.environ.get("THRONE_DIR") else REPO.parent / "Throne")
    if not (checkout / "core" / "mobile").is_dir():
        print(f"FAIL: no Throne checkout at {checkout} (pass --checkout or set THRONE_DIR); "
              "this audit only runs where the core is checked out")
        return 2

    problems = audit(checkout, args.overlay, args.ref if args.ref is not None else pinned_ref())
    if problems:
        for problem in problems:
            print(f"FAIL: {problem}")
        return 1
    print(f"core_patch_audit: OK (upstream anchors, overlay invariants, generated banners, pin {pinned_ref() or 'unchecked'})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
