// The service-engine subscription queue (ADR 0008 S6 production wiring).
//
// This is the production half of `subscription_queue.dart`: it owns one queue
// and one client inside the engine that also owns `documents/profiles.json`,
// turns state transitions and reports into the existing `subscriptionState` /
// `subscriptionReport` wire events, and gives the host one narrow command
// surface. The actual download/parse/diff/apply work stays in
// `subscription_refresh.dart` and is injected as a runner, so this file has no
// HTTP or document code of its own.
//
// The UI never talks to this class directly: `ServiceBridge` forwards
// `subscription.refresh` / `subscription.refreshAll` / `subscription.awaitIdle`
// to the service engine, and the service engine forwards the emitted events to
// the UI's `KernelProxy` event stream.

import 'subscription_client.dart';
import 'subscription_queue.dart';
import 'subscription_refresh.dart';

/// One subscription group the queue can refresh. Kept tiny so the engine does
/// not import the document store; the service entry maps ConfigurationRow to
/// this shape.
class SubscriptionGroupRef {
  const SubscriptionGroupRef({
    required this.id,
    required this.name,
    required this.url,
    this.archive = false,
    this.skipAutoUpdate = false,
  });

  final int id;
  final String name;
  final String url;
  final bool archive;
  final bool skipAutoUpdate;
}

/// Runs one refresh through the document gateway and parser.
typedef SubscriptionRefreshRunner = Future<SubscriptionRefreshResult> Function(
  int gid,
  SubscriptionRefreshSurface surface,
);

/// Lists the current subscription groups (the queue's refreshAll source).
typedef SubscriptionGroupLister = Future<List<SubscriptionGroupRef>> Function();

/// Emits one wire event: `type` is `subscriptionState`/`subscriptionReport`.
typedef SubscriptionEventEmitter = void Function(
  String type,
  Map<String, dynamic> value,
);

class SubscriptionEngine {
  SubscriptionEngine({
    required this.runRefresh,
    required this.listGroups,
    required this.emit,
    this.onGroupChanged,
    this.onForegroundAcquire,
    this.onForegroundRelease,
  });

  final SubscriptionRefreshRunner runRefresh;
  final SubscriptionGroupLister listGroups;
  final SubscriptionEventEmitter emit;

  /// Auto-selector / catalog follow-up for a successful refresh. Kept as a
  /// callback because the service engine owns the host bridge.
  final Future<void> Function(int gid, List<int> disturbed)? onGroupChanged;

  /// Foreground-service promotion/de-promotion, supplied by the service entry
  /// through the Kotlin `subscription.foreground` host call. Only foreground
  /// jobs (manual updates) request it; background polls do not.
  final void Function()? onForegroundAcquire;
  final void Function()? onForegroundRelease;

  late final SubscriptionQueue queue = SubscriptionQueue(
    onForegroundAcquire: onForegroundAcquire,
    onForegroundRelease: onForegroundRelease,
  );
  late final SubscriptionClient client = SubscriptionClient(queue);

  final Map<int, String> _names = <int, String>{};
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    client
      ..groupNameOf = ((gid) => _names[gid] ?? '')
      ..attach();
    client.stateEvents.listen((event) {
      emit('subscriptionState', event.toWire());
    });
    client.reports.listen((report) {
      emit('subscriptionReport', report.toWire());
    });
  }

  /// Enqueues one group. Returns false when that gid is already queued/running
  /// (the per-gid dedupe) or the group is not a live subscription.
  Future<bool> refresh(
    int gid, {
    bool showDiff = true,
    bool foreground = true,
  }) async {
    final group = (await listGroups()).where((entry) => entry.id == gid).firstOrNull;
    if (group == null || group.archive || group.url.trim().isEmpty) return false;
    _names[gid] = group.name;
    return queue.refreshGroup(
      gid,
      title: group.name,
      foreground: foreground,
      task: () => _runGroup(
        gid,
        showDiff ? SubscriptionRefreshSurface.diff : SubscriptionRefreshSurface.log,
      ),
    );
  }

  /// Enqueues every non-archived subscription. [onlyAllowed] mirrors the
  /// automatic-update filter (skip groups whose auto update is off).
  Future<bool> refreshAll({
    bool onlyAllowed = false,
    bool foreground = true,
  }) async {
    final groups = (await listGroups())
        .where((group) =>
            !group.archive &&
            group.url.trim().isNotEmpty &&
            (!onlyAllowed || !group.skipAutoUpdate))
        .toList();
    for (final group in groups) {
      _names[group.id] = group.name;
    }
    return queue.refreshAll(
      groups.map((group) => group.id),
      foreground: foreground,
      title: (gid) => _names[gid] ?? '',
      task: (gid) => _runGroup(gid, SubscriptionRefreshSurface.log),
    );
  }

  /// Enqueues exactly the [gids] the host decided are due (S6 automatic poll),
  /// then waits for the queue to go idle so the WorkManager job only completes
  /// once every refresh has been applied.
  ///
  /// Eligibility mirrors [refresh] (a live, non-archived subscription): the
  /// scheduler already applied its own interval/skip rules when it produced the
  /// ids. Per-gid dedupe is the queue's own, so a gid already queued by a manual
  /// update is not run twice; [awaitIdle] still spans that in-flight job. Run
  /// in the log surface (no diff popup) because a poll is background work.
  Future<void> refreshMany(
    Iterable<int> gids, {
    bool foreground = false,
  }) async {
    final byId = <int, SubscriptionGroupRef>{
      for (final group in await listGroups()) group.id: group,
    };
    for (final gid in gids.toSet()) {
      final group = byId[gid];
      if (group == null || group.archive || group.url.trim().isEmpty) continue;
      _names[gid] = group.name;
      queue.refreshGroup(
        gid,
        title: group.name,
        foreground: foreground,
        task: () => _runGroup(gid, SubscriptionRefreshSurface.log),
      );
    }
    await queue.awaitIdle();
  }

  Future<void> awaitIdle() => queue.awaitIdle();

  String groupNameOf(int gid) => _names[gid] ?? '';

  int get queuedLength => queue.queuedLength;
  Set<int> get pendingGids => queue.pendingGids;

  Future<void> _runGroup(int gid, SubscriptionRefreshSurface surface) async {
    try {
      final result = await runRefresh(gid, surface);
      if (result.applied && onGroupChanged != null) {
        await onGroupChanged!(gid, result.storedIds);
      }
    } catch (error) {
      queue.emitError(gid, '$error');
    }
  }

  Future<void> dispose() async {
    client.detach();
    queue.dispose();
    await client.close();
  }
}
