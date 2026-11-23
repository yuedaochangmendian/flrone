#!/usr/bin/env python3
"""The backup data-plane contract (P14; ADR 0006 stage C2c2a).

An Android app cannot dlopen the platform SQLite (no public `libsqlite3.so` on
AOSP, `libsqlite.so` not in public.libraries.txt), so the Dart-side `dart:ffi`
backup writer answers null on a stock device. The host side lives in
`BboxRoomSnapshot.kt` plus `LegacyRoomReader.kt`, and since C2c2a it has **no
live-Room op at all** — the backup reads and writes documents:

  * `backup.container`   - parameterized SQL Dart authors, host executes against
    the backup's own container file. ADR 0006 stage C2c1 replaced `data.roomSql`
    with this: it opens files in the app's own cache tree only, `sager_net.db`
    and the documents directory are refused, and there is no live-Room handle.
  * `settings.snapshot` / `markers.snapshot` - the live `settings.json` /
    `markers.json` documents as column rows (the export's source).
  * `settings.restore` / `markers.restore` - one merge + whole-set replace each
    (the restore's sink, including the selection repair from Dart's ids).
  * `data.legacyRows` - the retired `sager_net.db`, read with the framework
    SQLite and **no Room**, and only for documents that are still absent.

The retired DAO pumps `data.roomSnapshot`, `data.applyRoomSnapshot` and
`data.roomProfiles` must never come back, and neither may `data.roomSql`.

This audit keeps the two ends honest, the same way platform_duty_audit.py holds
BboxProfileDuty's op table:

  1. every live method has a Dart caller and a Kotlin handler, and the retired
     ones appear on neither side;
  2. `backup.container`'s op table agrees across both ends;
  3. BboxRoomSnapshot.kt authors no raw SQL literal and gates exec+query with
     `isAllowedSql`; the container arm itself never touches Room;
  4. `confinedContainerFile` still refuses the live database, the documents
     directory and the rule-set catalog (by name, directory and canonical path)
     and computes the live path without opening Room;
  5. the settings/markers merge is document-only (`SettingsJsonStore`), and the
     androidOnly key set agrees across SettingsRegistry.ANDROID_KEYS,
     BboxRoomSnapshot.ANDROID_ONLY_SETTINGS and Dart's backupAndroidKeys;
  6. the staged-row parser (`tableRows`) still fails loudly on a malformed row
     and is covered by the Kotlin unit test;
  7. `LegacyRoomReader` is read-only (SELECT only, `OPEN_READONLY`, no
     CREATE_IF_NECESSARY), and `RoomToJsonMigration` delegates to it instead of
     naming `SagerDatabase`;
  8. the Dart writer opens no live database and keeps the one-sided route
     cleanup on the documents.

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
LEGACY = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "LegacyRoomReader.kt"
MIGRATION = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "RoomToJsonMigration.kt"
WRITER = REPO_ROOT / "flutter" / "lib" / "services" / "backup_write.dart"
HOST = REPO_ROOT / "flutter" / "lib" / "services" / "room_snapshot_host.dart"
BOX = REPO_ROOT / "flutter" / "lib" / "box.dart"
BOX_API = REPO_ROOT / "flutter" / "lib" / "box_api.dart"
# The androidOnly key contract spans three files. Constants.kt resolves the
# Key.X symbols SettingsRegistry.ANDROID_KEYS is written with.
SETTINGS_REGISTRY = (
    REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "SettingsRegistry.kt"
)
CONSTANTS = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "Constants.kt"
# The Kotlin unit tests are the real gates for the staged-row wire shape and the
# legacy reader's row/eligibility decisions.
ROOM_SNAPSHOT_TEST = (
    REPO_ROOT / "app" / "src" / "test" / "java" / "io" / "flrone" / "bridge" / "BboxRoomSnapshotTest.kt"
)
LEGACY_TEST = (
    REPO_ROOT / "app" / "src" / "test" / "java" / "io" / "flrone" / "bridge" / "LegacyRoomReaderTest.kt"
)

METHODS = (
    "backup.container",
    "settings.snapshot",
    "markers.snapshot",
    "settings.restore",
    "markers.restore",
    "data.legacyRows",
)

# The ops dispatched inside `backup.container`. The channel audit only checks
# the method name; a renamed or misspelled op on either side would stay green
# until a backup/restore hit the unknown-op error at runtime.
CONTAINER_OPS = {"open", "close", "exec", "query", "readBytes", "writeBytes"}

# ADR 0006 stage C2c2a: the live-Room half of the data plane. A reappearing
# name restores an op that read or wrote Room's tables — a hard failure.
RETIRED_METHODS = (
    "data.roomSnapshot",
    "data.applyRoomSnapshot",
    "data.roomProfiles",
    "data.roomSql",
)


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


# A raw SQL literal is a string starting with a SQL keyword followed by SQL
# text. A bare keyword used as a whitelist token ("SELECT", "PRAGMA", ...) is
# not a statement: require a space + more SQL text after the keyword.
RAW_SQL = re.compile(
    r'"(?:SELECT|INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|PRAGMA|BEGIN|COMMIT|ROLLBACK)\b\s+[^"\n]+"',
    re.I,
)

# C2c2a: the duty file authors NO SQL literal at all. Every statement on a
# container handle comes from Dart and is bound with `?`; the old
# `PRAGMA foreign_key_check` commit gate lived in the deleted DAO pump.
ALLOWED_SQL_LITERALS: set[str] = set()

# Write statements the read-only legacy reader must never author.
WRITE_SQL = re.compile(
    r'"(?:INSERT|UPDATE|DELETE|CREATE|ALTER|DROP|ATTACH|VACUUM|REPLACE)\b\s+[^"\n]*"',
    re.I,
)


def strip_kotlin_comments(text: str) -> str:
    """Drop `//` and `/* … */` comments so a comment cannot pass a code check."""
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def raw_sql_literals(text: str) -> list[str]:
    """Raw SQL literals in [text], minus the exact reviewed exceptions."""
    return [m.group(0) for m in RAW_SQL.finditer(text) if m.group(0) not in ALLOWED_SQL_LITERALS]


def _kotlin_set_of(text: str, decl: str, symbolic: bool) -> set[str]:
    """Read a `setOf(...)` literal body for a `val <decl>: Set<String>`."""
    m = re.search(rf"val {decl}: Set<String> = setOf\((.*?)\n\s*\)", text, re.S)
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
    # C2c2a: no literal is allowlisted any more.
    if not raw_sql_literals('x("PRAGMA foreign_key_check")'):
        failures.append("raw_sql_literals accepted a literal with an empty allowlist")
    # The legacy reader's write detector.
    if not WRITE_SQL.search('db.rawQuery("DELETE FROM `settings`", null)'):
        failures.append("WRITE_SQL failed to detect a DELETE literal")
    if WRITE_SQL.search('db.rawQuery("SELECT * FROM `profiles`", null)'):
        failures.append("WRITE_SQL false-positived on a SELECT literal")
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
            print("backup data-plane audit self-test FAILED:", f)
        return 1
    print("backup data-plane audit self-test OK")
    return 0


def main() -> int:
    if "--self-test" in sys.argv:
        return self_test()
    problems: list[str] = []
    bridge = BRIDGE.read_text(encoding="utf-8")
    host = HOST.read_text(encoding="utf-8")
    duty = DUTY.read_text(encoding="utf-8")
    legacy = LEGACY.read_text(encoding="utf-8")
    writer = WRITER.read_text(encoding="utf-8")

    # 1. Every live method is implemented on the host and called from Dart.
    for method in METHODS:
        if f'"{method}"' not in bridge:
            problems.append(f"bridge lost handler {method}")
        if f"'{method}'" not in host:
            problems.append(f"host module lost caller {method}")

    # 1b. The retired live-Room ops appear on neither end (nor in the writer /
    #     controller wiring). Comments may name them in backticks; the checks
    #     look for the executable quoted forms.
    retired_files = {
        "ThroneBoxBridge.kt": bridge,
        "room_snapshot_host.dart": host,
        "backup_write.dart": writer,
        "box.dart": BOX.read_text(encoding="utf-8"),
        "box_api.dart": BOX_API.read_text(encoding="utf-8"),
    }
    for retired in RETIRED_METHODS:
        for name, text in retired_files.items():
            if re.search(rf"""['"]{re.escape(retired)}['"]""", text):
                problems.append(
                    f"{retired} is still called or handled in {name}; the backup "
                    "data plane is document-only (ADR 0006 stage C2c2a)"
                )
    if re.search(r"\bopenRoom\s*\(|['\"]openRoom['\"]", bridge + host + duty):
        problems.append(
            "an openRoom op/call survives; the container channel must not open "
            "the live database (ADR 0006 stage C2c1)"
        )

    # 2. backup.container op table: both ends name the same six operations.
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

    # 3. The container arm itself must not reach the live database: no
    #    dao/database symbol, and the only file door is the confined one.
    arm = kotlin_container_arm(bridge)
    if not arm:
        problems.append("cannot bound the backup.container arm in ThroneBoxBridge.kt")
    else:
        for symbol in ("SagerDatabase", "openHelper", "roomSql", "data.roomSnapshot"):
            if re.search(rf"\b{re.escape(symbol)}\b", arm):
                problems.append(
                    f"the backup.container arm references {symbol}; it must stay container-only"
                )
        if "confinedContainerFile" not in arm:
            problems.append(
                "the backup.container arm reads/writes paths without "
                "BboxRoomSnapshot.confinedContainerFile"
            )

    # 4. The path guard: the app's own storage only, with the live stores that
    #    share those roots refused by name, by directory and by canonical path —
    #    computed without opening Room.
    if "fun confinedContainerFile(" not in duty:
        problems.append("BboxRoomSnapshot.confinedContainerFile is missing; the container path guard is gone")
    else:
        guard = duty[duty.index("fun confinedContainerFile("):]
        guard = guard[:guard.find("\n    }")]
        for needle, why in (
            ("app.cacheDir", "the private-storage root list"),
            ("sager_net.db", "the live database name"),
            ("documents", "the documents directory"),
            ("databases", "Room's database directory"),
            ("routeprofiles", "the rule-set catalog"),
            ("canonical", "canonical path normalization"),
        ):
            if needle == "sager_net.db":
                # C2c2a computes the name from Key.DB_PROFILE instead of a copy.
                if needle not in guard and "Key.DB_PROFILE" not in guard:
                    problems.append(f"confinedContainerFile lost {why} ({needle})")
                continue
            if needle not in guard:
                problems.append(f"confinedContainerFile lost {why} ({needle})")
    if "SagerDatabase" in strip_kotlin_comments(duty):
        problems.append(
            "BboxRoomSnapshot.kt still names SagerDatabase; the backup data plane "
            "must not open Room, not even for the path guard (ADR 0006 stage C2c2a)"
        )
    if "getDatabasePath" not in duty:
        problems.append(
            "BboxRoomSnapshot.confinedContainerFile must compute the live path with "
            "the framework's getDatabasePath (no Room open)"
        )

    # 5. The settings/markers documents are the only store on this side.
    for needle, why in (
        ("SettingsJsonStore", "the settings/markers documents"),
        ("fun restoreSettings(", "the settings merge op"),
        ("fun restoreMarkers(", "the markers replacement op"),
        ("settings.snapshot", "the settings snapshot op"),
        ("markers.snapshot", "the markers snapshot op"),
    ):
        if needle not in duty:
            problems.append(f"BboxRoomSnapshot.kt lost {why} ({needle})")

    # 6. No raw SQL literal in the duty file; both exec and query are gated.
    for literal in raw_sql_literals(duty):
        line = duty.count("\n", 0, duty.index(literal)) + 1
        problems.append(f"BboxRoomSnapshot.kt:{line} authors a raw SQL literal {literal!r}; "
                        "all SQL must come from Dart and be parameterized")
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

    # 7. androidOnly key set: the three definitions must agree. SettingsRegistry's
    #    ANDROID_KEYS is the authority; a divergence means a key is treated as
    #    android-only on one side and overwritten/merged differently on the other.
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

    # 8. The staged-row parser. `markers.restore` sends the Dart-stage rows; the
    #    Kotlin parser accepted only a row list once, so every table arrived
    #    empty and a restore reset rows before inserting nothing. Hold the
    #    tolerant parser and the Kotlin unit test that pins both shapes.
    if "restoreMarkers(_tableToMaps(" not in writer:
        problems.append("backup_write.dart no longer sends the staged marker rows to markers.restore")
    if "fun tableRows(" not in duty or '"columns"' not in duty or '"rows"' not in duty:
        problems.append("BboxRoomSnapshot.tableRows no longer parses both staged-table shapes")
    if not ROOM_SNAPSHOT_TEST.is_file():
        problems.append("BboxRoomSnapshotTest.kt is missing; the staged-row regression guard is gone")
    else:
        test = ROOM_SNAPSHOT_TEST.read_text(encoding="utf-8")
        for needle in ("tableRows(", '"columns"', '"rows"', "restoreSettings", "restoreMarkers"):
            if needle not in test:
                problems.append(f"BboxRoomSnapshotTest does not cover {needle}")

    # 9. The legacy reader: read-only, no Room, document-gated.
    if not LEGACY.is_file():
        problems.append("LegacyRoomReader.kt is missing; the legacy hand-over has no raw reader")
    else:
        for literal in WRITE_SQL.findall(legacy):
            problems.append(f"LegacyRoomReader.kt authors a write statement {literal!r}; it must be read-only")
        if "SQLiteDatabase.OPEN_READONLY" not in legacy:
            problems.append("LegacyRoomReader.kt does not open the database read-only")
        if "CREATE_IF_NECESSARY" in legacy or "OPEN_READWRITE" in legacy:
            problems.append("LegacyRoomReader.kt can open the database writable; it must never create or migrate")
        for needle, why in (
            ("fun eligible(", "the document-presence gate"),
            ("fun snapshot(", "the data.legacyRows reply"),
            ("fun seedRouteDocuments(", "the route-document hand-over"),
            ("!file.isFile", "the missing-file fast path"),
        ):
            if needle not in legacy:
                problems.append(f"LegacyRoomReader.kt lost {why} ({needle})")
    if "SagerDatabase" in MIGRATION.read_text(encoding="utf-8"):
        problems.append("RoomToJsonMigration.kt still names SagerDatabase; seed must delegate to LegacyRoomReader")
    elif "LegacyRoomReader.seedRouteDocuments(" not in MIGRATION.read_text(encoding="utf-8"):
        problems.append("RoomToJsonMigration.seed no longer delegates to LegacyRoomReader")
    if not LEGACY_TEST.is_file():
        problems.append("LegacyRoomReaderTest.kt is missing; the read-only contract is unguarded")
    else:
        test = LEGACY_TEST.read_text(encoding="utf-8")
        for needle in ("a missing database answers empty and is never created", "seedRouteDocuments"):
            if needle not in test:
                problems.append(f"LegacyRoomReaderTest does not cover {needle}")

    # 10. The Dart writer opens no live database and keeps the one-sided route
    #     cleanup on the documents.
    if re.search(r"opener\(\s*env\.databasePath", writer):
        problems.append("backup_write.dart opens env.databasePath as a database; the data plane is document-only")
    if "RoomRows" in writer:
        problems.append("backup_write.dart still has the host Room-rows type")
    if "clearSourceGids" not in writer:
        problems.append("backup_write.dart lost the one-sided route source_gid cleanup")
    if "routeId == -1" not in writer:
        problems.append("backup_write.dart lost the one-sided groups route_id cleanup")

    if problems:
        print("backup data-plane contract FAILED:")
        for problem in problems:
            print(" -", problem)
        return 1
    print(f"backup data-plane contract OK: {len(METHODS)} methods, no live-Room op, "
          f"isAllowedSql gates exec+query, {len(CONTAINER_OPS)} container ops agree, "
          f"read-only legacy reader, {len(next(iter(sets.values())))} androidOnly keys agree across 3 files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
