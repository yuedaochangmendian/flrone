// A host-channel mock for the backup write path (P14; ADR 0006 stage C2c2a).
// It emulates the host methods the Kotlin side implements — the settings and
// markers document ops, `data.legacyRows`, and the backup container's SQL
// transport (`backup.container`) — backed by the same low-level SQLite the
// fixture uses, so the host path can be exercised on a desktop host without an
// Android device, with real SQL semantics.
//
// Production passes these calls to Kotlin over MethodChannel; here a fake
// `RoomSnapshotHost.call` routes them to in-process ffi. What the test pins is
// the WIRE SHAPE (method names, arg keys, row maps) and that Dart takes the host
// branch when ffi is unavailable. [FakeBackupHost.confine] mirrors the host's
// cache-tree confinement, so a Dart call site that reaches for the live database
// or the documents directory fails here too.

import 'dart:convert';
import 'dart:io';

import 'package:flrone/data/sqlite.dart' show Sqlite, SqliteDatabase;
import 'package:flrone/services/backup_write.dart' show SettingsRestore;
import 'package:flrone/services/room_snapshot_host.dart';

import 'backup_fixture.dart' show BackupSink;

/// The `settings.restore` wire map back into the request the sink consumes.
SettingsRestore settingsRestoreFromWire(Map<String, Object?> args) {
  List<int>? ids(String key) {
    final raw = args[key];
    if (raw is! List) return null;
    return [
      for (final value in raw)
        if (value is num) value.toInt(),
    ];
  }

  final rawSettings = args['settings'];
  return SettingsRestore(
    settings: args['hasSettings'] == true && rawSettings is Map
        ? <String, String>{
            for (final entry in rawSettings.entries) '${entry.key}': '${entry.value}',
          }
        : null,
    fromAndroid: args['fromAndroid'] == true,
    restoredProfiles: args['restoredProfiles'] == true,
    groupIds: ids('restoredGroupIds'),
    profileIds: ids('restoredProfileIds'),
    routeIds: ids('restoredRouteIds'),
  );
}

class FakeBackupHost {
  FakeBackupHost(
    this.sqlite, {
    String? containerRoot,
    BackupSink? sink,
    this.legacy = const <String, dynamic>{},
  })  : containerRoot = containerRoot ?? Directory.systemTemp.path,
        sink = sink ?? BackupSink();

  final Sqlite sqlite;

  /// The settings/markers documents this fake holds.
  final BackupSink sink;

  /// The `data.legacyRows` reply; tests build it with [legacyReply].
  final Map<String, dynamic> legacy;

  /// The app's cache tree on a device; the fake's stand-in is the system temp
  /// dir, where `Directory.systemTemp.createTemp` actually puts the snapshots.
  final String containerRoot;
  final Map<String, SqliteDatabase> _handles = <String, SqliteDatabase>{};
  final List<String> methods = <String>[];
  int _seq = 0;

  RoomSnapshotHost toHost() => RoomSnapshotHost(call: handle);

  /// The container path guard, mirroring `FlroneRoomSnapshot.confinedContainerFile`:
  /// the app's own storage only, with the live database directory, the documents
  /// directory and the rule-set catalog refused by segment.
  String confine(Object? rawPath) {
    final path = '${rawPath ?? ''}';
    if (path.isEmpty) throw StateError('backup.container needs a path');
    // `File.absolute` keeps `..` in `path` (Windows may normalise it), and
    // `File.uri.pathSegments` normalises the dot segments away, so a raw check
    // is the only reliable one: `/tmp/../elsewhere/backup.db` would otherwise
    // pass the prefix check below.
    if (path.split(RegExp(r'[/\\]+')).contains('..')) {
      throw StateError("backup.container path is outside the app's private storage: $path");
    }
    final file = File(path).absolute;
    final segments = file.uri.pathSegments;
    final name = segments.last;
    if (name == 'sager_net.db' || name.startsWith('sager_net.db-')) {
      throw StateError('backup.container must not open the live database: $path');
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
    methods.add(method);
    final args = (rawArgs is Map) ? Map<String, Object?>.from(rawArgs) : <String, Object?>{};
    switch (method) {
      case 'settings.snapshot':
        return <String, dynamic>{
          'rows': [
            for (final entry in sink.snapshotSettings().entries)
              <String, Object?>{'key': entry.key, 'value': entry.value},
          ],
        };
      case 'markers.snapshot':
        return <String, dynamic>{'rows': sink.snapshotMarkers()};
      case 'settings.restore':
        return <String, dynamic>{
          'warnings': sink.restoreSettings(settingsRestoreFromWire(args)),
        };
      case 'markers.restore':
        sink.restoreMarkers(<Map<String, Object?>>[
          for (final row in (args['rows'] as List? ?? const []))
            if (row is Map) Map<String, Object?>.from(row),
        ]);
        return null;
      case 'data.legacyRows':
        return legacy;
      case 'backup.container':
        return _containerSql(args);
      default:
        throw StateError('unexpected host method: $method');
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

/// The `data.legacyRows` reply a raw read-only reader would answer: each table
/// only while its document is absent, all-empty lists when the database file is
/// missing (which it must never create).
Map<String, dynamic> legacyReply(
  Sqlite sqlite,
  String databasePath, {
  required String documentsDir,
}) {
  List<Map<String, Object?>> none() => <Map<String, Object?>>[];
  final empty = <String, dynamic>{
    'profiles': none(),
    'groups': none(),
    'routeProfiles': none(),
    'routeRules': none(),
    'globalRouteRules': none(),
    'settings': none(),
    'markers': none(),
  };
  final file = File(databasePath);
  if (!file.existsSync()) return empty;
  final db = sqlite.openDatabase(databasePath, readOnly: true);
  if (db == null) return empty;
  try {
    final tables = db
        .query("SELECT name FROM sqlite_master WHERE type='table'")
        .map((row) => '${row.values.first}')
        .toSet();
    bool absent(String name) => !File('$documentsDir/$name').existsSync();
    List<Map<String, Object?>> rows(String table, bool enabled) {
      if (!enabled || !tables.contains(table)) return none();
      return db
          .query('SELECT * FROM `$table`')
          .map((row) => Map<String, Object?>.from(row))
          .toList();
    }

    final profiles = absent('profiles.json');
    final routes = absent('route_profiles.json');
    final settings = absent('settings.json');
    final markers = absent('markers.json');
    return <String, dynamic>{
      'profiles': rows('profiles', profiles),
      'groups': rows('groups', profiles),
      'routeProfiles': rows('route_profiles', routes),
      'routeRules': rows('route_rules', routes),
      'globalRouteRules': rows('global_route_rules', routes),
      'settings': rows('settings', settings),
      'markers': rows('markers', markers),
    };
  } finally {
    db.close();
  }
}
