"""scan an AAR / classes.jar for coroutines and stdlib API references the host may not provide.

Flutter plugins can be published against newer Kotlin artifacts than the host resolves. A bytecode
call to a member the resolved versions do not declare fails at runtime with NoSuchMethodError. This scan:

  1. reads every .class and collects Methodref / InterfaceMethodref / Fieldref entries under
     `kotlin/` and `kotlinx/coroutines/`;
  2. downloads the host's reference jars from Maven Central (cached under build/diagnostics-api-cache
     and, best effort, under ~/.cache/scan_aar_apis);
  3. resolves each reference against the declaring class's own and inherited members and reports
     whatever is left unbacked.

Maven Central answers a burst of jar fetches with 429 (or a gateway with 5xx). Those answers are
transient and the jars are immutable, so the fetch retries a bounded number of times before it
fails; a jar that still cannot be fetched fails the run instead of being skipped, because a skip
would silently weaken the audit.

Run from the repository root:
    uv run tools/diagnostics/scan_aar_apis.py <classes.jar-or.aar> [<another> ...] [--all]

Exit code 0 when nothing is missing, 1 when any reference is unbacked, 2 when a reference jar could
not be fetched (the scan did not run, so it has nothing to say about the artifact).
"""

from __future__ import annotations

import argparse
import io
import os
import struct
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CACHE = REPO_ROOT / "build" / "diagnostics-api-cache"
# A second copy outside the build directory: `build/` is disposable (and on CI it starts empty), so
# without this every cold checkout pays five Maven Central round trips — the window in which a 429
# used to fail the audit even though the build and tests had passed. None when the home directory
# cannot be resolved (then the repo cache is the only one, as before).
_HOME = os.path.expanduser("~")
USER_CACHE = Path(_HOME) / ".cache" / "scan_aar_apis" if _HOME not in ("", "~") else None

# Retry only what is transient. 429 is Maven Central's throttle (the reported CI failure); 5xx is a
# CDN or gateway under load. Anything else is a hard answer — a 404 means the URL is wrong, and
# retrying it would only delay the failure.
RETRY_STATUS = frozenset({429, 500, 502, 503, 504})
# Waits before attempt 2 and attempt 3: three attempts in total, 20 s of backoff.
RETRY_BACKOFF_SECONDS = (5, 15)
FETCH_TIMEOUT_SECONDS = 60

REFERENCE_JARS = {
    "kotlin-stdlib-2.4.21.jar":
        "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-stdlib/2.4.21/kotlin-stdlib-2.4.21.jar",
    "kotlin-stdlib-jdk7-2.4.21.jar":
        "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-stdlib-jdk7/2.4.21/kotlin-stdlib-jdk7-2.4.21.jar",
    "kotlin-stdlib-jdk8-2.4.21.jar":
        "https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-stdlib-jdk8/2.4.21/kotlin-stdlib-jdk8-2.4.21.jar",
    "kotlinx-coroutines-core-jvm-1.11.0.jar":
        "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-coroutines-core-jvm/1.11.0/kotlinx-coroutines-core-jvm-1.11.0.jar",
    "kotlinx-coroutines-android-1.11.0.jar":
        "https://repo1.maven.org/maven2/org/jetbrains/kotlinx/kotlinx-coroutines-android/1.11.0/kotlinx-coroutines-android-1.11.0.jar",
}

WATCHED = ("kotlin/", "kotlinx/coroutines/")


