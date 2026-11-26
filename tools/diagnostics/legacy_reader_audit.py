#!/usr/bin/env python3
"""Room retirement audit: Room and the one-time legacy seed chain are both gone.

After the legacy-Room-chain removal the app has no Room code, no Room database
on the live path and no one-time migration reader:

  * profiles/groups  -> `documents/profiles.json` (Dart's ConfigurationStore)
  * routes           -> the kernel's `documents/route_*.json` (Go's writer)
  * settings/markers -> `documents/settings.json` / `markers.json`

There is no fallback for pre-document installs: upgrades from installs that
predate `profiles.json` are unsupported, and a missing document is an empty
document — never a reason to open `sager_net.db` again. THRN backup containers
(`FlroneRoomSnapshot` / `backup.container`) are live code: they operate on the
backup's own file, not on a retired Room database, and must not be mistaken for
legacy residue.

This audit replaces `schema_audit.py` and `room_snapshot_audit.py`, both of
which guarded Room's own invariants (schema version, DAO SQL) and retired with
it. It checks, statically:

  1. `room_residue_failures`: no `androidx.room` import/annotation anywhere in
     `app/src`, no `@Entity`/`@Database`/`@Dao`, no `SagerDatabase`, no Room
     Gradle plugin/dependency, no `app/schemas`, no retired Dart data-plane
     files, and no `roomSchemaVersion`/`SqliteRoomProfileReader` in
     `flutter/lib`. The retired Kotlin symbols (`LegacyRoomReader`,
     `data.legacyRows`, `reMigrateFromRoom`, ...) are forbidden in `app/src` too.
     *Dart-side* tokens still present on this branch are only a note: the
     parallel Dart branch removes them; they become failures at merge time.
  2. `legacy_seed_failures`: `LegacyDocumentSeed` only seeds the UI documents
     from SharedPreferences and never writes/migrates a route document.
  3. `settings_store_failures`: `SettingsJsonStore` has no `LegacyRoomReader`
     reference and no `legacySettings`/`legacyMarkers` seams — it writes empty
     documents on first access instead of seeding from a retired database.
  4. `route_store_failures`: `RouteJsonStore` stays read-only (no write method,
     no file writes) — the kernel is the route documents' only writer.
  5. `ci_contract_failures`: ci.yml must run this audit; `schema_audit.py` and
     `room_snapshot_audit.py` must not return.

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
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"
SEED = APP_SRC / "main" / "java" / "io" / "flrone" / "bridge" / "LegacyDocumentSeed.kt"
SETTINGS_STORE = (
    APP_SRC / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "SettingsJsonStore.kt"
)
ROUTE_STORE = (
    APP_SRC / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "RouteJsonStore.kt"
)
CI = REPO_ROOT / ".github" / "workflows" / "ci.yml"
AUDIT_NAME = "legacy_reader_audit.py"

# Tokens that must not appear in app code at all. Room's own transitive
# dependency through WorkManager is a library, not app code: it never appears
# in these sources. The last group names the retired seed chain itself, which
# must not return now that the documents are authoritative.
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
    "LegacyRoomReader",
    "data.legacyRows",
    "reMigrateFromRoom",
    "migrateConfigurationsFromRoom",
    "RoomNodeReader",
    "MapRoomNodeReader",
    "legacyReply",
]
# Historian/comment mentions of the retired names are allowed only in docs; in
# source they would be a dead reference the compiler would catch anyway. The
# audit checks imports/annotations and declarations, which a comment cannot fake.
FORBIDDEN_GRADLE = ["androidx.room", "room.incremental", "room.schemaLocation", "com.google.devtools.ksp"]

# Dart-side tokens owned by the parallel branch. They CANNOT be failures on
# this branch (the Dart tree still calls data.legacyRows / reMigrate etc.), so
# they are reported as notes only. TODO: promote this list into FORBIDDEN_TOKENS
# with a flutter/lib scan when the parallel Dart branch merges.
PENDING_DART_TOKENS = [
    "LegacyRoomReader",
    "data.legacyRows",
    "reMigrateFromRoom",
    "migrateConfigurationsFromRoom",
]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments so a doc note that a format is retired is fine."""
    return re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.DOTALL)


def app_sources(root: Path = REPO_ROOT) -> list[Path]:
    return sorted(p for p in (root / "app" / "src").rglob("*") if p.suffix in (".kt", ".java"))


def forbidden_room_tokens(text: str) -> list[str]:
    """The Room/legacy-chain symbols a source file may not contain."""
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
            problems.append(f"flutter/lib/data/{name} still exists; the read-only Room data plane retired")
    for path in sorted(lib.rglob("*.dart")):
        text = read(path)
        if "roomSchemaVersion" in text:
            problems.append(f"{path.relative_to(root)} still reads roomSchemaVersion")
        if "SqliteRoomProfileReader" in text:
            problems.append(f"{path.relative_to(root)} still reads the ffi SQLite Room reader")
    return problems


