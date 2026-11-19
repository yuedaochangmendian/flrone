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
  });

  final List<Map<String, dynamic>>? profiles;
  final List<Map<String, dynamic>>? groups;
  final bool replaceAll;
  final int? nextProfileId;
  final int? nextGroupId;
  final List<int> deleteProfileIds;
  final List<int> deleteGroupIds;

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

    return AppliedProfilesDocument(
      profiles: rows(profilesTable),
      groups: rows(groupsTable),
      replaceAll: m['replaceAll'] == true,
      nextProfileId: (m['nextProfileId'] as num?)?.toInt(),
      nextGroupId: (m['nextGroupId'] as num?)?.toInt(),
      deleteProfileIds: ints('deleteProfileIds'),
      deleteGroupIds: ints('deleteGroupIds'),
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
  Future<ProfilesMigrationResult> migrate() {
    final started = _migration;
    if (started != null) return started;
    final future = _migrate();
    _migration = future;
    return future;
  }

  Future<ProfilesMigrationResult> _migrate() async {
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
    );
  }

  /// Applies a document pushed by Kotlin's parse handlers.
  Future<void> apply(AppliedProfilesDocument doc) async {
    final s = await store();
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
      return;
    }
    if (doc.deleteProfileIds.isNotEmpty || doc.deleteGroupIds.isNotEmpty) {
      await s.deleteIds(
        profileIds: doc.deleteProfileIds,
        groupIds: doc.deleteGroupIds,
      );
      // Rows to add in the same operation (e.g. re-import) come after the delete.
      if ((doc.profiles?.isNotEmpty ?? false) || (doc.groups?.isNotEmpty ?? false)) {
        await s.importRows(
          profiles: (doc.profiles ?? const []).map(ProfileRow.fromJson).toList(),
          groups: (doc.groups ?? const []).map(GroupRow.fromJson).toList(),
          nextProfileId: doc.nextProfileId,
          nextGroupId: doc.nextGroupId,
        );
      }
      return;
    }
    await s.importRows(
      profiles: (doc.profiles ?? const []).map(ProfileRow.fromJson).toList(),
      groups: (doc.groups ?? const []).map(GroupRow.fromJson).toList(),
      nextProfileId: doc.nextProfileId,
      nextGroupId: doc.nextGroupId,
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
