// WebDAV backup protocol tests (ADR 0005 phase 4). A tiny in-process WebDAV
// fake serves PROPFIND/GET/PUT/DELETE/MKCOL so the full create->list->download
// path, the index round-trip and every failure mode are exercised without a
// device, Kotlin or a real server.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flrone/services/backup_store.dart';
import 'package:flrone/services/backup_webdav.dart';
import 'package:flrone/services/webdav_client.dart' show WebDavClient, WebDavException;
import 'package:flutter_test/flutter_test.dart';

class _Dav {
  final List<String> methods = <String>[];
  final List<String> paths = <String>[];
  HttpServer? _server;
  late Future<void> Function(HttpRequest) _respond;

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

  Future<void> stop() => _server?.close(force: true) ?? Future.value();
}

/// A minimal THRN container with a database entry and Android meta, built from
/// the same codec the app uses. The embedded "database" is a 16-byte header —
/// enough for download's container check; profile preview gracefully finds no
/// profiles table.
List<int> _sampleContainer(String createdAt) => thrnEncode(
      thrnAndroidMeta(
        parts: const ThrnParts(profiles: true, routes: true, settings: true),
        appVersion: '4.10.1',
        deviceId: 'device-A',
        deviceName: 'Pixel',
        createdAt: createdAt,
      ),
      {thrnDatabase: utf8.encode('SQLite format 3\u0000')},
    );

/// A WebDAV multistatus listing with one .thrbackup file.
String _listing(String name, {int size = 100, String modified = 'Wed, 24 Sep 2026 03:43:00 GMT'}) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:multistatus xmlns:d="DAV:">'
    '<d:response><d:href>/Backups/</d:href><d:resourcetype><d:collection/></d:resourcetype></d:response>'
    '<d:response><d:href>/Backups/$name</d:href><d:resourcetype/>'
    '<d:getcontentlength>$size</d:getcontentlength><d:getlastmodified>$modified</d:getlastmodified>'
    '</d:response></d:multistatus>';

