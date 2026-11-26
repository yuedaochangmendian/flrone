// ADR 0005 final stage: the production wiring for the Dart-owned profile
// document. Mirrors `route_profiles_source.dart`'s injection pattern: the store
// stays free of box.dart so it is testable, and this file is the only place that
// binds it to the host's `data.path` fact.
//
// Read/write authority for profiles/groups is the JSON document. Upgrades from
// pre-document installs are no longer supported, so there is no legacy row
// source: this source only resolves the document and applies pushes from Kotlin.

import 'dart:convert';
import 'dart:io' show FileSystemException;
import 'configuration_document_status.dart';
import 'configuration_store.dart';

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

/// Minimal extraction of the `path` field from `data.path`'s reply, without
/// importing box.dart (which imports this layer back).
String? databaseLocationPath(Object? reply) {
  if (reply is! Map) return null;
  final path = reply['path'];
  return path is String && path.isNotEmpty ? path : null;
}

/// Owns the [ConfigurationStore]. [resolvePath] asks the host once for
/// `data.path`; everything else is local file IO and the `applyDocument` flow.
class ConfigurationStoreSource {
  ConfigurationStoreSource({
    required this.resolvePath,
    ConfigurationStore? store,
  }) : _store = store;

  final Future<dynamic> Function() resolvePath;
  final ConfigurationStore? _store;

  ConfigurationStore? _resolved;

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

  /// Applies a write pushed by Kotlin (Kotlin is a caller, never a writer of
  /// the profile/group document). A single request may combine a
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
    // No resources to release: the store is a document path, not an open handle.
  }
}

/// Kept so tests can decode a pushed document the same way the channel handler
/// does.
AppliedProfilesDocument? decodeAppliedProfiles(Object? raw) =>
    AppliedProfilesDocument.parse(raw is String ? jsonDecode(raw) : raw);
