#!/usr/bin/env python3
"""The P14 Room-snapshot duty contract (backup on devices without SQLite).

An Android app cannot dlopen the platform SQLite (no public `libsqlite3.so` on
AOSP, `libsqlite.so` not in public.libraries.txt), so the Dart-side `dart:ffi`
backup writer answers null on a stock device. P14 moves the Room row pump to the
process that owns Room: three narrow channel methods, all implemented by
`BboxRoomSnapshot.kt`:

  * `data.roomSnapshot`  - DAO reads of profiles/groups/routes/settings/markers
  * `data.roomSql`       - parameterized SQL Dart authors, host executes
  * `data.applyRoomSnapshot` - DAO writes in one transaction

This audit keeps the two ends honest, the same way platform_duty_audit.py holds
BboxProfileDuty's op table:

  1. all three methods have a Dart caller and a Kotlin handler;
  2. the Kotlin DAO row mappers emit every column the Dart desktop snapshot
     copies. A mapper that silently drops a column means silent backup data
     loss that unit tests with the ffi path cannot catch;
  3. BboxRoomSnapshot.kt authors no raw SQL literal - all SQL crosses the wire
     from Dart and is bound with `?` there (the security constraint of P14).

Run from the repository root:
    python3 tools/diagnostics/room_snapshot_audit.py
Exit 0 when both ends agree, 1 otherwise.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
BRIDGE = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "flutter" / "ThroneBoxBridge.kt"
DUTY = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "BboxRoomSnapshot.kt"
WRITER = REPO_ROOT / "flutter" / "lib" / "services" / "backup_write.dart"
HOST = REPO_ROOT / "flutter" / "lib" / "services" / "room_snapshot_host.dart"
# The Kotlin unit test is the real gate for the staged-table wire shape: if it
# is deleted or renamed the audit must fail, because that test is the only
# regression guard against "restore clears the user's rows".
ROOM_SNAPSHOT_TEST = (
    REPO_ROOT / "app" / "src" / "test" / "java" / "io" / "flrone" / "bridge" / "BboxRoomSnapshotTest.kt"
)

METHODS = ("data.roomSnapshot", "data.roomSql", "data.applyRoomSnapshot")

# The Kotlin mapper fun -> the Dart desktop table whose columns it must cover.
# `created_at` / `updated_at` are DDL-derived and intentionally absent from both.
MAPPERS = {
    "profileRow": "profiles",
    "groupRow": "groups",
    "routeProfileRow": "route_profiles",
    "routeRuleRow": "route_rules",
}
DERIVED = {"created_at", "updated_at", "profiles_json"}

RAW_SQL = re.compile(
    r'"(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|PRAGMA|BEGIN|COMMIT|ROLLBACK)\b',
    re.I,
)


def dart_desktop_columns() -> dict[str, set[str]]:
    """Read the `_desktopColumnsFor` switch's literal column lists."""
    text = WRITER.read_text(encoding="utf-8")
    out: dict[str, set[str]] = {}
    for table, body in re.findall(
        r"'(\w+)'\s*=>\s*const <String>\[(.*?)\]", text, re.S
    ):
        cols = set(re.findall(r"'([a-z_]+)'", body))
        out[table] = cols - DERIVED
    return out


def kotlin_mapper_columns() -> dict[str, set[str]]:
    """Read the `"column" to ...` keys inside each mapper's mapOf(...)."""
    text = DUTY.read_text(encoding="utf-8")
    out: dict[str, set[str]] = {}
    for fn in MAPPERS:
        m = re.search(rf"private fun {fn}\([^)]*\): Map<[^>]*> = mapOf\((.*?)\n    \)", text, re.S)
        if not m:
            out[fn] = set()
            continue
        out[fn] = set(re.findall(r'"([a-z_]+)"\s+to', m.group(1)))
    return out


def self_test() -> int:
    """Keep the detector honest: a pattern that matches nothing is not a pass."""
    failures: list[str] = []
    if not RAW_SQL.search('db.execSQL("SELECT * FROM groups")'):
        failures.append("RAW_SQL failed to detect a literal SELECT")
    if RAW_SQL.search('db.compileStatement(sql) // SQL comes from Dart'):
        failures.append("RAW_SQL false-positived on a bound statement")
    sample = "private fun x(): Map<String, Any?> = mapOf(\n" \
             '        "id" to 1,\n        "name" to "n",\n    )'
    if not re.search(r'private fun x\(\): Map<[^>]*> = mapOf\((.*?)\n    \)', sample, re.S):
        failures.append("mapper-bound regex failed on a well-formed sample")
    if failures:
        for f in failures:
            print("room snapshot audit self-test FAILED:", f)
        return 1
    print("room snapshot audit self-test OK")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    problems: list[str] = []
    bridge = BRIDGE.read_text(encoding="utf-8")
    host = HOST.read_text(encoding="utf-8")
    duty = DUTY.read_text(encoding="utf-8")

    for method in METHODS:
        if f'"{method}"' not in bridge:
            problems.append(f"bridge lost handler {method}")
        if f"'{method}'" not in host:
            problems.append(f"host module lost caller {method}")

    desktop = dart_desktop_columns()
    mappers = kotlin_mapper_columns()
    for fn, table in MAPPERS.items():
        expected = desktop.get(table, set())
        actual = mappers.get(fn, set())
        if not actual:
            problems.append(f"cannot bound BboxRoomSnapshot.{fn}'s mapOf - adjust kotlin_mapper_columns()")
            continue
        missing = expected - actual
        if missing:
            problems.append(
                f"{fn} does not emit column(s) {sorted(missing)} that Dart's "
                f"{table} snapshot copies - silent backup data loss"
            )

    for match in RAW_SQL.finditer(duty):
        line = duty.count("\n", 0, match.start()) + 1
        problems.append(f"BboxRoomSnapshot.kt:{line} authors a raw SQL literal; "
                        "all SQL must come from Dart and be parameterized")

    # The staged-table wire shape. Dart sends `{columns, rows}` per table; the
    # first Kotlin parser accepted only a row list, so every table arrived empty
    # and a restore reset the catalog before inserting nothing. Hold both ends
    # to the shape and require the Kotlin unit test that pins it.
    writer = WRITER.read_text(encoding="utf-8")
    if "'columns':" not in writer or "'rows':" not in writer:
        problems.append("backup_write.dart no longer sends the {columns, rows} staged-table shape")
    if "fun tableRows(" not in duty or '"columns"' not in duty or '"rows"' not in duty:
        problems.append("BboxRoomSnapshot.tableRows no longer parses the {columns, rows} staged-table shape")
    if not ROOM_SNAPSHOT_TEST.is_file():
        problems.append("BboxRoomSnapshotTest.kt is missing; the staged-table regression guard is gone")
    else:
        test = ROOM_SNAPSHOT_TEST.read_text(encoding="utf-8")
        for needle in ("tableRows(", '"columns"', '"rows"'):
            if needle not in test:
                problems.append(f"BboxRoomSnapshotTest does not cover {needle}")

    if problems:
        print("room snapshot contract FAILED:")
        for problem in problems:
            print(" -", problem)
        return 1
    print(f"room snapshot contract OK: {len(METHODS)} methods, "
          f"{len(MAPPERS)} mappers cover their Dart column lists, no raw SQL in Kotlin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
