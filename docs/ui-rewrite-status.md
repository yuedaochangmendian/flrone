# Flutter UI rewrite status

Baseline: `flutter/lib` UI was removed and rebuilt against FlClash
`afe71360` (2026-11-20), with `prism_ui` 0.1.2 vendored as
`flutter/plugins/prism_ui`.

## Rebuilt

| Surface | Files |
| --- | --- |
| App entry, theme, localization, navigation | `flutter/lib/main.dart`, `flutter/lib/app/` |
| Shell (desktop sidebar / mobile dock, lazy tabs) | `flutter/lib/pages/shell.dart` |
| Dashboard (status morph, traffic, mode, profile, groups, memory, LAN) | `flutter/lib/pages/dashboard.dart`, `flutter/lib/components/` |
| Proxies (groups, node grid, selection, delay, test) | `flutter/lib/pages/proxies.dart` |
| Profiles (select, sync, add/edit/delete) | `flutter/lib/pages/profiles.dart` |
| Requests (connections, close, detail) | `flutter/lib/pages/requests.dart` |
| Logs (kernel/logcat/previous, follow, filter, clear) | `flutter/lib/pages/logs.dart` |
| Routes (list, current, create/edit/delete) | `flutter/lib/pages/routes.dart` |
| Tools (general, appearance, network, diagnostics) | `flutter/lib/pages/tools.dart` |
| Advanced settings (General/Inbound/TUN/DNS/Core/Notification/WARP/Testing/Node presets) | `flutter/lib/app/settings_catalog.dart`, `flutter/lib/pages/settings_pages.dart` |
| Backup and restore (local + WebDAV) | `flutter/lib/pages/backup.dart` |
| Access control (per-app proxy/bypass) | `flutter/lib/pages/access.dart` |
| Speed test (kernel test session) | `flutter/lib/pages/speed_test.dart` |
| Connectivity probe | `flutter/lib/pages/connectivity.dart` |
| Tailscale / USB-IP endpoints and Taildrop | `flutter/lib/pages/endpoints.dart` |
| Terminal (Tailscale SSH + Ghostty host view) | `flutter/lib/pages/terminal.dart` |
| Node JSON editor | `flutter/lib/pages/profiles.dart` (`NodeJsonPage`) |
| Route rule JSON editor | `flutter/lib/pages/routes.dart` (`RouteRulesPage`) |
| FlClash app-level UI | `flutter/lib/ui/` |
| JSON schema engine (moved out of UI) | `flutter/lib/json/` |

## Preserved

`flutter/lib/box.dart`, `box_api.dart`, `capabilities.dart`,
`service_entry.dart`, `core/`, `data/`, `services/`, `common/`,
`providers/`, Android host and bridge code.

## Removed

The old `flutter/lib/pages/`, `flutter/lib/components/`, the old vendored
`flutter/lib/ui/`, `widgets.dart`, `theme_settings.dart`, `l10n.dart`, the
old `main.dart`, and the old UI test tree.

## Still to rebuild

- Typed protocol-specific node forms (the raw JSON editor is in place)
- OpenConnect / OpenVPN challenge-authentication pages
- USB attach picker and device transfer details
- Route import, bundled preset download and rule-set catalog picker
- Group settings (subscription filters, front/landing proxy, sort options)
- Profile details, reports, capture domains and terminal appearance settings

## Verification

```powershell
cd flutter
flutter analyze --fatal-infos
flutter test
flutter build bundle --debug
```

The Android APK/AAR build needs the documented module-scaffold step
(`flutter create --template=module` outside this repository) because the
checked-in `flutter/android` directory has no app Gradle project.
