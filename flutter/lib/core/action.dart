// The Bettbox-style JSON action protocol (ADR 0002, phase 1).
//
// Dart talks to the kernel through one C entry point (`throne_invoke_action`),
// sending an Action and receiving an ActionResult whose id echoes the request.
// The typed `throne_*` exports remain as the Go handlers' implementation.
//
// There is deliberately no freezed/build_runner here: the wire shapes are tiny,
// and one hand-written codec is easier for action_contract.py to audit than a
// generated enum map. That script checks this enum against the Go Method
// constants and the dispatcher registry by wire string.

import 'dart:convert';

/// One request method. The member's name IS the wire string; do not add a
/// separate map. `tools/diagnostics/action_contract.py` enforces that each
/// member has a Go Method constant and a registered handler.
enum ActionMethod {
  /// Manual diagnostics only — no production Dart caller; kept as a debug/smoke surface.
  actionVersion,

  // Routing: Go owns the one global rule table, `global_route_rules.json`, and
  // is its only writer. The profile CRUD, per-profile rule sets, current-route
  // marker and the per-profile pool opt-out are gone with the multi-profile UI:
  // there is a single ordered rule list, addressed as a whole. Profile CRUD
  // was once restored after being removed — this time the UI and Go delete it
  // in the same round, so no caller can reach a method the kernel no longer has.
  // `saveGlobalRules` and `deleteGlobalRule` stay for compatibility/backup; the
  // editor commits through the patch path so one edit no longer ships the whole
  // table. `action_contract.py` holds the Go side to exactly this set.
  getGlobalRules,
  saveGlobalRules,
  deleteGlobalRule,
  saveGlobalRulesPatch,

  // ADR 0005 final stage: the profile data surface left the action bus. Go no
  // longer reads Room's profile/group tables (they stopped being written when
  // Dart became the authority), and the model-bound operations are platform
  // duties now (`profiles.platform` -> FlroneProfileDuty). The nine
  // profileStats/profileNode*/configurationReorder/nodeDelete/profileClear*/
  // autoSelectorSave methods that used to be here are gone with
  // profile_actions.go and autoselector_actions.go.
  //
  // The speed-test metadata and the test-session control plane remain on the
  // bus. The progress feed is still a channel push; the five
  // `speedTestSession*` methods below relay into Kotlin. See
  // speed_test_actions.go and test_session_actions.go.
  speedTestOutbounds,
  groupNodes,

  // The profile editor's document codec (profile_codec_actions.go). These are
  // pure functions over one sing-box outbound string: they parse and re-emit it
  // through the *pinned core's* own option types (`option.Outbound` and the
  // concrete option structs), so the kernel's parser is the validator and no
  // second protocol model enters the tree. `profileValidate` answers
  // `{ok, issues:[{field,message,severity}], normalized?}` and rewrites the
  // caller's string nowhere but `normalized`; `profileNormalize` emits the
  // canonical compact document (deterministic for one core pin, not byte-stable
  // across a bump); `profileNewOutbound` seeds the new-node form for
  // direct/http/socks only — a shadowsocks or VMess template would have to
  // invent a security default. No UI caller yet: Kotlin keeps the editor until
  // the editor itself moves over.
  profileValidate,
  profileNormalize,
  profileNewOutbound,

  // The stored-form exporter's first slice (profile_export_simple.go): direct,
  // http, socks and shadowsocks only, answering `supported:false` for every
  // document that needs TLS/transport/multiplex so the caller can fall back to
  // the Kotlin exporter. No UI caller yet.
  profileExport,

  // The share-link importer's first slice (profile_import_*.go): one link in,
  // one stored node out for http/socks/shadowsocks without TLS/transport/
  // multiplex. A refusal answers supported:false with a reason and no nodes,
  // so the caller can fall back to Kotlin without a half-imported node.
  // No UI caller yet; corpus/import orchestration comes later.
  profileImport,

  // The proxies screen's in-place selector switch (groups_actions.go): the
  // running core's outbound manager flips the selector, no HTTP and no Clash
  // API. The reply is a typed status (`switched` / `not-found` /
  // `not-a-selector` / `not-running`), not a bool: every status but `switched`
  // means the running config cannot express the tap in place, so the caller
  // keeps the persistence + reload path. The payload is
  // `{group, tag, nodeId?}` with the display names the catalog already has.
  groupsSelect,

  // Config generation on the Go side (config_build_actions.go). This is the
  // production start path: config.prepare performs the Android-side writes,
  // then KernelService invokes this action and hands its reply to
  // createInstance. The reply is {coreConfig, deferRuleSets,
  // involvedProfileIds}; the Kotlin generator no longer exists.
  configBuild,

