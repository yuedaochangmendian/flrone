import 'dart:math' as math;

// The Go runtime's own memory accounting, read through the `runtimeMemory`
// action. The wire shape is produced by the parallel Go-side implementation;
// this decoder only reads numbers and never fabricates a missing one.
//
// `heapIdle` arrives with HeapReleased already subtracted (the released span is
// back in the OS, not retained by the Go allocator), so `runtimeTotal` is the
// part of the process RSS the Go runtime actually holds.

/// Automatic Go-heap trim policy thresholds.
///
/// These belong to the service engine (the sole kernel owner), not to the
/// display-only memory panel: the panel reads stats, it never acts on them.
const int kAutoTrimHighWaterBytes = 512 * 1024 * 1024; // 512 MiB
/// A trim is only worth its stop-the-world pause when at least this share of
/// what the Go runtime retains is idle heap it can hand back to the OS.
const double kAutoTrimIdleShare = 0.25;
/// Minimum gap between automatic trims, and the cadence of the periodic check.
/// The status feed is 1 Hz; checking the action bus every tick would be waste.
const Duration kAutoTrimCooldown = Duration(seconds: 60);

/// Whether the Go runtime is holding enough reclaimable heap to justify a
/// *full* automatic trim.
///
/// Deliberately uses [KernelMemoryStats.runtimeTotal] rather than RSS: the
/// process RSS also contains ART/Flutter/native mappings, which a Go GC cannot
/// release. The idle share is measured against what the runtime actually
/// holds, so a big process with a tight Go heap is left alone.
bool shouldTrimGoHeap(KernelMemoryStats stats) {
  final total = stats.runtimeTotal;
  if (total < kAutoTrimHighWaterBytes) return false;
  return stats.heapIdle > total * kAutoTrimIdleShare;
}

/// Snapshot of the Go runtime's memory and scheduler counters.
class KernelMemoryStats {
  const KernelMemoryStats({
    required this.rss,
    required this.heapAlloc,
    required this.heapSys,
    required this.heapInuse,
    required this.heapIdle,
    required this.stackInuse,
    required this.runtimeOther,
    required this.numGC,
    required this.goroutines,
  });

  /// Resident set size of the whole process, as reported by the Go runtime.
  final int rss;
  final int heapAlloc;
  final int heapSys;
  final int heapInuse;
  final int heapIdle;
  final int stackInuse;

  /// Go runtime overhead outside heap and stacks; measured, not derived here.
  final int runtimeOther;
  final int numGC;
  final int goroutines;

  static int _num(Object? value) => value is num ? value.toInt() : 0;

  factory KernelMemoryStats.fromJson(Object? raw) {
    final map = raw is Map ? raw : const <Object?, Object?>{};
    return KernelMemoryStats(
      rss: _num(map['rss']),
      heapAlloc: _num(map['heapAlloc']),
      heapSys: _num(map['heapSys']),
      heapInuse: _num(map['heapInuse']),
      heapIdle: _num(map['heapIdle']),
      stackInuse: _num(map['stackInuse']),
      runtimeOther: _num(map['runtimeOther']),
      numGC: _num(map['numGC']),
      goroutines: _num(map['goroutines']),
    );
  }

  /// Heap + stacks + other runtime spans actually held by the Go runtime.
  ///
  /// Deliberately not [rss]: the process RSS includes ART, Flutter, native
  /// libraries and file mappings, which are the app's side of the split.
  int get runtimeTotal => heapInuse + heapIdle + stackInuse + runtimeOther;
}

/// Derived process/core split for the memory panel.
///
/// [processRss] is the process's resident set: `ProcessInfo.currentRss` on
/// Android when available, otherwise the host's PSS-derived `rss` field.
/// [app] is everything in that process that is not held by the Go runtime; it
/// is clamped at zero so a host/Dart accounting mismatch cannot show a negative
/// slice. Every number here comes from the action or ProcessInfo — nothing is
/// synthesised.
class KernelMemorySplit {
  const KernelMemorySplit({
    required this.processRss,
    required this.coreTotal,
    required this.app,
  });

  final int processRss;
  final int coreTotal;
  final int app;

  factory KernelMemorySplit.from(KernelMemoryStats stats, int hostRss) {
    final core = stats.runtimeTotal;
    return KernelMemorySplit(
      processRss: hostRss,
      coreTotal: core,
      app: math.max(0, hostRss - core),
    );
  }
}
