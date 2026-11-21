# Prism UI and FlClash UI provenance

The application UI was rebuilt from scratch against FlClash `afe71360`
(`v0.9.4-4-gafe71360`, 2026-11-20).

## Packages

| Layer | Source | How it is consumed |
| --- | --- | --- |
| Primitives | FlClash `plugins/prism_ui` (prism_ui 0.1.2) | vendored at `flutter/plugins/prism_ui`, path dependency |
| App-level FlClash UI | FlClash `lib/ui` | copied into `flutter/lib/ui` (`scaffold/`, `icons/`, `list_item.dart`, `qr_code.dart`, `nested_sheet.dart`, ...) |
| App shell and screens | New code in this repository | `flutter/lib/app`, `flutter/lib/pages`, `flutter/lib/components` |

`package:prism_ui` owns the interaction primitives: surfaces, press feedback,
focus rings, switches, sheets, popups, navigation dock/sidebar, liquid glass,
motion helpers and the color system. The app-level `lib/ui` owns the pieces
FlClash builds on top of the package: the page scaffold, the glyph set, list
rows, nested sheets and QR rendering.

## Build notes

- `flutter/plugins/prism_ui` is a normal Flutter package. Its shaders resolve
  as `packages/prism_ui/shaders/...`; the app does not copy them again.
- `flutter/lib/ui` is owned by this repository and may be changed with the
  screens. It is not a hash-locked copy.
- The old `flutter/flclash-manifest.json` describes the pre-rewrite vendored
  tree and is retained only as historical provenance; it is not a build input.

## License

`prism_ui` is GPL-3.0 with third-party portions recorded in its `NOTICE`.
FlClash is GPL-3.0. Keep the repository `NOTICE`, the licenses under
`flutter/assets/licenses`, and the per-file copyright headers that came with
the vendored sources.
