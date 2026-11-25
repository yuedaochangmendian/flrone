import 'package:flrone/core/log_payload.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a routing line becomes destination, rule and proxy', () {
    final payload = LogPayload.parse(
      '[tun] 1.2.3.4:5555 --> example.com:443 match domain-suffix using Proxy(US)',
    );
    expect(payload.tag, 'tun');
    final route = payload.route!;
    expect(route.source, '1.2.3.4:5555');
    expect(route.destination, 'example.com:443');
    expect(route.rule, 'domain-suffix');
    expect(route.proxy, 'Proxy(US)');
    expect(route.error, isEmpty);
  });

  test('a dial failure carries its error', () {
    final route = LogPayload.parse(
      'dial Proxy(US) (match fallback) 10.0.0.1:443 --> example.com:443 error: timeout',
    ).route!;
    expect(route.proxy, 'Proxy(US)');
    expect(route.rule, 'fallback');
    expect(route.destination, 'example.com:443');
    expect(route.error, 'timeout');
  });

  test('a plain line keeps its text and tag', () {
    final payload = LogPayload.parse('[core] inbound connection accepted');
    expect(payload.tag, 'core');
    expect(payload.message, 'inbound connection accepted');
    expect(payload.route, isNull);
  });

  test('a line without a tag is still parsed for routes', () {
    final payload = LogPayload.parse(
      '1.2.3.4:5555 --> example.com:443 doesn\'t match any rule using DIRECT',
    );
    expect(payload.tag, isEmpty);
    expect(payload.route!.proxy, 'DIRECT');
  });
}
