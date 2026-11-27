// The kernel's one global route document as the backup's route store (ADR 0006
// stage A). These pin the `{version, name, rows}` envelope, atomic replacement,
// and the restore-side rule that a container predating the table must leave the
// live document untouched (an empty list genuinely means "no rules"). Legacy
// per-profile route documents are not supported and are ignored.

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

  test('an absent document is "not established" and reads empty', () {
    expect(docs.established, isFalse);
    expect(docs.readAll(), isNull);
    expect(docs.readTable('global_route_rules'), isEmpty);
  });

  test('writeTable and readTable round-trip the kernel envelope', () {
    docs.writeTable('global_route_rules', [
      {'rule_id': 1, 'name': 'Home', 'action': 'route'},
    ]);
    expect(docs.established, isTrue);
    final raw = jsonDecode(
        File('${root.path}${Platform.pathSeparator}global_route_rules.json')
            .readAsStringSync());
    expect(raw['version'], 2);
    expect(raw['name'], 'global_route_rules');
    expect(raw['revision'], 1,
        reason: 'a whole-document write bumps the revision from 0');
    expect(docs.readTable('global_route_rules'), [
      {'rule_id': 1, 'name': 'Home', 'action': 'route'},
    ]);
    expect(docs.readAll(), {
      'global_route_rules': [
        {'rule_id': 1, 'name': 'Home', 'action': 'route'},
      ],
    });
  });

  test('restore replaces the whole table', () {
    docs.writeTable('global_route_rules', [
      {'rule_id': 1, 'name': 'old'},
    ]);
    docs.restore(globalRules: [
      {'rule_id': 2, 'name': 'new'},
    ]);
    expect(docs.readTable('global_route_rules').single['name'], 'new');
  });

  test('restore bumps the revision so a stale editor patch is refused', () {
    final file = File(
        '${root.path}${Platform.pathSeparator}global_route_rules.json');
    docs.writeTable('global_route_rules', [
      {'id': 1, 'name': 'old'},
    ]);
    final before = docs.readRevision('global_route_rules');
    expect(before, 1);
    docs.restore(globalRules: [
      {'id': 2, 'name': 'new'},
    ]);
    expect(docs.readRevision('global_route_rules'), before + 1);
    final raw = jsonDecode(file.readAsStringSync());
    expect(raw['version'], 2);
    expect(raw['revision'], 2);
  });

  test('a v1 document is read at revision 0 and the next write upgrades it', () {
    final file = File(
        '${root.path}${Platform.pathSeparator}global_route_rules.json');
    file.writeAsStringSync(jsonEncode({
      'version': 1,
      'name': 'global_route_rules',
      'rows': [
        {'id': 9, 'name': 'legacy'}
      ],
    }));
    expect(docs.readRevision('global_route_rules'), 0);
    expect(docs.readTable('global_route_rules').single['name'], 'legacy');
    docs.restore(globalRules: [
      {'id': 10, 'name': 'new'},
    ]);
    expect(docs.readRevision('global_route_rules'), 1);
    expect(jsonDecode(file.readAsStringSync())['version'], 2);
  });

  test('restore with null leaves the live table alone; empty clears it', () {
    docs.writeTable('global_route_rules', [
      {'rule_id': 1, 'name': 'kept'},
    ]);
    docs.restore();
    expect(docs.readTable('global_route_rules').single['name'], 'kept');
    docs.restore(globalRules: const []);
    expect(docs.readTable('global_route_rules'), isEmpty);
  });

  test('a snapshot puts the exact previous bytes back', () {
    docs.writeTable('global_route_rules', [
      {'rule_id': 1, 'name': 'old-global'},
    ]);
    final before = File(
      '${root.path}${Platform.pathSeparator}global_route_rules.json',
    ).readAsStringSync();
    final snapshot = docs.snapshot();
    expect(snapshot.hadDocuments, isTrue);

    docs.restore(globalRules: [
      {'rule_id': 2, 'name': 'new-global'},
    ]);
    expect(docs.readTable('global_route_rules').single['name'], 'new-global');

    expect(docs.restoreSnapshot(snapshot),
        'The previous route document was restored.');
    expect(
      File('${root.path}${Platform.pathSeparator}global_route_rules.json')
          .readAsStringSync(),
      before,
    );
    expect(docs.readTable('global_route_rules').single['name'], 'old-global');
  });

  test('a snapshot of an absent document removes what a failed replace created', () {
    final snapshot = docs.snapshot();
    expect(snapshot.hadDocuments, isFalse);
    expect(snapshot.contents.values.every((raw) => raw == null), isTrue);
    expect(
      docs.restoreSnapshot(snapshot),
      'The route document did not exist before this restore and none was created.',
    );
    expect(docs.established, isFalse);

    docs.restore(globalRules: const []);
    final note = docs.restoreSnapshot(snapshot);
    expect(note, contains('did not exist before this restore'));
    expect(note, contains('was removed'));
    expect(docs.established, isFalse);
    for (final table in routeDocumentTables) {
      expect(
        File('${root.path}${Platform.pathSeparator}$table.json').existsSync(),
        isFalse,
        reason: table,
      );
    }
  });
}
