/// The levels the core accepts for its `logLevel` setting, quietest last. The log screen's
/// recording-level sheet offers exactly these, and the host maps the same names onto
/// logcat's filter spec, so one choice means one level for both tails.
const coreLogLevels = ['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'panic'];

/// A record's level as one of [coreLogLevels], normalised for display and ranking.
///
/// The channel already sends words, but the FFI kernel port sends sing-box's numeric
/// `log.Level` (trace 0, debug 1, info 2, warn 3, error 4, fatal 5, panic 6). This
/// normalises both, because a bare number used to reach the screen as the badge text and
/// rank as `info` in every comparison.
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

/// Severity rank used for the row tone (warn is the first warning-coloured level).
int logLevelRank(Object? level) => switch (logLevelName(level)) {
  'trace' => 0,
  'debug' => 1,
  'warn' => 3,
  'error' => 4,
  'fatal' || 'panic' || 'assert' => 5,
  _ => 2,
};
