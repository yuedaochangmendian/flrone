part of 'box.dart';

/// Semantic facade (Bettbox `ClashCore`-style): folds the scattered raw bridge
/// invocations — a bare name string plus an argument map — into typed, discoverable methods,
/// so the name is checked at compile time and the parameter shape lives in one place.
/// Grouped by domain as `extension`s on [BoxController].
///
/// The kernel operations (service lifecycle, mode, selection, WARP) take the FFI
/// path first — Dart drives the core directly when the rebuilt core is present —
/// and fall back to the method channel otherwise.

Future<bool> _kernelOp(BoxController box, Future<void> Function() body) async {
  try {
    await body();
    return true;
  } catch (error) {
    box.report(error);
    return false;
  }
}

/// The integer id a wire value stands for (the channel sends numbers, a test
/// may pass a string).
int _idOf(dynamic id) =>
    id is num ? id.toInt() : int.tryParse('${id ?? ''}') ?? 0;

/// Like [_kernelOp], but a request the kernel never answered is rethrown.
///
/// The start/stop toggle needs the distinction: an unanswered start keeps its
/// optimistic state (the heartbeat recovery converges it), while an explicit
/// refusal rolls back and reports. [_kernelOp] flattens both to false.
Future<bool> _serviceOp(BoxController box, Future<void> Function() body) async {
  try {
    await body();
    return true;
  } catch (error) {
    if (kernelUnanswered(error)) rethrow;
    box.report(error);
    return false;
  }
}

/// One subscription refresh's enqueue result.
///
/// A refusal is answered here (rather than announced as a snackbar) so a caller
/// that runs N refreshes can list the failures in one place. The download's own
/// errors are not part of this: they arrive later as `subscriptionReport`
/// events, which a collecting run holds too.
class ConfigurationUpdateResult {
  const ConfigurationUpdateResult({this.error});
  final String? error;
  bool get ok => error == null;
}

extension ConfigurationsApi on BoxController {
  // ADR 0005 final stage: profiles/groups are Dart-owned data, written through
  // `profiles.applyDocument` into `ConfigurationStore`. Eight document-only ops
  // (`stats`, `reorder`, `clearTestResults`, `nodeList`, `nodeReorder`, and the
  // configuration editor's `config`/`read`/`write`) are Dart-owned too now —
  // see [ProfileDocumentService]; they no longer cross this boundary. S7 moved
  // the auto-selector editor's document ops (`info`/`save`/`pin`/`create`) to
  // the same service as well. What still crosses needs the Throne outbound model
  // (parsing/validation), the subscription queue, a Kotlin-owned selection
  // setting, the auto-selector runtime (status/recheck/the pin notice), or one
  // of the narrow side effects (`sort.reposition`, `revision.edit`,
  // `subscription.schedule`): ONE `profiles.platform` call with
  // `{op, payload}`. `FlroneProfileDuty.kt` lists the ops;
  // tools/diagnostics/platform_duty_audit.py holds the two sides together, so
  // an op cannot drift or go dead.
  Future<dynamic> configurationPlatform(String op, [Json payload = const {}]) =>
      call('profiles.platform', {'op': op, 'payload': payload});

