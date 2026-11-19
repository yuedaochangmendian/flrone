// Reads the confirmation preview from a THRN container's embedded SQLite.
//
// ADR 0005 phase 4: the WebDAV envelope is now built in Dart. Its `profiles`
// member is only a preview for the "Restore N profiles?" dialog — the restore
// itself decodes the container's `thr` member natively. Reading `id, name` from
// the embedded `profiles` table is a single read-only query over the low-level
// dart:ffi SQLite (no Room schema gate, since the container is a desktop-shaped
// snapshot, not the live sager_net.db). If the platform has no libsqlite3 or the
// table is absent, an empty list is returned: the restore still works, only the
// pre-count is unavailable. This mirrors `BboxBackup.profileNames` (whose
// `nodeCounts` map is always empty in the current host).

import 'dart:io';
import 'dart:typed_data';

import '../data/sqlite.dart' show Sqlite, SqliteDatabase;

/// The group rows the restore confirmation counts: `{name, nodes: 0}`. Kept in
/// the exact shape `BboxBackup.profileNames` produces so the dialog needs no
/// change. [bytes] is the container's `database` entry.
List<Map<String, dynamic>> profileNamesFromContainer(Uint8List? bytes) {
  if (bytes == null || bytes.isEmpty) return <Map<String, dynamic>>[];
  final sqlite = Sqlite.open();
  if (sqlite == null) return <Map<String, dynamic>>[];
  String? path;
  SqliteDatabase? db;
  try {
    final temp = Directory.systemTemp.createTempSync('thrn-preview-');
    path = '${temp.path}/snapshot.db';
    File(path).writeAsBytesSync(bytes);
    db = sqlite.openDatabase(path, readOnly: true);
    if (db == null) return <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    for (final row in db.query('SELECT id, name FROM profiles')) {
      out.add(<String, dynamic>{
        'name': row['name'] ?? '',
        // BboxBackup.profileNames always reports 0 (nodeCounts is empty).
        'nodes': 0,
      });
    }
    return out;
  } on Object {
    return <Map<String, dynamic>>[];
  } finally {
    db?.close();
    if (path != null) {
      try {
        File(path).parent.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup of the temporary snapshot.
      }
    }
  }
}
