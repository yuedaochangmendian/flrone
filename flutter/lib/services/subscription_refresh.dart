// The first production slice of ADR 0008 S6: the core subscription refresh data
// path, ported from Kotlin `SubscriptionRefresh.kt` into pure Dart.
//
// Kotlin's `refresh` = fetch -> validate -> parse -> reconcile -> one document
// edit -> report. This file owns exactly that data path and nothing else:
//
//   * the document is reached through [SubscriptionDocumentGateway]; the
//     bundled adapter [ConfigurationStoreSubscriptionGateway] routes every
//     write to `ConfigurationStore.applyCombined` (the same single serialized
//     edit `ProfileDocumentService` uses). No file is opened or written here;
//   * the download goes through [SubscriptionHttpTransport] (or an injected
//     async fetcher for tests); the parse goes through an injected Go
//     `profileImport` bridge;
//   * digest/claim/identity pairing and the apply plan come from the existing
//     pure port in `data/subscription_reconcile.dart` — no digest is duplicated;
//   * queue events are plain callbacks, so neither `subscription_queue.dart`
//     nor a platform service is needed to test the refresh.
//
// Deliberately NOT ported in this slice (Kotlin-only extras). They are listed
// in [s6UnsupportedFeatures], surfaced in [SubscriptionRefreshResult.skippedFeatures]
// and reported through [SubscriptionRefreshService.onUnsupportedFeature], so a
// later slice can add them without silently approximating their behaviour:
// route rebinding, auto-selector runtime updates, URL-test follow-ups,
// multi-selector sticky rows, dynamic device HWID and HTTP/2/TLS pinning.
// Name include/exclude filters are ported here (`filterSubscriptionNodeNames`).
//
// `content://` URLs and front/landing-proxy groups ARE served now: when a
// [SubscriptionHostFetcher] is injected (the service engine injects the
// `subscription.fetch` host call), those groups' one-shot bodies come from
// Kotlin's own `SubscriptionFetch` — ContentResolver read, RequestIdentity and
// the OkHttp/proxy path — instead of a direct Dart socket. Everything else
// (plain HTTP(S), redirects, auth, caps, metadata) stays in Dart.
//
// Production wiring (the queue runner, `ProfileDocumentService`, host bridge)
// is a separate slice; this file never imports or modifies it.

import 'dart:convert';

import '../data/configuration_store.dart'
    show ConfigurationRow, ConfigurationStore, NodeRow;
import '../data/subscription_reconcile.dart'
    show
        SubscriptionApplyPlan,
        SubscriptionContentIndex,
        SubscriptionNewEntry,
        SubscriptionOldEntry,
        SubscriptionReconcilePlan,
        pairSubscriptionByIdentity,
        prepareSubscriptionArrival,
        reconcileSubscription,
        subscriptionContentKey,
        subscriptionIdentityKey;
import 'subscription_transport.dart'
    show
        SubscriptionFetchResult,
        SubscriptionHttpTransport,
        SubscriptionMetadata,
        subscriptionUrlNeedsHost;

/// A parsed node from the Go `profileImport` bridge.
///
/// [json] is the canonical stored JSON (`profileImport`'s `json` field), never
/// a re-encoding: the content digest in the reconcile port is byte-exact.
/// [identity] is that bridge's `identity` field, used only for supersede
/// pairing when the stored content is new. [dedupKey] is optional; when absent
/// the service uses `type|identity`, matching Kotlin `distinctNodes`' intent
/// (Kotlin keys on an export link with metadata stripped; the caller can supply
/// that link explicitly here).
class ProfileImportNode {
  const ProfileImportNode({
    required this.type,
    required this.name,
    required this.json,
    required this.identity,
    this.dedupKey = '',
  });

  final String type;
  final String name;
  final String json;
  final String identity;
  final String dedupKey;

  String get display => '[$type] $name';
}

/// The result of one `profileImport` call.
///
/// [supported] false means the bridge refused a body it cannot parse in this
/// build (advanced TLS/transport, unknown protocol); the service treats that
/// as a parse rejection and leaves the document untouched rather than guessing.
/// [text] is the importer's problem report, forwarded to the report callback.
class ProfileImportResult {
  const ProfileImportResult({
    this.nodes = const <ProfileImportNode>[],
    this.supported = true,
    this.text = '',
  });

  final List<ProfileImportNode> nodes;
  final bool supported;
  final String text;
}

/// Fetch seam. `SubscriptionHttpTransport.fetch` has exactly this signature;
/// tests inject a future-returning lambda so no socket is opened.
typedef SubscriptionRefreshFetcher = Future<SubscriptionFetchResult> Function(
  String url, {
  Map<String, String> headers,
});

/// Host fetch seam for the one-shot bodies a Dart isolate cannot reach:
/// `content://` (ContentResolver) and front/landing-proxy groups (the host's
/// OkHttp/RequestIdentity path). [subOptionsJson] lets the host resolve the
/// same user agent/TLS/HTTP identity a stored group would; [gid] is the stored
/// group (0 for an editor create, which reads the options JSON instead).
typedef SubscriptionHostFetcher = Future<SubscriptionFetchResult> Function(
  String url, {
  required String subOptionsJson,
  int gid,
});

/// Parse seam (Go `profileImport` action via the host bridge).
typedef SubscriptionBodyParser = Future<ProfileImportResult> Function(String body);

/// A single combined edit of the subscription group and its rows.
///
/// The shapes deliberately mirror `ConfigurationStore.applyCombined`:
/// [insertNodes] carry temporary *positive* placeholder ids at or above
/// [subscriptionPlaceholderIdBase] (never persisted), [nodePatches] are
/// Room-column-keyed partial updates, and [groupPatches] patch the `groups`
/// row. One call must be one serialized document edit (Kotlin's "single edit"
/// semantics) — no half-applied order or metadata.
class SubscriptionGatewayApply {
  const SubscriptionGatewayApply({
    required this.gid,
    this.insertNodes = const <NodeRow>[],
    this.nodePatches = const <int, Map<String, dynamic>>{},
    this.deleteNodeIds = const <int>[],
    this.groupPatches = const <int, Map<String, dynamic>>{},
    this.reorderNodeIds,
  });

