// Pure codec/derivation tests for the Go runtime memory surface. No platform
// channels, no Flutter engine: the wire shape is the contract the parallel Go
// side implements, and these tests pin the Dart side's reading of it.

import 'package:flrone/core/kernel_memory.dart';
import 'package:flutter_test/flutter_test.dart';

KernelMemoryStats _stats({
  required int heapInuse,
  required int heapIdle,
  int stackInuse = 0,
  int runtimeOther = 0,
  int rss = 0,
}) {
  return KernelMemoryStats(
    rss: rss,
    heapAlloc: 0,
    heapSys: 0,
    heapInuse: heapInuse,
    heapIdle: heapIdle,
    stackInuse: stackInuse,
    runtimeOther: runtimeOther,
    numGC: 0,
    goroutines: 0,
  );
}

void main() {
  const wire = <String, dynamic>{
    'rss': 297061581,
    'heapAlloc': 33947648,
    'heapSys': 94371840,
    'heapInuse': 58720256,
    'heapIdle': 35651584,
    'stackInuse': 4194304,
    'runtimeOther': 8388608,
    'numGC': 12,
    'goroutines': 37,
  };

  test('fromJson reads every number in the action wire shape', () {
    final stats = KernelMemoryStats.fromJson(wire);
    expect(stats.rss, 297061581);
    expect(stats.heapAlloc, 33947648);
    expect(stats.heapSys, 94371840);
    expect(stats.heapInuse, 58720256);
    expect(stats.heapIdle, 35651584);
    expect(stats.stackInuse, 4194304);
    expect(stats.runtimeOther, 8388608);
    expect(stats.numGC, 12);
    expect(stats.goroutines, 37);
  });

  test('runtimeTotal sums the retained parts, not heapSys or rss', () {
    final stats = KernelMemoryStats.fromJson(wire);
    expect(stats.runtimeTotal,
        58720256 + 35651584 + 4194304 + 8388608);
    expect(stats.runtimeTotal, isNot(stats.rss));
    expect(stats.runtimeTotal, isNot(stats.heapSys));
  });

  test('fromJson tolerates a missing or malformed payload with zeroes', () {
    final stats = KernelMemoryStats.fromJson(null);
    expect(stats.runtimeTotal, 0);
    expect(stats.numGC, 0);
    expect(stats.goroutines, 0);
    final partial = KernelMemoryStats.fromJson(<String, dynamic>{
      'heapInuse': 'not a number',
      'goroutines': 5.7,
    });
    expect(partial.heapInuse, 0);
    expect(partial.goroutines, 5);
  });

  test('the split clamps app at zero when the runtime holds more than RSS', () {
    final stats = KernelMemoryStats.fromJson(wire);
    final normal = KernelMemorySplit.from(stats, 300000000);
    expect(normal.processRss, 300000000);
    expect(normal.coreTotal, stats.runtimeTotal);
    expect(normal.app, 300000000 - stats.runtimeTotal);

    // Host RSS and the Go runtime's own accounting can disagree (different
    // moments, different definitions). A negative slice is never displayed.
    final inverted = KernelMemorySplit.from(stats, 1000);
    expect(inverted.app, 0);
  });

  group('automatic Go-trim predicate', () {
    test('stats fitting under the high-water line are left alone', () {
      // 400 MiB retained, 200 MiB idle: idle share is high but the heap is small.
      expect(
        shouldTrimGoHeap(_stats(
          rss: 900 * 1024 * 1024,
          heapInuse: 200 * 1024 * 1024,
          heapIdle: 200 * 1024 * 1024,
        )),
        isFalse,
        reason: 'a large RSS with a small Go heap is not the Go runtime\'s problem',
      );
    });

    test('high water with a meaningful idle share triggers a trim', () {
      // 600 MiB retained, 300 MiB idle (50% > 25%).
      expect(
        shouldTrimGoHeap(_stats(
          rss: 900 * 1024 * 1024,
          heapInuse: 300 * 1024 * 1024,
          heapIdle: 300 * 1024 * 1024,
        )),
        isTrue,
      );
    });

    test('high water with a tight heap does not trigger a trim', () {
      // 600 MiB retained but only 60 MiB idle (10% < 25%): GC cannot give much back.
      expect(
        shouldTrimGoHeap(_stats(
          heapInuse: 540 * 1024 * 1024,
          heapIdle: 60 * 1024 * 1024,
        )),
        isFalse,
      );
    });

    test('the idle share boundary is strict (> 25%)', () {
      const total = 512 * 1024 * 1024;
      expect(
        shouldTrimGoHeap(_stats(heapInuse: total * 3 ~/ 4, heapIdle: total ~/ 4)),
        isFalse,
        reason: 'exactly 25% is not a meaningful share',
      );
      expect(
        shouldTrimGoHeap(_stats(
          heapInuse: total * 3 ~/ 4,
          heapIdle: (total ~/ 4) + 1,
        )),
        isTrue,
      );
    });
  });
}
