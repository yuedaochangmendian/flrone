// Startup-attempt bookkeeping, ported from FlClash's boot guard.
//
// The app writes a marker right before it does its startup work and rewrites it
// as "running" once the UI is really up. A marker that is still "starting" on
// the next launch means the previous launch died before it could announce
// itself: once is an accident (do not repeat the automatic start), twice in a
// row is a crash loop (forget the remembered profile so the app opens without
// it). FlClash layers Android's `getHistoricalExitInfo` on top of this; the
// marker alone must still work, so the freshness window below stands in for
// "was this really the last run" without any platform API.
//
// Pure Dart: the store is injected, so the decision model is testable without
// preferences, a device or a second engine.

import 'dart:convert';

/// How far along a launch got. `starting` is written before the startup work and
/// `running` after the first frame; a marker left at `starting` is the evidence.
///
/// `restarting` is the deliberate relaunch (`BoxController.restartApp`): the
/// launch did not die, it was replaced on purpose, so the next launch treats it
/// as clean — but the host's automatic-start gate blocks on it like `starting`,
/// because the tunnel may still be running when the process goes away.
enum BootStage { starting, running, restarting }

/// What the next launch does differently, from mildest to strongest.
enum BootRecovery {
  /// The previous launch finished, or there was no marker: nothing to correct.
  none,

  /// The previous launch died before the UI came up: keep the app usable, but do
  /// not repeat the automatic start that may be what killed it.
  skipAutoSetup,

  /// Two launches in a row died: also forget the remembered profile, so nothing
  /// re-arms it until the user picks one.
  clearProfile,
}

/// The persisted attempt. Serialized as one JSON string preference, so a partial
/// write leaves the previous value rather than a half-record.
class BootRecord {
  const BootRecord({
    required this.stage,
    this.profileId,
    this.startedAt = 0,
    this.failureCount = 0,
  });

  final BootStage stage;

  /// The profile the attempt would have started, when one was selected. Used to
  /// name the casualty of a crash loop and to decide if clearing means anything
  /// (there is nothing to clear when none was ever selected).
  final int? profileId;

  /// Wall clock (ms) when the attempt began; the freshness window reads it.
  final int startedAt;

  /// Launches in a row that never reached [BootStage.running].
  final int failureCount;

  static BootRecord? fromJson(Object? value) {
    final decoded = switch (value) {
      String raw when raw.isNotEmpty => _decode(raw),
      Map map => map,
      _ => null,
    };
    if (decoded is! Map) return null;
    final name = decoded['stage'];
    BootStage? stage;
    for (final candidate in BootStage.values) {
      if (candidate.name == name) {
        stage = candidate;
        break;
      }
    }
    if (stage == null) return null;
    int? asInt(Object? value) => value is num ? value.toInt() : null;
    return BootRecord(
      stage: stage,
      profileId: asInt(decoded['profileId']),
      startedAt: asInt(decoded['startedAt']) ?? 0,
      failureCount: asInt(decoded['failureCount']) ?? 0,
    );
  }

  static Object? _decode(String raw) {
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'stage': stage.name,
    'profileId': profileId,
    'startedAt': startedAt,
    'failureCount': failureCount,
  };

  String encode() => jsonEncode(toJson());

  BootRecord copyWith({
    BootStage? stage,
    int? profileId,
    bool clearProfile = false,
    int? startedAt,
    int? failureCount,
  }) => BootRecord(
    stage: stage ?? this.stage,
    profileId: clearProfile ? null : (profileId ?? this.profileId),
    startedAt: startedAt ?? this.startedAt,
    failureCount: failureCount ?? this.failureCount,
  );

  @override
  String toString() =>
      'BootRecord(${stage.name}, profile: $profileId, '
      'failures: $failureCount)';
}

/// The one thing the guard needs from storage. Production backs it with the
/// preferences document; tests with a map.
abstract class BootRecordStore {
  Future<BootRecord?> read();

  Future<void> write(BootRecord record);
}

/// Preferences-backed store: one JSON string under [BootGuard.preferenceKey],
/// read synchronously from the controller's current document and written back
/// through its `preferences.set` path.
class PreferencesBootRecordStore implements BootRecordStore {
  PreferencesBootRecordStore({
    required this.readValue,
    required this.writeValue,
  });

  final Object? Function() readValue;
  final Future<void> Function(Object? value) writeValue;

  @override
  Future<BootRecord?> read() async => BootRecord.fromJson(readValue());

  @override
  Future<void> write(BootRecord record) => writeValue(record.encode());
}

/// What the newest [BootGuard.evaluate] decided, for the caller and for a screen
/// that renders the notice.
class BootDecision {
  const BootDecision({
    this.recovery = BootRecovery.none,
    this.failureCount = 0,
    this.failedProfileId,
    this.stale = false,
  });

  final BootRecovery recovery;
  final int failureCount;

  /// The profile the dying launch had selected, when the marker named one.
  final int? failedProfileId;