  final int gid;
  final List<NodeRow> insertNodes;
  final Map<int, Map<String, dynamic>> nodePatches;
  final Iterable<int> deleteNodeIds;
  final Map<int, Map<String, dynamic>> groupPatches;

  /// The group's new member order. Entries equal to an [insertNodes] placeholder
  /// must be replaced by the real allocated id before the document is saved.
  final List<int>? reorderNodeIds;
}

/// The ids storage assigned to the [SubscriptionGatewayApply.insertNodes]
/// placeholders, keyed by placeholder id.
class SubscriptionGatewayApplyResult {
  const SubscriptionGatewayApplyResult({
    this.insertedIds = const <int, int>{},
  });

  final Map<int, int> insertedIds;
}

/// The document gateway the refresh needs.
///
/// Production implementation note: this is a thin adapter over
/// `ProfileDocumentService`'s `ConfigurationStore` — [groupByGid] and
/// [membersOfGroup] are document reads, [apply] is routed to
/// `ConfigurationStore.applyCombined`, and [identityJsonOf] is answered by the
/// Go `profileExport` action's `identity` output. It never writes a file
/// itself. See [ConfigurationStoreSubscriptionGateway].
abstract class SubscriptionDocumentGateway {
  Future<ConfigurationRow?> groupByGid(int gid);

  /// Current members in group order (`user_order`, then `id`), matching
  /// `ConfigurationStore.profilesOfGroup` / `membersOf`.
  Future<List<NodeRow>> membersOfGroup(int gid);

  /// The stored row's `exportIdentity()` JSON. Empty means unknown: that row is
  /// then excluded from identity pairing (it can still be reused by content).
  Future<String> identityJsonOf(NodeRow row);

  /// Applies the whole refresh as one edit; returns allocated ids.
  Future<SubscriptionGatewayApplyResult> apply(SubscriptionGatewayApply request);

  /// Inserts a NEW subscription group in one combined edit and returns its
  /// store-allocated id. Deliberately a default method: the refresh-only fakes
  /// in the existing tests keep working unchanged, while the create path gets
  /// a seam that is backed by the same serialized document edit as [apply].
  ///
  /// [autoUpdate] mirrors Kotlin `ProxyGroup.skipAutoUpdate = !autoUpdate`: it
  /// is a group column, not part of `SubscriptionOptions.toJsonString()`.
  /// The single-node flag is left false (a subscription is a real group).
  Future<int> createSubscriptionGroup({
    required String name,
    required String url,
    required String subOptionsJson,
    bool autoUpdate = true,
  }) =>
      throw UnsupportedError('this gateway cannot create subscription groups');

  /// Best-effort rollback for a create whose node-apply edit failed after the
  /// group row was allocated. Default no-op keeps refresh-only fakes valid;
  /// the production store deletes the empty group in one edit.
  Future<void> deleteSubscriptionGroup(int gid) async {}
}

/// Sentinel ids for rows that are about to be inserted. They are positive so
/// [reconcileSubscription] sees them as stored arrivals, but far above any real
/// `nextProfileId` so a gateway can never mistake one for an existing row.
const int subscriptionPlaceholderIdBase = 1 << 60;

/// Document gateway backed by [ConfigurationStore].
///
/// [identityResolver] is the Go `profileExport` seam: the document stores only
/// `outbound_json`, while Kotlin derived the identity from the parsed outbound
/// model. Until that bridge is wired, returning '' keeps content reuse working
/// and only disables supersede pairing for old rows.
class ConfigurationStoreSubscriptionGateway implements SubscriptionDocumentGateway {
  ConfigurationStoreSubscriptionGateway(this.store, {this.identityResolver});

  final ConfigurationStore store;
  final Future<String> Function(NodeRow row)? identityResolver;

  @override
  Future<ConfigurationRow?> groupByGid(int gid) => store.group(gid);

  @override
  Future<List<NodeRow>> membersOfGroup(int gid) => store.profilesOfGroup(gid);

  @override
  Future<String> identityJsonOf(NodeRow row) async =>
      (await identityResolver?.call(row)) ?? '';

  @override
  Future<SubscriptionGatewayApplyResult> apply(SubscriptionGatewayApply request) async {
    // applyCombined allocates only rows with id <= 0, so the placeholder ids
    // used by the plan become temporary negative sentinels here; the returned
    // client->real map is re-keyed from placeholder to sentinel and back.
    final sentinels = <int, int>{};
    final rows = <NodeRow>[];
    for (var i = 0; i < request.insertNodes.length; i++) {
      final row = request.insertNodes[i];
      final sentinel = -(i + 1);
      sentinels[row.id] = sentinel;
      rows.add(row.copyWith(id: sentinel));
    }
    final order = request.reorderNodeIds == null
        ? null
        : <int>[
            for (final id in request.reorderNodeIds!)
              sentinels.containsKey(id) ? sentinels[id]! : id,
          ];
    final allocated = await store.applyCombined(
      replaceAll: false,
      profiles: rows,
      allocateIds: true,
      deleteNodeIds: request.deleteNodeIds,
      patches: request.nodePatches,
      groupPatches: request.groupPatches,
      reorderGroupId: order == null ? null : request.gid,
      reorderNodeIds: order,
    );
    return SubscriptionGatewayApplyResult(
      insertedIds: <int, int>{
        for (final entry in sentinels.entries)
          if (allocated.profiles.containsKey(entry.value))
            entry.key: allocated.profiles[entry.value]!,
      },
    );
  }

