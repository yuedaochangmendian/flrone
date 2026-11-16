/// The severity scale both log tails carry, ordered the way logcat orders it.
///
/// The host normalises each source's spelling on the way out — logcat's one-letter
/// priorities become words, `warning` becomes `warn` — so the only outliers here are
/// `panic`/`assert` (which sit with `fatal`) and a line whose level could not be read,
/// which the host calls `info`. Both ends rank through this file so a floor picked in
/// one place means the same thing everywhere.
const logLevelNames = ['trace', 'debug', 'info', 'warn', 'error', 'fatal'];

/// A record's level as one of [logLevelNames] (or `panic`/`assert`, which rank with
/// `fatal`).
///
/// The channel already sends words, but the FFI kernel port sends sing-box's numeric
/// `log.Level` (trace 0, debug 1, info 2, warn 3, error 4, fatal 5, panic 6). This
/// normalises both, because a bare number used to reach the screen as the badge text and
/// rank as `info` in every filter.
String logLevelName(Object? level) {
  if (level is num) {
    return switch (level.toInt()) {
      0 => 'trace',
      1 => 'debug',
      3 => 'warn',
      4 => 'error',
      5 => 'fatal',
      6 => 'panic',
      _ => 'info',
    };
  }
  final name = level?.toString().toLowerCase().trim() ?? '';
  return switch (name) {
    '' => 'info',
    'warning' => 'warn',
    'verbose' => 'trace',
    _ => name,
  };
}

int logLevelRank(Object? level) => switch (logLevelName(level)) {
  'trace' => 0,
  'debug' => 1,
  'warn' => 3,
  'error' => 4,
  'fatal' || 'panic' || 'assert' => 5,
  _ => 2,
};

/// Whether [level] clears [floor]; no floor keeps every record.
bool logLevelAtLeast(Object? level, String? floor) =>
    floor == null || logLevelRank(level) >= logLevelRank(floor);
