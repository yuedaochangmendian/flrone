import 'package:flrone/common/isolate_json.dart';
import 'package:flrone/common/refresh_gate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RefreshGate', () {
    test('gates rebuilds on foreground state', () {
      final gate = RefreshGate();
      expect(gate.shouldRebuild, isTrue);
      gate.setForeground(false);
      expect(gate.shouldRebuild, isFalse);
      expect(gate.foreground, isFalse);
      gate.setForeground(true);
      expect(gate.shouldRebuild, isTrue);
      gate.dispose();
    });

    test('respects the page predicate', () {
      var onDashboard = false;
      final gate = RefreshGate(pageIsDashboard: () => onDashboard);
      expect(gate.shouldRebuild, isFalse);
      onDashboard = true;
      expect(gate.shouldRebuild, isTrue);
      gate.dispose();
    });
  });

  test('decodeJsonInBackground parses off the calling isolate', () async {
    final value = await decodeJsonInBackground('{"list":[1,2,3]}');
    expect(value, isA<Map<dynamic, dynamic>>());
    expect((value! as Map)['list'], [1, 2, 3]);
  });
}
