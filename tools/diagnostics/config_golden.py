#!/usr/bin/env python3
"""Golden-fixture checker for the Kotlin ConfigGenerator oracle (Stage 0 of config.build).

The fixtures live in ``app/src/test/resources/config-golden/<case>/`` and are shared by three
consumers:

  * ``ConfigGeneratorGoldenTest`` (Kotlin, the oracle) builds ``coreConfig`` from
    ``profiles.json`` / ``settings.json`` / ``global_route_rules.json`` / ``build.json`` and
    writes ``app/build/config-golden/<case>/actual.json``.
  * this script compares that oracle output with the committed ``expected.json``. A mismatch
    prints the first byte offset, the JSON pointer of the first structural difference and both
    values, so a Go-builder regression is diagnosable without opening two huge strings by hand.
  * ``buildScript/core-patch/core/mobile/config_build_golden_test.go`` is the Stage-1 Go test
    skeleton: it reads the same fixture directories and is skipped until the Go builder exists.

``--update`` is the only way to change an expectation, and it always runs the Kotlin test first:
``expected.json`` is copied from the oracle's ``actual.json``, never computed by this script.

Usage (from the repository root)::

    python tools/diagnostics/config_golden.py --check
    python tools/diagnostics/config_golden.py --check --run-jvm   # run the Kotlin oracle first
    python tools/diagnostics/config_golden.py --update --case simple-shadowsocks
    python tools/diagnostics/config_golden.py --list

Exit code 0 when every fixture validates and every expected output matches; 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "app" / "src" / "test" / "resources" / "config-golden"
ACTUAL_DIR = ROOT / "app" / "build" / "config-golden"
TEST_CLASS = "io.nekohasekai.sagernet.outbound.config.ConfigGeneratorGoldenTest"
GRADLEW = ROOT / ("gradlew.bat" if os.name == "nt" else "gradlew")
INPUT_FILES = ("profiles.json", "settings.json", "global_route_rules.json", "build.json")
GENERATED_BY = "ConfigGeneratorGoldenTest"


class FixtureError(Exception):
    pass


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise FixtureError(f"{path.relative_to(ROOT)} is missing") from None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FixtureError(f"{path.relative_to(ROOT)} is not valid JSON: {error}") from None


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def fixture_cases(only: list[str] | None) -> list[Path]:
    if not FIXTURES.is_dir():
        raise FixtureError(f"fixture directory not found: {FIXTURES}")
    cases = sorted((path for path in FIXTURES.iterdir() if path.is_dir()), key=lambda p: p.name)
    if only:
        wanted = set(only)
        known = {case.name for case in cases}
        missing = sorted(wanted - known)
        if missing:
            raise FixtureError(f"unknown config-golden case(s): {', '.join(missing)}")
        cases = [case for case in cases if case.name in wanted]
    if not cases:
        raise FixtureError(f"no config-golden cases under {FIXTURES}")
    return cases


def validate_case(case: Path, require_expected: bool = True) -> None:
    """Structural checks that catch a half-written fixture before the JVM test does."""
    for name in INPUT_FILES:
        if not (case / name).is_file():
            raise FixtureError(f"{case.name}: {name} is missing")

    profiles = load_json(case / "profiles.json")
    if not isinstance(profiles, dict) or profiles.get("version") != 1:
        raise FixtureError(f"{case.name}: profiles.json must be a version-1 document")
    profile_rows = profiles.get("profiles")
    if not isinstance(profile_rows, list) or not profile_rows:
        raise FixtureError(f"{case.name}: profiles.json needs a non-empty profiles array")
    profile_ids = {
        row.get("id") for row in profile_rows if isinstance(row, dict) and isinstance(row.get("id"), int)
    }

    settings = load_json(case / "settings.json")
    if not isinstance(settings, dict) or settings.get("version") != 1 or settings.get("name") != "settings":
        raise FixtureError(f"{case.name}: settings.json must be a version-1 settings document")
    rows = settings.get("rows")
    if not isinstance(rows, list):
        raise FixtureError(f"{case.name}: settings.json needs a rows array")
    keys: set[str] = set()
    values: dict[str, str] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("key"), str):
            raise FixtureError(f"{case.name}: every settings row needs a string key")
        if row["key"] in keys:
            raise FixtureError(f"{case.name}: duplicate settings key {row['key']!r}")
        keys.add(row["key"])
        values[row["key"]] = str(row.get("value", ""))
    # The Kotlin oracle runs SettingsMapper on a plain JVM. Without this row, DataStore asks
    # Binder.getCallingUserHandle() for the per-user port offset, which is not mocked there.
    if "inbound_socks_port" not in keys:
        raise FixtureError(
            f"{case.name}: settings.json must spell out inbound_socks_port "
            "(the JVM oracle cannot derive DataStore's per-user default)"
        )
    # SettingsMapper generates a random core_box_api_secret when this row is missing or blank;
    # a golden fixture must pin it or every oracle run produces a different config.
    if not values.get("core_box_api_secret"):
        raise FixtureError(f"{case.name}: settings.json must set a non-empty core_box_api_secret")
    try:
        clash_port = int(values.get("core_box_clash_api", "0").strip())
    except ValueError:
        raise FixtureError(f"{case.name}: core_box_clash_api must be an integer") from None
    if clash_port > 0 and not values.get("core_box_clash_api_secret"):
        raise FixtureError(
            f"{case.name}: core_box_clash_api is enabled, so core_box_clash_api_secret must be non-empty"
        )
    # ConfigGenerator.validDuration("") builds its error text from Android resources, which the
    # plain-JVM oracle has no Context for: fixtures must use a valid non-empty duration.
    if not values.get("dns_query_timeout"):
        raise FixtureError(f"{case.name}: settings.json must set a non-empty dns_query_timeout (e.g. \"5s\")")
    if values.get("dns_optimistic") == "true" and not values.get("dns_optimistic_timeout"):
        raise FixtureError(f"{case.name}: dns_optimistic requires a non-empty dns_optimistic_timeout")

    route = load_json(case / "global_route_rules.json")
    if not isinstance(route, dict) or route.get("version") != 1 or not isinstance(route.get("rows"), list):
        raise FixtureError(f"{case.name}: global_route_rules.json must be a version-1 document with rows")

    build = load_json(case / "build.json")
    if not isinstance(build, dict):
        raise FixtureError(f"{case.name}: build.json must be an object")
    selected = build.get("selectedProfileId")
    if not isinstance(selected, int) or selected <= 0:
        raise FixtureError(f"{case.name}: build.json needs a positive selectedProfileId")
    if profile_ids and selected not in profile_ids:
        raise FixtureError(f"{case.name}: selectedProfileId {selected} is not in profiles.json")
    if "mode" in build and build["mode"] not in ("vpn", "proxy"):
        raise FixtureError(f"{case.name}: build.json mode must be \"vpn\" or \"proxy\"")
    if "deferRuleSets" in build and not isinstance(build["deferRuleSets"], bool):
        raise FixtureError(f"{case.name}: build.json deferRuleSets must be a boolean")

    if require_expected:
        expected = load_json(case / "expected.json")
        validate_oracle_document(case.name, expected, "expected.json")


def validate_oracle_document(case_name: str, document: Any, source: str) -> str:
    """Checks the oracle wrapper and returns its coreConfig string."""
    if not isinstance(document, dict):
        raise FixtureError(f"{case_name}: {source} must be a JSON object")
    if document.get("version") != 1:
        raise FixtureError(f"{case_name}: {source} must carry version 1")
    if document.get("generatedBy") != GENERATED_BY:
        raise FixtureError(f"{case_name}: {source} was not produced by {GENERATED_BY}")
    core = document.get("coreConfig")
    if not isinstance(core, str) or core == "":
        raise FixtureError(f"{case_name}: {source} has no coreConfig string")
    digest = document.get("sha256")
    if not isinstance(digest, str) or digest != sha256_text(core):
        raise FixtureError(f"{case_name}: {source} sha256 does not match its coreConfig (hand-edited?)")
    return core


def json_pointer(path: list[Any]) -> str:
    return "".join("/" + str(part).replace("~", "~0").replace("/", "~1") for part in path)


def first_json_diff(expected: Any, actual: Any, path: list[Any] | None = None) -> tuple[list[Any], Any, Any] | None:
    """The first structural difference in document order, as (path, expected, actual)."""
    path = [] if path is None else path
    if type(expected) is not type(actual) and not (
        isinstance(expected, (int, float)) and isinstance(actual, (int, float))
    ):
        return path, expected, actual
    if isinstance(expected, dict):
        expected_keys = sorted(expected)
        actual_keys = sorted(actual)
        for key in expected_keys:
            if key not in actual:
                return path + [key], expected[key], _MISSING
            diff = first_json_diff(expected[key], actual[key], path + [key])
            if diff is not None:
                return diff
        for key in actual_keys:
            if key not in expected:
                return path + [key], _MISSING, actual[key]
        return None
    if isinstance(expected, list):
        for index in range(min(len(expected), len(actual))):
            diff = first_json_diff(expected[index], actual[index], path + [index])
            if diff is not None:
                return diff
        if len(expected) != len(actual):
            return path + [min(len(expected), len(actual))], _MISSING, _MISSING
        return None
    if expected != actual:
        return path, expected, actual
    return None


class _Missing:
    def __repr__(self) -> str:
        return "<missing>"


_MISSING = _Missing()


def display(value: Any) -> str:
    if value is _MISSING:
        return "<missing>"
    text = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return text if len(text) <= 240 else text[:237] + "..."


def first_byte_offset(expected: str, actual: str) -> tuple[int, int, int]:
    left = expected.encode("utf-8")
    right = actual.encode("utf-8")
    limit = min(len(left), len(right))
    offset = 0
    while offset < limit and left[offset] == right[offset]:
        offset += 1
    return offset, len(left), len(right)


def report_mismatch(case_name: str, expected: str, actual: str) -> None:
    offset, expected_bytes, actual_bytes = first_byte_offset(expected, actual)
    print(f"[FAIL] {case_name}: coreConfig differs")
    print(f"  first byte offset: {offset} (expected {expected_bytes} bytes, actual {actual_bytes} bytes)")
    try:
        expected_object = json.loads(expected)
        actual_object = json.loads(actual)
    except json.JSONDecodeError as error:
        print(f"  JSON pointer: <unavailable: {error}>")
    else:
        diff = first_json_diff(expected_object, actual_object)
        if diff is None:
            print("  JSON pointer: <none: byte-only difference (key order/formatting)>")
        else:
            path, expected_value, actual_value = diff
            print(f"  JSON pointer: {json_pointer(path) or '/'}")
            print(f"  expected: {display(expected_value)}")
            print(f"  actual:   {display(actual_value)}")
    print(f"  expected sha256: {sha256_text(expected)}")
    print(f"  actual sha256:   {sha256_text(actual)}")


def run_jvm(update: bool, output_dir: Path) -> None:
    if not GRADLEW.is_file():
        raise FixtureError(f"Gradle wrapper not found: {GRADLEW}")
    # The Test task's lifecycle outputs are what make it up-to-date; dropping them (plus the
    # harness output) forces a real oracle run even when only -P flags changed.
    shutil.rmtree(output_dir, ignore_errors=True)
    shutil.rmtree(ROOT / "app" / "build" / "test-results" / "testOssDebugUnitTest", ignore_errors=True)
    args = [
        "app:testOssDebugUnitTest",
        "--tests",
        TEST_CLASS,
        "--console=plain",
        "--no-build-cache",
        f"-PconfigGoldenOutputDir={output_dir.as_posix()}",
    ]
    if update:
        args.append("-PconfigGoldenUpdate=true")
    if os.name == "nt":
        command = ["cmd.exe", "/d", "/c", str(GRADLEW)] + args
    else:
        command = [str(GRADLEW)] + args
    print(f"[run] {' '.join(command)}")
    completed = subprocess.run(command, cwd=ROOT)
    if completed.returncode != 0:
        raise FixtureError(f"the Kotlin oracle test failed (exit {completed.returncode})")


def check_cases(cases: list[Path], actual_dir: Path, run: bool) -> int:
    failed = 0
    for case in cases:
        try:
            validate_case(case)
        except FixtureError as error:
            print(f"[FAIL] {error}")
            failed += 1
    if failed:
        return 1

    if run:
        try:
            run_jvm(False, actual_dir)
        except FixtureError as error:
            print(f"[FAIL] {error}")
            return 1

    for case in cases:
        actual_file = actual_dir / case.name / "actual.json"
        if not actual_file.is_file():
            print(
                f"[FAIL] {case.name}: {actual_file.relative_to(ROOT)} is missing; "
                "run with --run-jvm or run ./gradlew app:testOssDebugUnitTest first"
            )
            failed += 1
            continue
        try:
            expected_text = validate_oracle_document(
                case.name, load_json(case / "expected.json"), "expected.json"
            )
            actual_text = validate_oracle_document(
                case.name, load_json(actual_file), "actual.json"
            )
        except FixtureError as error:
            print(f"[FAIL] {error}")
            failed += 1
            continue
        if expected_text != actual_text:
            report_mismatch(case.name, expected_text, actual_text)
            failed += 1
        else:
            print(f"[ OK ] {case.name}: {len(expected_text.encode('utf-8'))} bytes match")
    return 1 if failed else 0


def update_cases(cases: list[Path], actual_dir: Path) -> int:
    for case in cases:
        validate_case(case, require_expected=False)
    try:
        run_jvm(True, actual_dir)
    except FixtureError as error:
        print(f"[FAIL] {error}")
        return 1
    for case in cases:
        actual_file = actual_dir / case.name / "actual.json"
        if not actual_file.is_file():
            print(f"[FAIL] {case.name}: the oracle did not write {actual_file.relative_to(ROOT)}")
            return 1
        validate_oracle_document(case.name, load_json(actual_file), "actual.json")
        shutil.copyfile(actual_file, case / "expected.json")
        print(f"[updated] {case.relative_to(ROOT) / 'expected.json'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="validate fixtures and compare expected with actual (default)")
    mode.add_argument("--update", action="store_true", help="run the Kotlin oracle and overwrite expected.json (explicit only)")
    parser.add_argument("--case", action="append", metavar="NAME", help="only this fixture (repeatable)")
    parser.add_argument("--run-jvm", action="store_true", help="run ConfigGeneratorGoldenTest before checking")
    parser.add_argument("--actual-dir", type=Path, default=ACTUAL_DIR, help=f"oracle output directory (default: {ACTUAL_DIR})")
    parser.add_argument("--list", action="store_true", help="list fixture case names and exit")
    args = parser.parse_args()

    try:
        cases = fixture_cases(args.case)
    except FixtureError as error:
        print(f"[FAIL] {error}")
        return 1
    if args.list:
        for case in cases:
            print(case.name)
        return 0
    if args.update:
        return update_cases(cases, args.actual_dir)
    return check_cases(cases, args.actual_dir, args.run_jvm)


if __name__ == "__main__":
    sys.exit(main())
