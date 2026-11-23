// A host-channel mock for the P14 backup write path. It emulates exactly the
// three host methods BboxRoomSnapshot implements — `data.roomSnapshot`,
// `data.applyRoomSnapshot` and the backup container's SQL transport
// (`backup.container`) — backed by the same low-level SQLite the fixture uses,
// so the host path can be exercised on a desktop host without an Android
// device, with real SQL semantics.
//
// Production passes these calls to Kotlin over MethodChannel; here a fake
// `RoomSnapshotHost.call` routes them to in-process ffi. What the test pins is
// the WIRE SHAPE (method names, arg keys, row maps) and that Dart takes the host
// branch when ffi is unavailable. [FakeRoomHost.confine] mirrors the host's
// cache-tree confinement, so a Dart call site that reaches for Room's file or
// the documents directory fails here too.

import 'dart:convert';
import 'dart:io';

import 'package:flrone/data/sqlite.dart' show Sqlite, SqliteDatabase;
import 'package:flrone/services/room_snapshot_host.dart';

class FakeRoomHost {
  FakeRoomHost(this.sqlite, {required this.roomPath, String? containerRoot})
      : containerRoot = containerRoot ?? Directory.systemTemp.path;

  final Sqlite sqlite;
  final String roomPath;

  /// The app's cache tree on a device; the fake's stand-in is the system temp
  /// dir, where `Directory.systemTemp.createTemp` actually puts the snapshots.
  final String containerRoot;
  final Map<String, SqliteDatabase> _handles = <String, SqliteDatabase>{};
  int _seq = 0;

  RoomSnapshotHost toHost() => RoomSnapshotHost(call: handle);

  /// The container path guard, mirroring `BboxRoomSnapshot.confinedContainerFile`:
  /// the app's own storage only, with the live database directory, the documents
  /// directory and the rule-set catalog refused by segment.
  String confine(Object? rawPath) {
    final path = '${rawPath ?? ''}';
    if (path.isEmpty) throw StateError('backup.container needs a path');
    final file = File(path).absolute;
    final segments = file.uri.pathSegments;
    final name = segments.last;
    if (name == 'sager_net.db' || name.startsWith('sager_net.db-')) {
      throw StateError('backup.container must not open the live Room database: $path');
    }
    // `File.absolute` keeps `..` on Linux (Windows normalises it), so a path
    // such as `/tmp/../elsewhere/backup.db` would pass the prefix check below.
    // The host uses a canonical path; refuse the traversal here too.
    if (segments.contains('..')) {
      throw StateError("backup.container path is outside the app's private storage: $path");
    }
    for (final live in const ['databases', 'documents', 'routeprofiles']) {
      if (segments.contains(live)) {
        throw StateError('backup.container must not open a live data directory: $path');
      }
    }
    final root = Directory(containerRoot).absolute.path;
    if (!file.path.startsWith('$root${Platform.pathSeparator}')) {
      throw StateError("backup.container path is outside the app's private storage: $path");
    }
    return file.path;
  }

  Future<dynamic> handle(String method, [Object? rawArgs]) async {
    final args = (rawArgs is Map) ? Map<String, Object?>.from(rawArgs) : <String, Object?>{};
    switch (method) {
      case 'data.roomSnapshot':
        return _roomSnapshot(args);
      case 'data.applyRoomSnapshot':
        return _applyRoomSnapshot(args);
      case 'backup.container':
        return _containerSql(args);
      default:
        throw StateError('unexpected host method: $method');
    }
  }

  Map<String, dynamic> _roomSnapshot(Map<String, Object?> args) {
    final db = sqlite.openDatabase(roomPath, readOnly: true)!;
    try {
      final out = <String, dynamic>{};
      // Route tables come back under the Kotlin DAO bundle's camelCase keys; the
      // fixture may not carry `global_route_rules`, in which case it answers an
      // empty list like a DAO over an empty table.
      void rows(String table, String order, [String? key]) {
        final exists = db
            .query("SELECT 1 FROM sqlite_master WHERE type='table' AND name = ?", <Object?>[table])
            .isNotEmpty;
        out[key ?? table] = exists
            ? db
                .query('SELECT * FROM $table ORDER BY $order')
                .map((r) => Map<String, Object?>.from(r))
                .toList()
            : <Map<String, Object?>>[];
      }

      rows('groups', '`display_order`, `id`');
      rows('profiles', '`gid`, `user_order`, `id`');
      rows('route_profiles', '`id`', 'routeProfiles');
      rows('route_rules', '`route_profile_id`, `rule_order`', 'routeRules');
      rows('global_route_rules', '`rule_id`', 'globalRouteRules');
      rows('settings', '`key`');
      rows('markers', '`key`');
      int maxId(String table) =>
          (db.query('SELECT COALESCE(MAX(id),0) AS n FROM $table').first['n'] as num).toInt();
      out['sequences'] = <String, int>{
        'profiles': maxId('profiles'),
        'groups': maxId('groups'),
        'route_profiles': maxId('route_profiles'),
      };
      return out;
    } finally {
      db.close();
    }
  }

