#!/usr/bin/env python3
"""Checker for the frozen S5 profile stored-form corpus.

Fixtures live in ``app/src/test/resources/profile-corpus/<case>/`` with three
files: ``input.txt`` (raw oracle input), ``case.json`` (descriptor) and
``expected.json`` (frozen envelope + SHA-256, produced **only** by the Kotlin
``ProfileCorpusTest`` oracle in update mode, never hand-written).

This script is the Gradle-independent half of the gate. The JVM harness
re-derives the payload from the oracle and compares bytes; the Go harness
(``profile_corpus_test.go`` in the patched core tree) reads the same envelope
and validates its SHA now, with the byte comparison left as a TODO until the
Go profile codec lands. This checker validates the descriptor, the envelope,
the SHA-256 and the generator stamp, so a hand-edited expected.json cannot pass
any of the three harnesses. It never regenerates expectations (``--update`` and
``--run-jvm`` are rejected with an explanation).

Usage (from the repository root)::

    python3 tools/diagnostics/profile_corpus.py --check
    python3 tools/diagnostics/profile_corpus.py --list
    python3 tools/diagnostics/profile_corpus.py --self-test

Exit code 0 when every fixture validates; 1 otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import tempfile
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "app" / "src" / "test" / "resources" / "profile-corpus"
GENERATED_BY = "ProfileCorpusTest"
VERSION = 1
MODES = {"import", "export", "validate", "newOutbound", "migrate"}
CONTEXTS = {"default", "android-resources"}
DESCRIPTOR_KEYS = {"mode", "source", "format", "context", "formats", "expectError", "include"}


class FixtureError(Exception):
    pass


def display_path(path: Path) -> str:
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


def fixture_cases(only: list[str] | None) -> list[Path]:
    if not FIXTURES.is_dir():
        raise FixtureError(f"fixture directory not found: {display_path(FIXTURES)}")
    cases = sorted((p for p in FIXTURES.iterdir() if p.is_dir()), key=lambda p: p.name)
    if only:
        wanted = set(only)
        known = {c.name for c in cases}
        missing = sorted(wanted - known)
        if missing:
            raise FixtureError(f"unknown profile-corpus case(s): {', '.join(missing)}")
        cases = [c for c in cases if c.name in wanted]
    if not cases:
        raise FixtureError(f"no profile-corpus cases under {display_path(FIXTURES)}")
    return cases


def validate_descriptor(case: Path) -> dict[str, Any]:
    meta = load_json(case / "case.json")
    if not isinstance(meta, dict):
        raise FixtureError(f"{case.name}: case.json must be an object")
    unknown = sorted(set(meta) - DESCRIPTOR_KEYS)
    if unknown:
        raise FixtureError(f"{case.name}: case.json has unknown key(s): {', '.join(unknown)}")
    missing = sorted(DESCRIPTOR_KEYS - set(meta))
    if missing:
        raise FixtureError(f"{case.name}: case.json missing key(s): {', '.join(missing)}")
    if meta["mode"] not in MODES:
        raise FixtureError(f"{case.name}: case.json mode must be one of {sorted(MODES)}, got {meta['mode']!r}")
    for key in ("source", "format", "context"):
        if not isinstance(meta[key], str):
            raise FixtureError(f"{case.name}: case.json {key} must be a string")
    if meta["context"] not in CONTEXTS:
        raise FixtureError(f"{case.name}: case.json context must be one of {sorted(CONTEXTS)}, got {meta['context']!r}")
    if not isinstance(meta["formats"], list) or not all(isinstance(x, str) for x in meta["formats"]):
        raise FixtureError(f"{case.name}: case.json formats must be an array of strings")
    for key in ("expectError", "include"):
        if not isinstance(meta[key], bool):
            raise FixtureError(f"{case.name}: case.json {key} must be a boolean")
    if not (case / "input.txt").is_file():
        raise FixtureError(f"{case.name}: input.txt is missing")
    return meta


def canonical_json(value: Any) -> str:
    """The payload is frozen as canonical compact JSON; re-serialise to compare its SHA."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def validate_case(case: Path) -> tuple[bool, str]:
    """Return (included, mode). Raises FixtureError on any drift."""
    meta = validate_descriptor(case)
    name = case.name
    expected_file = case / "expected.json"
    if not meta["include"]:
        if expected_file.exists():
            raise FixtureError(f"{name}: include=false but expected.json exists (stale fixture)")
        return False, meta["mode"]
    expected = load_json(expected_file)
    if not isinstance(expected, dict):
        raise FixtureError(f"{name}: expected.json must be an object")
    if expected.get("version") != VERSION:
        raise FixtureError(f"{name}: expected.json version must be {VERSION}")
    if expected.get("generatedBy") != GENERATED_BY:
        raise FixtureError(
            f"{name}: expected.json was not produced by {GENERATED_BY} "
            f"(got {expected.get('generatedBy')!r}) -- hand-written or stale"
        )
    if "payload" not in expected:
        raise FixtureError(f"{name}: expected.json has no payload")
    payload_text = canonical_json(expected["payload"])
    digest = sha256_text(payload_text)
    if expected.get("sha256") != digest:
        raise FixtureError(
            f"{name}: expected.json sha256 does not match its payload "
            f"(expected {digest}, got {expected.get('sha256')!r}) -- edited by hand?"
        )
    body = expected_file.read_bytes().decode("utf-8")
    if b"\r\n" in expected_file.read_bytes():
        raise FixtureError(f"{name}: expected.json must use LF line endings")
    if meta["expectError"] and "error" not in expected["payload"]:
        raise FixtureError(f"{name}: expectError=true but the payload pins no error")
    if not meta["expectError"] and "error" in expected["payload"]:
        raise FixtureError(f"{name}: payload pins an error but expectError is false")
    return True, meta["mode"]


