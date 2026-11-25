#!/usr/bin/env python3
"""Audit that CI/release path filters still track every Gradle module.

A module rename (bboxmodel -> flronemodel in 6e5e0d0e) left the old name in
both workflow filters, so a PR touching only the renamed module's sources no
longer triggered any build. This check reads the same files the workflows do
and fails when a module included by settings.gradle.kts is absent from either
filter. It uses only the standard library: CI's python3 has no PyYAML.

Usage:
    python3 tools/diagnostics/workflow_path_audit.py
    python3 tools/diagnostics/workflow_path_audit.py --self-test
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CI = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE = ROOT / ".github" / "workflows" / "release.yml"
SETTINGS = ROOT / "settings.gradle.kts"

INCLUDE_RE = re.compile(r'^\s*include\s*\(\s*["\']:([^"\']+)["\']\s*\)', re.M)
PROJECT_DIR_RE = re.compile(
    r'^\s*project\s*\(\s*["\']:([^"\']+)["\']\s*\)\s*\.\s*projectDir\s*=\s*file\s*\(\s*["\']([^"\']+)["\']\s*\)',
    re.M,
)
TOKEN_RE = re.compile(r'[A-Za-z0-9_.\-]+(?:/[A-Za-z0-9_.\-*]+)*')


def error(message):
    print(f"::error::{message}")
    return 1


def modules(settings_text):
    """Map Gradle module names to their source path (first path segment for dirs)."""
    found = {name: name for name in INCLUDE_RE.findall(settings_text)}
    for name, path in PROJECT_DIR_RE.findall(settings_text):
        if name in found:
            found[name] = path
    return found


def list_under(text, key):
    """Return YAML list items under the first `key:` line, by indentation."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not re.match(rf'^\s*{re.escape(key)}:\s*$', line):
            continue
        indent = len(line) - len(line.lstrip())
        items = []
        for follow in lines[i + 1 :]:
            if not follow.strip():
                continue
            cur = len(follow) - len(follow.lstrip())
            if cur <= indent:
                break
            item = re.match(r'^\s*-\s*(.+?)\s*$', follow)
            if item:
                items.append(item.group(1))
        return items
    return []


def ci_filter_dirs(ci_text):
    """Top-level directories covered by ci.yml's `code` paths-filter entry."""
    return {dir_of(p) for p in list_under(ci_text, "code")}


def release_case_dirs(release_text):
    """Top-level directories covered by release.yml's app-change case arm."""
    lines = release_text.splitlines()
    start = next((i for i, l in enumerate(lines) if 'case "$file" in' in l), None)
    if start is None:
        return set()
    end = next((i for i, l in enumerate(lines[start:], start) if "APP_CHANGED=true" in l), start)
    block = "\n".join(lines[start + 1 : end]).replace("\\", " ")
    return {dir_of(t) for t in TOKEN_RE.findall(block)}


def dir_of(pattern):
    """Normalize a glob ('app/**', 'app/*', 'gradle.properties') to its first segment."""
    p = pattern.strip().strip("'\"")
    p = re.sub(r"/\*\*?$", "", p)
    return p.split("/")[0]


def missing(settings_text, ci_text, release_text):
    ci_dirs, rel_dirs = ci_filter_dirs(ci_text), release_case_dirs(release_text)
    out = set()
    for name, path in modules(settings_text).items():
        directory = dir_of(path)
        for label, covered in (("ci.yml", ci_dirs), ("release.yml", rel_dirs)):
            if directory not in covered:
                out.add(f"{name} ({directory}) missing from {label}")
    return out


def self_test():
    settings = (
        'include(":app")\n'
        'include(":flronemodel")\n'
        'include(":core")\n'
        'project(":core").projectDir = file("android/core")\n'
    )
    ci = "          filters: |\n            code:\n              - 'app/**'\n              - 'flronemodel/**'\n              - 'android/**'\n"
    release = (
        '            case "$file" in\n'
        "              app/*|flronemodel/*|android/*)\n"
        "                APP_CHANGED=true\n"
    )
    if missing(settings, ci, release):
        raise AssertionError("self-test: healthy fixtures were reported as broken")
    broken_ci = ci.replace("              - 'flronemodel/**'\n", "")
    broken_release = release.replace("flronemodel/*|", "")
    found = missing(settings, broken_ci, broken_release)
    if not any("flronemodel" in f and "ci.yml" in f for f in found):
        raise AssertionError("self-test: removal from ci.yml was not detected")
    if not any("flronemodel" in f and "release.yml" in f for f in found):
        raise AssertionError("self-test: removal from release.yml was not detected")
    print("workflow_path_audit self-test: ok")


def main():
    if "--self-test" in sys.argv[1:]:
        self_test()
        return 0
    texts = []
    for path in (SETTINGS, CI, RELEASE):
        if not path.is_file():
            return error(f"missing input file: {path}")
        texts.append(path.read_text(encoding="utf-8"))
    problems = sorted(missing(*texts))
    for problem in problems:
        error(f"workflow path filter out of date: {problem}")
    if problems:
        return 1
    print(f"workflow path filters cover all {len(modules(texts[0]))} Gradle modules")
    return 0


if __name__ == "__main__":
    sys.exit(main())
