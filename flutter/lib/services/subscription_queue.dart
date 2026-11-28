// The in-process subscription queue (ADR 0008 S6).
//
// Dart port of Kotlin's `SubscriptionQueue` and the listener half of
// `SubscriptionClient`. Jobs run one at a time, FIFO; a group is queued at most
// once; a batch refuses to start while a previous batch is in flight. The real
// work is injected (`Future<void> Function(SubscriptionJob)`), so this file has
// no HTTP, platform bridges or document writes. A future host facade can map
// the callbacks onto the existing `subscriptionState` (gid -> 1 queued /
// 2 running) and `subscriptionReport` (error/popup/status) wire events.
//
// Dart's event loop gives the same atomicity Kotlin gets from its lock: none of
// the critical sections below await, so no callback sees a half-updated queue.
// Listener delivery is synchronous over a snapshot, matching CopyOnWriteArrayList
// and keeping state/report ordering deterministic.

import 'dart:async';
import 'dart:collection';

/// Forwarded queue states. Absent from a gid -> state map means idle.
abstract final class SubscriptionQueueStates {
  static const int idle = 0;
  static const int queued = 1;
  static const int running = 2;
}

/// Gid for jobs not tied to a group (URL-test follow-up) and batch-wide errors.
const int subscriptionNoGid = -1;

/// One unit of work handed to the injected runner.
class SubscriptionJob {
  const SubscriptionJob({
    required this.gid,
    required this.task,
    this.title = '',
    this.foreground = true,
    this.batch = false,
  });

  /// The subscription group id, or [subscriptionNoGid] for a group-less job.
  final int gid;

  /// Human-readable group name, carried for reports and diagnostics.
  final String title;

  /// Whether a foreground hold is requested (acquire/release are injected so
  /// tests can count them without touching a platform service).
  final bool foreground;

  /// Whether this job was enqueued as part of a batch.
  final bool batch;

  /// The group-specific work. The injected runner calls this (the default
  /// runner does); tests can substitute the whole runner.
  final Future<void> Function() task;

  SubscriptionJob copyWith({
    int? gid,
    String? title,
    bool? foreground,
    bool? batch,
    Future<void> Function()? task,
  }) {
    return SubscriptionJob(
      gid: gid ?? this.gid,
      title: title ?? this.title,
      foreground: foreground ?? this.foreground,
      batch: batch ?? this.batch,
      task: task ?? this.task,
    );
  }
}

/// The in-process event sink, replacing the old oneway AIDL callback registry.
abstract class SubscriptionQueueListener {
  const SubscriptionQueueListener();

  /// [state] is one of [SubscriptionQueueStates.idle/queued/running].
  void onState(int gid, int state) {}
  void onReport(int gid, String title, String text, bool popup) {}
  void onError(int gid, String message) {}
  /// A refresh re-pointed a route reference the running config was built from.
  void onReloadNeeded(int gid) {}
}

/// `GroupRepo.postUpdate`/`postReload` equivalent: profiles were deleted or
/// changed in place and auto selectors must re-plan.
typedef GroupChangedListener = void Function(int gid, List<int> disturbed);

/// The in-process subscription job queue.
class SubscriptionQueue {
  SubscriptionQueue({
    Future<void> Function(SubscriptionJob)? runner,
    void Function()? onForegroundAcquire,
    void Function()? onForegroundRelease,
    void Function(Object error, StackTrace stack)? onListenerError,
  }) : _runner = runner ?? _defaultRunner,
       _onForegroundAcquire = onForegroundAcquire,
       _onForegroundRelease = onForegroundRelease,
       _onListenerError = onListenerError;

  static Future<void> _defaultRunner(SubscriptionJob job) => job.task();

  final Future<void> Function(SubscriptionJob) _runner;
  final void Function()? _onForegroundAcquire;
  final void Function()? _onForegroundRelease;
  final void Function(Object error, StackTrace stack)? _onListenerError;

  final Queue<SubscriptionJob> _queue = Queue<SubscriptionJob>();
  final Set<int> _pending = <int>{};
  final List<SubscriptionQueueListener> _listeners = <SubscriptionQueueListener>[];
  final List<GroupChangedListener> _groupChangedListeners = <GroupChangedListener>[];
  final List<Completer<void>> _idleWaiters = <Completer<void>>[];

  int _pendingBatch = 0;
  bool _draining = false;
  int _runningGid = subscriptionNoGid;
  int _outstanding = 0;
  bool _disposed = false;