class ClassFile:
    def __init__(self, data: bytes):
        self.utf8: dict[int, str] = {}
        self.class_names: dict[int, int] = {}
        self.name_types: dict[int, tuple[int, int]] = {}
        self.refs: set[tuple[str, str, str, str]] = set()
        self.declared: set[tuple[str, str, str]] = set()  # (name, descriptor, kind)
        self.name = ""
        self.super_name = ""
        self._parse(data)

    def utf_at(self, i: int) -> str:
        return self.utf8.get(i, "")

    def _parse(self, data: bytes) -> None:
        if data[:4] != b"\xca\xfe\xba\xbe":
            return
        count = struct.unpack_from(">H", data, 8)[0]
        offset = 10
        index = 1
        member_refs: list[tuple[int, int, str]] = []
        while index < count:
            tag = data[offset]
            offset += 1
            if tag == 1:
                length = struct.unpack_from(">H", data, offset)[0]
                offset += 2
                self.utf8[index] = data[offset: offset + length].decode("utf-8", "replace")
                offset += length
            elif tag == 7:
                self.class_names[index] = struct.unpack_from(">H", data, offset)[0]
                offset += 2
            elif tag == 12:
                self.name_types[index] = struct.unpack_from(">HH", data, offset)
                offset += 4
            elif tag in (9, 10, 11):
                class_index, nt_index = struct.unpack_from(">HH", data, offset)
                # Methodref and InterfaceMethodref are one member kind for matching: a class
                # file's methods section does not say which way the caller reached the member.
                member_refs.append((class_index, nt_index, {9: "field", 10: "method", 11: "method"}[tag]))
                offset += 4
            elif tag in (3, 4):
                offset += 4
            elif tag in (5, 6):
                offset += 8
                index += 1
            elif tag == 8:
                offset += 2
            elif tag == 15:
                offset += 3
            elif tag in (16, 19, 20):  # MethodType, Module, Package
                offset += 2
            elif tag in (17, 18):  # Dynamic, InvokeDynamic: bootstrap index + NameAndType
                offset += 4
            else:
                raise ValueError(f"unknown constant-pool tag {tag} at {offset - 1}")
            index += 1

        for class_index, nt_index, kind in member_refs:
            cls = self.utf_at(self.class_names.get(class_index, 0))
            name_idx, desc_idx = self.name_types.get(nt_index, (0, 0))
            self.refs.add((cls, self.utf_at(name_idx), self.utf_at(desc_idx), kind))

        # class header and members: access, this, super, interfaces, fields, methods
        _access, this_idx, super_idx = struct.unpack_from(">HHH", data, offset)
        offset += 6
        self.name = self.utf_at(self.class_names.get(this_idx, 0))
        self.super_name = self.utf_at(self.class_names.get(super_idx, 0))
        interfaces_count = struct.unpack_from(">H", data, offset)[0]
        offset += 2 + 2 * interfaces_count

        for kind in ("field", "method"):
            members_count = struct.unpack_from(">H", data, offset)[0]
            offset += 2
            for _ in range(members_count):
                _flags, name_idx, desc_idx = struct.unpack_from(">HHH", data, offset)
                offset += 6
                self.declared.add((self.utf_at(name_idx), self.utf_at(desc_idx), kind))
                attrs_count = struct.unpack_from(">H", data, offset)[0]
                offset += 2
                for _ in range(attrs_count):
                    _name_idx, length = struct.unpack_from(">HI", data, offset)
                    offset += 6 + length


def parse_jar_classes(data: bytes) -> list[ClassFile]:
    classes: list[ClassFile] = []
    with zipfile.ZipFile(io.BytesIO(data)) as jar:
        for entry in jar.namelist():
            if entry.endswith(".class"):
                try:
                    classes.append(ClassFile(jar.read(entry)))
                except Exception as failure:  # noqa: BLE001 - a bad entry must not kill the scan
                    print(f"warning: {entry}: {failure}", file=sys.stderr)
    return classes


def read_artifact_classes(path: Path) -> list[ClassFile]:
    data = path.read_bytes()
    if path.suffix == ".aar":
        with zipfile.ZipFile(io.BytesIO(data)) as aar:
            data = aar.read("classes.jar")
    return parse_jar_classes(data)


class ReferenceJarError(RuntimeError):
    """A reference jar could not be obtained; without it the scan cannot be trusted."""


def _is_complete_jar(data: bytes) -> bool:
    """A finished jar opens as a zip with entries; a truncated body or an error page does not."""
    try:
        with zipfile.ZipFile(io.BytesIO(data)) as jar:
            return bool(jar.namelist())
    except zipfile.BadZipFile:
        return False


def _unlink_quietly(path: Path) -> None:
    """Best-effort delete: a cache we cannot clean is still usable on the next run."""
    try:
        path.unlink()
    except OSError as error:
        print(f"warning: cannot remove {path}: {error}", file=sys.stderr)


def _cached_jar(*paths: Path) -> bytes | None:
    """The first complete candidate, or None. A half-written file is deleted, not trusted."""
    for path in paths:
        if not path.is_file():
            continue
        data = path.read_bytes()
        if _is_complete_jar(data):
            return data
        print(f"warning: {path} is not a complete jar; discarding it", file=sys.stderr)
        _unlink_quietly(path)
    return None


def _store(path: Path, data: bytes) -> bool:
    """Write a verified body atomically (temp + rename), so readers never see a partial file."""
    temp = path.with_name(f"{path.name}.{os.getpid()}.tmp")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp.write_bytes(data)
        os.replace(temp, path)
        return True
    except OSError as error:
        print(f"warning: cannot cache {path}: {error}", file=sys.stderr)
        return False
    finally:
        if temp.exists():
            _unlink_quietly(temp)


def _fetch(url: str) -> bytes:
    """GET [url], retrying the transient statuses with a short backoff.

    Raises [ReferenceJarError] with the last answer when the attempts are used up — never a silent
    skip and never a partial body: the caller validates the bytes before they are cached.
    """
    attempts = len(RETRY_BACKOFF_SECONDS) + 1
    reason = "no attempt made"
    for attempt in range(1, attempts + 1):
        retryable = True
        try:
            with urllib.request.urlopen(url, timeout=FETCH_TIMEOUT_SECONDS) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            error.close()
            reason = f"HTTP {error.code} {error.reason}"
            retryable = error.code in RETRY_STATUS
        except (urllib.error.URLError, OSError) as error:
            # Connection reset, DNS failure, timeout: the same transient shape as a 5xx.
            reason = f"{type(error).__name__}: {error}"
        if not retryable:
            raise ReferenceJarError(f"{url}: {reason}")
        if attempt < attempts:
            delay = RETRY_BACKOFF_SECONDS[attempt - 1]
            print(
                f"warning: {reason} for {url}; retrying in {delay}s (attempt {attempt}/{attempts})",
                file=sys.stderr,
            )
            time.sleep(delay)
    raise ReferenceJarError(f"{url}: still failing after {attempts} attempts: {reason}")


