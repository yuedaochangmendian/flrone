import 'package:flrone/common/egress_cache.dart';
import 'package:flutter_test/flutter_test.dart';

const _version = 7;
const _key = EgressKey(routeVersion: _version, outbound: '3:proxy:A');

void main() {
  late DateTime now;
  late EgressCache cache;
  setUp(() {
    now = DateTime.utc(2026, 11, 23, 12);
    cache = EgressCache(now: () => now);
  });

  test('a key is the route version plus the selected outbound', () {
    expect(
      const EgressKey(routeVersion: 7, outbound: 'a'),
      const EgressKey(routeVersion: 7, outbound: 'a'),
    );
    expect(
      const EgressKey(routeVersion: 7, outbound: 'a'),
      isNot(const EgressKey(routeVersion: 8, outbound: 'a')),
    );
    expect(
      const EgressKey(routeVersion: 7, outbound: 'a'),
      isNot(const EgressKey(routeVersion: 7, outbound: 'b')),
    );
  });

  test('the outbound identity ignores group order and follows the selection', () {
    final groups = <Map<String, dynamic>>[
      {'tag': 'proxy', 'selected': 'A'},
      {'tag': 'auto', 'selected': 'proxy'},
    ];
    final reversed = groups.reversed.toList();
    expect(
      egressOutboundIdentity(groups: groups, profileId: 3),
      egressOutboundIdentity(groups: reversed, profileId: 3),
    );
    expect(
      egressOutboundIdentity(groups: groups, profileId: 3),
      isNot(egressOutboundIdentity(groups: groups, profileId: 4)),
    );
    expect(
      egressOutboundIdentity(groups: groups, profileId: 3),
      isNot(
        egressOutboundIdentity(
          groups: [
            {'tag': 'proxy', 'selected': 'B'},
            {'tag': 'auto', 'selected': 'proxy'},
          ],
          profileId: 3,
        ),
      ),
    );
  });

  group('answers', () {
    test('a stored answer is a hit until exactly the TTL', () {
      cache.store(_key, {'ip': '203.0.113.9'});
      final hit = cache.read(_key);
      expect(hit, isA<EgressHit>());
      expect((hit as EgressHit).answer['ip'], '203.0.113.9');

      now = now.add(EgressCache.maxAge - const Duration(milliseconds: 1));
      expect(cache.read(_key), isA<EgressHit>());

      now = now.add(const Duration(milliseconds: 1));
      expect(cache.read(_key), isA<EgressMiss>());
    });

    test('hits hand out copies, and storing copies too', () {
      final source = <String, dynamic>{'ip': '203.0.113.9'};
      cache.store(_key, source);
      source['ip'] = '198.51.100.2';
      final first = cache.read(_key) as EgressHit;
      expect(first.answer['ip'], '203.0.113.9');

      first.answer['ip'] = '198.51.100.2';
      expect((cache.read(_key) as EgressHit).answer['ip'], '203.0.113.9');
    });

    test('an invalidated answer is a miss', () {
      cache.store(_key, {'ip': '203.0.113.9'});
      cache.invalidate(_key);
      expect(cache.read(_key), isA<EgressMiss>());
    });
  });

  group('throttle', () {
    test('an attempt blocks the same key for five seconds', () {
      cache.noteAttempt(_key);
      final throttled = cache.read(_key);
      expect(throttled, isA<EgressThrottled>());
      expect((throttled as EgressThrottled).retryAfter, EgressCache.throttle);

      now = now.add(EgressCache.throttle - const Duration(milliseconds: 1));
      expect(
        (cache.read(_key) as EgressThrottled).retryAfter,
        const Duration(milliseconds: 1),
      );

      now = now.add(const Duration(milliseconds: 1));
      expect(cache.read(_key), isA<EgressMiss>());
    });

    test('another key is not throttled by it', () {
      cache.noteAttempt(_key);
      expect(
        cache.read(const EgressKey(routeVersion: _version, outbound: 'other')),
        isA<EgressMiss>(),
      );
    });

    test('an answer replaces the attempt it belongs to', () {
      cache.noteAttempt(_key);
      now = now.add(const Duration(milliseconds: 300));
      cache.store(_key, {'ip': '203.0.113.9'});
      expect(cache.read(_key), isA<EgressHit>());
    });
  });

  group('failures', () {
    test('a failure is reused only for the failure cooldown', () {
      cache.noteAttempt(_key);
      now = now.add(const Duration(milliseconds: 200));
      cache.storeFailure(_key, 'IP check failed');
      final failed = cache.read(_key);
      expect(failed, isA<EgressFailed>());
      expect((failed as EgressFailed).message, 'IP check failed');
      expect(failed.retryAfter, EgressCache.failureCooldown);

      now = now.add(EgressCache.failureCooldown - const Duration(milliseconds: 1));
      expect(cache.read(_key), isA<EgressFailed>());

      now = now.add(const Duration(milliseconds: 1));
      expect(cache.read(_key), isA<EgressMiss>());
    });

    test('a success replaces a failure', () {
      cache.noteAttempt(_key);
      cache.storeFailure(_key, 'IP check failed');
      cache.store(_key, {'ip': '203.0.113.9'});
      expect(cache.read(_key), isA<EgressHit>());
    });
  });

  group('invalidation', () {
    test('a route version change drops every older entry', () {
      final older = const EgressKey(routeVersion: 7, outbound: 'a');
      final newer = const EgressKey(routeVersion: 8, outbound: 'a');
      cache.store(older, {'ip': '203.0.113.9'});
      cache.store(newer, {'ip': '198.51.100.2'});

      cache.noteRoute(8);
      expect(cache.read(older), isA<EgressMiss>());
      expect((cache.read(newer) as EgressHit).answer['ip'], '198.51.100.2');
    });

    test('a wire without the stamp does not clear the cache', () {
      cache.store(_key, {'ip': '203.0.113.9'});
      cache.noteRoute(null);
      expect(cache.read(_key), isA<EgressHit>());
    });

    test('entries are bounded, oldest first', () {
      final keys = [
        for (var i = 0; i < EgressCache.maxEntries + 1; i++)
          EgressKey(routeVersion: _version, outbound: 'chain-$i'),
      ];
      for (final key in keys) {
        cache.noteAttempt(key);
        cache.store(key, {'ip': '203.0.113.9'});
      }
      expect(cache.read(keys.first), isA<EgressMiss>());
      for (final key in keys.skip(1)) {
        expect(cache.read(key), isA<EgressHit>());
      }
    });
  });
}
