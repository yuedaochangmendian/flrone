// ADR 0005 final stage: the production wiring for the Dart-owned profile
// document. Mirrors `route_profiles_source.dart`'s injection pattern: the store
// and the migration stay free of box.dart so they are testable, and this file
// is the only place that binds them to the host's `data.path` fact and the
// preferences marker.
//
// Read authority for profiles/groups is now the JSON document. Room is opened
// read-only strictly as the one-time migration source; after the handover the
// document is authoritative and Room's profile/group tables are never read for
// catalog/config again (they still own settings/routes).

import 'dart:convert';
import 'dart:io' show FileSystemException;
import 'configuration_document_status.dart';
import 'configuration_store.dart';
import 'sqlite.dart' show SqlRow;

/// The wire shape Kotlin parse handlers send through `profiles.applyDocument`.
/// Either a full document (a re-parse that redefines the set) or row arrays to
/// merge by id. Row values are already Room-column-keyed maps.
class AppliedProfilesDocument {
  const AppliedProfilesDocument({
    this.profiles,
    this.groups,
    this.replaceAll = false,
    this.nextProfileId,
    this.nextGroupId,
    this.deleteNodeIds = const [],
    this.deleteGroupIds = const [],
    this.patchProfiles = const {},
    this.patchGroups = const {},
    this.allocateIds = false,
    this.reorderGroupId,
    this.reorderNodeIds,
    this.reorderGroups = false,
    this.trafficDeltas = const {},
  });

  final List<Map<String, dynamic>>? profiles;
  final List<Map<String, dynamic>>? groups;
  final bool replaceAll;
  final int? nextProfileId;
  final int? nextGroupId;
  final List<int> deleteNodeIds;
  final List<int> deleteGroupIds;
  /// Room-column patches keyed by row id (traffic, latency, group moves...).
  final Map<int, Map<String, dynamic>> patchProfiles;
  final Map<int, Map<String, dynamic>> patchGroups;
  /// When true, rows whose id <= 0 are assigned a real id by Dart; the reply's
  /// `allocatedIds` maps the caller's negative id to the assigned one.
  final bool allocateIds;
  /// Ordering operations performed after the row upserts in the same document.
  final int? reorderGroupId;
  final List<int>? reorderNodeIds;
  final bool reorderGroups;
  /// Atomic traffic increments keyed by profile id: {id: [rx, tx]}.
  final Map<int, List<int>> trafficDeltas;

  static AppliedProfilesDocument? parse(Object? raw) {
    if (raw is! Map) return null;
    final m = Map<String, dynamic>.from(raw);
    List<Map<String, dynamic>>? rows(String key) {
      final value = m[key];
      if (value is! List) return null;
      return value
          .whereType<Map>()
          .map((r) => Map<String, dynamic>.from(r))
          .toList();
    }

    List<int> ints(String key) {
      final value = m[key];
      if (value is! List) return const [];
      return value.map((v) => (v as num).toInt()).toList();
    }

    Map<int, Map<String, dynamic>> patches(String key) {
      final value = m[key];
      if (value is! Map) return const {};
      return value.map((key, patch) => MapEntry(
            (key is num) ? key.toInt() : int.tryParse('$key') ?? 0,
            patch is Map ? Map<String, dynamic>.from(patch) : <String, dynamic>{},
          ));
    }

    return AppliedProfilesDocument(
      profiles: rows(profilesTable),
      groups: rows(groupsTable),
      replaceAll: m['replaceAll'] == true,
      nextProfileId: (m['nextProfileId'] as num?)?.toInt(),
      nextGroupId: (m['nextGroupId'] as num?)?.toInt(),
      deleteNodeIds: ints('deleteProfileIds'),
      deleteGroupIds: ints('deleteGroupIds'),
      patchProfiles: patches('profilePatches'),
      patchGroups: patches('groupPatches'),
      allocateIds: m['allocateIds'] == true,
      reorderGroupId: (m['reorderGroupId'] as num?)?.toInt(),
      reorderNodeIds: m.containsKey('reorderProfileIds')
          ? ints('reorderProfileIds')
          : null,
      reorderGroups: m['reorderGroups'] == true,
      trafficDeltas: (() {
        final value = m['trafficDeltas'];
        if (value is! Map) return const <int, List<int>>{};
        return value.map((key, delta) => MapEntry(
              (key is num) ? key.toInt() : int.tryParse('$key') ?? 0,
              delta is List
                  ? delta.map((v) => (v as num).toInt()).toList()
                  : <int>[0, 0],
            ));
      })(),
    );
  }
}

/// A [RoomNodeReader] over rows the host already read (see
/// [ConfigurationStoreSource.readRoomRows]): the retired database's column-keyed rows,
/// straight from Kotlin's `LegacyRoomReader`. This is the only migration source
/// on Android (ADR 0006 stage C2c2b2 removed the ffi SQLite reader).
class MapRoomNodeReader implements RoomNodeReader {
  const MapRoomNodeReader(this._profiles, this._groups);

