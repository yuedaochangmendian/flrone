/// The levels the core accepts for its `logLevel` setting, quietest last. The host maps the
/// same names onto logcat's filter spec, so one choice means one level for both tails.
const coreLogLevels = ['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'panic'];

/// What the log screen's recording-level sheet offers: [coreLogLevels] plus `silent`.
///
/// `silent` is client-side. The core has no such level, so choosing it writes `panic` (the
/// core's quietest) to the `logLevel` setting, tails logcat at `*:S`, and drops every kernel
/// line this process filters itself — the app records nothing, without inventing a value the
/// config builder would reject.
const logRecordingLevels = [...coreLogLevels, 'silent'];

/// A record's level as one of [coreLogLevels], normalised for display and ranking.
///
/// The channel already sends words, but the FFI kernel port sends sing-box's numeric
/// `log.Level` (panic 0, fatal 1, error 2, warn 3, info 4, debug 5, trace 6). This
/// normalises both, because a bare number used to reach the screen as the badge text and
/// rank as `info` in every comparison.
String logLevelName(Object? level) {
  if (level is num) {
    return switch (level.toInt()) {
      0 => 'panic',
      1 => 'fatal',
      2 => 'error',
      3 => 'warn',
      4 => 'info',
      5 => 'debug',
      6 => 'trace',
      _ => 'info',
    };
  }
  final name = level?.toString().toLowerCase().trim() ?? '';
  return switch (name) {
    '' => 'info',
    'warning' => 'warn',
    'verbose' => 'trace',
    // Xray spells its quietest level `none`.
    'none' => 'silent',
    _ => name,
  };
}

/// The verbosity order used by the recording-level filter: trace is the most permissive and
/// silent the quietest. An unknown level is treated as info.
int logLevelIndex(Object? level) {
  final name = logLevelName(level);
  final index = logRecordingLevels.indexOf(name);
  return index < 0 ? logRecordingLevels.indexOf('info') : index;
}

/// Whether a line at [level] survives the configured recording level [floor].
///
/// This is the same comparison as the core's `level <= logLevel` check, but
/// expressed in the display order above. The FFI port used to bypass the host
/// sink, so the UI applied no floor at all.
bool logLevelAllowed(Object? level, Object? floor) =>
    logLevelIndex(level) >= logLevelIndex(floor);

/// Severity rank used for the row tone (warn is the first warning-coloured level).
int logLevelRank(Object? level) => switch (logLevelName(level)) {
  'trace' => 0,
  'debug' => 1,
  'warn' => 3,
  'error' => 4,
  'fatal' || 'panic' || 'assert' => 5,
  _ => 2,
};
