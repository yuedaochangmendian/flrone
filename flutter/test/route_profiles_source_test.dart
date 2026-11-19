// ADR 0005 phase 3: Go is the single writer/authority for the route documents,
// so this data-plane source has NO channel fallback. Every way SQLite can be
// absent must now surface a clear [RouteProfilesUnavailable] rather than a
// stale `routes.list` snapshot. These tests inject a fake reader, so no
// database and no MethodChannel are involved — the default `DataLayer.attach`
// is exercised only for the failures that return before sqlite is opened.

import 'package:flrone/data/data_layer.dart' show AttachFailure;
import 'package:flrone/data/route_profiles_source.dart';
import 'package:flutter_test/flutter_test.dart';

RouteProfilesWire validWire() => <String, Object?>{
      'currentId': 1,
      'profiles': [
        <String, Object?>{
          'id': 1,
          'name': 'Default',
          'current': true,
          'isRemote': false,
          'isRaw': false,
          'ruleCount': 3,
          'simpleRuleCount': 1,
        },
      ],
    };

class FakeReader implements RouteProfilesReader {
  FakeReader(this.wire, {this.throwOnRead = false});

  final RouteProfilesWire wire;
  final bool throwOnRead;
  int reads = 0;
  int closes = 0;

  @override
  RouteProfilesWire listWire() {
    reads++;
    if (throwOnRead) throw StateError('SQL failed');
    return wire;
  }

  @override
  void close() {
    closes++;
  }
}

/// Every constructor no longer takes a channelFallback: build one with the
/// test attach (or omit it to use the real DataLayer.attach for failures that
/// return before sqlite is opened) and assert the reply or thrown error.
RouteProfilesSource sourceWith(
  RouteProfilesAttach? attach, {
  Future<dynamic> Function()? resolvePath,
}) =>
    RouteProfilesSource(
      resolvePath: resolvePath ?? (() async => {'path': '/tmp/x.db', 'version': 19}),
      attach: attach,
    );

