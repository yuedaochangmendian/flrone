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
  actionVersion,

  // Phase 3c: routing. Go owns the route documents; Kotlin keeps a read-only view.
  //
  // The whole profile surface is here: the list, the editor seed, save, delete,
  // the active-profile marker, batch add, reset, the per-profile rule list and
  // the shared global pool with its per-profile opt-out. Profile CRUD was
  // briefly removed with a routing UI that only added rules to the pool; the
  // rebuilt routing UI edits profiles again, so the methods are back and this
  // enum is the contract `action_contract.py` holds the Go side to.
  getRouteProfiles,
  getRouteProfile,
  saveRouteProfile,
  deleteRouteProfile,
  setCurrentRoute,
  getRouteRules,
  saveRouteRules,
  batchAddRules,
  resetRouteRules,
  getGlobalRules,
  saveGlobalRules,
  setGlobalRuleDisabled,
  deleteGlobalRule,

  // ADR 0005 final stage: the profile data surface left the action bus. Go no
  // longer reads Room's profile/group tables (they stopped being written when
  // Dart became the authority), and the model-bound operations are platform
  // duties now (`profiles.platform` -> FlroneProfileDuty). The nine
  // profileStats/profileNode*/configurationReorder/nodeDelete/profileClear*/
  // autoSelectorSave methods that used to be here are gone with
  // profile_actions.go and autoselector_actions.go.
  //
  // The speed-test metadata and the test-session control plane remain on the
  // bus. The progress feed is still a channel push; the six
  // `speedTestSession*` methods below relay into Kotlin. See
  // speed_test_actions.go and test_session_actions.go.
  speedTestOutbounds,
  groupNodes,

  // ADR 0004 P4a: the test session moves onto the bus with the rest of the
  // control plane. Kotlin still owns the session; Go relays these six methods
  // through platform_request and Dart keeps the same argument/result shapes.
  // The `testSession` progress feed stays a channel push (see the Go handlers).
  speedTestSessionStart,
  speedTestSessionStop,
  speedTestSessionDismiss,
  speedTestSessionSort,
  speedTestSessionRemove,
  speedTestSessionVisible,
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