  // ------------------------------------------------------------------ introspection

  bool get isDisposed => _disposed;
  bool get isIdle => _outstanding == 0;
  bool get isDraining => _draining;
  int get runningGid => _runningGid;
  int get outstanding => _outstanding;
  Set<int> get pendingGids => Set<int>.unmodifiable(_pending);
  int get pendingBatch => _pendingBatch;
  int get queuedLength => _queue.length;

  // ------------------------------------------------------------------ callbacks

  /// Registers a listener and replays the current state of every pending group.
  /// Replaying in the same atomic section as state changes means a listener can
  /// never see a replayed state after a newer transition, or vice versa.
  void register(SubscriptionQueueListener listener) {
    if (_disposed || _listeners.contains(listener)) return;
    _listeners.add(listener);
    final replay = <MapEntry<int, int>>[
      for (final gid in _pending)
        MapEntry<int, int>(
          gid,
          gid == _runningGid
              ? SubscriptionQueueStates.running
              : SubscriptionQueueStates.queued,
        ),
    ];
    for (final entry in replay) {
      _deliver((l) => l.onState(entry.key, entry.value), listener);
    }
  }

  void unregister(SubscriptionQueueListener listener) {
    _listeners.remove(listener);
  }

  void addGroupChangedListener(GroupChangedListener listener) {
    if (_disposed || _groupChangedListeners.contains(listener)) return;
    _groupChangedListeners.add(listener);
  }

  /// Dispatch to all listeners; one throwing listener must not silence the rest.
  void _broadcast(void Function(SubscriptionQueueListener) action) {
    for (final listener in List<SubscriptionQueueListener>.of(_listeners)) {
      _deliver(action, listener);
    }
  }

  void _deliver(
    void Function(SubscriptionQueueListener) action,
    SubscriptionQueueListener listener,
  ) {
    try {
      action(listener);
    } catch (error, stack) {
      _onListenerError?.call(error, stack);
    }
  }

  void _stateLocked(int gid, int state) =>
      _broadcast((l) => l.onState(gid, state));

  /// A change report. [popup] asks a host facade to open the change window.
  void report(int gid, String title, String text, bool popup) =>
      _broadcast((l) => l.onReport(gid, title, text, popup));

  /// A task or request failure. gid -1 means no single group.
  void emitError(int gid, String message) =>
      _broadcast((l) => l.onError(gid, message));

  /// A refresh re-pointed something the running config resolves.
  void reloadNeeded(int gid) => _broadcast((l) => l.onReloadNeeded(gid));

  void groupChanged(int gid, List<int> disturbed) {
    for (final listener in List<GroupChangedListener>.of(_groupChangedListeners)) {
      try {
        listener(gid, disturbed);
      } catch (error, stack) {
        _onListenerError?.call(error, stack);
      }
    }
  }

  // ------------------------------------------------------------------ entry points

  /// Refreshes one group. Returns false when the gid is already queued or
  /// running (the per-gid dedupe), mirroring `SubscriptionQueue.refreshGroup`.
  bool refreshGroup(
    int gid, {
    String title = '',
    bool foreground = true,
    Future<void> Function()? task,
  }) {
    if (_disposed || _pending.contains(gid)) return false;
    _pending.add(gid);
    _enqueueLocked(
      SubscriptionJob(
        gid: gid,
        title: title,
        foreground: foreground,
        task: task ?? _noop,
      ),
    );
    return true;
  }

  /// Refreshes every group in [gids]. The whole batch is refused while another
  /// batch is in flight; a refused foreground batch also emits an error event
  /// with gid -1 so the UI can explain why nothing was enqueued.
  ///
  /// Gids already pending (or repeated inside [gids]) are skipped, matching
  /// Kotlin's `pending` check. Returns false only when the batch was refused.
  bool refreshAll(
    Iterable<int> gids, {
    bool foreground = true,
    String Function(int gid)? title,
    Future<void> Function(int gid)? task,
  }) {
    if (_disposed) return false;
    if (_pendingBatch > 0) {
      if (foreground) emitError(subscriptionNoGid, 'Batch refresh already running');
      return false;
    }
    for (final gid in gids) {
      if (_pending.contains(gid)) continue;
      _pending.add(gid);
      _pendingBatch++;
      final name = title?.call(gid) ?? '';
      _enqueueLocked(
        SubscriptionJob(
          gid: gid,
          title: name,
          foreground: foreground,
          batch: true,
          task: task == null ? _noop : () => task(gid),
        ),
      );
    }
    return true;
  }

