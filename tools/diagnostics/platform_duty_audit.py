"""The `profiles.platform` duty contract (ADR 0005 final stage).

The profile editor's Kotlin-only work — parsing, validation, the subscription
queue, the selection settings, the auto-selector runtime — crosses the bridge as
ONE channel method, `profiles.platform` with `{op, payload}`. That keeps the
channel surface small, but it also hides the op names and their payload keys from
the method-level channel audit: a renamed op or key would surface only as a
runtime error, and an op nobody calls would linger as dead surface.

This script closes that gap by checking the two tables against each other:

  * every literal op the Dart side invokes (`configurationPlatform('…', …)` /
    `_configurationDutyAct('…', …)`) has a `"…" to { … }` entry in
    `FlroneProfileDuty.kt`'s handler table;
  * every Kotlin entry has at least one Dart caller — an op only the Kotlin
    side calls internally belongs in FlroneProfiles, not on the bridge;
  * **the split is explicit**: the five document-only ops that moved into
    Dart's `ProfileDocumentService` (`stats`, `reorder`, `clearTestResults`,
    `nodeList`, `nodeReorder`) are listed in DART_DOCUMENT_OPS. None of them may
    reappear in the Kotlin table or cross `profiles.platform` again — a leftover
    handler or call would be a second reader/writer of the same document, not a
    harmless duplicate. Partial ownership of these ops is thereby a gate, not an
    omission;
  * **the payload keys agree**: for every call whose payload is a map literal,
    the keys Dart sends are exactly the keys the Kotlin handler reads
    (`payload.requireLong("id")`, `payload["revision"]`, …). A key rename on
    either side therefore fails even though the op name still matches.
    Calls that hand the whole form document over (`profileSave`, `profileNodeCreate`)
    are listed in OPAQUE_PAYLOADS with their reason; a new opaque call must be
    declared there rather than silently skipping the check.

Run from the repository root:
    python3 tools/diagnostics/platform_duty_audit.py [--self-test]
Exit code 0 when both directions agree, 1 otherwise.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DUTY = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "FlroneProfileDuty.kt"
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"

# The Dart entry points of the boundary. Only calls whose first argument is
# a string literal are auditable; the definitions take an identifier and
# never match the op pattern.
DART_CALL = re.compile(r"(?:configurationPlatform|_configurationDutyAct|_nodeWrite)\s*\(")
# One handler-table entry: `"op" to { payload -> … },` inside linkedMapOf(…).
# Ops may be dotted (`sort.reposition`): the name is a contract string, not an
# identifier.
KOTLIN_OP = re.compile(r'^\s*"([a-zA-Z][a-zA-Z0-9_.]*)"\s+to\s+\{', re.M)
# Keys a handler reads off its payload. `valueMap` falls back to the whole
# payload at runtime, but the documented key is still the one it names.
KOTLIN_KEY = re.compile(
    r'payload\.(?:requireLong|longOrNull|string|int|longList|valueMap)\(\s*"([a-zA-Z][a-zA-Z0-9_]*)"'
    r'|payload\[\s*"([a-zA-Z][a-zA-Z0-9_]*)"\s*\]'
)

# Ops whose payload is a whole form document, so its keys are not statically
# visible at the call site (the value is a variable). They are checked only for
# the op name; their schema lives in FlroneProfiles.save/commitNode.
OPAQUE_PAYLOADS: dict[str, str] = {
    "save": "FlroneProfiles.save(value) — the profile/group form document",
    "nodeCreate": "FlroneProfiles.commitNode(value) — the typed node form document",
}

# Ops that are Dart-owned now (`ProfileDocumentService`, ADR 0005 final stage
# follow-up). They read/write profiles.json through the ConfigurationStore, so
# they must NOT be on the platform boundary any more: a Kotlin handler would be
# a second reader/writer of the same document, and a `profiles.platform` call
# would route the same operation back across the bridge. `clearTestResults`
# keeps one narrow Kotlin side effect as `sort.reposition` (GroupSort's
# BY_TEST_RESULT/BY_LATENCY reposition), which is a separate op in the table.
DART_DOCUMENT_OPS: frozenset[str] = frozenset({
    "stats",
    "reorder",
    "clearTestResults",
    "nodeList",
    "nodeReorder",
})


def kotlin_table(text: str) -> dict[str, set[str]]:
    """Op -> payload keys its handler reads, from the linkedMapOf table."""
    start = text.find("linkedMapOf(")
    end = text.find("\n    )", start)
    if start < 0 or end < 0:
        raise SystemExit(
            "platform duty audit: cannot bound FlroneProfileDuty's handler table — "
            "adjust kotlin_table() to the new shape"
        )
    block = text[start:end]
    entries = list(KOTLIN_OP.finditer(block))
    table: dict[str, set[str]] = {}
    for index, match in enumerate(entries):
        body = block[match.end():entries[index + 1].start() if index + 1 < len(entries) else len(block)]
        keys: set[str] = set()
        for key in KOTLIN_KEY.finditer(body):
            keys.add(key.group(1) or key.group(2))
        table[match.group(1)] = keys
    return table


def _scan_string(text: str, index: int) -> int:
    """Index just past the string literal opening at [index]."""
    quote = text[index]
    index += 1
    while index < len(text):
        char = text[index]
        if char == "\\":
            index += 2
            continue
        if char == quote:
            return index + 1
        index += 1
    return index


def _matching(text: str, index: int, opener: str = "(", closer: str = ")") -> int:
    """Index of the closer matching the opener at [index], or -1."""
    depth = 0
    while index < len(text):
        char = text[index]
        if char in "'\"":
            index = _scan_string(text, index)
            continue
        if char == opener:
            depth += 1
        elif char == closer:
            depth -= 1
            if depth == 0:
                return index
        index += 1
    return -1


def _split_args(text: str, start: int, end: int) -> list[str]:
    """Top-level comma split of the argument list text[start:end]."""
    args: list[str] = []
    depth = 0
    piece = start
    index = start
    while index < end:
        char = text[index]
        if char in "'\"":
            index = _scan_string(text, index)
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            args.append(text[piece:index])
            piece = index + 1
        index += 1
    tail = text[piece:end]
    if tail.strip():
        args.append(tail)
    return args


def _map_keys(expression: str) -> set[str]:
    """Top-level keys of a Dart map literal (the expression starts with `{`)."""
    keys: set[str] = set()
    depth = 0
    index = 0
    while index < len(expression):
        char = expression[index]
        if char in "'\"":
            if depth == 1:
                end = _scan_string(expression, index)
                key = expression[index + 1:end - 1]
                probe = end
                while probe < len(expression) and expression[probe].isspace():
                    probe += 1
                if probe < len(expression) and expression[probe] == ":":
                    keys.add(key)
                index = end
                continue
            index = _scan_string(expression, index)
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        index += 1
    return keys


def dart_calls(text: str) -> dict[str, set[str] | None]:
    """Literal op -> payload keys; None means the payload is a non-literal.

    Repeats of the same op with different literals merge their keys (an op is
    expected to have one shape; a differing repeat widens the set and will fail
    against Kotlin unless both are real).
    """
    found: dict[str, set[str] | None] = {}
    for match in DART_CALL.finditer(text):
        open_index = match.end() - 1
        close_index = _matching(text, open_index)
        if close_index < 0:
            continue
        args = _split_args(text, open_index + 1, close_index)
        if not args:
            continue
        op_match = re.fullmatch(
            r"""\s*(['"])([a-zA-Z][a-zA-Z0-9_.]*)\1\s*""", args[0]
        )
        if not op_match:
            continue
        op = op_match.group(2)
        expression = args[1].strip() if len(args) > 1 else ""
        if not expression:
            keys: set[str] | None = set()
        elif expression.startswith("{"):
            keys = _map_keys(expression)
        else:
            keys = None
        previous = found.get(op, set())
        if previous is None or keys is None:
            found[op] = None
        else:
            found[op] = previous | keys
    return found


def audit_text(
    duty_text: str,
    dart_texts: dict[str, str],
    dart_ops: frozenset[str] = DART_DOCUMENT_OPS,
) -> tuple[list[str], dict[str, set[str]], dict[str, set[str] | None]]:
    """Pure core: problems, the Kotlin table, and the merged Dart calls."""
    table = kotlin_table(duty_text)
    calls: dict[str, set[str] | None] = {}
    sources: dict[str, list[str]] = {}
    for path, text in dart_texts.items():
        for op, keys in dart_calls(text).items():
            sources.setdefault(op, []).append(path)
            previous = calls.get(op, set())
            if previous is None or keys is None:
                calls[op] = None
            else:
                calls[op] = previous | keys

    problems: list[str] = []
    # Partial ownership, explicitly: an op that moved into Dart's document
    # service must not come back on either side of the platform boundary.
    for op in sorted(dart_ops & set(table)):
        problems.append(
            f"`{op}` is Dart-owned (ProfileDocumentService) but FlroneProfileDuty still handles it — "
            f"delete the handler instead of maintaining two readers/writers"
        )
    for op in sorted(dart_ops & set(calls)):
        problems.append(
            f"`{op}` is Dart-owned (ProfileDocumentService) but still crosses profiles.platform "
            f"({', '.join(sources.get(op, []))}) — call the Dart service directly"
        )
    for op in sorted(set(calls) - set(table)):
        problems.append(f"Dart calls `{op}` but FlroneProfileDuty has no handler ({', '.join(sources.get(op, []))})")
    for op in sorted(set(table) - set(calls)):
        problems.append(f"FlroneProfileDuty handles `{op}` but no Dart caller exists")
    for op, keys in sorted(calls.items()):
        if keys is None:
            if op not in OPAQUE_PAYLOADS:
                problems.append(
                    f"`{op}` passes a non-literal payload; declare it in OPAQUE_PAYLOADS with a reason "
                    f"or send a map literal so its keys can be audited"
                )
            continue
        if op not in table:
            continue
        expected = table[op]
        if keys != expected:
            missing = sorted(expected - keys)
            extra = sorted(keys - expected)
            detail = []
            if missing:
                detail.append(f"Kotlin reads but Dart never sends: {', '.join(missing)}")
            if extra:
                detail.append(f"Dart sends but Kotlin never reads: {', '.join(extra)}")
            problems.append(f"`{op}` payload keys drifted — " + "; ".join(detail))
    for op in sorted(OPAQUE_PAYLOADS):
        if op in calls and calls[op] is not None:
            problems.append(f"`{op}` is listed in OPAQUE_PAYLOADS but now sends a literal map; remove the exception")
    return problems, table, calls


def self_test() -> int:
    duty = '''
    private val handlers: LinkedHashMap<String, Handler> = linkedMapOf(
        "alpha" to { payload -> FlroneProfiles.alpha(payload.requireLong("id"), payload.string("uri")) },
        "beta" to { payload ->
            FlroneProfiles.beta(payload.requireLong("id"), payload.valueMap("value"), payload["revision"] as? String)
        },
        "gamma" to { _ -> FlroneProfiles.gamma() },
        "save" to { payload -> FlroneProfiles.save(payload) },
    )
    '''
    dart = '''
    Future<dynamic> alpha(dynamic id, String uri) =>
        configurationPlatform('alpha', {'id': id, 'uri': uri});
    Future<dynamic> beta(dynamic id, Json value) =>
        configurationPlatform('beta', {'id': id, 'value': value, 'revision': null});
    Future<dynamic> gamma() => configurationPlatform('gamma');
    Future<dynamic> save(Json value) => configurationPlatform('save', value);
    '''
    problems, table, calls = audit_text(duty, {"fixture.dart": dart})
    assert not problems, problems
    assert table["alpha"] == {"id", "uri"}, table
    assert calls["alpha"] == {"id", "uri"}, calls

    drift = dart.replace("'uri': uri", "'link': uri")
    problems, _, _ = audit_text(duty, {"fixture.dart": drift})
    assert any("payload keys drifted" in p and "uri" in p for p in problems), problems

    missing_op = dart.replace("configurationPlatform('gamma')", "configurationPlatform('delta')")
    problems, _, _ = audit_text(duty, {"fixture.dart": missing_op})
    assert any("has no handler" in p for p in problems), problems

    undeclared = dart.replace("configurationPlatform('save', value)", "configurationPlatform('save', someDocument)")
    # 'save' is declared opaque, so a variable payload stays allowed.
    problems, _, _ = audit_text(duty, {"fixture.dart": undeclared})
    assert not any("save" in p for p in problems), problems

    # A double-quoted literal is a real Dart call and must be audited the same
    # way; a single-quote-only parser silently skipped it.
    double_quoted = dart.replace("configurationPlatform('gamma')", 'configurationPlatform("gamma")')
    problems, _, calls = audit_text(duty, {"fixture.dart": double_quoted})
    assert not problems, problems
    assert "gamma" in calls, calls
    missing_delta = dart.replace("configurationPlatform('gamma')", 'configurationPlatform("delta")')
    problems, _, _ = audit_text(duty, {"fixture.dart": missing_delta})
    assert any("has no handler" in p and "delta" in p for p in problems), problems

    # Partial ownership is a gate: an op declared Dart-owned must not have a
    # Kotlin handler and must not cross profiles.platform any more.
    problems, _, _ = audit_text(duty, {"fixture.dart": dart}, frozenset({"gamma"}))
    assert any("Dart-owned" in p and "still handles" in p for p in problems), problems
    assert any("Dart-owned" in p and "still crosses" in p for p in problems), problems

    # A dotted op name (the narrow `sort.reposition` duty) is a real contract
    # string: both parsers must see it, or a whole handler would go unaudited.
    dotted_duty = '''
    private val handlers: LinkedHashMap<String, Handler> = linkedMapOf(
        "delta.op" to { payload -> FlroneProfiles.delta(payload.requireLong("id")) },
    )
    '''
    problems, table, calls = audit_text(
        dotted_duty, {"fixture.dart": "configurationPlatform('delta.op', {'id': 1});"}
    )
    assert not problems, problems
    assert table["delta.op"] == {"id"}, table
    assert calls["delta.op"] == {"id"}, calls

    print("platform duty audit self-test OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()

    dart_texts = {
        path.relative_to(REPO_ROOT).as_posix(): path.read_text(encoding="utf-8")
        for path in sorted(FLUTTER_LIB.rglob("*.dart"))
    }
    problems, table, calls = audit_text(DUTY.read_text(encoding="utf-8"), dart_texts)
    if problems:
        print("platform duty contract FAILED:")
        for problem in problems:
            print(" -", problem)
        return 1
    checked = sum(1 for op, keys in calls.items() if keys is not None)
    print(
        f"platform duty contract OK: {len(table)} ops, {checked} with audited payload keys, "
        f"{len(OPAQUE_PAYLOADS)} opaque, {len(DART_DOCUMENT_OPS)} Dart-owned document ops"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
