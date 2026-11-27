#!/usr/bin/env python3
"""Golden-fixture checker for the Kotlin config.build oracles.

Two suites share one gate, selected with ``--suite main|test`` (default ``main``):

  * ``main`` — the Stage-0 oracle for a started config. Fixtures live in
    ``app/src/test/resources/config-golden/<case>/`` and are shared by three consumers:

      - ``ConfigGeneratorGoldenTest`` (Kotlin, the oracle) builds ``coreConfig`` from
        ``profiles.json`` / ``settings.json`` / ``global_route_rules.json`` / ``build.json``
        and writes ``app/build/config-golden/<case>/actual.json``.
      - this script compares that oracle output with the committed ``expected.json``. A
        mismatch prints the first byte offset, the JSON pointer of the first structural
        difference and both values, so a Go-builder regression is diagnosable without opening
        two huge strings by hand.
      - ``buildScript/core-patch/core/mobile/config_build_golden_test.go`` is the Go side: it
        reads the same fixture directories and compares the Go builder's ``coreConfig`` byte
        for byte. ``build.json`` may also pin ``clockUnixSeconds`` (auto-selector freshness /
        warm ages) and ``expectError`` (the build must fail with the pinned ``error`` text).

  * ``test`` — the Stage-6 buildTest oracle. Fixtures live in
    ``app/src/test/resources/config-test-golden/<case>/`` and hold ``profiles.json`` /
    ``settings.json`` / ``build_test.json`` (``profileIds`` plus an optional ``goStage``) and
    the committed ``expected.json`` produced by ``ConfigTestGoldenTest`` through the production
    seam ``CoreConfigs.buildTest``. The envelope pins the whole result: ``coreConfig`` and its
    SHA-256, the ordered ``outboundTags`` / ``tagToProfileId`` / ``fullConfigs`` / ``skipped``
    arrays, ``tunIPv4Cidr``, ``involvedProfileIds`` and ``error``.

``--update`` is the only way to change an expectation, and it always runs the matching Kotlin
test first: ``expected.json`` is copied from the oracle's ``actual.json``, never computed by
this script.

Usage (from the repository root)::

    python tools/diagnostics/config_golden.py --check
    python tools/diagnostics/config_golden.py --check --run-jvm   # run the Kotlin oracle first
    python tools/diagnostics/config_golden.py --update --case simple-shadowsocks
    python tools/diagnostics/config_golden.py --list
    python tools/diagnostics/config_golden.py --suite test --check --run-jvm
    python tools/diagnostics/config_golden.py --suite test --update --case test-simple-batch

Exit code 0 when every fixture validates and every expected output matches; 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
GRADLEW = ROOT / ("gradlew.bat" if os.name == "nt" else "gradlew")
TAG_RE = re.compile(r"^proxy-(\d+)-0$")


@dataclass(frozen=True)
class Suite:
    name: str
    fixtures: Path
    actual_dir: Path
    test_class: str
    input_files: tuple[str, ...]
    generated_by: str
    output_property: str
    update_property: str


SUITES: dict[str, Suite] = {
    "main": Suite(
        name="main",
        fixtures=ROOT / "app" / "src" / "test" / "resources" / "config-golden",
        actual_dir=ROOT / "app" / "build" / "config-golden",
        test_class="io.nekohasekai.sagernet.outbound.config.ConfigGeneratorGoldenTest",
        input_files=("profiles.json", "settings.json", "global_route_rules.json", "build.json"),
        generated_by="ConfigGeneratorGoldenTest",
        output_property="configGoldenOutputDir",
        update_property="configGoldenUpdate",
    ),
    "test": Suite(
        name="test",
        fixtures=ROOT / "app" / "src" / "test" / "resources" / "config-test-golden",
        actual_dir=ROOT / "app" / "build" / "config-test-golden",
        test_class="io.nekohasekai.sagernet.bg.proto.ConfigTestGoldenTest",
        input_files=("profiles.json", "settings.json", "build_test.json"),
        generated_by="ConfigTestGoldenTest",
        output_property="configTestGoldenOutputDir",
        update_property="configTestGoldenUpdate",
    ),
}


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


def fixture_cases(suite: Suite, only: list[str] | None) -> list[Path]:
    if not suite.fixtures.is_dir():
        raise FixtureError(f"fixture directory not found: {suite.fixtures}")
    cases = sorted((path for path in suite.fixtures.iterdir() if path.is_dir()), key=lambda p: p.name)
    if only:
        wanted = set(only)
        known = {case.name for case in cases}
        missing = sorted(wanted - known)
        if missing:
            raise FixtureError(f"unknown {suite.fixtures.name} case(s): {', '.join(missing)}")
        cases = [case for case in cases if case.name in wanted]
    if not cases:
        raise FixtureError(f"no {suite.fixtures.name} cases under {suite.fixtures}")
    return cases


# --------------------------------------------------------------------------------------------- settings


def validate_settings_document(case: Path) -> dict[str, str]:
    """The settings constraints shared by both suites; returns the key -> value rows."""
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
    return values


# --------------------------------------------------------------------------------------------- main suite


def validate_main_case(case: Path, require_expected: bool = True) -> None:
    """Structural checks that catch a half-written fixture before the JVM test does."""
    for name in SUITES["main"].input_files:
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

    validate_settings_document(case)

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
    if "clockUnixSeconds" in build:
        clock = build["clockUnixSeconds"]
        if not isinstance(clock, int) or isinstance(clock, bool):
            raise FixtureError(f"{case.name}: build.json clockUnixSeconds must be an integer")
    if "expectError" in build and not isinstance(build["expectError"], bool):
        raise FixtureError(f"{case.name}: build.json expectError must be a boolean")
    if "goStage" in build:
        stage = build["goStage"]
        if not isinstance(stage, int) or isinstance(stage, bool) or stage < 0:
            raise FixtureError(f"{case.name}: build.json goStage must be a non-negative integer")
    if "requires" in build:
        requires = build["requires"]
        if not isinstance(requires, list) or not all(isinstance(item, str) for item in requires):
            raise FixtureError(f"{case.name}: build.json requires must be an array of strings")
    has_selector = any(
        isinstance(row, dict) and row.get("type") == "autoselector" for row in profile_rows
    )
    if has_selector and "clockUnixSeconds" not in build:
        raise FixtureError(
            f"{case.name}: an auto-selector fixture must pin build.json clockUnixSeconds "
            "(freshness and warm ages are otherwise wall-clock dependent)"
        )

    if require_expected:
        expected = load_json(case / "expected.json")
        validate_oracle_document(SUITES["main"], case.name, expected, "expected.json")
        expect_error = build.get("expectError", False)
        if expect_error and not expected.get("error"):
            raise FixtureError(f"{case.name}: build.json sets expectError but expected.json pins no error")
        if not expect_error and expected.get("error"):
            raise FixtureError(f"{case.name}: expected.json pins an error but build.json does not set expectError")


def validate_oracle_document(suite: Suite, case_name: str, document: Any, source: str) -> str:
    """Checks the main-suite oracle wrapper and returns its coreConfig string."""
    if not isinstance(document, dict):
        raise FixtureError(f"{case_name}: {source} must be a JSON object")
    if document.get("version") != 1:
        raise FixtureError(f"{case_name}: {source} must carry version 1")
    if document.get("generatedBy") != suite.generated_by:
        raise FixtureError(f"{case_name}: {source} was not produced by {suite.generated_by}")
    core = document.get("coreConfig")
    if not isinstance(core, str):
        raise FixtureError(f"{case_name}: {source} has no coreConfig string")
    error = document.get("error")
    if error is not None and (not isinstance(error, str) or error == ""):
        raise FixtureError(f"{case_name}: {source} error must be null or a non-empty string")
    if core == "" and error is None:
        raise FixtureError(f"{case_name}: {source} has no coreConfig but reports no error")
    digest = document.get("sha256")
    if not isinstance(digest, str) or digest != sha256_text(core):
        raise FixtureError(f"{case_name}: {source} sha256 does not match its coreConfig (hand-edited?)")
    return core


# --------------------------------------------------------------------------------------------- test suite


def _positive_id(value: Any, where: str, case_name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise FixtureError(f"{case_name}: {where} must be a positive integer profile id, not {value!r}")
    return value


def validate_test_case(case: Path, require_expected: bool = True) -> list[int]:
    """Fixture checks for the buildTest suite; returns the requested candidate ids in order."""
    for name in SUITES["test"].input_files:
        if not (case / name).is_file():
            raise FixtureError(f"{case.name}: {name} is missing")

    profiles = load_json(case / "profiles.json")
    if not isinstance(profiles, dict) or profiles.get("version") != 1:
        raise FixtureError(f"{case.name}: profiles.json must be a version-1 document")
    profile_rows = profiles.get("profiles")
    if not isinstance(profile_rows, list):
        raise FixtureError(f"{case.name}: profiles.json needs a profiles array")
    profile_ids: set[int] = set()
    group_ids: dict[int, str] = {}
    for row in profile_rows:
        if not isinstance(row, dict):
            raise FixtureError(f"{case.name}: every profiles row must be an object")
        profile_ids.add(_positive_id(row.get("id"), "profiles[].id", case.name))
    groups = profiles.get("groups", [])
    if not isinstance(groups, list):
        raise FixtureError(f"{case.name}: profiles.json groups must be an array")
    for group in groups:
        if not isinstance(group, dict):
            raise FixtureError(f"{case.name}: every groups row must be an object")
        group_id = _positive_id(group.get("id"), "groups[].id", case.name)
        name = group.get("name")
        group_ids[group_id] = name if isinstance(name, str) else ""
    # CoreConfigs.buildTest names a candidate's group through ProxyGroup.displayName(); the
    # blank-name fallback is an Android resource lookup the plain-JVM oracle cannot answer.
    for row in profile_rows:
        gid = row.get("gid")
        if not isinstance(gid, int) or isinstance(gid, bool) or gid <= 0:
            continue
        if gid not in group_ids:
            raise FixtureError(f"{case.name}: profile {row.get('id')} points at missing group {gid}")
        if not group_ids[gid].strip():
            raise FixtureError(
                f"{case.name}: group {gid} needs a non-blank name "
                "(ProxyGroup.displayName() would need Android resources for a blank one)"
            )
    # The group's landing / front proxy must be a stored profile, or every candidate of that
    # group is skipped with a "deleted" reason instead of the fixture exercising the chain.
    for group in groups:
        for key in ("landing_proxy_id", "front_proxy_id"):
            hop = group.get(key)
            if isinstance(hop, int) and not isinstance(hop, bool) and hop > 0 and hop not in profile_ids:
                raise FixtureError(f"{case.name}: group {group.get('id')} {key} {hop} is not in profiles.json")

    validate_settings_document(case)

    build = load_json(case / "build_test.json")
    if not isinstance(build, dict):
        raise FixtureError(f"{case.name}: build_test.json must be an object")
    ids = build.get("profileIds")
    if not isinstance(ids, list):
        raise FixtureError(f"{case.name}: build_test.json needs a profileIds array")
    profile_ids_requested = [_positive_id(value, f"build_test.json profileIds[{index}]", case.name)
                             for index, value in enumerate(ids)]
    if len(set(profile_ids_requested)) != len(profile_ids_requested):
        raise FixtureError(f"{case.name}: build_test.json profileIds must not repeat an id")
    unknown = sorted(set(profile_ids_requested) - profile_ids)
    if unknown:
        raise FixtureError(f"{case.name}: build_test.json profileIds {unknown} are not in profiles.json")
    if "goStage" in build:
        stage = build["goStage"]
        if not isinstance(stage, int) or isinstance(stage, bool) or stage < 0:
            raise FixtureError(f"{case.name}: build_test.json goStage must be a non-negative integer")

    if require_expected:
        expected = load_json(case / "expected.json")
        validate_test_envelope(case.name, expected, "expected.json", profile_ids_requested)
    return profile_ids_requested


def validate_test_envelope(
    case_name: str, document: Any, source: str, requested_ids: list[int] | None = None
) -> str:
    """Checks the buildTest envelope shape and returns its coreConfig string."""
    if not isinstance(document, dict):
        raise FixtureError(f"{case_name}: {source} must be a JSON object")
    if document.get("version") != 1:
        raise FixtureError(f"{case_name}: {source} must carry version 1")
    if document.get("generatedBy") != SUITES["test"].generated_by:
        raise FixtureError(f"{case_name}: {source} was not produced by {SUITES['test'].generated_by}")
    core = document.get("coreConfig")
    if not isinstance(core, str):
        raise FixtureError(f"{case_name}: {source} has no coreConfig string")
    digest = document.get("sha256")
    if not isinstance(digest, str) or digest != sha256_text(core):
        raise FixtureError(f"{case_name}: {source} sha256 does not match its coreConfig (hand-edited?)")
    error = document.get("error")
    if error is not None and not isinstance(error, str):
        raise FixtureError(f"{case_name}: {source} error must be null or a string")
    if isinstance(error, str) and not error:
        raise FixtureError(f"{case_name}: {source} error must be null or a non-empty string")
    if error is None and core == "":
        raise FixtureError(f"{case_name}: {source} has no coreConfig but reports no error")

    tags = document.get("outboundTags")
    if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
        raise FixtureError(f"{case_name}: {source} outboundTags must be an array of strings")
    if len(set(tags)) != len(tags):
        raise FixtureError(f"{case_name}: {source} outboundTags repeats a tag")

    mappings = document.get("tagToProfileId")
    if not isinstance(mappings, list):
        raise FixtureError(f"{case_name}: {source} tagToProfileId must be an array")
    mapped_tags: list[str] = []
    built_ids: list[int] = []
    for index, entry in enumerate(mappings):
        if not isinstance(entry, dict):
            raise FixtureError(f"{case_name}: {source} tagToProfileId[{index}] must be an object")
        tag = entry.get("tag")
        profile_id = _positive_id(entry.get("profileId"), f"{source} tagToProfileId[{index}].profileId", case_name)
        match = TAG_RE.match(tag) if isinstance(tag, str) else None
        if match is None:
            raise FixtureError(
                f"{case_name}: {source} tagToProfileId[{index}].tag {tag!r} must look like proxy-<profileId>-0"
            )
        if int(match.group(1)) != profile_id:
            raise FixtureError(
                f"{case_name}: {source} tag {tag!r} names profile {match.group(1)}, "
                f"but tagToProfileId maps it to {profile_id}"
            )
        mapped_tags.append(tag)
        built_ids.append(profile_id)
    if mapped_tags != tags:
        raise FixtureError(
            f"{case_name}: {source} tagToProfileId must follow outboundTags order exactly"
        )
    if len(set(built_ids)) != len(built_ids):
        raise FixtureError(f"{case_name}: {source} tagToProfileId repeats a profile id")

    full_configs = document.get("fullConfigs")
    if not isinstance(full_configs, list):
        raise FixtureError(f"{case_name}: {source} fullConfigs must be an array")
    full_ids: list[int] = []
    for index, entry in enumerate(full_configs):
        if not isinstance(entry, dict):
            raise FixtureError(f"{case_name}: {source} fullConfigs[{index}] must be an object")
        profile_id = _positive_id(entry.get("profileId"), f"{source} fullConfigs[{index}].profileId", case_name)
        config = entry.get("config")
        if not isinstance(config, str) or config == "":
            raise FixtureError(f"{case_name}: {source} fullConfigs[{index}].config must be a non-empty string")
        entry_sha = entry.get("sha256")
        if not isinstance(entry_sha, str) or entry_sha != sha256_text(config):
            raise FixtureError(
                f"{case_name}: {source} fullConfigs[{index}].sha256 does not match its config"
            )
        full_ids.append(profile_id)
    if len(set(full_ids)) != len(full_ids):
        raise FixtureError(f"{case_name}: {source} fullConfigs repeats a profile id")

    skipped = document.get("skipped")
    if not isinstance(skipped, list):
        raise FixtureError(f"{case_name}: {source} skipped must be an array")
    skipped_ids: list[int] = []
    for index, entry in enumerate(skipped):
        if not isinstance(entry, dict):
            raise FixtureError(f"{case_name}: {source} skipped[{index}] must be an object")
        profile_id = _positive_id(entry.get("profileId"), f"{source} skipped[{index}].profileId", case_name)
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason:
            raise FixtureError(f"{case_name}: {source} skipped[{index}].reason must be a non-empty string")
        skipped_ids.append(profile_id)
    if len(set(skipped_ids)) != len(skipped_ids):
        raise FixtureError(f"{case_name}: {source} skipped repeats a profile id")

    buckets = {
        "outboundTags": set(built_ids),
        "fullConfigs": set(full_ids),
        "skipped": set(skipped_ids),
    }
    names = sorted(buckets)
    for left_index, left in enumerate(names):
        for right in names[left_index + 1:]:
            overlap = buckets[left] & buckets[right]
            if overlap:
                raise FixtureError(
                    f"{case_name}: {source} profile ids {sorted(overlap)} appear in both {left} and {right}"
                )
    if requested_ids is not None:
        requested = set(requested_ids)
        accounted = set().union(*buckets.values())
        unexpected = sorted(accounted - requested)
        if unexpected:
            raise FixtureError(f"{case_name}: {source} accounts for profile ids not in build_test.json: {unexpected}")
        if error is None:
            missing = sorted(requested - accounted)
            if missing:
                raise FixtureError(
                    f"{case_name}: {source} reports no error but does not account for profile ids {missing}"
                )

    tun = document.get("tunIPv4Cidr")
    if tun is not None and (not isinstance(tun, str) or "/" not in tun):
        raise FixtureError(f"{case_name}: {source} tunIPv4Cidr must be null or a CIDR string")
    involved = document.get("involvedProfileIds")
    if not isinstance(involved, list):
        raise FixtureError(f"{case_name}: {source} involvedProfileIds must be an array")
    for index, value in enumerate(involved):
        _positive_id(value, f"{source} involvedProfileIds[{index}]", case_name)
    if involved != sorted(set(involved)):
        raise FixtureError(f"{case_name}: {source} involvedProfileIds must be sorted and unique")
    return core


def validate_case(suite: Suite, case: Path, require_expected: bool = True) -> None:
    if suite.name == "test":
        validate_test_case(case, require_expected)
    else:
        validate_main_case(case, require_expected)


def requested_test_ids(case: Path) -> list[int]:
    build = load_json(case / "build_test.json")
    ids = build.get("profileIds") if isinstance(build, dict) else None
    return [value for value in ids if isinstance(value, int) and not isinstance(value, bool)] if isinstance(ids, list) else []


# --------------------------------------------------------------------------------------------- reporting


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


def report_envelope_mismatch(case_name: str, expected: Any, actual: Any) -> None:
    print(f"[FAIL] {case_name}: oracle envelope differs")
    diff = first_json_diff(expected, actual)
    if diff is None:
        print("  JSON pointer: <none: byte-only difference in whitespace/ordering>")
        return
    path, expected_value, actual_value = diff
    print(f"  JSON pointer: {json_pointer(path) or '/'}")
    print(f"  expected: {display(expected_value)}")
    print(f"  actual:   {display(actual_value)}")


# --------------------------------------------------------------------------------------------- runner


def run_jvm(suite: Suite, update: bool, output_dir: Path) -> None:
    if not GRADLEW.is_file():
        raise FixtureError(f"Gradle wrapper not found: {GRADLEW}")
    # The Test task's lifecycle outputs are what make it up-to-date; dropping them (plus the
    # harness output) forces a real oracle run even when only -P flags changed.
    shutil.rmtree(output_dir, ignore_errors=True)
    shutil.rmtree(ROOT / "app" / "build" / "test-results" / "testOssDebugUnitTest", ignore_errors=True)
    args = [
        "app:testOssDebugUnitTest",
        "--tests",
        suite.test_class,
        "--console=plain",
        "--no-build-cache",
        f"-P{suite.output_property}={output_dir.as_posix()}",
    ]
    if update:
        args.append(f"-P{suite.update_property}=true")
    if os.name == "nt":
        command = ["cmd.exe", "/d", "/c", str(GRADLEW)] + args
    else:
        command = [str(GRADLEW)] + args
    print(f"[run] {' '.join(command)}")
    completed = subprocess.run(command, cwd=ROOT)
    if completed.returncode != 0:
        raise FixtureError(f"the Kotlin oracle test failed (exit {completed.returncode})")


def check_cases(suite: Suite, cases: list[Path], actual_dir: Path, run: bool) -> int:
    failed = 0
    for case in cases:
        try:
            validate_case(suite, case)
        except FixtureError as error:
            print(f"[FAIL] {error}")
            failed += 1
    if failed:
        return 1

    if run:
        try:
            run_jvm(suite, False, actual_dir)
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
        if suite.name == "test":
            requested = requested_test_ids(case)
            expected_document = load_json(case / "expected.json")
            actual_document = load_json(actual_file)
            try:
                expected_text = validate_test_envelope(
                    case.name, expected_document, "expected.json", requested
                )
                validate_test_envelope(case.name, actual_document, "actual.json", requested)
            except FixtureError as error:
                print(f"[FAIL] {error}")
                failed += 1
                continue
            if expected_document != actual_document:
                report_envelope_mismatch(case.name, expected_document, actual_document)
                failed += 1
            else:
                print(f"[ OK ] {case.name}: envelope matches ({len(expected_text.encode('utf-8'))} core bytes)")
            continue

        try:
            expected_document = load_json(case / "expected.json")
            actual_document = load_json(actual_file)
            expected_text = validate_oracle_document(
                suite, case.name, expected_document, "expected.json"
            )
            actual_text = validate_oracle_document(
                suite, case.name, actual_document, "actual.json"
            )
        except FixtureError as error:
            print(f"[FAIL] {error}")
            failed += 1
            continue
        expected_error = expected_document.get("error")
        actual_error = actual_document.get("error")
        if expected_text != actual_text or expected_error != actual_error:
            if expected_error != actual_error:
                print(
                    f"[FAIL] {case.name}: error differs\n"
                    f"  expected: {expected_error!r}\n"
                    f"  actual:   {actual_error!r}"
                )
            if expected_text != actual_text:
                report_mismatch(case.name, expected_text, actual_text)
            failed += 1
        else:
            print(f"[ OK ] {case.name}: {len(expected_text.encode('utf-8'))} bytes match")
    return 1 if failed else 0


def update_cases(suite: Suite, cases: list[Path], actual_dir: Path) -> int:
    for case in cases:
        try:
            validate_case(suite, case, require_expected=False)
        except FixtureError as error:
            print(f"[FAIL] {error}")
            return 1
    try:
        run_jvm(suite, True, actual_dir)
    except FixtureError as error:
        print(f"[FAIL] {error}")
        return 1
    for case in cases:
        actual_file = actual_dir / case.name / "actual.json"
        if not actual_file.is_file():
            print(f"[FAIL] {case.name}: the oracle did not write {actual_file.relative_to(ROOT)}")
            return 1
        try:
            if suite.name == "test":
                validate_test_envelope(
                    case.name,
                    load_json(actual_file),
                    "actual.json",
                    requested_test_ids(case),
                )
            else:
                validate_oracle_document(suite, case.name, load_json(actual_file), "actual.json")
        except FixtureError as error:
            print(f"[FAIL] {error}")
            return 1
        shutil.copyfile(actual_file, case / "expected.json")
        print(f"[updated] {case.relative_to(ROOT) / 'expected.json'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="validate fixtures and compare expected with actual (default)")
    mode.add_argument("--update", action="store_true", help="run the Kotlin oracle and overwrite expected.json (explicit only)")
    parser.add_argument("--suite", choices=sorted(SUITES), default="main",
                        help="fixture family to check: main (started config) or test (buildTest) (default: main)")
    parser.add_argument("--case", action="append", metavar="NAME", help="only this fixture (repeatable)")
    parser.add_argument("--run-jvm", action="store_true", help="run the suite's Kotlin oracle before checking")
    parser.add_argument("--actual-dir", type=Path, default=None,
                        help="oracle output directory (default: the suite's build directory)")
    parser.add_argument("--list", action="store_true", help="list fixture case names and exit")
    args = parser.parse_args()

    suite = SUITES[args.suite]
    actual_dir = args.actual_dir if args.actual_dir is not None else suite.actual_dir

    try:
        cases = fixture_cases(suite, args.case)
    except FixtureError as error:
        print(f"[FAIL] {error}")
        return 1
    if args.list:
        for case in cases:
            print(case.name)
        return 0
    if args.update:
        return update_cases(suite, cases, actual_dir)
    return check_cases(suite, cases, actual_dir, args.run_jvm)


if __name__ == "__main__":
    sys.exit(main())