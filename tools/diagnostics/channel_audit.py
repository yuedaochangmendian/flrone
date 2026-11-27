"""MethodChannel contract audit for the B-box bridge.

Cross-checks, statically, the two ends of the bridge that `flutter analyze` and
the Kotlin compiler cannot see (the contract lives in string literals):

  - Dart -> Kotlin: every method the UI invokes (`box.call('…')` / `box.act('…')`,
    dotted or bare inside BoxController) **or the service engine sends through
    its host boundary** (`host.call('…')` / `_host.call('…')` /
    `host.invokeMethod('…')` in kernel_service.dart / service_entry.dart) must
    have a `when(call.method)` handler in FlronePlatformBridge.kt or
    ServiceBridge.kt
  - Kotlin -> Dart: every event the host emits (`emit("…", …)`) must be consumed
    by a `case '…'` in the Dart event dispatcher (flutter/lib/box.dart), and every
    MethodChannel/EventChannel name declared anywhere in flutter/lib/**/*.dart
    must have a counterpart in io/flrone/**/*.kt (this now covers the service
    channel, its event channel and the profiles document channel, not just box.dart)
  - dispatch sites whose method is not a literal (ternaries, switch arms, widget
    arguments) are held to a declared allowlist in DYNAMIC_SITES — exact names and
    dot-terminated prefixes only — a new site or an undeclared name fails; every
    declared name must also have a handler
  - handlers with no caller are listed (with --verbose) as dead-weight candidates
  - the `io.flrone/secure` credential channel (S10) is registered outside the bridge's
    `when (call.method)` on purpose, so the checks above cannot see it: its name on both
    ends, its two methods and its registration after FlronePlatformBridge are pinned here

Run from the repository root:
    uv run tools/diagnostics/channel_audit.py [--verbose]

Exit code 0 when every call has a handler and every event a consumer, 1 otherwise.

Assumptions and maintenance
---------------------------
This is a deliberately shallow, regex-based cross-check, not a parser. Two
hand-maintained assumptions keep it working; both are fragile and are the first
things to suspect when the audit reports a false positive or a false negative:

  1. DYNAMIC_SITES is a manual allowlist of dispatch sites whose method name is
     not a string literal (ternaries, switch arms, widget-driven calls), keyed by
     source file, with exact names or dot-terminated prefixes. It is not derived
     from the Dart AST. Adding a new dynamic dispatch site anywhere else makes the
     audit fail until that site and the names it can produce are declared here;
     every declared name must also have a Kotlin handler. When the UI changes,
     review this table and keep the declared names in sync with the code.
  2. kotlin_handlers() bounds each `when (call.method)` block by the next member
     function, which it assumes sits at exactly four spaces of indentation (a
     normal Kotlin class-body `fun`). A nested `fun` at that same depth, or a
     class reformatted to a different indent, truncates the slice. The failure is
     deliberately fail-closed: handlers after such a boundary surface as missing,
     never silently excused. See the arm_indent note in kotlin_handlers() for the
     related column assumption on the `when` arms.

Both assumptions are documented rather than generalised here on purpose: the
audit is a CI gate, so rewriting the parsing logic in place would risk weakening
it. If either assumption stops matching the code, fix the assumption and the
table explicitly, then re-run the audit. The host-call boundary used to be a
third blind spot: the engine's `KernelHost.call(String method)` abstracted the
name into a variable, so the audit leaned on two blanket DYNAMIC_SITES file
vouchers. It now scans host.call/_host.call/host.invokeMethod literals directly;
the only vouchers left are genuine dynamic dispatch sites.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FLUTTER_LIB = REPO_ROOT / "flutter" / "lib"
BRIDGE = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "flutter" / "FlronePlatformBridge.kt"
# The service engine speaks to its own MethodChannel (`io.flrone/service`) and
# its event channel (`io.flrone/service/events`). Its host arms live here, not in
# FlronePlatformBridge — a deleted arm used to be invisible to this audit.
SERVICE_BRIDGE = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "flutter" / "ServiceBridge.kt"
# ADR 0002 phase 3b-2: migrated domains move out of the bridge's `when` into this
# registry. Both tables are legitimate handler sources; the bridge forwards to the
# registry first and falls through for everything else.
BRIDGE_ACTIONS = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "FlroneActions.kt"
BRIDGE_DIR = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone"
DART_DISPATCH = FLUTTER_LIB / "box.dart"
# S10's credential channel: a separate registration with a separate budget entry, so
# neither of the tables above covers it — see secure_channel_contract_failures().
SECURE_BOX = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "bridge" / "SecureBox.kt"
SECURE_DART = FLUTTER_LIB / "services" / "webdav_account.dart"
ACTIVITY = REPO_ROOT / "app" / "src" / "main" / "java" / "io" / "flrone" / "flutter" / "FlroneActivity.kt"

# Bridge dispatches only: the receiver is a box-ish identifier (`box`, `_box!`,
# `context.box`), so an unrelated `.call(` on a callback field never matches.
# `?.call(` on a Dart Callable is not a dispatch and the `?` lookbehind keeps it
# out; whitespace before the paren is allowed (`box.call ('…')`). The bare form
# (`call('…')` inside BoxController) is matched separately.
#
# The service engine reaches its host through `KernelHost.call(String method)`
# (kernel_service.dart) and a thin `MethodChannel.invokeMethod` in
# service_entry.dart. Their receivers are `host` / `_host`, or a channel field
# such as `_channel` / `_secureChannel`. These are the SAME contract as box.call:
# a deleted Kotlin arm is a MissingPluginException at runtime, so the literal
# names must count as callers. Kept in the same regexes so interpolated host
# names are caught by the dynamic-site check too.
RECEIVER = r"\w*box\s*!?\??\s*\.\s*(?:call|act)"
HOST_RECEIVER = r"(?:_?host|_?\w*[Cc]hannel)\s*\.\s*(?:call|invokeMethod)"
BARE = r"(?<![\w?.])(?:call|act)"
DISPATCH_RECEIVER = rf"(?:{RECEIVER}|{HOST_RECEIVER}|{BARE})"
CALL_RE = re.compile(
    rf"(?<!\?){DISPATCH_RECEIVER}\s*\(\s*'([a-zA-Z][a-zA-Z0-9_.:]*)'",
    re.IGNORECASE)
# An interpolated method name (`act('${widget.kind}.submit')`) is a dispatch the
# literal regex cannot name. The second alternative is a ZERO-WIDTH lookahead right
# after the paren: a consuming match would backtrack to the last `$` and leave
# first_argument() starting mid-string, silently disabling the tail check below.
DYNAMIC_CALL_RE = re.compile(
    rf"(?<!\?){DISPATCH_RECEIVER}\s*\(\s*(?!['\s)])"
    rf"|(?<!\?){DISPATCH_RECEIVER}\s*\(\s*(?='(?:[^'\\]|\\.)*\$)",
    re.IGNORECASE)
KOTLIN_METHOD_RE = re.compile(r'"([a-zA-Z][a-zA-Z0-9_.:]*)"\s*->')
EMIT_RE = re.compile(r'\bemit\(\s*"([a-zA-Z][a-zA-Z0-9_]*)"')
DART_CASE_RE = re.compile(r"case\s+'([a-zA-Z][a-zA-Z0-9_.:]*)'")
DART_CHANNEL_RE = re.compile(r"(?:Method|Event)Channel\(\s*'([^']+)'")
# A channel name may come from a top-level const (`MethodChannel(secureChannelName)`).
# Resolve it through DART_CONST_RE rather than counting the identifier as a channel.
DART_CHANNEL_REF_RE = re.compile(r"(?:Method|Event)Channel\(\s*([A-Za-z_]\w*)\s*[,\)]")
DART_CONST_RE = re.compile(r"^\s*const\s+([A-Za-z_]\w*)\s*=\s*'([^']+)'", re.M)
# Read channel names from the constructors on both ends rather than hard-coding
# an organisation prefix: renaming the bridge namespace must not break this gate.
KOTLIN_CHANNEL_RE = re.compile(r'(?:Method|Event)Channel\([^)]*?"([^"]+)"')
# Kotlin passes either a bare const (`MethodChannel(messenger, CHANNEL)`) or a
# qualified one (`MethodChannel(messenger, SecureBox.CHANNEL)`); resolve both via
# the const value, not by requiring a specific class name.
KOTLIN_CHANNEL_REF_RE = re.compile(r'(?:Method|Event)Channel\(\s*[^,()]+\s*,\s*([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)\s*(?:,|\))')
KOTLIN_CONST_RE = re.compile(r'\bconst\s+val\s+([A-Za-z_]\w*)\s*=\s*"([^"]+)"')

# Handlers are dotted (`word.word…`) with the single historical exception of
# `ready`; anything else a `"…" ->` match picks up inside the when block (nested
# data mappings like "Stopping", "directDns") is not a handler.
METHOD_NAME_RE = re.compile(r"^[a-z][a-zA-Z0-9_]*(?:\.[a-zA-Z0-9_]+)+$|^ready$")

# Dynamic dispatch sites (ternaries, switch arms, widget-driven methods) with
# their literals; a name ending in `.` matches every method under it, anything
# else matches exactly. Keep in sync with the code — a new dynamic site anywhere
# else fails the audit, and every declared name must have a handler.
DYNAMIC_SITES: dict[str, set[str]] = {
    "flutter/lib/box.dart": {"dashboard.memory.visible", "logs.logcat.visible", "groups.testSession.visible", "logs.visible"},
    "flutter/lib/components/status_panel.dart": {"service.start", "service.stop"},
    "flutter/lib/pages/logs.dart": {"logs.clear", "logs.logcat.clear"},
    # No voucher for kernel_control.dart / service_entry.dart: their host calls
    # are now literal `host.call('…')` / `.invokeMethod('…')` dispatch sites and
    # are counted by CALL_RE directly. The old blanket file vouchers hid the
    # service-engine host boundary — deleting a ServiceBridge.kt arm used to
    # pass this gate and fail at runtime with MissingPluginException. `log.note`
    # does NOT need a voucher either: every call site (box.dart, main.dart,
    # status_panel.dart and the kernel's host.call) names it as a literal.
}

# Generated code is not dispatch-site territory; only its literal calls count.
# The two `KernelHost.call(String method)` declarations are interface/impl
# signatures, not dispatch sites: a literal call through the interface is
# already counted by CALL_RE at the call site (kernel_service.dart /
# service_entry.dart). Exempt the declaration files from site gating while
# still letting their literal calls count.
DYNAMIC_EXEMPT = (
    "flutter/lib/ui/generated/",
    "flutter/lib/core/kernel_control.dart",
    "flutter/lib/service_entry.dart",
)
# Generated bindings hold no hand-written channel declarations. The two host
# interface files DO declare channels (service_entry.dart owns the service
# channel and its event channel), so they stay in the channel scan.
CHANNEL_EXEMPT = ("flutter/lib/ui/generated/",)

# The retired Room seed chain is gone from both sides of the bridge
# (LegacyRoomReader deleted, its Dart migration deleted). `data.legacyRows` must
# stay in neither the bridge list above nor a Dart call site; the general
# "every Dart call has a handler" check is the hard failure now — there is no
# pending-call allowance to carve out of it.


def covered(method: str, entries: set[str]) -> bool:
    """Exact names vouch exactly; a name ending in a dot vouches its prefix."""
    return any(method == entry or (entry.endswith(".") and method.startswith(entry)) for entry in entries)


def dart_calls() -> tuple[dict[str, list[str]], list[str]]:
    callers: dict[str, list[str]] = {}
    dynamic: list[str] = []
    for path in sorted(FLUTTER_LIB.rglob("*.dart")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        text = path.read_text(encoding="utf-8")
        for match in CALL_RE.finditer(text):
            callers.setdefault(match.group(1), []).append(rel)
        if rel.startswith(DYNAMIC_EXEMPT):
            continue
        for match in DYNAMIC_CALL_RE.finditer(text):
            line = text.count("\n", 0, match.start()) + 1
            dynamic.append(f"{rel}:{line}")
    return callers, dynamic


def registry_handlers() -> set[str]:
    """Names registered in FlroneActions (`register("dotted.name") { ... }`)."""
    if not BRIDGE_ACTIONS.is_file():
        return set()
    text = BRIDGE_ACTIONS.read_text(encoding="utf-8")
    return set(re.findall(r'register\(\s*"([a-zA-Z][a-zA-Z0-9_.]*)"', text))


def _handlers_in(text: str, start: int, end: int) -> set[str]:
    """Read `\"dotted\" ->` arms in one `when (call.method)` slice.

    Arms sit one level under the `when`'s own indentation; anchoring the match to
    that column keeps a nested `when (state) { \"dotted\" -> … }` from counting as
    a handler of the outer dispatch. The arm_indent assumption applies only to
    these conventionally formatted Kotlin blocks: the `when` line sits at N
    spaces and its arms at N + 4 (four-space class indentation). Tabs, a different
    indent width, or arms on the `when` line shift the column matched below and
    make handlers look missing (fail-closed, as the bounding comment in
    kotlin_handlers describes). This is a documented assumption, not a general
    Kotlin parser.
    """
    when_line = text[:start].rsplit("\n", 1)[-1]
    arm_indent = len(when_line) - len(when_line.lstrip()) + 4
    arms = re.finditer(rf"^ {{{arm_indent}}}\"([a-zA-Z][a-zA-Z0-9_.:]*)\"\s*->",
                       text[start:end], flags=re.M)
    return {name for name in (match.group(1) for match in arms) if METHOD_NAME_RE.match(name)}


def _handler_block(text: str, path: Path, *, last_member: bool) -> set[str]:
    """Bound one bridge's `when (call.method)` and collect its arms.

    Brace matching cannot be used here: Kotlin's nested string interpolations
    (`"${if (x) "a" else "b"}"`) defeat every regular-expression counter. The
    boundary assumes member functions sit at exactly four spaces of indentation
    — a nested `fun` at that depth inside the when block would truncate the slice
    (fail-closed: handlers after it surface as missing, never silently excused).

    The main bridge has members after `onMethodCall`; ServiceBridge's
    `onMethodCall` is the last member in its object, so the boundary is the
    function's closing brace at four spaces instead. In both cases an unknown
    boundary fails loudly rather than slicing to EOF, where later `"dotted" ->`
    mappings would leak in as phantom handlers.
    """
    start = text.find("when (call.method)")
    if start < 0:
        raise SystemExit(f"channel audit: {path.name} has no `when (call.method)` block")
    tail = text[start:]
    if last_member:
        boundary = re.search(r"\n    \}", tail)
        if boundary is None:
            raise SystemExit(f"channel audit: {path.name}: no closing brace after "
                             "`when (call.method)`; cannot bound the handler block")
    else:
        boundary = re.search(r"\n    (?:private |internal |override )?(?:suspend )?fun ", tail)
        if boundary is None:
            raise SystemExit(f"channel audit: {path.name}: no member function after "
                             "`when (call.method)`; cannot bound the handler block; "
                             "adjust _handler_block()")
    return _handlers_in(text, start, start + boundary.start())


def kotlin_handlers() -> set[str]:
    """Union of both channel bridges' method arms (plus the action registry).

    The UI bridge and the headless ServiceBridge answer different channels:
    `config.applied*` and `driver.ready` exist only in ServiceBridge. Auditing
    only the UI bridge left those arms invisible — a deleted ServiceBridge arm
    would have shipped as a MissingPluginException in the service engine.
    """
    if not SERVICE_BRIDGE.is_file():
        raise SystemExit("channel audit: ServiceBridge.kt is missing; the service-engine "
                         "host-call boundary cannot be audited")
    return (_handler_block(BRIDGE.read_text(encoding="utf-8"), BRIDGE, last_member=False)
            | _handler_block(SERVICE_BRIDGE.read_text(encoding="utf-8"), SERVICE_BRIDGE,
                             last_member=True))


def emitted_events() -> set[str]:
    """Events from both bridges; ServiceBridge emits `wifi.state` too."""
    return (set(EMIT_RE.findall(BRIDGE.read_text(encoding="utf-8")))
            | set(EMIT_RE.findall(SERVICE_BRIDGE.read_text(encoding="utf-8"))))


def consumed_events() -> set[str]:
    return set(DART_CASE_RE.findall(DART_DISPATCH.read_text(encoding="utf-8")))


def dart_channels() -> tuple[set[str], dict[str, str]]:
    """All channel names declared under flutter/lib/**/*.dart.

    box.dart is not the only owner any more: service_entry.dart declares both
    the service MethodChannel and its EventChannel, webdav_account.dart names
    the secure channel through a `const`, and box.dart also registers the
    profiles document channel. Scanning only box.dart made all of those
    invisible to the three-vs-three check. Generated bindings are skipped: they
    hold no hand-written channel declarations.

    Returns the channel set and the const-name -> literal map used to resolve
    indirect declarations (`MethodChannel(secureChannelName)`).
    """
    consts: dict[str, str] = {}
    for path in FLUTTER_LIB.rglob("*.dart"):
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel.startswith(CHANNEL_EXEMPT):
            continue
        consts.update(dict(DART_CONST_RE.findall(path.read_text(encoding="utf-8"))))
    found: set[str] = set()
    for path in FLUTTER_LIB.rglob("*.dart"):
        rel = path.relative_to(REPO_ROOT).as_posix()
        if rel.startswith(CHANNEL_EXEMPT):
            continue
        text = path.read_text(encoding="utf-8")
        found |= set(DART_CHANNEL_RE.findall(text))
        for name in DART_CHANNEL_REF_RE.findall(text):
            literal = consts.get(name)
            if literal is None:
                raise SystemExit(
                    f"channel audit: {rel} declares MethodChannel({name}) but no const "
                    f"literal was found; cannot audit the channel name")
            found.add(literal)
    return found, consts


def kotlin_channels() -> tuple[set[str], dict[str, str]]:
    """All channel names declared under io/flrone/**/*.kt.

    Literals and `const val` references are both resolved: ServiceBridge uses
    bare CHANNEL/EVENTS constants and SecureBox uses `SecureBox.CHANNEL`. Consts
    are keyed by their defining file so two classes that both declare `CHANNEL`
    (ServiceBridge vs SecureBox) cannot shadow each other. An unknown reference
    is a hard failure rather than a silently skipped channel.
    """
    consts_by_file: dict[str, dict[str, str]] = {}
    for path in BRIDGE_DIR.rglob("*.kt"):
        consts_by_file[path.stem] = dict(KOTLIN_CONST_RE.findall(
            path.read_text(encoding="utf-8")))
    found: set[str] = set()
    flat: dict[str, str] = {}
    for path in BRIDGE_DIR.rglob("*.kt"):
        text = path.read_text(encoding="utf-8")
        found |= set(KOTLIN_CHANNEL_RE.findall(text))
        local = consts_by_file.get(path.stem, {})
        for ref in KOTLIN_CHANNEL_REF_RE.findall(text):
            qualifier, _, name = ref.rpartition(".")
            # `SecureBox.CHANNEL` -> look in SecureBox.kt; a bare `CHANNEL` -> the
            # current file's own const first, then a unique global match.
            if qualifier:
                source = consts_by_file.get(qualifier, {})
                literal = source.get(name)
            else:
                literal = local.get(name)
                if literal is None:
                    matches = {c[name] for c in consts_by_file.values() if name in c}
                    literal = matches.pop() if len(matches) == 1 else None
            if literal is None:
                raise SystemExit(
                    f"channel audit: {path.relative_to(REPO_ROOT).as_posix()} declares "
                    f"MethodChannel({ref}) but no unambiguous const val literal "
                    f"was found; cannot audit the channel name")
            found.add(literal)
            flat[name] = literal
    return found, flat


def first_argument(text: str, open_paren: int) -> str:
    depth = 0
    for index in range(open_paren, len(text)):
        char = text[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return text[open_paren:index]
            depth -= 1
        elif char == "," and depth == 0:
            return text[open_paren:index]
    return text[open_paren:]


def allowed_name(method: str, literals: set[str]) -> bool:
    return covered(method, literals)


def site_allowed(site: str) -> bool:
    file, _, line = site.partition(":")
    literals = DYNAMIC_SITES.get(Path(file).as_posix())
    if literals is None:
        return False
    text = (REPO_ROOT / file).read_text(encoding="utf-8")
    matches = [m for m in DYNAMIC_CALL_RE.finditer(text)
               if text.count("\n", 0, m.start()) + 1 == int(line)]
    if not matches:
        return False
    # Every dispatch on the line must be allowed; one bad call must not hide
    # behind a good neighbour.
    verdicts = []
    for match in matches:
        first = first_argument(text, match.end())
        if "$" in first:
            # An interpolated name (`'${widget.kind}.cancel'`): vouch through the
            # constant tail after the last interpolation, which the declared set
            # must end with — the tail segment, not just any suffix.
            tail = re.search(r"\}([a-zA-Z0-9_.]*)'?\"?\)?\s*,?\s*$", first)
            if not tail or not tail.group(1):
                verdicts.append(False)
                continue
            segment = f".{tail.group(1).lstrip('.')}"
            verdicts.append(any(name.endswith(segment) for name in literals if not name.endswith(".")))
            continue
        # A conditional dispatch offers its branch results as the method names; a
        # plain quoted name must be declared; a bare identifier/member chain is
        # widget-driven and must be declared at its site in DYNAMIC_SITES.
        branches = [a or b for a, b in re.findall(r"\?\s*'([^']+)'|:\s*'([^']+)'", first)]
        if not branches:
            branches = [a or b for a, b in
                        re.findall(r"'([a-zA-Z][a-zA-Z0-9_.:]*)'|\"([a-zA-Z][a-zA-Z0-9_.:]*)\"", first)]
        if not branches:
            verdicts.append(True)
            continue
        verdicts.append(all(allowed_name(method, literals) for method in branches))
    return all(verdicts)


def ffi_id_contract_failures() -> list[str]:
    """Prevent a recurrence of the "profile 0 is gone" startup failure.

    The Flutter preference store holds appearance settings only; the native DB
    (DataStore.selectedProxy) owns the selected ProxyEntity, and the dashboard's
    selectedProfileId is a *group* id for display. Mining the wrong map used to
    send `config.build {id: 0}` on every start. The start path is now
    config.prepare (Kotlin side effects) followed by the Go configBuild action;
    no profile id crosses the boundary from Dart.
    """
    problems: list[str] = []
    service = (FLUTTER_LIB / "core" / "kernel_service.dart").read_text(encoding="utf-8")
    if "host.call('config.prepare')" not in service:
        problems.append("kernel_service.dart does not run config.prepare before the build")
    if "ActionMethod.configBuild" not in service:
        problems.append("kernel_service.dart does not invoke the Go configBuild action")
    if re.search(r"preferences\[['\"](?:selectedProxy|profileId)['\"]\]", service):
        problems.append("kernel_service.dart mines Flutter preferences for a proxy id")
    if re.search(r"\bIsolate\.run\b", service):
        problems.append("kernel_service.dart still opens a fresh isolate per FFI call")

    kernel = (REPO_ROOT / "app/src/main/java/io/flrone/bridge/FlroneKernel.kt").read_text(encoding="utf-8")
    if not re.search(r"fun prepareStart\(\)", kernel):
        problems.append("FlroneKernel.prepareStart must expose config.prepare")
    prepare = (REPO_ROOT / "app/src/main/java/io/flrone/bridge/ConfigPrepare.kt").read_text(encoding="utf-8")
    if "DataStore.selectedProxy" not in prepare:
        problems.append("ConfigPrepare no longer resolves DataStore.selectedProxy itself")
    if re.search(r'config\.prepare[\s\S]{0,300}call\.argument<Int>\("id"\)',
                 BRIDGE.read_text(encoding="utf-8")):
        problems.append("FlronePlatformBridge.config.prepare still forwards a guessed id")
    return problems


def backup_write_contract_failures() -> list[str]:
    """ADR 0005 phase 4: the backup write path is Dart-owned.

    `backup.create` / `backup.restore` must not reappear on the bridge: the THRN
    packing and the document mapping/merge live in
    `flutter/lib/services/backup_write.dart`. The host help is the read-only
    `data.path` facts, the narrow `data.applyBackupUi` writer for the two UI
    documents a full restore brings back, the backup container's SQL transport
    and the settings/markers document ops. The SAF decode path (`backup.open`)
    stays native and must remain.

    ADR 0006 stage C2c2a retired the live-Room half of the data plane:
    `data.roomSnapshot`, `data.applyRoomSnapshot` and `data.roomProfiles` are
    gone (with C2c1's `data.roomSql`) and must not return. The one-time legacy
    Room seed chain (`data.legacyRows` and its host reader) is retired too, on
    both sides: any restored handler or Dart call fails the general contract.
    """
    problems: list[str] = []
    bridge = BRIDGE.read_text(encoding="utf-8")
    for method in ("backup.create", "backup.restore"):
        if f'"{method}"' in bridge:
            problems.append(f'bridge still implements {method}; the write path is Dart-owned')
    # P14: the narrow host data-plane methods for stock Android, where the app
    # cannot dlopen SQLite. Dart still owns mapping/staging/envelope.
    # C2c1: the SQL transport is `backup.container` (the backup's own file, no
    # live-Room op). C2c2a: settings/markers go through their documents. The
    # retired `data.legacyRows` hand-over is gone with the legacy Room chain.
    for method in ("backup.open", "data.applyBackupUi", "backup.container",
                   "settings.snapshot", "markers.snapshot", "settings.restore",
                   "markers.restore"):
        if f'"{method}"' not in bridge:
            problems.append(f'bridge lost {method}; the data-plane host method must stay')
    for retired in ("data.roomSql", "data.roomSnapshot", "data.applyRoomSnapshot",
                    "data.roomProfiles", "data.legacyRows"):
        if f'"{retired}"' in bridge:
            problems.append(f'bridge still implements {retired}; the data plane is document-only')
    writer = FLUTTER_LIB / "services" / "backup_write.dart"
    if not writer.exists():
        problems.append("services/backup_write.dart is missing")
    else:
        text = writer.read_text(encoding="utf-8")
        for token in ("Future<Map<String, Object?>> createBackup", "Future<RestoreResult> restoreBackup"):
            if token not in text:
                problems.append(f"backup_write.dart no longer defines {token}")
    return problems


def platform_value_contract_failures() -> list[str]:
    """Prevent the `_Map<Object?, Object?> is not a Map<String, dynamic>` crash.

    StandardMessageCodec decodes native maps into `_Map<Object?, Object?>`.
    Casting those directly to `Json` used to abort `config.build`
    on every start. The fix belongs at
    the channel boundary (BoxController.call + the EventChannel stream), with
    checked conversions anywhere an isolate bounces a map back.
    """
    problems: list[str] = []
    box = (FLUTTER_LIB / "box.dart").read_text(encoding="utf-8")
    helper = FLUTTER_LIB / "core" / "platform_value.dart"
    service = FLUTTER_LIB / "core" / "kernel_service.dart"
    worker = FLUTTER_LIB / "core" / "kernel_worker.dart"

    if not helper.exists():
        problems.append("flutter/lib/core/platform_value.dart is missing")
    else:
        text = helper.read_text(encoding="utf-8")
        if not re.search(r"Object\?\s+normalizePlatformValue\(", text):
            problems.append("normalizePlatformValue() is missing")
        if "value is TypedData" not in text:
            problems.append("normalizePlatformValue() must preserve typed data (app icons)")
        if not re.search(r"value is Map[\s\S]{0,200}normalizePlatformValue", text):
            problems.append("normalizePlatformValue() must recurse into nested maps")

    call = re.search(r"Future<dynamic> call\(String method[\s\S]{0,300}?;", box)
    if not call or "normalizePlatformValue" not in call.group(0):
        problems.append("BoxController.call must normalize method-channel replies")
    if not re.search(r"_events\s*=[\s\S]{0,250}normalizePlatformValue", box):
        problems.append("the EventChannel stream must normalize its payloads")
    if "import 'core/platform_value.dart';" not in box:
        problems.append("box.dart must import the normalization helper")

    # Generated bindings (throne_ffi.dart) legitimately cast json.decode output;
    # hand-written runtime code must never cast a channel/isolate value to Json.
    for path in (service, worker):
        text = path.read_text(encoding="utf-8")
        if re.search(r"\bas\s+(?:Map<String,\s*dynamic>|Json)\b", text):
            problems.append(f"{path.name} casts a platform value directly to Json")
        if "asStringKeyedMap" not in text:
            problems.append(f"{path.name} must use asStringKeyedMap() for wire maps")

    test = REPO_ROOT / "flutter" / "test" / "platform_value_test.dart"
    if not test.exists():
        problems.append("platform_value_test.dart regression suite is missing")
    elif "StandardMessageCodec" not in test.read_text(encoding="utf-8"):
        problems.append("the regression suite must exercise the real codec shape")
    return problems


def secure_channel_contract_failures() -> list[str]:
    """S10: the credential envelope's channel.

    `io.flrone/secure` is deliberately its own registration (the box is not a bridge domain),
    so the two cross-checks above never look at it: the handler set comes from the
    bridge/registry, not from SecureBox's own `when`. A renamed method on either end, or a
    registration reordered before the bridge, would ship as a MissingPluginException at the
    first WebDAV save — with the failure only visible to a user on a phone. Pinned here.
    """
    problems: list[str] = []
    bridge_marker = "FlronePlatformBridge(this, flutterEngine.dartExecutor.binaryMessenger)"
    secure_marker = "SecureChannel(flutterEngine.dartExecutor.binaryMessenger)"

    if not SECURE_BOX.is_file():
        return ["SecureBox.kt is missing; the io.flrone/secure host end has no implementation"]
    box = SECURE_BOX.read_text(encoding="utf-8")
    if '"io.flrone/secure"' not in box:
        problems.append('SecureBox.kt does not declare the "io.flrone/secure" channel')
    if not SECURE_DART.is_file():
        problems.append("services/webdav_account.dart is missing")
    else:
        dart = SECURE_DART.read_text(encoding="utf-8")
        if "'io.flrone/secure'" not in dart:
            problems.append("webdav_account.dart does not name the io.flrone/secure channel")
    # Both ends must speak the same two methods; the names are string literals either way.
    for method in ("seal", "open"):
        if f'"{method}"' not in box:
            problems.append(f'SecureBox.kt does not answer "{method}"')
        if SECURE_DART.is_file() and f"'{method}'" not in SECURE_DART.read_text(encoding="utf-8"):
            problems.append(f"webdav_account.dart never invokes '{method}'")
    if not ACTIVITY.is_file():
        problems.append("FlroneActivity.kt is missing")
    else:
        activity = ACTIVITY.read_text(encoding="utf-8")
        if secure_marker not in activity:
            problems.append("FlroneActivity does not register the secure channel")
        elif bridge_marker in activity and activity.index(bridge_marker) > activity.index(secure_marker):
            problems.append("the secure channel is registered before FlronePlatformBridge")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--verbose", action="store_true", help="also list handlers with no Dart caller")
    args = parser.parse_args()

    calls, dynamic = dart_calls()
    # Handlers live in two places now: the bridge's own `when` arms and the
    # FlroneActions registry the bridge forwards to first. A name in either counts.
    handlers = kotlin_handlers() | registry_handlers()
    emits = emitted_events()
    consumers = consumed_events()

    missing_handlers = sorted(set(calls) - handlers)
    missing_consumers = sorted(emits - consumers)
    unknown_dynamic = [site for site in dynamic if not site_allowed(site)]
    # A declared dynamic name with no handler is invisible to every check above
    # (its callers are all dynamic): validate the declarations themselves. A
    # declaration only applies when its site file exists in the audited tree.
    dead_declarations = sorted(
        literal for file, literals in DYNAMIC_SITES.items() for literal in literals
        if (REPO_ROOT / file).exists()
        and not covered(literal, handlers)
    )
    # A voucher whose file was deleted keeps its literals in `dynamic_known`, which would mask a
    # missing handler if a similar call reappeared — and `dead_declarations` skips it because it
    # only checks files that exist. Both are silent, so the stale file itself is a failure.
    stale_sites = sorted(file for file in DYNAMIC_SITES if not (REPO_ROOT / file).exists())
    dynamic_known = {method for literals in DYNAMIC_SITES.values() for method in literals if not method.endswith(".")}
    uncalled = sorted(handler for handler in handlers - set(calls) - dynamic_known)
    dart_ch, _ = dart_channels()
    kotlin_ch, _ = kotlin_channels()
    missing_channels = sorted(dart_ch - kotlin_ch)

    print(f"bridge methods: {len(handlers)} handlers, {len(calls)} distinct Dart callers")
    print(f"events: {len(emits)} emitted, {len(consumers)} consumed; "
          f"channels: {len(dart_ch)} dart, {len(kotlin_ch)} kotlin")

    failed = False
    # Every scanner must have found something. A rename of the call shape (say `box.call(`
    # becoming a wrapper) empties `calls`, every set difference below then comes out empty,
    # and the audit reports a clean contract while comparing nothing — the same failure the
    # action_contract gate was hardened against.
    for found, label in (
        (calls, "Dart dispatch sites"),
        (handlers, "Kotlin handlers"),
        (emits, "emitted events"),
        (consumers, "Dart event cases"),
        (dart_ch, "Dart channels"),
        (kotlin_ch, "Kotlin channels"),
    ):
        if not found:
            failed = True
            print(f"\nFAIL — no {label} found; the scanner matched nothing, so the audit could "
                  f"not run (fix the pattern, do not read this as a pass)")
    if missing_handlers:
        failed = True
        print("\nFAIL — Dart calls without a Kotlin handler:")
        for method in missing_handlers:
            print(f"  {method}  (called from {', '.join(sorted(set(calls[method])))})")
    if missing_consumers:
        failed = True
        print("\nFAIL — Kotlin events without a Dart consumer (flutter/lib/box.dart):")
        for event in missing_consumers:
            print(f"  {event}")
    if stale_sites:
        failed = True
        print("\nFAIL — DYNAMIC_SITES vouchers for files that no longer exist:")
        for site in stale_sites:
            print(f"  {site}")
    if unknown_dynamic:
        failed = True
        print("\nFAIL — dynamic dispatch sites outside DYNAMIC_SITES (declare them in the script):")
        for site in unknown_dynamic:
            print(f"  {site}")
    if dead_declarations:
        failed = True
        print("\nFAIL — declared dynamic names without a handler (the caller is dynamic,")
        print("so this is the only place the breakage would show):")
        for literal in dead_declarations:
            print(f"  {literal}")
    if missing_channels:
        failed = True
        print("\nFAIL — Dart channels with no Kotlin counterpart:")
        for channel in missing_channels:
            print(f"  {channel}")
    if args.verbose and uncalled:
        print("\nnote — Kotlin handlers with no Dart caller found:")
        for method in uncalled:
            print(f"  {method}")
    id_problems = ffi_id_contract_failures()
    if id_problems:
        failed = True
        print("\nFAIL — FFI profile-id contract:")
        for problem in id_problems:
            print(f"  {problem}")

    wire_problems = platform_value_contract_failures()
    if wire_problems:
        failed = True
        print("\nFAIL — platform value contract:")
        for problem in wire_problems:
            print(f"  {problem}")

    backup_problems = backup_write_contract_failures()
    if backup_problems:
        failed = True
        print("\nFAIL — backup write-path contract (ADR 0005 phase 4):")
        for problem in backup_problems:
            print(f"  {problem}")

    secure_problems = secure_channel_contract_failures()
    if secure_problems:
        failed = True
        print("\nFAIL — secure credential channel contract (S10):")
        for problem in secure_problems:
            print(f"  {problem}")

    if not failed:
        print("\ncontract OK: every live call has a handler, every event a consumer, "
              "the FFI path never invents a proxy id, and platform values are normalized")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
