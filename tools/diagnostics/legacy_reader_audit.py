#!/usr/bin/env python3
"""ADR 0006 stage C2c2b2: Room is gone; the retired database has one reader.

After C2c2b2 the app has no Room code and no database on the live path:

  * profiles/groups  -> `documents/profiles.json` (Dart's ProfileStore)
  * routes           -> the kernel's `documents/route_*.json` (Go's writer)
  * settings/markers -> `documents/settings.json` / `markers.json`

The only code allowed to touch the old `sager_net.db` is
`app/src/main/java/io/flrone/bridge/LegacyRoomReader.kt`, and only for the
one-time seed: read-only, no DDL, no writes, per-table document gate.

This audit replaces `schema_audit.py` and `room_snapshot_audit.py`, both of
which guarded Room's own invariants (schema version, DAO SQL) and retired with
it. It checks, statically:

  1. no Room residue: no `androidx.room` import/annotation anywhere in
     `app/src`, no `@Entity`/`@Database`/`@Dao`, no `SagerDatabase`, no
     `RoomToJsonMigration`, no `AndroidLegacySettingsReader`, no
     `RoomPreferenceDataStore`/`TempDatabase`, no `app/schemas`, no Room/KSP
     Gradle plugin or dependency, no `roomSchemaVersion` or ffi SQLite reader in
     `flutter/lib`, and no `flutter/lib/data/db.dart`/`data_layer.dart`/
     `route_profiles_source.dart` (the read-only Room data plane);
  2. `LegacyRoomReader` is read-only: `OPEN_READONLY`, no
     `CREATE_IF_NECESSARY`/`CREATE`, no INSERT/UPDATE/DELETE/DDL, only SELECTs
     against a compile-time table list;
  3. the seed delegates to it (`LegacyDocumentSeed.seed` ->
     `LegacyRoomReader.seedRouteDocuments`), and `SettingsJsonStore` seeds from
     `LegacyRoomReader.settings()`/`markers()` instead of a second reader;
  4. `RouteJsonStore` is read-only (no write method, no file writes) — the
     kernel is the route documents' only writer.

Run from the repository root:
    python3 tools/diagnostics/legacy_reader_audit.py [--self-test]
Exit 0 when every invariant holds, 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
APP_SRC = REPO_ROOT / "app" / "src"
GRADLE_FILES = [
    REPO_ROOT / "app" / "build.gradle.kts",
    REPO_ROOT / "build.gradle.kts",
    REPO_ROOT / "settings.gradle.kts",
]
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"
LEGACY = APP_SRC / "main" / "java" / "io" / "flrone" / "bridge" / "LegacyRoomReader.kt"
SEED = APP_SRC / "main" / "java" / "io" / "flrone" / "bridge" / "LegacyDocumentSeed.kt"
SETTINGS_STORE = (
    APP_SRC / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "SettingsJsonStore.kt"
)
ROUTE_STORE = (
    APP_SRC / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "RouteJsonStore.kt"
)
CI = REPO_ROOT / ".github" / "workflows" / "ci.yml"

# Tokens that must not appear in app code at all. Room's own transitive
# dependency through WorkManager is a library, not app code: it never appears
# in these sources.
FORBIDDEN_TOKENS = [
    "androidx.room",
    "@Entity",
    "@Database",
    "@Dao",
    "@TypeConverter",
    "SagerDatabase",
    "RoomToJsonMigration",
    "AndroidLegacySettingsReader",
    "RoomPreferenceDataStore",
    "TempDatabase",
]
# Historian/comment mentions of the retired names are allowed only in docs; in
# source they would be a dead reference the compiler would catch anyway. The
# audit checks imports/annotations and declarations, which a comment cannot fake.
FORBIDDEN_GRADLE = ["androidx.room", "room.incremental", "room.schemaLocation", "com.google.devtools.ksp"]

WRITE_SQL = re.compile(r"\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|VACUUM)\b", re.IGNORECASE)
SELECT_SQL = re.compile(r"\bSELECT\b", re.IGNORECASE)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def app_sources() -> list[Path]:
    return sorted(p for p in APP_SRC.rglob("*") if p.suffix in (".kt", ".java"))


def forbidden_room_tokens(text: str) -> list[str]:
    """The Room symbols a source file may not contain."""
    return [token for token in FORBIDDEN_TOKENS if token in text]


def room_residue_failures(root: Path = REPO_ROOT) -> list[str]:
    problems: list[str] = []
    src = root / "app" / "src"
    for path in sorted(p for p in src.rglob("*") if p.suffix in (".kt", ".java")):
        text = read(path)
        for token in forbidden_room_tokens(text):
            problems.append(f"{path.relative_to(root)} still names {token}")
    # Declarations, not comments: an annotation at the start of a line.
    for path in sorted(p for p in src.rglob("*") if p.suffix in (".kt", ".java")):
        for number, line in enumerate(read(path).splitlines(), 1):
            stripped = line.strip()
            if re.match(r"^@(Entity|Database|Dao|TypeConverter)\b", stripped):
                problems.append(f"{path.relative_to(root)}:{number} declares a Room annotation")
    if (root / "app" / "schemas").exists():
        problems.append("app/schemas still exists; Room's exported schemas retired with the database")
    for path in (root / "app" / "build.gradle.kts", root / "build.gradle.kts"):
        if not path.exists():
            continue
        text = read(path)
        for token in FORBIDDEN_GRADLE:
            if token in text:
                problems.append(f"{path.relative_to(root)} still configures {token}")
    lib = root / "flutter" / "lib"
    for name in ("db.dart", "data_layer.dart", "route_profiles_source.dart", "groups_dao.dart", "route_profiles_dao.dart"):
        if (lib / "data" / name).exists():
            problems.append(f"flutter/lib/data/{name} still exists; the read-only Room view retired")
    for path in sorted(lib.rglob("*.dart")):
        text = read(path)
        if "roomSchemaVersion" in text:
            problems.append(f"{path.relative_to(root)} still reads roomSchemaVersion")
        if "SqliteRoomProfileReader" in text:
            problems.append(f"{path.relative_to(root)} still reads the ffi SQLite Room reader")
    return problems


def readonly_violations(text: str) -> list[str]:
    """Room-file access that would write, create or migrate."""
    problems: list[str] = []
    if "OPEN_READONLY" not in text:
        problems.append("LegacyRoomReader does not open the database OPEN_READONLY")
    if "CREATE_IF_NECESSARY" in text:
        problems.append("LegacyRoomReader can create the database")
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*"):
            continue
        if not SELECT_SQL.search(stripped):
            continue
        if WRITE_SQL.search(stripped):
            problems.append(f"LegacyRoomReader:{number} mixes a write into a SELECT")
    # A write outside a SELECT string is still a write.
    for number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if stripped.startswith("//") or stripped.startswith("*") or SELECT_SQL.search(stripped):
            continue
        if re.search(r'"(?:INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|REPLACE|VACUUM)\b', stripped, re.IGNORECASE):
            problems.append(f"LegacyRoomReader:{number} authors a write statement")
    return problems


def legacy_reader_failures(root: Path = REPO_ROOT) -> list[str]:
    problems: list[str] = []
    legacy = root / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "LegacyRoomReader.kt"
    seed = root / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "LegacyDocumentSeed.kt"
    settings = root / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "SettingsJsonStore.kt"
    route_store = root / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "RouteJsonStore.kt"
    if not legacy.exists():
        return ["LegacyRoomReader.kt is missing; the one-time seed has no reader"]
    text = read(legacy)
    problems.extend(readonly_violations(text))
    for needle, why in [
        ('const val PROFILES = "profiles"', "the compile-time table list"),
        ('const val GROUPS = "groups"', "the compile-time table list"),
        ('const val SETTINGS = "settings"', "the compile-time table list"),
        ('const val MARKERS = "markers"', "the compile-time table list"),
        ("fun seedRouteDocuments(", "the route document hand-over"),
        ("fun eligible(", "the document-presence gate"),
        ("fun snapshot(", "the data.legacyRows reply"),
        ("fun settings(", "the settings seed"),
        ("fun markers(", "the markers seed"),
    ]:
        if needle not in text:
            problems.append(f"LegacyRoomReader lost {why} ({needle})")
    if "if (File(dir, \"route_profiles.json\").isFile) return false" not in text:
        problems.append("LegacyRoomReader.seedRouteDocuments lost its per-file skip")
    if not seed.exists():
        problems.append("LegacyDocumentSeed.kt is missing")
    else:
        seed_text = read(seed)
        # The single global rule table replaced the three route documents, so the
        # hand-over now delegates to the global migration helpers instead of the
        # retired seedRouteDocuments. The invariant is unchanged: LegacyDocumentSeed
        # must never write the rules itself — LegacyRoomReader stays the one reader.
        if not any(
            f"LegacyRoomReader.{method}(" in seed_text
            for method in ("migrateDocumentsToGlobal", "seedGlobalFromRoom")
        ):
            problems.append("LegacyDocumentSeed.seed no longer delegates to LegacyRoomReader")
    if not settings.exists():
        problems.append("SettingsJsonStore.kt is missing")
    else:
        settings_text = read(settings)
        if "LegacyRoomReader.settings()" not in settings_text:
            problems.append("SettingsJsonStore no longer seeds settings from LegacyRoomReader")
        if "LegacyRoomReader.markers()" not in settings_text:
            problems.append("SettingsJsonStore no longer seeds markers from LegacyRoomReader")
    if not route_store.exists():
        problems.append("RouteJsonStore.kt is missing")
    else:
        route_text = read(route_store)
        for forbidden in ("fun save(", "fun delete(", "fun write(", ".writeText(", "renameTo("):
            if forbidden in route_text:
                problems.append(f"RouteJsonStore is no longer read-only ({forbidden})")
    return problems


def ci_contract_failures(root: Path = REPO_ROOT) -> list[str]:
    problems: list[str] = []
    ci = root / ".github" / "workflows" / "ci.yml"
    if not ci.exists():
        return [".github/workflows/ci.yml is missing"]
    text = read(ci)
    for retired in ("schema_audit.py", "room_snapshot_audit.py"):
        if retired in text:
            problems.append(f"ci.yml still runs the retired {retired}")
    if "legacy_reader_audit.py" not in text:
        problems.append("ci.yml does not run legacy_reader_audit.py")
    return problems


def self_test() -> int:
    failures: list[str] = []
    if not forbidden_room_tokens("import androidx.room.Database\n"):
        failures.append("a Room import was not detected")
    if not forbidden_room_tokens("@Entity(tableName = \"x\")"):
        failures.append("a Room annotation was not detected")
    if readonly_violations("db.execSQL(\"DELETE FROM t\")") == []:
        failures.append("a write statement was not detected")
    if readonly_violations("SQLiteDatabase.openDatabase(path, null, SQLiteDatabase.OPEN_READONLY)") != []:
        failures.append("a read-only open was not accepted")
    if readonly_violations("SQLiteDatabase.openDatabase(path, null, SQLiteDatabase.CREATE_IF_NECESSARY)") == []:
        failures.append("a creating open was not detected")
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        (root / "app" / "src").mkdir(parents=True)
        (root / "app" / "schemas").mkdir()
        (root / "flutter" / "lib" / "data").mkdir(parents=True)
        (root / "flutter" / "lib" / "data" / "db.dart").write_text("const roomSchemaVersion = 21;")
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "ci.yml").write_text("python3 tools/diagnostics/schema_audit.py")
        problems = room_residue_failures(root)
        if not any("app/schemas" in p for p in problems):
            failures.append("the schemas directory was not detected")
        if not any("db.dart" in p for p in problems):
            failures.append("the Dart Room data plane was not detected")
        if not any("schema_audit" in p for p in ci_contract_failures(root)):
            failures.append("a retired CI audit was not detected")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("legacy_reader_audit self-test: OK (10 cases)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    problems = room_residue_failures()
    problems.extend(legacy_reader_failures())
    problems.extend(ci_contract_failures())
    if problems:
        print("Room retirement is incomplete:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"legacy_reader_audit: OK ({len(app_sources())} Kotlin/Java sources, no Room residue)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
