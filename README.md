# Flrone

[![CI](https://github.com/yuedaochangmendian/throne-flclash-ui/actions/workflows/ci.yml/badge.svg)](https://github.com/yuedaochangmendian/throne-flclash-ui/actions/workflows/ci.yml) [![Latest release](https://img.shields.io/github/v/release/yuedaochangmendian/throne-flclash-ui)](https://github.com/yuedaochangmendian/throne-flclash-ui/releases) [![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

Other languages: [简体中文](readme/README_zh.md) · [English (short)](readme/README_en.md)

An Android GUI proxy utility on the [sing-box](https://github.com/yuedaochangmendian/sing-box-ext) core: Throne's engine with a
fully rebuilt Flutter interface on the prism UI layer FlClash's dev branch uses. Supports Android 7.0 (API 24) and newer, including
Android TV.

## What this repository is

A downstream distribution of [throneproj/ThroneForAndroid](https://github.com/throneproj/ThroneForAndroid): the
core (sing-box, protocol and configuration surface) is pinned per release to Throne's own (`THRONE_CORE_REF`
in `nb4a.properties`) and built by CI, while everything above it — the interface, the bridge layer, the release
line — is owned here.

- **One interface**: the Flutter UI is the app's only screen as of 3.0.0; the legacy Fragment interface retired
  entirely (the VPN notification, share/open intents and the quick settings tile all land in it).
- **Xray is no longer supported**: the Xray core, the Xray-shaped VLESS profile type, the Xray multiplex
  settings, the geo data files and the XDRIVE transport are gone. VLESS — including XHTTP, mKCP and VLESS
  Encryption — runs on sing-box.
- **Kernel is the maintained fork**: sing-box comes from [yuedaochangmendian/sing-box-ext](https://github.com/yuedaochangmendian/sing-box-ext) — Throneproj's base plus VLESS Encryption, XHTTP, mKCP and REALITY — pinned by tag in `buildScript/apply-core-patch.sh` and built from source by CI. The Throne mobile bridge is still pinned per release by `THRONE_CORE_REF`; upstream core releases underpin the fork.
- Upstream's own releases, docs ([throneproj.github.io](https://throneproj.github.io)) and donation options live in
  the [upstream repository](https://github.com/throneproj/ThroneForAndroid).

### Install and update

- Releases ship three ABI splits (arm64-v8a, armeabi-v7a, x86_64) with SHA256SUMS from
  [GitHub Releases](https://github.com/yuedaochangmendian/throne-flclash-ui/releases); the in-app update check
  verifies size and SHA-256 before offering the installer.
- Releases from v2.0.0 on are signed with a key that Android refuses to install over a 1.x release (signature
  conflict): uninstall the old release first and import subscriptions again.
- **Preview builds (`-pre.N`) are the default delivery channel.** They are built and signed on the maintainer's
  workstation with `tools/local-build/local-release.sh` and uploaded as GitHub prereleases; merging to `main` does
  not run CI or any build. Their `versionCode` is below the stable release of the same version
  (`X.Y.Z` stable is `*999`, previews are `*001..*998`), so Android refuses to install one over that stable release
  (`INSTALL_FAILED_VERSION_DOWNGRADE`); going from stable back to a preview requires uninstalling first. The in-app
  updater only follows `releases/latest`, which a preview never touches — see `docs/release-runbook.md` for the
  promotion path.

## Features

- Groups and subscriptions that work like Throne desktop: per-group subscription options (filters, clean-up, URL test after an update), front / landing proxy, HWID headers, scheduled updates with change reports
- **Subscriptions name and describe themselves**: a name is optional (the server's `Profile-Title`, then the URL host), and every card shows the remaining quota and the expiry — or `Permanent` when the provider did not date it
- **Hand-imported single nodes** live on their own page, apart from the profile cards; a single-node import lands there, and the selected node survives a restart
- **Network toolbox**: a Bettbox-style card grid for speed tests, traffic statistics, connectivity, node-test settings and exit detection
- **REALITY** on the extended kernel, including the hybrid X25519MLKEM768 key share for uTLS fingerprints that predate ML-KEM
- About: tapping the version badge checks for updates and the GPL-3.0 badge opens the licence page
- Backups in the desktop's `.thrbackup` format, restorable on either side: save, share or sync over WebDAV
- Route profiles shared with desktop, preloaded from [routeprofiles](https://github.com/throneproj/routeprofiles), plus Android-only rule conditions: apps, Wi-Fi network (SSID / BSSID), network type and metered networks
- Auto Selector profiles that keep the best server of one or more groups ranked and switch automatically
- Cloudflare WARP: a built-in WARP mode for routing
- URL, IP / country and speed tests, with a bulk-test panel (live progress, latency histogram, fastest servers, sort / remove unavailable / connect to fastest)
- Connectivity test: the home card and full page probe Bettbox's service list (AI, streaming, China direct, social, developer, gaming, crypto) through the running exit, with latency, status grouping and per-service retry
- The sing-box dashboard built in (live traffic, connections, logs)
- The home status card shows the exit's region as a regional-indicator emoji badge, with its location and carrier beside the address and run time / location / operator along the bottom; tapping the badge re-checks the exit IP, and with the service stopped it reports the address the phone itself uses
- The Log screen is FlClash's own log view: one export action, an empty state, a scrollbar that names the record at the thumb, and a list that stops following the newest line once you scroll away; each record is split into what it says and where it came from, and the filter action sets the recording level for both tails
- JSON editor with sing-box-aware formatting
- Home-screen widgets, a quick settings tile, and server switching from the notification
- Android TV: launcher banner, D-pad navigation, previous / next server

## Supported protocols

- SOCKS
- HTTP(S)
- Shadowsocks
- Trojan
- VMess
- VLESS
- TUIC
- Hysteria
- Hysteria2
- AnyTLS
- Mieru
- Snell
- NaïveProxy
- Juicity
- TrustTunnel
- ShadowTLS
- Wireguard
- AmneziaWG
- MASQUE
- SSH
- OpenVPN/OpenConnect
- Custom Outbound
- Custom Config
- Chaining outbounds

## Subscription Formats

Various formats are supported, including share links, various JSON representation of Sing-box configs, and v2rayN link format as well as limited support for Shadowsocks and Clash formats. Only the outbounds (servers) of a subscription are imported; its routing rules are ignored.

Deeplinks are also supported, read the [documentation](https://throneproj.github.io/advanced/deeplinks/) for more information.

## Development

- **CI** (`ci.yml`, every push): Kotlin unit tests + debug build (with the c-shared `libthrone.so` built from the
  pinned upstream ref by `buildScript/build-cshared.sh`; no gomobile/AAR), the Flutter module's
  `analyze --fatal-infos` + widget tests, a
  [channel contract audit](tools/diagnostics/channel_audit.py) that fails when a bridge method or event loses an
  end, and a scan proving the freshly built Flutter AAR only calls APIs the pinned kotlin-stdlib/coroutines
  provide. Merging to `main` does not run CI or a build.
- **Releases**: prereleases are built and uploaded locally
  (`tools/local-build/local-release.sh`, which builds and uploads by default; `--build-only` keeps artifacts local): tag `vX.Y.Z-pre.N`, notes from the matching `CHANGELOG.md`
  section, no `throne-update.json`, never `releases/latest`; `N` advances automatically and `VERSION_NAME` is
  bumped only to start a new version line. A stable release is an explicit maintainer promotion via
  `stable-release.yml`, the only release path on GitHub: it calls `ci.yml` as a gate on the target commit, then
  rebuilds with `channel=stable`, tags `vX.Y.Z`, publishes with `prerelease=false` and `--latest`, and adds
  `throne-update.json` (versionCode `*1000+999`).
- **Specs**: `openspec/specs/` holds the governing specifications; changes go through `openspec/changes/`.
- **Design documents**: [docs/bbox-bridge.md](docs/bbox-bridge.md) (the bridge layer),
  [docs/bbox-flutter.md](docs/bbox-flutter.md) (the Flutter module), [docs/device-checklist.md](docs/device-checklist.md)
  (the pre-release device gate), [docs/prism-upstream.md](docs/prism-upstream.md) (the vendored Prism UI
  baseline and drift policy), [docs/roadmap.md](docs/roadmap.md) (where the project is heading).
- `Capabilities.kt` is the single source of truth for which B-box-only features exist; the bridge documents
  every method and event it serves.
- **Contributing**: see [CONTRIBUTING.md](CONTRIBUTING.md) for the development environment, local verification
  commands and the branch / pull-request workflow.

## Community / Feedback

Please use [GitHub Issues](https://github.com/yuedaochangmendian/throne-flclash-ui/issues) to report bugs, request
features or ask questions; the issue templates there ask for exported logs and reproduction steps. For vulnerabilities
that must not be disclosed in public, follow [SECURITY.md](SECURITY.md) instead.

## Credits

- [yuedaochangmendian/sing-box-ext](https://github.com/yuedaochangmendian/sing-box-ext), this app's kernel: Throneproj's sing-box base plus VLESS encryption, XHTTP, mKCP and REALITY
- [throneproj/sing-box](https://github.com/throneproj/sing-box), a fork of [SagerNet/sing-box](https://github.com/SagerNet/sing-box)
- [throneproj/ThroneForAndroid](https://github.com/throneproj/ThroneForAndroid), the engine and data model this project follows

Android GUI:

- [MatsuriDayo/NekoBoxForAndroid](https://github.com/MatsuriDayo/NekoBoxForAndroid)
- [SagerNet/SagerNet](https://github.com/SagerNet/SagerNet)
- [shadowsocks/shadowsocks-android](https://github.com/shadowsocks/shadowsocks-android)
- [giturass/B-box](https://github.com/giturass/B-box), the interface this UI was adapted from
- [appshubcc/Bettbox](https://github.com/appshubcc/Bettbox), the architecture and data-plane reference this port follows

## FAQ

**How does this differ from Throne or NekoBox for Android?** <br/>
It started as a NekoBox for Android fork; v2.0.0 replaced its core and data model with Throne desktop's. This
distribution then replaced Throne's own interface with the Flutter one described above — same engine, same
profile types, share links, route profiles and backup format, one modern screen.

**Where are the downloadable route profiles/rulesets coming from?**<br/>
They are located at the [routeprofiles](https://github.com/throneproj/routeprofiles) repository, the same one Throne desktop uses.

**Why are some servers skipped when I import a link or a subscription?**<br/>
As on desktop, Extra Core, Chain and Auto Selector profiles are never imported from links, subscriptions or shared route profiles; create them in the app instead. Nodes the app cannot run are skipped too, and the import reports what was left out.