  /// The marker was too old (or dated in the future) to blame this launch; it is
  /// reported here and then treated as clean, so a clock jump or a device that
  /// sat powered off cannot degrade a healthy launch.
  final bool stale;

  bool get isDegraded => recovery != BootRecovery.none;

  @override
  String toString() =>
      'BootDecision(${recovery.name}, failures: $failureCount, '
      'profile: $failedProfileId, stale: $stale)';
}

/// The startup-attempt state machine.
///
/// Call order, once per launch: [evaluate] (first, before any automatic work),
/// [markAttempt] (immediately before the start it gates) and [markRunning] (once
/// the UI is really up — the first frame, not the first build).
class BootGuard {
  BootGuard({
    required BootRecordStore store,
    int Function()? now,
    this.freshness = const Duration(minutes: 10),
    this.clearThreshold = 2,
  }) : _store = store,
       _now = now ?? _wallClock;

  /// The preferences key holding the encoded [BootRecord].
  static const preferenceKey = 'bootGuardRecord';

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Attempts older than this are not evidence: a process the OS killed hours
  /// after it started does not look like a crash loop, and FlClash has the
  /// platform's exit info for that distinction instead.
  final Duration freshness;

  /// Consecutive unfinished launches that escalate to [BootRecovery.clearProfile]
  /// (FlClash's `crashRecoveryClearThreshold`).
  final int clearThreshold;

  final BootRecordStore _store;
  final int Function() _now;

  BootDecision _decision = const BootDecision();

  /// The profile id of the newest record, so [markAttempt] can carry it when the
  /// caller does not pass one (a start that happens long after [evaluate]).
  int? _lastProfileId;

  BootDecision get decision => _decision;

  /// Whether a launch-time automatic start may run. False on any degraded
  /// decision; the caller starts on the user's tap instead.
  bool get allowsAutoStart => !_decision.isDegraded;

  /// Reads the marker, decides, and records this attempt as `starting`.
  ///
  /// Must run before the launch's automatic work: it is the only chance to see
  /// the previous marker before [markAttempt]/[markRunning] overwrite it.
  Future<BootDecision> evaluate({int? profileId}) async {
    final decision = _resolve(previous: await _store.read());
    _decision = decision;
    final recorded = decision.recovery == BootRecovery.clearProfile
        ? null
        : (profileId ?? _lastProfileId);
    _lastProfileId = recorded;
    await _store.write(
      BootRecord(
        stage: BootStage.starting,
        profileId: recorded,
        startedAt: _now(),
        failureCount: decision.failureCount,
      ),
    );
    return decision;
  }

  /// Re-stamps the current attempt, for a start that happens after [evaluate]
  /// (a user tap, a deferred auto-start). Idempotent: a marker that already
  /// says exactly this is left alone, so calling it right after [evaluate] is
  /// free; the failure count is kept, not incremented — the increment happened
  /// at [evaluate], where a previous marker was actually observed.
  Future<void> markAttempt({int? profileId}) async {
    final target = _decision.recovery == BootRecovery.clearProfile
        ? null
        : (profileId ?? _lastProfileId);
    final current = await _store.read();
    if (current != null &&
        current.stage == BootStage.starting &&
        current.profileId == target &&
        current.failureCount == _decision.failureCount) {
      return;
    }
    _lastProfileId = target;
    await _store.write(
      BootRecord(
        stage: BootStage.starting,
        profileId: target,
        startedAt: _now(),
        failureCount: _decision.failureCount,
      ),
    );
  }

  /// The UI came up: from here a crash is a crash, not a failed launch. The
  /// count is cleared on a clean launch and kept on a degraded one (FlClash's
  /// behaviour: the degraded launch's own crash escalates immediately).
  Future<void> markRunning() async {
    final record = await _store.read();
    if (record == null) return;
    _lastProfileId = record.profileId;
    await _store.write(
      record.copyWith(
        stage: BootStage.running,
        failureCount: _decision.isDegraded ? record.failureCount : 0,
      ),
    );
  }

  BootDecision _resolve({required BootRecord? previous}) {
    // A finished launch and a deliberate restart are both clean; only a marker
    // left at `starting` is evidence of a launch that died on its way up.
    if (previous == null || previous.stage != BootStage.starting) {
      _lastProfileId = previous?.profileId;
      return const BootDecision();
    }
    _lastProfileId = previous.profileId;
    final age = _now() - previous.startedAt;
    final stale = previous.startedAt <= 0 ||
        age > freshness.inMilliseconds ||
        // A marker dated in the future is a clock change, not a launch.
        age < -const Duration(minutes: 1).inMilliseconds;
    if (stale) return const BootDecision(stale: true);
    final failures = previous.failureCount + 1;
    final clear = failures >= clearThreshold && previous.profileId != null;
    return BootDecision(
      recovery: clear ? BootRecovery.clearProfile : BootRecovery.skipAutoSetup,
      failureCount: failures,
      failedProfileId: previous.profileId,
    );
  }
}
