// The pure data half of Kotlin `SubscriptionReconcile` (the port of the
// desktop's SubscriptionReconcile.cpp / GroupUpdater.cpp digest and diff pass).
//
// This file deliberately owns no platform state: no HTTP, no profile store, no
// document writes. It hashes canonical stored JSON strings the caller already
// has (Go `profileImport`/`profileExport` emit them as the node's `json` field),
// pairs arrivals to old rows by identity, and produces the reconciliation plan a
// future subscription queue will apply. The Kotlin original lives at
// `app/src/main/java/io/nekohasekai/sagernet/group/SubscriptionReconcile.kt`
// and the refresh caller at `SubscriptionRefresh.kt` (ImportSink.add/finish).
//
// Every rule below is a direct port; in particular the two passes in
// `reconcileSubscription` run in Kotlin's order (updates, stale, order) and all
// FIFO queues are keyed in group/arrival order rather than sorted, because a
// duplicate claims the *first* unclaimed old row in group order (#1775).

import 'dart:collection';
import 'dart:convert';

import '../services/backup_store.dart' show thrnSha256Hex;

/// `contentKeyOf` (GroupUpdater.cpp:32-34): the SHA-256, as lowercase hex, of
/// the UTF-8 bytes of the canonical compact stored JSON. `exportJson` must be
/// the canonical string itself (the Go exporter's `json`), not a re-encode of
/// it: re-encoding can change key order and therefore the digest.
String subscriptionContentKey(String exportJson) =>
    thrnSha256Hex(utf8.encode(exportJson));

/// `identityKeyOf` (GroupUpdater.cpp:36-38): the digest of `type|identityJson`.
/// The pipe is literal ASCII even when either side is empty; Kotlin's
/// `"$type|$identityJson"` does the same.
String subscriptionIdentityKey(String type, String identityJson) =>
    thrnSha256Hex(utf8.encode('$type|$identityJson'));

/// An old group member, in group order. Port of Kotlin `OldEntry`.
///
/// [content] is the already-computed content key, [identity] the already-computed
/// identity key; [display] is the human label used in the change report only.
class SubscriptionOldEntry {
  const SubscriptionOldEntry(this.id, this.content, this.identity, this.display);

  final int id;
  final String content;
  final String identity;
  final String display;
}

/// A parsed arrival, in arrival order. Port of Kotlin `NewEntry`.
///
/// [id] follows the same contract as the Kotlin field: it is the claimed old
/// id when [reused], the updated old id when [supersedes] is positive, the id
/// assigned by storage for an inserted row, or -1 when nothing was stored.
class SubscriptionNewEntry {
  SubscriptionNewEntry(this.display);

  final String display;
  int id = -1;
  bool reused = false;
  bool contentKnown = false;
  String content = '';

  /// Computed only when the content was never known (see [prepareSubscriptionArrival]).
  String identity = '';

  /// The old row of the same identity that takes this arrival's data in place;
  /// 0 means none.
  int supersedes = 0;
}

/// Mirrors `ImportSink.add`'s indexed branch (SubscriptionRefresh.kt:691-711):
/// hash the canonical stored JSON, announce the arrival, claim an identical old
/// row once, and compute the identity key only for content that was never known.
///
/// The caller keeps the parsed node alongside the returned entry at the same
/// index; a future queue uses that pairing to write the patch/insert payloads
/// described by [SubscriptionApplyPlan]. The unindexed plain-import path in
/// Kotlin has no diff and is not part of this layer.
SubscriptionNewEntry prepareSubscriptionArrival(
  SubscriptionContentIndex index, {
  required String display,
  required String storedJson,
  required String type,
  required String identityJson,
}) {
  final entry = SubscriptionNewEntry(display);
  entry.content = subscriptionContentKey(storedJson);
  index.noteArrival(entry.content);
  entry.contentKnown = index.knows(entry.content);
  final claimed = index.claim(entry.content);
  if (claimed != null) {
    entry.id = claimed;
    entry.reused = true;
    return entry;
  }
  if (!entry.contentKnown) {
    entry.identity = subscriptionIdentityKey(type, identityJson);
  }
  return entry;
}

/// `ContentIndex` (SubscriptionReconcile.kt:107-137): each old profile is
/// claimed at most once, in group order, by identical arrivals in arrival
/// order. Insertion order of the queues is significant; do not sort them.
class SubscriptionContentIndex {
  SubscriptionContentIndex(Iterable<SubscriptionOldEntry> old) {
    for (final entry in old) {
      (_unclaimed[entry.content] ??= Queue<int>()).addLast(entry.id);
      _known.add(entry.content);
    }
  }

