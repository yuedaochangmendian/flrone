# Releases are prerelease by default

## Why

The 2026-11-15 simplification collapsed `release.yml` to one `workflow_run`
path, but made every `main` CI success publish a **stable** release and move
`releases/latest`. The user then asked for the opposite default: "之后再发版默认发
prerelease". A stable release (and the in-app updater manifest) should be a
deliberate maintainer action, never an accidental side effect of a merge.

## What Changes

- `release.yml` keeps its single `workflow_run` trigger; no dispatch, no tag
  push. The automatic product becomes a preview:
  - tag `v${VERSION_NAME}-pre.${N}`, where `N` = highest existing preview
    number for that version + 1 (1..998). A failed `git ls-remote` aborts
    rather than guessing a free tag.
  - `channel=preview`, `build-number=N`, `prerelease=true`.
  - `release_assets.py ... dist preview` → 3 ABI APKs + `SHA256SUMS`, no
    `throne-update.json`.
  - the `Mark latest` step is removed; `publish_release.sh --prerelease`
    keeps it off `releases/latest`.
- Consecutive merges in one version line advance `N` automatically; bumping
  `VERSION_NAME` only starts a new line (or is required at `N > 998`).
- Stable promotion stays explicit: `gh release edit <tag>
  --prerelease=false`, clean title, `--latest`, and a generated update
  manifest. Documented in `docs/github-workflow.md` and
  `docs/release-runbook.md`.
- `nb4a.properties`: 4.11.1 → 4.11.2 / 180; `CHANGELOG.md` gains `#### 4.11.2`
  describing the form-button, node-editor and proxies fixes from PR #94.
- Sync `docs/github-workflow.md`, `docs/release-runbook.md`, `README.md`,
  `CONTRIBUTING.md` and the active `repository-governance` spec requirement
  ("单一自动 prerelease 工作流").

## Impact

- `releases/latest` stays on the last explicitly promoted stable release
  (v4.11.1); the in-app updater is no longer moved by every merge.
- Preview assets intentionally carry no `throne-update.json`, so governance's
  "preview must not carry manifest" check stays satisfied.
- Historical `-pre.N` releases and the baseline exceptions are untouched.

## Verification

- `release.yml` parses with a single `workflow_run` trigger; every `run:` block
  passes `bash -n`; preview-number parsing tested against `ls-remote` shapes
  (no tags → 1, `pre.67` with annotated `^{}` rows → 68, other versions
  ignored).
- `release_notes.sh 4.11.2` resolves the CHANGELOG section.
- After merge: `main` CI green → Release publishes `v4.11.2-pre.1` with
  `isPrerelease=true`, 4 assets, `releases/latest` unchanged.
