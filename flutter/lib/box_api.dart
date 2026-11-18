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
  // Profile reads that Go answers from the JSON documents (ADR 0002 phase 3d, PR-3).
  // When the FFI driver is attached these go through the action bus; the channel
  // fallback keeps editor screens working before the VPN starts.
  Future<dynamic> profileDecodeIntent(String uri) =>
      call('profiles.decodeIntent', {'uri': uri});
  Future<dynamic> profileAutoSelectorInfo(dynamic id) =>
      call('profiles.autoSelectorInfo', {'id': id});
  Future<dynamic> profileAutoSelectorStatus() =>
      call('profiles.autoSelectorStatus');
  Future<dynamic> profileAutoSelectorPin(dynamic id, dynamic memberId) =>
      call('profiles.autoSelectorPin', {'id': id, 'memberId': memberId});
  Future<dynamic> profileAutoSelectorRecheck() =>
      call('profiles.autoSelectorRecheck', {});
  Future<dynamic> profileAutoSelectorSave(dynamic id, Json value) async {
    final k = kernel.attached;
    if (k != null) {
      final info = await k.invoke<Object?>(
        ActionMethod.autoSelectorSave,
        data: {'id': id, 'value': value},
      );
      // The selector is a profiles row, so the catalog Dart renders is stale
      // until the host re-reads it: Room's invalidation tracker does not see an
      // external writer.
      await _refreshAfterKernelWrite();
      return info;
    }
    return call('profiles.autoSelectorSave', {'id': id, 'value': value});
  }
  Future<dynamic> profileAutoSelectorCreate(dynamic groupId, {String? name}) =>
      call('profiles.autoSelectorCreate', {'groupId': groupId, 'name': ?name});
  Future<dynamic> profileConfig(dynamic id) =>
      call('profiles.config', {'id': id});

  /// Subscription refreshes are network-bound: bounded retry with a per-attempt
  /// timeout keeps a stalled download from hanging the UI indefinitely.
  Future<bool> profileUpdate(dynamic id) async {
    try {
      await retryCall<dynamic>(
        task: () => call('profiles.update', {'id': id}),
        maxAttempts: 2,
        timeout: const Duration(seconds: 60),
      );
      return true;
    } catch (error) {
      report(error);
      return false;
    }
  }

  /// A kernel write to profiles.json/groups.json cannot fire the Kotlin repo
  /// listeners, so the catalog Dart renders would keep the old rows. This asks
  /// the host for one immediate catalog refresh after such a write.
  Future<void> _refreshAfterKernelWrite() async {
    try {
      await call('data.refresh');
    } catch (_) {
      // The write itself succeeded; a failed refresh only delays the redraw.
    }
  }

  Future<dynamic> profileNodeLink(String group, String tag, dynamic nodeJson) =>
      call('profiles.nodeLink', {'group': group, 'tag': tag, 'json': nodeJson});
  Future<dynamic> profileNodeDelete(dynamic id) async {
    final k = kernel.attached;
    if (k != null) {
      final result = await k.invoke<Object?>(ActionMethod.profileNodeDelete, data: {'id': id});
      await _refreshAfterKernelWrite();
      return result;
    }
    return call('profiles.nodeDelete', {'id': id});
  }
  Future<dynamic> profileNodeConfig(dynamic id) async {
    final k = kernel.attached;
    if (k == null) return call('profiles.nodeConfig', {'id': id});
    try {
      return await k.invoke<Object?>(ActionMethod.profileNodeConfig, data: {'id': id});
    } catch (_) {
      // The kernel reads Room directly, so a missing database file, a WAL lock or a
      // decode defect fails the read outright; the channel reads the same rows through
      // ProfileManager. Reads only: a failed write must surface, not be re-applied.
      return call('profiles.nodeConfig', {'id': id});
    }
  }
  Future<dynamic> profileNodeUpdate(dynamic id, String name, String content) =>
      call('profiles.nodeUpdate', {'id': id, 'name': name, 'content': content});
  Future<dynamic> profileNodeTuningInfo(dynamic id) async {
    final k = kernel.attached;
    if (k == null) return call('profiles.nodeTuningInfo', {'id': id});
    try {
      return await k.invoke<Object?>(ActionMethod.profileNodeTuningInfo, data: {'id': id});
    } catch (_) {
      // Same read-only fallback as profileNodeConfig: the channel answers from
      // ProfileManager when the kernel cannot reach Room.
      return call('profiles.nodeTuningInfo', {'id': id});
    }
  }
  Future<dynamic> profileNodeTuningSave(dynamic id, Json value) =>
      call('profiles.nodeTuningSave', {'id': id, 'value': value});
  Future<dynamic> profileRead(dynamic id) => call('profiles.read', {'id': id});
  Future<bool> profileClearTestResults(dynamic id) async {
    final k = kernel.attached;
    if (k != null) {
      await k.invoke<Object?>(ActionMethod.profileClearTestResults, data: {'id': id});
      await _refreshAfterKernelWrite();
      return true;
    }
    return act('profiles.clearTestResults', {'id': id});
  }
  Future<bool> profileClearTraffic(dynamic id) async {
    final k = kernel.attached;
    if (k != null) {
      await k.invoke<Object?>(ActionMethod.profileClearTraffic, data: {'id': id});
      await _refreshAfterKernelWrite();
      return true;
    }
    return act('profiles.clearTraffic', {'id': id});
  }
  Future<bool> profileDelete(dynamic id) => act('profiles.delete', {'id': id});
  Future<bool> profileSwitchRelative(int step) async {
    if (kernel.ffiMode) {
      final done = await act('profiles.switchRelative', {'step': step});
      if (done) await kernel.onSelectionChanged();
      return done;
    }
    return act('profiles.switchRelative', {'step': step});
  }

  Future<bool> profileSelect(dynamic id) async {
    if (kernel.ffiMode) {
      final done = await act('profiles.select', {'id': id});
      if (done) await kernel.onSelectionChanged();
      return done;
    }
    return act('profiles.select', {'id': id});
  }

  Future<dynamic> profileImportFile() => call('profiles.importFile');
  Future<dynamic> profileCreateNode(dynamic groupId, dynamic type) =>
      call('profiles.createNode', {'groupId': groupId, 'type': type});
  Future<dynamic> profileNodeCreate(Json value) =>
      call('profiles.nodeCreate', value);
  Future<dynamic> profileSave(Json value) => call('profiles.save', value);
  Future<bool> profileReorder(List<dynamic> ids) async {
    final k = kernel.attached;
    if (k != null) {
      await k.invoke<Object?>(ActionMethod.profileReorder, data: {'ids': ids});
      await _refreshAfterKernelWrite();
      return true;
    }
    return act('profiles.reorder', {'ids': ids});
  }
  Future<bool> profileScanClose(dynamic session) =>
      act('profiles.scan.close', {'session': session});
  Future<dynamic> profileScan(dynamic session, String text) =>
      call('profiles.scan', {'session': session, 'text': text});
  Future<dynamic> profileWrite(dynamic id, String content, dynamic revision) =>
      call('profiles.write', {
        'id': id,
        'content': content,
        'revision': revision,
      });

  /// Validated, rollback-protected config edit. Checks the JSON before it can
  /// reach the core, keeps the previous content, and restores it if the bridge
  /// rejects the write (Bettbox's patch-then-validate / prevProfileId pattern).
  Future<dynamic> profileWriteGuarded(
    dynamic id,
    String content,
    dynamic revision,
  ) => guardedConfigWrite<dynamic>(
    readPrevious: () async {
      final value = json(await profileRead(id));
      final current = value['content'] ?? value['config'] ?? value['text'];
      return current is String ? current : '';
    },
    commit: (checked) => profileWrite(id, checked, revision),
    restore: (previous) => profileWrite(id, previous, revision),
    candidate: content,
  );
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
  ThroneKernel _routeKernel() =>
      kernel.attached ??
      (throw StateError(
        'the route store needs the FFI driver; start the VPN first',
      ));

  /// The three route READS degrade to the channel, exactly as the data plane
  /// does: the kernel may be absent (no FFI driver) or its Room read may fail,
  /// and a screen that shows the profile list or the pooled rules should not go
  /// dark for that. The Kotlin `routes.list` arm reads the same documents
  /// through `RouteManager`; the rule reads still have no channel arm, so a
  /// failed kernel read there surfaces a friendly message instead of the raw
  /// Go error. Writes below never degrade — masking a failed write would risk
  /// double-applying or hiding data loss.
  Future<dynamic> routeList() async {
    try {
      return await _routeKernel().invoke<Object?>(
        ActionMethod.getRouteProfiles,
      );
    } catch (_) {
      // No FFI driver, or its Room read failed; the channel arm answers the
      // same documents through RouteManager.
      return call('routes.list');
    }
  }

  /// One profile's metadata and its simple-rule text, the editor's seed. `id`
  /// 0 answers an empty seed for a new profile.
  ///
  /// This read has no channel fallback: `routes.list` is the only route read the
  /// host answers, so a missing FFI driver surfaces the kernel error rather than
  /// a second, differently-shaped answer.
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

  Future<dynamic> routeRuleSets(String query, int limit) =>
      call('routes.ruleSets', {'query': query, 'limit': limit});

  Future<dynamic> routeGlobalRules(dynamic profileId) => _routeKernel()
      .invoke<Object?>(ActionMethod.getGlobalRules, data: {'profileId': profileId});

  Future<dynamic> routeSaveGlobalRules(dynamic rules) =>
      _routeKernel().invoke<Object?>(ActionMethod.saveGlobalRules, data: {'rules': rules});

  Future<dynamic> routeDeleteGlobalRule(dynamic id) =>
      _routeKernel().invoke<Object?>(ActionMethod.deleteGlobalRule, data: {'id': id});
}

