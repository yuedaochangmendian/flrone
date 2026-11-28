import 'dart:convert';
import 'dart:io';

import 'package:flrone/services/subscription_transport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {

  Future<HttpServer> serve(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      handler(request).catchError((Object error) {
        request.response.statusCode = 500;
        request.response.write('$error');
        return request.response.close();
      });
    });
    addTearDown(() => server.close(force: true));
    return server;
  }

  String base(HttpServer server) => 'http://127.0.0.1:${server.port}';

  test('fetch decodes a plain body and its metadata', () async {
    final server = await serve((request) async {
      request.response.headers.set(
        'Subscription-UserInfo',
        'upload=10; download=20; total=100; expire=1700000000',
      );
      request.response.headers.set(
        'Profile-Title',
        'base64:${base64.encode(utf8.encode('Node Pool'))}',
      );
      request.response.headers.set(
        'Content-Disposition',
        "attachment; filename*=UTF-8''%E8%8A%82%E7%82%B9.txt",
      );
      request.response.write('#profile-update-interval: 12\n');
      request.response.write('ss://example');
      await request.response.close();
    });

    final result = await SubscriptionHttpTransport().fetch('${base(server)}/sub');
    expect(result.body, contains('#profile-update-interval: 12'));
    expect(result.metadata.title, 'Node Pool');
    expect(result.metadata.upload, 10);
    expect(result.metadata.download, 20);
    expect(result.metadata.total, 100);
    expect(result.metadata.serverInterval, 12);
    expect(result.metadata.hasQuota, isTrue);
    expect(result.fileName, '节点.txt');
  });

  test('fetch decodes labeled gzip and unlabeled zlib', () async {
    final payload = utf8.encode('vmess://abc\n');
    final gzipServer = await serve((request) async {
      final bytes = gzip.encode(payload);
      request.response.headers.contentType = ContentType.binary;
      request.response.add(bytes);
      await request.response.close();
    });
    final zlibServer = await serve((request) async {
      final bytes = zlib.encode(payload);
      request.response.headers.contentType = ContentType.binary;
      request.response.add(bytes);
      await request.response.close();
    });
    final transport = SubscriptionHttpTransport();
    expect((await transport.fetch(base(gzipServer))).body, 'vmess://abc\n');
    expect((await transport.fetch(base(zlibServer))).body, 'vmess://abc\n');
  });

  test('the body cap aborts a large response', () async {
    final server = await serve((request) async {
      request.response.add(List<int>.filled(1024, 0x41));
      await request.response.close();
    });
    final transport = SubscriptionHttpTransport(maxBodyBytes: 64);
    await expectLater(
      transport.fetch(base(server)),
      throwsA(isA<SubscriptionTransportException>().having(
        (error) => error.message,
        'message',
        contains('size limit'),
      )),
    );
  });

  test('redirects keep URL credentials on the same origin and drop them cross-origin', () async {
    final captured = <String?>[];
    final serverB = await serve((request) async {
      captured.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response.write('ok');
      await request.response.close();
    });
    final serverA = await serve((request) async {
      captured.add(request.headers.value(HttpHeaders.authorizationHeader));
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set('location', '${base(serverB)}/final');
      await request.response.close();
    });

    final transport = SubscriptionHttpTransport();
    final started = 'http://user:pass@127.0.0.1:${serverA.port}/start';
    final result = await transport.fetch(started);
    expect(result.body, 'ok');
    final basic = 'Basic ${base64.encode(utf8.encode('user:pass'))}';
    expect(captured, [basic, isNull],
        reason: 'the second origin must not receive the first origin credentials');

    captured.clear();
    await transport.fetch('http://user:pass@127.0.0.1:${serverB.port}/direct');
    expect(captured.single, basic);
  });

  test('the redirect cap stops a loop', () async {
    late HttpServer server;
    server = await serve((request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set('location', '${base(server)}/again');
      await request.response.close();
    });
    final transport = SubscriptionHttpTransport(maxRedirects: 2);
    await expectLater(
      transport.fetch(base(server)),
      throwsA(isA<SubscriptionTransportException>().having(
        (error) => error.message,
        'message',
        contains('Too many redirects'),
      )),
    );
  });

  test('https to http redirects are refused by policy', () {
    expect(
      SubscriptionHttpTransport.allowsRedirect(
        Uri.parse('https://example.com/a'),
        Uri.parse('http://example.com/b'),
      ),
      isFalse,
    );
    expect(
      SubscriptionHttpTransport.allowsRedirect(
        Uri.parse('https://example.com/a'),
        Uri.parse('https://example.com/b'),
      ),
      isTrue,
    );
  });

  test('metadata falls back to body comments and base64 values', () {
    final metadata = SubscriptionHttpTransport.parseMetadata(
      const <String, String>{'content-type': 'text/plain'},
      '# profile-title: base64:${base64.encode(utf8.encode('Title'))}\n'
      '//profile-update-interval: 1d\n'
      '# subscription-userinfo: upload=1; download=2; total=3; expire=4\n'
      'ss://not-a-comment',
    );
    expect(metadata.title, 'Title');
    expect(metadata.serverInterval, 24);
    expect(metadata.upload, 1);
    expect(metadata.total, 3);
    expect(metadata.valid, isTrue);
  });

  test('interval and filename parsers match the Kotlin rules', () {
    expect(SubscriptionHttpTransport.parseUpdateInterval('12'), 12);
    expect(SubscriptionHttpTransport.parseUpdateInterval('2d'), 48);
    expect(SubscriptionHttpTransport.parseUpdateInterval('86400s'), 24);
    expect(SubscriptionHttpTransport.parseUpdateInterval('0'), 0);
    expect(SubscriptionHttpTransport.parseUpdateInterval('bad'), 0);

    expect(
      SubscriptionFileName.fromDisposition(
        "attachment; filename*=UTF-8''%E8%8A%82%E7%82%B9.txt",
      ),
      '节点.txt',
    );
    expect(
      SubscriptionFileName.fromDisposition(
        'attachment; filename="dir/sub.txt"',
      ),
      'sub.txt',
    );
    expect(SubscriptionFileName.fromDisposition(null), '');
  });

  test('error messages never keep URL credentials', () {
    final redacted = SubscriptionHttpTransport.redact(
      'SocketException: failed https://user:secret@example.com/sub?token=abc',
    );
    expect(redacted, isNot(contains('secret')));
    expect(redacted, isNot(contains('token=abc')));
    expect(redacted, contains('<url>'));
  });
}