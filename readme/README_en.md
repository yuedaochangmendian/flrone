# Flrone — short overview

> The full English README is at the repository root: [README.md](../README.md). 简体中文版见 [README_zh.md](README_zh.md).

## What this is

Flrone is an Android GUI proxy utility built on the [sing-box](https://github.com/yuedaochangmendian/sing-box-ext) core, using Throne's engine and data model behind a fully rebuilt Flutter interface adapted from FlClash's prism UI layer / the B-box interface. It supports Android 7.0 (API 24) and newer, including Android TV, and is distributed under GPL-3.0. Xray is no longer supported: VLESS (including XHTTP, mKCP and VLESS Encryption) runs on sing-box.

## Relation to upstream Throne

This repository is a downstream distribution of [throneproj/ThroneForAndroid](https://github.com/throneproj/ThroneForAndroid). The mobile bridge is pinned per release via `THRONE_CORE_REF` in `nb4a.properties`; sing-box itself is the maintained fork [yuedaochangmendian/sing-box-ext](https://github.com/yuedaochangmendian/sing-box-ext) (Throneproj's base plus VLESS Encryption, XHTTP, mKCP and REALITY), pinned by tag in `buildScript/apply-core-patch.sh` and built from source by CI. The interface, the bridge layer and the release line are maintained here. Upstream's own releases, documentation (throneproj.github.io) and donation options remain in the upstream repository.

## Download

Get the APKs from [GitHub Releases](https://github.com/yuedaochangmendian/flrone/releases). Each release ships three ABI splits (arm64-v8a, armeabi-v7a, x86_64) with `SHA256SUMS`; the in-app update check verifies size and SHA-256 before offering the installer. Releases from v2.0.0 on use a signing key that conflicts with 1.x installations: uninstall the old release first and import subscriptions again.

## Key features

1. **Throne-desktop-compatible data model** — groups and subscriptions (per-group filters, URL test after an update, scheduled updates), shared route profiles, and `.thrbackup` backups restorable on either side, including WebDAV sync.
2. **One Flutter interface** — built-in sing-box dashboard (live traffic, connections, logs), a bulk-test panel, a sing-box-aware JSON editor, home-screen widgets, a quick settings tile and D-pad navigation for Android TV.
3. **Single nodes, subscriptions and toolbox** — hand-imported single nodes on their own page with a selection that survives restarts; optional subscription names (server title, then URL host) with remaining quota and expiry (`Permanent` when undated); a Bettbox-style network toolbox.
4. **Verifiable distribution and self-update** — three ABI splits, `SHA256SUMS` and a `throne-update.json` manifest carrying the signer certificate's `signerSha256`, all produced by the release pipeline.

## Feedback

Please use [GitHub Issues](https://github.com/yuedaochangmendian/flrone/issues) for bugs, feature requests and questions (attach exported logs with secrets removed). For vulnerabilities that must stay private, follow [SECURITY.md](../SECURITY.md). Before contributing, read [CONTRIBUTING.md](../CONTRIBUTING.md).
