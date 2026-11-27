// Dart half of the speed-test delta feed (Go: speed_test_delta_test.go).
// These tests pin the merge semantics the reply port relies on: a delta is
// folded into the last full frame before it reaches the UI, a full frame resets
// the baseline, and a cancelled frame ends the run without resurrecting stale
// state. `speedTestDone` / error frames never enter the merger.

import 'package:flrone/core/speed_test_delta.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> full({
  String tag = 'proxy',
  String dl = '1.00 M',
  String ul = '2.00 M',
  int bytes = 100,
  bool cancelled = false,
  bool running = true,
}) =>
    <String, dynamic>{
      'Tag': tag,
      'DlSpeed': dl,
      'UlSpeed': ul,
      'Latency': 10,
      'ServerName': 'server',
      'ServerCountry': 'CN',
      'Error': '',
      'Cancelled': cancelled,
      'DlBytes': bytes,
      'UlBytes': 200,
      'Running': running,
    };

void main() {
  group('speed-test delta merge', () {
    test('a full frame passes through unchanged', () {
      expect(mergeSpeedTestDelta(full(), null), full());
    });

    test('a delta merges into the last full frame with only changed fields', () {
      final merged = mergeSpeedTestDelta(
        <String, dynamic>{
          'tag': 'proxy',
          'delta': <String, dynamic>{'DlSpeed': '3.00 M', 'DlBytes': 250},
        },
        full(),
      );
      expect(merged, isNotNull);
      expect(merged!['Tag'], 'proxy');
      expect(merged['DlSpeed'], '3.00 M');
      expect(merged['DlBytes'], 250);
      // Untouched fields survive from the baseline.
      expect(merged['UlSpeed'], '2.00 M');
      expect(merged['ServerName'], 'server');
      expect(merged['Latency'], 10);
      expect(merged['Cancelled'], isFalse);
    });

    test('a delta without a matching baseline builds a partial frame, not stale', () {
      final merged = mergeSpeedTestDelta(
        <String, dynamic>{
          'tag': 'other',
          'delta': <String, dynamic>{'DlSpeed': '9 M'},
        },
        full(tag: 'proxy'),
      );
      expect(merged!['Tag'], 'other');
      expect(merged['DlSpeed'], '9 M');
      expect(merged.containsKey('UlSpeed'), isFalse);
    });

    test('identity detection only fires for a delta shape', () {
      expect(isSpeedTestDelta(<String, dynamic>{
        'tag': 'proxy',
        'delta': <String, dynamic>{'DlSpeed': '1 M'},
      }), isTrue);
      expect(isSpeedTestDelta(full()), isFalse);
      expect(isSpeedTestDelta(<String, dynamic>{'delta': 'not a map'}), isFalse);
    });

    test('a cancelled full frame resets the baseline for a clean next run', () {
      final terminal = full(cancelled: true, running: false);
      expect(mergeSpeedTestDelta(terminal, full()), terminal);
      // A new full frame after cancellation is accepted as-is.
      expect(mergeSpeedTestDelta(full(dl: 'fresh'), terminal), full(dl: 'fresh'));
    });

    test('a non-map payload and a done signal do not produce a frame', () {
      expect(mergeSpeedTestDelta(null, full()), isNull);
      expect(mergeSpeedTestDelta('speedTestDone', full()), isNull);
    });
  });
}
