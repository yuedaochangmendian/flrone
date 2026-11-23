#!/usr/bin/env python3
"""Keeps Dart's copy of the schema honest.

`flutter/lib/data/` reads Room's file directly, which means it also depends on
Room's schema without being checked by it. Two failure modes have no symptom:

1. A version skew: bump `@Database(version = …)` in SagerDatabase.kt and leave
   `roomSchemaVersion` in db.dart alone, and every query keeps working — it
   just reads columns by name from a table whose shape moved, returning the
   wrong field instead of failing. `DataDatabase._checkSchema` catches this at
   runtime by refusing to open, but a refusal on a user's phone is a bug
   report; this catches it on push.

2. A column skew: a Room migration renames or drops a column the DAO's SQL
   mentions by name. The version audit above still passes (both sides say 19),
   and at runtime the query throws inside `RouteProfilesSource.list`, which
   catches it and silently falls back to the channel — the whole SQLite path
   is dead and nothing reports it. So this audit also parses the exported
   schema JSON (`app/schemas/…/<version>.json`) and checks every column the
   DAO SQL references against the table it claims to read — not only SELECT,
   but INSERT/REPLACE column lists and UPDATE's SET columns as well.

3. A type skew: a fresh install is created by Room from the entities while an
   upgrade runs the hand-written `CREATE TABLE` migrations. The two can agree
   on column names and disagree on types, making the same version number mean
   two different databases — and nothing notices, because SQLite applies
   affinity when comparing, so every query keeps working. The audit compares
   the migrations' declared types against the schema's exported affinities.

Also checks that the file name matches `Key.DB_PROFILE`, because a rename there
would make Dart open a fresh empty file — which `openAt` creates, since the
write path passes SQLITE_OPEN_CREATE.

The SQL parsing is deliberately small: it resolves `FROM`/`JOIN` tables and
aliases, then checks qualified (`p.name`) and bare (`name`) identifiers. It is
not a SQL engine; if a statement cannot be resolved, that is a failure, not a
skip — a gate that silently passes on confusion is worse than no gate.

Run from the repository root:
    python3 tools/diagnostics/schema_audit.py
    python3 tools/diagnostics/schema_audit.py --self-test

Exit code 0 when the two sides agree, 1 otherwise.
"""

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

DATABASE_KT = ROOT / "app/src/main/java/io/nekohasekai/sagernet/database/SagerDatabase.kt"
CONSTANTS_KT = ROOT / "app/src/main/java/io/nekohasekai/sagernet/Constants.kt"
DB_DART = ROOT / "flutter/lib/data/db.dart"
ROUTE_STORE_GO = ROOT / "buildScript/core-patch/core/mobile/route_store.go"
ROUTE_ACTIONS_GO = ROOT / "buildScript/core-patch/core/mobile/route_actions.go"
MIGRATION_KT = ROOT / "app/src/main/java/io/flrone/bridge/RoomToJsonMigration.kt"
SCHEMAS_ROOT = ROOT / "app/schemas"
DAO_DIR = ROOT / "flutter/lib/data"

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

SQL_KEYWORDS = {
    "SELECT", "FROM", "WHERE", "GROUP", "BY", "ORDER", "LIMIT", "OFFSET",
    "HAVING", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "CROSS", "FULL",
    "NATURAL", "ON", "AS", "AND", "OR", "NOT", "IN", "IS", "NULL", "LIKE",
    "GLOB", "BETWEEN", "CASE", "WHEN", "THEN", "ELSE", "END", "DISTINCT",
    "UNION", "ALL", "EXISTS", "ASC", "DESC", "USING", "SET", "VALUES",
    "INTO", "INSERT", "UPDATE", "DELETE", "COLLATE", "CAST",
}

# Tokens that can follow a table name without being its alias.
CLAUSE_WORDS = SQL_KEYWORDS


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing file: {path.relative_to(ROOT)}")
        raise


def fail(message: str) -> None:
    print(f"::error::{message}")


