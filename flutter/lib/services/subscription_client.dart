// The UI-facing half of the S6 subscription queue (ADR 0008 S6).
//
// Dart port of `SubscriptionClient`: one listener registration turns the
// queue's callbacks into a gid -> state map and an event stream. The shapes
// deliberately match the existing Flutter wire semantics so a future host
// facade can forward them unchanged:
//
//   * `states`       gid -> 1 queued / 2 running (absent = idle), like the
//                    `subscriptionState` channel event's map;
//   * `stateEvents`  every transition, including register-time replay, so a
//                    spinner can span the whole download;
//   * `reports`      `{kind, groupName, title, text}` maps, the
//                    `subscriptionReport` wire shapes for popup/status/error.
//                    A reload hint does not produce a report in the host bridge
//                    (it becomes configChanged/applyRequired), but is exposed
//                    via onReload / a reload-kind event here.
//
// No platform channels, HTTP or document writes: wiring into Box and the host
// bridge is a separate, later slice.

import 'dart:async';

import 'subscription_queue.dart';

/// One subscription event: a change report (popup opens the change window), an
/// error or a status line. `kind` values are the `subscriptionReport` wire
/// kinds; `groupName` is the display name the host would have looked up.
class SubscriptionReportEvent {
  const SubscriptionReportEvent({
    required this.kind,
    required this.gid,
    this.groupName = '',
    this.title = '',
    this.text = '',
    this.popup = false,
    this.error = false,
    this.reload = false,
  });

  /// 'error' / 'popup' / 'status', or 'reload' for a reload hint.
  final String kind;
  final int gid;
  final String groupName;
  final String title;
  final String text;
  final bool popup;
  final bool error;
  final bool reload;

  /// The wire map consumed by BoxController._onEvent's `subscriptionReport`.
  Map<String, dynamic> toWire() {
    switch (kind) {
      case 'error':
        return <String, dynamic>{
          'kind': 'error',
          'groupName': groupName,
          'text': text.isNotEmpty ? text : title,
        };
      case 'popup':
        return <String, dynamic>{
          'kind': 'popup',
          'groupName': groupName,
          'title': title,
          'text': text,
        };
      case 'reload':
        return <String, dynamic>{
          'kind': 'reload',
          'groupName': groupName,
          'text': text,
        };
      default:
        return <String, dynamic>{'kind': 'status', 'text': text};
    }
  }
}

/// One queue state transition, forwarded so a refresh spinner can span the
/// whole download. Maps to the `subscriptionState` wire event.
class SubscriptionStateEvent {
  const SubscriptionStateEvent(this.gid, this.state);

  final int gid;
  final int state;

  Map<String, dynamic> toWire() => <String, dynamic>{'gid': gid, 'state': state};
}

/// Bridges a [SubscriptionQueue] into observable state and report streams.
/// The queue does not know about this class; callers own the registration
/// lifecycle via [attach]/[detach].
class SubscriptionClient {
  SubscriptionClient(this.queue);

  final SubscriptionQueue queue;

  final Map<int, int> _states = <int, int>{};
  final StreamController<SubscriptionReportEvent> _reports =
      StreamController<SubscriptionReportEvent>.broadcast();
  final StreamController<SubscriptionStateEvent> _stateEvents =
      StreamController<SubscriptionStateEvent>.broadcast();

  /// Live queue state: gid -> 1 queued / 2 running, absent = idle. Matches the
  /// map the host pushes in `subscriptionState`.
  Map<int, int> get states => Map<int, int>.unmodifiable(_states);

  Stream<SubscriptionReportEvent> get reports => _reports.stream;
  Stream<SubscriptionStateEvent> get stateEvents => _stateEvents.stream;
  bool get attached => _listener != null;

  /// Resolves group ids to display names for report `groupName` fields. The
  /// default mirrors Kotlin's `GroupRepo.get(gid)?.displayName() ?? ''`.
  String Function(int gid)? groupNameOf;

  /// Called on each state -> idle transition, where Kotlin fires
  /// `GroupRepo.postUpdate` / `postReload`.
  void Function(int gid)? onIdle;

  /// Called for reload hints, which the host turns into configChanged /
  /// applyRequired rather than a subscriptionReport.
  void Function(int gid)? onReload;

  SubscriptionQueueListener? _listener;

  void attach() {
    if (_listener != null) return;
    _listener = _ClientListener(this);
    queue.register(_listener!);
  }

  void detach() {
    final listener = _listener;
    if (listener == null) return;
    _listener = null;
    queue.unregister(listener);
    _states.clear();
  }

  Future<void> close() async {
    detach();
    await _reports.close();
    await _stateEvents.close();
  }

  void _onState(int gid, int state) {
    if (state == SubscriptionQueueStates.idle) {
      _states.remove(gid);
    } else {
      _states[gid] = state;
    }
    if (!_stateEvents.isClosed) {
      _stateEvents.add(SubscriptionStateEvent(gid, state));
    }
    if (state == SubscriptionQueueStates.idle) onIdle?.call(gid);
  }

  void _onReport(int gid, String title, String text, bool popup) {
    if (_reports.isClosed) return;
    _reports.add(
      SubscriptionReportEvent(
        kind: popup ? 'popup' : 'status',
        gid: gid,
        groupName: gid < 0 ? '' : (groupNameOf?.call(gid) ?? ''),
        title: title,
        text: text,
        popup: popup,
      ),
    );
  }

  void _onError(int gid, String message) {
    if (_reports.isClosed) return;
    _reports.add(
      SubscriptionReportEvent(
        kind: 'error',
        gid: gid,
        groupName: gid < 0 ? '' : (groupNameOf?.call(gid) ?? ''),
        text: message,
        error: true,
      ),
    );
  }

  void _onReloadNeeded(int gid) {
    onReload?.call(gid);
    if (_reports.isClosed) return;
    _reports.add(
      SubscriptionReportEvent(
        kind: 'reload',
        gid: gid,
        groupName: gid < 0 ? '' : (groupNameOf?.call(gid) ?? ''),
        reload: true,
      ),
    );
  }
}

class _ClientListener extends SubscriptionQueueListener {
  _ClientListener(this._client);

  final SubscriptionClient _client;

  @override
  void onState(int gid, int state) => _client._onState(gid, state);

  @override
  void onReport(int gid, String title, String text, bool popup) =>
      _client._onReport(gid, title, text, popup);

  @override
  void onError(int gid, String message) => _client._onError(gid, message);

  @override
  void onReloadNeeded(int gid) => _client._onReloadNeeded(gid);
}
