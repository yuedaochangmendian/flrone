"""The `profiles.platform` duty contract (ADR 0005 final stage).

The profile editor's Kotlin-only work — parsing, validation, the subscription
queue, the selection settings, the auto-selector runtime — crosses the bridge as
ONE channel method, `profiles.platform` with `{op, payload}`. That keeps the
channel surface small, but it also hides the op names from the method-level
channel audit: a renamed op would surface only as a runtime error, and an op
nobody calls would linger as dead surface.

This script closes that gap by checking the two tables against each other:

  * every literal op the Dart side invokes (`profilePlatform('…')` /
    `_profileDutyAct('…')`) has a `"…" to { … }` entry in
    `BboxProfileDuty.kt`'s handler table;
  * every Kotlin entry has at least one Dart caller — an op only the Kotlin
    side calls internally belongs in BboxProfiles, not on the bridge.

Run from the repository root:
    python3 tools/diagnostics/platform_duty_audit.py
Exit code 0 when both directions agree, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DUTY = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "BboxProfileDuty.kt"
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"

# The two Dart entry points of the boundary: the raw invoker and the bool
# wrapper. Only calls with a literal op are auditable; the definition itself
# takes an identifier and never matches.
DART_CALL = re.compile(
    r"(?:profilePlatform|_profileDutyAct)\s*\(\s*'([a-zA-Z][a-zA-Z0-9_]*)'"
)
# One handler-table entry: `"op" to { payload -> … },` inside linkedMapOf(…).
KOTLIN_OP = re.compile(r'^\s*"([a-zA-Z][a-zA-Z0-9_]*)"\s+to\s+\{', re.M)


def kotlin_ops() -> set[str]:
    text = DUTY.read_text(encoding="utf-8")
    start = text.find("linkedMapOf(")
    end = text.find("\n    )", start)
    if start < 0 or end < 0:
        raise SystemExit(
            "platform duty audit: cannot bound BboxProfileDuty's handler table — "
            "adjust kotlin_ops() to the new shape"
        )
    return set(KOTLIN_OP.findall(text[start:end]))


def dart_ops() -> dict[str, list[str]]:
    """Literal ops the Dart side invokes, with the files that invoke them."""
    found: dict[str, list[str]] = {}
    for path in sorted(FLUTTER_LIB.rglob("*.dart")):
        for op in DART_CALL.findall(path.read_text(encoding="utf-8")):
            found.setdefault(op, []).append(path.relative_to(REPO_ROOT).as_posix())
    return found


def main() -> int:
    kotlin = kotlin_ops()
    dart = dart_ops()
    problems: list[str] = []
    for op in sorted(set(dart) - kotlin):
        problems.append(f"Dart calls `{op}` but BboxProfileDuty has no handler ({', '.join(dart[op])})")
    for op in sorted(kotlin - set(dart)):
        problems.append(f"BboxProfileDuty handles `{op}` but no Dart caller exists")
    if problems:
        print("platform duty contract FAILED:")
        for problem in problems:
            print(" -", problem)
        return 1
    print(f"platform duty contract OK: {len(kotlin)} ops, both ends agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
