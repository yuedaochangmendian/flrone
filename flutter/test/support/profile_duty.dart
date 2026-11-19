// Test-side reader for the one profile duty boundary.
//
// ADR 0005 final stage: the profile editor's Kotlin-only work goes through ONE
// channel method, `profiles.platform` with `{op, payload}`. Tests that used to
// match a named arm (`profiles.save`) ask for the op instead; keeping the shape
// in one helper means a future rename is a one-line change here.
import 'package:flrone/box.dart' show json;
import 'package:flutter/services.dart';

/// The `profiles.platform` op of [call], or null when it is another method.
String? dutyOp(MethodCall call) {
  if (call.method != 'profiles.platform') return null;
  final op = json(call.arguments)['op'];
  return op is String ? op : null;
}

/// The payload map of a `profiles.platform` call (empty for other methods).
Map<String, dynamic> dutyPayload(MethodCall call) {
  if (call.method != 'profiles.platform') return <String, dynamic>{};
  final payload = json(call.arguments)['payload'];
  return payload is Map ? json(payload) : <String, dynamic>{};
}