  /// Mirrors `requestUrlTest`: the URL test holds an outstanding slot so
  /// [awaitIdle] spans it, then its follow-up goes back through the queue as a
  /// group-less job (never racing another job over the same group).
  void requestUrlTest(
    int gid, {
    Future<void> Function()? urlTest,
    Future<void> Function()? followUp,
  }) {
    if (_disposed) return;
    // Hold the test slot until the follow-up is enqueued, so awaitIdle never
    // observes a zero gap between the two phases.
    _changeOutstanding(1);
    _runUrlTest(urlTest ?? _noop, followUp ?? _noop);
  }

  Future<void> _runUrlTest(
    Future<void> Function() urlTest,
    Future<void> Function() followUp,
  ) async {
    try {
      try {
        await urlTest();
      } catch (error, stack) {
        // A failed test must not cancel the follow-up.
        _onListenerError?.call(error, stack);
      }
      if (_disposed) return;
      // Enqueue the follow-up *before* releasing the test slot: the counter
      // never dips to zero between the two phases, so awaitIdle spans both.
      _enqueueLocked(
        SubscriptionJob(
          gid: subscriptionNoGid,
          foreground: false,
          task: followUp,
        ),
      );
    } finally {
      _changeOutstanding(-1); // release the test slot from requestUrlTest
    }
  }

  /// Completes when no job is queued or running and no URL-test follow-up is
  /// outstanding. Repeated calls are safe.
  Future<void> awaitIdle() {
    if (_outstanding == 0) return Future<void>.value();
    final completer = Completer<void>();
    _idleWaiters.add(completer);
    return completer.future;
  }

  /// Stops event delivery and resolves idle waiters. In-flight runner futures
  /// are owned by the injected runner and are not cancelled here.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _listeners.clear();
    _groupChangedListeners.clear();
    _settleIdleWaiters();
  }

  // ------------------------------------------------------------------ worker

  void _enqueueLocked(SubscriptionJob job) {
    _queue.addLast(job);
    _changeOutstanding(1);
    if (job.foreground) _onForegroundAcquire?.call();
    if (job.gid >= 0) _stateLocked(job.gid, SubscriptionQueueStates.queued);
    if (_draining) return;
    _draining = true;
    // Runs synchronously up to the first await, so "running" is emitted before
    // the caller can enqueue the next job: queued -> running -> idle per job.
    _drain();
  }

  Future<void> _drain() async {
    while (true) {
      final job = _takeNextLocked();
      if (job == null) return;
      try {
        await _runner(job);
      } catch (taskError, stack) {
        // Anything thrown here would otherwise take the whole service down.
        if (job.foreground) {
          emitError(job.gid, 'Subscription task failed: $taskError');
          _onListenerError?.call(taskError, stack);
        }
      } finally {
        _finishLocked(job);
      }
    }
  }

  SubscriptionJob? _takeNextLocked() {
    final job = _queue.isEmpty ? null : _queue.removeFirst();
    if (job == null) {
      _draining = false;
      return null;
    }
    if (job.gid >= 0) {
      _runningGid = job.gid;
      _stateLocked(job.gid, SubscriptionQueueStates.running);
    }
    return job;
  }

  void _finishLocked(SubscriptionJob job) {
    if (job.gid >= 0) {
      _runningGid = subscriptionNoGid;
      _pending.remove(job.gid);
      _stateLocked(job.gid, SubscriptionQueueStates.idle);
    }
    if (job.batch && _pendingBatch > 0) _pendingBatch--;
    if (job.foreground) _onForegroundRelease?.call();
    _changeOutstanding(-1);
  }

  void _changeOutstanding(int delta) {
    _outstanding += delta;
    assert(_outstanding >= 0, 'SubscriptionQueue outstanding went negative');
    if (_outstanding == 0) _settleIdleWaiters();
  }

  void _settleIdleWaiters() {
    if (_idleWaiters.isEmpty) return;
    final waiters = List<Completer<void>>.of(_idleWaiters);
    _idleWaiters.clear();
    for (final waiter in waiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
  }

  static Future<void> _noop() async {}
}

/// The process-wide default queue. Tests construct their own instances so
/// state and listeners never leak between cases.
final SubscriptionQueue subscriptionQueue = SubscriptionQueue();
