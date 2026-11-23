#!/usr/bin/env python3
"""The P14 Room-snapshot duty contract (backup on devices without SQLite).

An Android app cannot dlopen the platform SQLite (no public `libsqlite3.so` on
AOSP, `libsqlite.so` not in public.libraries.txt), so the Dart-side `dart:ffi`
backup writer answers null on a stock device. P14 moves the Room row pump to the
process that owns Room: three narrow channel methods, all implemented by
`BboxRoomSnapshot.kt`:

  * `data.roomSnapshot`  - DAO reads of profiles/groups/routes, plus
    settings/markers synthesized from their documents (ADR 0006 stage C2b:
    Room's tables retired in schema 21, the host snapshot keeps the column
    shape so a container still carries the two SQL tables)
  * `backup.container`   - parameterized SQL Dart authors, host executes against
    the backup's own container file. ADR 0006 stage C2c1 replaced `data.roomSql`
    with this: it opens files in the app's cache tree only, `sager_net.db` and
    the documents directory are refused, and there is no live-Room op.
  * `data.applyRoomSnapshot` - DAO writes (routes) plus document writes
    (settings/markers) in one call

This audit keeps the two ends honest, the same way platform_duty_audit.py holds
BboxProfileDuty's op table:

  1. all three methods have a Dart caller and a Kotlin handler;
  2. the Kotlin DAO row mappers emit every column the Dart desktop snapshot
     copies. A mapper that silently drops a column means silent backup data
     loss that unit tests with the ffi path cannot catch;
  3. BboxRoomSnapshot.kt authors no raw SQL literal except the one reviewed
     parameterless `PRAGMA foreign_key_check` (exact-match allowlist) - all
     other SQL crosses the wire from Dart and is bound with `?` there (the
     security constraint of P14);
  4. `isAllowedSql` gates both `exec` and `query` (the backup.container
     whitelist);
  5. the androidOnly key set agrees across SettingsRegistry.ANDROID_KEYS,
     BboxRoomSnapshot.ANDROID_ONLY_SETTINGS and Dart's backupAndroidKeys;
  6. the retired settings/markers entities, DAOs and tables are not named by
     the duty file any more (ADR 0006 stage C2b — schema 21 dropped them);
  7. C2c1: `data.roomSql` is gone everywhere, no live-Room open op exists, and
     the container guard refuses the live Room database, the documents
     directory and the rule-set catalog (no live store may be reachable
     through the transport).

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
# The androidOnly key contract spans three files. Constants.kt resolves the
# Key.X symbols SettingsRegistry.ANDROID_KEYS is written with.
SETTINGS_REGISTRY = (
    REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "SettingsRegistry.kt"
)
CONSTANTS = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "Constants.kt"
# The Kotlin unit test is the real gate for the staged-table wire shape: if it
# is deleted or renamed the audit must fail, because that test is the only
# regression guard against "restore clears the user's rows".
ROOM_SNAPSHOT_TEST = (
    REPO_ROOT / "app" / "src" / "test" / "java" / "io" / "flrone" / "bridge" / "BboxRoomSnapshotTest.kt"
)

METHODS = ("data.roomSnapshot", "backup.container", "data.applyRoomSnapshot")

# The ops dispatched inside `backup.container`. The channel audit only checks
# the method name; a renamed or misspelled op on either side would stay green
# until a backup/restore hit the unknown-op error at runtime. C2c1 removed
# `openRoom`: the transport has no live Room handle.
CONTAINER_OPS = {"open", "close", "exec", "query", "readBytes", "writeBytes"}

# The retired transport's name. A reappearing `data.roomSql` arm would restore
# the live-Room door C2c1 closed, so it is a hard failure everywhere.
RETIRED_CHANNEL = "data.roomSql"


def dart_container_ops(text: str) -> set[str]:
    """The literal `'op': '…'` values of every backup.container call in [text]."""
    return set(
        re.findall(
            r"'backup\.container'.{0,240}?'op':\s*'([a-zA-Z]+)'", text, re.S
        )
    )


def _braced_block(text: str, open_index: int) -> str:
    """The text between the `{` at [open_index] and its matching `}`."""
    depth = 0
    index = open_index
    while index < len(text):
        char = text[index]
        if char == '"':
            index += 1
            while index < len(text) and text[index] != '"':
                index += 2 if text[index] == "\\" else 1
            index += 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[open_index + 1:index]
        index += 1
    return ""


def kotlin_container_ops(text: str) -> set[str]:
    """The quoted arms of `when (args["op"])` in the bridge's container handler.

    Brace-counted rather than regex-bounded: several arms have their own
    `{ … }` bodies, so the first closing brace after the `when` is not the end
    of the block.
    """
    m = re.search(r'when \(args\["op"\]\)\s*\{', text)
    if not m:
        return set()
    body = _braced_block(text, m.end() - 1)
    ops: set[str] = set()
    for arm in re.finditer(
        r'^\s*((?:"[a-zA-Z]+"\s*,\s*)*"[a-zA-Z]+")\s*->', body, re.M
    ):
        ops |= set(re.findall(r'"([a-zA-Z]+)"', arm.group(1)))
    return ops


def kotlin_container_arm(text: str) -> str:
    """The body of the `"backup.container" ->` arm of the bridge's `when`."""
    m = re.search(r'"backup\.container"\s*->', text)
    if not m:
        return ""
    open_brace = text.find("{", m.end())
    if open_brace < 0:
        return ""
    return _braced_block(text, open_brace)