  final List<SqlRow> _profiles;
  final List<SqlRow> _groups;

  @override
  List<SqlRow> profiles() => _profiles;

  @override
  List<SqlRow> groups() => _groups;
}

/// Minimal extraction of the `path` field from `data.path`'s reply, without
/// importing box.dart (which imports this layer back).
String? databaseLocationPath(Object? reply) {
  if (reply is! Map) return null;
  final path = reply['path'];
  return path is String && path.isNotEmpty ? path : null;
}

/// Owns the [ConfigurationStore] and runs the one-time migration. Injected callbacks
/// keep it free of the channel layer:
///  - [resolvePath] asks the host once for `data.path`;
///  - [markerRead]/[markerWrite] use the existing preferences document;
///  - [readRoomRows] is the host's read of the retired database
///    (`data.legacyRows`, Kotlin's LegacyRoomReader — the only reader of it).
///    There is no ffi SQLite reader: ADR 0006 stage C2c2b2 retired Room, and an
///    Android app cannot dlopen the platform SQLite anyway.
class ConfigurationStoreSource {
  ConfigurationStoreSource({
    required this.resolvePath,
    required this.markerRead,
    required this.markerWrite,
    ConfigurationStore? store,
    this.readRoomRows,
  }) : _store = store;

  final Future<dynamic> Function() resolvePath;
  final Future<bool> Function() markerRead;
  final Future<void> Function() markerWrite;
  final ConfigurationStore? _store;

  /// The retired database's rows, read by the host.
  ///
  /// Null = no host reader is wired (tests, bridge mode). A fresh install has
  /// no database file and answers empty row lists, which seeds an empty
  /// document.
  final Future<RoomNodeReader?> Function()? readRoomRows;

  ConfigurationStore? _resolved;
  Future<ConfigurationMigrationResult>? _migration;

  /// Resolves the store path from the host's `data.path`. Async because the
  /// channel answer is; everything after that is local file IO.
  Future<ConfigurationStore> store() async {
    final existing = _resolved;
    if (existing != null) return existing;
    final reply = await resolvePath();
    final location = databaseLocationPath(reply);
    if (location == null) {
      throw StateError('profiles store needs data.path from the host');
    }
    final dir = documentsDirFromDatabasePath(location);
    final created = _store ?? ConfigurationStore(path: '$dir/$profilesFileName');
    _resolved = created;
    return created;
  }

  /// Whether the handover has completed, from either the preferences marker or
  /// an existing document. Safe to call before [store] resolves (just the marker).
  Future<bool> isMigrated() async {
    if (await markerRead()) return true;
    final s = _resolved;
    return s != null && await s.exists();
  }

  /// Forces a fresh parse of the document for the diagnostics UI. Never reads a
  /// cached snapshot: a corrupt file could otherwise hit an in-memory copy that
  /// was loaded before it was damaged.
  ///
  /// Uses [ConfigurationStore.readFresh], not `reload`: the diagnostics page can be
  /// opened while a subscription refresh or test result is writing, and
  /// `reload` would replace the copy that write reads back.
  ///
  /// Three states only — missing / corrupt(message) / ok(counts, bytes). IO and
  /// format failures are folded into [ConfigurationDocumentCorrupt] so the caller
  /// never has to interpret an exception type.
  Future<ConfigurationDocumentStatus> status() async {
    final s = await store();
    if (!await s.exists()) return const ConfigurationDocumentMissing();
    try {
      final doc = await s.readFresh();
      return ConfigurationDocumentOk(
        groups: doc.groups.length,
        profiles: doc.profiles.length,
        bytes: await s.size(),
      );
    } on ConfigurationStoreFormatException catch (error) {
      return ConfigurationDocumentCorrupt(error.message);
    } on FileSystemException catch (error) {
      return ConfigurationDocumentCorrupt(error.message);
    }
  }

  /// Runs the migration at most once per process. Concurrent callers share the
  /// same future, so a cold-start burst cannot open two Room readers.
  /// [force] is the explicit recovery path for a missing/corrupt document: it
  /// ignores the completed marker and rebuilds a broken document from Room.
  Future<ConfigurationMigrationResult> migrate({bool force = false}) {
    if (!force) {
      final started = _migration;
      if (started != null) return started;
    }
    final future = _migrate(force: force);
    if (!force) _migration = future;
    return future;
  }

  /// Explicit recovery entry point: ignore the completed marker and rebuild a
  /// missing/corrupt document from Room. A still-valid document is kept (it is
  /// newer than Room), so this never throws away legitimate newer edits.
  Future<ConfigurationMigrationResult> reMigrate() => migrate(force: true);

