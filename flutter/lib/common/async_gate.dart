import 'dart:async';
import 'dart:collection';

/// Bounds how many round trips are in flight at once.
///
/// FlClash caps its process/app lookups at 8 (`maxConcurrentProcessLookups`):
/// one lookup is one platform-channel round trip, and the connections page asks
/// for one per visible row from `build`. A fast scroll used to put every
/// distinct process path on the channel at once, all queued behind the same
/// platform thread — the replies themselves are cheap, the burst is not. The
/// gate keeps at most [limit] running; the rest wait in arrival order.
///
/// Callers that already have an answer (a cache hit) must not call [run] at all,
/// so a cached lookup costs no slot.
class AsyncGate {
  AsyncGate({this.limit = 8}) : assert(limit > 0, 'a gate with no slots never opens');

  final int limit;
  int _inFlight = 0;
  final _waiting = Queue<Completer<void>>();

  /// Tasks currently holding a slot (running or about to run).
  int get inFlight => _inFlight;

  /// Tasks queued behind the limit, in arrival order.
  int get waiting => _waiting.length;

  /// Runs [task] once a slot is free and releases the slot when it settles.
  ///
  /// The slot is released from a `finally`, so a failed lookup cannot leak one
  /// and stall the feed it belongs to.
  Future<T> run<T>(Future<T> Function() task) async {
    if (_inFlight < limit) {
      _inFlight++;
    } else {
      final slot = Completer<void>();
      _waiting.add(slot);
      await slot.future;
    }
    try {
      return await task();
    } finally {
      _release();
    }
  }

  void _release() {
    // A freed slot goes straight to the oldest waiter, so the count stays at
    // `limit` while anybody is queued and no wake-up can race another taker.
    if (_waiting.isNotEmpty) {
      _waiting.removeFirst().complete();
    } else {
      _inFlight--;
    }
  }
}