# The Kotlin mapper fun -> the Dart desktop table whose columns it must cover.
# `created_at` / `updated_at` are DDL-derived and intentionally absent from both.
MAPPERS = {
    "profileRow": "profiles",
    "groupRow": "groups",
    "routeProfileRow": "route_profiles",
    "routeRuleRow": "route_rules",
    "globalRuleRow": "global_route_rules",
}
DERIVED = {"created_at", "updated_at", "profiles_json"}

# A raw SQL literal is a string starting with a SQL keyword followed by SQL
# text. A bare keyword used as a whitelist token ("SELECT", "PRAGMA", ...) is
# not a statement: require a space + more SQL text after the keyword.
RAW_SQL = re.compile(
    r'"(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|PRAGMA|BEGIN|COMMIT|ROLLBACK)\b\s+[^"\n]+"',
    re.I,
)

# Exactly one SQL literal is reviewed and allowed in Kotlin: the parameterless,
# read-only integrity probe that mirrors the FFI path's `foreign_key_check`
# commit gate. The allowlist is an exact string — this pragma WITH an argument
# (or any spelling drift) still fails the audit, as does every other literal.
ALLOWED_SQL_LITERALS = {'"PRAGMA foreign_key_check"'}

# Symbols that belonged to the settings/markers half of Room. ADR 0006 stage C2b
# deleted them (schema 21); the duty file routes those two stores through
# SettingsJsonStore instead, and naming one of these again is how a second store
# would sneak back in.
RETIRED_SETTINGS_SYMBOLS = ("settingsDao", "markerDao", "SettingEntry", "MarkerEntity")


def raw_sql_literals(text: str) -> list[str]:
    """Raw SQL literals in [text], minus the exact reviewed exceptions."""
    return [m.group(0) for m in RAW_SQL.finditer(text) if m.group(0) not in ALLOWED_SQL_LITERALS]


def _kotlin_set_of(text: str, decl: str, symbolic: bool) -> set[str]:
    """Read a `setOf(...)` literal body for a `val <decl>: Set<String>`."""
    m = re.search(rf"val {re.escape(decl)}: Set<String> = setOf\((.*?)\n\s*\)", text, re.S)
    if not m:
        return set()
    if symbolic:
        return set(re.findall(r"Key\.(\w+)", m.group(1)))
    return set(re.findall(r'"([^"]+)"', m.group(1)))


