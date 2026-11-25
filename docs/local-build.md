# Local full build

How to build this repository on a workstation, end to end, without GitHub Actions.
`tools/local-build/local-env.sh` pins the toolchain,
`tools/local-build/local-inputs.sh` prepares the same inputs the CI actions
prepare, `tools/local-build/local-release.sh` builds and uploads a prerelease,
and Gradle then runs the same tasks CI runs.

> **Prereleases are built here, not in CI.** The automatic prerelease workflow was
> removed: `local-release.sh` produces the signed APK set and uploads it to GitHub.
> GitHub Actions now builds only a **stable** release (`stable-release.yml`, which
> calls `ci.yml` as its gate).

## Prerequisites

| Component | Version used | Where this machine keeps it |
|---|---|---|
| JDK | 21 (Temurin); the build compiles to JVM 17 | `/e/hu/toolchain/jdk21` |
| Gradle | 8.14.5 (AGP 8.13.2 needs ≥ 8.13; Gradle 9 is not supported) | `/e/hu/toolchain/gradle-8.14.5` |
| Android SDK | platform 37, build-tools 37.0.0, NDK 28.2.13676358, CMake 3.22.1 | `/e/hu/toolchain/android-sdk` |
| Go | **1.27.0** — the version CI pins in `.github/actions/throne-core/action.yml`; `build-cshared.sh` runs `GOTOOLCHAIN=local` | `/e/hu/toolchain/go-1.27` (versioned); `/e/hu/toolchain/go` is the shared alias |
| Flutter | `3.50.0` — the version CI pins in `.github/actions/android-build/action.yml` | `/e/hu/toolchain/flutter-3.50.0` (versioned); `/e/hu/toolchain/flutter` is the shared alias and may be older |
| gomobile/gobind | only needed for the AAR path CI uses; the c-shared path does not use them | `~/go/bin` |

`local-env.sh` picks the Go 1.26+ and Flutter 3.50.0 installs when they exist and
prints every resolved path; it warns when the Flutter in use is not the CI pin.

Installing the two versioned SDKs (one-off):

```bash
# Go 1.27.0 — https://dl.google.com/go/go1.27.0.windows-amd64.zip, extracted to E:/go-sdk/go1.27
# Flutter 3.50.0 — https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.50.0-stable.zip
#   extracted to E:/flutter-sdk/flutter-3.50.0
# both are exposed through the toolchain as junctions:
#   E:/hu/toolchain/go-1.27        -> E:/go-sdk/go1.27/go
#   E:/hu/toolchain/flutter-3.50.0 -> E:/flutter-sdk/flutter-3.50.0/flutter
```

## Quick start

```bash
source tools/local-build/local-env.sh          # pins JAVA_HOME, SDK, NDK, Gradle home, Flutter, Go
bash tools/local-build/local-inputs.sh         # Flutter AAR + kernel + schema + rule sets + dashboard
./gradlew app:testOssDebugUnitTest app:assembleOssDebug
```

`local-inputs.sh --check` only verifies that the inputs are present;
`--only=flutter,routeprofiles` runs a subset.

## Publish a prerelease

```bash
source tools/local-build/local-env.sh
bash tools/local-build/local-release.sh              # build + publish the prerelease
bash tools/local-build/local-release.sh --build-only # build + package into dist/ only
```

`local-release.sh` mirrors what the removed release workflow did:

1. requires a clean tree and every build input (`--allow-dirty` builds a dirty tree but implies `--build-only`: an uncommitted APK must never be published);
2. reads `VERSION_NAME` / `VERSION_CODE` from `nb4a.properties` and takes
   `N = highest existing vX.Y.Z-pre.N tag + 1` from GitHub (`--build N` overrides;
   a failed lookup aborts rather than reusing a tag);
3. signs with the release key and passes `THRONE_CHANNEL=preview THRONE_BUILD=N`
   to `app:assembleOssRelease`, so `versionName` is `X.Y.Z-pre.N` and `versionCode`
   is `VERSION_CODE*1000+N` — identical metadata to the old CI previews;
4. runs `buildScript/release_assets.py ... preview` (3 ABI APKs + `SHA256SUMS`,
   no `throne-update.json`);
5. verifies the commit is on `main` and calls `buildScript/publish_release.sh`
   (`--prerelease`, never `--latest`); `--build-only` stops before this step.

Signing material (not in the repository):

| Variable | Default | Meaning |
|---|---|---|
| `LOCAL_SIGNING_KEYSTORE` | `E:/tmp/2026-11-01-18-33-32/throne-release.keystore` | the release keystore (alias `throne-release`) |
| `LOCAL_SIGNING_PASS_FILE` | `E:/tmp/2026-11-01-18-33-32/dist/throne-release-signing-backup-2026-11-02.txt` | file with `STORE_PASS=...` |
| `LOCAL_SIGNING_STORE_PASS` | — | store password, overrides the file |
| `LOCAL_SIGNING_KEY_ALIAS` | `throne-release` | alias |

