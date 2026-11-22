# Prism UI: provenance

`flutter/lib/ui` is a fork of [`chen08209/prism_ui`](https://github.com/chen08209/prism_ui),
a Flutter UI kit, vendored into this repository. This document records where the copy
came from and what the license obligations are. It is a provenance record, not a
drift policy: the UI layer is owned by this project and evolves freely.

## Provenance

| Field | Value |
| --- | --- |
| Repo | `https://github.com/chen08209/prism_ui.git` |
| Originally vendored from | `260f53f1e0497680a53b339c3e8f6648bbb0b1d4` (2026-11-15) |
| Last synced from | `7831ade349ede896aedb8a5757dc9c3fe88081d5` (0.1.3, 2026-11-19) |
| Files taken | 145 (`lib/**/*.dart`) |
| License | GPL-3.0 (third-party portions per `NOTICE`) |

The 2026-11-20 sync took the four commits that were still missing from the
`260f53f1e` baseline: `typography.dart` (span emphasis), `list_row.dart` (a long
trailing value keeps its title), `popup.dart` (menu label width), and
`collapsible_section.dart` (header caption/leading gap). The other upstream
changes in that range were either already present at the baseline or not
applicable to Flutter 3.47 (`ScrollCacheExtent` still needs the explicit
`rendering.dart` import here). Local patches in `dialog.dart`, `list.dart`,
`paged_sheet.dart`, `prism_list.dart`, `route_motion_hold.dart` and
`banner.dart` were preserved, and the per-file hashes in
`flutter/flclash-manifest.json` were updated for the files the manifest tracks.

## Why vendored

The kit was vendored rather than consumed from pub.dev because the app adds product
features inside the same layer and needs to change kit internals:

- The app-authored modules that live alongside the kit: the JSON-schema editor
  (`json/`, `json/engine/`), QR rendering (`qr_code.dart`, `qr_matrix.dart`), the
  page scaffold (`scaffold/`), the glyph set (`icons/app_glyphs.dart`), the fonts
  barrel, and the module barrel `ui.dart`.
- Shader assets move from `packages/prism_ui/shaders/...` to `shaders/...` because
  the kit is compiled into the app rather than resolved from a package namespace.

## Ownership

The vendored layer is **owned by this project**. There is no drift gate and no
requirement to keep any file byte-identical to upstream. Files may be rewritten,
merged, split or deleted as the app requires. Upstream remains a reference for
fixes worth taking, not an authority over the tree's shape.

## Sync aid (not a gate)

`tools/diagnostics/prism_diff.py` records the tree and answers "what changed
since the last sync", so the next upstream pass is reviewable instead of
guesswork. It never blocks anything:

```sh
python tools/diagnostics/prism_diff.py --record   # after a sync: rewrite the baseline
python tools/diagnostics/prism_diff.py            # added / removed / changed vs the baseline
python tools/diagnostics/prism_diff.py --json     # the same report as JSON
python tools/diagnostics/prism_diff.py --strict   # one-off check, exits 1 on any difference
```

`tools/prism_baseline.json` is the committed inventory (path → sha256 plus the
upstream commit read from this document). CI does not run the script: by the
ownership rule above, drift is expected and legitimate.

## License obligations

`lib/ui` and `lib/ui/hct`, `lib/ui/shapes`, `lib/ui/sliver_list` derive from GPL-3.0
and MIT/Apache-2.0 sources. Do not remove:

- the repository `NOTICE` file;
- the `LicenseRegistry` entries registered in `flutter/lib/main.dart`;
- the per-file copyright headers carried over by the vendored files.
