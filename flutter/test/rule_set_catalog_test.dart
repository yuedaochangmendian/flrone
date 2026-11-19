// ADR 0005 phase 3: `routes.ruleSets` moved off the channel onto a pure-Dart
// reader of the installed `srslist.h`. These tests pin the parse (the name ->
// URL map), the case-insensitive exact/prefix/substring search order, the
// dedup-first-URL rule, and the empty-file / missing-file cases. No filesystem
// is touched: the reader is injected.

import 'package:flrone/data/rule_set_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sample = '''
// routeprofiles rule-set list
{"geosite-cn", "https://example.test/geosite-cn.srs"}
{"GeoIP-CN", "https://example.test/geoip-cn.srs"}
{"geosite-google", "https://example.test/google.srs"}
{"geosite-cn", "https://example.test/duplicate.srs"}
{"geosite-github", "https://example.test/github.srs"}
''';

  group('parseRuleSetCatalog', () {
    test('parses entries into a name -> URL list, keeping the first duplicate', () {
      final entries = parseRuleSetCatalog(sample);
      expect(entries, hasLength(4));
      expect(entries.map((e) => e.name), [
        'geosite-cn',
        'GeoIP-CN',
        'geosite-google',
        'geosite-github',
      ]);
      expect(entries.first.url, 'https://example.test/geosite-cn.srs',
          reason: 'a duplicate name must not overwrite the first URL');
    });

    test('an empty or missing body gives an empty catalog', () {
      expect(parseRuleSetCatalog(''), isEmpty);
      expect(parseRuleSetCatalog('not a rule set'), isEmpty);
    });

    test('toWire matches the old channel shape', () {
      expect(RuleSetEntry('x', 'https://e.test/x.srs').toWire(), {
        'name': 'x',
        'url': 'https://e.test/x.srs',
      });
    });
  });

  group('searchRuleSetCatalog', () {
    final entries = parseRuleSetCatalog(sample);

    test('an empty query returns the first N entries in order', () {
      final found = searchRuleSetCatalog(entries, '', 2);
      expect(found.map((e) => e.name), ['geosite-cn', 'GeoIP-CN']);
    });

    test('exact matches rank before prefix and substring, case-insensitively', () {
      // "GEOSITE-CN" is an exact match on geosite-cn. "geoip" is a prefix of
      // GeoIP-CN. "github" is a substring of geosite-github.
      final exact = searchRuleSetCatalog(entries, 'GEOSITE-CN', 10);
      expect(exact.first.name, 'geosite-cn');

      final prefix = searchRuleSetCatalog(entries, 'geoip', 10);
      expect(prefix.map((e) => e.name), ['GeoIP-CN']);

      final substring = searchRuleSetCatalog(entries, 'github', 10);
      expect(substring.map((e) => e.name), ['geosite-github']);
    });

    test('an exact query that is also a prefix of others still ranks exact first', () {
      // "geosite-cn" is exact for one entry and a prefix of none here, but the
      // ordering rule matters when both happen: craft such a catalog.
      final local = parseRuleSetCatalog(
        '{"cn", "u1"}\n{"cn-extra", "u2"}\n{"xcn", "u3"}',
      );
      expect(searchRuleSetCatalog(local, 'cn', 10).map((e) => e.name), [
        'cn', 'cn-extra', 'xcn',
      ]);
    });

    test('a non-positive limit returns nothing', () {
      expect(searchRuleSetCatalog(entries, '', 0), isEmpty);
      expect(searchRuleSetCatalog(entries, 'cn', -3), isEmpty);
    });

    test('a query with no match returns nothing', () {
      expect(searchRuleSetCatalog(entries, 'zzzz', 10), isEmpty);
    });
  });

  group('RuleSetCatalogSource', () {
    test('search loads then filters, with total = full catalog size', () async {
      final source = RuleSetCatalogSource(readText: () async => sample);
      final answer = await source.search('geosite', 10);
      expect(answer['total'], 4);
      final rows = answer['entries'] as List;
      expect(rows.length, 3);
      expect(rows.first, {
        'name': 'geosite-cn',
        'url': 'https://example.test/geosite-cn.srs',
      });
    });

    test('a missing file yields an empty but well-formed answer', () async {
      final source = RuleSetCatalogSource(readText: () async => null);
      final answer = await source.search('', 10);
      expect(answer, {'total': 0, 'entries': isEmpty});
    });

    test('re-reads on every search so a refresh is picked up', () async {
      var calls = 0;
      final source = RuleSetCatalogSource(readText: () async {
        calls++;
        return calls == 1 ? '{"a", "u1"}' : '{"a", "u1"}\n{"b", "u2"}';
      });
      expect((await source.search('', 10))['total'], 1);
      expect((await source.search('', 10))['total'], 2);
    });
  });
}
