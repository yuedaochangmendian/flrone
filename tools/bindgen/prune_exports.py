#!/usr/bin/env python3
"""Prune the checked-in generated C ABI artifacts down to the live surface.

bindgen.py can emit 427 typed ``throne_*`` exports, but the Dart/Kotlin/Go
callers only use a few dozen (see ADR 0004 P4/P5). Regenerating from the sources
jar is not always possible -- P3 removed the jar from the repository -- so this
script applies a *reproducible* narrowing pass to the generated files that are
checked in:

  * both copies of ``bridge_symbols.h``  -- drop declarations outside the list,
    keep the callback typedef / include guard / runtime prose verbatim;
  * ``bridge_calls.go``                  -- drop ``//export`` blocks outside the
    list, keep the hand-written helpers, drop imports that become unused;
  * ``throne_ffi.dart``                  -- drop ``_lookup`` bindings outside
    the list and whole wrapper classes (or individual methods) that have no
    live symbol, keep the shared helpers, fail on any dangling reference.

``tools/bindgen/live_exports.txt`` is the single source of truth. The pass is
idempotent, has a dry-run mode, and fails loudly (non-zero) rather than
silently mis-cutting a block it does not understand.

Usage (from anywhere)::

    python3 tools/bindgen/prune_exports.py              # apply
    python3 tools/bindgen/prune_exports.py --dry-run    # show what would change
    python3 tools/bindgen/prune_exports.py --check      # dry-run, exit 1 if dirty

The diagnostics gates (``symbol_audit.py`` etc.) then assert the pruned
Go == C == Dart contract against the same whitelist.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

ROOT_DEFAULT = Path(__file__).resolve().parents[2]

DECL_RE = re.compile(r"^\s*[\w ]+?\s*\*?\s*(throne_\w+)\s*\([^;]*\);\s*$")
EXPORT_RE = re.compile(r"^//export (throne_\w+)\s*$")
LOOKUP_RE = re.compile(r"_lookup.*?\('(throne_\w+)'\)")
CLASS_RE = re.compile(r"^class (Throne\w+) \{$")
MEMBER_START_RE = re.compile(
    r"^  (?!  )(?:///"  # doc comment
    r"|(?:final |static |late final )"
    r"|[A-Za-z_][\w<>?, .]*\s+\w+\s*\("
    r"|Throne\w*\s*\("
    r")"
)


class PruneError(RuntimeError):
    """A block could not be classified safely; never write a partial result."""


# --------------------------------------------------------------------------- #
# whitelist
# --------------------------------------------------------------------------- #

def read_whitelist(path: Path) -> set[str]:
    if not path.is_file():
        raise PruneError(f"missing whitelist: {path}")
    syms: list[str] = []
    for line in path.read_text(encoding="utf-8").splitlines():
        code = line.split("#", 1)[0].strip()
        if not code:
            continue
        if not re.fullmatch(r"throne_\w+", code):
            raise PruneError(f"{path}: unparseable whitelist entry: {line!r}")
        syms.append(code)
    if len(syms) != len(set(syms)):
        dupes = sorted({s for s in syms if syms.count(s) > 1})
        raise PruneError(f"{path}: duplicate symbols: {dupes}")
    if not syms:
        raise PruneError(f"{path}: the whitelist is empty")
    return set(syms)


# --------------------------------------------------------------------------- #
# header
# --------------------------------------------------------------------------- #

PRUNED_COUNT_COMMENT = (
    "/* Live typed ABI, pruned from 427 generated exports by "
    "tools/bindgen/prune_exports.py; see live_exports.txt. */"
)


def prune_header(text: str, whitelist: set[str], label: str) -> str:
    out: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        m = DECL_RE.match(line)
        if m:
            sym = m.group(1)
            if sym not in whitelist:
                continue
            seen.add(sym)
            out.append(line)
            continue
        # The generator's stale "340 java->go crossings ..." banner is replaced
        # with a canonical one; matching on the word keeps this idempotent.
        if line.startswith("/*") and "crossings" in line and line.rstrip().endswith("*/"):
            out.append(PRUNED_COUNT_COMMENT)
            continue
        out.append(line)

    missing = sorted(whitelist - seen)
    if missing:
        raise PruneError(f"{label}: whitelisted symbols have no declaration: {missing}")
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------- #
# bridge_calls.go
# --------------------------------------------------------------------------- #

def _export_blocks(lines: list[str], label: str) -> tuple[list[tuple[int, int, str]], set[str]]:
    """Return [(start, end_exclusive, symbol)] for every //export block."""
    blocks: list[tuple[int, int, str]] = []
    i = 0
    while i < len(lines):
        m = EXPORT_RE.match(lines[i])
        if not m:
            i += 1
            continue
        sym = m.group(1)
        j = i + 1
        # A cgo export is a single top-level Go func; its closing brace is the
        # first line that is exactly '}' at column 0.
        while j < len(lines) and lines[j] != "}":
            j += 1
        if j >= len(lines):
            raise PruneError(f"{label}: //export {sym} at line {i + 1} has no closing '}}'")
        # sanity: the func signature must carry the exported name, otherwise
        # //export and func disagree and cgo would fail at build time.
        if not any(re.match(rf"^func {re.escape(sym)}\s*\(", ln) for ln in lines[i + 1:j + 1]):
            raise PruneError(
                f"{label}: //export {sym} at line {i + 1} has no matching func declaration"
            )
        blocks.append((i, j + 1, sym))
        i = j + 1
    return blocks, {b[2] for b in blocks}


