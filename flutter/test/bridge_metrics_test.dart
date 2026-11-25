// Process-wide bridge counters: disabled by default, zero-cost when off, and
// recording per-kind counts/bytes/decode time when enabled. The kernel's
// message-port listener calls the same record helpers; here we drive those
// helpers directly so the test needs no libthrone.so or ThroneKernel instance.

import 'dart:typed_data';

import 'package:flrone/core/bridge_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    BridgeMetrics.enabled = false;
    BridgeMetrics.reset();
  });

  tearDown(() {
    BridgeMetrics.enabled = false;
    BridgeMetrics.reset();
  });

  test('disabled records nothing', () {
    expect(BridgeMetrics.enabled, isFalse);
    BridgeMetrics.record('status', 200);
    BridgeMetrics.recordJsonEvent(
      '{"method":"status","data":{}}',
      <String, dynamic>{'method': 'status'},
    );
    expect(BridgeMetrics.snapshot(), isEmpty);
  });

  test('enabled counts a JSON event by method name with raw byte length', () {
    BridgeMetrics.enabled = true;
    const raw = '{"method":"status","data":{"memory":42}}';
    BridgeMetrics.recordJsonEvent(
      raw,
      <String, dynamic>{'method': 'status', 'data': <String, dynamic>{'memory': 42}},
      decodeMicros: 7,
    );

    final snapshot = BridgeMetrics.snapshot();
    expect(snapshot, hasLength(1));
    final row = snapshot['status']!;
    expect(row.count, 1);
    expect(row.bytes, raw.length);
    expect(row.decodeMicros, 7);
  });

  test('enabled counts a binary log frame by byte length', () {
    BridgeMetrics.enabled = true;
    final frame = Uint8List.fromList(<int>[0x46, 0x4c, 0x42, 0x31, 1, 0, 0, 0]);
    BridgeMetrics.record('logFrame', frame.length);

    final row = BridgeMetrics.snapshot()['logFrame']!;
    expect(row.count, 1);
    expect(row.bytes, 8);
    expect(row.decodeMicros, 0);
  });

  test('measure returns the value and elapsed micros only when enabled', () {
    // Disabled: direct call, zero micros, no counter row.
    final (disabledValue, disabledMicros) = BridgeMetrics.measure(() => 41 + 1);
    expect(disabledValue, 42);
    expect(disabledMicros, 0);
    expect(BridgeMetrics.snapshot(), isEmpty);

    // Enabled: value unchanged, counter still empty until record() is called.
    BridgeMetrics.enabled = true;
    final (enabledValue, enabledMicros) = BridgeMetrics.measure(() => 41 + 1);
    expect(enabledValue, 42);
    expect(enabledMicros, greaterThanOrEqualTo(0));
    expect(BridgeMetrics.snapshot(), isEmpty);
  });

  test('snapshot is immutable and reset clears counters', () {
    BridgeMetrics.enabled = true;
    BridgeMetrics.record('status', 10);
    BridgeMetrics.record('status', 20, decodeMicros: 3);
    BridgeMetrics.record('logFrame', 8);

    final before = BridgeMetrics.snapshot();
    expect(before['status']!.count, 2);
    expect(before['status']!.bytes, 30);
    expect(before['status']!.decodeMicros, 3);
    expect(() => before['status'] = const BridgeMetric(0, 0, 0), throwsUnsupportedError);

    BridgeMetrics.reset();
    expect(BridgeMetrics.snapshot(), isEmpty);
    // The previously handed-out snapshot still reflects the old values.
    expect(before['status']!.count, 2);
  });
}
