// The policy that keeps the Go VPN-status watcher attached to the *current* core.
//
// The watch is registered per Go Instance, not per app: a stop/start pair builds
// a new instance, so a one-shot "armed" latch leaves the fresh core with no
// listener and no challenge can ever be pushed. Worse, the core answers false
// when it has no OpenVPN/OpenConnect endpoint yet — that is not an error and
// must not be latched as success either: a later config reload may add one.
//
// This class is pure Dart (no controller, no engine, no timers started in a
// constructor): the run key, the arm call, the retry sleep and the error sink
// are all injected so the policy can be tested without a kernel. The caller
// feeds it every state change and drops it on dispose.

/// Decides when to install the per-run VPN status watcher.
///
/// [runKey] identifies one core run (and its config): null while stopped, a
/// stable value while running. It changes on stop/start and on a reload that
/// builds a new instance. [arm] calls `vpnWatchStatus()` and answers whether
/// this core actually installed a watcher.
///
/// A false answer is retried up to [maxAttempts] times, [retryDelay] apart,
/// while the same run stays active. Once those attempts are spent the key is
/// considered settled: ordinary 1 Hz state ticks do not spin on a core with no
/// endpoint. A different key always gets a fresh budget (that is how a config
/// change can add an endpoint), and a stop clears every bit of state.
Future<void> _realDelay(Duration delay) => Future<void>.delayed(delay);
void _reportNothing(Object error) {}

class VpnWatchArmer {
  VpnWatchArmer({
    required this.runKey,
    required this.arm,
    this.retryDelay = const Duration(seconds: 5),
    this.maxAttempts = 3,
    Future<void> Function(Duration delay)? sleep,
    void Function(Object error)? onError,
  })  : _sleep = sleep ?? _realDelay,
        _onError = onError ?? _reportNothing;

  final String? Function() runKey;
  final Future<bool> Function() arm;
  final Duration retryDelay;
  final int maxAttempts;

  final Future<void> Function(Duration) _sleep;
  final void Function(Object) _onError;

  String? _armedKey;
  String? _attemptingKey;
  String? _settledKey;
  int _generation = 0;
  bool _disposed = false;

  /// Call on every controller notification. Safe to call at any rate: one
  /// watcher per key, at most [maxAttempts] arm calls in one retry sequence.
  Future<void> onState() async {
    if (_disposed) return;
    final key = runKey();
    if (key == null) {
      reset();
      return;
    }
    if (key == _armedKey || key == _attemptingKey || key == _settledKey) return;

    final generation = ++_generation;
    _attemptingKey = key;
    try {
      // At least one attempt even if a caller configures a zero budget.
      var attempt = 0;
      while (attempt < (maxAttempts < 1 ? 1 : maxAttempts)) {
        if (_disposed || generation != _generation) return;
        bool watching;
        try {
          watching = await arm();
        } catch (error) {
          // A transport failure is the same situation as "no endpoint yet":
          // retry while this run is still active, never surface it as armed.
          _onError(error);
          watching = false;
        }
        if (_disposed || generation != _generation) return;
        if (watching) {
          _armedKey = key;
          return;
        }
        attempt++;
        if (attempt >= (maxAttempts < 1 ? 1 : maxAttempts)) break;
        await _sleep(retryDelay);
        // The sleep is the window in which a stop or a reload can happen; the
        // generation check at the top of the loop discards a stale sequence.
      }
      if (!_disposed && generation == _generation) _settledKey = key;
    } finally {
      if (generation == _generation && _attemptingKey == key) _attemptingKey = null;
    }
  }

  /// Forgets the current run: a stop, a restart request or an explicit reset.
  /// Allows the same key to be armed again if the core comes back with it.
  void reset() {
    _generation++;
    _armedKey = null;
    _attemptingKey = null;
    _settledKey = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    reset();
  }
}
