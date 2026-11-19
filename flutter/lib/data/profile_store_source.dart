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
import 'profile_store.dart';

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
    this.deleteProfileIds = const [],
    this.deleteGroupIds = const [],
    this.patchProfiles = const {},
    this.patchGroups = const {},
    this.allocateIds = false,
    this.reorderGroupId,
    this.reorderProfileIds,
    this.reorderGroups = false,
    this.trafficDeltas = const {},
  });

  final List<Map<String, dynamic>>? profiles;
  final List<Map<String, dynamic>>? groups;
  final bool replaceAll;
  final int? nextProfileId;
  final int? nextGroupId;
  final List<int> deleteProfileIds;
  final List<int> deleteGroupIds;
  /// Room-column patches keyed by row id (traffic, latency, group moves...).
  final Map<int, Map<String, dynamic>> patchProfiles;
  final Map<int, Map<String, dynamic>> patchGroups;
  /// When true, rows whose id <= 0 are assigned a real id by Dart; the reply's
  /// `allocatedIds` maps the caller's negative id to the assigned one.
  final bool allocateIds;
  /// Ordering operations performed after the row upserts in the same document.
  final int? reorderGroupId;
  final List<int>? reorderProfileIds;
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
      deleteProfileIds: ints('deleteProfileIds'),
      deleteGroupIds: ints('deleteGroupIds'),
      patchProfiles: patches('profilePatches'),
      patchGroups: patches('groupPatches'),
      allocateIds: m['allocateIds'] == true,
      reorderGroupId: (m['reorderGroupId'] as num?)?.toInt(),
      reorderProfileIds: m.containsKey('reorderProfileIds')
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

/// Minimal extraction of the `path` field from `data.path`'s reply, without
/// importing box.dart (which imports this layer back).
String? databaseLocationPath(Object? reply) {
  if (reply is! Map) return null;
  final path = reply['path'];
  return path is String && path.isNotEmpty ? path : null;
}

/// Owns the [ProfileStore] and runs the one-time migration. Injected callbacks
/// keep it free of the channel layer:
///  - [resolvePath] asks the host once for `data.path`;
///  - [markerRead]/[markerWrite] use the existing preferences document.
class ProfileStoreSource {
  ProfileStoreSource({
    required this.resolvePath,
    required this.markerRead,
    required this.markerWrite,
    ProfileStore? store,
    Future<RoomProfileReader?> Function()? openRoom,
  })  : _store = store,
        _openRoom = openRoom ?? _defaultOpenRoom;

  final Future<dynamic> Function() resolvePath;
  final Future<bool> Function() markerRead;
  final Future<void> Function() markerWrite;
  final ProfileStore? _store;
  final Future<RoomProfileReader?> Function() _openRoom;

  ProfileStore? _resolved;
  Future<ProfilesMigrationResult>? _migration;

  /// Resolves the store path from the host's `data.path`. Async because the
  /// channel answer is; everything after that is local file IO.
  Future<ProfileStore> store() async {
    final existing = _resolved;
    if (existing != null) return existing;
    final reply = await resolvePath();
    final location = databaseLocationPath(reply);
    if (location == null) {
      throw StateError('profiles store needs data.path from the host');
    }
    final dir = documentsDirFromDatabasePath(location);
    final created = _store ?? ProfileStore(path: '$dir/$profilesFileName');
    _resolved = created;
    return created;
  }

  /// A caller that does not inject a Room factory has no migration source:
  /// the document is then treated as authoritative and no Room copy is made.
  /// Production (box.dart) always injects one backed by `data.path`.
  static Future<RoomProfileReader?> _defaultOpenRoom() async => null;

  /// Whether the handover has completed, from either the preferences marker or
  /// an existing document. Safe to call before [store] resolves (just the marker).
  Future<bool> isMigrated() async {
    if (await markerRead()) return true;
    final s = _resolved;
    return s != null && await s.exists();
  }