def _cache_paths(name: str) -> list[Path]:
    """Where this jar may live: the repo cache first, then the user cache when there is one."""
    paths = [CACHE / name]
    if USER_CACHE is not None:
        paths.append(USER_CACHE / name)
    return paths


def reference_jar(name: str, url: str) -> bytes:
    """The jar's bytes: from a complete cache entry, or fetched and then cached.

    The cache never outranks correctness: only a body that opens as a jar is written, and the write
    is atomic, so a failed or interrupted download leaves no entry behind.
    """
    cached = _cached_jar(*_cache_paths(name))
    if cached is not None:
        return cached
    print(f"fetching {name} …", file=sys.stderr)
    data = _fetch(url)
    if not _is_complete_jar(data):
        raise ReferenceJarError(f"{url}: the body is not a jar (truncated response or an error page)")
    # Best effort both ways: a read-only checkout (or an unset HOME) still gets a usable scan from
    # the body in hand.
    for path in _cache_paths(name):
        _store(path, data)
    return data


def reference_world() -> tuple[set[tuple[str, str, str, str]], dict[str, str]]:
    """(all declared members as (class, name, desc, kind), class -> super)."""
    members: set[tuple[str, str, str, str]] = set()
    supers: dict[str, str] = {}
    for name, url in REFERENCE_JARS.items():
        for cls in parse_jar_classes(reference_jar(name, url)):
            supers[cls.name] = cls.super_name
            for member in cls.declared:
                members.add((cls.name, *member))
    return members, supers


PLATFORM = ("java/", "javax/", "android/", "dalvik/", "libcore/", "sun/", "jdk/", "kotlinx/android/")

# Verdicts for one reference against the host's jars.
#   declared          - the member is declared by the class or a library superclass
#   platform-owner    - the owner class itself comes from the platform; the pin cannot speak to it
#   platform-super    - the chain ran into a platform superclass without a hit; the member would
#                       have to be declared there (java/lang/Object's universal methods live here).
#                       Counted separately: unverifiable by pinning, not evidence of a real miss.
#   missing           - owner is in the pinned jars and no class in its chain declares the member
#   unknown-owner     - the owner class is not in the pinned jars at all (a class-level miss)
def backed(ref: tuple[str, str, str, str], members: set, supers: dict[str, str]) -> str:
    cls, name, desc, kind = ref
    if cls.startswith(PLATFORM):
        return "platform-owner"
    seen = set()
    while cls and cls not in seen:
        seen.add(cls)
        if (cls, name, desc, kind) in members:
            return "declared"
        if cls.startswith(PLATFORM):
            return "platform-super"
        parent = supers.get(cls)
        if parent is None:
            return "unknown-owner" if len(seen) == 1 else "missing"
        cls = parent
    return "missing"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifacts", nargs="*", help="classes.jar or .aar files to scan")
    parser.add_argument("--all", action="store_true", help="list every reference, not just missing ones")
    parser.add_argument("--libs", action="store_true", help="also scan app/libs/*.jar (vendored prebuilt jars)")
    args = parser.parse_args()

    paths = [Path(raw) for raw in args.artifacts]
    if args.libs:
        paths += sorted((REPO_ROOT / "app/libs").glob("*.jar")) if (REPO_ROOT / "app/libs").is_dir() else []
    if not paths:
        parser.error("no artifacts to scan")

    refs_total: set[tuple[str, str, str, str]] = set()
    for path in paths:
        refs = {ref for cls in read_artifact_classes(path) for ref in cls.refs if ref[0].startswith(WATCHED)}
        refs_total |= refs
        print(f"{path.name}: {len(refs)} coroutines/stdlib references")

    try:
        members, supers = reference_world()
    except ReferenceJarError as failure:
        # Exit 2, not 1: a fetch failure is "the scan could not run", not a finding about the AAR.
        print(
            f"error: the reference jars are unavailable, so no verdict is trustworthy:\n  {failure}",
            file=sys.stderr,
        )
        return 2
    verdicts = {ref: backed(ref, members, supers) for ref in refs_total}
    counts = {state: sum(1 for v in verdicts.values() if v == state)
              for state in ("declared", "platform-owner", "platform-super", "missing", "unknown-owner")}
    missing = {ref for ref, v in verdicts.items() if v in ("missing", "unknown-owner")}

    if args.all:
        for cls, name, desc, kind in sorted(refs_total):
            print(f"{verdicts[(cls, name, desc, kind)]:14s} {kind:7s} {cls}.{name}{desc}")

    print(f"\n{len(refs_total)} references: " +
          ", ".join(f"{state}={count}" for state, count in counts.items()))
    for cls, name, desc, kind in sorted(missing):
        print(f"  MISSING {kind} {cls}.{name}{desc}")
    return 1 if missing else 0


if __name__ == "__main__":
    sys.exit(main())
