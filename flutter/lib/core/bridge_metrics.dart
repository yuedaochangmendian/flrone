// Process-wide, disabled-by-default counters for the Dart side of the native
// kernel bridge (see docs/perf-bridge-audit.md for the payload inventory).
//
// The counters answer "how many messages of each kind crossed, how big were
// they, and how long did the JSON decoder take" without changing delivery
// order or payload shapes. When [BridgeMetrics.enabled] is false — the default,
// including every production build — the recording helpers return before any
// allocation: one boolean read per message, no Stopwatch, no map writes.
//
// This is deliberately a plain class with static state rather than a package:
// both the kernel isolate's `ThroneKernel` and tests share one process-wide
// view, and a debug build can print [snapshot] from anywhere.

/// One accumulated counter row. Immutable; handed out only through
/// [BridgeMetrics.snapshot].
class BridgeMetric {
  const BridgeMetric(this.count, this.bytes, this.decodeMicros);

  /// Number of messages recorded for this kind.
  final int count;

  /// Sum of payload sizes: `String.length` for JSON, `Uint8List.length` for binary.
  final int bytes;

  /// Sum of `jsonDecode` microseconds where the decoder was timed. Stays 0 for
  /// kinds that never decode JSON on the measured path (e.g. `logFrame`).
  final int decodeMicros;

  @override
  String toString() =>
      'BridgeMetric(count: $count, bytes: $bytes, decodeMicros: $decodeMicros)';
}

/// Process-wide bridge payload counters, off by default.
///
/// Flip [enabled] in a debug build and read [snapshot] after a scenario;
/// [reset] between scenarios to measure deltas. Nothing here synchronizes
/// across isolates — `ThroneKernel` lives on one isolate (the kernel worker),
/// and that is the only production recorder.
abstract final class BridgeMetrics {
  static bool enabled = false;

  static final Map<String, _MutableMetric> _rows = <String, _MutableMetric>{};

  /// Records one message. No-op (no allocation) when disabled.
  ///
  /// [kind] is the wire method name for JSON events/results or a fixed label
  /// such as `logFrame` for binary frames. [bytes] is the raw payload length.
  /// [decodeMicros] is the elapsed `jsonDecode` time, already converted to
  /// microseconds by the caller (0 when no decoder ran).
  static void record(String kind, int bytes, {int decodeMicros = 0}) {
    if (!enabled) return;
    final row = _rows.putIfAbsent(kind, _MutableMetric.new);
    row.count++;
    row.bytes += bytes;
    row.decodeMicros += decodeMicros;
  }

  /// Runs [decode] and returns its value together with the elapsed decode
  /// time in microseconds (0 when disabled).
  ///
  /// The [Stopwatch] exists solely on the enabled path, so the disabled hot
  /// path is a direct call with no wrapper allocation. The caller records the
  /// result once it knows the wire kind (e.g. the decoded `method` name).
  static (T value, int micros) measure<T>(T Function() decode) {
    if (!enabled) return (decode(), 0);
    final watch = Stopwatch()..start();
    late final T value;
    try {
      value = decode();
    } finally {
      watch.stop();
    }
    return (value, watch.elapsedMicroseconds);
  }

  /// An immutable copy of the current counters, safe to print or retain.
  static Map<String, BridgeMetric> snapshot() => Map<String, BridgeMetric>.unmodifiable(
        _rows.map((key, value) => MapEntry(
              key,
              BridgeMetric(value.count, value.bytes, value.decodeMicros),
            )),
      );

  /// Records one decoded JSON event from the message-port listener.
  ///
  /// Extracted so the accounting can be tested without constructing a real
  /// [ThroneKernel] (which needs a native library). [decodeMicros] is the
  /// elapsed `jsonDecode` time, or 0 when timing was off / unavailable.
  static void recordJsonEvent(Object? raw, Map<String, dynamic>? event, {int decodeMicros = 0}) {
    if (!enabled) return;
    record(
      event?['method']?.toString() ?? 'unknown',
      raw is String ? raw.length : 0,
      decodeMicros: decodeMicros,
    );
  }

  /// Clears all counters. Caller decides when a measurement window starts.
  static void reset() => _rows.clear();
}

class _MutableMetric {
  int count = 0;
  int bytes = 0;
  int decodeMicros = 0;
}
