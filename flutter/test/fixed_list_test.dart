import 'package:flrone/common/fixed_list.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('append trims the oldest rows at capacity', () {
    final list = FixedList<int>(capacity: 3);
    list.appendAll([1, 2, 3]);
    expect(list.list, [1, 2, 3]);
    list.appendAll([4]);
    expect(list.list, [2, 3, 4]);
    list.appendAll([5, 6]);
    expect(list.list, [4, 5, 6]);
  });

  test('a batch larger than the window keeps only its newest rows', () {
    final list = FixedList<int>(capacity: 3)..appendAll([1, 2]);
    list.appendAll([3, 4, 5, 6]);
    expect(list.list, [4, 5, 6]);
    expect(list.length, 3);
  });

  test('every mutation changes the revision; a no-op does not', () {
    final list = FixedList<int>(capacity: 2);
    expect(list.revision, 0);
    list.appendAll([1]);
    expect(list.revision, 1);
    list.appendAll(const []);
    expect(list.revision, 1, reason: 'an empty append moves nothing');
    list.replaceAll([2, 3]);
    expect(list.revision, 2);
    list.clear();
    expect(list.revision, 3);
    expect(list.isEmpty, isTrue);
    list.clear();
    expect(list.revision, 3, reason: 'clearing an empty window moves nothing');
  });

  test('replaceAll swaps the window and trims to capacity', () {
    final list = FixedList<int>(capacity: 2)..replaceAll([1, 2, 3]);
    expect(list.list, [2, 3]);
    list.replaceAll([9]);
    expect(list.list, [9]);
  });

  test('the snapshot is stable between mutations and detached from the buffer', () {
    final list = FixedList<int>(capacity: 4)..appendAll([1, 2]);
    final first = list.list;
    expect(identical(list.list, first), isTrue, reason: 'reads reuse the cached snapshot');
    list.appendAll([3]);
    final second = list.list;
    expect(identical(second, first), isFalse);
    expect(first, [1, 2], reason: 'a reader holding the old snapshot keeps its rows');
    expect(second, [1, 2, 3]);
    expect(() => second.add(4), throwsUnsupportedError);
  });

  test('a feed that keeps appending stays at capacity', () {
    final list = FixedList<int>(capacity: 2);
    for (var i = 0; i < 100; i++) {
      list.appendAll([i]);
    }
    expect(list.list, [98, 99]);
    expect(list.length, 2);
  });
}