  @override
  Future<int> createSubscriptionGroup({
    required String name,
    required String url,
    required String subOptionsJson,
    bool autoUpdate = true,
  }) async {
    // One applyCombined: the group row is allocated by the store, so no half
    // created group can be observed by a concurrent writer. Metadata and nodes
    // land in the caller's second edit (the create service's single apply).
    final allocated = await store.applyCombined(
      replaceAll: false,
      allocateIds: true,
      groups: <ConfigurationRow>[
        ConfigurationRow(
          id: 0, // client allocation sentinel; the store assigns the real id
          name: name,
          url: url,
          subOptionsJson: subOptionsJson,
          skipAutoUpdate: !autoUpdate,
          single: false,
        ),
      ],
    );
    final id = allocated.groups[0];
    if (id == null || id <= 0) {
      throw StateError('the store did not allocate a subscription group id');
    }
    return id;
  }

  @override
  Future<void> deleteSubscriptionGroup(int gid) async {
    // A group row created by [createSubscriptionGroup] has no members yet; if
    // the subsequent node apply fails, remove it so a failed create leaves no
    // empty subscription behind. This is its own serialized edit; the caller
    // only uses it on the failure path.
    await store.applyCombined(
      replaceAll: false,
      deleteGroupIds: <int>[gid],
    );
  }
}

/// Where a refresh's problems go, mirroring Kotlin's `Surface`.
enum SubscriptionRefreshSurface { log, diff, report }

/// Machine-readable stopping reasons, mirroring Kotlin `Rejected.Reason` plus
/// the two Dart-only refusal paths (bridge refusal, concurrent stale answer).
enum SubscriptionRefreshOutcome {
  applied,
  noop,
  fetchFailed,
  empty,
  webPage,
  filtered,
  parseRefused,
  stale,
}

/// Kotlin-only extras this slice intentionally does not emulate. `content://`
/// and front/landing proxies are no longer in this set: they are served by the
/// host `subscription.fetch` seam, and only reported when that seam is absent.
enum SubscriptionUnsupportedFeature {
  routeRebinding,
  autoSelectorRuntime,
  urlTestFollowUp,
  frontLandingProxy,
  multiSelectorStickyRows,
  contentUrlInput,
  dynamicHwid,
  http2TlsPinning,
}

const Set<SubscriptionUnsupportedFeature> s6UnsupportedFeatures = <SubscriptionUnsupportedFeature>{
  SubscriptionUnsupportedFeature.routeRebinding,
  SubscriptionUnsupportedFeature.autoSelectorRuntime,
  SubscriptionUnsupportedFeature.urlTestFollowUp,
  SubscriptionUnsupportedFeature.multiSelectorStickyRows,
  SubscriptionUnsupportedFeature.dynamicHwid,
  SubscriptionUnsupportedFeature.http2TlsPinning,
};

/// Callback event states. Values match `SubscriptionQueueStates`
/// (0 idle / 1 queued / 2 running); the constants are repeated here so this
/// pure slice does not import the queue.
abstract final class SubscriptionRefreshStates {
  static const int idle = 0;
  static const int queued = 1;
  static const int running = 2;
}

/// What one refresh did. [applied] is true only when the document edit ran;
/// [changed] counts structural row changes (reorder/metadata-only updates are
/// applied but not "changed"). [storedIds] lists the group's new member ids in
/// arrival order, including reused and superseded rows.
class SubscriptionRefreshResult {
  const SubscriptionRefreshResult({
    required this.gid,
    required this.outcome,
    this.applied = false,
    this.changed = false,
    this.added = 0,
    this.updated = 0,
    this.deleted = 0,
    this.addedNames = const <String>[],
    this.updatedNames = const <String>[],
    this.deletedNames = const <String>[],
    this.storedIds = const <int>[],
    this.error = '',
    this.reportText = '',
    this.metadata = '',
    this.skippedFeatures = const <String>[],
  });

  final int gid;
  final SubscriptionRefreshOutcome outcome;
  final bool applied;
  final bool changed;
  final int added;
  final int updated;
  final int deleted;
  final List<String> addedNames;
  final List<String> updatedNames;
  final List<String> deletedNames;
  final List<int> storedIds;
  final String error;
  final String reportText;
  final String metadata;
  final List<String> skippedFeatures;

  @override
  String toString() => 'SubscriptionRefreshResult($gid, $outcome, '
      'added=$added updated=$updated deleted=$deleted)';
}

/// The outcome of `SubscriptionRefreshService.create`. [gid] is 0 when nothing
/// was written: a fetch/parse/empty/webpage refusal is all-or-nothing, so no
/// group row exists on any non-applied outcome. [added] is the number of nodes
/// stored in the new group, [name] its final (possibly inferred) name and
/// [reportText] the importer/change report shown by the editor.
class SubscriptionCreateResult {
  const SubscriptionCreateResult({
    required this.outcome,
    this.gid = 0,
    this.name = '',
    this.added = 0,
    this.error = '',
    this.reportText = '',
    this.metadata = '',
  });

  final SubscriptionRefreshOutcome outcome;
  final int gid;
  final String name;
  final int added;
  final String error;
  final String reportText;
  final String metadata;

  bool get applied => outcome == SubscriptionRefreshOutcome.applied;

  @override
  String toString() => 'SubscriptionCreateResult($outcome, gid=$gid, '
      'name=$name, added=$added)';
}

/// One reconcile/apply plan shared by the refresh and create paths.
class _PlannedSubscriptionApply {
  const _PlannedSubscriptionApply({
    required this.entries,
    required this.inserts,
    required this.patches,
    required this.reportPlan,
    required this.applyPlan,
  });

  final List<SubscriptionNewEntry> entries;
  final List<NodeRow> inserts;
  final Map<int, Map<String, dynamic>> patches;
  final SubscriptionReconcilePlan reportPlan;
  final SubscriptionApplyPlan applyPlan;
}

/// Raised by [SubscriptionRefreshService.create] for a user-facing refusal.
/// The message never contains the URL, credentials or a raw response body.
class SubscriptionCreateException implements Exception {
  const SubscriptionCreateException(this.message, this.outcome);

