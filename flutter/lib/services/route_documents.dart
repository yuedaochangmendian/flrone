// The kernel-owned route documents (ADR 0002 phase 3c): `<documents>/route_profiles.json`
// and `route_rules.json`, one versioned envelope per file (`{version, name, rows}`),
// rows keyed by the Room column names the one-time seed copied verbatim. The Go kernel is
// the everyday writer (`route_store.go`'s writeDocument: temp file, flush, rename); the
// Kotlin side keeps a read-only, mtime-keyed view (`RouteJsonStore`) and refuses to write
// Room once the documents exist (`RouteManager.save`'s check).
//
// A backup restore is the one privileged writer outside the kernel — the same class of
// operation as `RoomToJsonMigration.seed` (a hand-over, not a sync) and
// `ConfigurationStore.replaceAll`: a whole-set replace, never a merge. This module owns that
// replace so the restore path stops channelling routes through Room's tables, which froze
// at the migration hand-over (backing them up exported the freeze; restoring into them
// wrote rows the app never read again). It also owns the pre-replace snapshot the restore
// puts back when the replace itself, or a later step, fails — the route-document twin of
// the profiles document's rollback.
//
// Reading and writing here are plain file I/O: the kernel re-reads per action and
// `RouteJsonStore`'s cache keys on mtime+length, so a replacement invalidates both by
// construction.

import 'dart:convert';
import 'dart:io';

/// The route tables the backup carries. `global_route_rules` is the third
/// kernel document — staged since ADR 0006's follow-up; older containers
/// without it leave the live document untouched on restore.
const routeDocumentTables = ['route_profiles', 'route_rules', 'global_route_rules'];

/// A pre-replace capture of the route documents: raw file contents per table,
/// `null` where the document did not exist. [RouteDocuments.restoreSnapshot]
/// puts it back; [hadDocuments] distinguishes "nothing was there" from "empty
/// documents were".
class RouteDocumentsSnapshot {
  const RouteDocumentsSnapshot(this.contents);

  final Map<String, String?> contents;

  bool get hadDocuments => contents.values.any((raw) => raw != null);
}

class RouteDocuments {
  RouteDocuments(this.dir);

  /// `<filesDir>/documents`, the directory the host names in `data.path`.
  final Directory dir;

  File _file(String table) => File('${dir.path}${Platform.pathSeparator}$table.json');

  /// The marker `RoomToJsonMigration.seed` also uses: its presence means the
  /// hand-over ran and the kernel owns the routes.
  bool get established => _file('route_profiles').existsSync();

  /// All staged route documents, or null on a pre-migration install (no
  /// documents yet — Room's tables are still the authority there and the
  /// export must fall back to them).
  Map<String, List<Map<String, Object?>>>? readAll() {
    if (!established) return null;
    return {for (final table in routeDocumentTables) table: readTable(table)};
  }

  /// The rows of one document; a missing file is an empty set (the kernel's
  /// readDocument answers the same).
  List<Map<String, Object?>> readTable(String table) {
    final file = _file(table);
    if (!file.existsSync()) return const [];
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return const [];
    final rows = decoded['rows'];
    return [
      if (rows is List)
        for (final row in rows)
          if (row is Map) Map<String, Object?>.from(row),
    ];
  }

  /// Replaces one document atomically: temp file, flush, rename — the exact
  /// discipline of Go's `writeDocument`, so a crash mid-write leaves the
  /// previous file intact.
  void writeTable(String table, List<Map<String, Object?>> rows) {
    _writePayload(table, jsonEncode({
      'version': 1,
      'name': table,
      'rows': rows,
    }));
  }

  /// Captures the three documents exactly as the kernel left them — raw text,
  /// not rows, so a rollback puts back every column this build does not
  /// understand and a file that did not exist stays absent.
  ///
  /// Taken before a privileged replace ([restore]); a failure of that replace
  /// or of any later restore step puts the capture back through
  /// [restoreSnapshot].
  RouteDocumentsSnapshot snapshot() => RouteDocumentsSnapshot({
        for (final table in routeDocumentTables) table: _readRaw(table),
      });