  /// One duty op folded into [act]'s bool semantics: a failure is reported and
  /// answered false, never mistaken for success.
  Future<bool> _configurationDutyAct(String op, [Json payload = const {}]) async {
    try {
      await configurationPlatform(op, payload);
      // A successful profile/group write invalidates the picker's cached node
      // rows even when the host has not pushed a `state` aspect yet. Read-only
      // duties also land here; an extra cache miss is harmless.
      invalidateGroupNodesCache();
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  /// The same bool semantics for the Dart-owned document ops: a write failure
  /// is reported, never mistaken for success.
  Future<bool> _profileDocumentWrite(Future<void> Function() write) async {
    try {
      await write();
      invalidateGroupNodesCache();
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<dynamic> configurationDecodeIntent(String uri) =>
      configurationPlatform('decodeIntent', {'uri': uri});

  /// The auto-selector editor's document half is Dart-owned now (S7): the row's
  /// `outbound_json` lives in the same `profiles.json` the store owns, so the
  /// seed reads locally and the writes relay to the service engine's document
  /// owner (`relayDocument`) instead of crossing `profiles.platform`. What
  /// stays on the platform boundary is only the runtime shadow: the live status
  /// read, a recheck request and the pin notice the running core would apply.
  Future<Json> autoSelectorInfo(dynamic id) async =>
      json(await profileDocuments.autoSelectorInfo(_idOf(id)));

  Future<dynamic> autoSelectorStatus() =>
      configurationPlatform('autoSelectorStatus');

  /// Stores the pin in the Dart document, then lets the host report it to the
  /// runtime shadow (the live core belongs to the service engine).
  Future<dynamic> autoSelectorPin(dynamic id, dynamic memberId) async {
    final member = _idOf(memberId);
    final reply = await relayDocument('autoSelectorPin', <String, dynamic>{
      'id': _idOf(id),
      'memberId': member,
    });
    await configurationPlatform('autoSelectorRuntimePin', {'memberId': member});
    return reply;
  }

  Future<dynamic> autoSelectorRecheck() =>
      configurationPlatform('autoSelectorRecheck');

  Future<dynamic> autoSelectorSave(dynamic id, Json value) =>
      relayDocument('autoSelectorSave', <String, dynamic>{
        'id': _idOf(id),
        'value': value,
      });

  Future<dynamic> autoSelectorCreate(dynamic groupId, {String? name}) =>
      relayDocument('autoSelectorCreate', <String, dynamic>{
        'groupId': groupId,
        'name': ?name,
      });

  /// A subscription refresh is *enqueued*, not awaited: the Kotlin `update` op
  /// hands the download to the service engine's Dart queue and returns at once,
  /// and the real outcome arrives later as `subscriptionReport` events (log
  /// surface + notification). The old retryCall wrapper pretended to bound a
  /// download it never touched — two attempts against the enqueue, a 60 s timeout
  /// against a call that returns in milliseconds. Failures are reported by the
  /// event stream; retry here means "tap refresh again". The host answers an
  /// error for a URL its/Dart's readers cannot fetch (an unsupported scheme).
  Future<bool> configurationUpdate(dynamic id) async {
    final outcome = await configurationUpdateOutcome(id);
    final error = outcome.error;
    if (error != null) report(error);
    return outcome.ok;
  }

  /// The enqueue half of [configurationUpdate] without the snackbar: the host's
  /// refusal is answered to the caller, which is what lets "Update all" collect
  /// per-profile outcomes into one result instead of N transient messages.
  Future<ConfigurationUpdateResult> configurationUpdateOutcome(dynamic id) async {
    try {
      await configurationPlatform('update', {'id': id});
      return const ConfigurationUpdateResult();
    } catch (error) {
      return ConfigurationUpdateResult(error: BoxController.describe(error));
    }
  }

  /// Profile/group writes invalidate the cached node catalog even before the
  /// host pushes its state aspect. Reads (nodeConfig/nodeTuningInfo,
  /// configurationConfig) deliberately do not.
  Future<dynamic> _nodeWrite(String op, Json payload) async {
    final result = await configurationPlatform(op, payload);
    invalidateGroupNodesCache();
    return result;
  }

  /// The share link of one node. The Go `profileExport` slice owns every
  /// link-bearing stored type; the reply's `link`/`jsonLink` fields are used
  /// generically (`link` only when it looks like a URI, so Direct's
  /// query-only form keeps the loss-less JSON link). custom/chain/autoselector
  /// answer the stored document's `throne://add/` JSON link.
  Future<dynamic> nodeLink(String group, String tag, dynamic nodeJson) async {
    final target = await profileDocuments.selectionTargetForMember(
      groupTag: group,
      nodeTag: tag,
    );
    if (target != null) {
      final row = await profileDocuments.nodeRow(target.profileId);
      final attached = kernel.attached;
      if (row != null && attached != null) {
        try {
          final reply = json(
            await attached.invoke<Object?>(
              ActionMethod.profileExport,
              data: <String, dynamic>{
                'json': row.outboundJson,
                if (row.name != null) 'name': row.name,
              },
            ),
          );
          if (reply['supported'] == true) {
            final link = nodeJson == true
                ? reply['jsonLink']
                : (reply['link']?.toString().contains('://') == true
                    ? reply['link']
                    : reply['jsonLink']);
            if (link is String && link.isNotEmpty) return link;
          }
        } catch (_) {
          // The action is an optimization while the full codec lands: an
          // unanswered/refused call keeps the Kotlin exporter's answer.
        }
      }
    }
    return _nodeWrite('nodeLink', {
      'group': group,
      'tag': tag,
      'json': nodeJson,
    });
  }
  Future<dynamic> nodeDelete(dynamic id) =>
      _nodeWrite('nodeDelete', {'id': id});
  Future<dynamic> nodeConfig(dynamic id) =>
      configurationPlatform('nodeConfig', {'id': id});
  Future<dynamic> nodeUpdate(dynamic id, String name, String content) =>
      _nodeWrite('nodeUpdate', {'id': id, 'name': name, 'content': content});
  Future<dynamic> nodeTuningInfo(dynamic id) =>
      configurationPlatform('nodeTuningInfo', {'id': id});
  Future<dynamic> nodeTuningSave(dynamic id, Json value) =>
      _nodeWrite('nodeTuningSave', {'id': id, 'value': value});
  /// The configuration editor's manifest: the group row as its JSON document,
  /// the optimistic-lock revision, the pretty text the details page parses and
  /// the card's stats. Dart-owned now ([ProfileDocumentService.config]) — no
  /// host round trip, so no cache invalidation either.
  Future<Json> configurationConfig(dynamic id) async =>
      json(await profileDocuments.config(_idOf(id)));

  /// The same manifest as plain text for export/share (no stats, no second
  /// pretty-print pass).
  Future<String> configurationRead(dynamic id) =>
      profileDocuments.read(_idOf(id));

  /// Applies an edited manifest. S6: the WHOLE op runs inside the owner's
  /// write path — the revision guard, key whitelist and node-membership checks,
  /// the `revision.edit` intent bump before the edit, the poller re-plan on a
  /// URL edit, and the catalog push. The UI never splits this into a local
  /// read-then-row-upsert; one relay op carries the exact document op.
  Future<Json> configurationWrite(dynamic id, String content, dynamic revision) async {
    final reply = await relayDocument('configurationWrite', <String, dynamic>{
      'id': _idOf(id),
      'content': content,
      if (revision is String) 'revision': revision,
    });
    invalidateGroupNodesCache();
    return json(reply);
  }

  /// Clears the group's stored test results in the owner's document; the narrow
  /// Kotlin `sort.reposition` duty runs inside the owner's write path too.
  Future<bool> configurationClearTestResults(dynamic id) async =>
      _profileDocumentWrite(() => relayDocument(
        'configurationClearTestResults',
        <String, dynamic>{'id': _idOf(id)},
      ));
  Future<bool> configurationDelete(dynamic id) =>
      _configurationDutyAct('delete', {'id': id});

  /// The settings mirror for a Dart-resolved selection (ADR 0008 S4): the host
  /// writes `selectedProxy`/`currentProfile`/`current_group` and refreshes the
  /// rows, but never broadcasts or reloads. Returns false when the row vanished
  /// between resolution and the write.
  Future<bool> _mirrorSelection(ProfileSelectionTarget target) async {
    try {
      final reply = await configurationPlatform('selection.mirror', {
        'profileId': target.profileId,
        'groupId': target.groupId,
      });
      return reply != false;
    } catch (error) {
      report(error);
      return false;
    }
  }

  /// The selection is Dart-owned now: resolve the member/group from the
  /// profiles document, mirror the choice into settings, project it into
  /// `profile_selection.json`, then let the running core rebuild from it.
  Future<bool> configurationSwitchRelative(int step) async {
    final current = await currentSelectionMemberId();
    final target = await profileDocuments.selectionNeighbour(current, step);
    if (target == null) return false;
    return _applySelectionTarget(target);
  }

  Future<bool> configurationSelect(dynamic id) async {
    final target = await profileDocuments.selectionTargetForGroup(
      _idOf(id),
      preferredProfileId: selectedMemberId,
    );
    if (target == null) return false;
    return _applySelectionTarget(target);
  }

  /// Selects a member row by its profile id. The speed panel's ranking passes
  /// member ids; a profile card passes group ids (`configurationSelect`), so the
  /// two id spaces need explicit entry points.
  Future<bool> configurationSelectProfile(dynamic id) async {
    final target = await profileDocuments.selectionTargetForProfile(_idOf(id));
    if (target == null) return false;
    return _applySelectionTarget(target);
  }

  /// The shared tail of every Dart-owned selection: mirror the settled ids into
  /// settings, project them into `profile_selection.json`, then let the running
  /// core rebuild. Ordering is deliberate: settings first, so a crash between
  /// the two still leaves the newer choice for `config.prepare` to resolve;
  /// the document is the build's only selection source and is repaired inside
  /// `_buildConfig` even if this write is missed.
  Future<bool> _applySelectionTarget(ProfileSelectionTarget target) async {
    if (!await _mirrorSelection(target)) return false;
    await recordSelection(
      profileId: target.profileId,
      groupId: target.groupId,
    );
    if (kernel.ffiMode) {
      await kernel.onSelectionChanged();
    } else if (running) {
      await serviceReload();
    }
    return true;
  }

  /// SAF picker: platform UI, not profile data.
  Future<dynamic> configurationImportFile() => call('files.pickProfile');
  Future<dynamic> createNode(dynamic type) =>
      _nodeWrite('createNode', {'type': type});
  Future<dynamic> nodeCreate(Json value) =>
      _nodeWrite('nodeCreate', value);

  /// The node page's list: the single-node container's rows in list order.
  /// S6: `nodeList` PRUNES empty containers, so it is a write and runs in the
  /// owner; the reply keeps the old `{groupId, groupName, nodes}` shape. The
  /// editor reads the full document locally through [configurationConfig].
  Future<Json> nodeList() async => json(await relayDocument('configurationNodeList'));

  /// Reorders the node page's list to [ids] (the container group's member order
  /// in the profiles document). S6: the serialized document edit runs in the
  /// owner; the next [nodeList] answers the saved sequence.
  Future<bool> nodeReorder(int groupId, List<dynamic> ids) =>
      _profileDocumentWrite(
        () => relayDocument('nodeReorder', <String, dynamic>{
          'groupId': groupId,
          'ids': [for (final id in ids) _idOf(id)],
        }),
      );

  /// Single-node import: one share link, a list of them or a base64
  /// subscription → `{nodes: [{name, type, json}], skipped, messages}`.
  Future<Json> nodeParse(String text) async =>
      json(await configurationPlatform('nodeParse', {'text': text}));
  Future<dynamic> configurationSave(Json value) async {
    final result = await configurationPlatform('save', value);
    invalidateGroupNodesCache();
    return result;
  }
  Future<bool> configurationReorder(List<dynamic> ids) => _profileDocumentWrite(
        () => relayDocument('configurationReorder', <String, dynamic>{
          'ids': [for (final id in ids) _idOf(id)],
        }),
      );
}

/// The global rule table as one consistent snapshot: the rules plus the
/// revision and content digest Go stamped on them. A patch is only valid while
/// [version] still matches the store's revision.
class RouteRulesSnapshot {
  const RouteRulesSnapshot(this.rules, this.version, this.etag);

  final List<Json> rules;
  final int version;
  final String etag;

  factory RouteRulesSnapshot.fromWire(Object? wire) {
    final answer = json(wire);
    return RouteRulesSnapshot(
      [for (final entry in rows(answer['rules'])) entry],
      (answer['version'] as num?)?.toInt() ?? 0,
      answer['etag']?.toString() ?? '',
    );
  }
}

/// One incremental edit to the global rule table. [added] rows get a fresh id
/// from Go; [updated] and [deleted] name rows by the id they were loaded with;
/// [order] is the complete display order by id (empty means keep the existing
/// order and append the additions).
class RouteRulesPatch {
  const RouteRulesPatch({
    required this.baseVersion,
    this.added = const [],
    this.updated = const [],
    this.deleted = const [],
    this.order = const [],
  });

  final int baseVersion;
  final List<Json> added;
  final List<Json> updated;
  final List<int> deleted;
  final List<int> order;

  Json toWire() => <String, dynamic>{
        'baseVersion': baseVersion,
        'added': added,
        'updated': updated,
        'deleted': deleted,
        'order': order,
      };
}

/// The result of an accepted patch: the new revision and digest, plus counts.
class RouteRulesPatchResult {
  const RouteRulesPatchResult(
    this.version,
    this.etag, {
    this.added = 0,
    this.updated = 0,
    this.deleted = 0,
    this.ids = const [],
  });

  final int version;
  final String etag;
  final int added;
  final int updated;
  final int deleted;

  /// The ids Go assigned to the patch's `added` rows, in order. The editor
  /// attaches these to its draft so the next patch has a correct base.
  final List<int> ids;

  factory RouteRulesPatchResult.fromWire(Object? wire) {
    final answer = json(wire);
    return RouteRulesPatchResult(
      (answer['version'] as num?)?.toInt() ?? 0,
      answer['etag']?.toString() ?? '',
      added: (answer['added'] as num?)?.toInt() ?? 0,
      updated: (answer['updated'] as num?)?.toInt() ?? 0,
      deleted: (answer['deleted'] as num?)?.toInt() ?? 0,
      ids: [
        for (final id in answer['ids'] is List ? answer['ids'] as List : const <Object?>[])
          (id as num).toInt(),
      ],
    );
  }
}

/// A refused patch because the store moved since the snapshot was taken. The
/// kernel is the sole writer, so the conservative response is to reload and
/// reapply the user's edit — never a silent merge or an id renumber.
class RouteRulesStale implements Exception {
  const RouteRulesStale(this.currentVersion, this.etag, this.message);

  final int currentVersion;
  final String etag;
  final String message;

  /// Recognises the typed stale payload from a [KernelProxyException.details]
  /// map, whether it crossed the in-process bus or the isolate IPC link.
  static RouteRulesStale? fromError(Object? error) {
    if (error is RouteRulesStale) return error;
    if (error is! KernelProxyException) return null;
    final details = error.details;
    if (details is! Map || details['kind'] != 'stale') return null;
    return RouteRulesStale(
      (details['version'] as num?)?.toInt() ?? 0,
      details['etag']?.toString() ?? '',
      error.message,
    );
  }

  @override
  String toString() => 'RouteRulesStale(version=$currentVersion, etag=$etag): $message';
}

extension RoutesApi on BoxController {
  // Routing is a single global rule table (`global_route_rules.json`): Go owns
  // it and is its only writer, so every call goes through the JSON action bus.
  // The per-profile CRUD, rule sets, current marker and host selection channel
  // are gone with the multi-profile UI (UI and Go delete them in the same
  // round). Only the rule-set catalog search stays local: it reads installed
  // files, not route data.
  //
  // The bus is attached on demand and attaching is not starting: the prewarmed
  // service engine opens the FFI driver without a box (`KernelService.initialize`),
  // and a connect only resolves that engine's port and says hello (see
  // [attachKernel]). Waiting for a `running` dashboard event before connecting
  // made opening Routing before a start read as "start the VPN first", which a
  // route read or write never needed.
  Future<ActionInvoker> _routeKernel() async {
    final attached = kernel.attached;
    if (attached != null) return attached;
    try {
      await attachKernel(timeout: BoxController.kernelAttachTimeout);
    } catch (_) {
      // The engine is still booting (or gone); the typed answer below is the
      // one the routing screen shows, not the transport's internal wording.
    }
    return kernel.attached ??
        (throw const KernelProxyException(
          'The core is still starting. Try routing again in a moment.',
          unanswered: true,
        ));
  }

  /// The whole ordered rule list, read over the JSON action bus.
  ///
  /// Go owns the one global table; there is deliberately no channel fallback —
  /// without the FFI driver there is no authoritative answer, and a stale
  /// snapshot must not be shown.
  Future<dynamic> routeGlobalRules() async =>
      (await _routeKernel()).invoke<Object?>(ActionMethod.getGlobalRules);

  /// Reads the table with its revision + etag envelope, for incremental edits.
  Future<RouteRulesSnapshot> routeGlobalRulesSnapshot() async =>
      RouteRulesSnapshot.fromWire(await routeGlobalRules());

  /// Applies one incremental edit under a revision guard. A stale base is a
  /// typed [RouteRulesStale] refusal: the caller reloads and reapplies, rather
  /// than merging into a table it has not seen.
  Future<RouteRulesPatchResult> routeSaveGlobalRulesPatch(RouteRulesPatch patch) async {
    final kernel = await _routeKernel();
    try {
      return RouteRulesPatchResult.fromWire(await kernel.invoke<Object?>(
        ActionMethod.saveGlobalRulesPatch,
        data: patch.toWire(),
      ));
    } on KernelProxyException catch (error) {
      final stale = RouteRulesStale.fromError(error);
      if (stale != null) throw stale;
      rethrow;
    }
  }

  /// The rule-set catalog search. This is not route data: it reads the
  /// installed `srslist.h` file through [DataApi.dataPath]'s directory fact
  /// (ADR 0005 phase 3), so the `routes.ruleSets` channel arm is gone. No FFI
  /// driver is needed, only the host's `data.path`.
  Future<dynamic> routeRuleSets(String query, int limit, {int offset = 0}) =>
      ruleSets.search(query, limit, offset: offset);
}

// Settings authoritative rows stay on the channel (ADR 0002 amended, ADR 0005
// phase 2): Room is the only writer for `ThroneSettings`. UI-only keys are Dart's
// `preferences` document (uiOnlyKeys / ui_overlay.dart) and never cross it. A
// bus-first arm here silently swallowed every write once the FFI driver attached,
// so the authoritative domain stays channel-only.
extension SettingsApi on BoxController {
  Future<dynamic> settingsSet(String key, dynamic value, {bool restart = false}) =>
      call('settings.set', {
        'key': key, 'value': value, if (restart) 'restart': true,
      });

  Future<dynamic> settingsPatch(Map<String, dynamic> values) =>
      call('settings.patch', {'value': values});

  Future<dynamic> settingsReset(List<String> keys) =>
      call('settings.reset', {'keys': keys});

  Future<dynamic> preferencesSet(Map<String, dynamic> values) =>
      call('preferences.set', {'value': values});
}

/// The one channel call the data plane still needs: the host answers with the
/// Room file's path and the schema version it actually opened at. Everything
/// after that is a `dart:ffi` read — see `lib/data/route_profiles_source.dart`.
extension DataApi on BoxController {
  Future<dynamic> dataPath() => call('data.path');

  /// The production [BackupEnvironmentFactory] bound to this controller.
  Future<BackupEnvironment> resolveBackupEnvironment() async {
    final reply = json(await dataPath());
    final ui = reply['backupUi'] is Map
        ? json(reply['backupUi'])
        : <String, dynamic>{};
    Map<String, Object?> doc(String key) => ui[key] is Map
        ? json(ui[key])
        : <String, Object>{};

    return BackupEnvironment(
      databasePath: '${reply['path']}',
      appVersion: '${reply['appVersion'] ?? version}',
      deviceId: '${reply['deviceId'] ?? ''}',
      deviceName: '${reply['deviceName'] ?? ''}',
      defaultGroupName: '${reply['defaultGroupName'] ?? 'Default'}',
      preferences: ui['preferences'] is Map
          ? json(ui['preferences'])
          : <String, Object?>{...preferences}..remove('webdavAccount'),
      settingsDocument: doc('settings'),
      qualityDocument: doc('quality'),
      // ADR 0005: profiles/groups are Dart-owned; backups must export the
      // document, not the unwritten Room tables. ADR 0006 stage B: a restore
      // replaces the document directly (the staged rows' only sink), so the UI
      // sees the new catalog with no Room round-trip.
      profileDocument: () async {
        try {
          final store = await configurationStore.store();
          // A fresh document is synthesised when the file is absent; that is
          // a pre-migration install whose Room tables are still authoritative,
          // so report "no document" and let export fall back to Room.
          if (!await store.exists()) return null;
          return await store.document;
        } on Object {
          return null; // unreadable document or no data.path: fall back to Room
        }
      },
      applyRestoredProfiles: (document) async {
        // S6: a backup restore is a whole-document write; it goes through the
        // owner like every other structural write. Encode the ProfilesDocument
        // to its JSON rows so the isolate/channel hop stays plain maps.
        await relayDocument('applyRestoredProfiles', <String, dynamic>{
          'document': document.toJson(),
        });
      },
      // P14/Android: the host owns the framework SQLite and the settings/
      // markers documents, where dart:ffi cannot load SQLite. These seams are
      // always wired; the writer falls back to ffi for the container on
      // desktop/CI (where Sqlite.open() works) and only uses the host when it
      // must. ADR 0006 stage C2c2a: the backup data plane no longer reads or
      // writes Room — settings/markers go through their documents.
      settingsSnapshot: () => roomSnapshotHost.settingsSnapshot(),
      markersSnapshot: () => roomSnapshotHost.markersSnapshot(),
      restoreSettings: (request) => roomSnapshotHost.restoreSettings(
        settings: request.settings,
        fromAndroid: request.fromAndroid,
        restoredProfiles: request.restoredProfiles,
        groupIds: request.groupIds,
        profileIds: request.profileIds,
      ),
      restoreMarkers: (rows) => roomSnapshotHost.restoreMarkers(rows),
    );
  }

  /// Attaches the documents directory on the host and publishes host facts.
  ///
  /// ADR 0005 phase 3: the routing screen used to need a one-time seed of the
  /// kernel's route documents from Room. That legacy chain is retired — a missing
  /// document is an empty document and Go self-seeds the Default profile — so the
  /// call now only mounts the host's read-only views and publishes host facts
  /// (e.g. `battery_exempt`) that Go's settingsWire reads. No return value is
  /// consumed; earlier versions answered a `seeded` flag nobody used.
  Future<void> dataSeedDocuments() async {
    await call('data.documents');
  }
}

/// Kernel-side log reading (LogsApi).
///
/// Two streams exist and both are answered by the host:
///  * `logs.visible` — sing-box's own log tail (`FlroneLogs`, polled).
///  * `logs.logcat.visible` — the Android logcat ring (`FlroneLogcat`), which is where
///    Kotlin-and-native problems show up. Nothing consumed it until now, so the whole
///    native path ran without a way to read it from the app.
///
/// Visibility is reference-counted through `BoxData`, so one page request per screen
/// (see [BoxDataSubscription]) and the host starts/stops sampling on the transition.
extension LogsApi on BoxController {
  /// The host clears `core.log`; the FFI kernel rows live in this process and are not
  /// touched by the channel reset, so drop them here as well.
  Future<bool> logsClear() async {
    final cleared = await act('logs.clear');
    if (cleared) clearKernelLogs();
    return cleared;
  }

  Future<bool> logcatClear() => act('logs.logcat.clear');
}



extension GroupsApi on BoxController {
  Future<bool> groupTest(dynamic tag, {List<int>? profileIds}) {
    final arguments = <String, dynamic>{'tag': tag};
    if (profileIds != null) arguments['profileIds'] = profileIds;
    return act('groups.test', arguments);
  }

  /// Selects the member named by [group]/[tag]/[nodeId] (ADR 0008 S4).
  ///
  /// Dart resolves the member and its group from the profiles document it owns.
  /// The running core still flips a selector in place through the Go
  /// `groupsSelect` action, which skips the config rebuild; every other status
  /// (`not-found`, `not-a-selector`, `not-running`, no attached core) takes the
  /// rebuild path. In both cases the settled ids are mirrored into settings and
  /// projected into `profile_selection.json`; the document is what the next
  /// build reads. A failed mirror returns false without touching the document,
  /// so settings and the build source never disagree about a live switch that
  /// did not persist.
  Future<bool> groupSelect(dynamic group, dynamic tag, {int? nodeId}) async {
    final target = await profileDocuments.selectionTargetForMember(
      groupTag: group.toString(),
      nodeTag: tag.toString(),
      nodeId: nodeId,
    );
    if (target == null) return false;
    final arguments = <String, dynamic>{
      'group': group,
      'tag': tag,
      'nodeId': ?nodeId,
    };
    final attached = kernel.attached;
    if (attached != null) {
      try {
        final reply = json(
          await attached.invoke<Object?>(
            ActionMethod.groupsSelect,
            data: arguments,
          ),
        );
        if (reply['status'] == 'switched') {
          // The core already moved. A failed persistence write must not send
          // the caller down the reload path and throw that away; report it so
          // the next start not remembering the choice is visible.
          if (!await _mirrorSelection(target)) return true;
          await recordSelection(
            profileId: target.profileId,
            groupId: target.groupId,
          );
          return true;
        }
      } catch (_) {
        // An unanswered or refused action means the same thing as a non-switched
        // status: nothing live was changed. The fallback's own failure is what
        // gets reported, so this stays quiet.
      }
    }
    return _applySelectionTarget(target);
  }

  // ADR 0004 P4a: the five session controls moved to the JSON action bus. The
  // bus carries the same argument maps and the same reply shapes the channel
  // arms did, so callers see no change: `start`/`sort` return the host's bool
  // verdict (false = refused), `remove` returns {"removed": N}, and a host
  // failure is reported and flattened to false exactly as `act` did.
  //
  // There is no channel fallback: the test session needs a running core, the
  // same precondition `speedTestOutbounds` enforces. A cold start with no
  // kernel answers false / throws rather than calling handlers that no longer
  // exist on the host.
  //
  // `visible` is deliberately NOT here: it is the demand signal for the UI's
  // EventChannel feed (BoxDataSubscription -> _syncData), not a session control,
  // so it stays on `groups.testSession.visible` (see SpeedTestApi).

  /// Attaches the bus or throws the same precondition error the other kernel-only
  /// reads use; a speed run cannot start without the core it measures through.
  ActionInvoker get _sessionKernel {
    final k = kernel.attached;
    if (k == null) {
      throw StateError(
        'The test session needs the running core; start the VPN first',
      );
    }
    return k;
  }

  /// Runs one bus control and folds its verdict into [act]'s bool semantics:
  /// a boolean reply is returned verbatim, anything else means success, and a
  /// failure is reported and answered false (never mistaken for a start).
  Future<bool> _sessionAct(ActionMethod method, [Json? args]) async {
    try {
      final reply = await _sessionKernel.invoke<Object?>(method, data: args);
      return reply is bool ? reply : true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<bool> groupTestSessionStartChecked(Json args) =>
      _sessionAct(ActionMethod.speedTestSessionStart, args);
  Future<bool> groupTestSessionStop() =>
      _sessionAct(ActionMethod.speedTestSessionStop);
  Future<bool> groupTestSessionSort(dynamic groupId) =>
      _sessionAct(ActionMethod.speedTestSessionSort, {'groupId': groupId});
  Future<dynamic> groupTestSessionRemove(List<dynamic> ids) =>
      _sessionKernel.invoke<Object?>(
        ActionMethod.speedTestSessionRemove,
        data: {'ids': ids},
      );
  Future<bool> groupTestSessionDismiss() =>
      _sessionAct(ActionMethod.speedTestSessionDismiss);
}

extension WebdavApi on BoxController {
  /// The account is one Dart-owned value in the preferences document. The old
  /// Kotlin `webdav.get` channel and the legacy Room fold are both gone; this
  /// just reads the current document. Same `{uri, user, password, fileName}`
  /// shape as before — the password is opened from its Keystore envelope (S10).
  Future<dynamic> webdavGet() async => webDavAccount.read();

  /// Connectivity is pure HTTP (phase 0): the account now comes straight from
  /// [WebDavAccountStore] instead of the old `webdav.get` channel; the
  /// PROPFIND/MKCOL probe runs in Dart (`services/webdav_client.dart`). The
  /// signature and boolean answer are unchanged.
  ///
  /// A stored password this device cannot decrypt (S10: a Keystore reset) reads
  /// as empty; the probe then fails with a 401, so the reason is reported here,
  /// where the user asked for a connection. The diagnostic is already the
  /// sentence to show (`BoxController.describe` passes a String through).
  Future<dynamic> webdavCheck() async {
    final account = await webDavAccount.read();
    final diagnostic = webDavAccount.lastDiagnostic;
    if (diagnostic != null) report(diagnostic);
    return webDavCheck(account);
  }

  /// Writes the account into the preferences document through `preferences.set`.
  /// The reply is the stored account, matching the old `webdav.set` answer.
  Future<dynamic> webdavSet(dynamic value) =>
      webDavAccount.save(value == null ? null : json(value));

  Future<WebDavBackupTransport?> _newWebDavService() => newWebDavBackup();

  /// ADR 0005 phase 4: the WebDAV file protocol moved to Dart
  /// (`services/backup_webdav.dart`). The account and the container bytes are
  /// both Dart-owned now (`backup.create` was deleted from the bridge); listing,
  /// naming, PUT and the `throne_backups.json` index are pure Dart too.
  /// Answers `true` on success, `false` on failure, or the warning text when
  /// the file uploaded but the index did not (the old bool hid that half).
  Future<dynamic> webdavUpload() async {
    final service = await _newWebDavService();
    if (service == null) return false;
    try {
      final envelope = json(await backupCreate());
      final encoded = envelope['thr'];
      if (encoded is! String || encoded.isEmpty) return false;
      final bytes = tolerantBase64Decode(encoded);
      final parts = <String>{
        if (envelope['scope'] != 'profiles') ...{
          partProfiles, partRoutes, partSettings,
        }
      };
      // `scope == profiles` still exports profiles (BackupExport.Selection always
      // has profiles = true); mirror that for the index metadata.
      if (parts.isEmpty) parts.add(partProfiles);
      final WebDavUploadResult result = await service.upload(bytes, parts);
      if (result.indexError != null) {
        report(result.indexError!);
        return 'The backup file was uploaded, but the index update failed; it may not appear in the restore list.';
      }
      return true;
    } on Object catch (error) {
      report(error);
      return false;
    }
  }

  /// Reads the newest remote backup. Listing, download, integrity checks and
  /// envelope construction are pure Dart; only the container bytes are handed
  /// to Kotlin `backup.restore` (which decodes `thr` itself). The envelope shape
  /// is identical to `backup.create`/local open, so the page is unchanged.
  Future<dynamic> webdavRead() async {
    final service = await _newWebDavService();
    if (service == null) return null;
    try {
      final entries = await service.list();
      // The old Kotlin readWebdav() answered null when the folder had no
      // backups; the page turns that into "No remote backup found".
      if (entries.isEmpty) return null;
      final bytes = await service.download(entries.first);
      final container = thrnDecode(bytes);
      return <String, dynamic>{
        'format': container.version,
        'createdAt': container.createdAt,
        // Best-effort preview for the confirmation count. The restore itself
        // reads `thr` and needs no profile list; the preview uses the ffi
        // reader where available and falls back to the host's SQL handle on a
        // stock device (where an empty preview used to reject every
        // profiles-only restore as "holds no profiles").
        'profiles': await previewProfileNames(roomSnapshotHost, container.database),
        'thr': base64Encode(bytes),
        'ui': container.flroneUi,
      };
    } on Object catch (error) {
      report(error);
      return null;
    }
  }
}



extension ConnectionsApi on BoxController {
  /// Starts (`visible`), parks (`visible: false, pause: true`) or closes the core feed.
  ///
  /// The page's activity gate keeps its three states: full while on screen,
  /// parked while covered or backgrounded (the rows already rendered stay, but
  /// the core stops sampling), and off on dispose (the rendered rows are
  /// dropped too). The core computes rates and the closed ring; the feed is a
  /// push, so there is no host-side sampler to park.
  Future<bool> connectionsSetVisible(bool visible, {bool pause = false}) async {
    final sent = await watchConnectionFeed('rows', visible, intervalMs: 1500);
    if (!visible && !pause) clearConnections();
    return sent;
  }

  Future<bool> connectionsCloseAll() =>
      invokeConnectionAction(ActionMethod.connectionsCloseAll);

  Future<bool> connectionsClose(dynamic id) =>
      invokeConnectionAction(ActionMethod.connectionsClose, {'id': '$id'});
}

extension GroupCatalogApi on BoxController {
  /// Drops the cached node catalog so the next [groupNodes] re-reads the bridge.
  ///
  /// Call this from a profile/group *write* path when the write does not itself
  /// raise a `state` aspect (the regular host push does, and is picked up by the
  /// revision check in [groupNodes]).
  void invalidateGroupNodesCache() {
    groupNodesCache = null;
    groupNodesCacheRevision = -1;
  }

  /// Attaches the kernel on demand for the catalog read. Attaching is not
  /// starting: the prewarmed service engine opens the FFI driver with no box
  /// ([RoutesApi._routeKernel] does the same). The picker works before a VPN
  /// start; only a document that Dart has not written yet has no answer.
  Future<ActionInvoker> _catalogKernel() async {
    final attached = kernel.attached;
    if (attached != null) return attached;
    try {
      await attachKernel(timeout: BoxController.kernelAttachTimeout);
    } catch (_) {
      // The engine is still booting (or gone); the typed answer below is the
      // one the picker shows, not the transport's internal wording.
    }
    return kernel.attached ??
        (throw const KernelProxyException(
          'The core is still starting. Try the picker again in a moment.',
          unanswered: true,
        ));
  }

  /// The outbound picker's list: every node of every group, id and tag only.
  ///
  /// ADR 0004 P4: the bus is the single read of the Dart-owned profiles.json
  /// (Go `handleGroupNodes` / `readProfilesDocument`). The old `groups.nodes`
  /// channel arm read the *same* file, so keeping it as a fallback was a second,
  /// duplicate read, not a Room rescue; it is gone. A failed or missing document
  /// is an error rather than a silent empty list.
  ///
  /// The picker is opened repeatedly while profiles/groups stay untouched, and
  /// these rows are the largest payload the bridge builds. A non-empty result
  /// is cached on the controller and returned for repeat calls until the
  /// `state` aspect revision moves (the aspect notifier covers both the host
  /// `profiles`/`groups` pushes and the local write paths). Empty results are
  /// never cached, so a profile set written after an empty read is picked up
  /// on the next open.
  Future<List<Json>> groupNodes() async {
    final revision = revisionOf(BoxAspect.state);
    final cached = groupNodesCache;
    if (cached != null && groupNodesCacheRevision == revision) return cached;

    final nodes =
        rows(json(await (await _catalogKernel()).invoke<Object?>(ActionMethod.groupNodes))['nodes']);
    // Only non-empty results are worth caching; an empty catalog keeps trying
    // the bus so a newly written profile set is picked up immediately.
    if (nodes.isNotEmpty) {
      // Only cache when the state aspect did not move during the fetch: a
      // write landing mid-flight would otherwise be masked by storing the
      // *new* revision next to pre-write rows.
      if (revisionOf(BoxAspect.state) == revision) {
        groupNodesCache = nodes;
        groupNodesCacheRevision = revision;
      }
    } else {
      invalidateGroupNodesCache();
    }
    return nodes;
  }
}

extension SpeedTestApi on BoxController {
  /// The running box's outbound tags, the speed screen's outbound picker.
  ///
  /// Needs a live core: Go's `currentInstance()` reports "instance is not
  /// running" when the VPN is down, so callers must either start the VPN first
  /// or use [GroupCatalogApi.groupNodes] (which needs no running core).
  Future<List<String>> speedTestOutbounds() async {
    final attached = kernel.attached;
    if (attached == null) {
      throw StateError(
        'The outbound list needs the running core; start the VPN first',
      );
    }
    final result = await attached.invoke<Object?>(
      ActionMethod.speedTestOutbounds,
    );
    final list = json(result)['outbounds'];
    return [for (final value in list as List? ?? const []) value.toString()];
  }
}

/// Bridge-performance reads on the JSON action bus (performance_actions.go).
///
/// These need a live core: the Go handlers resolve the running instance through
/// `currentInstance()`, so a stopped VPN is an error rather than silent zeros.
/// The bus is attached without starting anything — a read here is as harmless
/// as a route read before a connect.
extension BridgePerformanceApi on BoxController {
  Future<ActionInvoker> _performanceKernel() async {
    final attached = kernel.attached;
    if (attached != null) return attached;
    try {
      await attachKernel(timeout: BoxController.kernelAttachTimeout);
    } catch (_) {
      // The engine may still be booting; the typed precondition below is the
      // one a caller shows, not the transport's internal wording.
    }
    return kernel.attached ??
        (throw const KernelProxyException(
          'The core is still starting. Try again in a moment.',
          unanswered: true,
        ));
  }

  /// Tells the core whether the app is backgrounded: auto-selectors probe less
  /// often. This deliberately does not pause the instance — doing so would
  /// suppress the auto-selector/URLTest/WireGuard periodic recovery the tunnel
  /// needs. Device doze is the separate setDoze action, driven by the host.
  ///
  /// Process-wide and idempotent: the lifecycle observer only sends on a real
  /// state transition, so a resume/pause pair is one action each.
  Future<bool> setScreenOff(bool off) async {
    final reply = await (await _performanceKernel()).invoke<Object?>(
      ActionMethod.setScreenOff,
      data: {'off': off},
    );
    return reply is bool ? reply : true;
  }

}

/// Go runtime memory accounting on the JSON action bus.
///
/// Unlike the bridge-performance reads above, [runtimeMemory] is answered even
/// with no running instance — the Go handler reads the runtime directly — so a
/// stopped core reports its own (idle) footprint rather than an error. The two
/// control calls are process-wide and idempotent.
extension KernelMemoryApi on BoxController {
  Future<KernelMemoryStats> runtimeMemory() async {
    final reply = json(
      await (await _performanceKernel()).invoke<Object?>(
        ActionMethod.runtimeMemory,
      ),
    );
    return KernelMemoryStats.fromJson(reply);
  }

  /// [full] runs `debug.FreeOSMemory()`; false is the light `runtime.GC()` used
  /// for ordinary memory-pressure hints. It is required: the Go handler refuses
  /// a missing/mistyped flag rather than silently picking the expensive path.
  /// Both values work with no running instance.
  ///
  /// This is the Go half of the user-facing "release memory" action. The ART /
  /// decoded-image half is [DashboardApi.dashboardTrimArtMemory]; neither half
  /// alone releases the whole process, so callers that report a single
  /// "released" result must run both (as components/memory_panel.dart does).
  Future<bool> forceGc({required bool full}) async {
    final reply = await (await _performanceKernel()).invoke<Object?>(
      ActionMethod.forceGC,
      data: {'full': full},
    );
    return reply is bool ? reply : true;
  }

  Future<bool> setLogStream(bool enabled) async {
    final reply = await (await _performanceKernel()).invoke<Object?>(
      ActionMethod.setLogStream,
      data: {'enabled': enabled},
    );
    return reply is bool ? reply : true;
  }
}

extension UrlApi on BoxController {
  Future<bool> openUrl(String url) => act('url.open', {'url': url});
}

extension PermissionsApi on BoxController {
  /// Asks the host for the camera permission before the host's scanner opens.
  Future<bool> ensureCameraPermission() async =>
      await call('permissions.camera') == true;

  /// Opens the host's ZXing scan activity and returns the decoded payload. Multi-frame
  /// symbols are assembled on the host; null means the activity was dismissed.
  Future<String?> scanQrCode() async => await call('scan.qr') as String?;
}

extension DocumentApi on BoxController {
  Future<dynamic> documentSave(
    String name,
    String content, {
    bool redact = false,
  }) => call('document.save', {
    'name': name,
    'content': content,
    if (redact) 'redact': true,
  });
}

extension AppsApi on BoxController {
  Future<dynamic> appsList(Json args) => call('apps.list', args);

  /// Every installed package the host classifies as a mainland app (package prefix, publisher
  /// certificate country, or component names) — the access screen's smart selection.
  Future<dynamic> appsChina() => call('apps.china');
}

extension ShareApi on BoxController {
  /// The Android share sheet for one profile link.
  Future<dynamic> shareText(dynamic content) =>
      call('share.text', {'content': content});
}

extension ServiceApi on BoxController {
  /// The dashboard's "restart required" Apply.
  ///
  /// Records the deliberate relaunch in the boot guard before the host kills the process
  /// ([BootStage.restarting]). The badge only exists while the service runs, so the sticky
  /// service may be restarted by Android in the next process; the host gates that automatic
  /// start on the marker, and without the record the previous launch still reads as `running`
  /// — the start is not gated, and a start that crashes the relaunch repeats on every launch.
  /// A deliberate restart is not a failed launch, so the next boot guard decision stays clean.
  Future<bool> restartApp() async {
    try {
      final previous = BootRecord.fromJson(preferences[BootGuard.preferenceKey]);
      final profileId = previous?.profileId ??
          (selectedConfigurationId > 0 ? selectedConfigurationId : null);
      await setPreferences({
        BootGuard.preferenceKey: BootRecord(
          stage: BootStage.restarting,
          profileId: profileId,
          startedAt: DateTime.now().millisecondsSinceEpoch,
          failureCount: previous?.failureCount ?? 0,
        ).encode(),
      });
    } catch (error) {
      // Bookkeeping must never be why the restart fails.
      report(error);
    }
    return serviceReload(restart: true);
  }

  Future<bool> serviceReload({bool restart = false}) async {
    // An AppRestart-level change (the log buffer) only takes effect in a new process. The host's
    // `app.restart` stops the service and relaunches; the channel works in both driver modes.
    if (restart) return await call('app.restart') == true;
    if (kernel.ffiMode) {
      return _kernelOp(
        this,
        () => kernel.reloadService(reason: 'service.reload from the UI'),
      );
    }
    return act('service.reload', restart ? {'restart': true} : null);
  }

  Future<bool> serviceStart() async {
    if (!kernel.ffiMode) {
      // Starting the Android service is what spawns the service engine. The
      // engine auto-starts the core, but the UI still has to attach to it to
      // receive dashboard/rates events — the channel no longer pushes those in
      // FFI mode, so waiting for the port is part of the start.
      if (!await act('service.start')) return false;
      if (kernel.remote) {
        try {
          // attachKernel, not a bare connect: the start's own connect is the
          // path that used to leave a live proxy with no event listener (every
          // driver event silently dropped while `active` reported true).
          await attachKernel(timeout: const Duration(seconds: 10));
        } catch (error) {
          // The engine did not come up in time: unanswered, not refused. The
          // caller keeps its optimistic state and the reconnect loop converges.
          if (kernelUnanswered(error)) rethrow;
          report(error);
          return false;
        }
      }
    }
    return _serviceOp(this, kernel.startService);
  }

  Future<bool> serviceStop() async {
    if (kernel.ffiMode) {
      final stopped = await _serviceOp(this, kernel.stopService);
      if (stopped) return true;
      // The service engine may have gone down with a killed process; the
      // platform channel is still the authority for the Android service.
    }
    return act('service.stop');
  }
}




extension DashboardApi on BoxController {
  /// ART / decoded-image trim only. The host handler (FlronePlatformBridge's
  /// `dashboard.releaseMemory`) calls `FlroneMemory.release()`, which trims the
  /// ART heap and asks Flutter to drop decoded images — it never touches the Go
  /// heap. Callers that must also collect the core must pair this with
  /// [KernelMemoryApi.forceGc] and measure the freed Go bytes themselves (the
  /// memory panel does exactly this). The wire name stays `dashboard.releaseMemory`
  /// for bridge compatibility.
  Future<bool> dashboardTrimArtMemory() => act('dashboard.releaseMemory');

  Future<dynamic> dashboardProbeOpen(dynamic id) =>
      call('dashboard.probe.open', {'id': id});
  Future<dynamic> dashboardProbeGet(
    dynamic id,
    String url,
    int timeoutMillis,
  ) => call('dashboard.probe.get', {
    'id': id,
    'url': url,
    'timeoutMillis': timeoutMillis,
  });
  Future<dynamic> dashboardProbeClose(dynamic id) =>
      call('dashboard.probe.close', {'id': id});
  Future<dynamic> dashboardEgress(dynamic id, {bool force = false}) =>
      call('dashboard.egress', {'id': id, if (force) 'force': true});
}

extension BackupApi on BoxController {
  /// ADR 0005 phase 4: the Room snapshot and THRN packing are Dart-owned.
  /// The host contributes only facts Dart cannot derive (via `data.path`);
  /// the envelope shape is unchanged so BackupPage and the WebDAV transport
  /// need no edit.
  Future<BackupEnvironment> _environment() =>
      backupEnvironment?.call() ?? resolveBackupEnvironment();

  Future<dynamic> backupCreate([String scope = 'all']) async {
    final injected = backupCreateFn;
    if (injected != null) return injected(scope);
    final env = await _environment();
    return createBackup(env: env, scope: scope, host: roomSnapshotHost);
  }

  Future<dynamic> backupRestore(
    dynamic backup,
    dynamic scope,
    dynamic strategy,
  ) async {
    final injected = backupRestoreFn;
    if (injected != null) return injected(backup, '$scope', '$strategy');
    final payload = json(backup);
    final encoded = payload['thr'];
    if (encoded is! String || encoded.isEmpty) {
      throw const FormatException('Backup envelope has no container');
    }
    final env = await _environment();
    final result = await restoreBackup(
      env: env,
      // Tolerant decode: Kotlin's `Base64.DEFAULT` wraps at 76 columns and a
      // `.thrbackup` staged through the host carries those newlines.
      bytes: tolerantBase64Decode(encoded),
      scope: '$scope',
      strategy: '$strategy',
      host: roomSnapshotHost,
      // The native bridge refreshed the catalog after a restore; keep that
      // contract so the proxies/profiles screens redraw the new rows.
      refresh: () => call('data.refresh'),
      // A full-scope restore restores the UI documents through the narrow host
      // writer; the WebDAV account (a credential) is never restored.
      applyUi: '$scope' == 'all'
          ? (ui) => call('data.applyBackupUi', {'ui': ui})
          : null,
    );
    if (result.warnings.isNotEmpty) {
      report(result.warnings.join('\n'));
    }
    // A wording-only note: the restore's profile part is a document write that
    // fails before anything else commits, so there is no "committed but stale"
    // state left to report here.
    return result;
  }
}
extension MiscApi on BoxController {
  Future<dynamic> updatesCheck() => call('updates.check');
  Future<bool> systemProxySet(bool enabled) =>
      act('systemProxy.set', {'enabled': enabled});
  Future<bool> modeSet(dynamic mode) async {
    if (kernel.ffiMode) {
      return _kernelOp(this, () => kernel.setMode(mode.toString()));
    }
    return act('mode.set', {'mode': mode});
  }

  Future<dynamic> filesOpen(String uri) => call('files.open', {'uri': uri});
  Future<dynamic> dnsSuggestions() => call('dns.suggestions');
  Future<bool> batteryOpen() => act('battery.open');
  Future<dynamic> configCheck(String content) =>
      call('config.check', {'content': content});
}

/// OpenVPN / OpenConnect sign-in challenges.
///
/// The three control calls are Dart-driven through the JSON action bus. Status
/// *changes* are pushed by Go as `vpnStatus` message-port events, forwarded by
/// KernelService to BoxEventBus; a screen can subscribe without polling, and a
/// sheet opened later reads the latest snapshot with [vpnStatus]. No answers or
/// credentials are cached here — the sheet owns the fields for its lifetime.
extension VpnAuthApi on BoxController {
  Future<ActionInvoker> _vpnKernel() async {
    final attached = kernel.attached;
    if (attached != null) return attached;
    try {
      await attachKernel(timeout: BoxController.kernelAttachTimeout);
    } catch (_) {
      // The engine may still be booting; the typed precondition below is the
      // one the UI shows, not the transport's internal wording.
    }
    return kernel.attached ??
        (throw const KernelProxyException(
          'The core is still starting. Try again in a moment.',
          unanswered: true,
        ));
  }

  /// The current endpoint statuses; `timeoutMs > 0` waits for a still-handshaking
  /// endpoint to settle. The wire is the core's raw JSON array.
  Future<List<Json>> vpnStatus({int timeoutMs = 0}) async {
    final raw = await (await _vpnKernel()).invoke<Object?>(
      ActionMethod.vpnStatus,
      data: timeoutMs > 0 ? {'timeoutMs': timeoutMs} : const <String, dynamic>{},
    );
    if (raw is List) {
      return [for (final item in raw) if (item is Map) json(item)];
    }
    return const <Json>[];
  }

  /// Installs the Go watcher. The first call posts one status push immediately;
  /// every later endpoint change is pushed as another `vpnStatus` event.
  Future<bool> vpnWatchStatus() async {
    final reply = json(await (await _vpnKernel()).invoke<Object?>(
      ActionMethod.vpnWatchStatus,
    ));
    return reply['watching'] == true;
  }

  /// Answers one challenge. [answer] holds only the four documented keys —
  /// never log or persist it.
  Future<void> vpnSubmitChallenge(String tag, String id, Json answer) async {
    await (await _vpnKernel()).invoke<Object?>(
      ActionMethod.submitVPNChallenge,
      data: {'tag': tag, 'id': id, 'answer': answer},
    );
  }

  /// Gives up on one challenge.
  Future<void> vpnCancelChallenge(String tag, String id) async {
    await (await _vpnKernel()).invoke<Object?>(
      ActionMethod.cancelVPNChallenge,
      data: {'tag': tag, 'id': id},
    );
  }
}

/// The manual "Update resources" action, the Throne half of FlClash's
/// `ResourcesAction.updateAll` (lib/providers/actions/resources.dart): the core
/// refetches the running config's remote rule-sets.
extension ResourcesApi on BoxController {
  /// Runs the refetch and folds the answer into what the banner shows.
  ///
  /// Rule sets need a live instance: with the tunnel stopped the work is skipped
  /// ([ResourceUpdateReport.ruleSetsSkipped] says so) instead of producing the
  /// control's typed refusal.
  Future<ResourceUpdateReport> updateResources() async {
    final coreRunning = running;
    Map<String, dynamic>? ruleSets;
    Object? ruleSetsFailure;
    if (coreRunning) {
      try {
        ruleSets = await kernel.updateRuleSets();
      } catch (error) {
        ruleSetsFailure = error;
      }
    }
    return foldResourceUpdate(
      coreRunning: coreRunning,
      ruleSets: ruleSets,
      ruleSetsFailure: ruleSetsFailure,
    );
  }
}

/// One manual "Update resources" run, as the routing screen reports it.
///
/// Pure data: the page decides the wording, this type only says what happened.
class ResourceUpdateReport {
  const ResourceUpdateReport({
    required this.coreRunning,
    required this.ruleSetsUpdated,
    required this.ruleSetsError,
    required this.ruleSetsFailure,
  });

  /// The dashboard said the tunnel was up when the action started.
  final bool coreRunning;

  /// Rule sets the core fetched and cached.
  final int ruleSetsUpdated;

  /// The core's own failure text for individual sets (empty when every one was
  /// fetched); the update partially succeeded, [ruleSetsUpdated] still counts.
  final String ruleSetsError;

  /// The rule-set call itself failed (no instance / transport): user-facing text
  /// from [BoxController.describe]. No count exists then.
  final String? ruleSetsFailure;

  /// Rule sets were not attempted because the core is stopped.
  bool get ruleSetsSkipped => !coreRunning;

  /// Everything that was attempted fully succeeded.
  bool get clean => ruleSetsFailure == null && ruleSetsError.isEmpty;
}

/// Folds the raw answer of a manual "Update resources" run into
/// [ResourceUpdateReport]. Extracted so the counting is unit-testable without a
/// core or a channel.
ResourceUpdateReport foldResourceUpdate({
  required bool coreRunning,
  Map<String, dynamic>? ruleSets,
  Object? ruleSetsFailure,
}) {
  final rulesAnswer = ruleSets ?? const <String, dynamic>{};
  return ResourceUpdateReport(
    coreRunning: coreRunning,
    ruleSetsUpdated:
        coreRunning && ruleSetsFailure == null ? (rulesAnswer['updated'] as num?)?.toInt() ?? 0 : 0,
    ruleSetsError: coreRunning && ruleSetsFailure == null
        ? rulesAnswer['error']?.toString() ?? ''
        : '',
    ruleSetsFailure: ruleSetsFailure == null ? null : BoxController.describe(ruleSetsFailure),
  );
}

