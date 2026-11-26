// ADR 0005 phase 2: the Dart half of the UI-only settings overlay.
//
// Kotlin's `SettingsSchema.kt` declares `UI_ONLY_KEYS` as the code-side single
// source of truth; this set is its Dart mirror, checked by
// `tools/diagnostics/settings_contract.py`. A key here is shell presentation
// state owned by the `preferences` JSON document — it is never a Room/Throne
// row, never a service input, and never travels through `settings.set`.
//
// The split matters because the two sides must not both write the same key:
// Kotlin writes the authoritative Throne rows, Dart writes this overlay. The
// sets are disjoint, so merging them cannot lose either side's value (the
// failure mode ADR 0002 originally moved settings back onto the channel for).

/// Local alias so this module does not import box.dart (which imports it back).
typedef Json = Map<String, dynamic>;

/// Shell-only keys Dart owns in `preferences`. Keep in sync with the Kotlin
/// `UI_ONLY_KEYS` set; settings_contract.py fails the build if they drift.
const Set<String> uiOnlyKeys = {
  'fontFamily',
  'fontFollowTheme',
  'fontPath',
  'fontSize',
  'theme',
  'appTheme',
  'useSystemTheme',
  'nightTheme',
  'pureBlack',
  'amoledTheme',
  'color',
  'colorStyle',
  'systemColor',
  'fontScale',
  'logFontSize',
  'floatingNavigation',
  'liquidGlass',
  'tabAnimation',
  'appLanguage',
  'proxySort',
  'groupLayoutMode',
  'compactProfileRows',
  'compactGroupCards',
  'restoreStrategy',
};

/// Rebuilds the full settings view from the two independent stores, every time.
///
/// [authoritative] is the map the host put on `ready`/`settings` (Throne rows
/// plus the host-derived read-only keys); [overlay] is the current Dart
/// `preferences` document. Overlay values win for the keys Dart owns, then the
/// host's derived keys are normalised exactly as Kotlin's `settingsWire()` does.
/// Nothing is cached: a caller always sees the fresh Kotlin snapshot merged
/// with the fresh Dart overlay, so a new host value can never be masked by a
/// stale merged whole-map copy.
Json mergeSettings(Json authoritative, Json overlay) {
  final merged = Map<String, dynamic>.of(authoritative);
  for (final key in uiOnlyKeys) {
    final value = overlay[key];
    if (value != null) merged[key] = value;
  }
  return merged;
}

/// Splits a batch into the Dart-owned overlay rows and the authoritative rows
/// that must still cross the channel (ADR 0005 phase 2).
({Json overlay, Json authoritative}) splitSettings(Json values) {
  final overlay = <String, dynamic>{};
  final authoritative = <String, dynamic>{};
  values.forEach((key, value) {
    (uiOnlyKeys.contains(key) ? overlay : authoritative)[key] = value;
  });
  return (overlay: overlay, authoritative: authoritative);
}