  final Map<String, Queue<int>> _unclaimed = <String, Queue<int>>{};
  final Set<String> _known = <String>{};
  final Set<String> _arrivals = <String>{};
  final Set<int> _claimedIds = <int>{};

  bool knows(String content) => _known.contains(content);

  /// Claims the first unclaimed old id with this content, or returns null.
  int? claim(String content) {
    final ids = _unclaimed[content];
    if (ids == null || ids.isEmpty) return null;
    final id = ids.removeFirst();
    _claimedIds.add(id);
    return id;
  }

  void noteArrival(String content) {
    _arrivals.add(content);
  }

  bool arrived(String content) => _arrivals.contains(content);

  bool isClaimed(int id) => _claimedIds.contains(id);
}

/// The identity pass of `Reconcile` (SubscriptionReconcile.cpp:19-63), once
/// every arrival has gone through [prepareSubscriptionArrival] and before any
/// is stored: an arrival that pairs with a leftover old row gets it as
/// [SubscriptionNewEntry.supersedes], so it updates that row in place instead of
/// being inserted and deleted again.
///
/// Leftovers are old rows the content pass never saw: neither claimed nor of a
/// content that arrived. Arrivals eligible for pairing are those neither reused
/// nor content-known. Both sides are consumed FIFO (group order / arrival
/// order), so one old row can never supersede two arrivals.
void pairSubscriptionByIdentity(
  Iterable<SubscriptionOldEntry> old,
  Iterable<SubscriptionNewEntry> incoming,
  SubscriptionContentIndex index,
) {
  final leftoverByIdentity = <String, Queue<int>>{};
  for (final entry in old) {
    if (index.isClaimed(entry.id) || index.arrived(entry.content)) continue;
    (leftoverByIdentity[entry.identity] ??= Queue<int>()).addLast(entry.id);
  }
  for (final entry in incoming) {
    if (entry.reused || entry.contentKnown) continue;
    final leftovers = leftoverByIdentity[entry.identity];
    if (leftovers == null || leftovers.isEmpty) continue;
    entry.supersedes = leftovers.removeFirst();
  }
}

/// `ReconcilePlan` (SubscriptionReconcile.kt:139-149): the document order plus
/// the update/delete sets and the display-name lists used by the change report.
/// Lists preserve Kotlin's construction order, not sort order.
class SubscriptionReconcilePlan {
  /// The group's new list: old ids (kept or updated in place) and new ids in
  /// arrival order.
  final List<int> order = <int>[];

  /// Old ids that took an arrival's data in place.
  final List<int> updates = <int>[];
  final List<int> stale = <int>[];
  final List<String> added = <String>[];
  final List<String> updated = <String>[];
  final List<String> deleted = <String>[];
}

/// `Reconcile` (SubscriptionReconcile.cpp:19-63) over the stored arrivals,
/// paired by [pairSubscriptionByIdentity].
///
/// Pass one collects updates and matches the old ids they replace. Pass two
/// marks every old row that was neither claimed by the content pass nor matched
/// by an update as stale. Pass three builds [SubscriptionReconcilePlan.order]:
/// a superseding arrival contributes the old id, a reused arrival its claimed
/// id, an inserted arrival its stored id, and an arrival with no stored id
/// contributes nothing. Only inserted arrivals appear in `plan.added`.
SubscriptionReconcilePlan reconcileSubscription(
  Iterable<SubscriptionOldEntry> old,
  Iterable<SubscriptionNewEntry> incoming,
  SubscriptionContentIndex index,
) {
  final plan = SubscriptionReconcilePlan();

  final matchedOld = <int>{};
  for (final entry in incoming) {
    if (entry.supersedes <= 0) continue;
    plan.updates.add(entry.supersedes);
    plan.updated.add(entry.display);
    matchedOld.add(entry.supersedes);
  }

  for (final entry in old) {
    if (index.isClaimed(entry.id) || matchedOld.contains(entry.id)) continue;
    plan.stale.add(entry.id);
    plan.deleted.add(entry.display);
  }

  for (final entry in incoming) {
    if (entry.supersedes > 0) {
      plan.order.add(entry.supersedes);
      continue;
    }
    if (entry.id < 0) continue;
    plan.order.add(entry.id);
    if (!entry.reused) plan.added.add(entry.display);
  }
  return plan;
}

