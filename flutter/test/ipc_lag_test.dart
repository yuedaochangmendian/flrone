// IPC lag is measured from a wall-clock stamp (the two isolates share no
// monotonic clock). A clock adjustment can make the delta negative or huge;
// the receiving side clamps negatives to zero so an "ipc lag" diagnostic never
// reports a fake stall from a backwards clock step. The 100 ms reporting
// threshold is unchanged.

import 'package:flrone/core/kernel_proxy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lagMillis clamps a backwards clock to zero', () {
    // A send stamp ahead of the receive instant (NTP step backwards, or two
    // engines whose wall clocks are briefly unsynced) is not transport lag.
    expect(lagMillis(1000, 1500), 0);
    expect(lagMillis(1000, 1000), 0);
    expect(lagMillis(1500, 1000), 500);
  });

  test('the reporting threshold stays 100 ms and a negative delta is silent', () {
    expect(KernelProxy.lagReportMs, 100);
    // A -2 s clock step must not cross the threshold (it used to produce a
    // negative lag that failed `> 100` silently — clamping makes the intent
    // explicit rather than relying on the comparison).
    expect(lagMillis(1000, 3000) > KernelProxy.lagReportMs, isFalse);
    // A genuine 250 ms stall still crosses it.
    expect(lagMillis(1250, 1000) > KernelProxy.lagReportMs, isTrue);
    // Exactly at the threshold is not reported (strict >).
    expect(lagMillis(1100, 1000) > KernelProxy.lagReportMs, isFalse);
  });
}