def android_only_sets() -> dict[str, set[str]]:
    """Resolve the three androidOnly key sets to their literal string values."""
    consts = CONSTANTS.read_text(encoding="utf-8")
    key_values = dict(re.findall(r'const val (\w+)\s*=\s*"([^"]+)"', consts))

    registry = SETTINGS_REGISTRY.read_text(encoding="utf-8")
    key_symbols = _kotlin_set_of(registry, "ANDROID_KEYS", symbolic=True)
    registry_keys = {key_values[s] for s in key_symbols if s in key_values}

    duty = DUTY.read_text(encoding="utf-8")
    duty_keys = _kotlin_set_of(duty, "ANDROID_ONLY_SETTINGS", symbolic=False)

    writer = WRITER.read_text(encoding="utf-8")
    m = re.search(
        r"const Set<String> backupAndroidKeys = <String>\{(.*?)\n\};", writer, re.S
    )
    dart_keys = set(re.findall(r"'([^']+)'", m.group(1))) if m else set()

    return {
        "SettingsRegistry.ANDROID_KEYS": registry_keys,
        "BboxRoomSnapshot.ANDROID_ONLY_SETTINGS": duty_keys,
        "backup_write.dart.backupAndroidKeys": dart_keys,
    }


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
    """Keep the detectors honest: a pattern that matches nothing is not a pass."""
    failures: list[str] = []
    if not RAW_SQL.search('db.execSQL("SELECT * FROM groups")'):
        failures.append("RAW_SQL failed to detect a literal SELECT")
    if RAW_SQL.search('db.compileStatement(sql) // SQL comes from Dart'):
        failures.append("RAW_SQL false-positived on a bound statement")
    # Bare whitelist tokens ("SELECT", "PRAGMA", ...) must not be flagged.
    if RAW_SQL.search('val CONTAINER_KEYWORDS = setOf("SELECT", "PRAGMA")'):
        failures.append("RAW_SQL false-positived on bare whitelist keywords")
    # The reviewed literal is allowlisted by exact match only.
    if raw_sql_literals('x("PRAGMA foreign_key_check")'):
        failures.append("allowlist failed to accept the reviewed foreign_key_check literal")
    if not raw_sql_literals('x("PRAGMA foreign_key_check; DROP TABLE t")'):
        failures.append("allowlist accepted an augmented foreign_key_check literal")
    if not raw_sql_literals('x("PRAGMA user_version = 5")'):
        failures.append("raw_sql_literals missed a PRAGMA assignment literal")
    sample = "private fun x(): Map<String, Any?> = mapOf(\n" \
             '        "id" to 1,\n        "name" to "n",\n    )'
    if not re.search(r'private fun x\(\): Map<[^>]*> = mapOf\((.*?)\n    \)', sample, re.S):
        failures.append("mapper-bound regex failed on a well-formed sample")
    # backup.container op parsing: multi-name arms and multi-line Dart maps.
    kt_ops = (
        'when (args["op"]) {\n'
        '                "open", "close" -> x()\n'
        '                "exec" -> y()\n'
        '            }'
    )
    if kotlin_container_ops(kt_ops) != {"open", "close", "exec"}:
        failures.append("kotlin backup.container op extraction failed")
    dart_ops_sample = (
        "await call('backup.container', <String, Object?>{\n"
        "      'op': 'open',\n"
        "      'path': path,\n"
        "    });\n"
        "await call('backup.container', <String, Object?>{'op': 'close'});"
    )
    if dart_container_ops(dart_ops_sample) != {"open", "close"}:
        failures.append("dart backup.container op extraction failed")
    # The arm extractor must bound the handler body, not just a line or two.
    arm = kotlin_container_arm(
        'x\n                "backup.container" -> result.respondIo {\n'
        '                    when (args["op"]) { "open" -> y() }\n'
        '                }\n                "other" -> Unit\n'
    )
    if '"open"' not in arm or '"other"' in arm:
        failures.append("kotlin backup.container arm extraction failed")
    # setOf extraction must resolve both symbolic (Key.X) and literal sets.
    sym = 'val ANDROID_KEYS: Set<String> = setOf(\n    Key.SERVICE_MODE, Key.PROXY_APPS,\n    )'
    if _kotlin_set_of(sym, "ANDROID_KEYS", symbolic=True) != {"SERVICE_MODE", "PROXY_APPS"}:
        failures.append("symbolic setOf extraction failed")
    lit = 'val ANDROID_ONLY_SETTINGS: Set<String> = setOf(\n    "a", "b",\n    )'
    if _kotlin_set_of(lit, "ANDROID_ONLY_SETTINGS", symbolic=False) != {"a", "b"}:
        failures.append("literal setOf extraction failed")
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

    # backup.container op table: both ends name the same six operations.
    dart_ops = dart_container_ops(host)
    kotlin_ops = kotlin_container_ops(bridge)
    if not dart_ops or not kotlin_ops:
        problems.append(
            "cannot parse the backup.container op table "
            f"(dart={sorted(dart_ops)}, kotlin={sorted(kotlin_ops)})"
        )
    elif dart_ops != kotlin_ops:
        problems.append(
            f"backup.container ops differ: Dart {sorted(dart_ops)} vs Kotlin {sorted(kotlin_ops)}"
        )
    elif dart_ops != CONTAINER_OPS:
        problems.append(
            f"backup.container op table changed ({sorted(dart_ops)}); update CONTAINER_OPS in this audit"
        )

    # ADR 0006 stage C2c1: `data.roomSql` is retired on both ends, and no
    # live-Room open op may exist — that arm handed Dart Room's own connection.
    # Comments may still name the retirement (in backticks); the checks look for
    # the executable forms.
    if re.search(r"""['"]data\.roomSql['"]""", bridge + host):
        problems.append(
            f"{RETIRED_CHANNEL} is still called or handled; the backup SQL "
            "transport is backup.container and has no live-Room handle "
            "(ADR 0006 stage C2c1)"
        )
    if re.search(r"\bopenRoom\s*\(|['\"]openRoom['\"]", bridge + host + duty):
        problems.append(
            "an openRoom op/call survives; the container channel must not open "
            "the live Room database (ADR 0006 stage C2c1)"
        )

    # The container arm itself must not reach Room: no dao/database symbol, and
    # the only file door is the confined one.
    arm = kotlin_container_arm(bridge)
    if not arm:
        problems.append("cannot bound the backup.container arm in ThroneBoxBridge.kt")
    else:
        for symbol in ("SagerDatabase", "openHelper", "roomSql"):
            if re.search(rf"\b{symbol}\b", arm):
                problems.append(
                    f"the backup.container arm references {symbol}; it must stay container-only"
                )
        if "confinedContainerFile" not in arm:
            problems.append(
                "the backup.container arm reads/writes paths without "
                "BboxRoomSnapshot.confinedContainerFile"
            )

    # The path guard: the app's own storage only, with the live stores that
    # share those roots refused by name, by directory and by canonical path.
    if "fun confinedContainerFile(" not in duty:
        problems.append("BboxRoomSnapshot.confinedContainerFile is missing; the container path guard is gone")
    else:
        guard = duty[duty.index("fun confinedContainerFile("):]
        guard = guard[:guard.find("\n    }")]
        for needle, why in (
            ("app.cacheDir", "the private-storage root list"),
            ("sager_net.db", "the live Room database name"),
            ("documents", "the documents directory"),
            ("databases", "Room's database directory"),
            ("routeprofiles", "the rule-set catalog"),
            ("canonical", "canonical path normalization"),
        ):
            if needle not in guard:
                problems.append(f"confinedContainerFile lost {why} ({needle})")

    # A one-sided restore must clear references into the side that was replaced
    # (Dart's `_commit` does the same), or a stale route owner claims a new group.
    if (
        "doProfiles != doRoutes" not in duty
        or "resetRouteIds" not in duty
        or "resetSourceGids" not in duty
    ):
        problems.append(
            "applyRoomSnapshot no longer clears cross-table references for a "
            "profiles-only or routes-only restore"
        )

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

    for literal in raw_sql_literals(duty):
        line = duty.count("\n", 0, duty.index(literal)) + 1
        problems.append(f"BboxRoomSnapshot.kt:{line} authors a raw SQL literal {literal!r}; "
                        "all SQL must come from Dart and be parameterized")

    # ADR 0006 stage C2b: the settings/markers entities, DAOs and tables retired
    # with schema 21. A leftover reference would not compile; pinning it here
    # keeps a later "small fallback" from quietly reintroducing the second store.
    for retired in RETIRED_SETTINGS_SYMBOLS:
        if retired in duty:
            problems.append(
                f"BboxRoomSnapshot.kt still names the retired `{retired}`; "
                "settings/markers are documents now (ADR 0006 stage C2b)"
            )

    # backup.container whitelist: a pure isAllowedSql must gate BOTH exec and
    # query, otherwise a future path can bypass the statement checks.
    if "isAllowedSql" not in duty:
        problems.append("BboxRoomSnapshot.kt has no isAllowedSql statement whitelist")
    else:
        for fn in ("exec", "query"):
            m = re.search(rf"fun {fn}\(args: Map<String, Any\?>\):(.*?)\n    \}}", duty, re.S)
            if not m:
                problems.append(f"cannot bound BboxRoomSnapshot.{fn} - adjust the audit regex")
            elif "isAllowedSql" not in m.group(1):
                problems.append(f"BboxRoomSnapshot.{fn} does not call isAllowedSql; "
                                "the SQL whitelist is bypassed")

    # androidOnly key set: the three definitions must agree. SettingsRegistry's
    # ANDROID_KEYS is the authority; a divergence means a key is treated as
    # android-only on one side and overwritten/merged differently on the other.
    sets = android_only_sets()
    names = list(sets)
    for i, name in enumerate(names):
        for other in names[i + 1:]:
            only_here = sets[name] - sets[other]
            only_there = sets[other] - sets[name]
            if only_here or only_there:
                problems.append(
                    f"androidOnly key sets differ: {name} vs {other} | "
                    f"only in {name}: {sorted(only_here)} | "
                    f"only in {other}: {sorted(only_there)}"
                )
    if any(not v for v in sets.values()):
        problems.append("an androidOnly key set could not be parsed "
                        f"(counts: { {k: len(v) for k, v in sets.items()} })")

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
          f"{len(MAPPERS)} mappers cover their Dart column lists, no raw SQL in Kotlin, "
          f"isAllowedSql gates exec+query, {len(CONTAINER_OPS)} container ops agree, "
          f"no live-Room op, {len(next(iter(sets.values())))} androidOnly keys agree across 3 files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
