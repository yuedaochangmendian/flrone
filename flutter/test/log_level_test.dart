import 'package:flrone/common/log_level.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the core\'s numeric level becomes the word both tails use', () {
    expect(
      [for (var level = 0; level <= 6; level++) logLevelName(level)],
      ['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'panic'],
    );
    expect(logLevelName('WARNING'), 'warn');
    expect(logLevelName('verbose'), 'trace');
    expect(logLevelName(null), 'info');
    expect(logLevelName(''), 'info');
    expect(logLevelName('warn'), 'warn');
  });

  test('a numeric level ranks as its word, not as info', () {
    expect(logLevelRank(3), 3);
    expect(logLevelAtLeast(3, 'warn'), isTrue);
    expect(logLevelAtLeast(1, 'warn'), isFalse);
    expect(logLevelAtLeast(2, 'debug'), isTrue);
    expect(logLevelAtLeast(0, null), isTrue);
    expect(logLevelRank('panic'), 5);
    expect(logLevelRank('assert'), 5);
    expect(logLevelRank('unknown'), 2);
  });
}