def _drop_unused_imports(text: str, label: str) -> str:
    m = re.search(r"^import \(\n(.*?)^\)$", text, re.S | re.M)
    if not m:
        raise PruneError(f"{label}: cannot locate the parenthesized import block")
    block = m.group(0)
    body = text[:m.start()] + text[m.end():]  # search outside the import block
    kept: list[str] = []
    for line in m.group(1).splitlines():
        stripped = line.strip()
        if not stripped:
            kept.append(line)
            continue
        im = re.match(r'^(?:(\w+|\.|_)\s+)?"([^"]+)"$', stripped)
        if not im:
            raise PruneError(f"{label}: unparseable import line: {line!r}")
        alias, path = im.group(1), im.group(2)
        if alias in (".", "_"):
            ident = None  # side-effect import: always keep
        elif alias:
            ident = alias
        else:
            ident = path.rsplit("/", 1)[-1]
        if ident is None or re.search(rf"\b{re.escape(ident)}\.", body):
            kept.append(line)
    return text[:m.start()] + "import (\n" + "\n".join(kept) + "\n)" + text[m.end():]


def prune_go_calls(text: str, whitelist: set[str], runtime_syms: set[str],
                   label: str) -> str:
    lines = text.splitlines()
    blocks, found = _export_blocks(lines, label)
    # Every whitelisted symbol must be implemented exactly once across the two
    # Go files. bridge_runtime.go owns its hand-written exports; bridge_calls.go
    # owns the generated ones. Do not silently drop a live export.
    expected = whitelist - runtime_syms
    missing = sorted(expected - found)
    if missing:
        raise PruneError(f"{label}: whitelisted exports have no Go body: {missing}")
    unexpected = sorted((found & whitelist) & runtime_syms)
    if unexpected:
        raise PruneError(
            f"{label}: symbols owned by bridge_runtime.go also exported here: {unexpected}"
        )

    drop = {s for s in found if s not in whitelist}
    keep_lines: list[str] = []
    for i, line in enumerate(lines):
        if any(start <= i < end for start, end, _ in blocks
               if lines[start][len("//export "):].strip() in drop):
            continue
        keep_lines.append(line)

    # Collapse blank-line runs left by removed blocks (gofmt keeps at most one).
    collapsed = re.sub(r"\n{3,}", "\n\n", "\n".join(keep_lines) + "\n")
    return _drop_unused_imports(collapsed, label)


# --------------------------------------------------------------------------- #
# throne_ffi.dart
# --------------------------------------------------------------------------- #

def _class_spans(lines: list[str]) -> list[tuple[int, int, str]]:
    spans: list[tuple[int, int, str]] = []
    i = 0
    while i < len(lines):
        m = CLASS_RE.match(lines[i])
        if not m:
            i += 1
            continue
        j = i + 1
        while j < len(lines) and lines[j] != "}":
            j += 1
        if j >= len(lines):
            raise PruneError(f"class {m.group(1)} at line {i + 1} has no closing '}}'")
        spans.append((i, j + 1, m.group(1)))
        i = j + 1
    return spans