def check(only: list[str] | None) -> int:
    failures: list[str] = []
    included = 0
    excluded = 0
    modes: dict[str, int] = {}
    for case in fixture_cases(only):
        try:
            is_included, mode = validate_case(case)
            if is_included:
                included += 1
                modes[mode] = modes.get(mode, 0) + 1
            else:
                excluded += 1
        except FixtureError as error:
            failures.append(str(error))
    for failure in failures:
        print(f"::error::{failure}")
    print(
        f"profile_corpus: {included} included, {excluded} excluded, "
        f"{len(failures)} failure(s); modes={dict(sorted(modes.items()))}"
    )
    return 1 if failures else 0


def list_cases() -> int:
    for case in fixture_cases(None):
        try:
            meta = validate_descriptor(case)
            state = "included" if meta["include"] else "excluded"
            print(f"{case.name}\t{meta['mode']}\t{state}\t{meta['source']}")
        except FixtureError as error:
            print(f"{case.name}\tERROR\t{error}")
            return 1
    return 0


def self_test() -> int:
    """Exercise every detector against synthetic in-memory cases (no fixture dependency)."""
    checks = 0

    def expect_error(label: str, fn, fragment: str):
        nonlocal checks
        checks += 1
        try:
            fn()
        except FixtureError as error:
            if fragment not in str(error):
                print(f"::error::self-test {label}: wrong message: {error}")
                return False
            return True
        print(f"::error::self-test {label}: expected FixtureError, got none")
        return False

    ok = True

    # SHA / envelope validation with a synthetic case.
    with tempfile.TemporaryDirectory() as tmp:
        case = Path(tmp) / "case"
        case.mkdir()
        payload = {"json": '{"type":"direct"}', "type": "direct"}
        body = (
            '{\n'
            '  "version": 1,\n'
            f'  "generatedBy": "{GENERATED_BY}",\n'
            f'  "sha256": "{sha256_text(canonical_json(payload))}",\n'
            f'  "payload": {json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))}\n'
            '}\n'
        )
        (case / "case.json").write_text(json.dumps({
            "mode": "export", "source": "test", "format": "stored", "context": "default",
            "formats": ["stored"], "expectError": False, "include": True,
        }), encoding="utf-8")
        (case / "input.txt").write_text('{"type":"direct"}', encoding="utf-8")
        (case / "expected.json").write_bytes(body.encode("utf-8"))
        try:
            included, mode = validate_case(case)
            checks += 1
            if not included or mode != "export":
                print("::error::self-test valid case rejected")
                ok = False
        except FixtureError as error:
            print(f"::error::self-test valid case threw: {error}")
            ok = False

        # Wrong generatedBy (stale/hand-written).
        stale = case / "expected.json"
        original = stale.read_text(encoding="utf-8")
        stale.write_bytes(original.replace(GENERATED_BY, "SomeOtherTool").encode("utf-8"))
        ok &= expect_error("stale generatedBy", lambda: validate_case(case), "not produced by")

        # Hand-edited payload (SHA mismatch).
        stale.write_bytes(original.replace('"direct"', '"http"').encode("utf-8"))
        ok &= expect_error("sha mismatch", lambda: validate_case(case), "sha256 does not match")

        # CRLF envelope.
        stale.write_text(original.replace("\n", "\r\n"), encoding="utf-8")
        ok &= expect_error("crlf", lambda: validate_case(case), "LF line endings")

        # excluded with stale expected.json.
        stale.write_bytes(original.encode("utf-8"))
        descriptor = case / "case.json"
        desc = json.loads(descriptor.read_text(encoding="utf-8"))
        desc["include"] = False
        descriptor.write_text(json.dumps(desc), encoding="utf-8")
        ok &= expect_error("excluded stale", lambda: validate_case(case), "include=false but expected.json exists")

    # Descriptor shape checks.
    with tempfile.TemporaryDirectory() as tmp:
        case = Path(tmp) / "case"
        case.mkdir()
        (case / "input.txt").write_text("", encoding="utf-8")
        (case / "case.json").write_text(json.dumps({
            "mode": "bogus", "source": "", "format": "", "context": "default",
            "formats": [], "expectError": False, "include": True,
        }), encoding="utf-8")
        ok &= expect_error("bad mode", lambda: validate_descriptor(case), "mode must be one of")

    print(f"profile_corpus self-test: {'OK' if ok else 'FAILED'} ({checks} checks)")
    return 0 if ok else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--check", action="store_true", help="validate fixtures and frozen expectations (default)")
    action.add_argument("--list", action="store_true", help="list fixture case names and modes")
    action.add_argument("--self-test", action="store_true", help="exercise the detectors against synthetic cases")
    parser.add_argument("--case", action="append", metavar="NAME", help="only this case (repeatable)")
    parser.add_argument("--update", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--run-jvm", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.update or args.run_jvm:
        print(
            "::error::profile_corpus regeneration is owned by ProfileCorpusTest; "
            "run ./gradlew app:testOssDebugUnitTest -PprofileCorpusUpdate=true",
        )
        return 1
    if args.self_test:
        return self_test()
    if args.list:
        return list_cases()
    return check(args.case)


if __name__ == "__main__":
    sys.exit(main())
