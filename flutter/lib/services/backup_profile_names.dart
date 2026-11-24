// Reads the confirmation preview from a THRN container's embedded SQLite.
//
// ADR 0005 phase 4: the WebDAV envelope is now built in Dart. Its `profiles`
// member is only a preview for the "Restore N profiles?" dialog — the restore
// itself decodes the container's `thr` member natively. Reading `id, name` from
// the embedded `profiles` table is a single read-only query over the low-level
// dart:ffi SQLite (no Room schema gate, since the container is a desktop-shaped
// snapshot, not the live sager_net.db). If the platform has no libsqlite3 or the
// table is absent, an empty list is returned: the restore still works, only the
// pre-count is unavailable. This mirrors `FlroneBackup.profileNames` (whose
// `nodeCounts` map is always empty in the current host).

import 'dart:io';
import 'dart:typed_data';

import '../data/sqlite.dart' show Sqlite, SqliteDatabase;
import 'room_snapshot_host.dart' show HostSqlHandle, RoomSnapshotHost;

/// The group rows the restore confirmation counts: `{name, nodes: 0}`. Kept in
/// the exact shape `FlroneBackup.profileNames` produces so the dialog needs no
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
        // FlroneBackup.profileNames always reports 0 (nodeCounts is empty).
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

/// The host-backed fallback for [profileNamesFromContainer]: the ffi reader
/// answers null on a stock Android device (no public `libsqlite3.so`), which
/// left the "Restore N profiles?" pre-count empty there — and an empty preview
/// rejected every WebDAV profiles-only restore as "holds no profiles". The
/// host owns a SQLite that can read the same temp snapshot file.
Future<List<Map<String, dynamic>>> profileNamesFromContainerViaHost(
  RoomSnapshotHost host,
  Uint8List? bytes,
) async {
  if (bytes == null || bytes.isEmpty) return <Map<String, dynamic>>[];
  String? path;
  HostSqlHandle? handle;
  try {
    final temp = Directory.systemTemp.createTempSync('thrn-preview-host-');
    path = '${temp.path}/snapshot.db';
    File(path).writeAsBytesSync(bytes);
    handle = await host.openSql(path, write: false);
    final rows = await host.sqlQuery(handle, 'SELECT id, name FROM profiles');
    return [
      for (final row in rows)
        <String, dynamic>{
          'name': row['name'] ?? '',
          // FlroneBackup.profileNames always reports 0 (nodeCounts is empty).
          'nodes': 0,
        },
    ];
  } on Object {
    return <Map<String, dynamic>>[];
  } finally {
    if (handle != null) {
      try {
        await host.closeSql(handle);
      } on Object {
        // Best-effort cleanup.
      }
    }
    if (path != null) {
      try {
        File(path).parent.deleteSync(recursive: true);
      } on Object {
        // Best-effort cleanup of the temporary snapshot.
      }
    }
  }
}

/// The confirmation preview: the direct ffi reader first (the fast path where
/// a public libsqlite3 exists), the host fallback otherwise.
Future<List<Map<String, dynamic>>> previewProfileNames(
  RoomSnapshotHost host,
  Uint8List? bytes,
) async {
  final direct = profileNamesFromContainer(bytes);
  if (direct.isNotEmpty) return direct;
  return profileNamesFromContainerViaHost(host, bytes);
}