void main() {
  group('RouteProfilesSource', () {
    test('a valid SQLite answer is returned', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      final source = sourceWith((_, {onFailure}) async => reader);

      expect(await source.list(), same(wire));
      expect(reader.reads, 1);
      expect(reader.closes, 0);
    });

    test('concurrent first reads share one attach', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attaches = 0;
      final source = sourceWith((_, {onFailure}) async {
        attaches++;
        // A real attach awaits the channel; let the second read overlap it.
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return reader;
      });

      final first = source.list();
      final second = source.list();
      expect(await first, same(wire));
      expect(await second, same(wire));
      expect(attaches, 1,
          reason: 'the loser of the attach race used to leak its connection');
      expect(reader.reads, 2);
    });

    test('a reader that fails mid-read is closed, demoted, and errors', () async {
      final bad = FakeReader(validWire(), throwOnRead: true);
      var attaches = 0;
      final source = sourceWith((_, {onFailure}) async {
        attaches++;
        return bad;
      });

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      expect(bad.closes, 1, reason: 'a broken reader must not stay cached');

      // SQL cannot heal inside this run: no re-attach, always the same error.
      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      expect(attaches, 1);
      expect(bad.reads, 1);
    });

    test('an attach answering null throws a visible error', () async {
      final source = sourceWith((_, {onFailure}) async => null);

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });

    test('an exception during attach throws a visible error', () async {
      final source = sourceWith(
        (_, {onFailure}) async => throw StateError('libsqlite3 missing'),
      );

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });

    test('an empty profile list throws instead of using stale data', () async {
      final source = sourceWith((_, {onFailure}) async => FakeReader(
            <String, Object?>{
              'currentId': 1,
              'profiles': <Object?>[],
            },
          ));

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });

    test('a malformed answer without currentId throws', () async {
      final source = sourceWith((_, {onFailure}) async => FakeReader(
            <String, Object?>{'profiles': validWire()['profiles']},
          ));

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });

    test('a healthy reader is reused across reads', () async {
      final reader = FakeReader(validWire());
      var attaches = 0;
      final source = sourceWith((_, {onFailure}) async {
        attaches++;
        return reader;
      });

      await source.list();
      await source.list();

      expect(attaches, 1);
      expect(reader.reads, 2);
    });

    test('dispose closes the connection and later reads throw', () async {
      final reader = FakeReader(validWire());
      final source = sourceWith((_, {onFailure}) async => reader);

      await source.list();
      source.dispose();

      expect(reader.closes, 1);
      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });
  });

  group('attach retry and invalidation', () {
    test('a transient failure (cold-start data.path race) is retried on the next read', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attempts = 0;
      final source = sourceWith(
        (resolve, {onFailure}) async {
          attempts++;
          if (attempts < 2) {
            onFailure?.call(AttachFailure.hostPath);
            return null;
          }
          return reader;
        },
        resolvePath: () async => null,
      );

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      expect(await source.list(), same(wire));
      expect(attempts, 2);
    });

    test('a schema version mismatch is permanent: no retry, not even retryFailed()', () async {
      var attempts = 0;
      final source = sourceWith(
        (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.schemaVersion);
          return null;
        },
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 18},
      );

      for (var i = 0; i < 3; i++) {
        await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      }
      source.retryFailed();
      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));

      expect(attempts, 1);
    });

    test('transient attempts are capped', () async {
      var attempts = 0;
      final source = sourceWith(
        (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.hostPath);
          return null;
        },
        resolvePath: () async => null,
      );

      for (var i = 0; i < 5; i++) {
        await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      }

      expect(attempts, 3);
    });

    test('retryFailed() restarts the transient budget', () async {
      var attempts = 0;
      final source = sourceWith(
        (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.hostPath);
          return null;
        },
        resolvePath: () async => null,
      );

      for (var i = 0; i < 5; i++) {
        await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      }
      expect(attempts, 3);

      source.retryFailed();
      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      expect(attempts, 4);
    });

    test('retryFailed() does not touch a healthy reader', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attaches = 0;
      final source = sourceWith((_, {onFailure}) async {
        attaches++;
        return reader;
      });

      await source.list();
      await source.list();
      source.retryFailed();
      await source.list();

      expect(attaches, 1);
      expect(reader.reads, 3);
      expect(reader.closes, 0);
    });

    test('invalidate() closes the reader and the next read re-attaches', () async {
      final first = FakeReader(validWire());
      final second = FakeReader(validWire());
      final readers = [first, second];
      var attaches = 0;
      final source = sourceWith((_, {onFailure}) async => readers[attaches++]);

      await source.list();
      source.invalidate();

      expect(first.closes, 1);

      await source.list();
      expect(attaches, 2);
      expect(second.reads, 1);
    });

    test('invalidate() does not revive a permanent failure', () async {
      var attempts = 0;
      final source = sourceWith(
        (resolve, {onFailure}) async {
          attempts++;
          onFailure?.call(AttachFailure.schemaVersion);
          return null;
        },
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 18},
      );

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      source.invalidate();
      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));

      expect(attempts, 1);
    });

    test('an openFailed attach is retried like a transient one', () async {
      final wire = validWire();
      final reader = FakeReader(wire);
      var attempts = 0;
      final source = sourceWith((resolve, {onFailure}) async {
        attempts++;
        if (attempts < 2) {
          onFailure?.call(AttachFailure.openFailed);
          return null;
        }
        return reader;
      });

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
      expect(await source.list(), same(wire));
      expect(attempts, 2);
    });
  });

  group('DataLayer.attach failures (no sqlite opened)', () {
    // These failures all return before `Sqlite.open()`, so the real default
    // attach can be exercised on the host without a native library. No channel
    // is consulted: the error must be visible (ADR 0005 phase 3).

    test('a host that throws for data.path raises a visible error', () async {
      final source = sourceWith(null, resolvePath: () async => throw StateError('no host'));

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });

    test('a null data.path reply raises a visible error', () async {
      final source = sourceWith(null, resolvePath: () async => null);

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });

    test('a schema version this build does not know raises a visible error', () async {
      final source = sourceWith(
        null,
        resolvePath: () async => {'path': '/tmp/x.db', 'version': 18},
      );

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });

    test('a data.path reply without a path raises a visible error', () async {
      final source = sourceWith(null, resolvePath: () async => {'version': 19});

      await expectLater(source.list(), throwsA(isA<RouteProfilesUnavailable>()));
    });
  });
}