  // ADR 0004 P4a: the test session moves onto the bus with the rest of the
  // control plane. Kotlin still owns the session; Go relays these five methods
  // through platform_request and Dart keeps the same argument/result shapes.
  // The `testSession` progress feed stays a channel push (see the Go handlers).
  // `visible` is not here: it is the UI feed's demand signal, which stays on
  // the channel so it works without a core (see SpeedTestApi).
  speedTestSessionStart,
  speedTestSessionStop,
  speedTestSessionDismiss,
  speedTestSessionSort,
  speedTestSessionRemove,

  // Phase 0/2: debug-gated pprof capture. Inert unless a developer creates the
  // profile.enable marker inside the app's files dir via adb; the Go handler
  // rejects every call otherwise. Payload:
  //   {kind: 'cpu'|'heap'|'goroutine'|'allocs'|'block', seconds: N, dir: String}
  // where dir is the app-private files dir. See profile_actions.go.
  /// Manual diagnostics only — no production Dart caller; its Go handler stays for pprof smoke tests.
  diagnosticsProfile,

  // Bridge performance controls (performance_actions.go); wire names are pinned
  // by action_contract.py.
  setScreenOff,
  setDoze,

  // OpenVPN/OpenConnect sign-in challenges (vpn_auth_actions.go). The status
  // read and the submit/cancel writes are Dart-driven; status *changes* arrive
  // as `vpnStatus` message-port pushes, not as invokes. See box_api.dart.
  vpnStatus,
  submitVPNChallenge,
  cancelVPNChallenge,
  vpnWatchStatus,

  // Kernel memory accounting + Go runtime control (parallel Go-side work).
  // `runtimeMemory` works with no running instance; forceGC/setLogStream are
  // process-wide. Wire names are the member names — see action_contract.py.
  runtimeMemory,
  forceGC,
  setLogStream,

  // The core's connection feed. `connectionsWatch` is the demand signal for
  // the page's rows and the traffic ledger's attribution; the close controls
  // replace the old loopback Clash API calls. Rows and deltas arrive as
  // `connections` / `trafficDeltas` pushes, not as action replies.
  // See connections_actions.go and connections_feed.go.
  connectionsWatch,
  connectionsClose,
  connectionsCloseAll,

}

/// `message` is the tag of an unsolicited Go->Dart push. It never appears in
/// [ActionMethod] because it has no handler and cannot be invoked.
const actionPushMethod = 'message';

class Action {
  const Action({required this.id, required this.method, this.data});

  final String id;
  final ActionMethod method;
  final Object? data;

  String encode() => jsonEncode({
    'id': id,
    'method': method.name,
    if (data != null) 'data': data,
  });

  /// Decodes an Action wire before a caller registers a pending Completer.
  ///
  /// A malformed wire can never produce a correlated reply (the Go bridge
  /// rejects it and posts an id-less error), so detecting it locally turns a
  /// silent hard-coded-timeout hang into an immediate [FormatException]. The
  /// `method` must also be a known [ActionMethod]: the Go dispatcher would
  /// answer "unknown action method" with an id, but there is no reason to
  /// spend a round trip finding that out.
  static ({String id, String method}) decodeRequest(String wire) {
    final decoded = jsonDecode(wire);
    if (decoded is! Map) {
      throw const FormatException('action wire is not an object');
    }
    final id = decoded['id'];
    final method = decoded['method'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('action wire has no id');
    }
    if (method is! String || method.isEmpty) {
      throw const FormatException('action wire has no method');
    }
    // Only a recognised method can have a handler on the Go side; rejecting
    // unknown ones here keeps the wire contract and action_contract.py in step.
    ActionMethod.values.byName(method); // throws ArgumentError when unknown
    return (id: id, method: method);
  }
}

class ActionResult {
  const ActionResult({
    required this.id,
    required this.method,
    required this.code,
    this.data,
  });

  /// Empty for a push, or for a malformed action the kernel could not parse.
  final String id;
  final String method;
  final int code;
  final Object? data;

  bool get isError => code != 0;

  static ActionResult? decode(Object? raw) {
    if (raw is! String) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      // A push event uses {"method","data"} with no id and no code. An action
      // result uses {"id","method","data","code"}. A message carrying an id but
      // no code is a truncated result: treat it as an error rather than
      // dropping it, so its pending Completer is never left hanging.
      final id = '${decoded['id'] ?? ''}';
      if (!decoded.containsKey('code') && id.isEmpty) return null;
      return ActionResult(
        id: id,
        method: '${decoded['method'] ?? ''}',
        code: (decoded['code'] as num?)?.toInt() ?? -1,
        data: decoded['data'],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Thrown when the kernel answers an action with a non-zero code.
class ActionException implements Exception {
  const ActionException(this.method, this.message, {this.timedOut = false});

  final String method;
  final String message;

  /// The kernel never answered within the caller's budget, as opposed to answering an error.
  /// The IPC envelope names this timeout `unanswered` so a control call stays optimistic.
  final bool timedOut;

  @override
  String toString() => 'ActionException($method): $message';
}