  final String message;
  final SubscriptionRefreshOutcome outcome;

  @override
  String toString() => message;
}

/// Runs one subscription refresh against an injected gateway/fetcher/parser.
class SubscriptionRefreshService {
  SubscriptionRefreshService({
    required this.gateway,
    SubscriptionHttpTransport? transport,
    SubscriptionRefreshFetcher? fetcher,
    SubscriptionHostFetcher? hostFetcher,
    SubscriptionBodyParser? parser,
    int Function()? nowSeconds,
    this.onState,
    this.onReport,
    this.onError,
    this.onGroupChanged,
    this.onUnsupportedFeature,
    this.isCurrentIntent,
  })  : _transport = transport,
        _fetcher = fetcher,
        _hostFetcher = hostFetcher,
        _parser = parser,
        _nowSeconds = nowSeconds ??
            (() => DateTime.now().millisecondsSinceEpoch ~/ 1000);

  final SubscriptionDocumentGateway gateway;
  final SubscriptionHttpTransport? _transport;
  final SubscriptionRefreshFetcher? _fetcher;
  final SubscriptionHostFetcher? _hostFetcher;
  final SubscriptionBodyParser? _parser;
  final int Function() _nowSeconds;

  /// Queue-state callback: `SubscriptionRefreshStates.running` on entry,
  /// `idle` on exit. The queue itself remains the owner of `queued`.
  final void Function(int gid, int state)? onState;

  /// `SubscriptionQueue.report`: gid, title, text, popup.
  final void Function(int gid, String title, String text, bool popup)? onReport;

  /// `SubscriptionQueue.error`.
  final void Function(int gid, String message)? onError;

  /// `GroupRepo.postUpdate` / `SubscriptionQueue.groupChanged` hook: ids whose
  /// stored JSON or membership changed, for a later auto-selector slice.
  final void Function(int gid, List<int> disturbed)? onGroupChanged;

  /// Hook for a later slice to implement the Kotlin-only extras instead of
  /// silently dropping them.
  final void Function(int gid, String feature)? onUnsupportedFeature;

  /// Newest-intent guard (`GroupRevisions.holds`), owned by the coordinator.
  /// Called after the download; false discards the answer.
  final Future<bool> Function()? isCurrentIntent;

  /// Fetches, validates, parses, reconciles and applies one subscription group.
  ///
  /// [surface] controls reporting only (log = callbacks only, diff/report =
  /// also a report event); [notifyErrors] mirrors Kotlin's flag.
  Future<SubscriptionRefreshResult> refresh(
    int gid, {
    SubscriptionRefreshSurface surface = SubscriptionRefreshSurface.log,
    bool notifyErrors = true,
  }) async {
    onState?.call(gid, SubscriptionRefreshStates.running);
    try {
      final group = await gateway.groupByGid(gid);
      if (group == null || group.archive || group.url.trim().isEmpty) {
        return SubscriptionRefreshResult(gid: gid, outcome: SubscriptionRefreshOutcome.noop);
      }
      final skipped = _skippedFeatures(group);
      for (final feature in skipped) {
        onUnsupportedFeature?.call(gid, feature);
      }
      final url = group.url.trim();
      late final SubscriptionFetchResult fetched;
      try {
        fetched = await _fetchGroup(group);
      } on Object catch (error) {
        final message = SubscriptionHttpTransport.redact('$error');
        _reportError(gid, group.name, message, surface, notifyErrors, fatal: true);
        return SubscriptionRefreshResult(
          gid: gid,
          outcome: SubscriptionRefreshOutcome.fetchFailed,
          error: message,
          skippedFeatures: skipped,
        );
      }

      // The group may have been deleted/edited while the body downloaded.
      final current = await gateway.groupByGid(gid);
      if (current == null || current.archive || current.url.trim() != url ||
          (isCurrentIntent != null && !await isCurrentIntent!())) {
        return SubscriptionRefreshResult(
          gid: gid,
          outcome: SubscriptionRefreshOutcome.stale,
          skippedFeatures: skipped,
        );
      }

      final parser = _parser ?? _missingParser;
      late final ProfileImportResult parsed;
      try {
        parsed = await parser(fetched.body);
      } on Object catch (error) {
        return _reject(
          gid,
          group,
          SubscriptionRefreshOutcome.parseRefused,
          'Subscription parse failed: ${SubscriptionHttpTransport.redact('$error')}',
          surface,
          notifyErrors,
          skipped,
        );
      }
      if (!parsed.supported) {
        return _reject(
          gid,
          group,
          SubscriptionRefreshOutcome.parseRefused,
          parsed.text.isEmpty ? 'Subscription body is not supported by this build' : parsed.text,
          surface,
          notifyErrors,
          skipped,
        );
      }
      if (parsed.nodes.isEmpty) {
        final reason = looksLikeWebPage(fetched.body)
            ? SubscriptionRefreshOutcome.webPage
            : SubscriptionRefreshOutcome.empty;
        return _reject(
          gid,
          group,
          reason,
          reason == SubscriptionRefreshOutcome.webPage
              ? 'Subscription URL returned a web page, not a subscription'
              : 'Subscription is empty',
          surface,
          notifyErrors,
          skipped,
        );
      }

      // Kotlin applies the group's include/exclude patterns before dedup.
      final named = filterSubscriptionNodeNames(
        parsed.nodes,
        group.subOptionsJson,
        onInvalidPattern: (pattern, error) {
          onUnsupportedFeature?.call(gid, 'invalid name filter "$pattern": $error');
        },
      );
      if (named.isEmpty) {
        return _reject(
          gid,
          group,
          SubscriptionRefreshOutcome.filtered,
          'All ${parsed.nodes.length} nodes were filtered by name rules',
          surface,
          notifyErrors,
          skipped,
        );
      }

      // Kotlin's `distinctNodes`: first occurrence wins, unparseable nodes are
      // kept (the caller supplies an explicit dedupKey for those).
      final arrivals = <ProfileImportNode>[];
      final seen = <String>{};
      for (final node in named) {
        final key = node.dedupKey.isNotEmpty
            ? node.dedupKey
            : '${node.type}|${node.identity}';
        if (!seen.add(key)) continue;
        arrivals.add(node);
      }
      if (arrivals.isEmpty) {
        return _reject(
          gid,
          group,
          SubscriptionRefreshOutcome.filtered,
          'All ${named.length} nodes were rejected or repeated',
          surface,
          notifyErrors,
          skipped,
        );
      }

      final planned = await _planApply(gid, arrivals);
      final metadataJson = subscriptionMetadataJson(fetched.metadata);
      final allocated = await gateway.apply(
        SubscriptionGatewayApply(
          gid: gid,
          insertNodes: planned.inserts,
          nodePatches: planned.patches,
          deleteNodeIds: planned.applyPlan.deleteIds,
          groupPatches: <int, Map<String, dynamic>>{
            gid: <String, dynamic>{
              'sub_last_update': _nowSeconds(),
              'info': '',
              'sub_metadata_json': metadataJson,
            },
          },
          reorderNodeIds: planned.applyPlan.order,
        ),
      );

      final storedIds = _storedIds(planned, allocated);
      final text = _changeText(planned.reportPlan, parsed.text, parsed.nodes.length - arrivals.length);
      onReport?.call(
        gid,
        surface == SubscriptionRefreshSurface.report
            ? 'New subscription: ${group.name}'
            : 'Subscription update: ${group.name}',
        text,
        surface != SubscriptionRefreshSurface.log,
      );
      onGroupChanged?.call(
        gid,
        <int>[...planned.reportPlan.updates, ...planned.applyPlan.deleteIds],
      );
      return SubscriptionRefreshResult(
        gid: gid,
        outcome: SubscriptionRefreshOutcome.applied,
        applied: true,
        changed: planned.reportPlan.added.isNotEmpty ||
            planned.reportPlan.updated.isNotEmpty ||
            planned.reportPlan.deleted.isNotEmpty,
        added: planned.reportPlan.added.length,
        updated: planned.reportPlan.updated.length,
        deleted: planned.reportPlan.deleted.length,
        addedNames: List<String>.from(planned.reportPlan.added),
        updatedNames: List<String>.from(planned.reportPlan.updated),
        deletedNames: List<String>.from(planned.reportPlan.deleted),
        storedIds: storedIds,
        reportText: text,
        metadata: metadataJson,
        skippedFeatures: skipped,
      );
    } finally {
      onState?.call(gid, SubscriptionRefreshStates.idle);
    }
  }

