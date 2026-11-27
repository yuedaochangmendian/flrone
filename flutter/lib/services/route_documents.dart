// The kernel-owned global route document (ADR 0002 phase 3c): `<documents>/global_route_rules.json`,
// one versioned envelope (`{version, name, rows, revision}`), rows keyed by the Room column names
// the one-time migration copied verbatim. Schema version 2 carries a monotonic `revision` that
// guards incremental saves; version 1 files are read as revision 0. The Go kernel is the everyday
// writer (`route_store.go`'s writeDocument: temp file, flush, rename). There is a single global
// rule table — the old per-profile route documents are gone with the profile UI.
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

/// The one route table the backup carries. Older containers used per-profile
/// route documents; that format is no longer supported — a container without
/// `global_route_rules.json` has no routes.
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

  /// The marker the migration seeder also uses: the presence of the global
  /// route document means the hand-over ran and the kernel owns the routes.
  /// Legacy per-profile route documents are ignored.
  bool get established => routeDocumentTables.any((table) => _file(table).existsSync());

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

  /// The document's revision (0 for a missing or v1 file). The Go increment
  /// client uses this as its optimistic-concurrency base, so any write that
  /// bypasses the kernel must move it forward or a later patch would be
  /// accepted against rows the writer never saw.
  int readRevision(String table) {
    final file = _file(table);
    if (!file.existsSync()) return 0;
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map) return 0;
    final revision = decoded['revision'];
    if (revision is num) return revision.toInt();
    // A string spelling from a hand-edited file is tolerated, like Go's
    // rowInt64; an unparseable value is treated as an old (v1) document.
    if (revision is String) return int.tryParse(revision) ?? 0;
    return 0;
  }

  /// Replaces the document atomically: temp file, flush, rename — the exact
  /// discipline of Go's `writeDocument`, so a crash mid-write leaves the
  /// previous file intact. [revision] is written verbatim; callers that change
  /// the rows must pass the current revision + 1.
  void writeTable(String table, List<Map<String, Object?>> rows, {int? revision}) {
    final next = revision ?? (readRevision(table) + 1);
    _writePayload(table, jsonEncode({
      'version': 2,
      'name': table,
      'rows': rows,
      'revision': next,
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
  /// rules" and replaces the document. The replacement bumps the revision, so
  /// any editor that loaded its snapshot before the restore gets a stale-patch
  /// refusal rather than silently overwriting the restored rows with its old
  /// view. A rollback via [restoreSnapshot] puts back the exact previous bytes
  /// (including the old revision) because the restore never happened from the
  /// user's point of view.
  void restore({List<Map<String, Object?>>? globalRules}) {
    if (globalRules == null) return;
    writeTable('global_route_rules', [
      for (final row in globalRules) Map<String, Object?>.from(row),
    ]);
  }
}
