import 'package:flrone/box.dart';
import 'package:flrone/pages/logs.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two tails are append-only rings stamped with a shared arrival `seq`.
/// These tests exercise the merger directly so a regression that pushes both
/// 5000-row rings through a full re-materialise + sort on every batch is caught
/// without a device trace.
Json _entry(int seq, {required int millis, required String level, required String message}) => {
  'seq': seq,
  'id': seq,
  'receivedAt': millis,
  'level': level,
  'message': message,
};

List<Json> _tail(int count, {required int startSeq, required int startMillis, String prefix = 'core'}) => [
  for (var i = 0; i < count; i++)
    _entry(startSeq + i, millis: startMillis + i, level: 'info', message: '$prefix line $i'),
];

void main() {
  test('merges two interleaved tails by time then shared arrival sequence', () {
    final merger = LogRowMerger();
    final logs = [
      _entry(1, millis: 1000, level: 'info', message: 'core a'),
      _entry(3, millis: 3000, level: 'warn', message: 'core b'),
    ];
    final logcat = [
      _entry(2, millis: 2000, level: 'debug', message: 'cat a'),
      _entry(4, millis: 4000, level: 'error', message: 'cat b'),
    ];
    expect(merger.merge(logs, logcat).map((row) => row.message), [
      'core a', 'cat a', 'core b', 'cat b',
    ]);
  });

  test('ties on the same millisecond keep arrival order (List.sort is unstable)', () {
    final merger = LogRowMerger();
    final result = merger.merge(
      [_entry(2, millis: 1000, level: 'info', message: 'core'), _entry(4, millis: 1000, level: 'info', message: 'core 2')],
      [_entry(1, millis: 1000, level: 'info', message: 'cat'), _entry(3, millis: 1000, level: 'info', message: 'cat 2')],
    );
    expect(result.map((row) => row.seq), [1, 2, 3, 4]);
  });

  test('an append to one tail reuses retained rows and keeps interleaving order', () {
    final merger = LogRowMerger();
    final logs = [
      _entry(1, millis: 1000, level: 'info', message: 'core a'),
      _entry(4, millis: 4000, level: 'info', message: 'core b'),
    ];
    final logcat = [
      _entry(2, millis: 2000, level: 'debug', message: 'cat a'),
      _entry(3, millis: 3000, level: 'debug', message: 'cat b'),
    ];
    final first = merger.merge(logs, logcat);
    final reused = first[0];
    // A new core entry with a later millis and seq than the logcat tail.
    final appended = [...logs, _entry(5, millis: 5000, level: 'warn', message: 'core c')];
    final second = merger.merge(appended, logcat);
    expect(second.map((row) => row.message), [
      'core a', 'cat a', 'cat b', 'core b', 'core c',
    ]);
    expect(identical(second.first, reused), isTrue, reason: 'retained rows must not be rematerialised');
  });

  test('a batch interleaved between the two prior tails is inserted in order', () {
    final merger = LogRowMerger();
    final logs = [_entry(1, millis: 1000, level: 'info', message: 'a'), _entry(4, millis: 4000, level: 'info', message: 'd')];
    final logcat = [_entry(2, millis: 2000, level: 'info', message: 'b')];
    merger.merge(logs, logcat);
    // The new logcat row's time/seq falls between the two existing core rows.
    final result = merger.merge(logs, [...logcat, _entry(3, millis: 3000, level: 'info', message: 'c')]);
    expect(result.map((row) => row.message), ['a', 'b', 'c', 'd']);
  });

  test('a ring trim drops the evicted row and keeps the retained suffix', () {
    final merger = LogRowMerger();
    final logs = [
      _entry(1, millis: 1000, level: 'info', message: 'old'),
      _entry(2, millis: 2000, level: 'info', message: 'kept'),
      _entry(3, millis: 3000, level: 'info', message: 'newest'),
    ];
    merger.merge(logs, <Json>[]);
    // A full ring would evict the front, not delete the retained suffix.
    final result = merger.merge(logs.sublist(1), <Json>[]);
    expect(result.map((row) => row.message), ['kept', 'newest']);
  });

  test('a clear replaces the merged rows with the current tails', () {
    final merger = LogRowMerger();
    merger.merge(_tail(10, startSeq: 1, startMillis: 1000), const []);
    final result = merger.merge(<Json>[], <Json>[]);
    expect(result, isEmpty);
  });

  test('merging two full rings with a fresh batch stays within a stopwatch budget', () {
    const ring = 5000;
    final logs = _tail(ring, startSeq: 1, startMillis: 1000, prefix: 'core');
    final logcat = _tail(ring, startSeq: ring + 1, startMillis: 1001, prefix: 'cat');
    final merger = LogRowMerger();
    final sw = Stopwatch()..start();
    final initial = merger.merge(logs, logcat);
    expect(initial, hasLength(2 * ring));
    // One ~300 ms batch: 20 new lines per tail, interleaved by time and seq.
    final nextLogs = [...logs.sublist(20), ..._tail(20, startSeq: 2 * ring + 1, startMillis: 1000 + ring, prefix: 'core')];
    final nextCat = [...logcat.sublist(20), ..._tail(20, startSeq: 2 * ring + 21, startMillis: 1001 + ring, prefix: 'cat')];
    for (var batch = 0; batch < 5; batch++) {
      merger.merge(nextLogs, nextCat);
    }
    sw.stop();
    // Optimised: one linear merge of 10000 + 40 rows per batch. The old code
    // rebuilt and sorted 10000 rows per batch; 500ms is generous even under the
    // Dart VM test runner while still catching an O(n log n) per batch regression
    // that runs the whole ring again.
    expect(sw.elapsedMilliseconds, lessThan(500),
        reason: 'log merge must not re-materialise/sort both rings on each batch '
            '(took ${sw.elapsedMilliseconds}ms for initial build + 5 batches)');
  });
}
