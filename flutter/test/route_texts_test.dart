// What a rule row says about its conditions, and what the import path spells on the wire.
//
// The kernel writes every list condition as `<name>_json` and mirrors only five of them under
// the short name (`wireRules`). A row that read the short name alone therefore showed
// "No conditions" for a rule whose only condition was e.g. a rule set — the screenshot that
// started this. The import side had the mirror-image bug: it sent editor-shaped maps, whose
// short names `ruleRowFromWire` stores verbatim outside its five aliases, so the stored
// `rule_set_json` stayed empty and the rule built as a match-all.

import 'dart:async';

import 'package:flrone/core/action.dart';
import 'package:flrone/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_route_kernel.dart';
import 'support/test_app.dart';

void main() {
  /// A context below PrismApp, which is what `tr` and the row styles read.
  Future<BuildContext> context(WidgetTester tester) async {
    late BuildContext found;
    await tester.pumpWidget(TestApp(child: Builder(builder: (context) {
      found = context;
      return const SizedBox.shrink();
    })));
    return found;
  }

  group('ruleConditions', () {
    testWidgets('reads a column-named list the wire carries', (tester) async {
      final box = await context(tester);
      // The exact shape `wireRules` answers for a rule whose only condition is a rule set.
      final rule = <String, dynamic>{
        'name': 'CN',
        'action': 'route',
        'outbound_id': -2,
        'rule_set_json': ['geoip-cn', 'geosite-cn', 'geosite-cn-extra'],
      };
      expect(ruleConditions(box, rule), 'rule-set: geoip-cn +2');
    });

    testWidgets('still reads the five short names the kernel aliases', (tester) async {
      final box = await context(tester);
      expect(ruleConditions(box, {'domain': ['a.test']}), 'domain: a.test');
      expect(ruleConditions(box, {'domain_suffix': ['a.test', 'b.test']}), 'suffix: a.test +1');
      expect(ruleConditions(box, {'ip_cidr': ['10.0.0.0/8']}), 'ip: 10.0.0.0/8');
      expect(ruleConditions(box, {'process_name': ['curl']}), 'process: curl');
      expect(ruleConditions(box, {'network_type': ['wifi']}), 'network type: wifi');
    });

    testWidgets('prefers the column when a rule carries both spellings', (tester) async {
      final box = await context(tester);
      final rule = <String, dynamic>{
        'domain_suffix': ['stale.test'],
        'domain_suffix_json': ['live.test'],
      };
      expect(ruleConditions(box, rule), 'suffix: live.test');
    });

    testWidgets('every column-named list renders, not just the aliases', (tester) async {
      final box = await context(tester);
      expect(ruleConditions(box, {'domain_keyword_json': ['ads']}), 'keyword: ads');
      expect(ruleConditions(box, {'port_json': ['80']}), 'port: 80');
      expect(ruleConditions(box, {'package_name_json': ['com.example']}), 'app: com.example');
      expect(ruleConditions(box, {'wifi_ssid_json': ['home']}), 'ssid: home');
    });

    testWidgets('a rule with no conditions still says so', (tester) async {
      final box = await context(tester);
      expect(ruleConditions(box, {'action': 'route', 'outbound_id': -2}), 'No conditions');
    });
  });

  group('ruleName', () {
    testWidgets('falls back to the first value under either spelling', (tester) async {
      final box = await context(tester);
      expect(ruleName({'rule_set_json': ['geoip-cn']}, 0), 'geoip-cn');
      expect(ruleName({'rule_set': ['geoip-cn']}, 0), 'geoip-cn');
      expect(ruleName({'package_name_json': ['com.example']}, 0), 'com.example');
      expect(ruleName({'name': 'Named', 'rule_set_json': ['x']}, 0), 'Named');
      expect(ruleName({'action': 'route'}, 2), '#3');
      expect(box, isNotNull);
    });
  });

  group('import canonicalisation', () {
    test('a rule map becomes the column spelling the store reads', () {
      final stored = routeRulesForStore([
        {
          'name': 'CN',
          'type': 'custom',
          'action': 'route',
          'outbound_id': -2,
          'rule_set': ['geoip-cn'],
          'domain': ['a.test'],
          'domain_keyword': ['ads'],
          'port': ['443'],
        },
      ]).single;
      // Every list is a `_json` column; the store and the config generator read only those.
      expect(stored['rule_set_json'], ['geoip-cn']);
      expect(stored['domain_json'], ['a.test']);
      expect(stored['domain_keyword_json'], ['ads']);
      expect(stored['port_json'], ['443']);
      for (final key in ['rule_set', 'domain', 'domain_keyword', 'port']) {
        expect(stored.containsKey(key), isFalse, reason: '$key must not be sent alongside its column');
      }
      // The scalars and metadata are untouched.
      expect(stored['action'], 'route');
      expect(stored['outbound_id'], -2);
      expect(stored['type'], 'custom');
    });

    test('a parsed share document is canonicalised on the way to the store', () {
      final document = parseRouteDocument(
        '{"kind":"throne-route-profile","name":"Bypass China","default_outbound":"direct",'
        '"rules":[{"action":"route","outbound":"direct","rule_set":["geoip-cn","geosite-cn"],'
        '"domain_keyword":["baidu"]}]}',
      );
      expect(document, isNotNull);
      // The parsed document stays editor-shaped: the rule page edits the short names.
      expect(document!.rules.single['rule_set'], ['geoip-cn', 'geosite-cn']);

      final stored = routeRulesForStore(document.rules).single;
      expect(stored['rule_set_json'], ['geoip-cn', 'geosite-cn']);
      expect(stored['domain_keyword_json'], ['baidu']);
      expect(stored['outbound_id'], -2);
      expect(stored['rule_set'], isNull);
    });

    test('empty conditions are left out rather than sent as empty columns', () {
      final stored = routeRulesForStore([
        {'name': 'Noop', 'type': 'custom', 'action': 'reject', 'rule_set': <String>[]},
      ]).single;
      expect(stored.containsKey('rule_set_json'), isFalse);
      expect(stored['action'], 'reject');
    });
  });

  group('the import save path', () {
    /// The wire a save actually sends, through the same fake kernel the routing screen's
    /// tests attach: what the store receives is what `handleSaveRouteRules` decodes.
    test('writes column-named lists for an imported document', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final savedRules = <Map<String, dynamic>>[];
      final savedProfiles = <Map<String, dynamic>>[];

      Object? handler(ActionMethod method, Object? data) {
        switch (method) {
          case ActionMethod.saveRouteProfile:
            savedProfiles.add(Map<String, Object?>.from(data as Map));
            return 9;
          case ActionMethod.saveRouteRules:
            savedRules.addAll([
              for (final entry in (data as Map)['rules'] as List)
                Map<String, dynamic>.from(entry as Map),
            ]);
            return {'rules': savedRules};
          default:
            return null;
        }
      }

      const channel = MethodChannel('test.route-texts');
      final events = StreamController<dynamic>.broadcast();
      final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      addTearDown(() async {
        await events.close();
        messenger.setMockMethodCallHandler(channel, null);
      });
      final box = BoxController(channel: channel, events: events.stream);
      box.kernel.debugAttach(FakeRouteKernel(handler), NoopKernelWorker());
      addTearDown(box.dispose);

      final document = parseRouteDocument(
        '{"kind":"throne-route-profile","name":"Bypass China","default_outbound":"direct",'
        '"rules":[{"action":"route","outbound":"direct","rule_set":["geoip-cn","geosite-cn"]}]}',
      )!;
      expect(await saveImportedProfile(box, document), 9);

      expect(savedProfiles, hasLength(1));
      expect(savedRules, hasLength(1));
      final wire = savedRules.single;
      expect(wire['rule_set_json'], ['geoip-cn', 'geosite-cn']);
      expect(wire['rule_set'], isNull, reason: 'the short name would land beside an empty column');
    });
  });
}
