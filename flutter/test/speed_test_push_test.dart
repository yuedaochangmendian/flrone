// The speed screen's verdicts, as pure functions.
//
// This file used to mirror `_applyFrame` and `ThroneKernel.speedTestStates` — two
// pieces of the pre-session speed test that no longer exist — so it pinned copies
// of code nothing ran. The session feed replaced both; what is worth pinning now
// is the decision the screen makes about a wire, and that decision is exported
// (`speedTestRowReason`) so the tests exercise the code the page runs.

import 'package:flrone/pages/speed_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// One row in the shape `FlroneTestSessions.wire` emits.
Map<String, dynamic> _row(String error) => {
  'id': 0,
  'phase': 'DONE',
  'latency': 0,
  'error': error,
  'ok': false,
  'failed': false,
  'aborted': true,
};

Map<String, dynamic> _session(List<String> rowErrors) => {
  'kind': 2,
  'running': false,
  'failure': 'NONE',
  'speed': null,
  'rows': [for (final error in rowErrors) _row(error)],
};

void main() {
  group('speedTestRowReason', () {
    test('the engine\'s own cause is the reason', () {
      expect(
        speedTestRowReason(
          _session(['aborted: instance is not running']),
        ),
        'aborted: instance is not running',
      );
    });

    test('a bare abort marker names no cause and is skipped', () {
      // `SpeedTestRunner` reports a stopped profile as ERROR_ABORTED ("test
      // aborted"); that is the word for "stopped", not a reason.
      expect(speedTestRowReason(_session(['test aborted'])), isNull);
      expect(speedTestRowReason(_session(['aborted'])), isNull);
      // Go's cancellation text is the same non-answer.
      expect(speedTestRowReason(_session(['context canceled'])), isNull);
    });

    test('a real reason after a bare marker still wins', () {
      expect(
        speedTestRowReason(
          _session(['test aborted', 'aborted: instance is not running']),
        ),
        'aborted: instance is not running',
      );
    });

    test('an empty row list or blank errors name nothing', () {
      expect(speedTestRowReason(_session(const [])), isNull);
      expect(speedTestRowReason(_session(const ['', '   '])), isNull);
      expect(speedTestRowReason(const {}), isNull);
    });
  });
}
