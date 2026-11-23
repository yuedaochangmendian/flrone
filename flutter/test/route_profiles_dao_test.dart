// The point of these tests is the wire shape. `BboxRoutes.list()` fixes it, and
// a SQL answer that differs by one key or one count would make the SQLite path
// visible to the screen. No database is opened here: a [Queryable] fake answers
// with fixed rows.
//
// Schema 21 retired Room's `settings` table (ADR 0006 stage C2b), so the
// selection is an argument now and no DAO SQL may name `settings`/`markers`.

import 'package:flrone/data/route_profiles_dao.dart';
import 'package:flrone/data/sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every query with the profile rows; the retired tables must never be
/// queried, which [queries] lets each test assert.
class FakeDb implements Queryable {
  FakeDb({this.profileRows = const []});

  final List<SqlRow> profileRows;
  final List<String> queries = [];
  final List<List<Object?>> params = [];

  @override
  List<SqlRow> query(String sql, [List<Object?> params = const []]) {
    queries.add(sql);
    this.params.add(params);
    return profileRows;
  }
}

void main() {
  group('RouteProfilesDao SQL', () {
    test('list orders by id like RouteDao.allProfiles()', () {
      final db = FakeDb();
      RouteProfilesDao(db).list();

      expect(db.queries.single, contains('FROM route_profiles'));
      expect(db.queries.single, contains('ORDER BY p.id'));
    });

    test('a profile with no rules is kept, with zero counts', () {
      final db = FakeDb();
      RouteProfilesDao(db).list();

      // LEFT JOIN, not INNER JOIN: a profile without rules must not vanish.
      expect(db.queries.single, contains('LEFT JOIN route_rules'));
      expect(db.queries.single, contains('COUNT(r.route_profile_id)'));
      expect(db.queries.single, contains('COALESCE('));
    });

    test('only the four simple address rule types are counted as simple', () {
      final db = FakeDb();
      RouteProfilesDao(db).list();

      expect(db.queries.single, contains('IN (1, 2, 3, 10)'));
      expect(simpleAddressRuleTypes, [1, 2, 3, 10]);
    });

    test('no DAO statement names the retired settings/markers tables', () {
      final db = FakeDb();
      RouteProfilesDao(db).listWire();

      expect(db.queries, isNotEmpty);
      for (final sql in db.queries) {
        expect(sql, isNot(contains('settings')));
        expect(sql, isNot(contains('markers')));
      }
    });
  });

  group('RouteProfileRow mapping', () {
    test('a complete row maps every field', () {
      final row = RouteProfileRow.fromRow({
        'id': 7,
        'name': 'Tokyo',
        'is_remote': 1,
        'is_raw': 0,
        'rule_count': 5,
        'simple_rule_count': 2,
      });

      expect(row.id, 7);
      expect(row.name, 'Tokyo');
      expect(row.isRemote, isTrue);
      expect(row.isRaw, isFalse);
      expect(row.ruleCount, 5);
      expect(row.simpleRuleCount, 2);
    });

    test('Room booleans are 0/1 and migration-added columns can be null', () {
      final row = RouteProfileRow.fromRow({
        'id': 1,
        'name': null,
        'is_remote': null,
        'is_raw': 1,
        'rule_count': null,
        'simple_rule_count': null,
      });

      expect(row.name, '');
      expect(row.isRemote, isFalse);
      expect(row.isRaw, isTrue);
      expect(row.ruleCount, 0);
      expect(row.simpleRuleCount, 0);
    });

    test('a missing row does not throw', () {
      final row = RouteProfileRow.fromRow({});

      expect(row.id, 0);
      expect(row.name, '');
      expect(row.isRemote, isFalse);
    });

    test('toWire matches one BboxRoutes.list() entry exactly', () {
      final row = RouteProfileRow(
        id: 4,
        name: 'Work',
        defaultOutbound: 'proxy',
        isRemote: true,
        isRaw: false,
        ruleCount: 9,
        simpleRuleCount: 3,
      );

      expect(row.toWire(4), {
        'id': 4,
        'name': 'Work',
        'defaultOutbound': 'proxy',
        'current': true,
        'isRemote': true,
        'isRaw': false,
        'ruleCount': 9,
        'simpleRuleCount': 3,
      });
      expect(row.toWire(1)['current'], isFalse);
    });
  });

  group('current_route_id decoding', () {
    test('settings stores decimal text', () {
      expect(RouteProfileRow.parseCurrentId('3'), 3);
      expect(RouteProfileRow.parseCurrentId(' 12 '), 12);
    });

    test('an integer shape is accepted too', () {
      expect(RouteProfileRow.parseCurrentId(7), 7);
    });

    test('missing, unparsable and non-positive values use the registry default', () {
      expect(RouteProfileRow.parseCurrentId(null), defaultCurrentRouteId);
      expect(RouteProfileRow.parseCurrentId('nope'), defaultCurrentRouteId);
      expect(RouteProfileRow.parseCurrentId('0'), defaultCurrentRouteId);
      expect(RouteProfileRow.parseCurrentId('-2'), defaultCurrentRouteId);
      expect(defaultCurrentRouteId, 1);
    });
  });

  group('listWire', () {
    test('reproduces the whole routes.list reply', () {
      final db = FakeDb(
        profileRows: [
          {'id': 1, 'name': 'Default', 'is_remote': 0, 'is_raw': 0,
            'rule_count': 4, 'simple_rule_count': 1},
          {'id': 2, 'name': 'Remote', 'is_remote': 1, 'is_raw': 1,
            'rule_count': 0, 'simple_rule_count': 0},
        ],
      );

      // The selection is the caller's now (the settings document, not Room).
      final wire = RouteProfilesDao(db).listWire(currentRouteId: '2');

      expect(wire['currentId'], 2);
      expect(wire['profiles'], isA<List>());
      final profiles = wire['profiles']! as List;
      expect(profiles, hasLength(2));
      expect(profiles.first, {
        'id': 1, 'name': 'Default', 'defaultOutbound': 'direct', 'current': false,
        'isRemote': false, 'isRaw': false,
        'ruleCount': 4, 'simpleRuleCount': 1,
      });
      expect(profiles.last['current'], isTrue);
      expect(profiles.last['isRaw'], isTrue);
    });

    test('an empty table is reported as empty', () {
      final db = FakeDb();

      final wire = RouteProfilesDao(db).listWire();

      expect(wire['currentId'], defaultCurrentRouteId);
      expect(wire['profiles'], isEmpty);
    });
  });
}
