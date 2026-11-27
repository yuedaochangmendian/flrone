# Core pin upgrade runbook

How to move the kernel (`THRONE_CORE_REF` in `nb4a.properties`) to a newer
`throneproj/Throne` commit without shipping a broken APK. The core is **not**
developed in this repo: CI clones the pinned commit and applies this repo's
overlay on top. Everything below is about re-validating that overlay against a
new upstream tree.

Before touching anything, run the drift report (a **manual** tool — `ci.yml`
does not run `core_pin_report.py`; run it yourself when planning a pin bump):

```bash
python3 tools/diagnostics/core_pin_report.py --ext        # pinned vs dev + ext tag
python3 tools/diagnostics/core_pin_report.py --json --ref dev > /tmp/core.json
```

`--ref` accepts a branch or SHA; `--ext` also compares `SINGBOX_EXT_VERSION`
with the latest `yuedaochangmendian/sing-box-ext` tag. Read the reported commit
counts for `core/mobile`, `core/internal`, `core/gen/libcore.proto` and
`core/go.mod` — those are exactly the surfaces the overlay replaces or edits.
See [`tools/diagnostics/core_pin_report.py`](../tools/diagnostics/core_pin_report.py).

## 1. Worktree

Do the investigation in a **separate worktree**, never on the `main` checkout:

```bash
git worktree add -b bump/core-<short-sha> ../core-bump main
cd ../core-bump
```

Keep `main` clean so a failed experiment can be abandoned with
`git worktree remove --force`. All pin edits, overlay diffs and test builds
happen in the worktree; only a fully green branch is merged as a PR.

## 2. Overlay patch series discipline

`buildScript/core-patch/` is an **overlay**, not a patch queue that merges:
`apply-core-patch.sh` copies whole files over the upstream checkout, so an
overlay file silently wins and an upstream shape change shows up later as a Go
compile error. Treat each logical change as its own reviewable commit:

1. Fetch the new commit shallowly into a scratch checkout and apply the overlay:

   ```bash
   bash buildScript/apply-core-patch.sh /path/to/Throne
   python3 tools/diagnostics/core_patch_audit.py --checkout /path/to/Throne
   (cd /path/to/Throne/core && go test ./mobile/ -count=1)
   ```

2. Diff the **upstream** files at the old and new pins for every file the
   overlay owns (see the header comment in `apply-core-patch.sh`). Renamed
   fields, changed handler signatures and new required interface methods do not
   merge — update the matching file under `core-patch/` first, one concern per
   commit. Do not "fix" the overlay by weakening `core_patch_audit.py`.
3. Regenerate only what changed: `tools/bindgen/bindgen.py` for the `throne_*`
   C ABI and `tools/gen_settings_schema.py` for settings. Keep generated
   outputs in the same commit as the generator change.

   Bindgen owns six checked-in artifacts (both `bridge_symbols.h` copies,
   `bridge_calls.go`, `bridge_runtime.go`, `dartbridge.go`, `throne_ffi.dart`).
   After changing a template or an output, run the idempotence gate — it
   regenerates the full pipeline (`bindgen.py` → gofmt → `prune_exports.py` →
   gofmt) into a temp dir and fails on any byte difference:

   ```bash
   python3 tools/diagnostics/bindgen_check.py --go-src /path/to/Throne/core/mobile
   ```

   CI runs the same gate in the `build` job against the pinned patched tree
   (`$THRONE_DIR/core/mobile`), next to the preamble/linkage audits. The
   `--go-src` tree is required: two generated bodies depend on the real Go
   sources, so a generation against an empty directory is not comparable.
   The checked-in files are authoritative: if the gate reports drift, port the
   change into the generator (or regenerate), do not edit the generator to
   match a stale output.
4. Set the new pin (one commit, by itself):

   ```text
   nb4a.properties: THRONE_CORE_REF=<full 40-char commit sha>
   ```

   An immutable SHA, never a moving branch — CI cache keys are built from it.

## 3. ext.10 dependency alignment

The kernel fork tag lives in `buildScript/apply-core-patch.sh`:

```text
SINGBOX_EXT_VERSION="${SINGBOX_EXT_VERSION:-v1.15.0-ext.10}"
SING_FORK_VERSION="${SING_FORK_VERSION:-v0.9.4-0.20261125171526-5979c7963e80}"
```

These are the values currently applied by `apply-core-patch.sh` for the pinned
`bdc8be00` core (ext.10 was the resolution of the 2026-11-26 spike below). If a
newer Throne pin needs a newer fork tag, bump all three places together or the
build will silently use the wrong kernel:

1. `SINGBOX_EXT_VERSION` in `apply-core-patch.sh` → the new ext tag.
2. The `replace github.com/sagernet/sing-box => …` line in the **patched
   checkout's** `core/go.mod` is rewritten by the script; confirm the resulting
   version matches the new tag after `apply-core-patch.sh`.
