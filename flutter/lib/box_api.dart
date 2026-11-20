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

extension ProfilesApi on BoxController {
  // ADR 0005 final stage: profiles/groups are Dart-owned data, written through
  // `profiles.applyDocument` into `ProfileStore`. What still crosses to Kotlin
  // needs the Throne outbound model (parsing/validation), the subscription
  // queue, a Kotlin-owned selection setting or the auto-selector runtime: ONE
  // `profiles.platform` call with `{op, payload}`. `BboxProfileDuty.kt` lists
  // the ops; tools/diagnostics/platform_duty_audit.py holds the two sides
  // together, so an op cannot drift or go dead.
  Future<dynamic> profilePlatform(String op, [Json payload = const {}]) =>
      call('profiles.platform', {'op': op, 'payload': payload});

  /// One duty op folded into [act]'s bool semantics: a failure is reported and
  /// answered false, never mistaken for success.
  Future<bool> _profileDutyAct(String op, [Json payload = const {}]) async {
    try {
      await profilePlatform(op, payload);
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<dynamic> profileDecodeIntent(String uri) =>
      profilePlatform('decodeIntent', {'uri': uri});
  Future<dynamic> profileAutoSelectorInfo(dynamic id) =>
      profilePlatform('autoSelectorInfo', {'id': id});
  Future<dynamic> profileAutoSelectorStatus() =>
      profilePlatform('autoSelectorStatus');
  Future<dynamic> profileAutoSelectorPin(dynamic id, dynamic memberId) =>
      profilePlatform('autoSelectorPin', {'id': id, 'memberId': memberId});
  Future<dynamic> profileAutoSelectorRecheck() =>
      profilePlatform('autoSelectorRecheck');
  Future<dynamic> profileAutoSelectorSave(dynamic id, Json value) =>
      profilePlatform('autoSelectorSave', {'id': id, 'value': value});
  Future<dynamic> profileAutoSelectorCreate(dynamic groupId, {String? name}) =>
      profilePlatform('autoSelectorCreate', {'groupId': groupId, 'name': ?name});
  Future<dynamic> profileConfig(dynamic id) =>
      profilePlatform('config', {'id': id});

  /// Subscription refreshes are network-bound: bounded retry with a per-attempt
  /// timeout keeps a stalled download from hanging the UI indefinitely.
  Future<bool> profileUpdate(dynamic id) async {
    try {
      await retryCall<dynamic>(
        task: () => profilePlatform('update', {'id': id}),
        maxAttempts: 2,
        timeout: const Duration(seconds: 60),
      );
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  Future<dynamic> profileNodeLink(String group, String tag, dynamic nodeJson) =>
      profilePlatform('nodeLink', {'group': group, 'tag': tag, 'json': nodeJson});
  Future<dynamic> profileNodeDelete(dynamic id) =>
      profilePlatform('nodeDelete', {'id': id});
  Future<dynamic> profileNodeConfig(dynamic id) =>
      profilePlatform('nodeConfig', {'id': id});
  Future<dynamic> profileNodeUpdate(dynamic id, String name, String content) =>
      profilePlatform('nodeUpdate', {'id': id, 'name': name, 'content': content});
  Future<dynamic> profileNodeTuningInfo(dynamic id) =>
      profilePlatform('nodeTuningInfo', {'id': id});
  Future<dynamic> profileNodeTuningSave(dynamic id, Json value) =>
      profilePlatform('nodeTuningSave', {'id': id, 'value': value});
  Future<dynamic> profileRead(dynamic id) =>
      profilePlatform('read', {'id': id});
  Future<bool> profileClearTestResults(dynamic id) =>
      _profileDutyAct('clearTestResults', {'id': id});
  Future<bool> profileClearTraffic(dynamic id) =>
      _profileDutyAct('clearTraffic', {'id': id});
  Future<bool> profileDelete(dynamic id) =>
      _profileDutyAct('delete', {'id': id});

  /// The selection is a Kotlin-owned setting and a running kernel must switch
  /// to it; the duty writes it and the proxy notifies the kernel.
  Future<bool> profileSwitchRelative(int step) async {
    final done = await _profileDutyAct('switchRelative', {'step': step});
    if (done && kernel.ffiMode) await kernel.onSelectionChanged();
    return done;
  }

  Future<bool> profileSelect(dynamic id) async {
    final done = await _profileDutyAct('select', {'id': id});
    if (done && kernel.ffiMode) await kernel.onSelectionChanged();
    return done;
  }

  /// SAF picker: platform UI, not profile data.
  Future<dynamic> profileImportFile() => call('files.pickProfile');
  Future<dynamic> profileCreateNode(dynamic groupId, dynamic type) =>
      profilePlatform('createNode', {'groupId': groupId, 'type': type});
  Future<dynamic> profileNodeCreate(Json value) =>
      profilePlatform('nodeCreate', value);
  Future<dynamic> profileSave(Json value) => profilePlatform('save', value);
  Future<bool> profileReorder(List<dynamic> ids) =>
      _profileDutyAct('reorder', {'ids': ids});
  Future<dynamic> profileWrite(dynamic id, String content, dynamic revision) =>
      profilePlatform('write', {
        'id': id,
        'content': content,
        'revision': revision,
      });
}

extension RoutesApi on BoxController {
  // The route surface, ADR 0002 phase 3c.
  //
  // The kernel owns the route documents and is their only writer, so every call goes
  // through the JSON action bus. The channel arms are gone: without the FFI driver there is
  // no route store to answer from, and old-version compatibility was dropped deliberately.
  //
  // The routing UI edits route profiles again (list, editor, delete, current
  // marker, batch add, reset) against the kernel-owned documents, plus the shared
  // global pool with its per-profile opt-outs. Only the rule-set catalog search
  // stays on the channel: it reads the installed files, not route data.
  ActionInvoker _routeKernel() =>
      kernel.attached ??
      (throw StateError(
        'the route store needs the FFI driver; start the VPN first',
      ));

  /// The route list, read over the JSON action bus. Go owns the route documents
  /// and is their only writer; there is deliberately no `routes.list` channel
  /// fallback (ADR 0005 phase 3) — without the FFI driver there is no
  /// authoritative answer, and a stale Room snapshot must not be shown.
  Future<dynamic> routeList() =>
      _routeKernel().invoke<Object?>(ActionMethod.getRouteProfiles);

  /// One profile's metadata and its simple-rule text, the editor's seed. `id`
  /// 0 answers an empty seed for a new profile.
  ///
  /// Like every route read, this has no channel fallback (ADR 0005 phase 3):
  /// a missing FFI driver surfaces the kernel error rather than a stale answer.
  Future<dynamic> routeGetProfile(dynamic id) =>
      _routeKernel().invoke<Object?>(ActionMethod.getRouteProfile, data: {'id': id});

  /// Creates or updates a route profile; absent fields are left untouched.
  ///
  /// A write never degrades: swallowing it would show the edit as applied while
  /// the profile stayed as it was.
  Future<dynamic> routeSaveProfile({
    dynamic id,
    String? name,
    String? defaultOutbound,
    bool? isRemote,
    String? remoteUrl,
    bool? autoUpdate,
    List<int>? endpointIds,
    String? rules,
  }) => _routeKernel().invoke<Object?>(ActionMethod.saveRouteProfile, data: {
    'id': id,
    'name': name,
    'defaultOutbound': defaultOutbound,
    'isRemote': isRemote,
    'remoteUrl': remoteUrl,
    'autoUpdate': autoUpdate,
    'endpointIds': endpointIds,
    'rules': rules,
  });

  /// Deletes a route profile and its rules; the last profile is refused.
  Future<dynamic> routeDeleteProfile(dynamic id) => _routeKernel()
      .invoke<Object?>(ActionMethod.deleteRouteProfile, data: {'id': id});

  /// Marks a profile as the active route at the kernel alone: it moves the route
  /// document's `__current` marker. The host's `settings.current_route_id` row
  /// is NOT written, so a config built afterwards can still follow the previous
  /// selection. Use [routeSetCurrentHost] to change the selection.
  Future<dynamic> routeSetCurrent(dynamic id) =>
      _routeKernel().invoke<Object?>(ActionMethod.setCurrentRoute, data: {'id': id});

  /// Marks a profile as the active route through the host, which is the writer
  /// of both stores: `DataStore.currentRouteId` (Room, the `settings` table the
  /// config build reads) first, then the kernel's document marker. A UI
  /// selection must take this path — the Go bus alone would leave the
  /// authoritative row on the previous profile.
  Future<dynamic> routeSetCurrentHost(dynamic id) =>
      call('state.setCurrentRoute', {'id': id});

  /// Adds one rule per non-empty line of `prefix:value -> outbound`.
  Future<dynamic> routeBatchAddRules(dynamic id, String text) => _routeKernel()
      .invoke<Object?>(ActionMethod.batchAddRules, data: {'id': id, 'text': text});

  /// Resets a profile's rules to the Default chain's.
  Future<dynamic> routeResetRules(dynamic id) =>
      _routeKernel().invoke<Object?>(ActionMethod.resetRouteRules, data: {'id': id});

  Future<dynamic> routeRules(dynamic id) =>
      _routeKernel().invoke<Object?>(ActionMethod.getRouteRules, data: {'id': id});

  Future<dynamic> routeSaveRules(dynamic id, dynamic rules) => _routeKernel()
      .invoke<Object?>(ActionMethod.saveRouteRules, data: {'id': id, 'rules': rules});

  /// The rule-set catalog search. This is not route data: it reads the
  /// installed `srslist.h` file through [DataApi.dataPath]'s directory fact
  /// (ADR 0005 phase 3), so the `routes.ruleSets` channel arm is gone. No FFI
  /// driver is needed, only the host's `data.path`.
  Future<dynamic> routeRuleSets(String query, int limit) =>
      ruleSets.search(query, limit);

  Future<dynamic> routeGlobalRules(dynamic profileId) => _routeKernel()
      .invoke<Object?>(ActionMethod.getGlobalRules, data: {'profileId': profileId});

  Future<dynamic> routeSaveGlobalRules(dynamic rules) =>
      _routeKernel().invoke<Object?>(ActionMethod.saveGlobalRules, data: {'rules': rules});

  Future<dynamic> routeDeleteGlobalRule(dynamic id) =>
      _routeKernel().invoke<Object?>(ActionMethod.deleteGlobalRule, data: {'id': id});
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
      // document, not the unwritten Room tables. Restore rebuilds the document
      // from the committed rows so the UI sees them without a restart.
      profileDocument: () async {
        try {
          final store = await profileStore.store();
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
        await (await profileStore.store()).replaceAll(document);
      },
      // P14: the host owns Room on Android, where dart:ffi cannot load SQLite.
      // These seams are always wired; the writer falls back to ffi on desktop/CI
      // (where Sqlite.open() works) and only uses them when it must.
      roomSnapshot: (profiles, groups) async {
        final reply = await roomSnapshotHost.roomSnapshot(
          profiles: profiles,
          groups: groups,
        );
        return reply;
      },
      applyRoomSnapshot: (rows) => roomSnapshotHost.applyRoomSnapshot(rows),
    );
  }

  /// Seeds the kernel's route documents from Room once, on an UPGRADED device.
  ///
  /// ADR 0005 phase 3 decision: KEEP this call. Go self-seeds the Default
  /// profile (`readRouteState(true)`) so a fresh install needs no UI seed, but
  /// an install that already has Room `route_profiles`/`route_rules` rows still
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
///  * `logs.visible` — sing-box / Xray's own log tail (`BboxLogs`, polled).
///  * `logs.logcat.visible` — the Android logcat ring (`BboxLogcat`), which is where
///    Kotlin-and-native problems show up. Nothing consumed it until now, so the whole
///    native path ran without a way to read it from the app.
///
/// Visibility is reference-counted through `BoxData`, so one page request per screen
/// (see [BoxDataSubscription]) and the host starts/stops sampling on the transition.
extension LogsApi on BoxController {
  Future<bool> logsClear() => act('logs.clear');
  Future<bool> logcatClear() => act('logs.logcat.clear');

  /// The previous session's kernel tail (`core.log.prev`), parsed by the host like the live
  /// one. A missing file answers an empty batch; the log screen fetches it on demand.
  Future<dynamic> logsPrevious() => call('logs.previous');
}

extension TerminalApi on BoxController {
  Future<dynamic> terminalSettings() => call('terminal.settings');
  Future<dynamic> terminalSet(dynamic key, dynamic value) =>
      call('terminal.set', {'key': key, 'value': value});
  Future<bool> terminalSetChecked(dynamic key, dynamic value) =>
      act('terminal.set', {'key': key, 'value': value});
  Future<dynamic> terminalThemes(bool dark) =>
      call('terminal.themes', {'dark': dark});
  Future<dynamic> terminalFonts() => call('terminal.fonts');
  Future<bool> terminalImportFont() => act('terminal.importFont');
  Future<bool> terminalDeleteFont(dynamic path) =>
      act('terminal.deleteFont', {'path': path});
}

extension ReportsApi on BoxController {
  Future<dynamic> reportList(String kind) =>
      call('reports.list', {'kind': kind});
  Future<bool> reportClear(String kind) => act('reports.clear', {'kind': kind});
  Future<dynamic> reportFiles(Json args) => call('reports.files', args);
  Future<bool> reportDelete(Json args) => act('reports.delete', args);
  Future<bool> reportSave(Json args) => act('reports.save', args);
  Future<bool> reportExport(Json args) => act('reports.export', args);
  Future<dynamic> reportRead(Json args) => call('reports.read', args);
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

extension SshApi on BoxController {
  Future<dynamic> sshSnapshot() => call('ssh.snapshot');
  Future<dynamic> sshOptions(dynamic endpoint, dynamic peer) =>
      call('ssh.options', {'endpoint': endpoint, 'peer': peer});
  Future<dynamic> sshStart(
    dynamic endpoint,
    dynamic peer, {
    dynamic username,
    dynamic terminalType,
    dynamic remember,
  }) => call('ssh.start', {
    'endpoint': endpoint,
    'peer': peer,
    'username': username,
    'terminalType': terminalType,
    'remember': remember,
  });
  Future<bool> sshClose(dynamic id) => act('ssh.close', {'id': id});
  Future<bool> sshDuplicate() => act('ssh.duplicate');
  Future<bool> sshSelect(dynamic id) => act('ssh.select', {'id': id});
}

extension WebdavApi on BoxController {
  /// The account is a Dart-owned value in the preferences document (ADR 0005
  /// phase 1). The old Kotlin `webdav.get` channel is gone; the host folds the
  /// legacy Room account into `preferences` on upgrade so this just reads the
  /// current document. Same `{uri, user, password, fileName}` shape as before.
  Future<dynamic> webdavGet() async => webDavAccount.read();

  /// Connectivity is pure HTTP (phase 0): the account now comes straight from
  /// [WebDavAccountStore] instead of the old `webdav.get` channel; the
  /// PROPFIND/MKCOL probe runs in Dart (`services/webdav_client.dart`). The
  /// signature and boolean answer are unchanged.
  Future<dynamic> webdavCheck() async => webDavCheck(webDavAccount.read());

  /// Writes the account into the preferences document. The host's
  /// `preferences.set` mirrors `webdavAccount` back to Room for the phase-4
  /// container codec. The reply is the stored account, matching old `webdav.set`.
  Future<dynamic> webdavSet(dynamic value) =>
      webDavAccount.save(value == null ? null : json(value));

  WebDavBackupTransport? _newWebDavService() => newWebDavBackup();

  /// ADR 0005 phase 4: the WebDAV file protocol moved to Dart
  /// (`services/backup_webdav.dart`). The account and the container bytes are
  /// both Dart-owned now (`backup.create` was deleted from the bridge); listing,
  /// naming, PUT and the `throne_backups.json` index are pure Dart too.
  /// Returns a bool exactly like the old `webdav.upload` handler did.
  Future<dynamic> webdavUpload() async {
    final service = _newWebDavService();
    if (service == null) return false;
    try {
      final envelope = json(await backupCreate());
      final encoded = envelope['thr'];
      if (encoded is! String || encoded.isEmpty) return false;
      final bytes = base64Decode(encoded);
      final parts = <String>{
        if (envelope['scope'] != 'profiles') ...{
          partProfiles, partRoutes, partSettings,
        }
      };
      // `scope == profiles` still exports profiles (BackupExport.Selection always
      // has profiles = true); mirror that for the index metadata.
      if (parts.isEmpty) parts.add(partProfiles);
      final WebDavUploadResult result = await service.upload(bytes, parts);
      if (result.indexError != null) report(result.indexError!);
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
    final service = _newWebDavService();
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
        // reads `thr` and needs no profile list; an unreadable embedded DB just
        // means the dialog cannot pre-count the groups.
        'profiles': profileNamesFromContainer(container.database),
        'thr': base64Encode(bytes),
        'ui': container.flroneUi,
      };
    } on Object catch (error) {
      report(error);
      return null;
    }
  }
}

extension TaildropApi on BoxController {
  Future<bool> taildropSubscribe(dynamic endpoint) =>
      act('taildrop.subscribe', {'endpoint': endpoint});
  Future<bool> taildropUnsubscribe() => act('taildrop.unsubscribe');
  Future<bool> taildropCancelReceive(
    dynamic endpoint,
    dynamic name,
    dynamic sender,
  ) => act('taildrop.cancelReceive', {
    'endpoint': endpoint,
    'name': name,
    'sender': sender,
  });
  Future<bool> taildropSave(dynamic endpoint, dynamic name) =>
      act('taildrop.save', {'endpoint': endpoint, 'name': name});
  Future<bool> taildropDelete(dynamic endpoint, dynamic name) =>
      act('taildrop.delete', {'endpoint': endpoint, 'name': name});
  Future<dynamic> taildropSend(dynamic args) => call('taildrop.send', args);
}

extension RemoteApi on BoxController {
  Future<dynamic> remoteList() => call('remote.list');
  Future<bool> remoteDisconnect() => act('remote.disconnect');
  Future<bool> remoteConnect(dynamic id) => act('remote.connect', {'id': id});
  Future<bool> remoteDelete(dynamic id) => act('remote.delete', {'id': id});
  Future<bool> remoteSave(Json value) => act('remote.save', value);
}

extension ConnectionsApi on BoxController {
  Future<bool> connectionsSetVisible(bool visible) =>
      act('connections.visible', {'visible': visible});
  Future<bool> connectionsCloseAll() => act('connections.closeAll');
  Future<bool> connectionsClose(dynamic id) =>
      act('connections.close', {'id': id});
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
}

extension ShareApi on BoxController {
  Future<dynamic> shareText(dynamic content) =>
      call('share.text', {'content': content});
  Future<bool> shareSend(dynamic token, dynamic endpoint, dynamic peer) =>
      act('share.send', {'token': token, 'endpoint': endpoint, 'peer': peer});
  Future<bool> shareDiscard(dynamic token) =>
      act('share.discard', {'token': token});
}

extension ServiceApi on BoxController {
  Future<bool> serviceReload({bool restart = false}) async {
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
          await kernel.connect(timeout: const Duration(seconds: 10));
        } catch (error) {
          report(error);
          return false;
        }
      }
    }
    return _kernelOp(this, kernel.startService);
  }

  Future<bool> serviceStop() async {
    if (kernel.ffiMode) {
      final stopped = await _kernelOp(this, kernel.stopService);
      if (stopped) return true;
      // The service engine may have gone down with a killed process; the
      // platform channel is still the authority for the Android service.
    }
    return act('service.stop');
  }
}

extension CaptureApi on BoxController {
  Future<bool> captureExport(Json args) => act('capture.export', args);
  Future<dynamic> captureSettings() => call('capture.settings');
  Future<dynamic> captureDomains(String query) =>
      call('capture.domains', {'query': query});
  Future<dynamic> captureConfigure(dynamic revision, Json config) =>
      call('capture.configure', {'revision': revision, 'config': config});
}

extension TailscaleApi on BoxController {
  Future<bool> tailscaleStopPing() => act('tailscale.stopPing');
  Future<bool> tailscalePing(dynamic args) => act('tailscale.ping', args);
  Future<bool> tailscaleLogout(dynamic endpoint) =>
      act('tailscale.logout', {'endpoint': endpoint});
  Future<bool> tailscaleExit(dynamic endpoint, dynamic peer) =>
      act('tailscale.exit', {'endpoint': endpoint, 'peer': peer});
}

extension UsbApi on BoxController {
  Future<dynamic> usbList() => call('usb.list');
  Future<bool> usbDetach(dynamic id) => act('usb.detach', {'id': id});
  Future<bool> usbAttach(dynamic server, dynamic device) =>
      act('usb.attach', {'server': server, 'device': device});
}

extension DashboardApi on BoxController {
  Future<bool> dashboardReleaseMemory() => act('dashboard.releaseMemory');
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
      bytes: base64Decode(encoded),
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
    return result.warnings;
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
  Future<dynamic> warpRegister(String tunnelType) => kernel.ffiMode
      ? kernel.warpRegister(tunnelType)
      : call('warp.register', {'tunnelType': tunnelType});
}

extension DiagnosticsApi on BoxController {
  /// One made-up connection walked through the running instance's route rules.
  /// The kernel answers the desktop-shaped `TestRouteResponse`; the page renders
  /// its steps and final outbound. Needs the FFI driver (and a running core).
  Future<dynamic> routeTest(Json request) {
    final attached = kernel.attached;
    if (attached == null) {
      throw StateError('The route test needs the running core; start the VPN first');
    }
    return attached.invoke<Object?>(
      ActionMethod.routeTest,
      data: request,
      timeout: const Duration(seconds: 40),
    );
  }

}
