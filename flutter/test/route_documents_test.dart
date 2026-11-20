// The kernel route documents as the backup's route store (ADR 0006 stage A).
//
// These pin the contract `route_store.go` reads: the `{version, name, rows}`
// envelope, atomic replacement, and the restore-side rules — one-sided
// `source_gid` cleanup, the canonical Default seed, and `__current`
// reconciliation (the marker never round-trips through the container).

import 'dart:convert';
import 'dart:io';

import 'package:flrone/services/route_documents.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  late RouteDocuments docs;

  setUp(() {
    root = Directory.systemTemp.createTempSync('route-docs-test-');
    docs = RouteDocuments(root);
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } on Object {
      // best-effort cleanup
    }
  });

  test('an absent document set is "not established" and reads empty', () {
    expect(docs.established, isFalse);
    expect(docs.readAll(), isNull);
    expect(docs.readTable('route_profiles'), isEmpty);
  });

  test('writeTable and readTable round-trip the kernel envelope', () {
    docs.writeTable('route_profiles', [
      {'id': 1, 'name': 'Home', 'is_raw': false},
    ]);
    expect(docs.established, isTrue);
    final raw = jsonDecode(
        File('${root.path}${Platform.pathSeparator}route_profiles.json')
            .readAsStringSync());
    expect(raw['version'], 1);
    expect(raw['name'], 'route_profiles');
    expect(docs.readTable('route_profiles'), [
      {'id': 1, 'name': 'Home', 'is_raw': false},
    ]);
    // The readAll gate keys on route_profiles.json, matching the migration
    // seeder's marker.
    expect(docs.readAll(), {
      'route_profiles': [
        {'id': 1, 'name': 'Home', 'is_raw': false},
      ],
      'route_rules': isEmpty,
    });
  });

  test('restore replaces the whole set and keeps source_gid with profiles', () {
    docs.restore(
      profiles: [
        {'id': 3, 'name': 'Kept', 'is_raw': 0, 'source_gid': 7},
      ],
      rules: [
        {'route_profile_id': 3, 'rule_order': 0, 'name': 'r'},
      ],
      profilesRestored: true,
    );
    final profiles = docs.readTable('route_profiles');
    expect(profiles.single['source_gid'], 7);
    expect(docs.readTable('route_rules').single['name'], 'r');
  });

  test('restore without profiles clears source_gid (one-sided cleanup)', () {
    docs.restore(
      profiles: [
        {'id': 3, 'name': 'Kept', 'is_raw': 0, 'source_gid': 7},
      ],
      rules: const [],
      profilesRestored: false,
    );
    expect(docs.readTable('route_profiles').single['source_gid'], -1);
  });

  test('clearSourceGids patches the surviving set in place', () {
    docs.writeTable('route_profiles', [
      {'id': 3, 'name': 'Kept', 'source_gid': 7},
      {'id': 4, 'name': 'Also', 'source_gid': -1},
    ]);
    docs.clearSourceGids();
    final rows = docs.readTable('route_profiles');
    expect(rows.map((row) => row['source_gid']), [-1, -1]);
  });

  test('a restore with no usable profile seeds the Default chain', () {
    docs.restore(
      profiles: [
        {'id': 5, 'name': 'Raw snapshot', 'is_raw': 1},
      ],
      rules: const [],
      profilesRestored: true,
    );
    final profiles = docs.readTable('route_profiles');
    final rules = docs.readTable('route_rules');
    final seeded = profiles.singleWhere((row) => row['name'] == 'Default');
    expect(seeded['id'], 6);
    expect(seeded['default_outbound_id'], -1);
    expect(seeded['is_raw'], isFalse);
    expect(rules, [
      {
        'route_profile_id': 6,
        'rule_order': 0,
        'name': 'Route DNS',
        'action': 'hijack-dns',
        'protocol': 'dns',
        'type': 0,
      },
    ]);
  });

  test('a usable profile keeps the set unseeded', () {
    docs.restore(
      profiles: [
        {'id': 1, 'name': 'Home', 'is_raw': false},
      ],
      rules: const [],
      profilesRestored: true,
    );
    expect(docs.readTable('route_profiles'), hasLength(1));
    expect(docs.readTable('route_rules'), isEmpty);
  });

  test('__current lands on the restored selection, not anywhere else', () {
    docs.restore(
      profiles: [
        {'id': 1, 'name': 'Old', 'is_raw': 0, '__current': true},
        {'id': 2, 'name': 'New', 'is_raw': 0},
      ],
      rules: const [],
      profilesRestored: true,
      currentRouteId: 2,
    );
    final rows = docs.readTable('route_profiles');
    expect(rows.first['__current'], isNull);
    expect(rows.last['__current'], isTrue);
  });

  test('without a selection the marker falls back to the kernel read', () {
    // currentRouteId unknown (no settings in the container): the rows keep no
    // marker and `currentRouteID` in Go falls back to the first usable.
    docs.restore(
      profiles: [
        {'id': 1, 'name': 'Home', 'is_raw': 0},
      ],
      rules: const [],
      profilesRestored: true,
    );
    expect(docs.readTable('route_profiles').single.containsKey('__current'), isFalse);
  });
}
