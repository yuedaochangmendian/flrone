// The rule-set catalog, read from the rule-set directory in pure Dart.
//
// ADR 0005 phase 3: `routes.ruleSets` used to be a method-channel arm in
// `BboxActions` that asked `RouteManager.catalog()` for the name -> URL map.
// That catalog is not route DATA (Go owns the route documents); it is a file
// fact: the `routeprofiles/srslist.h` file under filesDir, written by
// RouteRepo.refresh or bundled by CI. Dart reaches the same file through the
// `data.path` fact the data plane already uses, so the channel arm is gone and this
// file is the reader.
//
// There is no second writer here. `srslist.h` is still written by Kotlin's
// RouteRepo (and shipped in the assets); this file only parses it. The parse
// and the search are ports of Kotlin `RuleSetCatalog`.

import 'dart:io';

import 'data_layer.dart' show DatabaseLocation;

/// One `srslist.h` entry: a rule-set name and its `.srs` URL.
class RuleSetEntry {
  const RuleSetEntry(this.name, this.url);

  final String name;
  final String url;

  Map<String, Object?> toWire() => <String, Object?>{'name': name, 'url': url};
}

/// Matches `{"geosite-cn", "https://…"}` in an `srslist.h`. Equivalent to
/// Kotlin `RuleSetCatalog.ENTRY`; a single matcher over the whole text avoids
/// the native buffer copy `RegExp.allMatches` would make per entry on Android.
final RegExp _entryPattern = RegExp(r'\{\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\}');

/// Parses one `srslist.h` body. A name seen twice keeps its first URL, matching
/// Kotlin `RuleSetCatalog`'s `LinkedHashMap` (order is insertion order).
List<RuleSetEntry> parseRuleSetCatalog(String text) {
  final seen = <String>{};
  final entries = <RuleSetEntry>[];
  for (final match in _entryPattern.allMatches(text)) {
    final name = match.group(1)!;
    if (!seen.add(name)) continue;
    entries.add(RuleSetEntry(name, match.group(2)!));
  }
  return entries;
}

/// Case-insensitive search ported from Kotlin `RuleSetCatalog.search`: exact
/// matches first, then prefixes, then substrings, each in catalog order.
List<RuleSetEntry> searchRuleSetCatalog(
  Iterable<RuleSetEntry> entries,
  String query,
  int limit,
) {
  if (limit <= 0) return const <RuleSetEntry>[];
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return entries.take(limit).toList();
  final exact = <RuleSetEntry>[];
  final prefix = <RuleSetEntry>[];
  final contains = <RuleSetEntry>[];
  for (final entry in entries) {
    final name = entry.name.toLowerCase();
    if (name == needle) {
      exact.add(entry);
    } else if (name.startsWith(needle)) {
      prefix.add(entry);
    } else if (name.contains(needle)) {
      contains.add(entry);
    }
  }
  return <RuleSetEntry>[...exact, ...prefix, ...contains].take(limit).toList();
}

/// Supplies the raw `srslist.h` text, or null when the runtime copy is absent.
/// Injectable so a test needs no filesystem.
typedef RuleSetTextReader = Future<String?> Function();

/// Reads and parses the rule-set catalog on demand. The catalog is re-read on
/// every search so a `RouteRepo.refresh` that replaces `srslist.h` is picked up
/// without a restart; the file is small and the parse cheap.
class RuleSetCatalogSource {
  RuleSetCatalogSource({required RuleSetTextReader readText})
      : _readText = readText;

  final RuleSetTextReader _readText;

  Future<List<RuleSetEntry>> load() async {
    final text = await _readText();
    return parseRuleSetCatalog(text ?? '');
  }

  Future<Map<String, Object?>> search(String query, int limit) async {
    final entries = await load();
    final found = searchRuleSetCatalog(entries, query, limit);
    return <String, Object?>{
      'total': entries.length,
      'entries': found.map((entry) => entry.toWire()).toList(),
    };
  }
}

/// The production reader: `srslist.h` under the app's `routeprofiles/`
/// directory, located from the Room database path the host publishes through
/// `data.path`. The database's parent is the `databases` dir; one above that is
/// the app dir, whose `files/routeprofiles/srslist.h` is `RouteRepo.srsListFile()`.
Future<String?> readRuleSetCatalogText(Future<dynamic> Function() resolvePath) async {
  final location = DatabaseLocation.parse(await resolvePath());
  if (location == null) return null;
  final appDir = File(location.path).parent.parent;
  final file = File(
    '${appDir.path}${Platform.pathSeparator}files'
    '${Platform.pathSeparator}routeprofiles${Platform.pathSeparator}srslist.h',
  );
  try {
    return await file.readAsString();
  } on FileSystemException {
    // No runtime copy yet: the picker shows an empty catalog. RouteRepo.refresh
    // (and the CI-bundled asset it falls back to) is the only producer of this
    // file; this pure-Dart reader never writes it.
    //
    // The Kotlin reader additionally fell back to the bundled
    // `assets/routeprofiles/srslist.h` before the first refresh. That asset
    // belongs to the host Android module and is not in the Flutter module's
    // asset bundle, so scanning it here would need a new channel — exactly what
    // phase 3 removes. The runtime copy is created by `RouteRepo.refresh`, which
    // the remote-profile update path drives; until then the picker shows an
    // empty catalog. No route data is affected by that gap.
    return null;
  }
}