  /// Creates a new subscription group: fetch → validate → parse → create the
  /// group → apply the nodes, in that order.
  ///
  /// The validation half is the SAME code path as [refresh] (transport, parser,
  /// webpage/empty/unsupported refusals and `distinctNodes` dedupe); nothing is
  /// written until a usable body exists, so a bad URL or a blocked page leaves
  /// no half-created group. The group row and its nodes are stored by two
  /// serialized document edits: one [SubscriptionDocumentGateway.createSubscriptionGroup]
  /// to allocate the id, then the same reconcile/apply plan a refresh uses.
  /// Throws [SubscriptionCreateException] with a user-facing message on any
  /// refusal; the message is redacted and never carries a credential or URL.
  Future<SubscriptionCreateResult> create({
    required String name,
    required String url,
    required String subOptionsJson,
    bool autoUpdate = true,
    bool foreground = false,
  }) async {
    final trimmedUrl = url.trim();
    if (trimmedUrl.isEmpty) {
      throw const SubscriptionCreateException(
        'Subscription URL is required', SubscriptionRefreshOutcome.noop,
      );
    }
    final lower = trimmedUrl.toLowerCase();
    final isHttp = lower.startsWith('http://') || lower.startsWith('https://');
    final isContent = lower.startsWith('content://');
    if (!isHttp && !isContent) {
      // Every other scheme is outside both readers. The Kotlin fetch/import
      // path that used to take these was removed (S8), so refuse with the same
      // user-facing sentence the host reader uses.
      final scheme = trimmedUrl.split('://').first.toLowerCase();
      throw SubscriptionCreateException(
        'Unsupported subscription scheme: ${scheme.isEmpty ? '(none)' : scheme}',
        SubscriptionRefreshOutcome.parseRefused,
      );
    }
    if (isContent && _fetcher == null && _hostFetcher == null) {
      // A content:// create has no Dart reader: it needs the host seam.
      throw const SubscriptionCreateException(
        'A content:// subscription needs the host fetch, which is unavailable',
        SubscriptionRefreshOutcome.parseRefused,
      );
    }
    late final SubscriptionFetchResult fetched;
    try {
      fetched = await _fetchCreate(trimmedUrl, subOptionsJson);
    } on Object catch (error) {
      throw SubscriptionCreateException(
        SubscriptionHttpTransport.redact('$error'),
        SubscriptionRefreshOutcome.fetchFailed,
      );
    }

    final parser = _parser ?? _missingParser;
    late final ProfileImportResult parsed;
    try {
      parsed = await parser(fetched.body);
    } on Object catch (error) {
      throw SubscriptionCreateException(
        'Subscription parse failed: ${SubscriptionHttpTransport.redact('$error')}',
        SubscriptionRefreshOutcome.parseRefused,
      );
    }
    if (!parsed.supported) {
      throw SubscriptionCreateException(
        parsed.text.isEmpty ? 'Subscription body is not supported by this build' : parsed.text,
        SubscriptionRefreshOutcome.parseRefused,
      );
    }
    if (parsed.nodes.isEmpty) {
      final webPage = looksLikeWebPage(fetched.body);
      throw SubscriptionCreateException(
        webPage
            ? 'Subscription URL returned a web page, not a subscription'
            : 'Subscription is empty',
        webPage ? SubscriptionRefreshOutcome.webPage : SubscriptionRefreshOutcome.empty,
      );
    }

    final named = filterSubscriptionNodeNames(
      parsed.nodes,
      subOptionsJson,
      onInvalidPattern: (pattern, error) {
        onUnsupportedFeature?.call(0, 'invalid name filter "$pattern": $error');
      },
    );
    if (named.isEmpty) {
      throw SubscriptionCreateException(
        'All ${parsed.nodes.length} nodes were filtered by name rules',
        SubscriptionRefreshOutcome.filtered,
      );
    }

    final arrivals = <ProfileImportNode>[];
    final seen = <String>{};
    for (final node in named) {
      final key = node.dedupKey.isNotEmpty ? node.dedupKey : '${node.type}|${node.identity}';
      if (!seen.add(key)) continue;
      arrivals.add(node);
    }
    if (arrivals.isEmpty) {
      throw SubscriptionCreateException(
        'All ${named.length} nodes were rejected or repeated',
        SubscriptionRefreshOutcome.filtered,
      );
    }

    final resolvedName = _createName(name, fetched);
    final gid = await gateway.createSubscriptionGroup(
      name: resolvedName,
      url: trimmedUrl,
      subOptionsJson: subOptionsJson,
      autoUpdate: autoUpdate,
    );
    final planned = await _planApply(gid, arrivals);
    final metadataJson = subscriptionMetadataJson(fetched.metadata);
    try {
      await gateway.apply(
        SubscriptionGatewayApply(
          gid: gid,
          insertNodes: planned.inserts,
          nodePatches: planned.patches,
          deleteNodeIds: planned.applyPlan.deleteIds,
          groupPatches: <int, Map<String, dynamic>>{
            gid: <String, dynamic>{
              'sub_last_update': _nowSeconds(),
              'info': '',
              'sub_metadata_json': metadataJson,
            },
          },
          reorderNodeIds: planned.applyPlan.order,
        ),
      );
    } catch (_) {
      // The group row was created before the rows could reference its id; if
      // the one node-apply edit fails, remove that empty group so create is
      // all-or-nothing from the caller's point of view.
      try {
        await gateway.deleteSubscriptionGroup(gid);
      } catch (_) {
        // Keep the original apply error; a rollback failure is still better
        // than masking the reason the create failed.
      }
      rethrow;
    }
    final text = _changeText(planned.reportPlan, parsed.text, parsed.nodes.length - arrivals.length);
    onReport?.call(gid, 'New subscription: $resolvedName', text, foreground);
    return SubscriptionCreateResult(
      outcome: SubscriptionRefreshOutcome.applied,
      gid: gid,
      name: resolvedName,
      added: planned.reportPlan.added.length,
      reportText: text,
      metadata: metadataJson,
    );
  }