def _split_members(body: list[str], label: str) -> list[tuple[int, int]]:
    """Split a class body (without header/closing brace) into member spans.

    A member starts at column-2 indentation when brace depth is zero. Preceding
    doc-comment lines are folded into the following member.
    """
    starts: list[int] = []
    depth = 0
    for idx, line in enumerate(body):
        if depth == 0 and MEMBER_START_RE.match(line):
            starts.append(idx)
        depth += line.count("{") - line.count("}")
        if depth < 0:
            raise PruneError(f"{label}: unbalanced braces at body line {idx + 1}")
    if depth != 0:
        raise PruneError(f"{label}: unbalanced braces (final depth {depth})")
    members: list[tuple[int, int]] = []
    for n, s in enumerate(starts):
        end = starts[n + 1] if n + 1 < len(starts) else len(body)
        b = s
        while b > 0 and body[b - 1].strip().startswith("///"):
            b -= 1
        members.append((b, end))
    return members


def _prune_throneffi(lines: list[str], start: int, end: int,
                     whitelist: set[str]) -> tuple[list[str], set[str]]:
    """Return the pruned ThroneFFI class lines and the lookups it kept."""
    head = lines[start]  # 'class ThroneFFI {'
    body = lines[start + 1:end - 1]  # exclude header + closing '}'
    # Head members: the _lookup field and the constructor (before the first
    # late final binding). Everything from the first 'late final _throne_' is a
    # binding block; a block ends at the next such line.
    first = next((i for i, l in enumerate(body) if l.startswith("  late final _throne_")), None)
    if first is None:
        raise PruneError("ThroneFFI: no _throne_ lookup bindings found")
    prefix = body[:first]

    starts = [i for i, l in enumerate(body) if l.startswith("  late final _throne_")]
    kept_syms: set[str] = set()
    out = list(prefix)
    for n, s in enumerate(starts):
        block = body[s:starts[n + 1] if n + 1 < len(starts) else len(body)]
        lm = LOOKUP_RE.search("\n".join(block))
        if not lm:
            raise PruneError(
                f"ThroneFFI: lookup block at body line {s + 1} has no symbol string"
            )
        sym = lm.group(1)
        if sym in whitelist:
            kept_syms.add(sym)
            out.extend(block)
        # else: drop the whole binding (lookup + public accessor method)
    # Every whitelist symbol must have had a binding in the original generated
    # file; if not, the generator or the whitelist drifted and a getter would be
    # silently unavailable. (symbol_audit.py asserts the reverse direction.)
    missing = sorted(whitelist - kept_syms)
    if missing:
        raise PruneError(f"ThroneFFI: whitelisted symbols have no generated binding: {missing}")
    return [head, *out, "}"], kept_syms


def prune_dart(text: str, whitelist: set[str]) -> str:
    lines = text.splitlines()
    spans = _class_spans(lines)
    ffi = [s for s in spans if s[2] == "ThroneFFI"]
    if len(ffi) != 1:
        raise PruneError(f"throne_ffi.dart: expected exactly one ThroneFFI class, found {len(ffi)}")
    ffi_start, ffi_end, _ = ffi[0]

    # Split the file into: [before FFI][FFI][shared helpers][wrapper classes ...]
    wrapper_spans = [s for s in spans if s[2] != "ThroneFFI"]
    helpers_start = ffi_end
    first_wrapper = wrapper_spans[0][0] if wrapper_spans else len(lines)

    out: list[str] = lines[:ffi_start]
    ffi_lines, kept_lookups = _prune_throneffi(lines, ffi_start, ffi_end, whitelist)
    out.extend(ffi_lines)
    out.extend(lines[helpers_start:first_wrapper])  # _cstr/_HandleRef/finalizer/helpers

    # Decide which wrapper classes survive and verify there are no dangling
    # class references afterwards.
    kept_class_bodies: dict[str, list[str]] = {}
    dropped: set[str] = set()
    for start, end, name in wrapper_spans:
        body = lines[start + 1:end - 1]
        members = _split_members(body, name)
        kept_members: list[str] = []
        has_live = False
        for b, e in members:
            chunk = body[b:e]
            blob = "\n".join(chunk)
            syms = set(re.findall(r"\b(throne_\w+)\b", blob)) & whitelist
            structural = ("_handleFinalizer.attach(" in blob
                          or "void release() =>" in blob
                          or bool(re.match(r"^  final ", "\n".join(chunk[:1]))))
            if syms:
                has_live = True
            if syms or structural:
                kept_members.extend(chunk)
        if has_live:
            kept_class_bodies[name] = [lines[start], *kept_members, "}"]
        else:
            dropped.add(name)

    # Dangling-reference check: a kept member may not reference a dropped class.
    survivor_code = "\n".join(
        "\n".join(v) for v in kept_class_bodies.values()
    ) + "\n" + "\n".join(kept_lookups)
    for cls in sorted(dropped):
        if re.search(rf"\b{re.escape(cls)}\b", survivor_code):
            raise PruneError(
                f"throne_ffi.dart: dropping wrapper class {cls} would leave a dangling "
                "reference in a kept binding; widen live_exports.txt or keep the class"
            )

    for _, _, name in wrapper_spans:
        if name in kept_class_bodies:
            out.extend(kept_class_bodies[name])
            out.append("")  # one blank line between classes

    # Anything after the last wrapper class (e.g. decodeBridgeEvent) is shared.
    last_wrapper_end = wrapper_spans[-1][1] if wrapper_spans else first_wrapper
    tail = [l for l in lines[last_wrapper_end:] if l.strip()]
    out.extend(tail)

    return re.sub(r"\n{3,}", "\n\n", "\n".join(out) + "\n")


