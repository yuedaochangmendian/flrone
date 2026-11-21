"""settings audit diagnostic for the B-box UI settings surface.

Three-way diff of what Throne stores, what the bridge exposes and what the UI edits:
  - store keys: SettingsRegistry.kt (`bool|int|long|string|oneOf|stringList("key" ...)`) and the
    `Key` object in Constants.kt (the camelCase keys DataStore binds through ktx delegates)
  - bridge keys: SettingsSchema.kt (`boolEntry|intEntry|textEntry|listEntry("key" ...)` and
    `Entry(bridgeKey = "key" ...)`) plus the RESET_ROW_ALIASES store-row map
  - UI keys: flutter/lib/pages/throne.dart (`Setting*(<title>, 'key' ...)`) and the keys each
    page's restoreDefaultsAction resets

A store key is covered when it is the row of some schema entry (camelToSnake(key), the key
itself, or an alias). A bridge key is covered when a Setting* control edits it. A UI key is
covered when a schema entry backs it.

The keys no column claims fall in three non-actionable books, kept apart so the diff only names
what batch work remains: NON_SETTING (runtime state, managed by code), SHELL_OWNED (a user
setting the B-box shell edits through its own store or flow, not the Throne settings surface) and
RESTORE_ONLY (a key no settings page on either side ever edits; it travels through restores).

Run from the repository root:
    uv run tools/diagnostics/settings_audit.py [--summary]

Exit code 0 when every column is covered, 1 when any gap is listed.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
REGISTRY = REPO_ROOT / "app/src/main/java/io/nekohasekai/sagernet/database/SettingsRegistry.kt"
CONSTANTS = REPO_ROOT / "app/src/main/java/io/nekohasekai/sagernet/Constants.kt"
SCHEMA = REPO_ROOT / "app/src/main/java/io/flrone/bridge/SettingsSchema.kt"
THRONE_DART = REPO_ROOT / "flutter/lib/pages/throne.dart"

STORE_CALL = re.compile(r'(?:bool|int|long|string|oneOf|stringList)\(\s*"([A-Za-z0-9_]+)"')
KEY_CONST = re.compile(r'const val [A-Z0-9_]+ = "([A-Za-z0-9_]+)"')
BRIDGE_KEY = re.compile(
    r'(?:boolEntry|intEntry|textEntry|listEntry)\(\s*"([A-Za-z0-9_]+)"'
    r'|bridgeKey = "([A-Za-z0-9_]+)"'
    r'|Entry\(\s*"([A-Za-z0-9_]+)"'
)
ALIAS_ROW = re.compile(r'"([A-Za-z0-9_]+)"\s+to\s+"([A-Za-z0-9_]+)"')
_Q = r"[\"']"
UI_KEY = re.compile(r"Setting(?:Toggle|Text|Number|Lines|DnsServer|Json)\(\s*" + _Q + r"[^\"']*" + _Q + r"\s*,\s*" + _Q + r"([A-Za-z0-9_]+)" + _Q)
UI_CHOICE = re.compile(r"SettingChoice<[^>]*>\(\s*" + _Q + r"[^\"']*" + _Q + r"\s*,\s*" + _Q + r"([A-Za-z0-9_]+)" + _Q)
# settings.dart's own switch primitive, which reads box.settings and writes box.setSetting.
UI_NATIVE = re.compile(r"NativeToggle\(\s*" + _Q + r"[^\"']*" + _Q + r"\s*,\s*" + _Q + r"([A-Za-z0-9_]+)" + _Q)
UI_SET = re.compile(r"setSetting\(\s*" + _Q + r"([A-Za-z0-9_]+)" + _Q)
UI_READ = re.compile(r"settings\[\s*" + _Q + r"([A-Za-z0-9_]+)" + _Q + r"\s*\]")
# The rebuilt settings surface is catalog-driven: SettingEntry.toggle('key', ...)
# and its siblings carry the same key-first shape as the old Setting* widgets.
UI_ENTRY = re.compile(
    r"SettingEntry\.(?:toggle|text|integer|lines|options)\(\s*"
    + _Q
    + r"([A-Za-z0-9_]+)"
    + _Q
)
RESTORE_KEYS = re.compile(r"restoreDefaultsAction\(\s*context\s*,\s*const\s*\[([^\]]*)\]")
RESTORE_KEY_ITEM = re.compile(r"[\"']([A-Za-z0-9_]+)[\"']")

# Store keys that are runtime state rather than user settings: they carry a selection, a
# history or a service status and are managed by code, never edited on a settings page.
# They are listed here so the diff only names actionable gaps.
NON_SETTING = {
    "current_group",            # GroupRepo's selected group
    "current_route_id",         # the route profile in use
    "direct_dns_history",       # DnsServerHistory input log
    "remote_dns_history",
    "route_auto_update_last",   # update timestamps
    "sub_auto_update_last",
    "profileId",                # DataStore.selectedProxy: the started node
    "profileCurrent",           # service bookkeeping
    "profileDirty",
    "profileGroup",
    "runningProfiles",
    "runningRoute",
    "serviceError",             # last start failure, shown as status
    "serviceErrorDns",
    "serviceErrorGeo",
    "serviceErrorRuleSets",
    "deviceId",                 # device identity for subscriptions
    "deviceName",
    "hwidFallback",
    "batteryPromptShown",       # one-shot prompts
    "previewHintDismissedVersion",
    "wifiPermissionAsked",
    "updateSkippedVersionCode",
    "resumeAfterUpdate",
    "logExportRedact",          # the log export dialog's checkbox state
    "subscriptionLink",         # share-sheet scratch
    "groupName",                # group form scratch
    "groupType",
    "warp_amnezia_packets",     # generated with the WARP identity, never edited
    "warp_masque_ifc_addrs",    # written by the MASQUE registration, never edited
    "proxy",                    # Key names shared with intents, not settings
    "vpn",
    "serverConfig",
}

# ADR 0005 phase 2: the UI-only overlay set lives in SettingsSchema.UI_ONLY_KEYS
# (the code-side single source of truth). Derived below so this audit cannot drift
# from the Kotlin/Dart authority. The four font keys are the former SETTINGS_KEY
# overlay; the rest are shell presentation keys in the preferences document.
def _ui_only_keys() -> set[str]:
    text = SCHEMA.read_text(encoding="utf-8")
    m = re.search(r"val UI_ONLY_KEYS: Set<String> = setOf\((.*?)\n\)", text, re.S)
    return set(re.findall(r'"([A-Za-z0-9_]+)"', m.group(1))) if m else set()

OVERLAY_SETTING = _ui_only_keys()

# User settings the B-box shell edits through its own store or its own flow rather than the
# Throne settings surface: the appearance page keeps its own theme and language, the B-box list
# presentation replaces the old layout options, and the backup page owns the WebDAV account.
# Since ADR 0005 phase 1 that account is a Dart-owned preferences document value mirrored into
# these Room rows for compatibility; the webdav.get/set channels are gone.
SHELL_OWNED = OVERLAY_SETTING | {
    # Keys that are still Dart-owned but are not in the settings overlay (the
    # traffic graph presentation is not configurable, and the WebDAV account is
    # a Dart document value mirrored into Room for the phase-4 container codec).
    "traffic_graph_hidden",  # the B-box dashboard's sparklines are not configurable
    "traffic_graph_hidden_dirs",
    "traffic_graph_range",
    "traffic_graph_smooth",
    "traffic_graph_markers",
    "webdavServer",          # Dart account store, mirrored here for phase-4 compat
    "webdavUsername",
    "webdavPassword",
    "webdavPath",
}

# Keys no settings page on either side ever edits: they travel through .thrbackup restores and
# desktop sync, and the code reads them where it needs them.
RESTORE_ONLY = {
    "appTLSVersion",         # Nets.kt restricts the app's own TLS; no page surfaces it
    "notificationActions",   # ServiceNotification picks its buttons from it
    "notificationTitlePrefix",  # legacy; folded into the title template on read, never edited now
    "show_config_security",  # ProfileRowHolder reads it for its display flags
    "xray_vless_preference", # SettingsMapper reads it when the importer builds a VLESS node
    "xray_geoip_url",        # XrayGeoAssets reads it when a config needs geoip.dat
    "xray_geosite_url",      # XrayGeoAssets reads it when a config needs geosite.dat
}

# Keys that deliberately have no settings control on Android. They stay valid bridge keys, so
# restores and old installs keep working.
ANDROID_OMITTED = {
    # The log screen's recording-level control owns logLevel, and these three are host
    # defaults now: the Core page's Logging and Xray groups were removed on purpose.
    "xrayLogLevel",
    "logBufSize",
    "xrayVlessPreference",
    # The WARP registration UI (WarpPage) died with the registration chain (PR #179):
    # these stay valid bridge keys so restores round-trip and the config generator
    # can still build the WARP outbound from an old install's values.
    "enableWarp",
    "warpApiHosts",
    "warpEndpoint",
    "warpIfcAddrs",
    "warpMasqueEndpoint",
    "warpMasqueHttpMode",
    "warpMasquePeerPublicKey",
    "warpMasquePrivateKey",
    "warpMasqueSni",
    "warpMode",
    "warpPrivateKey",
    "warpPublicKey",
    "warpReserved",
    "warpTosAccepted",
}

# Every book the three-way diff consults before it names a store key as a gap.
NON_ACTIONABLE = NON_SETTING | SHELL_OWNED | RESTORE_ONLY


def camel_to_snake(name: str) -> str:
    return re.sub(r"(?<!^)(?=[A-Z])", "_", name).lower()


def go_schema_keys() -> set[str]:
    """Bridge keys from the generated settings_schema.go."""
    go_file = REPO_ROOT / "buildScript/core-patch/core/mobile/settings_schema.go"
    if not go_file.exists():
        return set()
    return set(re.findall(r'bridgeKey: "([A-Za-z0-9_]+)"', go_file.read_text(encoding="utf-8")))


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def parse_store_keys() -> tuple[set[str], set[str]]:
    registry = set(STORE_CALL.findall(read(REGISTRY)))
    key_object = read(CONSTANTS)
    key_block = key_object[key_object.index("object Key {"):]
    # Stop at the object's closing brace; later top-level `const val` lines are other constants.
    end = key_block.index("\n}")
    key_block = key_block[:end]
    constants = set(KEY_CONST.findall(key_block))
    return registry, constants


def parse_schema() -> tuple[set[str], dict[str, set[str]]]:
    text = read(SCHEMA)
    keys = {a or b or c for a, b, c in BRIDGE_KEY.findall(text)}
    keys.discard("")
    alias_block = text[text.index("RESET_ROW_ALIASES"):]
    alias_block = alias_block[: alias_block.index(")")]
    aliases: dict[str, set[str]] = {}
    for key, row in ALIAS_ROW.findall(alias_block):
        aliases.setdefault(key, set()).add(row)
    return keys, aliases


def parse_ui() -> tuple[set[str], set[str]]:
    # Consumption is spread over the pages: the Setting* primitives edit by key, and the
    # custom sheets (access, settings) call setSetting / read settings by key directly.
    controls: set[str] = set()
    restored: set[str] = set()
    for path in (REPO_ROOT / "flutter/lib").rglob("*.dart"):
        text = path.read_text(encoding="utf-8")
        controls |= set(UI_KEY.findall(text))
        controls |= set(UI_CHOICE.findall(text))
        controls |= set(UI_NATIVE.findall(text))
        controls |= set(UI_ENTRY.findall(text))
        controls |= set(UI_SET.findall(text))
        controls |= set(UI_READ.findall(text))
        for block in RESTORE_KEYS.findall(text):
            restored |= set(RESTORE_KEY_ITEM.findall(block))
    return controls, restored


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--summary", action="store_true", help="counts only")
    args = parser.parse_args()

    registry, constants = parse_store_keys()
    bridge, aliases = parse_schema()
    ui_controls, ui_restored = parse_ui()

    # Every store row a schema entry covers, however the row is named.
    covered_rows: set[str] = set()
    for key in bridge:
        covered_rows.add(key)
        covered_rows.add(camel_to_snake(key))
        covered_rows |= aliases.get(key, set())

    registry_missing = sorted(key for key in registry if key not in covered_rows and key not in NON_ACTIONABLE)
    constants_missing = sorted(key for key in constants if key not in covered_rows and key not in NON_ACTIONABLE)
    bridge_missing_ui = sorted(
        key for key in bridge
        if key not in ui_controls and key not in NON_SETTING and key not in ANDROID_OMITTED)
    ui_missing_bridge = sorted(
        key for key in ui_controls if key not in bridge and key not in NON_SETTING and key not in OVERLAY_SETTING)
    restored_missing_control = sorted(key for key in ui_restored if key not in ui_controls)

    # Go schema column: the generated settings_schema.go must cover the same bridge keys.
    go_missing = sorted(key for key in bridge if key not in go_schema_keys())
    go_extra = sorted(key for key in go_schema_keys() if key not in bridge)

    gaps = {
        "registry store keys with no schema entry": registry_missing,
        "Key constants with no schema entry": constants_missing,
        "schema bridge keys with no Setting* control": bridge_missing_ui,
        "Setting* keys with no schema entry": ui_missing_bridge,
        "restoreDefaults keys with no control on the page": restored_missing_control,
        "schema keys missing from Go settings_schema.go": go_missing,
        "Go settings_schema.go keys not in Kotlin schema": go_extra,
    }

    if args.summary:
        for title, items in gaps.items():
            print(f"{len(items):4d}  {title}")
    else:
        for title, items in gaps.items():
            print(f"## {title} ({len(items)})")
            for item in items:
                print(f"  - {item}")
            print()
    return 1 if any(gaps.values()) else 0


if __name__ == "__main__":
    sys.exit(main())
