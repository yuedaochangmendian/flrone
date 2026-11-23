// Host-backed backup I/O (P14; ADR 0006 stage C2c2a removed live Room from it).
//
// An Android app process may only `dlopen` libraries listed in
// `public.libraries.txt`. AOSP system images ship no `libsqlite3.so`, and the
// platform `libsqlite.so` is not public, so `data/sqlite.dart`'s `Sqlite.open()`
// answers null on a stock device — the desktop/CI backup write path cannot open
// a snapshot file there. This module is the Android path: the host runs the
// backup container's SQL and reads/writes the settings and markers documents,
// with dart:ffi kept as the desktop/CI fallback.
//
// Dart stays the ONLY place that maps/stages rows and owns the THRN envelope.
// The host performs exactly five jobs, none of which touches Room:
//
//  * `backup.container` — parameterized SQL Dart authors against a backup
//    **container** file in the app's own storage (C2c1; the live database and
//    the documents directory are refused);
//  * `settings.snapshot` / `markers.snapshot` — the live `settings.json` /
//    `markers.json` documents as `{key, value}` / `{key, marked_at}` rows
//    (C2c2a; the export's source);
//  * `settings.restore` / `markers.restore` — the one merge + whole-set replace
//    each (C2c2a; the restore's sink, with the selection repair from the ids
//    Dart names);
//  * `data.legacyRows` — the retired `sager_net.db` read with the framework
//    SQLite, no Room, only for the documents that are still absent (C2c2a).
//
// C2c1 retired `data.roomSql`; C2c2a retired the `data.roomSnapshot` /
// `data.applyRoomSnapshot` DAO row pumps. There is no live-Room op on this
// channel any more.

import 'dart:convert';
import 'dart:typed_data';

import '../data/sqlite.dart' show SqlRow;

/// Kotlin's `Base64.DEFAULT` wraps output at 76 columns, and dart's decoder
/// rejects the embedded newlines with a FormatException. Strip all whitespace
/// first so either encoder's output decodes; the Kotlin producers send
/// `NO_WRAP`, this is the safety net for stale payloads.
List<int> tolerantBase64Decode(String text) =>
    base64Decode(text.replaceAll(RegExp(r'\s'), ''));

/// A handle to a backup container the host opened. Opaque to Dart; passed back
/// on every [RoomSnapshotHost.sqlQuery]/[RoomSnapshotHost.sqlExec].
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

  /// The host's live settings document, keyed by setting name. Null when the
  /// host has no document mounted (a bridge/test host that does not answer);
  /// an empty map is a real state ("the document has no rows").
  Future<Map<String, String>?> settingsSnapshot() async {
    final reply = await call('settings.snapshot');
    final rows = reply is Map ? reply['rows'] : reply;
    if (rows is! List) return null;
    final out = <String, String>{};
    for (final row in rows) {
      if (row is! Map) continue;
      final key = row['key'];
      final value = row['value'];
      if (key is String && value is String) out[key] = value;
    }
    return out;
  }

  /// The host's live markers document (`{key, marked_at}` rows), or null when
  /// the host cannot answer.
  Future<List<SqlRow>?> markersSnapshot() async {
    final reply = await call('markers.snapshot');
    final rows = reply is Map ? reply['rows'] : reply;
    if (rows is! List) return null;
    return [
      for (final row in rows)
        if (row is Map) Map<String, Object?>.from(row),
    ];
  }

  /// Merges the container's settings rows and repairs the selection keys in a
  /// single host request (the host owns the document). [settings] is null when
  /// the container carried no settings block: the live values then stay and
  /// only the selection repair runs. The id lists name the catalog the
  /// selection may point at; null means "no document to compare with" and
  /// leaves that key be.
  Future<List<String>> restoreSettings({
    required Map<String, String>? settings,
    required bool fromAndroid,
    required bool restoredProfiles,
    List<int>? groupIds,
    List<int>? profileIds,
    List<int>? routeIds,
  }) async {
    final reply = await call('settings.restore', <String, Object?>{
      'hasSettings': settings != null,
      'settings': settings ?? const <String, String>{},
      'fromAndroid': fromAndroid,
      'restoredProfiles': restoredProfiles,
      'restoredGroupIds': ?groupIds,
      'restoredProfileIds': ?profileIds,
      'restoredRouteIds': ?routeIds,
    });
    final warnings = reply is Map ? reply['warnings'] : null;
    return warnings is List ? [for (final w in warnings) '$w'] : const <String>[];
  }

  /// Replaces the host's markers document in one write.
  Future<void> restoreMarkers(List<SqlRow> rows) async {
    await call('markers.restore', <String, Object?>{'rows': rows});
  }

  /// The one-time legacy read (`data.legacyRows`): profiles/groups plus the
  /// route/settings/marker rows whose documents are still absent. Null when the
  /// host did not answer; an all-empty reply is a fresh install.
  Future<Map<String, dynamic>?> legacyRows() async {
    final reply = await call('data.legacyRows');
    return reply is Map<String, dynamic> ? reply : null;
  }

  /// Opens a backup container file on the host. [path] must be a real file in
  /// the app's own storage (a temp export snapshot, a staged restore database,
  /// an embedded backup DB); [write] creates it when absent. Returns a handle.
  ///
  /// C2c1: this is the container channel (`backup.container`), so the live
  /// database, the documents directory and the rule-set catalog are refused by
  /// the host — there is no way to reach a live store through here.
  Future<HostSqlHandle> openSql(String path, {required bool write}) async {
    final reply = await call('backup.container', <String, Object?>{
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

  Future<void> closeSql(HostSqlHandle handle) async {
    await call('backup.container', <String, Object?>{'op': 'close', 'handle': handle.id});
  }

  /// Executes a Dart-authored, parameterized statement. [sql] uses only `?`
  /// placeholders; [params] are bound by the host. Returns the affected-row
  /// count for DML (or 0 for DDL).
  Future<int> sqlExec(HostSqlHandle handle, String sql, [List<Object?> params = const []]) async {
    final reply = await call('backup.container', <String, Object?>{
      'op': 'exec',
      'handle': handle.id,
      'sql': sql,
      'params': params,
    });
    return reply is num ? reply.toInt() : 0;
  }

  /// Runs a Dart-authored, parameterized query and returns column-keyed rows.
  Future<List<SqlRow>> sqlQuery(HostSqlHandle handle, String sql, [List<Object?> params = const []]) async {
    final reply = await call('backup.container', <String, Object?>{
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

  /// Reads a container file's bytes through the host (for the embedded
  /// `database` entry).
  Future<Uint8List> readBytes(String path) async {
    final reply = await call('backup.container', <String, Object?>{'op': 'readBytes', 'path': path});
    final text = reply is Map ? reply['bytes'] : reply;
    if (text is! String) throw const FormatException('host did not read the file');
    return Uint8List.fromList(decode(text));
  }

  /// Writes bytes to a container file through the host.
  Future<void> writeBytes(String path, List<int> bytes) async {
    await call('backup.container', <String, Object?>{
      'op': 'writeBytes',
      'path': path,
      'bytes': encode(bytes),
    });
  }
}
