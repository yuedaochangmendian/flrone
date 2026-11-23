// The boot guard's decision model, with an in-memory store and a settable
// clock: no preferences, no device, no platform exit info.

import 'package:flrone/services/boot_guard.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStore implements BootRecordStore {
  BootRecord? record;
  int writes = 0;

  @override
  Future<BootRecord?> read() async => record;

  @override
  Future<void> write(BootRecord record) async {
    this.record = record;
    writes++;
  }
}

class _Clock {
  int now = 1700000000000;
  int call() => now;
  void advance(Duration by) => now += by.inMilliseconds;
}

BootGuard _guard(_MemoryStore store, _Clock clock) =>
    BootGuard(store: store, now: clock.call);

void main() {
  test('a launch with no marker is clean and starts attempts from zero', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    final guard = _guard(store, clock);

    final decision = await guard.evaluate(profileId: 7);

    expect(decision.recovery, BootRecovery.none);
    expect(decision.isDegraded, isFalse);
    expect(decision.failureCount, 0);
    expect(guard.allowsAutoStart, isTrue);
    // The attempt is recorded before any automatic work: that is the marker the
    // next launch reads if this one never reaches markRunning.
    expect(store.record?.stage, BootStage.starting);
    expect(store.record?.profileId, 7);
    expect(store.record?.startedAt, clock.now);
  });

  test('the first launch that never reached the UI degrades the next one', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    await _guard(store, clock).evaluate(profileId: 7);
    // No markRunning: the process died before the UI was up.
    clock.advance(const Duration(seconds: 2));

    final guard = _guard(store, clock);
    final decision = await guard.evaluate(profileId: 7);

    expect(decision.recovery, BootRecovery.skipAutoSetup);
    expect(decision.isDegraded, isTrue);
    expect(decision.failureCount, 1);
    expect(decision.failedProfileId, 7);
    expect(guard.allowsAutoStart, isFalse);
    expect(store.record?.stage, BootStage.starting, reason: 'still unproven');
    expect(store.record?.failureCount, 1);
  });

  test('two unfinished launches in a row clear the remembered profile', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    await _guard(store, clock).evaluate(profileId: 7);
    clock.advance(const Duration(seconds: 2));
    final second = await _guard(store, clock).evaluate(profileId: 7);
    expect(second.recovery, BootRecovery.skipAutoSetup);

    clock.advance(const Duration(seconds: 2));
    final third = await _guard(store, clock).evaluate(profileId: 7);

    expect(third.recovery, BootRecovery.clearProfile);
    expect(third.failureCount, 2);
    expect(third.failedProfileId, 7);
    // Nothing is re-armed for the next launch to read.
    expect(store.record?.stage, BootStage.starting);
    expect(store.record?.profileId, isNull);
    // With no profile left, a further failure cannot clear anything.
    clock.advance(const Duration(seconds: 2));
    final fourth = await _guard(store, clock).evaluate(profileId: null);
    expect(fourth.recovery, BootRecovery.skipAutoSetup);
  });

  test('a marker older than the freshness window is not evidence', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    store.record = BootRecord(
      stage: BootStage.starting,
      profileId: 7,
      startedAt: clock.now - const Duration(hours: 3).inMilliseconds,
      failureCount: 1,
    );

    final decision = await _guard(store, clock).evaluate(profileId: 7);

    expect(decision.recovery, BootRecovery.none);
    expect(decision.stale, isTrue);
    expect(decision.isDegraded, isFalse);
    expect(store.record?.failureCount, 0, reason: 'the count restarts');
    expect(store.record?.profileId, 7);
  });

  test('a marker dated in the future is a clock change, not a launch', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    store.record = BootRecord(
      stage: BootStage.starting,
      profileId: 7,
      startedAt: clock.now + const Duration(minutes: 30).inMilliseconds,
    );

    final decision = await _guard(store, clock).evaluate(profileId: 7);

    expect(decision.recovery, BootRecovery.none);
    expect(decision.stale, isTrue);
  });

  test('markRunning clears the attempt so the next launch is clean', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    final guard = _guard(store, clock);
    await guard.evaluate(profileId: 7);
    expect(store.record?.stage, BootStage.starting);

    clock.advance(const Duration(seconds: 3));
    await guard.markRunning();

    expect(store.record?.stage, BootStage.running);
    expect(store.record?.failureCount, 0);
    expect(store.record?.profileId, 7);

    clock.advance(const Duration(seconds: 30));
    final next = await _guard(store, clock).evaluate(profileId: 7);
    expect(next.recovery, BootRecovery.none);
    expect(next.isDegraded, isFalse);
  });

  test('a degraded launch that reaches the UI keeps its count', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    await _guard(store, clock).evaluate(profileId: 7);
    clock.advance(const Duration(seconds: 2));
    final guard = _guard(store, clock);
    final degraded = await guard.evaluate(profileId: 7);
    expect(degraded.recovery, BootRecovery.skipAutoSetup);

    await guard.markRunning();

    expect(store.record?.stage, BootStage.running);
    expect(
      store.record?.failureCount,
      1,
      reason: 'the count survives a degraded-but-successful launch',
    );
  });

  test('markAttempt is free for a marker that already says the same', () async {
    final store = _MemoryStore();
    final clock = _Clock();
    final guard = _guard(store, clock);
    await guard.evaluate(profileId: 7);
    final startedAt = store.record?.startedAt;
    expect(store.writes, 1);

    clock.advance(const Duration(seconds: 5));
    await guard.markAttempt(profileId: 7);

    expect(store.writes, 1, reason: 'nothing changed, nothing was written');
    expect(store.record?.startedAt, startedAt);
    expect(store.record?.failureCount, 0);

    // A different profile is a different attempt: the marker follows it.
    await guard.markAttempt(profileId: 9);
    expect(store.record?.profileId, 9);
    expect(store.record?.startedAt, clock.now);
    expect(store.record?.failureCount, 0);
  });

  test('the preferences store round-trips one JSON string', () async {
    Object? stored;
    final store = PreferencesBootRecordStore(
      readValue: () => stored,
      writeValue: (value) async => stored = value,
    );
    const record = BootRecord(
      stage: BootStage.starting,
      profileId: 42,
      startedAt: 1234,
      failureCount: 1,
    );

    await store.write(record);
    expect(stored, isA<String>());

    final read = await store.read();
    expect(read?.stage, BootStage.starting);
    expect(read?.profileId, 42);
    expect(read?.startedAt, 1234);
    expect(read?.failureCount, 1);

    stored = 'not json';
    expect(await store.read(), isNull);
    stored = null;
    expect(await store.read(), isNull);
  });
}