  /// The editor's name, then the server's Profile-Title, the response filename
  /// and the URL host — the same fallback ladder Kotlin uses on create.
  String _createName(String supplied, SubscriptionFetchResult fetched) {
    final text = supplied.trim();
    if (text.isNotEmpty) return text;
    final title = fetched.metadata.title.trim();
    if (title.isNotEmpty) return title;
    final fileName = fetched.fileName.trim();
    if (fileName.isNotEmpty) return fileName;
    final host = Uri.tryParse(fetched.finalUrl)?.host.trim() ?? '';
    final cleaned = host.replaceFirst(RegExp(r'^www\.'), '').trim();
    return cleaned.isEmpty ? 'Subscription' : cleaned;
  }

  Map<String, String> _headersFromOptionsJson(String subOptionsJson) {
    final options = _decodeObject(subOptionsJson);
    final userAgent = options?['user_agent'];
    if (userAgent is String && userAgent.trim().isNotEmpty) {
      return <String, String>{'user-agent': userAgent.trim()};
    }
    return const <String, String>{};
  }

  /// Builds one apply plan from the CURRENT group rows. Shared verbatim by the
  /// refresh and create paths so digest/claim pairing and dedup never diverge.
  Future<_PlannedSubscriptionApply> _planApply(
    int gid,
    List<ProfileImportNode> arrivals,
  ) async {
    final rows = await gateway.membersOfGroup(gid);
    final old = <SubscriptionOldEntry>[];
    for (final row in rows) {
      final identityJson = await gateway.identityJsonOf(row);
      // An unknown identity must not collapse every row of one type into the
      // same `type|` key: that would let an unrelated arrival supersede the
      // first leftover. Give each unknown row a key no arrival can produce;
      // content-based reuse still works.
      final identity = identityJson.isEmpty
          ? '\u0000unknown:${row.id}'
          : subscriptionIdentityKey(row.type, identityJson);
      old.add(
        SubscriptionOldEntry(
          row.id,
          subscriptionContentKey(row.outboundJson),
          identity,
          row.display,
        ),
      );
    }

    final index = SubscriptionContentIndex(old);
    final entries = <SubscriptionNewEntry>[];
    for (final node in arrivals) {
      entries.add(
        prepareSubscriptionArrival(
          index,
          display: node.display,
          storedJson: node.json,
          type: node.type,
          identityJson: node.identity,
        ),
      );
    }
    pairSubscriptionByIdentity(old, entries, index);

    // Storage ids are allocated in the single gateway edit. Give the new rows
    // sentinel ids now so the pure reconcile pass can build a complete order;
    // the gateway substitutes them with the real ids before persisting.
    // Superseded entries keep their old row id (the same assignment
    // `planSubscriptionRefresh` performs), so storedIds and report counts
    // see the updated row rather than an unstored -1 entry.
    var nextPlaceholder = subscriptionPlaceholderIdBase;
    for (var i = 0; i < entries.length; i++) {
      final entry = entries[i];
      if (entry.supersedes > 0) {
        entry.id = entry.supersedes;
      } else if (!entry.reused) {
        entry.id = nextPlaceholder++;
      }
    }
    final reportPlan = reconcileSubscription(old, entries, index);
    final applyPlan = SubscriptionApplyPlan.from(reportPlan, entries);

    final inserts = <NodeRow>[];
    for (final i in applyPlan.insertArrivals) {
      final node = arrivals[i];
      inserts.add(
        NodeRow(
          id: entries[i].id,
          type: node.type,
          name: node.name,
          gid: gid,
          userOrder: i,
          outboundJson: node.json,
        ),
      );
    }
    final patches = <int, Map<String, dynamic>>{};
    for (final patch in applyPlan.patches) {
      final node = arrivals[patch.arrivalIndex];
      patches[patch.oldId] = <String, dynamic>{
        'type': node.type,
        'name': node.name,
        'outbound_json': node.json,
      };
    }
    return _PlannedSubscriptionApply(
      entries: entries,
      inserts: inserts,
      patches: patches,
      reportPlan: reportPlan,
      applyPlan: applyPlan,
    );
  }

