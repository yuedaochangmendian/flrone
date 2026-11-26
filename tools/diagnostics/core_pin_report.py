#!/usr/bin/env python3
"""Report how far a Throne core pin has drifted from a ref (default: dev).

Reads the two pins that decide what kernel ships:

  * THRONE_CORE_REF from nb4a.properties (the throneproj/Throne commit CI clones)
  * SINGBOX_EXT_VERSION from buildScript/apply-core-patch.sh (the sing-box-ext
    replace line) -- reported with --ext against yuedaochangmendian/sing-box-ext

Only the standard library and `gh` are used. Every request goes through `gh api`
with HTTPS_PROXY set (the workstation's GitHub path); override or clear it with
--proxy / --no-proxy. This is a read-only report: no files are changed.

Exit codes:
  0  report printed (a pin behind its ref is normal, not an error)
  2  usage / configuration problem (missing pin, missing gh, bad ref)
  3  gh is not authenticated (or the token has no access)
  4  network / GitHub API failure (including an unknown ref or pin)

Examples:
  python tools/diagnostics/core_pin_report.py
  python tools/diagnostics/core_pin_report.py --ref dev --ext
  python tools/diagnostics/core_pin_report.py --ref e3a8bd34 --ext --json
  python tools/diagnostics/core_pin_report.py --no-proxy --ref main
"""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
THRONE_REPO = "throneproj/Throne"
EXT_REPO = "yuedaochangmendian/sing-box-ext"
DEFAULT_PROXY = "http://127.0.0.1:7890"
MAX_FILES_SHOWN = 20  # use --json for the complete list

# Ordered so the most bridge-sensitive surface is named first.
SCOPES = (
    ("core/mobile", lambda p: p.startswith("core/mobile/")),
    ("core/internal", lambda p: p.startswith("core/internal/")),
    ("core/gen/libcore.proto", lambda p: p == "core/gen/libcore.proto"),
    ("core/go.mod", lambda p: p == "core/go.mod"),
)


def die(message: str, code: int = 2) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(code)


def read_pin(path: Path, key: str) -> str:
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if line.startswith(key + "="):
            value = line[len(key) + 1 :].strip().strip('"').strip("'")
            if value:
                return value
    die(f"{key} not found in {path.relative_to(ROOT).as_posix()}")


def read_ext_pin(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    # SINGBOX_EXT_VERSION="${SINGBOX_EXT_VERSION:-v1.15.0-ext.9}"
    match = re.search(
        r'^SINGBOX_EXT_VERSION="\$\{SINGBOX_EXT_VERSION:-([^}]+)\}"',
        text,
        re.MULTILINE,
    )
    if not match:
        die(f"SINGBOX_EXT_VERSION default not found in {path.relative_to(ROOT).as_posix()}")
    return match.group(1)


class Gh:
    """Thin gh api wrapper: one env, one error classification, stdlib only."""

    def __init__(self, proxy: str | None, jobs: int):
        self.env = os.environ.copy()
        if proxy:
            self.env["HTTPS_PROXY"] = proxy
            self.env["https_proxy"] = proxy
        else:
            for key in ("HTTPS_PROXY", "https_proxy"):
                self.env.pop(key, None)
        self.jobs = jobs

    def api(self, endpoint: str, jq: str = ".") -> object:
        try:
            proc = subprocess.run(
                ["gh", "api", endpoint, "--jq", jq],
                env=self.env,
                capture_output=True,
                text=True,
                timeout=90,
            )
        except FileNotFoundError:
            die("gh CLI not found (install gh and run `gh auth login`)")
        except subprocess.TimeoutExpired:
            die(f"gh api timed out: {endpoint}", 4)
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "no detail").strip().splitlines()[-1]
            low = detail.lower()
            # Only GitHub's own verdicts count as auth failures. "proxyconnect",
            # "timeout" and similar contain no HTTP status and are network trouble.
            if re.search(r"\b(401|403|unauthorized|bad credentials)\b", low) or (
                "http " in low and re.search(r"http (401|403)\b", low)
            ):
                die(f"gh api authentication failed: {detail}", 3)
            die(f"gh api failed for {endpoint}: {detail}", 4)
        try:
            return json.loads(proc.stdout)
        except json.JSONDecodeError:
            die(f"gh api returned non-JSON for {endpoint}: {proc.stdout[:200]!r}", 4)

    def auth(self) -> None:
        """Check for a token locally (no network) so missing auth has its own code."""
        try:
            proc = subprocess.run(
                ["gh", "auth", "token"],
                env=self.env,
                capture_output=True,
                text=True,
                timeout=20,
            )
        except FileNotFoundError:
            die("gh CLI not found (install gh and run `gh auth login`)")
        except subprocess.TimeoutExpired:
            die("gh auth token lookup timed out", 4)
        if proc.returncode != 0 or not proc.stdout.strip():
            die(
                "gh is not authenticated; run `gh auth login` (or pass GH_TOKEN)",
                3,
            )

    def commit_files(self, sha: str) -> tuple[str, list[str]]:
        return sha, self.api(
            f"repos/{THRONE_REPO}/commits/{sha}",
            "[.files[]?.filename]",
        )