  Future<ConfigurationMigrationResult> _migrate({bool force = false}) async {
    // No host path (widget tests, bridge mode, cold-start race): there is no
    // Room source to read and no document directory to write. Stay quiet — a
    // reported error here would surface a spurious snackbar in tests and on a
    // device whose channel is not up yet. The next attach retries.
    final pathProbe = databaseLocationPath(await resolvePath());
    if (pathProbe == null || pathProbe.isEmpty) {
      return const ConfigurationMigrationResult(
          migrated: false, profileCount: 0, groupCount: 0);
    }
    final s = await store();
    // Short-circuit before asking for the Room rows: after the handover the
    // reader would be fetched (and on Android that is a full catalog read over
    // the channel) only to be discarded by migrateConfigurationsFromRoom's own
    // marker/existence checks.
    //
    // The marker is only a short-circuit when the document really exists — a
    // completed marker with no file is the pre.26–29 failure mode (the write
    // reported success but the document never landed); treating that as done
    // strands the catalog empty forever. Existence is checked first, and a
    // reload validates the file even when the marker says complete, so a
    // corrupt document surfaces instead of being silently accepted.
    if (!force && await s.exists()) {
      await s.reload(); // throws on a corrupt doc rather than overwriting it
      if (await markerRead()) {
        return const ConfigurationMigrationResult(
            migrated: false, profileCount: 0, groupCount: 0);
      }
      await markerWrite();
      return const ConfigurationMigrationResult(
          migrated: false, profileCount: 0, groupCount: 0);
    }
    // The retired database is the migration source, read by the host
    // (`data.legacyRows` -> LegacyRoomReader). Android cannot dlopen the
    // platform SQLite, and no Room code exists to ask.
    final room = await readRoomRows?.call();
    if (room == null) {
      if (readRoomRows != null) {
        // A host reader was wired and could not answer: do NOT silently
        // replace the user's legacy catalog with an empty document. Surface
        // the failure (initialize reports it) and keep the old rows as the
        // only copy until an explicit reMigrate succeeds.
        throw StateError(
          'the host could not read the retired database for the profiles migration',
        );
      }
      // No host reader at all (tests, bridge mode): an empty document is still
      // a working store, and it is what keeps the catalog alive. Without the
      // file every Kotlin write would have no store at all while every
      // read goes through DartProfileStore, so imported profiles vanish and
      // the catalog stays empty forever (the v4.14.0-pre.26 regression).
      if (!await s.exists()) {
        await s.replaceAll(ProfilesDocument());
        await markerWrite();
        return const ConfigurationMigrationResult(
            migrated: true, profileCount: 0, groupCount: 0);
      }
      await markerWrite();
      return const ConfigurationMigrationResult(
          migrated: false, profileCount: 0, groupCount: 0);
    }
    return migrateConfigurationsFromRoom(
      store: s,
      room: room,
      // A marker is only authoritative when the document is actually on disk:
      // marker=true + no file is the pre.26–29 failure, which must rebuild.
      // When the file is there, reload once so a corrupt document surfaces
      // instead of being silently accepted by the marker.
      alreadyMigrated: () async {
        if (!await markerRead() || !await s.exists()) return false;
        await s.reload(); // throws on a corrupt doc rather than accepting it
        return true;
      },
      markMigrated: markerWrite,
      force: force,
    );
  }

  /// Applies a write pushed by Kotlin (Kotlin is a caller, never a writer of
  /// Room's profile/group tables any more). A single request may combine a
  /// full replace, deletes, row upserts, per-column patches and a reorder;
  /// they run in that order as ONE store edit, so no caller observes a
  /// half-applied edit and nothing interleaves between the steps.
  ///
  /// Returns the map of client-assigned (negative) ids to the real ids Dart
  /// allocated, so Kotlin can fix up in-memory entities before answering its
  /// own caller. Empty when [AppliedProfilesDocument.allocateIds] is false.
  Future<AllocatedNodeIds> apply(AppliedProfilesDocument doc) async {
    final s = await store();
    return s.applyCombined(
      replaceAll: doc.replaceAll,
      nextProfileId: doc.nextProfileId,
      nextGroupId: doc.nextGroupId,
      profiles: (doc.profiles ?? const []).map(NodeRow.fromJson).toList(),
      groups: (doc.groups ?? const []).map(ConfigurationRow.fromJson).toList(),
      allocateIds: doc.allocateIds,
      deleteNodeIds: doc.deleteNodeIds,
      deleteGroupIds: doc.deleteGroupIds,
      patches: doc.patchProfiles,
      traffic: doc.trafficDeltas.map(
        (id, d) => MapEntry(id, (rx: d.isNotEmpty ? d[0] : 0, tx: d.length > 1 ? d[1] : 0)),
      ),
      groupPatches: doc.patchGroups,
      reorderGroupId: doc.reorderGroupId,
      reorderNodeIds: doc.reorderNodeIds,
      reorderGroups: doc.reorderGroups,
    );
  }

  void dispose() {
    // The Room reader is a short-lived, one-shot migration connection owned by
    // the injected factory (box.dart closes it with its data layer).
  }
}

/// Kept so tests can decode a pushed document the same way the channel handler
/// does.
AppliedProfilesDocument? decodeAppliedProfiles(Object? raw) =>
    AppliedProfilesDocument.parse(raw is String ? jsonDecode(raw) : raw);
