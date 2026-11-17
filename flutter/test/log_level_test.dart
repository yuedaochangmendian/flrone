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
    expect(logLevelRank(1), 1);
    expect(logLevelRank(2), 2);
    expect(logLevelRank('panic'), 5);
    expect(logLevelRank('assert'), 5);
    expect(logLevelRank('unknown'), 2);
  });
}