void main() {
  _Dav? dav;
  setUp(() => dav = _Dav());
  tearDown(() => dav?.stop());

  WebDavBackupService service() => WebDavBackupService(
        WebDavClientForTest(dav!.url).client,
        deviceId: 'device-A',
        deviceName: 'Pixel',
        appVersion: '4.10.1',
      );

  group('upload', () {
    test('PUTs the container and writes the index (create path)', () async {
      final container = _sampleContainer('Thu Sep 24 03:43:00 2026');
      final puts = <String, List<int>>{};
      await dav!.start((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_listing('placeholder.thrbackup'));
        } else if (request.method == 'PUT') {
          final bytes = <int>[];
          await request.listen(bytes.addAll).asFuture<void>();
          puts[request.uri.path.split('/').last] = bytes;
          request.response.statusCode = HttpStatus.created;
        } else {
          request.response.statusCode = HttpStatus.ok;
        }
        await request.response.close();
      });

      final result = await service().upload(container, {'profiles', 'routes', 'settings'});
      expect(result.indexError, isNull);
      expect(result.file, startsWith('throne_backup_4.10.1_'));
      expect(result.file, endsWith('.thrbackup'));
      final uploaded = puts.entries.firstWhere((e) => e.key.endsWith('.thrbackup'));
      expect(uploaded.value, container);
      // The index is a second PUT with file/size/sha256 metadata.
      final indexPut = puts.entries.firstWhere((e) => e.key == backupIndexFile);
      final index = jsonDecode(utf8.decode(indexPut.value)) as Map<String, dynamic>;
      expect(index['format'], 1);
      final backup = (index['backups'] as List).first as Map<String, dynamic>;
      expect(backup['file'], result.file);
      expect(backup['sha256'], thrnSha256Hex(container));
      expect(backup['size'], container.length);
      expect(backup['platform'], 'android');
      expect(backup['parts'], containsAll(['profiles', 'routes', 'settings']));
    });

    test('a 401 on the PUT raises a typed WebDavException', () async {
      await dav!.start((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_listing('x.thrbackup'));
        } else if (request.method == 'PUT') {
          request.response.statusCode = HttpStatus.unauthorized;
        } else {
          request.response.statusCode = HttpStatus.ok;
        }
        await request.response.close();
      });
      expect(
        () => service().upload(_sampleContainer('x'), {'profiles'}),
        throwsA(isA<WebDavException>().having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('a stalled PUT times out instead of hanging', () async {
      await dav!.start((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_listing('x.thrbackup'));
          await request.response.close();
        }
        // PUT: never close.
      });
      final svc = WebDavBackupService(
        WebDavClientForTest(dav!.url, timeout: const Duration(milliseconds: 200)).client,
      );
      expect(() => svc.upload(_sampleContainer('x'), {'profiles'}), throwsA(isA<WebDavException>()));
    });
  });

  group('list + download', () {
    test('joins the index with the listing and downloads verified bytes', () async {
      final container = _sampleContainer('Thu Sep 24 03:43:00 2026');
      const name = 'throne_backup_4.10.1_20260924_034300_abcd.thrbackup';
      final index = {
        'format': 1,
        'backups': [
          {
            'file': name,
            'created_at': '2026-09-24T03:43:00Z',
            'size': container.length,
            'sha256': thrnSha256Hex(container),
            'device_id': 'device-A',
            'device_name': 'Pixel',
            'platform': 'android',
            'app_version': '4.10.1',
            'parts': ['profiles', 'settings'],
          },
        ],
      };
      await dav!.start((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_listing(name, size: container.length));
        } else if (request.uri.path.endsWith(backupIndexFile)) {
          request.response.write(jsonEncode(index));
        } else if (request.method == 'GET') {
          request.response.add(container);
        } else {
          request.response.statusCode = HttpStatus.ok;
        }
        await request.response.close();
      });

      final svc = service();
      final entries = await svc.list();
      expect(entries, hasLength(1));
      expect(entries.single.file, name);
      expect(entries.single.indexed, isTrue);
      expect(entries.single.thisDevice, isTrue);
      expect(entries.single.appVersion, '4.10.1');
      expect(entries.single.parts, containsAll(['profiles', 'settings']));
      final downloaded = await svc.download(entries.single);
      expect(downloaded, container);
    });

    test('download refuses bytes that fail the index SHA-256', () async {
      const name = 'throne_backup_x.thrbackup';
      await dav!.start((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_listing(name, size: 3));
        } else if (request.uri.path.endsWith(backupIndexFile)) {
          request.response.write(jsonEncode({
            'format': 1,
            'backups': [
              {'file': name, 'created_at': '2026-09-24T03:43:00Z', 'size': 3, 'sha256': '00' * 32},
            ],
          }));
        } else if (request.method == 'GET') {
          request.response.write('abc');
        }
        await request.response.close();
      });
      final entries = await service().list();
      expect(
        () => service().download(entries.single),
        throwsA(isA<WebDavException>()),
      );
    });

    test('download refuses a non-THRN file', () async {
      const name = 'throne_backup_x.thrbackup';
      await dav!.start((request) async {
        if (request.method == 'PROPFIND') {
          request.response.statusCode = 207;
          request.response.write(_listing(name, size: 3));
        } else if (request.uri.path.endsWith(backupIndexFile)) {
          request.response.statusCode = HttpStatus.notFound;
        } else if (request.method == 'GET') {
          request.response.write('abc');
        }
        await request.response.close();
      });
      final entries = await service().list();
      expect(entries.single.indexed, isFalse); // synthesized, no expected digest
      expect(() => service().download(entries.single), throwsA(isA<WebDavException>()));
    });
  });

  group('errors', () {
    test('a 401 on listing raises a typed WebDavException', () async {
      await dav!.start((request) async {
        request.response.statusCode = HttpStatus.unauthorized;
        await request.response.close();
      });
      expect(() => service().list(), throwsA(isA<WebDavException>().having(
        (e) => e.statusCode, 'statusCode', 401)));
    });

    test('a missing folder yields an empty list, not an error', () async {
      await dav!.start((request) async {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
      expect(await service().list(), isEmpty);
    });

    test('fromAccount returns null without a URI', () {
      expect(WebDavBackupService.fromAccount(null), isNull);
      expect(WebDavBackupService.fromAccount({}), isNull);
      expect(WebDavBackupService.fromAccount({'uri': 'http://x.test'}), isNotNull);
    });
  });
}

/// Small wrapper so tests can pass a custom timeout to WebDavClient.
class WebDavClientForTest {
  WebDavClientForTest(String url, {Duration? timeout})
      : client = WebDavClient(
          uri: url,
          user: 'u',
          password: 'p',
          directory: 'Backups',
          requestTimeout: timeout ?? const Duration(seconds: 5),
        );
  final WebDavClient client;
}