def short(sha: str) -> str:
    return sha[:8]


def scope_of(path: str) -> str | None:
    for name, matches in SCOPES:
        if matches(path):
            return name
    return None


def collect(gh: Gh, pin: str, ref: str) -> dict:
    # base...head: ahead = commits in ref absent from pin, behind = pin-only commits.
    compare = gh.api(
        f"repos/{THRONE_REPO}/compare/{pin}...{ref}",
        "{status: .status, ahead: .ahead_by, behind: .behind_by,"
        " commits: [.commits[] | {sha: .sha, message: (.commit.message | split(\"\\n\")[0])}],"
        " files: [.files[]? | {filename: .filename, status: .status}]}",
    )
    pin_info = gh.api(
        f"repos/{THRONE_REPO}/commits/{pin}",
        "{sha: .sha, date: .commit.committer.date,"
        " message: (.commit.message | split(\"\\n\")[0])}",
    )
    commits = compare["commits"]
    # The compare endpoint omits per-commit file lists; fetch them in parallel.
    # Authentication/network failures inside a worker still exit with their class.
    files_by_sha: dict[str, list[str]] = {}
    if commits:
        with concurrent.futures.ThreadPoolExecutor(max_workers=gh.jobs) as pool:
            for sha, files in pool.map(lambda c: gh.commit_files(c["sha"]), commits):
                files_by_sha[sha] = files

    scope_commits: dict[str, int] = {name: 0 for name, _ in SCOPES}
    scope_files: dict[str, set[str]] = {name: set() for name, _ in SCOPES}
    touching: list[str] = []
    for item in commits:
        touched = {name for name in (scope_of(f) for f in files_by_sha[item["sha"]]) if name}
        if touched:
            touching.append(item["sha"])
        for name in touched:
            scope_commits[name] += 1
    # The compare `files` array is authoritative for the aggregate file list:
    # GitHub truncates it at 300 files, so note that limit when printing.
    for entry in compare["files"]:
        name = scope_of(entry["filename"])
        if name:
            scope_files[name].add(f"{entry['status']}: {entry['filename']}")

    return {
        "pin": pin_info,
        "ref": ref,
        "status": compare["status"],
        "ahead": compare["ahead"],
        "behind": compare["behind"],
        "commits": len(commits),
        "touching": len(touching),
        "scope_commits": scope_commits,
        "scope_files": {name: sorted(files) for name, files in scope_files.items()},
        "files_truncated": len(compare["files"]) >= 300,
        "latest": commits[-1] if commits else None,
    }