  String? _readRaw(String table) {
    final file = _file(table);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  /// Puts [snapshot] back after a step following the replace failed, and
  /// returns the note the restore appends to its error text. Never throws: the
  /// original failure is what the user must read first.
  ///
  /// A document that existed is rewritten to its captured bytes; a document
  /// that did not exist is removed again when the failed restore created it
  /// (the honest inverse — the kernel's `established` marker is one of these
  /// files, so leaving a created set behind would claim a hand-over that never
  /// ran). When none existed, the note says so instead of inventing content,
  /// the same explicit style as the profiles rollback.
  String restoreSnapshot(RouteDocumentsSnapshot snapshot) {
    var removed = false;
    try {
      for (final table in routeDocumentTables) {
        final raw = snapshot.contents[table];
        final file = _file(table);
        if (raw != null) {
          _writePayload(table, raw);
        } else if (file.existsSync()) {
          file.deleteSync();
          removed = true;
        }
      }
    } on Object catch (error) {
      return 'The previous route documents could not be restored ($error); '
          'the restored routes are still in place.';
    }
    if (!snapshot.hadDocuments) {
      return removed
          ? 'The route documents did not exist before this restore; the ones '
              'it created were removed.'
          : 'The route documents did not exist before this restore and none '
              'were created.';
    }
    return 'The previous route documents were restored.';
  }

  /// The atomic replacement both [writeTable] and [restoreSnapshot] use.
  void _writePayload(String table, String payload) {
    dir.createSync(recursive: true);
    final file = _file(table);
    final temp = File('${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
    temp.writeAsStringSync(payload, flush: true);
    try {
      temp.renameSync(file.path);
    } on FileSystemException {
      // rename cannot cross filesystems or replace on some volumes: fall back
      // to a direct write, the same belt the migration seeder wears.
      file.writeAsStringSync(payload, flush: true);
      temp.deleteSync();
    }
  }

  /// The privileged whole-set replace a backup restore performs.
  ///
  /// * a restore that brings routes without profiles clears `source_gid` on
  ///   every row (the groups they named were not restored and could now be
  ///   someone else's) — the defensive twin of [clearSourceGids];
  /// * when no usable (non-raw) profile survives, the canonical Default seed
  ///   (Go's `defaultNodeRow`/`defaultProfileRules`: the profile plus the
  ///   Route DNS hijack rule) is appended, so a config build never falls
  ///   through to `route.final = direct`;
  /// * `__current` is set on [currentRouteId]'s row when it exists (the THRN
  ///   container carries Room columns only, so the marker never round-trips),
  ///   else the kernel's own read fallback — first usable profile — applies.
  void restore({
    required List<Map<String, Object?>> profiles,
    required List<Map<String, Object?>> rules,
    required bool profilesRestored,
    int? currentRouteId,
    List<Map<String, Object?>>? globalRules,
  }) {
    final seededProfiles = [
      for (final row in profiles) Map<String, Object?>.from(row),
    ];
    final seededRules = [
      for (final row in rules) Map<String, Object?>.from(row),
    ];
    if (!profilesRestored) {
      for (final row in seededProfiles) {
        row['source_gid'] = -1;
      }
    }
    if (!seededProfiles.any((row) => !_isRaw(row))) {
      final nextId = seededProfiles
              .map((row) => _asInt(row['id']) ?? 0)
              .fold<int>(0, (a, b) => a > b ? a : b) +
          1;
      seededProfiles.add({
        'id': nextId,
        'name': 'Default',
        'default_outbound_id': -1,
        'is_raw': false,
      });
      seededRules.add({
        'route_profile_id': nextId,
        'rule_order': 0,
        'name': 'Route DNS',
        'action': 'hijack-dns',
        'protocol': 'dns',
        'type': 0,
      });
    }
    if (currentRouteId != null) {
      for (final row in seededProfiles) {
        if (_asInt(row['id']) == currentRouteId && !_isRaw(row)) {
          row['__current'] = true;
        } else {
          row.remove('__current');
        }
      }
    }
    // Rules before profiles. The two files are written in sequence, so a crash between them
    // leaves a mixed pair (new rules, previous profiles) whichever order is chosen; the next
    // successful import or restore rewrites both, which is the only recovery this path has. The
    // previous comment claimed the order prevented that mixed pair — it does not.
    writeTable('route_rules', seededRules);
    writeTable('route_profiles', seededProfiles);
    if (globalRules != null) {
      // The global pool rides the same privileged replace. Older containers
      // pass null and the live document survives untouched — the empty case
      // is not, it genuinely means "no rules".
      writeTable('global_route_rules', [
        for (final row in globalRules) Map<String, Object?>.from(row),
      ]);
    }
  }

  /// The one-sided restore cleanup: profiles/groups were replaced *under* the
  /// surviving routes, whose `source_gid` may now name someone else's group —
  /// the document-side twin of the Room path's `resetSourceGids`, which ran
  /// against tables the app no longer reads.
  void clearSourceGids() {
    if (!established) return;
    final rows = readTable('route_profiles');
    var changed = false;
    for (final row in rows) {
      if (_asInt(row['source_gid']) != -1) {
        row['source_gid'] = -1;
        changed = true;
      }
    }
    if (changed) writeTable('route_profiles', rows);
  }
}

int? _asInt(Object? value) => value is num ? value.toInt() : int.tryParse('$value');

bool _isRaw(Map<String, Object?> row) => row['is_raw'] == true || row['is_raw'] == 1;
