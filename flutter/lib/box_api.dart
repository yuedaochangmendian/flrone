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
  // `profiles.applyDocument` into `ConfigurationStore`. What still crosses to Kotlin
  // needs the Throne outbound model (parsing/validation), the subscription
  // queue, a Kotlin-owned selection setting or the auto-selector runtime: ONE
  // `profiles.platform` call with `{op, payload}`. `FlroneProfileDuty.kt` lists
  // the ops; tools/diagnostics/platform_duty_audit.py holds the two sides
  // together, so an op cannot drift or go dead.
  Future<dynamic> configurationPlatform(String op, [Json payload = const {}]) =>
      call('profiles.platform', {'op': op, 'payload': payload});

  /// One duty op folded into [act]'s bool semantics: a failure is reported and
  /// answered false, never mistaken for success.
  Future<bool> _configurationDutyAct(String op, [Json payload = const {}]) async {
    try {
      await configurationPlatform(op, payload);
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<dynamic> configurationDecodeIntent(String uri) =>
      configurationPlatform('decodeIntent', {'uri': uri});
  Future<dynamic> autoSelectorInfo(dynamic id) =>
      configurationPlatform('autoSelectorInfo', {'id': id});
  Future<dynamic> autoSelectorStatus() =>
      configurationPlatform('autoSelectorStatus');
  Future<dynamic> autoSelectorPin(dynamic id, dynamic memberId) =>
      configurationPlatform('autoSelectorPin', {'id': id, 'memberId': memberId});
  Future<dynamic> autoSelectorRecheck() =>
      configurationPlatform('autoSelectorRecheck');
  Future<dynamic> autoSelectorSave(dynamic id, Json value) =>
      configurationPlatform('autoSelectorSave', {'id': id, 'value': value});
  Future<dynamic> autoSelectorCreate(dynamic groupId, {String? name}) =>
      configurationPlatform('autoSelectorCreate', {'groupId': groupId, 'name': ?name});
  Future<dynamic> configurationConfig(dynamic id) =>
      configurationPlatform('config', {'id': id});

  /// A subscription refresh is *enqueued*, not awaited: the Kotlin `update` op
  /// hands the download to `SubscriptionQueue` and returns at once, and the
  /// real outcome arrives later as `subscriptionReport` events (log surface +
  /// notification). The old retryCall wrapper pretended to bound a download it
  /// never touched — two attempts against the enqueue, a 60 s timeout against
  /// a call that returns in milliseconds. Failures are reported by the event
  /// stream; retry here means "tap refresh again".
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

  Future<dynamic> nodeLink(String group, String tag, dynamic nodeJson) =>
      configurationPlatform('nodeLink', {'group': group, 'tag': tag, 'json': nodeJson});
  Future<dynamic> nodeDelete(dynamic id) =>
      configurationPlatform('nodeDelete', {'id': id});
  Future<dynamic> nodeConfig(dynamic id) =>
      configurationPlatform('nodeConfig', {'id': id});
  Future<dynamic> nodeUpdate(dynamic id, String name, String content) =>
      configurationPlatform('nodeUpdate', {'id': id, 'name': name, 'content': content});
  Future<dynamic> nodeTuningInfo(dynamic id) =>
      configurationPlatform('nodeTuningInfo', {'id': id});
  Future<dynamic> nodeTuningSave(dynamic id, Json value) =>
      configurationPlatform('nodeTuningSave', {'id': id, 'value': value});
  Future<dynamic> configurationRead(dynamic id) =>
      configurationPlatform('read', {'id': id});
  Future<bool> configurationClearTestResults(dynamic id) =>
      _configurationDutyAct('clearTestResults', {'id': id});
  Future<bool> configurationClearTraffic(dynamic id) =>
      _configurationDutyAct('clearTraffic', {'id': id});
  Future<bool> configurationDelete(dynamic id) =>
      _configurationDutyAct('delete', {'id': id});

  /// The selection is a Kotlin-owned setting and a running kernel must switch
  /// to it; the duty writes it and the proxy notifies the kernel.
  Future<bool> configurationSwitchRelative(int step) async {
    final done = await _configurationDutyAct('switchRelative', {'step': step});
    if (done && kernel.ffiMode) await kernel.onSelectionChanged();
    return done;
  }

  Future<bool> configurationSelect(dynamic id) async {
    final done = await _configurationDutyAct('select', {'id': id});
    if (done && kernel.ffiMode) await kernel.onSelectionChanged();
    return done;
  }

  /// SAF picker: platform UI, not profile data.
  Future<dynamic> configurationImportFile() => call('files.pickProfile');
  Future<dynamic> createNode(dynamic type) =>
      configurationPlatform('createNode', {'type': type});
  Future<dynamic> nodeCreate(Json value) =>
      configurationPlatform('nodeCreate', value);

  /// The node page's list: the single-node container's rows in list order. The
  /// reply carries `groupId`, `groupName` and `nodes` (`{id, name, type, delay,
  /// testedAt}`); the editor reads the full document through [nodeConfig].
  Future<Json> nodeList() async => json(await configurationPlatform('nodeList'));

  /// Reorders the node page's list to [ids] (the container group's member order
  /// in the profiles document). The host writes through Dart's store, so the
  /// next [nodeList] answers the saved sequence.
  Future<bool> nodeReorder(int groupId, List<dynamic> ids) =>
      _configurationDutyAct('nodeReorder', {'groupId': groupId, 'ids': ids});

  /// Single-node import: one share link, a list of them or a base64
  /// subscription → `{nodes: [{name, type, json}], skipped, messages}`.
  Future<Json> nodeParse(String text) async =>
      json(await configurationPlatform('nodeParse', {'text': text}));
  Future<dynamic> configurationSave(Json value) => configurationPlatform('save', value);
  Future<bool> configurationReorder(List<dynamic> ids) =>
      _configurationDutyAct('reorder', {'ids': ids});
  Future<dynamic> configurationWrite(dynamic id, String content, dynamic revision) =>
      configurationPlatform('write', {
        'id': id,
        'content': content,
        'revision': revision,
      });
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

  /// Replaces the whole global table. A write never degrades: swallowing it
  /// would show the edit as applied while the kernel kept the old rules.
  Future<dynamic> routeSaveGlobalRules(dynamic rules) async =>
      (await _routeKernel()).invoke<Object?>(
        ActionMethod.saveGlobalRules,
        data: {'rules': rules},
      );

  /// Deletes one rule from the global table.
  Future<dynamic> routeDeleteGlobalRule(dynamic id) async => (await _routeKernel())
      .invoke<Object?>(ActionMethod.deleteGlobalRule, data: {'id': id});

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
        await (await configurationStore.store()).replaceAll(document);
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

  /// Seeds the kernel's route documents from Room once, on an UPGRADED device.
  ///
  /// ADR 0005 phase 3 decision: KEEP this call. Go self-seeds the Default
  /// profile (`readRouteState(true)`) so a fresh install needs no UI seed, but
  /// an install that already has legacy per-profile Room rows still
  /// needs that one-time export — without it the kernel sees empty documents
  /// and the user's saved routes are lost. The host no-ops when the documents
  /// already exist, so Go remains the sole ongoing writer (handover, not
  /// dual-write). The same handler also seeds the UI docs and publishes host
  /// facts (e.g. `battery_exempt`) that Go's settingsWire reads.
  Future<bool> dataSeedDocuments() async {
    final raw = normalizePlatformValue(await call('data.documents'));
    return raw is Map && raw['seeded'] == true;
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

  Future<bool> groupSelect(dynamic group, dynamic tag, {int? nodeId}) async {
    final arguments = <String, dynamic>{
      'group': group,
      'tag': tag,
      'nodeId': ?nodeId,
    };
    if (kernel.ffiMode) {
      final done = await act('groups.select', arguments);
      if (done) await kernel.onSelectionChanged();
      return done;
    }
    return act('groups.select', arguments);
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

  Future<dynamic> groupTestSessionStart(Json args) =>
      _sessionKernel.invoke<Object?>(ActionMethod.speedTestSessionStart, data: args);
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

extension GroupSettingsApi on BoxController {
  Future<dynamic> groupSettingsGet(dynamic id) =>
      call('groupSettings.get', {'id': id});
  Future<dynamic> groupSettingsSet(Json value) =>
      call('groupSettings.set', {'value': value});
}


extension WebdavApi on BoxController {
  /// The account is a Dart-owned value in the preferences document (ADR 0005
  /// phase 1). The old Kotlin `webdav.get` channel is gone; the host folds the
  /// legacy Room account into `preferences` on upgrade so this just reads the
  /// current document. Same `{uri, user, password, fileName}` shape as before —
  /// the password is opened from its Keystore envelope (S10) inside the store.
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

  /// Writes the account into the preferences document. The host's
  /// `preferences.set` mirrors `webdavAccount` back to Room for the phase-4
  /// container codec. The reply is the stored account, matching old `webdav.set`.
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
  /// Starts (`visible`), parks (`visible: false, pause: true`) or closes the sampled feed.
  ///
  /// The host's three states are the page's activity gate's, not a switch: a page mounted
  /// in the background or covered by another route asks for `pause`, which stops the 1.5 s
  /// sample loop but keeps the rows and the closed ring already emitted — a short cover must
  /// not blank the list. A plain `visible: false` is the dispose path and drops both, so the
  /// dashboard card cannot inherit a stale list. While parked, the card's count keeps coming
  /// from the host's cheap list-length poll (`dashboard.connections`, S6).
  Future<bool> connectionsSetVisible(bool visible, {bool pause = false}) => act(
    'connections.visible',
    {'visible': visible, if (pause) 'pause': true},
  );
  Future<bool> connectionsCloseAll() => act('connections.closeAll');
  Future<bool> connectionsClose(dynamic id) =>
      act('connections.close', {'id': id});

  /// Why the list is empty: `{running, apiEnabled, reachable, port, address, error, pumpError}`.
  Future<Json> connectionsState() async => json(await call('connections.state'));

  /// Turns the core's Clash API on; the core has to reload before the port answers.
  Future<({bool changed, Json state})> connectionsEnableApi() async {
    final result = json(await call('connections.enableApi'));
    return (changed: result['changed'] == true, state: json(result['state']));
  }
}

extension GroupCatalogApi on BoxController {
  /// Asks for the node rows (true) or gives them back (false); `ready` and every other screen
  /// carry counts only, because the rows are the largest payload the bridge builds.
  Future<bool> groupsSetVisible(bool visible) =>
      act('groups.visible', {'visible': visible});

  /// The outbound picker's list: every node of every group, id and tag only.
  ///
  /// ADR 0004 P4: the kernel answers from Room over the action bus (the same
  /// rows `ProfileManager` reads). Screens that render before the VPN starts
  /// have no driver attached, so those keep the channel fallback; once the
  /// driver is up the bus is authoritative and a failed kernel read surfaces
  /// rather than being masked by a second, differently-shaped answer.
  Future<List<Json>> groupNodes() async {
    final attached = kernel.attached;
    if (attached != null) {
      try {
        final nodes =
            rows(json(await attached.invoke<Object?>(ActionMethod.groupNodes))['nodes']);
        // Go reads the Dart-owned profiles.json (P13). Before the one-time
        // migration has produced that file it answers an empty catalog even
        // when Room still holds the profiles, so an empty bus answer falls
        // through once: the host's ProfileManager is the Room reader until the
        // document exists, and the picker must not open empty on an upgraded
        // device's first launch.
        if (nodes.isNotEmpty) return nodes;
      } catch (_) {
        // Read-only: the channel answers the same rows through ProfileManager
        // when the kernel cannot reach Room (missing file / WAL lock). A failed
        // write, by contrast, must surface rather than be re-applied.
      }
    }
    return rows(json(await call('groups.nodes'))['nodes']);
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

extension CrashesApi on BoxController {
  Future<dynamic> crashesList() => call('crashes.list', {});
  Future<dynamic> crashesRead(dynamic name) =>
      call('crashes.read', {'name': name});
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
  Future<bool> wifiPermissionsEnsure() => act('wifiPermissions.ensure');
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