def annotation_body(source: str) -> str | None:
    """The text inside `@Database(...)`, found by balancing parentheses.

    `@Database\\s*\\((.*?)\\)` stops at the first `)`, which may belong to a
    nested call (`AutoMigration(from = 1, to = 2)`). That would truncate the
    body and could hide `version` entirely. Count the nesting instead.
    """
    match = re.search(r"@Database\s*\(", source)
    if not match:
        return None
    depth = 1
    for index in range(match.end(), len(source)):
        char = source[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return source[match.end():index]
    return None


def load_room_tables(version: int) -> dict[str, dict[str, str]] | None:
    """`{table: {column: affinity}}` from Room's exported schema for [version]."""
    schema_path = None
    if SCHEMAS_ROOT.is_dir():
        for candidate in SCHEMAS_ROOT.glob(f"*/{version}.json"):
            schema_path = candidate
            break
    if schema_path is None:
        return None
    with schema_path.open(encoding="utf-8") as handle:
        document = json.load(handle)
    tables: dict[str, dict[str, str]] = {}
    for entity in document.get("database", {}).get("entities", []):
        name = entity.get("tableName")
        if not name:
            continue
        columns: dict[str, str] = {}
        for field in entity.get("fields", []):
            column = field.get("columnName") or field.get("fieldPath")
            if column:
                columns[column] = str(field.get("affinity") or "").upper()
        tables[name] = columns
    return tables


# SQLite's declared-type spellings collapsed to the five affinities Room exports.
DDL_AFFINITY = {
    "INTEGER": "INTEGER", "INT": "INTEGER", "BIGINT": "INTEGER", "LONG": "INTEGER",
    "TEXT": "TEXT", "VARCHAR": "TEXT", "CHAR": "TEXT", "CLOB": "TEXT",
    "REAL": "REAL", "DOUBLE": "REAL", "FLOAT": "REAL",
    "BLOB": "BLOB",
    "NUMERIC": "NUMERIC", "DECIMAL": "NUMERIC", "BOOLEAN": "NUMERIC",
    "DATE": "NUMERIC", "DATETIME": "NUMERIC",
}

# Parts of a CREATE TABLE body that name no column.
DDL_NON_COLUMNS = {"primary", "foreign", "unique", "constraint", "check"}


def split_ddl(body: str) -> list[str]:
    """Comma-split a CREATE TABLE body at parenthesis depth 0."""
    parts: list[str] = []
    depth = 0
    current: list[str] = []
    for char in body:
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
        if char == "," and depth == 0:
            parts.append("".join(current))
            current = []
            continue
        current.append(char)
    parts.append("".join(current))
    return parts


def migration_ddl(source: str) -> dict[str, dict[str, str]]:
    """`{table: {column: affinity}}` from the hand-written migrations.

    Room generates a fresh install from the entities, while an upgrade runs these
    `CREATE TABLE` statements. A type that differs between the two produces two
    different databases for the same version number, and nothing reports it: every
    query keeps working because SQLite coerces. The last definition of a table wins
    (migrations run in order).
    """
    # Kotlin concatenates adjacent string literals with `" +"` / `"…"`; join them first.
    joined = re.sub(r'"\s*\+\s*"', "", source)
    tables: dict[str, dict[str, str]] = {}
    pattern = re.compile(
        r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`\"]?(\w+)[`\"]?\s*\("
        r"|DROP\s+TABLE\s+(?:IF\s+EXISTS\s+)?[`\"]?(\w+)[`\"]?",
        re.I,
    )
    # Events are applied in source order: a later DROP removes the table a migration
    # created earlier (proxy_entities is created in 9→10 and dropped before 20).
    for match in pattern.finditer(joined):
        if match.group(2):
            tables.pop(match.group(2), None)
            continue
        depth = 1
        end = match.end()
        while end < len(joined) and depth > 0:
            if joined[end] == "(":
                depth += 1
            elif joined[end] == ")":
                depth -= 1
            end += 1
        body = joined[match.end():end - 1]
        columns: dict[str, str] = {}
        for part in split_ddl(body):
            column = re.match(r"\s*[`\"]?(\w+)[`\"]?\s+([A-Za-z]+)", part)
            if not column:
                continue
            name = column.group(1).lower()
            if name in DDL_NON_COLUMNS:
                continue
            affinity = DDL_AFFINITY.get(column.group(2).upper())
            if affinity:
                columns[name] = affinity
        tables[match.group(1)] = columns
    return tables


def dart_string_blocks(source: str) -> list[str]:
    """Every string literal, with adjacent literals merged.

    Dart concatenates adjacent literals (`'SELECT … ' 'FROM …'`), and
    `groups_dao.dart` relies on it, so the extractor must too. Comments are
    skipped first so a quoted word inside one cannot glue two literals
    together.
    """
    blocks: list[str] = []
    parts: list[str] = []
    index = 0
    length = len(source)

    def flush() -> None:
        if parts:
            blocks.append("".join(parts))
            parts.clear()

    while index < length:
        char = source[index]
        if source[index : index + 2] == "//":
            end = source.find("\n", index)
            index = length if end < 0 else end + 1
            continue
        if source[index : index + 2] == "/*":
            end = source.find("*/", index)
            index = length if end < 0 else end + 2
            continue
        if char in "'\"":
            quote = char * 3 if source[index : index + 3] == char * 3 else char
            end = index + len(quote)
            literal: list[str] = []
            while end < length:
                if len(quote) == 1 and source[end] == "\\":
                    literal.append(source[end : end + 2])
                    end += 2
                    continue
                if source[end : end + len(quote)] == quote:
                    break
                literal.append(source[end])
                end += 1
            index = min(end + len(quote), length)
            parts.append("".join(literal))
            # Whitespace then another quote keeps the concatenation going.
            rest = index
            while rest < length and source[rest].isspace():
                rest += 1
            if not (rest < length and source[rest] in "'\""):
                flush()
                index = rest
            else:
                index = rest
            continue
        flush()
        index += 1
    flush()
    return blocks


def tokenize(sql: str) -> list[str]:
    return re.findall(r"[A-Za-z_][A-Za-z0-9_]*|\d+(?:\.\d+)?|'[^']*'|\S", sql)


def table_aliases(tokens: list[str]) -> dict[str, str]:
    """`{table_or_alias: table}` for every FROM/JOIN in the statement."""
    aliases: dict[str, str] = {}
    for index, token in enumerate(tokens):
        if token.upper() not in ("FROM", "JOIN"):
            continue
        if index + 1 >= len(tokens) or not IDENTIFIER.fullmatch(tokens[index + 1]):
            continue
        table = tokens[index + 1]
        aliases[table] = table
        alias = None
        cursor = index + 2
        if cursor < len(tokens) and tokens[cursor].upper() == "AS":
            if cursor + 1 < len(tokens) and IDENTIFIER.fullmatch(tokens[cursor + 1]):
                alias = tokens[cursor + 1]
        elif cursor < len(tokens) and IDENTIFIER.fullmatch(tokens[cursor]):
            if tokens[cursor].upper() not in CLAUSE_WORDS:
                alias = tokens[cursor]
        if alias:
            aliases[alias] = table
    return aliases


def audit_insert(
    tokens: list[str],
    tables: dict[str, dict[str, str]],
    version: int,
    where: str,
    problems: list[str],
) -> int:
    """Column-check the column list of an INSERT/REPLACE; values are not identifiers."""
    try:
        into = next(index for index, token in enumerate(tokens) if token.upper() == "INTO")
    except StopIteration:
        problems.append(f"{where}: INSERT without INTO — cannot resolve its table")
        return 0
    if into + 1 >= len(tokens) or not IDENTIFIER.fullmatch(tokens[into + 1]):
        problems.append(f"{where}: INSERT has no table name")
        return 0
    table = tokens[into + 1]
    if table not in tables:
        problems.append(
            f"{where}: INSERT writes table `{table}`, which schema v{version} does not define"
        )
        return 0
    if into + 2 >= len(tokens) or tokens[into + 2] != "(":
        problems.append(f"{where}: INSERT into `{table}` has no column list — add one so this audit can check it")
        return 0
    checked = 0
    index = into + 3
    while index < len(tokens) and tokens[index] != ")":
        token = tokens[index]
        if IDENTIFIER.fullmatch(token):
            if token in tables[table]:
                checked += 1
            else:
                problems.append(
                    f"{where}: `{table}.{token}` — schema v{version} has no `{token}` column"
                )
        index += 1
    return checked


def audit_statement(
    sql: str,
    tables: dict[str, dict[str, str]],
    version: int,
    where: str,
    problems: list[str],
) -> int:
    """Column-check one statement; returns how many references it verified."""
    # Dart interpolation (`${simpleAddressRuleTypes.join(', ')}`) is values,
    # not structure — replace it so the tokenizer sees a plain literal.
    sql = re.sub(r"\$\{[^}]*\}", " 1 ", sql)
    tokens = tokenize(sql)
    if not tokens:
        return 0
    first = tokens[0].upper()
    if first in ("INSERT", "REPLACE"):
        return audit_insert(tokens, tables, version, where, problems)
    aliases = table_aliases(tokens)
    # `UPDATE t SET …` names its table before SET, where the FROM/JOIN scan cannot see it.
    if first == "UPDATE" and len(tokens) > 1 and IDENTIFIER.fullmatch(tokens[1]):
        aliases[tokens[1]] = tokens[1]
    checked = 0

    for table in sorted(set(aliases.values())):
        if table not in tables:
            problems.append(
                f"{where}: query reads table `{table}`, which schema v{version} "
                f"does not define"
            )

    distinct_tables = sorted(set(aliases.values()))
    single_table = distinct_tables[0] if len(distinct_tables) == 1 else None

    count = len(tokens)
    for index, token in enumerate(tokens):
        if not IDENTIFIER.fullmatch(token):
            continue
        previous = tokens[index - 1] if index > 0 else ""
        following = tokens[index + 1] if index + 1 < count else ""
        if previous == "." or following == ".":
            # Qualified reference: `p.name`. Resolve from the middle token.
            if following == ".":
                qualifier = token
                column = (
                    tokens[index + 2]
                    if index + 2 < count and IDENTIFIER.fullmatch(tokens[index + 2])
                    else "*"
                )
                if column == "*":
                    continue
                table = aliases.get(qualifier)
                if table is None:
                    problems.append(
                        f"{where}: `{qualifier}.{column}` qualifies `{qualifier}`, "
                        f"which is neither a table nor an alias in this statement"
                    )
                elif table in tables and column not in tables[table]:
                    problems.append(
                        f"{where}: `{qualifier}.{column}` — schema v{version} has no "
                        f"`{column}` column in `{table}`"
                    )
                else:
                    checked += 1
            continue
        upper = token.upper()
        if upper in SQL_KEYWORDS:
            continue
        if following == "(":
            continue  # A function call, not a column.
        if previous.upper() == "AS":
            continue  # An output alias, not a column.
        if token in aliases:
            continue  # The table's own name.
        if single_table is not None:
            if token in tables.get(single_table, {}):
                checked += 1
            else:
                problems.append(
                    f"{where}: bare `{token}` — schema v{version} has no such "
                    f"column in `{single_table}`"
                )
        else:
            problems.append(
                f"{where}: bare `{token}` in a multi-table statement is ambiguous; "
                f"qualify it (e.g. `p.{token}`)"
            )
    return checked


STATEMENT_STARTS = ("SELECT", "WITH", "INSERT", "REPLACE", "UPDATE", "DELETE")


def statement_kind(statement: str) -> str | None:
    """The leading SQL keyword, or None when the text is not a statement."""
    match = re.match(r"\s*(\w+)", statement)
    if not match:
        return None
    word = match.group(1).upper()
    return word if word in STATEMENT_STARTS else None


def audit_dao_sql(
    tables: dict[str, dict[str, str]],
    version: int,
    problems: list[str],
) -> int:
    """Column-check every statement in every `*_dao.dart`; returns reference count.

    SELECT, INSERT/REPLACE, UPDATE and DELETE are all column-checked, so the scope is
    the file's SQL rather than one keyword. A statement that starts with none of them
    is not SQL and is skipped; a statement that starts with one of them but uses a
    shape the audit cannot resolve is reported rather than passed.
    """
    checked = 0
    statements = 0
    for dao in sorted(DAO_DIR.glob("*_dao.dart")):
        source = read(dao)
        for block in dart_string_blocks(source):
            for statement in block.split(";"):
                kind = statement_kind(statement)
                if kind is None:
                    continue
                statements += 1
                snippet = " ".join(statement.split())[:60]
                checked += audit_statement(
                    statement,
                    tables,
                    version,
                    f"{dao.relative_to(ROOT)} (`{snippet}…`)",
                    problems,
                )
    if statements == 0:
        problems.append("no DAO SQL found under flutter/lib/data — the audit saw nothing")
    print(f"column audit: {statements} statements, {checked} column references checked")
    return checked


def audit_document_migration(tables: dict[str, set[str]], problems: list[str]) -> None:
    """ADR 0002 phase 2: the Room -> JSON export must cover every table.

    A missed table used to be invisible at compile time and only showed up as a user's
    vanished profiles after an upgrade. The migration lists tables in Kotlin, the store
    lists documents in Dart, and Room's exported schema is the authoritative list.

    Since ADR 0002 phase 3c only the ROUTE tables are kernel-owned; profiles and groups
    stay Kotlin's, and settings/markers left Room entirely in schema 21 (ADR 0006 stage
    C2b: `documents/settings.json` / `markers.json`, outside this schema). This check
    therefore no longer demands a full migration.
    What it does demand: the Kotlin seed and the Dart document list name the SAME tables,
    those tables exist in Room, and every table the Go patch reads or writes is among them
    — a table the kernel opens but the seed never writes would be a silently empty document.
    """
    room_tables = set(tables)
    # Internal Room bookkeeping is not user data.
    room_tables.discard("room_master_table")

    migration = read(MIGRATION_KT)
    block = re.search(r"val tables\s*=\s*listOf\((.*?)\)", migration, re.S)
    if not block:
        problems.append("RoomToJsonMigration.kt has no `val tables = listOf(...)`")
        return
    kotlin_tables = set(re.findall(r'"([a-z_]+)"', block.group(1)))

    # route_store.go declares the two route tables and route_actions.go the global
    # pool. Profiles and groups are not seeded: the kernel reads/writes those Room
    # tables directly over SQLite (room_db.go), so they are not documents here.
    store = read(ROUTE_STORE_GO) + read(ROUTE_ACTIONS_GO)
    blocks = re.findall(r"const \((.*?)^\)", store, re.M | re.S)
    if not blocks:
        problems.append("route_store.go has no document-name const block")
        return
    all_consts = "\n".join(blocks)
    dart_tables = set(re.findall(r'route(?:Profiles|Rules)Doc\s*=\s*"([a-z_]+)"', all_consts))
    dart_tables |= set(re.findall(r'"(global_route_rules)"', store))

    # The two hand-written lists must agree with each other …
    if kotlin_tables != dart_tables:
        for name in sorted(kotlin_tables - dart_tables):
            problems.append(f"route_store.go does not read {name!r}, which the seed writes")
        for name in sorted(dart_tables - kotlin_tables):
            problems.append(f"route_store.go reads {name!r}, which the seed never writes")
    # … and both must be real Room tables.
    for name in sorted((kotlin_tables | dart_tables) - room_tables):
        problems.append(f"the route documents name {name!r}, which Room's schema does not have")
    # The kernel's own table names must be covered by the seed.
    go_tables = {"route_profiles", "route_rules", "global_route_rules"}
    for name in sorted(go_tables - kotlin_tables):
        problems.append(
            f"the Go route store reads {name!r} but the Kotlin seed never writes it"
        )


def audit_migration_types(
    ddl: dict[str, dict[str, str]],
    tables: dict[str, dict[str, str]],
    version: int,
    problems: list[str],
) -> int:
    """Compare the migrations' DDL types with Room's exported affinities.

    A fresh install is created by Room from the entities; an upgrade runs the
    hand-written `CREATE TABLE` statements. If the two disagree about a column's
    type, the same version number means two different databases — and every query
    still works, because SQLite applies affinity to comparisons.
    """
    if not ddl:
        problems.append("SagerDatabase.kt has no CREATE TABLE migrations to check")
        return 0
    checked = 0
    for table, columns in sorted(ddl.items()):
        if table not in tables:
            problems.append(
                f"migration creates table `{table}`, which schema v{version} does not define"
            )
            continue
        for column, affinity in sorted(columns.items()):
            declared = tables[table].get(column)
            if declared is None:
                problems.append(
                    f"migration defines `{table}.{column}` ({affinity}), which schema v{version} "
                    f"does not have"
                )
            elif declared and declared != affinity:
                problems.append(
                    f"type skew: migration declares `{table}.{column}` as {affinity}, "
                    f"schema v{version} says {declared}"
                )
            else:
                checked += 1
    print(f"migration type audit: {len(ddl)} tables, {checked} column types checked")
    return checked


def self_test() -> int:
    """Exercise the statement and type checks against fixtures, not the real tree."""
    tables = {"t": {"id": "INTEGER", "name": "TEXT"}}
    failures: list[str] = []

    def check(label: str, sql: str, expected_checked: int, expect_problem: bool = False) -> None:
        problems: list[str] = []
        checked = audit_statement(sql, tables, 1, label, problems)
        if expect_problem != bool(problems):
            failures.append(f"{label}: problems={problems!r}, checked={checked}")
        elif not expect_problem and checked != expected_checked:
            failures.append(f"{label}: checked {checked}, expected {expected_checked}")

    check("select", "SELECT name FROM t WHERE id = ?", 2)
    check("insert", "INSERT INTO t (id, name) VALUES (?, ?)", 2)
    check("insert unknown column", "INSERT INTO t (id, gone) VALUES (?, ?)", 0, expect_problem=True)
    check("insert without columns", "INSERT INTO t VALUES (?, ?)", 0, expect_problem=True)
    check("update", "UPDATE t SET name = ? WHERE id = ?", 2)
    check("delete", "DELETE FROM t WHERE id = ?", 1)
    check("unknown column", "SELECT gone FROM t", 0, expect_problem=True)

    ddl = migration_ddl(
        'db.execSQL("CREATE TABLE IF NOT EXISTS `t` (`id` INTEGER NOT NULL, " + "`name` TEXT)")'
    )
    problems: list[str] = []
    audit_migration_types(ddl, tables, 1, problems)
    if problems:
        failures.append(f"matching DDL reported a skew: {problems!r}")
    if ddl.get("t") != {"id": "INTEGER", "name": "TEXT"}:
        failures.append(f"DDL parse: {ddl.get('t')!r}")

    problems = []
    audit_migration_types({"t": {"id": "TEXT", "name": "TEXT"}}, tables, 1, problems)
    if not any("type skew" in problem for problem in problems):
        failures.append("a TEXT-vs-INTEGER skew was not reported")

    dropped = migration_ddl(
        'db.execSQL("CREATE TABLE IF NOT EXISTS `gone` (`id` INTEGER)") '
        'db.execSQL("DROP TABLE IF EXISTS `gone`")'
    )
    if "gone" in dropped:
        failures.append("a dropped table stayed in the DDL map")

    if failures:
        for failure in failures:
            print(f"FAIL: {failure}")
        return 1
    print("schema_audit self-test: OK (10 cases)")
    return 0


def main() -> int:
    if "--self-test" in sys.argv[1:]:
        return self_test()
    problems = []

    database_kt = read(DATABASE_KT)
    constants_kt = read(CONSTANTS_KT)
    db_dart = read(DB_DART)

    # The @Database annotation: `version = 19,` inside the annotation's parentheses.
    body = annotation_body(database_kt)
    if body is None:
        problems.append("could not find a balanced @Database(...) in SagerDatabase.kt")
        room_version = None
    else:
        version_match = re.search(r"\bversion\s*=\s*(\d+)", body)
        if not version_match:
            problems.append("could not read `version = N` from @Database")
            room_version = None
        else:
            room_version = int(version_match.group(1))

    dart_match = re.search(r"roomSchemaVersion\s*=\s*(\d+)", db_dart)
    dart_version = int(dart_match.group(1)) if dart_match else None
    if dart_version is None:
        problems.append("could not read `roomSchemaVersion = N` from flutter/lib/data/db.dart")

    if room_version is not None and dart_version is not None and room_version != dart_version:
        problems.append(
            f"schema version skew: SagerDatabase.kt is at {room_version}, "
            f"flutter/lib/data/db.dart says {dart_version}. "
            f"Bump roomSchemaVersion (and update the DAOs for any column that moved)."
        )

    db_name_match = re.search(r'DB_PROFILE\s*=\s*"([^"]+)"', constants_kt)
    kotlin_name = db_name_match.group(1) if db_name_match else None
    if kotlin_name is None:
        problems.append("could not read DB_PROFILE from Constants.kt")

    dart_name_match = re.search(r"databaseFileName\s*=\s*'([^']+)'", db_dart)
    dart_name = dart_name_match.group(1) if dart_name_match else None
    if dart_name is None:
        problems.append("could not read `databaseFileName` from flutter/lib/data/db.dart")

    if kotlin_name and dart_name and kotlin_name != dart_name:
        problems.append(
            f"database name mismatch: Key.DB_PROFILE is {kotlin_name!r}, "
            f"db.dart says {dart_name!r}"
        )

    # Column audit: Room's exported schema against the SQL the DAOs run.
    if room_version is not None and dart_version is not None and room_version == dart_version:
        tables = load_room_tables(room_version)
        if tables is None:
            problems.append(
                f"Room exported no schema JSON for version {room_version} under "
                f"app/schemas — the column audit has nothing to check against"
            )
        else:
            audit_dao_sql(tables, room_version, problems)
            audit_migration_types(migration_ddl(read(DATABASE_KT)), tables, room_version, problems)
            audit_document_migration(tables, problems)

    if problems:
        for problem in problems:
            fail(problem)
        return 1

    print(
        f"schema OK: version {room_version}, file {dart_name!r}, "
        f"Dart and Room agree (version, file name and DAO columns)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
