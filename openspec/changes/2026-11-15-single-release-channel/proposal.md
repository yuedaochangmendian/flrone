# Simplify the GitHub release flow to one channel

## Why

`release.yml` had three triggers (`workflow_run`, `workflow_dispatch`, `push tags`)
and two channels (preview / stable). In practice main produced a stream of
`-pre.N` prereleases while `releases/latest` stayed on an old stable build, so
the in-app updater never saw current code and every release decision needed a
manual step. The repository had one channel that mattered and three ways to
reach it.

## What Changes

- `release.yml` keeps **only** `workflow_run` (CI success on `main`). Delete
  `workflow_dispatch`, `push.tags`, the preview channel, `PUBLISH` /
  `DISPATCH_CHANNEL` / `AUTO_PRERELEASE`, the tag-push branch, the dispatch
  channel branch, and the `publish=false` artifact-only path.
- Version comes from `nb4a.properties` `VERSION_NAME`; tag `vX.Y.Z`,
  `channel=stable`, `build-number=999`, `prerelease=false`, explicit
  `--latest`. One tag per version: an existing tag is a safe skip, so cutting
  the next release means bumping `VERSION_NAME` and adding its CHANGELOG
  section.
- Keep the guards that matter: the triggering CI commit must still be current
  `main`, and there must be app/build-input changes since the last release tag.
  Keep `build-inputs` reuse, signing, `release_assets.py` (stable produces
  `throne-update.json`), `publish_release.sh` retries and the publish-failure
  artifact.
- `nb4a.properties`: `VERSION_CODE` 177 → 178 for the first stable build.
- Sync the governing docs (`docs/github-workflow.md`,
  `docs/release-runbook.md`, `README.md`, `CONTRIBUTING.md`) and the active
  `openspec/specs/repository-governance/spec.md` requirement
  "单一自动正式版工作流".
- Delete all non-`main` remote branches and close their open PRs; the branch
  model stays PR → main.

## Impact

- `v4.11.0` becomes the first release published through the single path and
  replaces `v4.0.0` as `releases/latest`; the in-app updater starts offering
  current builds again.
- Historical `-pre.N` releases remain in place as published history. No new
  ones are produced; governance baseline entries about old preview assets stay.
- Dependabot config is unchanged, so dependency PRs will keep opening weekly;
  closing them remains a maintenance action.
- Governance audit (`github_governance.py`) continues to require the 5 stable
  assets and `releases/latest` to carry `throne-update.json`.

## Verification

- `release.yml` parses with a single `workflow_run` trigger; every `run:` block
  passes `bash -n`; `release_notes.sh 4.11.0` resolves the CHANGELOG section.
- PR CI green → merge → main CI green → Release `workflow_run` publishes
  `v4.11.0`; verify `isPrerelease=false`, 5 assets, `releases/latest=v4.11.0`.