/// One in-place patch for a future queue: the old row [oldId] receives the data
/// of the arrival at [arrivalIndex]. The canonical stored JSON, name and type
/// stay with the caller's arrival payload, exactly as Kotlin's ImportSink keeps
/// its `pending` Outbound list next to the entries.
class SubscriptionProfilePatch {
  const SubscriptionProfilePatch(this.oldId, this.arrivalIndex);

  final int oldId;
  final int arrivalIndex;
}

/// The write-shaped view of a [SubscriptionReconcilePlan], derived without
/// touching storage. This is the data a future queue apply needs: patch the
/// updated rows with the matching arrivals, insert the stored new arrivals,
/// delete the stale rows, then publish [order] as the group's member list.
class SubscriptionApplyPlan {
  SubscriptionApplyPlan._(
    this.order,
    this.patches,
    this.insertArrivals,
    this.deleteIds,
  );

  /// Derives the apply shape. [incoming] must be the same list, in the same
  /// order, that was passed to [reconcileSubscription].
  factory SubscriptionApplyPlan.from(
    SubscriptionReconcilePlan plan,
    List<SubscriptionNewEntry> incoming,
  ) {
    final patches = <SubscriptionProfilePatch>[];
    final insertArrivals = <int>[];
    for (var i = 0; i < incoming.length; i++) {
      final entry = incoming[i];
      if (entry.supersedes > 0) {
        patches.add(SubscriptionProfilePatch(entry.supersedes, i));
      } else if (entry.id > 0 && !entry.reused) {
        insertArrivals.add(i);
      }
    }
    return SubscriptionApplyPlan._(
      List<int>.from(plan.order),
      patches,
      insertArrivals,
      List<int>.from(plan.stale),
    );
  }

  final List<int> order;
  final List<SubscriptionProfilePatch> patches;
  final List<int> insertArrivals;
  final List<int> deleteIds;
}

/// Convenience: the full pure pass for one refresh — index the old group,
/// prepare the arrivals, pair by identity, and build both the report plan and
/// the apply shape. Kept side-effect free apart from the mutable entries it
/// returns, matching Kotlin's pair-then-reconcile call order.
///
/// [assignedIds] supplies the storage-assigned ids for arrivals that are
/// neither reused nor superseding (Kotlin's `addProfileBatch` result). A future
/// queue inserts those rows first, then calls this to obtain a complete plan;
/// with no ids supplied the inserted arrivals have no id yet and are simply
/// absent from `plan.order`/`plan.added`, exactly like Kotlin before `finish`.
SubscriptionRefreshPlan planSubscriptionRefresh({
  required List<SubscriptionOldEntry> old,
  required List<String> storedJson,
  required List<String> types,
  required List<String> identityJson,
  required List<String> displays,
  Map<int, int> assignedIds = const <int, int>{},
}) {
  if (storedJson.length != types.length ||
      storedJson.length != identityJson.length ||
      storedJson.length != displays.length) {
    throw ArgumentError('arrival lists must have the same length');
  }
  final index = SubscriptionContentIndex(old);
  final entries = <SubscriptionNewEntry>[];
  for (var i = 0; i < storedJson.length; i++) {
    entries.add(prepareSubscriptionArrival(
      index,
      display: displays[i],
      storedJson: storedJson[i],
      type: types[i],
      identityJson: identityJson[i],
    ));
  }
  pairSubscriptionByIdentity(old, entries, index);
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry.supersedes > 0) {
      // Kotlin's patch loop: an update keeps the old row's id.
      entry.id = entry.supersedes;
    } else if (!entry.reused && assignedIds.containsKey(i)) {
      entry.id = assignedIds[i]!;
    }
  }
  final plan = reconcileSubscription(old, entries, index);
  return SubscriptionRefreshPlan(
    index: index,
    entries: entries,
    plan: plan,
    apply: SubscriptionApplyPlan.from(plan, entries),
  );
}

/// Bundles the mutable arrival entries with the two plans produced by
/// [planSubscriptionRefresh].
class SubscriptionRefreshPlan {
  const SubscriptionRefreshPlan({
    required this.index,
    required this.entries,
    required this.plan,
    required this.apply,
  });

  final SubscriptionContentIndex index;
  final List<SubscriptionNewEntry> entries;
  final SubscriptionReconcilePlan plan;
  final SubscriptionApplyPlan apply;
}