  List<int> _storedIds(
    _PlannedSubscriptionApply planned,
    SubscriptionGatewayApplyResult allocated,
  ) {
    final storedIds = <int>[];
    for (final entry in planned.entries) {
      final id = allocated.insertedIds[entry.id] ?? entry.id;
      if (id >= 0) storedIds.add(id);
    }
    return storedIds;
  }

  /// The refresh's one fetch. An injected [SubscriptionRefreshFetcher] wins
  /// (unit tests); otherwise `content://` and front/landing-proxy groups go to
  /// the host seam when it was injected, and every other URL stays Dart.
  Future<SubscriptionFetchResult> _fetchGroup(ConfigurationRow group) {
    final url = group.url.trim();
    final fetcher = _fetcher;
    if (fetcher != null) return fetcher(url, headers: _requestHeaders(group));
    final hostFetcher = _hostFetcher;
    if (hostFetcher != null && _hostFetchNeeded(group)) {
      return hostFetcher(url, subOptionsJson: group.subOptionsJson, gid: group.id);
    }
    return _defaultFetcher(url, headers: _requestHeaders(group));
  }

  /// The create's one fetch: the group does not exist yet, so a content:// URL
  /// (or a test-injected fetcher) is the only reason to leave Dart.
  Future<SubscriptionFetchResult> _fetchCreate(
    String url,
    String subOptionsJson,
  ) {
    final fetcher = _fetcher;
    if (fetcher != null) {
      return fetcher(url, headers: _headersFromOptionsJson(subOptionsJson));
    }
    final hostFetcher = _hostFetcher;
    if (hostFetcher != null && subscriptionUrlNeedsHost(url)) {
      return hostFetcher(url, subOptionsJson: subOptionsJson, gid: 0);
    }
    return _defaultFetcher(url, headers: _headersFromOptionsJson(subOptionsJson));
  }

  /// A group whose one-shot body needs the host reader: `content://` (no
  /// ContentResolver in Dart) or the group's front/landing proxy settings
  /// (Kotlin's OkHttp/proxy path and RequestIdentity).
  bool _hostFetchNeeded(ConfigurationRow group) =>
      subscriptionUrlNeedsHost(group.url) ||
      group.frontProxyId > 0 ||
      group.landingProxyId > 0;

  Future<SubscriptionFetchResult> _defaultFetcher(
    String url, {
    Map<String, String> headers = const <String, String>{},
  }) {
    final transport = _transport ?? SubscriptionHttpTransport();
    return transport.fetch(url, headers: headers);
  }

  Future<ProfileImportResult> _missingParser(String body) async {
    throw StateError('No profileImport parser was injected');
  }

  /// Kotlin `RequestIdentity.headers` without the device half: the user agent
  /// is a stored group option, while dynamic HWID/TLS/HTTP2 stay host duties
  /// (and are listed in [skippedFeatures]).
  Map<String, String> _requestHeaders(ConfigurationRow group) {
    final headers = <String, String>{};
    final options = _decodeObject(group.subOptionsJson);
    final userAgent = options?['user_agent'];
    if (userAgent is String && userAgent.trim().isNotEmpty) {
      headers['user-agent'] = userAgent.trim();
    }
    return headers;
  }

  List<String> _skippedFeatures(ConfigurationRow group) {
    final skipped = <String>[];
    final options = _decodeObject(group.subOptionsJson) ?? <String, dynamic>{};
    // The host seam runs Kotlin's RequestIdentity, so a group it serves also
    // honours its HWID/TLS/HTTP overrides; a direct-Dart group does not.
    final hostCoversFetch = _hostFetcher != null && _hostFetchNeeded(group);
    if (options['url_test'] == true) {
      skipped.add(SubscriptionUnsupportedFeature.urlTestFollowUp.name);
    }
    if (!hostCoversFetch &&
        (options['hwid'] != null ||
            options['hwid_os'] != null ||
            options['hwid_os_version'] != null ||
            options['hwid_model'] != null)) {
      skipped.add(SubscriptionUnsupportedFeature.dynamicHwid.name);
    }
    if (!hostCoversFetch &&
        (options['tls_version'] != null || options['http_version'] != null)) {
      skipped.add(SubscriptionUnsupportedFeature.http2TlsPinning.name);
    }
    // With the host seam wired (production), content:// and front/landing
    // proxy groups are served, so they are no longer "skipped"; a bare unit
    // test without the seam still reports them as Kotlin-only.
    if (!hostCoversFetch) {
      if (group.frontProxyId > 0 || group.landingProxyId > 0) {
        skipped.add(SubscriptionUnsupportedFeature.frontLandingProxy.name);
      }
      if (group.url.toLowerCase().startsWith('content://')) {
        skipped.add(SubscriptionUnsupportedFeature.contentUrlInput.name);
      }
    }
    return skipped;
  }