def pending_dart_notes(root: Path = REPO_ROOT) -> list[str]:
    """Warn-only: Dart tokens that the parallel branch removes after merge."""
    notes: list[str] = []
    for path in sorted((root / "flutter" / "lib").rglob("*.dart")):
        text = read(path)
        hits = [token for token in PENDING_DART_TOKENS if token in text]
        if hits:
            notes.append(f"{path.relative_to(root)} still names {', '.join(hits)}")
    return notes


def legacy_seed_failures(seed_text: str) -> list[str]:
    """Invariants of LegacyDocumentSeed: UI documents only, never route documents."""
    problems: list[str] = []
    if "fun seedUiDocuments(" not in seed_text:
        problems.append("LegacyDocumentSeed no longer seeds the UI documents")
    if any(token in strip_comments(seed_text) for token in (
        "global_route_rules", "route_profiles", "route_rules",
        "seedRouteDocuments", "migrateDocumentsToGlobal", "seedGlobalFromRoom",
    )):
        problems.append("LegacyDocumentSeed must not write or migrate route documents")
    return problems


def settings_store_failures(text: str) -> list[str]:
    """Inverted contract: no retired reader/seams; ensure() writes empty docs."""
    problems: list[str] = []
    clean = strip_comments(text)
    for forbidden in ("LegacyRoomReader", "legacySettings", "legacyMarkers",
                      "data.legacyRows", "reMigrateFromRoom"):
        if forbidden in clean:
            problems.append(f"SettingsJsonStore still has the retired {forbidden} seam")
    if "fun ensure()" not in clean:
        problems.append("SettingsJsonStore lost ensure() (empty first-access documents)")
    return problems


def seed_chain_failures(root: Path = REPO_ROOT) -> list[str]:
    """Post-removal contract: no legacy reader; UI-doc seed and documents only."""
    problems: list[str] = []
    seed = root / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "LegacyDocumentSeed.kt"
    settings = (
        root / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "SettingsJsonStore.kt"
    )
    if not seed.exists():
        problems.append("LegacyDocumentSeed.kt is missing")
    else:
        problems.extend(legacy_seed_failures(read(seed)))
    if not settings.exists():
        problems.append("SettingsJsonStore.kt is missing")
    else:
        problems.extend(settings_store_failures(read(settings)))
    problems.extend(route_store_failures(root))
    return problems


def route_store_failures_text(text: str) -> list[str]:
    """RouteJsonStore stays read-only — the kernel is the route documents' writer."""
    problems: list[str] = []
    for forbidden in ("fun save(", "fun delete(", "fun write(", ".writeText(", "renameTo("):
        if forbidden in text:
            problems.append(f"RouteJsonStore is no longer read-only ({forbidden})")
    return problems


def route_store_failures(root: Path = REPO_ROOT) -> list[str]:
    path = root / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database" / "RouteJsonStore.kt"
    if not path.exists():
        return ["RouteJsonStore.kt is missing"]
    return route_store_failures_text(read(path))


def ci_contract_failures(root: Path = REPO_ROOT) -> list[str]:
    problems: list[str] = []
    ci = root / ".github" / "workflows" / "ci.yml"
    if not ci.exists():
        return [".github/workflows/ci.yml is missing"]
    text = read(ci)
    for retired in ("schema_audit.py", "room_snapshot_audit.py"):
        if retired in text:
            problems.append(f"ci.yml still runs the retired {retired}")
    if AUDIT_NAME not in text:
        problems.append(f"ci.yml does not run {AUDIT_NAME}")
    return problems