  /// Runs the migration at most once per process. Concurrent callers share the
  /// same future, so a cold-start burst cannot open two Room readers.
  /// [force] is the explicit recovery path for a missing/corrupt document: it
  /// ignores the completed marker and rebuilds a broken document from Room.
  Future<ProfilesMigrationResult> migrate({bool force = false}) {
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
  Future<ProfilesMigrationResult> reMigrate() => migrate(force: true);

  Future<ProfilesMigrationResult> _migrate({bool force = false}) async {
    // No host path (widget tests, bridge mode, cold-start race): there is no
    // Room source to read and no document directory to write. Stay quiet — a
    // reported error here would surface a spurious snackbar in tests and on a
    // device whose channel is not up yet. The next attach retries.
    final pathProbe = databaseLocationPath(await resolvePath());
    if (pathProbe == null || pathProbe.isEmpty) {
      return const ProfilesMigrationResult(
          migrated: false, profileCount: 0, groupCount: 0);
    }
    final s = await store();
    // Open Room read-only; if it cannot be opened there is no migration source,
    // but a document (or an empty catalog) is still a valid answer.
    final room = await _openRoom();
    if (room == null) {
      if (await s.exists()) await markerWrite();
      return const ProfilesMigrationResult(
          migrated: false, profileCount: 0, groupCount: 0);
    }
    return migrateProfilesFromRoom(
      store: s,
      room: room,
      alreadyMigrated: markerRead,
      markMigrated: markerWrite,
      force: force,
    );
  }

  /// Applies a write pushed by Kotlin (Kotlin is a caller, never a writer of
  /// Room's profile/group tables any more). A single request may combine a
  /// full replace, deletes, row upserts, per-column patches and a reorder;
  /// they run in that order against the one document so no caller observes a
  /// half-applied edit.
  ///
  /// Returns the map of client-assigned (negative) ids to the real ids Dart
  /// allocated, so Kotlin can fix up in-memory entities before answering its
  /// own caller. Empty when [AppliedProfilesDocument.allocateIds] is false.
  Future<AllocatedProfileIds> apply(AppliedProfilesDocument doc) async {
    final s = await store();
    AllocatedProfileIds allocated = const AllocatedProfileIds();
    if (doc.replaceAll) {
      final current = await s.document;
      await s.replaceAll(ProfilesDocument(
        version: current.version,
        name: current.name,
        nextProfileId: doc.nextProfileId ?? current.nextProfileId,
        nextGroupId: doc.nextGroupId ?? current.nextGroupId,
        profiles: (doc.profiles ?? const []).map(ProfileRow.fromJson).toList(),
        groups: (doc.groups ?? const []).map(GroupRow.fromJson).toList(),
      ));
    } else {
      if (doc.deleteProfileIds.isNotEmpty || doc.deleteGroupIds.isNotEmpty) {
        await s.deleteIds(
          profileIds: doc.deleteProfileIds,
          groupIds: doc.deleteGroupIds,
        );
      }
      final profiles = (doc.profiles ?? const []).map(ProfileRow.fromJson).toList();
      final groups = (doc.groups ?? const []).map(GroupRow.fromJson).toList();
      if (doc.allocateIds) {
        allocated = await s.importRowsAllocating(profiles: profiles, groups: groups);
      } else if (profiles.isNotEmpty || groups.isNotEmpty) {
        await s.importRows(
          profiles: profiles,
          groups: groups,
          nextProfileId: doc.nextProfileId,
          nextGroupId: doc.nextGroupId,
        );
      }
      if (doc.patchProfiles.isNotEmpty) await s.patchProfiles(doc.patchProfiles);
      if (doc.trafficDeltas.isNotEmpty) {
        await s.addTraffic(doc.trafficDeltas.map(
          (id, d) => MapEntry(id, (rx: d.isNotEmpty ? d[0] : 0, tx: d.length > 1 ? d[1] : 0)),
        ));
      }
      if (doc.patchGroups.isNotEmpty) await s.patchGroups(doc.patchGroups);
      if (doc.reorderGroupId != null && doc.reorderProfileIds != null) {
        await s.reorderGroup(doc.reorderGroupId!, doc.reorderProfileIds!);
      }
      if (doc.reorderGroups) {
        final ids = (await s.groups()).map((g) => g.id).toList();
        await s.reorderGroups(ids);
      }
    }
    return allocated;
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
