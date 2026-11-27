// Dart half of the speed-test delta feed (see Go speed_test_delta.go).
//
// The kernel posts the first frame for a tag as a full 11-field
// SpeedTestResult (Go field names), then frames of the shape
//   {"tag": <Tag>, "delta": {<field>: <new value>, ...}}
// carrying only fields that changed. This merger keeps the last full frame per
// tag, applies a delta to it, and delivers the merged FULL frame to the UI —
// preserving the old "every speedTestResult event is a complete snapshot"
// semantics, including a screen that opens mid-run.
//
// A `Cancelled` full frame (terminal) resets that tag's baseline, as does
// [clearSpeedTestDeltas] when the port is closed / a new run starts. A frame
// with no recognizable tag is passed through untouched, so an older kernel or
// a foreign producer cannot be corrupted by the merger.
//
// Wire names are the Go struct field names (Tag, DlSpeed, ...); they are kept
// verbatim so a full frame still decodes identically to the pre-delta build.

/// Merges one decoded `speedTestResult` [data] payload with [last] (the last
/// full frame for that tag, or null). Returns the full frame to deliver, or
/// null when the frame carried no new information and can be dropped.
Map<String, dynamic>? mergeSpeedTestDelta(
  Object? data,
  Map<String, dynamic>? last,
) {
  if (data is! Map) return null;
  final raw = Map<String, dynamic>.from(data);
  // A delta frame is identified by an exact lowercase `delta` map near a
  // `tag` string. Any other shape is a legacy full frame — return it verbatim.
  final delta = raw['delta'];
  if (delta is! Map || raw['tag'] is! String) {
    return raw;
  }
  final tag = raw['tag'] as String;
  // Identity check: never merge a delta whose tag does not match the baseline.
  // A mismatched tag is treated as a fresh full frame request; if we have no
  // baseline we cannot reconstruct one, so drop it rather than paint stale data.
  final base = last != null && last['Tag'] == tag
      ? Map<String, dynamic>.from(last)
      : <String, dynamic>{'Tag': tag};
  for (final entry in delta.entries) {
    base[entry.key.toString()] = entry.value;
  }
  return base;
}

/// True when [data] is a delta frame (not a legacy full frame).
bool isSpeedTestDelta(Object? data) =>
    data is Map && data['delta'] is Map && data['tag'] is String;
