import 'package:flrone/capabilities.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an empty manifest prunes nothing', () {
    expect(BoxCapabilities.empty.known, isFalse);
    expect(BoxCapabilities.empty.of('terminal'), isTrue);
    expect(BoxCapabilities.parse(null).known, isFalse);
  });

  test('a manifest prunes only the false capabilities', () {
    final caps = BoxCapabilities.parse({
      'terminal': false,
      'logs': true,
    });
    expect(caps.known, isTrue);
    expect(caps.of('terminal'), isFalse);
    expect(caps.of('logs'), isTrue);
    expect(caps.of('missing'), isFalse);
  });

  test('a malformed manifest falls back to the unknown host', () {
    expect(BoxCapabilities.parse('not a map').known, isFalse);
    expect(BoxCapabilities.parse(42).known, isFalse);
  });
}
