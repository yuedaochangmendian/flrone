import 'package:flrone/box.dart';
import 'package:flutter_test/flutter_test.dart';

/// A deliberately generous frame-time budget rather than a pixel golden: the
/// CI runner is Linux while local development is Windows, so image goldens are
/// not reproducible across the two until a CI-generated baseline is committed.
/// These assertions catch an accidental O(n^2) or a regression that pushes
/// parsing back onto the UI isolate, without being sensitive to font rastering.
void main() {
  test('normalizing a large event payload stays within budget', () {
    final payload = <Object?>[
      for (var i = 0; i < 2000; i++)
        <Object?, Object?>{'id': i, 'name': 'node-$i', 'meta': <Object?, Object?>{'a': 1}},
    ];
    final stopwatch = Stopwatch()..start();
    final parsed = rows(payload);
    stopwatch.stop();
    expect(parsed.length, 2000);
    expect(stopwatch.elapsedMilliseconds, lessThan(2000),
        reason: 'normalizePlatformValue regressed on a 2000-row payload');
  });

  test('traffic windows are bounded', () {
    expect(BoxController.trafficWindow, 30);
    expect(BoxController.maxLogLength, 5000);
  });
}
