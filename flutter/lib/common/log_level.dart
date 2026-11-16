/// The severity scale both log tails carry, ordered the way logcat orders it.
///
/// The host normalises each source's spelling on the way out — logcat's one-letter
/// priorities become words, `warning` becomes `warn` — so the only outliers here are
/// `panic`/`assert` (which sit with `fatal`) and a line whose level could not be read,
/// which the host calls `info`. Both ends rank through this file so a floor picked in
/// one screen means the same thing in the other.
const logLevelNames = ['trace', 'debug', 'info', 'warn', 'error', 'fatal'];

int logLevelRank(Object? level) => switch (level.toString().toLowerCase().trim()) {
  'trace' || 'verbose' || 'v' => 0,
  'debug' || 'd' => 1,
  'warn' || 'warning' || 'w' => 3,
  'error' || 'e' => 4,
  'fatal' || 'f' || 'assert' || 'a' || 'panic' => 5,
  _ => 2,
};

/// Whether [level] clears [floor]; no floor keeps every record.
bool logLevelAtLeast(Object? level, String? floor) =>
    floor == null || logLevelRank(level) >= logLevelRank(floor);
