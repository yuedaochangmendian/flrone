// S6 production queue wiring: the service-engine SubscriptionEngine turns the
// pure queue/client into the wire events and host command surface. The refresh
// data path itself is tested in subscription_refresh_test.dart; these tests pin
// the production wiring without HTTP or a document store.

import 'dart:async';

import 'package:flrone/services/subscription_engine.dart';
import 'package:flrone/services/subscription_refresh.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('refresh enqueues, runs once, and emits running/idle wire states', () async {
    final runs = <int>[];
    final events = <Map<String, dynamic>>[];
    final gate = Completer<void>();
    final engine = SubscriptionEngine(
      runRefresh: (gid, surface) async {
        runs.add(gid);
        await gate.future;
        return SubscriptionRefreshResult(
          gid: gid,
          outcome: SubscriptionRefreshOutcome.applied,
          applied: true,
        );
      },
      listGroups: () async => const [
        SubscriptionGroupRef(id: 7, name: 'Sub', url: 'https://example.test/sub'),
      ],
      emit: (type, value) => events.add(<String, dynamic>{'type': type, 'value': value}),
    )..start();

    expect(await engine.refresh(7), isTrue);
    expect(await engine.refresh(7), isFalse, reason: 'per-gid dedupe');
    gate.complete();
    await engine.awaitIdle();

    expect(runs, [7]);
    expect(
      events.where((event) => event['type'] == 'subscriptionState').map((event) => event['value']),
      containsAll(<Map<String, dynamic>>[
        <String, dynamic>{'gid': 7, 'state': 2},
        <String, dynamic>{'gid': 7, 'state': 0},
      ]),
    );
    await engine.dispose();
  });

  test('refreshAll skips archived, empty and (optionally) auto-update-off groups', () async {
    final runs = <int>[];
    final engine = SubscriptionEngine(
      runRefresh: (gid, surface) async {
        runs.add(gid);
        return SubscriptionRefreshResult(gid: gid, outcome: SubscriptionRefreshOutcome.applied);
      },
      listGroups: () async => const [
        SubscriptionGroupRef(id: 1, name: 'A', url: 'https://a.test'),
        SubscriptionGroupRef(id: 2, name: 'B', url: 'https://b.test', skipAutoUpdate: true),
        SubscriptionGroupRef(id: 3, name: 'C', url: ''),
        SubscriptionGroupRef(id: 4, name: 'D', url: 'https://d.test', archive: true),
      ],
      emit: (_, _) {},
    )..start();

    expect(await engine.refreshAll(onlyAllowed: true), isTrue);
    await engine.awaitIdle();
    expect(runs, [1]);
    await engine.dispose();
  });

  test('refreshMany enqueues exactly the due gids, dedupes and awaits idle', () async {
    final runs = <int>[];
    final surfaces = <SubscriptionRefreshSurface>[];
    final gate = Completer<void>();
    final engine = SubscriptionEngine(
      runRefresh: (gid, surface) async {
        runs.add(gid);
        surfaces.add(surface);
        await gate.future;
        return SubscriptionRefreshResult(gid: gid, outcome: SubscriptionRefreshOutcome.applied);
      },
      listGroups: () async => const [
        SubscriptionGroupRef(id: 1, name: 'A', url: 'https://a.test'),
        SubscriptionGroupRef(id: 2, name: 'B', url: 'https://b.test', skipAutoUpdate: true),
        SubscriptionGroupRef(id: 3, name: 'C', url: ''),
        SubscriptionGroupRef(id: 4, name: 'D', url: 'https://d.test', archive: true),
      ],
      emit: (_, _) {},
    )..start();

    // 2 is auto-update-off and 3/4 are ineligible; the engine only runs what it
    // is handed (the scheduler already applied its interval/skip rules), but it
    // still refuses a group that cannot be refreshed and never duplicates a gid.
    var idle = false;
    final pending = engine.refreshMany(const [1, 2, 3, 4, 1], foreground: false);
    pending.then((_) => idle = true);
    await Future<void>.delayed(Duration.zero);
    expect(idle, isFalse, reason: 'refreshMany must span the running queue');
    expect(engine.pendingGids, {1, 2});
    gate.complete();
    await pending;

    expect(idle, isTrue);
    expect(runs, [1, 2]);
    expect(surfaces.every((surface) => surface == SubscriptionRefreshSurface.log), isTrue);
    expect(engine.queuedLength, 0);
    await engine.dispose();
  });

  test('a missing group is not enqueued', () async {
    final engine = SubscriptionEngine(
      runRefresh: (gid, surface) async =>
          SubscriptionRefreshResult(gid: gid, outcome: SubscriptionRefreshOutcome.noop),
      listGroups: () async => const [],
      emit: (_, _) {},
    )..start();
    expect(await engine.refresh(99), isFalse);
    await engine.dispose();
  });
}