  Map<String, dynamic> _applyRoomSnapshot(Map<String, Object?> args) {
    final db = sqlite.openDatabase(roomPath, readOnly: false)!;
    try {
      final doProfiles = args['doProfiles'] == true;
      final doRoutes = args['doRoutes'] == true;
      final doSettings = args['doSettings'] == true;
      void replace(String table, Object? wire) {
        final t = (wire as Map).cast<String, Object?>();
        final cols = (t['columns'] as List).map((e) => e.toString()).toList();
        final rows = (t['rows'] as List).map((e) => (e as List).cast<Object?>()).toList();
        if (rows.isEmpty) return;
        final sql = 'INSERT INTO `$table` (${cols.map((c) => '`$c`').join(',')}) '
            'VALUES (${cols.map((_) => '?').join(',')})';
        for (final row in rows) {
          db.execute(sql, row);
        }
      }

      List<int>? wireIds(String key) {
        final raw = args[key];
        if (raw is! List) return null;
        return raw.map((v) => (v as num).toInt()).toList();
      }

      db.execute('BEGIN IMMEDIATE');
      try {
        // ADR 0006 stage B: no profiles/groups writes — the restore put them
        // straight into the Dart document, and this fake mirrors that.
        if (doRoutes) {
          db.execute('DELETE FROM route_rules');
          db.execute('DELETE FROM route_profiles');
          replace('route_profiles', args['routeProfiles']);
          replace('route_rules', args['routeRules']);
        }
        if (doSettings) {
          final settings = (args['settings'] as Map).cast<String, String>();
          settings.forEach((k, v) => db.execute(
              'INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)', <Object?>[k, v]));
          db.execute('DELETE FROM markers');
          replace('markers', args['markers']);
        }
        // Selection repair: the restored ids when Dart sent them (the document
        // is the catalog), Room otherwise — the Kotlin handler's rule.
        final groupIds = wireIds('restoredGroupIds') ??
            db.query('SELECT id FROM groups ORDER BY display_order, id')
                .map((r) => (r.values.first as num).toInt())
                .toList();
        if (doProfiles || doSettings) {
          if (groupIds.isNotEmpty) {
            db.execute('INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)',
                <Object?>['current_group', groupIds.first.toString()]);
          }
          final profileIds = wireIds('restoredProfileIds')?.toSet();
          if (profileIds != null) {
            for (final key in const ['profileId', 'profileCurrent']) {
              final row = db.query('SELECT value FROM settings WHERE key = ?', <Object?>[key]);
              final value = row.isEmpty ? null : '${row.first.values.first}';
              final id = int.tryParse(value?.trim() ?? '');
              if (id != null && id > 0 && !profileIds.contains(id)) {
                db.execute('DELETE FROM settings WHERE key = ?', <Object?>[key]);
              }
            }
          }
        }
        db.execute('COMMIT');
      } on Object {
        db.execute('ROLLBACK');
        rethrow;
      }
      return <String, dynamic>{'warnings': <String>[]};
    } finally {
      db.close();
    }
  }

  Future<dynamic> _containerSql(Map<String, Object?> args) async {
    switch (args['op']) {
      case 'open':
        final db = sqlite.openDatabase(confine(args['path']),
            readOnly: args['write'] != true)!;
        final id = 'h${_seq++}';
        _handles[id] = db;
        return <String, dynamic>{'handle': id};
      case 'close':
        _handles.remove(args['handle'])?.close();
        return null;
      case 'exec':
        return _handles[args['handle']]!.execute(
            args['sql'] as String, (args['params'] as List?)?.cast<Object?>() ?? const <Object?>[]);
      case 'query':
        return _handles[args['handle']]!
            .query(args['sql'] as String, (args['params'] as List?)?.cast<Object?>() ?? const <Object?>[])
            .map((r) => Map<String, Object?>.from(r))
            .toList();
      case 'writeBytes':
        File(confine(args['path'])).writeAsBytesSync(base64Decode(args['bytes'] as String));
        return null;
      case 'readBytes':
        return base64Encode(File(confine(args['path'])).readAsBytesSync());
      default:
        throw StateError('unexpected backup.container op: ${args['op']}');
    }
  }
}