def ext_report(gh: Gh, pinned: str) -> dict:
    tags = gh.api(f"repos/{EXT_REPO}/tags?per_page=100", "[.[].name]")
    latest = tags[0] if tags else None

    def key(tag: str) -> tuple[int, ...]:
        match = re.fullmatch(
            r"v?(\d+)\.(\d+)\.(\d+)(?:-ext\.(\d+))?", tag
        )
        return tuple(int(x) if x else 0 for x in match.groups()) if match else (0, 0, 0, 0)

    return {
        "pinned": pinned,
        "latest": latest,
        "behind": (key(latest) > key(pinned)) if latest else None,
        "tags_seen": len(tags),
    }


def human(report: dict, ext: dict | None) -> None:
    pin = report["pin"]
    stamp = pin["date"][:10] if pin.get("date") else "?"
    print("Throne core pin report")
    print("======================")
    print(f"pin    : {short(pin['sha'])}  {stamp}  {pin['message']}")
    delta = f"ahead {report['ahead']} / behind {report['behind']} ({report['status']})"
    print(f"vs     : {report['ref']}  {delta}")
    print(f"commits: {report['commits']} new, {report['touching']} touch a watched core path")
    if report["latest"]:
        latest = report["latest"]
        print(f"tip    : {short(latest['sha'])}  {latest['message']}")
    print()
    print("commits / files by surface (files are from the compare, capped at 300 by GitHub):")
    for name, _ in SCOPES:
        files = report["scope_files"][name]
        print(f"  {name:24s} {report['scope_commits'][name]:3d} commits  {len(files):3d} files")
    print()
    for name, _ in SCOPES:
        files = report["scope_files"][name]
        if not files:
            continue
        print(f"{name} ({len(files)}):")
        for entry in files[:MAX_FILES_SHOWN]:
            print(f"  {entry}")
        if len(files) > MAX_FILES_SHOWN:
            print(f"  ... and {len(files) - MAX_FILES_SHOWN} more (--json for all)")
    if report["files_truncated"]:
        print("! GitHub truncated the compare file list at 300; counts may be low.")
    if ext:
        print()
        print("sing-box-ext pin")
        print("---------------")
        print(f"pinned : {ext['pinned']}")
        print(f"latest : {ext['latest'] or 'no tags'}")
        if ext["latest"]:
            print("status : " + ("behind (consider bumping)" if ext["behind"] else "up to date"))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Compare the pinned Throne core with a ref (read-only, gh api)."
    )
    parser.add_argument("--ref", default="dev", help="ref to compare against (default: dev)")
    parser.add_argument(
        "--ext",
        action="store_true",
        help="also compare SINGBOX_EXT_VERSION with the latest sing-box-ext tag",
    )
    parser.add_argument(
        "--proxy",
        default=DEFAULT_PROXY,
        help=f"HTTPS proxy for gh (default: {DEFAULT_PROXY}; use --no-proxy to clear)",
    )
    parser.add_argument(
        "--no-proxy", action="store_true", help="do not set HTTPS_PROXY for gh"
    )
    parser.add_argument("--jobs", type=int, default=8, help="parallel commit-file lookups (default: 8)")
    parser.add_argument("--json", action="store_true", help="emit JSON instead of the human report")
    args = parser.parse_args()

    pin = read_pin(ROOT / "nb4a.properties", "THRONE_CORE_REF")
    ext_pin = read_ext_pin(ROOT / "buildScript" / "apply-core-patch.sh") if args.ext else None
    if args.jobs < 1 or args.jobs > 16:
        die("--jobs must be between 1 and 16")

    gh = Gh(None if args.no_proxy else args.proxy, args.jobs)
    gh.auth()
    report = collect(gh, pin, args.ref)
    ext = ext_report(gh, ext_pin) if args.ext else None
    if args.json:
        print(json.dumps({"throne": report, "ext": ext}, ensure_ascii=False, indent=2))
    else:
        human(report, ext)


if __name__ == "__main__":
    main()
