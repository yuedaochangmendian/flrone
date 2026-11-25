// The lifecycle feed is a real switch, not a filter: stopping FrameWatch must
// release its persistent frame callback and 25 ms loop timer, and starting it
// again must be safe to call repeatedly.

import 'package:flrone/core/frame_watch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stop releases the frame callback and the loop timer', (tester) async {
    final reports = <String>[];
    final watch = FrameWatch(report: reports.add, context: () => 'test');
    addTearDown(watch.stop);

    expect(watch.running, isFalse);
    watch.start();
    expect(watch.running, isTrue);
    watch.start(); // idempotent: one callback, one timer
    expect(watch.running, isTrue);
    watch.stop();
    expect(watch.running, isFalse);
    watch.stop();
    expect(watch.running, isFalse);
    // No pending timer is left behind (the test binding fails if one is).
    expect(reports, isEmpty);
  });

  testWidgets('the process controller drives only an attached watch', (tester) async {
    final control = LifecycleDiagnostics();
    final watch = FrameWatch(report: (_) {}, context: () => 'test');
    addTearDown(watch.stop);

    control.setEnabled(true); // nothing attached: no-op
    expect(watch.running, isFalse);

    control.attach(watch);
    expect(control.enabled, isFalse);
    control.setEnabled(true);
    expect(watch.running, isTrue);
    expect(control.enabled, isTrue);
    control.setEnabled(true);
    expect(watch.running, isTrue);
    control.setEnabled(false);
    expect(watch.running, isFalse);
    expect(control.enabled, isFalse);
  });
}