  SubscriptionRefreshResult _reject(
    int gid,
    ConfigurationRow group,
    SubscriptionRefreshOutcome outcome,
    String message,
    SubscriptionRefreshSurface surface,
    bool notifyErrors,
    List<String> skipped,
  ) {
    if (notifyErrors || surface != SubscriptionRefreshSurface.log) {
      onError?.call(gid, message);
    }
    if (surface != SubscriptionRefreshSurface.log) {
      onReport?.call(
        gid,
        'Subscription update: ${group.name}',
        message,
        surface == SubscriptionRefreshSurface.report,
      );
    }
    return SubscriptionRefreshResult(
      gid: gid,
      outcome: outcome,
      error: message,
      skippedFeatures: skipped,
    );
  }

  void _reportError(
    int gid,
    String groupName,
    String message,
    SubscriptionRefreshSurface surface,
    bool notifyErrors, {
    required bool fatal,
  }) {
    if (notifyErrors || surface != SubscriptionRefreshSurface.log) {
      onError?.call(gid, message);
    }
    if (fatal && surface == SubscriptionRefreshSurface.report) {
      onReport?.call(gid, 'New subscription: $groupName', message, true);
    }
  }

  /// The Kotlin `notice` lines + importer problems, without Android string ids.
  String _changeText(
    SubscriptionReconcilePlan plan,
    String parseText,
    int filteredOut,
  ) {
    final lines = <String>[];
    if (plan.added.isNotEmpty) {
      lines.add('[+] ${notice(plan.added, '[+]', 'added')}');
    }
    if (plan.updated.isNotEmpty) {
      lines.add('[~] ${notice(plan.updated, '[~]', 'updated')}');
    }
    if (plan.deleted.isNotEmpty) {
      lines.add('[-] ${notice(plan.deleted, '[-]', 'deleted')}');
    }
    if (lines.isEmpty) lines.add('Nothing changed');
    if (filteredOut > 0) lines.add('$filteredOut repeated nodes dropped');
    if (parseText.isNotEmpty) lines.add(parseText);
    return lines.join('\n');
  }
}

/// Kotlin `notice`: a list of 1000+ names collapses to one count line.
String notice(List<String> names, String prefix, String action) {
  if (names.length >= 1000) return '$prefix $action ${names.length}\n';
  return names.map((name) => '$prefix $name\n').join();
}

/// Kotlin `looksLikeWebPage`: skip whitespace and BOM, then test the two HTML
/// openers case-insensitively.
bool looksLikeWebPage(String body) {
  var start = 0;
  while (start < body.length &&
      (body[start].trim().isEmpty || body[start] == '\uFEFF')) {
    start++;
  }
  final rest = body.substring(start);
  final lower = rest.toLowerCase();
  return lower.startsWith('<!doctype html') || lower.startsWith('<html');
}

/// Kotlin `SubscriptionNameFilter.apply`: include/exclude regexes from the
/// subscription options, matched case-insensitively against the node display
/// name (the tag, or `server:port` when unnamed). An invalid pattern is
/// ignored, exactly like the Kotlin editor's "filter ignored" path.
List<ProfileImportNode> filterSubscriptionNodeNames(
  List<ProfileImportNode> nodes,
  String subOptionsJson, {
  void Function(String pattern, String error)? onInvalidPattern,
}) {
  final options = _decodeObject(subOptionsJson);
  final includeText = options?['name_include'];
  final excludeText = options?['name_exclude'];
  final include = includeText is String ? _compileNamePattern(includeText, onInvalidPattern) : null;
  final exclude = excludeText is String ? _compileNamePattern(excludeText, onInvalidPattern) : null;
  if (include == null && exclude == null) return nodes;
  return <ProfileImportNode>[
    for (final node in nodes)
      if ((include == null || include.hasMatch(_subscriptionDisplayName(node))) &&
          (exclude == null || !exclude.hasMatch(_subscriptionDisplayName(node))))
        node,
  ];
}

RegExp? _compileNamePattern(
  String pattern,
  void Function(String pattern, String error)? onInvalid,
) {
  if (pattern.isEmpty) return null;
  try {
    return RegExp(pattern, caseSensitive: false, unicode: true);
  } on FormatException catch (error) {
    onInvalid?.call(pattern, error.message);
    return null;
  }
}

String _subscriptionDisplayName(ProfileImportNode node) {
  final name = node.name.trim();
  if (name.isNotEmpty) return name;
  final object = _decodeObject(node.json);
  final server = object?['server'];
  final port = object?['server_port'];
  if (server is! String || server.isEmpty || port is! num) return '';
  final host = server.contains(':') ? '[$server]' : server;
  return '$host:${port.toInt()}';
}

/// Kotlin `SubUserInfo.toJsonString()` for `sub_metadata_json`: nothing at all
/// is written when !valid; otherwise keys are sorted and defaults omitted.
/// Dart's `jsonEncode` emits sorted keys in insertion order and uses the same
/// compact escaping as Kotlin's `JsonWriter` for these values.
String subscriptionMetadataJson(SubscriptionMetadata metadata) {
  if (!metadata.valid) return '{}';
  final raw = <String, dynamic>{
    'valid': true,
    'has_quota': metadata.hasQuota,
    if (metadata.upload > 0) 'upload': metadata.upload,
    if (metadata.download > 0) 'download': metadata.download,
    if (metadata.total > 0) 'total': metadata.total,
    if (metadata.expire > 0) 'expire': metadata.expire,
    if (metadata.title.isNotEmpty) 'title': metadata.title,
    if (metadata.webUrl.isNotEmpty) 'web_url': metadata.webUrl,
    if (metadata.supportUrl.isNotEmpty) 'support_url': metadata.supportUrl,
    if (metadata.announce.isNotEmpty) 'announce': metadata.announce,
    if (metadata.serverInterval > 0) 'server_interval': metadata.serverInterval,
  };
  final keys = raw.keys.toList()..sort();
  return jsonEncode(<String, dynamic>{for (final key in keys) key: raw[key]});
}

Map<String, dynamic>? _decodeObject(String text) {
  if (text.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Display name of a stored member, mirroring Kotlin `displayTypeAndName`.
extension on NodeRow {
  String get display => '[$type] ${name ?? ''}';
}