// Settings stay on the channel (ADR 0002, amended). Room is the authoritative
// store for `ThroneSettings`, and preferences live in SharedPreferences; Go's
// JSON documents hold neither. A bus-first arm here silently swallowed every
// write once the FFI driver attached, so this domain is channel-only.
extension SettingsApi on BoxController {
  Future<dynamic> settingsGet() => call('settings.get', {});

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

  /// Seeds the kernel's route documents from Room (ADR 0002, phase 3c).
  ///
  /// The kernel is the only writer once the documents exist, so the host answers
  /// `{"seeded": false}` and does nothing when they are already there. Called once
  /// per attach: the kernel cannot seed itself, because Room is Android-only.
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

  Future<dynamic> groupTestSessionStart(Json args) =>
      call('groups.testSession.start', args);
  Future<bool> groupTestSessionStartChecked(Json args) =>
      act('groups.testSession.start', args);
  Future<bool> groupTestSessionStop() => act('groups.testSession.stop');
  Future<bool> groupTestSessionSort(dynamic groupId) =>
      act('groups.testSession.sort', {'groupId': groupId});
  Future<dynamic> groupTestSessionRemove(List<dynamic> ids) =>
      call('groups.testSession.remove', {'ids': ids});
  Future<bool> groupTestSessionDismiss() => act('groups.testSession.dismiss');
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
  Future<dynamic> webdavGet() => call('webdav.get');
  Future<dynamic> webdavCheck() => call('webdav.check');
  Future<dynamic> webdavSet(dynamic value) =>
      call('webdav.set', {'value': value});
  Future<dynamic> webdavUpload() => call('webdav.upload');
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
  Future<List<Json>> groupNodes() async =>
      rows(json(await call('groups.nodes'))['nodes']);
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
  Future<bool> appsPermission() => act('apps.permission');
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
    if (kernel.ffiMode) return _kernelOp(this, kernel.startService);
    return act('service.start');
  }

  Future<bool> serviceStop() async {
    if (kernel.ffiMode) return _kernelOp(this, kernel.stopService);
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
  Future<dynamic> backupCreate() => call('backup.create');
  Future<dynamic> backupRestore(
    dynamic backup,
    dynamic scope,
    dynamic strategy,
  ) => call('backup.restore', {
    'backup': backup,
    'scope': scope,
    'strategy': strategy,
  });
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
