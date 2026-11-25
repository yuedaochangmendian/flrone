// The kernel-owned global route document (ADR 0002 phase 3c): `<documents>/global_route_rules.json`,
// one versioned envelope (`{version, name, rows}`), rows keyed by the Room column names the
// one-time migration copied verbatim. The Go kernel is the everyday writer (`route_store.go`'s
// writeDocument: temp file, flush, rename). There is a single global rule table — the old
// `route_profiles`/`route_rules` documents are gone with the profile UI.
//
// A backup restore is the one privileged writer outside the kernel — the same class of
// operation as `RoomToJsonMigration.seed` and `ConfigurationStore.replaceAll`: a whole-set
// replace, never a merge. This module owns that replace so the restore path stops channelling
// routes through Room's tables. It also owns the pre-replace snapshot the restore puts back
// when the replace itself, or a later step, fails.
//
// Reading and writing here are plain file I/O: the kernel re-reads per action and its cache
// keys on mtime+length, so a replacement invalidates both by construction.

import 'dart:convert';
import 'dart:io';

/// The one route table the backup carries. Older containers carried
/// `route_profiles`/`route_rules` as well; the backup writer folds those rows
/// into this single table before the restore reaches here.
const routeDocumentTables = ['global_route_rules'];

/// A pre-replace capture of the route document: the raw file content, or
/// `null` where the document did not exist. [RouteDocuments.restoreSnapshot]
/// puts it back; [hadDocuments] distinguishes "nothing was there" from "an
/// empty document was".
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

  /// The marker the migration seeder also uses: the presence of any of the
  /// route documents means the hand-over ran and the kernel owns the routes.
  /// The legacy names are checked too, so a pre-single-table install still
  /// exports its rules.
  bool get established => routeDocumentTables.any((table) => _file(table).existsSync()) ||
      _file('route_profiles').existsSync() ||
      _file('route_rules').existsSync();

  /// The global document, or null on a pre-migration install (no document yet).
  Map<String, List<Map<String, Object?>>>? readAll() {
    if (!established) return null;
    return {for (final table in routeDocumentTables) table: readTable(table)};
  }

  /// The rows of the document; a missing file is an empty set (the kernel's
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

  /// Replaces the document atomically: temp file, flush, rename — the exact
  /// discipline of Go's `writeDocument`, so a crash mid-write leaves the
  /// previous file intact.
  void writeTable(String table, List<Map<String, Object?>> rows) {
    _writePayload(table, jsonEncode({
      'version': 1,
      'name': table,
      'rows': rows,
    }));
  }

  /// Captures the document exactly as the kernel left it — raw text, not rows,
  /// so a rollback puts back every column this build does not understand and
  /// a file that did not exist stays absent.
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
      return 'The previous route document could not be restored ($error); '
          'the restored routes are still in place.';
    }
    if (!snapshot.hadDocuments) {
      return removed
          ? 'The route document did not exist before this restore; the one '
              'it created was removed.'
          : 'The route document did not exist before this restore and none '
              'was created.';
    }
    return 'The previous route document was restored.';
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
  /// A null [globalRules] means the container predates the global table and
  /// the live document survives untouched; an empty list genuinely means "no
  /// rules" and replaces the document.
  void restore({List<Map<String, Object?>>? globalRules}) {
    if (globalRules == null) return;
    writeTable('global_route_rules', [
      for (final row in globalRules) Map<String, Object?>.from(row),
    ]);
  }
}