The key must be the one the published APKs used: a different key cannot install
over an existing release. `dist/` is gitignored and rewritten on every run.

## What `local-inputs.sh` does

| Step | Output | Mirrors |
|---|---|---|
| `flutter` | `flutter/build/host/outputs/repo/io/flrone/ui/flutter_release/1.0` | `android-build` → “Flutter AAR” |
| `core` | `deployment/android-cshared/<abi>/libthrone.so` (arm64-v8a, armeabi-v7a, x86_64) | `throne-core` → c-shared build |
| `schema` | `app/src/main/assets/schema/sing-box.json` | `throne-core` → “Generate sing-box schema” |
| `routeprofiles` | `app/src/main/assets/routeprofiles/srslist.h` + `profile/` | `routeprofiles` action |
| `dashboard` | `app/src/main/assets/sb-dashboard/` | `sing-box-dashboard` action |

Every remote pull uses the pin the workflow uses — `THRONE_CORE_REF` in
`nb4a.properties`, `SRS_REF`/`PROFILE_REF` in the routeprofiles action,
`DASHBOARD_REF` in the dashboard action — so a local build is the same snapshot
CI builds. The kernel checkout is fetched as a codeload tarball (no git history,
no `.git` needed) and cached under `LOCAL_BUILD_CACHE` (`E:/hu/Temp/local-build-cache`
by default); delete that directory to rebuild from scratch.

`core` must run before `schema` (the schema generator runs inside the patched
checkout). The script enforces the order.

## Verification

```bash
source tools/local-build/local-env.sh
bash tools/local-build/local-inputs.sh --check

cd flutter && flutter analyze --fatal-infos && flutter test --coverage && cd ..
python tools/diagnostics/coverage_gate.py flutter/coverage/lcov.info \
  --min 60 --exclude 'lib/core/throne_ffi.dart' --exclude 'lib/ui/**' \
  --min-dir lib/box_api.dart:32 --min-dir lib/pages:50

python tools/diagnostics/channel_audit.py
python tools/diagnostics/symbol_audit.py
python tools/diagnostics/settings_contract.py

./gradlew app:testOssDebugUnitTest app:assembleOssDebug
```

Expected on a clean checkout: `analyze` clean, 962-ish Flutter tests green,
445-ish JVM tests green, a debug APK per ABI under `app/build/outputs/apk/`.

## Pitfalls this environment handles

| Symptom | Cause | Handling |
|---|---|---|
| `Could not find io.flrone.ui:flutter_release:1.0` | The AAR is a build product and is gitignored | `local-inputs.sh --only=flutter` (or run the whole script) |
| `FileNotFoundException … srslist.h` / `cannot write` on Windows | `File.renameTo` cannot replace an existing file on Windows | Production code falls back to a direct write (`RuleSetCatalog`, `RouteRepo`); keep that fallback |
| 35 backup/import tests fail locally | Windows has no `libsqlite3.so` | `BACKUP_TEST_SQLITE='C:\Windows\System32\winsqlite3.dll' flutter test` |
| Gradle: `Connection refused` for an uncached artifact | A stale `systemProp.*.proxyPort` in `$GRADLE_USER_HOME/gradle.properties` | That file sets `127.0.0.1:7890`; keep it pointing at the active proxy |
| `go.mod requires go >= 1.26.0 (running go 1.25.5; GOTOOLCHAIN=local)` | `build-cshared.sh` pins the local toolchain for the cross build | Install Go 1.27.0 as `E:/hu/toolchain/go-1.27`; `local-env.sh` prefers it |
| `invalid flag in #cgo LDFLAGS: -l:libcronet.a` | Go 1.26 rejects that link-flag form; CI builds with 1.27 | Use Go 1.27 (see above) |
| `binary is out of date, re-install it` (gomobile) | gomobile built with another Go version | Only affects the gomobile AAR path; the c-shared path does not use gomobile |
| `schemagen` fails after a core cache hit | Missing `script/build_android.sh` in the checkout | Re-run `--only=core`, which re-applies the overlay |

## Not reproduced locally

* **Stable release signing** — the stable artifacts are still built and signed
  by `stable-release.yml` with the repository `SIGNING_*` secrets. A preview is
  built and signed locally (above); the two use the same key, so they are
  upgrade-compatible.
* **Dry runs** — publishing is the default. Use `--build-only`, inspect `dist/`,
  then rerun without it (or with `--build N`) when the artifacts look right.
