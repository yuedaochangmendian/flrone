#!/usr/bin/env python3
"""Golden-fixture checker for the frozen config.build expectations.

Two suites share one gate, selected with ``--suite main|test`` (default ``main``):

  * ``main`` — a started config. Fixtures live in
    ``app/src/test/resources/config-golden/<case>/`` with
    ``profiles.json`` / ``settings.json`` / ``global_route_rules.json`` /
    ``build.json`` and the frozen ``expected.json``. ``build.json`` may pin
    ``outboundMode`` (rule/global/direct), ``clockUnixSeconds`` (auto-selector
    freshness / warm ages) and ``expectError`` (the build must fail with the
    pinned ``error`` text).
  * ``test`` — the buildTest envelope. Fixtures live in
    ``app/src/test/resources/config-test-golden/<case>/`` and pin
    ``coreConfig`` + SHA-256, the ordered ``outboundTags`` / ``tagToProfileId`` /
    ``fullConfigs`` / ``skipped`` arrays, ``tunIPv4Cidr``,
    ``involvedProfileIds`` and ``error``.

``expected.json`` was produced by the Kotlin oracle before the C7 cutover. That
oracle (``ConfigGeneratorGoldenTest`` / ``ConfigTestGoldenTest``) was deleted
with ConfigGenerator, so the files are frozen: the Go harness
(``config_build_golden_test.go`` / ``config_test_golden_test.go``) is the
byte-for-byte comparison. This script validates the fixture documents, the
envelope and its SHA-256; ``--update`` and ``--run-jvm`` fail with an
explanation.

Usage (from the repository root)::

    python tools/diagnostics/config_golden.py --check
    python tools/diagnostics/config_golden.py --suite test --check
    python tools/diagnostics/config_golden.py --list

Exit code 0 when every fixture validates and every expected output matches; 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
TAG_RE = re.compile(r"^proxy-(\d+)-0$")


@dataclass(frozen=True)
class Suite:
    name: str
    fixtures: Path
    input_files: tuple[str, ...]
    generated_by: str


SUITES: dict[str, Suite] = {
    "main": Suite(
        name="main",
        fixtures=ROOT / "app" / "src" / "test" / "resources" / "config-golden",
        input_files=("profiles.json", "settings.json", "global_route_rules.json", "build.json"),
        generated_by="ConfigGeneratorGoldenTest",
    ),
    "test": Suite(
        name="test",
        fixtures=ROOT / "app" / "src" / "test" / "resources" / "config-test-golden",
        input_files=("profiles.json", "settings.json", "build_test.json"),
        generated_by="ConfigTestGoldenTest",
    ),
}


class FixtureError(Exception):
    pass


def display_path(path: Path) -> str:
    """A path for messages: relative to the repository when inside it, absolute otherwise."""
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise FixtureError(f"{display_path(path)} is missing") from None
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FixtureError(f"{display_path(path)} is not valid JSON: {error}") from None


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
        # settings.json is the SettingsJsonStore format: every stored value is a string.
        # Coercing a number/boolean here would hide a fixture that the app would read
        # differently.
        if not isinstance(row.get("value"), str):
            raise FixtureError(f"{case.name}: settings key {row['key']!r} must carry a string value")
        values[row["key"]] = row["value"]
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
    rule_ids: set[int] = set()
    rule_orders: set[int] = set()
    for index, rule in enumerate(route["rows"]):
        if not isinstance(rule, dict):
            raise FixtureError(f"{case.name}: global_route_rules.json rows[{index}] must be an object")
        rule_id = rule.get("id")
        order = rule.get("rule_order")
        if not isinstance(rule_id, int) or isinstance(rule_id, bool) or rule_id <= 0:
            raise FixtureError(f"{case.name}: rows[{index}].id must be a positive integer")
        if not isinstance(order, int) or isinstance(order, bool) or order < 0:
            raise FixtureError(f"{case.name}: rows[{index}].rule_order must be a non-negative integer")
        if rule_id in rule_ids:
            raise FixtureError(f"{case.name}: duplicate route rule id {rule_id}")
        if order in rule_orders:
            raise FixtureError(f"{case.name}: duplicate route rule_order {order} (the build order would be ambiguous)")
        rule_ids.add(rule_id)
        rule_orders.add(order)

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
    if "outboundMode" in build and build["outboundMode"] not in ("rule", "global", "direct"):
        raise FixtureError(f"{case.name}: build.json outboundMode must be \"rule\", \"global\" or \"direct\"")
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


def check_cases(suite: Suite, cases: list[Path]) -> int:
    """Validate every fixture and its frozen expectation.

    The byte comparison itself runs in the Go harness
    (``config_build_golden_test.go`` / ``config_test_golden_test.go``), which
    reads the same ``expected.json``. This script keeps the fixture contract:
    the expected envelope is well formed, its SHA-256 matches, and an
    ``expectError`` case carries an error. The Kotlin oracle that produced these
    files was deleted with ConfigGenerator, so ``expected.json`` is frozen.
    """
    failed = 0
    for case in cases:
        try:
            validate_case(suite, case)
            expected = load_json(case / "expected.json")
            if suite.name == "test":
                core = validate_test_envelope(
                    case.name, expected, "expected.json", requested_test_ids(case)
                )
            else:
                core = validate_oracle_document(suite, case.name, expected, "expected.json")
        except FixtureError as error:
            print(f"[FAIL] {error}")
            failed += 1
            continue
        print(f"[ OK ] {case.name}: frozen expectation ({len(core.encode('utf-8'))} core bytes)")
    return 1 if failed else 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="validate fixtures and frozen expectations (default)")
    mode.add_argument(
        "--update",
        action="store_true",
        help="no longer available: the Kotlin oracle was deleted, expected.json is frozen",
    )
    parser.add_argument("--suite", choices=sorted(SUITES), default="main",
                        help="fixture family to check: main (started config) or test (buildTest) (default: main)")
    parser.add_argument("--case", action="append", metavar="NAME", help="only this fixture (repeatable)")
    parser.add_argument(
        "--run-jvm",
        action="store_true",
        help="no longer available: the Go harness is the byte comparison",
    )
    parser.add_argument("--actual-dir", type=Path, default=None, help="ignored: kept for old scripts")
    parser.add_argument("--list", action="store_true", help="list fixture case names and exit")
    args = parser.parse_args()

    suite = SUITES[args.suite]
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
        print("[FAIL] expected.json is frozen: the Kotlin oracle (ConfigGeneratorGoldenTest / ConfigTestGoldenTest) was deleted")
        return 1
    if args.run_jvm:
        print("[FAIL] there is no Kotlin oracle to run; the Go harness compares expected.json byte for byte")
        return 1
    return check_cases(suite, cases)


if __name__ == "__main__":
    sys.exit(main())