3. `SING_FORK_VERSION` must mirror the `replace github.com/sagernet/sing =>`
   line in **sing-box-ext's own `go.mod`** (a replace in a dependency is
   ignored, so this repo repeats it). `go mod tidy` in the patched core must
   succeed with `GONOSUMDB='github.com/yuedaochangmendian/*'`; the fork tag is
   not in sum.golang.org yet. Verify with `core_pin_report.py --ext` that the
   pinned tag is the one you intend.
4. Update the README / changelog line that names the fork tag.

## 4. Gates — all required before merge

A core bump invalidates both `throne-core` caches (pin and overlay hash), so a
full rebuild runs in CI. Do not merge on a partial run.

- **3-ABI build:** `.github/actions/throne-core/action.yml` builds
  `deployment/android-cshared/{arm64-v8a,armeabi-v7a,x86_64}/libthrone.so`,
  verifies the symbols `throne_register_callbacks`, `throne_host_call`,
  `throne_run_action` in each, and checks 16 KB LOAD alignment on arm64 and
  x86_64. Regenerate `app/src/main/assets/schema/sing-box.json` with the same
  Android build tags.
- **Protocol / schema:** the generated sing-box option schema must parse and
  match the new core; the Go overlay tests (`go test ./mobile/ -count=1`) and
  `core_patch_audit.py --checkout` must pass.
- **FFI:** `tools/diagnostics/ffi_regression_test.py` and the Dart bridge tests
  in `flutter/test/` (new `throne_*` exports, callback registration). The AAR
  channel audit (`aar_channel_audit.py`) must stay within
  `tools/diagnostics/aar_channels.txt`.
- **Smoke:** `flutter analyze --fatal-infos`, `flutter test` (coverage floor),
  JVM unit tests, and the full diagnostics set from `ci.yml` — in particular
  `channel_audit.py`, `symbol_audit.py`, `action_contract.py` and
  `platform_duty_audit.py`. Manual smoke on a device: start VPN, switch a
  group, run a URLTest, open logs and export them with a 3-ABI preview APK.
- `flutter test` on this Windows host needs `BACKUP_TEST_SQLITE` pointing at a
  `sqlite3.dll` for `backup_write_test.dart` / `legacy_import_test.dart`;
  without it those two files fail for the environment, not the change. Use the
  Linux CI run as the authority.

## 5. Rollback

If a bumped pin fails a gate after merge:

1. Revert the pin commit: restore the previous `THRONE_CORE_REF` (and the
   `SINGBOX_EXT_VERSION` / `SING_FORK_VERSION` values if ext was bumped) in a
   new commit — do not force-push `main`.
2. If a preview was already published, keep it but make sure
   `releases/latest` still points at the last stable `vX.Y.Z`, not the preview
   (see `docs/release-runbook.md`). To pull a bad update from users, create a
   new patch version with the reverted pin, release it as a prerelease, then
   promote it as the new rollback tag.
3. Record the failed pin, the gate that caught it and the reason in the
   changelog / this runbook so the next attempt does not repeat it.

## 2026-11-26 spike: `bdc8be00` core bump (resolved)

**Resolved history.** The spike used ext.9 to test the new `bdc8be00` core and
stopped at the first hard failures; the resolution was to bump the fork
versions to the ext.10 / `…5979c7963e80` pair now pinned in
`apply-core-patch.sh` (§3). `nb4a.properties` today pins `THRONE_CORE_REF=bdc8be00…`.
The findings below are kept for the next core bump — do not redo the ext.9
experiment:

1. **ext.9 cannot build the new dependency set.** `go mod tidy` fails because
   ext.9's `dns/transport/local/systemconfig/source_darwin.go` and
   `experimental/libbox/monitor.go` import `sing-tun/dnsinfo`, which the new
   `sing-tun` removed. Forcing the old `sing-tun` lets tidy pass, then the
   c-shared build fails on `sing-snell … undefined: N.ErrPacketTooBig` — the
   ext.9 `sing` fork predates the fix. The rebased `v1.15.0-ext.10` (whose own
   `go.mod` declares `throneproj/sing …5979c7963e80`) is a prerequisite, not an
   optimisation.
2. **Overlay merge shape.** A 24-file three-way merge over the overlay left 19
   clean and 5 conflicting: `rpc/lifecycle.go` (keep upstream `sysdns.Release`
   and the fork's `untrackDNSTunnels`), `probe/dnstunnel.go` (upstream still
   calls `startupAllowance`; the overlay renamed it `dnsTunnelAllowance`), and
   the scanner rewrite in `scan/dns.go`, `mobile/instance.go`, `mobile/test.go`
   (product decisions: resolver/WARP scans vs the fork's xdns phases).
   The overwrite semantics also silently freeze `libcore.proto`, `main.go`,
   `rpc/{scan,egress,urltest}.go` and `mobile/context.go` at the old content —
   review those diffs explicitly or the new RPCs disappear.
3. **Removed upstream packages.** `rpc/tor.go`, `rulesets/parse.go`,
   `scan/{http3_*,icmp_*,tlshttp}.go` and `torproc/` are gone; search the
   overlay and Kotlin bridge for references before building.

The investigative worktree (`E:/hu/Temp/core-bump-wt`, branch `core-bump-spike`)
was scratch only; none of its unmerged overlay edits are needed for the shipped
pin.
