// Rule-editor field validation. Manual entry is the only input since 4.17.0
// dropped external import, so these pure-function checks are the line between
// a typo and a rule the kernel silently misreads. No widget tree needed.

import 'package:flrone/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

String describe(RuleFieldIssue issue) => issue.describe((key) => key);

void main() {
  group('validateRuleFields', () {
    test('accepts an empty rule and well-formed values', () {
      expect(validateRuleFields(<String, dynamic>{}), isNull);
      expect(validateRuleFields({
        'ip_cidr': ['10.0.0.0/8', '2001:db8::/32', '192.168.1.1'],
        'source_ip_cidr': ['172.16.0.0/12'],
        'port': ['80', '443', '1'],
        'source_port': ['1024', '65535'],
        'port_range': ['1000:2000', '100-200'],
        'source_port_range': ['3000:4000'],
        'domain_regex': [r'^ads[0-9]+\.example\.com$'],
        'package_name_regex': [r'^com\.example\..*'],
        'process_path_regex': [r'^/usr/bin/.+'],
        'process_name_regex': [r'^curl$'],
        'override_port': '8080',
        'tls_fragment_fallback_delay': '500ms',
      }), isNull);
    });

    test('rejects invalid IPv4/IPv6 CIDR and names the line', () {
      final issue = validateRuleFields({
        'ip_cidr': ['10.0.0.0/8', '999.1.1.1/24'],
      });
      expect(issue, isNotNull);
      expect(issue!.field, 'ip_cidr');
      expect(issue.labelKey, 'IP CIDR');
      expect(describe(issue), contains('999.1.1.1/24'));

      // Out-of-range prefix and malformed IPv6 are rejected too.
      expect(validateRuleFields({'ip_cidr': ['10.0.0.0/33']})?.field, 'ip_cidr');
      expect(validateRuleFields({'ip_cidr': ['2001:db8::/129']})?.field, 'ip_cidr');
      expect(validateRuleFields({'source_ip_cidr': ['not-a-cidr/8']})?.field, 'source_ip_cidr');
    });

    test('rejects invalid ports and ranges', () {
      expect(validateRuleFields({'port': ['0']})?.field, 'port');
      expect(validateRuleFields({'port': ['65536']})?.field, 'port');
      expect(validateRuleFields({'port': ['abc']})?.field, 'port');
      expect(validateRuleFields({'source_port': ['70000']})?.field, 'source_port');
      final range = validateRuleFields({'port_range': ['2000:1000']});
      expect(range, isNotNull);
      expect(range!.field, 'port_range');
      expect(range.reasonKey, 'Port out of range');
      expect(validateRuleFields({'source_port_range': ['1-2-3']})?.field, 'source_port_range');
    });

    test('rejects invalid regular expressions in every regex field', () {
      for (final field in const [
        'domain_regex', 'package_name_regex', 'process_name_regex', 'process_path_regex',
      ]) {
        final issue = validateRuleFields({field: ['(']});
        expect(issue, isNotNull, reason: '$field must reject a broken regex');
        expect(issue!.field, field);
        expect(issue.reasonKey, 'Invalid regular expression');
      }
    });

    test('rejects out-of-range override port and bad fallback delay', () {
      expect(validateRuleFields({'override_port': '70000'})?.field, 'override_port');
      expect(validateRuleFields({'override_port': 'abc'})?.field, 'override_port');
      // Throne's "unset" sentinel stays valid so old rules can be saved again.
      expect(validateRuleFields({'override_port': '0'}), isNull);
      expect(validateRuleFields({'tls_fragment_fallback_delay': 'nonsense'})?.field,
          'tls_fragment_fallback_delay');
      expect(validateRuleFields({'tls_fragment_fallback_delay': '-5'}), isNotNull);
      expect(validateRuleFields({'tls_fragment_fallback_delay': '500ms'}), isNull);
      expect(validateRuleFields({'tls_fragment_fallback_delay': '500'}), isNull);
    });

    test('reports the first offending field in a deterministic order', () {
      final issue = validateRuleFields({
        'domain_regex': ['('],
        'port': ['99999'],
      });
      expect(issue!.field, 'port', reason: 'port checks run before regex checks');
    });

    test('never mutates the rule map', () {
      final rule = <String, dynamic>{
        'ip_cidr': ['10.0.0.0/8'],
        'port': ['80'],
      };
      final snapshot = Map<String, dynamic>.from(rule);
      validateRuleFields(rule);
      expect(rule, equals(snapshot));
    });
  });
}
