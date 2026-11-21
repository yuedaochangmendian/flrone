import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flrone/services/webdav_client.dart';
import 'package:flutter_test/flutter_test.dart';

/// A tiny in-process WebDAV fake. It records request methods/paths so the test
/// can assert the PROPFIND/MKCOL semantics, and lets each test decide how to
/// answer by returning a status code (or holding the connection for timeouts).
class _FakeDav {
  final List<String> methods = <String>[];
  final List<String> paths = <String>[];
  HttpServer? _server;
  late final Future<void> Function(HttpRequest) _respond;

  Future<void> start(Future<void> Function(HttpRequest) respond) async {
    _respond = respond;
    _server ??= await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) {
      methods.add(request.method);
      paths.add(request.uri.path);
      unawaited(_respond(request));
    });
  }

  String get url => 'http://127.0.0.1:${_server!.port}';
  int get port => _server!.port;

  Future<void> stop() => _server?.close(force: true) ?? Future.value();
}

void main() {
  _FakeDav? dav;

  setUp(() async {
    dav = _FakeDav();
  });

  tearDown(() async {
    await dav?.stop();
  });

  WebDavClient client({Duration requestTimeout = const Duration(seconds: 2)}) =>
      WebDavClient(
        uri: dav!.url,
        user: 'u',
        password: 'p',
        directory: 'Backups',
        requestTimeout: requestTimeout,
      );

  test('check: PROPFIND 2xx means connected, with Basic auth and Depth 0', () async {
    String? authorization;
    String? depth;
    await dav!.start((request) async {
      authorization = request.headers.value(HttpHeaders.authorizationHeader);
      depth = request.headers.value('Depth');
      request.response.statusCode = HttpStatus.multiStatus;
      await request.response.close();
    });

    expect(await client().check(), isTrue);
    expect(dav!.methods, ['PROPFIND']);
    expect(dav!.paths, ['/Backups/']);
    expect(depth, '0');
    expect(authorization, 'Basic ${base64Encode(utf8.encode('u:p'))}');
  });

  test('check: 404 then MKCOL creates each segment and succeeds', () async {
    var propfindSeen = false;
    await dav!.start((request) async {
      if (request.method == 'PROPFIND') {
        propfindSeen = true;
        request.response.statusCode = HttpStatus.notFound;
      } else if (request.method == 'MKCOL') {
        request.response.statusCode = HttpStatus.created;
      } else {
        request.response.statusCode = HttpStatus.ok;
      }
      await request.response.close();
    });

    expect(await client().check(), isTrue);
    expect(propfindSeen, isTrue);
    expect(dav!.methods, contains('MKCOL'));
  });

  test('check: 401 raises a typed WebDavException', () async {
    await dav!.start((request) async {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });

    expect(
      () => client().check(),
      throwsA(isA<WebDavException>().having(
        (e) => e.statusCode, 'statusCode', HttpStatus.unauthorized)),
    );
  });

  test('check: a stalled server times out instead of hanging', () async {
    // Hold the PROPFIND open: never complete the response so the client's own
    // timeout is the only thing that can end it.
    await dav!.start((request) async {
      // Intentionally no response.close().
    });

    expect(
      () => client(requestTimeout: const Duration(milliseconds: 200)).check(),
      throwsA(isA<WebDavException>()),
    );
  });

  test('downloadToFile: missing remote file throws before touching the target', () async {
    final temp = await Directory.systemTemp.createTemp('webdav-test-');
    addTearDown(() => temp.delete(recursive: true));
    await dav!.start((request) async {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    });

    final target = File('${temp.path}/backup.bin');
    expect(
      () => client().downloadToFile('missing.thrbackup', target),
      throwsA(isA<WebDavException>().having((e) => e.statusCode, 'statusCode', 404)),
    );
    expect(await target.exists(), isFalse);
  });

  test('downloadToFile: bytes are written to a nested temp path', () async {
    final temp = await Directory.systemTemp.createTemp('webdav-test-');
    addTearDown(() => temp.delete(recursive: true));
    final payload = utf8.encode('THRN-synthetic-bytes');
    await dav!.start((request) async {
      request.response.add(payload);
      await request.response.close();
    });

    final target = File('${temp.path}/nested/backup.bin');
    final written = await client().downloadToFile('b.thrbackup', target);
    expect(await written.readAsBytes(), payload);
    expect(dav!.methods, ['GET']);
    expect(dav!.paths, ['/Backups/b.thrbackup']);
  });

  test('uploadFromFile: a missing local file throws without any HTTP request', () async {
    await dav!.start((request) async {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
    });

    expect(
      () => client().uploadFromFile('b.thrbackup', File('/no/such/file')),
      throwsA(isA<WebDavException>()),
    );
    expect(dav!.methods, isEmpty);
  });

  test('uploadBytes: PUT carries the bytes and requires 2xx', () async {
    final received = <int>[];
    await dav!.start((request) async {
      await request.listen(received.addAll).asFuture<void>();
      request.response.statusCode = HttpStatus.created;
      await request.response.close();
    });

    await client().uploadBytes('b.thrbackup', utf8.encode('container'));
    expect(dav!.methods, ['PUT']);
    expect(utf8.decode(received), 'container');
  });

  test('defaultWebDavCheck: null account and auth failure answer false', () async {
    expect(await defaultWebDavCheck(null), isFalse);
    expect(await defaultWebDavCheck(<String, dynamic>{}), isFalse);

    await dav!.start((request) async {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
    });
    final account = <String, dynamic>{
      'uri': dav!.url,
      'user': 'u',
      'password': 'p',
      'fileName': 'Backups',
    };
    expect(await defaultWebDavCheck(account), isFalse);
  });

  test('WebDavClient: an invalid URI is rejected up front', () {
    expect(
      () => WebDavClient(uri: 'ftp://example.test'),
      throwsA(isA<WebDavException>()),
    );
  });
}
