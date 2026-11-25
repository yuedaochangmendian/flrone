// What a rule row says about its conditions.
//
// The kernel writes every list condition as `<name>_json` and mirrors only five of them under
// the short name (`wireRules`). A row that read the short name alone therefore showed
// "No conditions" for a rule whose only condition was e.g. a rule set — the screenshot that
// started this.

import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
