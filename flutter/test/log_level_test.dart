import 'package:flrone/common/log_level.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the core\'s numeric level becomes the word both tails use', () {
    expect(
      [for (var level = 0; level <= 6; level++) logLevelName(level)],
      ['panic', 'fatal', 'error', 'warn', 'info', 'debug', 'trace'],
    );
    expect(logLevelName('WARNING'), 'warn');
    expect(logLevelName('verbose'), 'trace');
    expect(logLevelName(null), 'info');
    expect(logLevelName(''), 'info');
    expect(logLevelName('warn'), 'warn');
  });

  test('a numeric level ranks as its word, not as info', () {
    expect(logLevelRank(0), 5);
    expect(logLevelRank(1), 5);
    expect(logLevelRank(2), 4);
    expect(logLevelRank(3), 3);
    expect(logLevelRank(4), 2);
    expect(logLevelRank(5), 1);
    expect(logLevelRank(6), 0);
    expect(logLevelRank('panic'), 5);
    expect(logLevelRank('assert'), 5);
    expect(logLevelRank('unknown'), 2);
  });

  test('the old quietest spellings map onto the core\'s panic', () {
    expect(logLevelName('none'), 'panic');
    expect(logLevelIndex('none'), logLevelIndex('panic'));
    expect(coreLogLevels, isNot(contains('silent')));
  });

  test('a recording level drops more verbose lines', () {
    expect(logLevelAllowed('trace', 'info'), isFalse);
    expect(logLevelAllowed('debug', 'info'), isFalse);
    expect(logLevelAllowed('info', 'info'), isTrue);
    expect(logLevelAllowed('warn', 'info'), isTrue);
    expect(logLevelAllowed('panic', 'warn'), isTrue);
    expect(logLevelAllowed('info', 'warn'), isFalse);
  });
}
