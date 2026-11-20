// Host-backed Room snapshot I/O (P14).
//
// An Android app process may only `dlopen` libraries listed in
// `public.libraries.txt`. AOSP system images ship no `libsqlite3.so`, and the
// platform `libsqlite.so` is not public, so `data/sqlite.dart`'s `Sqlite.open()`
// answers null on a stock device — the desktop/CI backup write path cannot open
// Room or a snapshot file there. This module is the Android path: the process
// that owns Room (Kotlin) supplies the rows and writes them back, with dart:ffi
// kept as the desktop/CI fallback.
//
// Dart stays the ONLY place that maps/stages rows and owns the THRN envelope.
// The host reads its tables through Room DAO methods (`data.roomSnapshot`),
// writes them back through Room DAOs in one transaction (`data.applyRoomSnapshot`),
// and runs Dart-authored parameterized SQL against a temp snapshot file it owns
// (`data.roomSql`). No SQL string is authored in Kotlin.

import 'dart:convert';
import 'dart:typed_data';

import '../data/sqlite.dart' show SqlRow;

/// Kotlin's `Base64.DEFAULT` wraps output at 76 columns, and dart's decoder
/// rejects the embedded newlines with a FormatException. Strip all whitespace
/// first so either encoder's output decodes; the Kotlin producers send
/// `NO_WRAP`, this is the safety net for stale payloads.
List<int> tolerantBase64Decode(String text) =>
    base64Decode(text.replaceAll(RegExp(r'\s'), ''));

/// A handle to a database the host opened (a temp snapshot or Room's file).
/// Opaque to Dart; passed back on every [RoomSnapshotHost.sqlQuery]/[sqlExec].
class HostSqlHandle {
  const HostSqlHandle(this.id);
  final String id;
}

/// The host side of the backup write path, over MethodChannel.
///
/// Injected [call] keeps it free of `box.dart` (which imports the services
/// layer back) and lets tests supply a mock — that is how "ffi missing, host
/// answers" is exercised on a desktop host without an Android device.
class RoomSnapshotHost {
  RoomSnapshotHost({
    required this.call,
    this.encode = base64Encode,
    this.decode = tolerantBase64Decode,
  });

  final Future<dynamic> Function(String method, [Object? args]) call;
  final String Function(List<int> bytes) encode;
  final List<int> Function(String text) decode;

  /// Live Room rows via DAO reads (create's source). `profiles`/`groups` are
  /// the Dart-owned document rows that win over Room's stale copies (ADR 0005);
  /// null means no document and Room is the pre-migration source.
  Future<Map<String, dynamic>?> roomSnapshot({
    List<SqlRow>? profiles,
    List<SqlRow>? groups,
  }) async {
    final args = <String, Object?>{};
    if (profiles != null) args['profiles'] = profiles;
    if (groups != null) args['groups'] = groups;
    final reply = await call('data.roomSnapshot', args);
    return reply is Map<String, dynamic> ? reply : null;
  }

  /// Writes staged rows back to Room in one host transaction. Returns the
  /// committed profiles/groups rows so Dart can rebuild the owned document.
  Future<Map<String, dynamic>> applyRoomSnapshot(Map<String, Object?> rows) async {
    final reply = await call('data.applyRoomSnapshot', rows);
    if (reply is! Map<String, dynamic>) {
      throw const FormatException('host did not acknowledge the Room write');
    }
    return reply;
  }

  /// Opens a database file on the host. [path] is a real file (a temp snapshot
  /// or an embedded backup DB); [write] creates it when absent. Returns a handle.
  Future<HostSqlHandle> openSql(String path, {required bool write}) async {
    final reply = await call('data.roomSql', <String, Object?>{
      'op': 'open',
      'path': path,
      'write': write,
    });
    final id = reply is Map ? reply['handle'] : reply;
    if (id is! String || id.isEmpty) {
      throw const FormatException('host did not open the database');
    }
    return HostSqlHandle(id);
  }

  /// Opens Room's own file (read-only or read-write) through the host's
  /// SupportSQLiteDatabase. [path] must equal `data.path`'s answer.
  Future<HostSqlHandle> openRoom(String path, {required bool write}) async {
    final reply = await call('data.roomSql', <String, Object?>{
      'op': 'openRoom',
      'path': path,
      'write': write,
    });
    final id = reply is Map ? reply['handle'] : reply;
    if (id is! String || id.isEmpty) {
      throw const FormatException('host did not open Room');
    }
    return HostSqlHandle(id);
  }

  Future<void> closeSql(HostSqlHandle handle) async {
    await call('data.roomSql', <String, Object?>{'op': 'close', 'handle': handle.id});
  }

  /// Executes a Dart-authored, parameterized statement. [sql] uses only `?`
  /// placeholders; [params] are bound by the host. Returns the affected-row
  /// count for DML (or 0 for DDL).
  Future<int> sqlExec(HostSqlHandle handle, String sql, [List<Object?> params = const []]) async {
    final reply = await call('data.roomSql', <String, Object?>{
      'op': 'exec',
      'handle': handle.id,
      'sql': sql,
      'params': params,
    });
    return reply is num ? reply.toInt() : 0;
  }

  /// Runs a Dart-authored, parameterized query and returns column-keyed rows.
  Future<List<SqlRow>> sqlQuery(HostSqlHandle handle, String sql, [List<Object?> params = const []]) async {
    final reply = await call('data.roomSql', <String, Object?>{
      'op': 'query',
      'handle': handle.id,
      'sql': sql,
      'params': params,
    });
    if (reply is! List) return const <SqlRow>[];
    return reply
        .whereType<Map>()
        .map((r) => Map<String, Object?>.from(r))
        .toList();
  }

  /// Reads a file's bytes through the host (for the embedded `database` entry).
  Future<Uint8List> readBytes(String path) async {
    final reply = await call('data.roomSql', <String, Object?>{'op': 'readBytes', 'path': path});
    final text = reply is Map ? reply['bytes'] : reply;
    if (text is! String) throw const FormatException('host did not read the file');
    return Uint8List.fromList(decode(text));
  }

  /// Writes bytes to a file through the host.
  Future<void> writeBytes(String path, List<int> bytes) async {
    await call('data.roomSql', <String, Object?>{
      'op': 'writeBytes',
      'path': path,
      'bytes': encode(bytes),
    });
  }
}