# --------------------------------------------------------------------------- #
# driver
# --------------------------------------------------------------------------- #

def _write(path: Path, data: str, dry_run: bool, check: bool,
           changed: list[str]) -> None:
    current = path.read_text(encoding="utf-8") if path.exists() else None
    if current == data:
        return
    changed.append(str(path))
    if dry_run or check:
        return
    path.write_text(data, encoding="utf-8", newline="\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", type=Path, default=ROOT_DEFAULT,
                    help="repository root (default: parent of tools/bindgen)")
    ap.add_argument("--live", type=Path, help="override live_exports.txt path")
    ap.add_argument("--headers", nargs=2, type=Path,
                    help="override the two bridge_symbols.h paths")
    ap.add_argument("--go", type=Path, help="override bridge_calls.go path")
    ap.add_argument("--dart", type=Path, help="override throne_ffi.dart path")
    ap.add_argument("--dry-run", action="store_true",
                    help="print files that would change without writing")
    ap.add_argument("--check", action="store_true",
                    help="like --dry-run but exit 1 if any file would change")
    args = ap.parse_args()

    root = args.root.resolve()
    live = (args.live or root / "tools" / "bindgen" / "live_exports.txt").resolve()
    patch = root / "buildScript" / "core-patch" / "core" / "mobile"
    headers = [p.resolve() for p in args.headers] if args.headers else [
        patch / "bridge_symbols.h",
        root / "android" / "core" / "src" / "main" / "cpp" / "bridge_symbols.h",
    ]
    go_path = (args.go or patch / "bridge_calls.go").resolve()
    dart_path = (args.dart or root / "flutter" / "lib" / "core" / "throne_ffi.dart").resolve()
    runtime_path = patch / "bridge_runtime.go"

    try:
        whitelist = read_whitelist(live)

        # The two headers are the same contract consumed by two toolchains. If
        # they have drifted apart, refuse rather than silently picking one.
        htexts = []
        for h in headers:
            if not h.is_file():
                raise PruneError(f"missing header: {h}")
            htexts.append(h.read_text(encoding="utf-8"))
        if htexts[0] != htexts[1]:
            raise PruneError(f"the two bridge_symbols.h copies differ before pruning: "
                             f"{headers[0]} vs {headers[1]}")
        pruned_header = prune_header(htexts[0], whitelist, str(headers[0]))
        pruned_header2 = prune_header(htexts[1], whitelist, str(headers[1]))
        if pruned_header != pruned_header2:
            raise PruneError("pruned headers are not byte-identical")

        runtime_syms = set(re.findall(
            r"^//export (throne_\w+)", runtime_path.read_text(encoding="utf-8"), re.M
        )) if runtime_path.is_file() else set()
        go_text = go_path.read_text(encoding="utf-8")
        pruned_go = prune_go_calls(go_text, whitelist, runtime_syms, str(go_path))
        dart_text = dart_path.read_text(encoding="utf-8")
        pruned_dart = prune_dart(dart_text, whitelist)
    except PruneError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1

    changed: list[str] = []
    for h in headers:
        _write(h, pruned_header, args.dry_run, args.check, changed)
    _write(go_path, pruned_go, args.dry_run, args.check, changed)
    _write(dart_path, pruned_dart, args.dry_run, args.check, changed)

    total = len(set(re.findall(r"^//export (throne_\w+)", go_text, re.M)) | runtime_syms)
    print(f"whitelist: {len(whitelist)} live symbols (out of ~{total} generated)")
    if changed:
        verb = "would change" if (args.dry_run or args.check) else "pruned"
        for p in changed:
            print(f"  {verb}: {p}")
    else:
        print("  all generated artifacts already match the whitelist (idempotent)")
    if args.check and changed:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
