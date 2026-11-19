#!/usr/bin/env python3
"""Verify settings_schema.go matches SettingsSchema.kt (ADR 0002, phase 3e).

Runs the generator in --check mode and additionally diffs the key set against
the Kotlin source so a schema edit that forgets regeneration fails loudly.

Usage:
    python tools/diagnostics/settings_contract.py
"""

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
GENERATOR = ROOT / "tools" / "gen_settings_schema.py"
SCHEMA_KT = ROOT / "app/src/main/java/io/flrone/bridge/SettingsSchema.kt"
SCHEMA_GO = ROOT / "buildScript/core-patch/core/mobile/settings_schema.go"

BRIDGE_KEY = re.compile(
    r'(?:boolEntry|intEntry|textEntry|listEntry)\(\s*"([A-Za-z0-9_]+)"'
    r'|bridgeKey = "([A-Za-z0-9_]+)"'
    r'|Entry\(\s*"([A-Za-z0-9_]+)"'
)
GO_KEY = re.compile(r'bridgeKey: "([A-Za-z0-9_]+)"')
DART_UI_ONLY = ROOT / "flutter/lib/services/ui_overlay.dart"
UI_BLOCK = re.compile(r"val UI_ONLY_KEYS: Set<String> = setOf\((.*?)\n\)", re.S)
DART_UI_BLOCK = re.compile(r"const Set<String> uiOnlyKeys = \{(.*?)\};", re.S)
QUOTED = re.compile(r'"([A-Za-z0-9_]+)"')
DART_QUOTED = re.compile(r"'([A-Za-z0-9_]+)'")


def ui_only_keys() -> tuple[set[str], set[str]]:
    """ADR 0005 phase 2: the Kotlin and Dart UI-only overlay sets must agree."""
    kotlin: set[str] = set()
    dart: set[str] = set()
    if SCHEMA_KT.exists():
        m = UI_BLOCK.search(SCHEMA_KT.read_text(encoding="utf-8"))
        if m:
            kotlin = set(QUOTED.findall(m.group(1)))
    if DART_UI_ONLY.exists():
        m = DART_UI_BLOCK.search(DART_UI_ONLY.read_text(encoding="utf-8"))
        if m:
            dart = set(DART_QUOTED.findall(m.group(1)))
    return kotlin, dart


def main() -> int:
    problems = []
    kt_keys: set[str] = set()
    go_keys: set[str] = set()

    # 1. Run the generator's --check mode.
    result = subprocess.run(
        [sys.executable, str(GENERATOR), "--check"],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        problems.append(f"generator --check failed: {result.stderr.strip()}")

    # 2. Verify the key sets match.
    if SCHEMA_KT.exists() and SCHEMA_GO.exists():
        for m in BRIDGE_KEY.finditer(SCHEMA_KT.read_text(encoding="utf-8")):
            key = m.group(1) or m.group(2) or m.group(3)
            if key:
                kt_keys.add(key)

        go_keys = set(GO_KEY.findall(SCHEMA_GO.read_text(encoding="utf-8")))

        for key in sorted(kt_keys - go_keys):
            problems.append(f"key {key!r} in SettingsSchema.kt but not in settings_schema.go")
        for key in sorted(go_keys - kt_keys):
            problems.append(f"key {key!r} in settings_schema.go but not in SettingsSchema.kt")
    else:
        problems.append(f"missing file: schema_kt={SCHEMA_KT.exists()} schema_go={SCHEMA_GO.exists()}")

    # 3. ADR 0005 phase 2: the UI-only overlay key set has one source of truth in
    # Kotlin (SettingsSchema.UI_ONLY_KEYS) and one Dart mirror (ui_overlay.dart).
    kotlin_ui, dart_ui = ui_only_keys()
    if not kotlin_ui:
        problems.append("UI_ONLY_KEYS missing or empty in SettingsSchema.kt")
    if not dart_ui:
        problems.append("uiOnlyKeys missing or empty in flutter/lib/services/ui_overlay.dart")
    for key in sorted(kotlin_ui - dart_ui):
        problems.append(f"UI-only key {key!r} in Kotlin but not in Dart uiOnlyKeys")
    for key in sorted(dart_ui - kotlin_ui):
        problems.append(f"UI-only key {key!r} in Dart uiOnlyKeys but not in Kotlin")
    # An overlay key must never also be a Throne schema key (two writers).
    overlap = (kotlin_ui & kt_keys) if SCHEMA_KT.exists() else set()
    for key in sorted(overlap):
        problems.append(f"UI-only key {key!r} is also a ThroneSettings bridge key (two writers)")

    if problems:
        for p in problems:
            print(f"::error::{p}")
        return 1

    print(f"settings contract OK: {len(go_keys) if SCHEMA_GO.exists() else '?'} keys agree")
    return 0


if __name__ == "__main__":
    sys.exit(main())
