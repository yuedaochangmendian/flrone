import 'dart:ui' show AppLifecycleState;

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

    test('only a hidden app suspends: an unfocused window keeps updating', () {
      // `inactive` means visible without window focus (split screen, the shade,
      // a system dialog). Suspending there froze the dashboard speed card the
      // moment another window took focus.
      expect(RefreshGate.suspendedFor(AppLifecycleState.resumed), isFalse);
      expect(RefreshGate.suspendedFor(AppLifecycleState.inactive), isFalse);
      expect(RefreshGate.suspendedFor(AppLifecycleState.hidden), isTrue);
      expect(RefreshGate.suspendedFor(AppLifecycleState.paused), isTrue);
      expect(RefreshGate.suspendedFor(AppLifecycleState.detached), isTrue);
    });
  });
}
