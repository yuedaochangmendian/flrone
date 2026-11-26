import 'dart:async';

import 'package:flrone/components/connectivity/connectivity_checker.dart';
import 'package:flrone/components/connectivity/connectivity_store.dart';
import 'package:flutter_test/flutter_test.dart';


/// Controllable checker: each check blocks until the test releases it.
class _GatedChecker extends ConnectivityChecker {
  final Map<String, Completer<MediaUnlockResult>> gates = {};
  final List<String> started = [];

  @override
  Future<MediaUnlockResult> check(String id) {
    started.add(id);
    final completer = Completer<MediaUnlockResult>();
    gates[id] = completer;
    return completer.future;
  }

  void complete(String id, {MediaUnlockStatus status = MediaUnlockStatus.unlocked}) {
    gates.remove(id)!.complete(MediaUnlockResult(status, region: 'US', latencyMs: 10));
  }
}

void main() {
  test('region normalisation follows the reference mapping', () {
    expect(normalizeRegion('US'), 'US');
    expect(normalizeRegion('us'), 'US');
    expect(normalizeRegion('CHN'), 'CN');
    expect(normalizeRegion('HKG'), 'HK');
    expect(normalizeRegion('USA'), 'US');
    expect(normalizeRegion(''), isNull);
    expect(normalizeRegion(null), isNull);
  });

  test('service ids are unique and lookups resolve', () {
    final ids = connectivityServices.map((service) => service.id).toSet();
    expect(ids.length, connectivityServices.length);
    for (final service in connectivityServices) {
      expect(connectivityService(service.id), same(service));
      expect(service.asset, 'assets/images/platforms/${service.id}.svg');
    }
    expect(connectivityService('missing'), isNull);
  });

  test('status classification follows the reference semantics', () {
    expect(const ConnectivityResult(status: ConnectivityStatus.completed).isCompleted, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.limited).isCompleted, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.blocked).isBlocked, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.flagged).isBlocked, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.failed).isBlocked, isTrue);
    expect(const ConnectivityResult(status: ConnectivityStatus.failed).isCompleted, isFalse);
    expect(const ConnectivityResult(status: ConnectivityStatus.completed).isBlocked, isFalse);
  });

  test('unknown service ids fail without a network call', () async {
    final result = await ConnectivityChecker().check('not-a-service');
    expect(result.status, MediaUnlockStatus.failed);
    expect(result.error, 'unknown service');
  });

  test('more-streaming services are exactly the HK four', () {
    expect(connectivityMoreStreaming, {'mytvsuper', 'viutv', 'hoytv', 'rthk'});
    for (final id in connectivityMoreStreaming) {
      expect(connectivityService(id), isNotNull);
    }
  });

  test('runOne queues behind an in-flight sweep without clearing its testing set', () async {
    final checker = _GatedChecker();
    final store = ConnectivityStore(checker: checker);
    // Capture state right after the sweep settles, before the queued retry starts.
    bool sweepSettledCleanly = false;
    void listen() {
      if (!store.running && store.testing.isEmpty &&
          store.results.keys.toSet().containsAll(['openai', 'claude'])) {
        sweepSettledCleanly = true;
      }
    }
    store.addListener(listen);
    // A two-service sweep; concurrency is 8, so both checks are in flight.
    final sweep = store.runAll(ids: ['openai', 'claude']);
    await Future<void>.delayed(Duration.zero);
    expect(checker.started, unorderedEquals(['openai', 'claude']));
    expect(store.running, isTrue);
    expect(store.testing, {'openai', 'claude'});

    // A retry arrives while the sweep is in flight. It must not start its probe
    // until the sweep finishes, nor clear running/testing out of band.
    final retry = store.runOne('openai');
    await Future<void>.delayed(Duration.zero);
    expect(checker.started, unorderedEquals(['openai', 'claude']),
        reason: 'runOne must wait for the sweep instead of interleaving');

    checker.complete('openai');
    checker.complete('claude');
    await sweep;
    await Future<void>.delayed(const Duration(milliseconds: 120)); // 100 ms coalescing timer
    store.removeListener(listen);
    // At the boundary the sweep had settled: no pending testing ids, results kept.
    expect(sweepSettledCleanly, isTrue);
    expect(store.results.keys.toSet(), unorderedEquals(['openai', 'claude']));

    // The retry probe has now started (after the sweep) and replaces its row.
    expect(checker.started, ['openai', 'claude', 'openai']);
    checker.complete('openai', status: MediaUnlockStatus.blocked);
    await retry;
    expect(store.results['openai']!.status, ConnectivityStatus.blocked);
    expect(store.results['claude']!.status, ConnectivityStatus.completed);
    expect(store.running, isFalse);
    expect(store.testing, isEmpty);
    expect(store.testedAt, isNotNull);
  });

  test('a forced sweep and a retry keep state consistent in queue order', () async {
    final checker = _GatedChecker();
    final store = ConnectivityStore(checker: checker);
    final retry = store.runOne('openai');
    await Future<void>.delayed(Duration.zero);
    expect(checker.started, ['openai']);
    checker.complete('openai');
    await retry;
    final sweep = store.runAll(ids: ['claude']);
    await Future<void>.delayed(Duration.zero);
    checker.complete('claude');
    await sweep;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(store.running, isFalse);
    expect(store.testing, isEmpty);
    expect(store.results.keys, containsAll(['openai', 'claude']));
  });
}