def self_test() -> int:
    failures: list[str] = []
    if not forbidden_room_tokens("import androidx.room.Database\n"):
        failures.append("a Room import was not detected")
    if not forbidden_room_tokens("@Entity(tableName = \"x\")"):
        failures.append("a Room annotation was not detected")
    if not forbidden_room_tokens("class LegacyRoomReader"):
        failures.append("the retired LegacyRoomReader was not detected")
    if not forbidden_room_tokens("call(\"data.legacyRows\")"):
        failures.append("the retired data.legacyRows handler was not detected")
    clean_seed = """object LegacyDocumentSeed {
        fun seedUiDocuments(dir: File, settingsJson: String?, preferencesJson: String?): Boolean {
            File(dir, "ui_settings.json").writeText(settingsJson.orEmpty())
            return true
        }
    }
"""
    if legacy_seed_failures(clean_seed):
        failures.append("a UI-only LegacyDocumentSeed was not accepted")
    for bad in ("File(dir, \"global_route_rules.json\").writeText(rows)",
                "LegacyRoomReader.seedRouteDocuments(dir)",
                "LegacyRoomReader.migrateDocumentsToGlobal(dir)",
                "LegacyRoomReader.seedGlobalFromRoom(dir)"):
        if not any("route" in p for p in legacy_seed_failures(clean_seed + bad)):
            failures.append(f"a route-document write was not detected: {bad}")
    clean_settings = """object SettingsJsonStore {
        fun ensure() { /* writes empty documents */ }
    }
"""
    if settings_store_failures(clean_settings):
        failures.append("a clean SettingsJsonStore was not accepted")
    for bad in ("LegacyRoomReader.settings()", "legacySettings", "legacyMarkers",
                "data.legacyRows", "reMigrateFromRoom"):
        if not settings_store_failures(clean_settings + bad):
            failures.append(f"a legacy settings seam was not detected: {bad}")
    clean_route = """object RouteJsonStore {
        var directory: File? = null
        fun rows(): Map<String, String> = emptyMap()
    }
"""
    if route_store_failures_text(clean_route):
        failures.append("a read-only RouteJsonStore was not accepted")
    for bad in ("fun save(", "fun write(", ".writeText(", "renameTo("):
        if not route_store_failures_text(clean_route + bad):
            failures.append(f"a RouteJsonStore write was not detected: {bad}")
    with tempfile.TemporaryDirectory() as temp:
        root = Path(temp)
        (root / "app" / "src").mkdir(parents=True)
        (root / "app" / "schemas").mkdir()
        (root / "flutter" / "lib" / "data").mkdir(parents=True)
        (root / "flutter" / "lib" / "data" / "db.dart").write_text("const roomSchemaVersion = 21;")
        (root / ".github" / "workflows").mkdir(parents=True)
        (root / ".github" / "workflows" / "ci.yml").write_text(
            f"python3 tools/diagnostics/schema_audit.py\npython3 tools/diagnostics/{AUDIT_NAME}\n")
        problems = room_residue_failures(root)
        if not any("app/schemas" in p for p in problems):
            failures.append("the schemas directory was not detected")
        if not any("db.dart" in p for p in problems):
            failures.append("the Dart Room data plane was not detected")
        ci_problems = ci_contract_failures(root)
        if not any("schema_audit" in p for p in ci_problems):
            failures.append("a retired CI audit was not detected")
        if any(AUDIT_NAME in p for p in ci_problems):
            failures.append("ci_contract_failures rejected a CI file that runs this audit")
        # Seed/settings/route contract on fixture trees: missing files, a legacy
        # reader seam and a writable RouteJsonStore must each fail.
        seed_dir = root / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge"
        settings_dir = root / "app" / "src" / "main" / "java" / "io" / "nekohasekai" / "sagernet" / "database"
        seed_dir.mkdir(parents=True)
        settings_dir.mkdir(parents=True)
        if not any("missing" in p for p in seed_chain_failures(root)):
            failures.append("missing seed/settings/route files were not detected")
        (seed_dir / "LegacyDocumentSeed.kt").write_text(clean_seed)
        (settings_dir / "SettingsJsonStore.kt").write_text(clean_settings)
        (settings_dir / "RouteJsonStore.kt").write_text(clean_route)
        if seed_chain_failures(root):
            failures.append("a clean seed/settings/route fixture was not accepted")
        (settings_dir / "SettingsJsonStore.kt").write_text(
            clean_settings + "val reader = LegacyRoomReader.settings()\n")
        if not settings_store_failures(read(settings_dir / "SettingsJsonStore.kt")):
            failures.append("a legacy reader reference in SettingsJsonStore was not detected")
        (settings_dir / "SettingsJsonStore.kt").write_text(clean_settings)
        (settings_dir / "RouteJsonStore.kt").write_text(clean_route + "fun write(x: String) {}\n")
        if not seed_chain_failures(root):
            failures.append("a writable RouteJsonStore was not detected")
    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print(f"{AUDIT_NAME} self-test: OK (21 cases)")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()
    problems = room_residue_failures()
    problems.extend(seed_chain_failures())
    problems.extend(ci_contract_failures())
    for note in pending_dart_notes():
        print(f"note — Dart still names a retired token (removed by the parallel Dart branch): {note}")
    if problems:
        print("Room retirement is incomplete:")
        for problem in problems:
            print(f"  - {problem}")
        return 1
    print(f"{AUDIT_NAME}: OK ({len(app_sources())} Kotlin/Java sources, "
          "no Room residue, no legacy seed chain)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
