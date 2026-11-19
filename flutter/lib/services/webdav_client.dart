// Pure-Dart WebDAV transport (Bettbox data-authority alignment, phase 1 slice).
//
// This is the one WebDAV/backup channel method that is genuinely independent of
// Room: `webdav.check` only needs the account map (Dart-owned since ADR 0005
// phase 1 via `WebDavAccountStore`) and a PROPFIND/MKCOL round trip. The remaining methods
// (`backup.create/open/restore`, `webdav.upload/read`) build or parse THRN
// containers straight out of Room, so they stay on the channel until the whole
// backup document store moves — see docs/adr/0002-bettbox-alignment.md.
//
// The behaviour here mirrors Kotlin `WebDavBackup.ensureDirectory()` / `check()`:
// PROPFIND Depth 0 on the collection; on 404 create each path segment with MKCOL;
// Basic auth; redirects NOT followed for WebDAV verbs; connect/read timeouts.
// No package dependencies: dart:io + dart:convert only.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// An account map as the Dart account store keeps it: `{uri, user, password, fileName}`.
/// The shape is unchanged from the old `webdav.get` answer so the form and probe
/// need no changes (ADR 0005 phase 1).
typedef WebDavAccount = Map<String, dynamic>;

/// The seam the controller uses for the connectivity check, so widget tests can
/// supply a fake without standing up an HTTP server (same pattern as
/// `RouteProfilesAttach` in `data/route_profiles_source.dart`).
typedef WebDavChecker = Future<bool> Function(WebDavAccount? account);

/// A WebDAV error with a user-facing message, mirroring the Kotlin IOException
/// texts from `WebDavBackup.requireOk`.
class WebDavException implements Exception {
  const WebDavException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Minimal WebDAV client for the backup folder. Files are plain bytes: the THRN
/// container codec is native for now, so this owns only the HTTP transport.
class WebDavClient {
  WebDavClient({
    required String uri,
    this.user = '',
    this.password = '',
    String directory = '',
    this.connectionTimeout = const Duration(seconds: 15),
    this.requestTimeout = const Duration(seconds: 60),
  }) : base = _parseUri(uri) {
    final segments =
        directory.trim().split('/').where((s) => s.isNotEmpty).toList();
    // Kotlin WebDavBackup.configured(): a blank path defaults to "Throne".
    _segments = List.unmodifiable(segments.isEmpty ? ['Throne'] : segments);
  }

  final Uri base;
  final String user;
  final String password;
  final Duration connectionTimeout;
  final Duration requestTimeout;
  late final List<String> _segments;

  static Uri _parseUri(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const WebDavException('Enter a WebDAV HTTP or HTTPS directory address');
    }
    return uri;
  }

  Uri _collection(int depth) {
    final path = <String>[
      ...base.pathSegments.where((s) => s.isNotEmpty),
      ..._segments.take(depth),
      '',
    ];
    return Uri(scheme: base.scheme, host: base.host, port: base.port, pathSegments: path);
  }

  /// The configured folder as a collection URL (trailing slash), matching
  /// Kotlin `WebDavBackup.directory`.
  Uri get directory => _collection(_segments.length);

  Uri fileUrl(String name) =>
      directory.resolve(Uri.encodeComponent(name));

  String get _authorization =>
      'Basic ${base64Encode(utf8.encode('$user:$password'))}';

  HttpClient _newClient() => HttpClient()
    ..connectionTimeout = connectionTimeout
    ..idleTimeout = requestTimeout;

  Future<HttpClientRequest> _open(
      String method, Uri url, HttpClient client) async {
    final request = await client.openUrl(method, url).timeout(requestTimeout);
    // PROPFIND/MKCOL/PUT/DELETE must not turn into a GET on a 301/302.
    request.followRedirects = false;
    request.headers.set(HttpHeaders.authorizationHeader, _authorization);
    return request;
  }

  /// `webdav.check`: reach the folder, creating it when it does not exist.
  /// Returns true only when the folder is reachable; any HTTP/auth/transport
  /// error becomes a [WebDavException].
  Future<bool> check() async {
    final client = _newClient();
    try {
      final probe = await _open('PROPFIND', directory, client);
      probe.headers.set('Depth', '0');
      final response = await probe.close().timeout(requestTimeout);
      await response.drain<void>();
      final missing = response.statusCode == 404;
      if (!missing) {
        _requireOk(response.statusCode, response.headers.value('location'));
        return true;
      }
      for (var depth = 1; depth <= _segments.length; depth++) {
        final mkcol = await _open('MKCOL', _collection(depth), client);
        final made = await mkcol.close().timeout(requestTimeout);
        await made.drain<void>();
        final code = made.statusCode;
        if (code == 405) continue; // already a collection
        if ((code >= 300 && code <= 399) || code == 401 || code == 403) {
          _requireOk(code, made.headers.value('location'));
        }
        if (code < 200 || code >= 300) {
          throw const WebDavException('Could not create the WebDAV directory');
        }
      }
      return true;
    } on WebDavException {
      rethrow;
    } on SocketException {
      throw const WebDavException('Could not connect to the WebDAV server');
    } on TimeoutException {
      throw const WebDavException('The WebDAV server did not respond in time');
    } on HttpException {
      throw const WebDavException('The WebDAV server returned an invalid response');
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads a remote backup file as bytes. Throws a 404 [WebDavException]
  /// when the file is missing. Kept for the backup phase so it can reuse the
  /// same transport without reintroducing a Kotlin HTTP path.
  Future<List<int>> downloadBytes(String name) async {
    final client = _newClient();
    try {
      final request = await _open('GET', fileUrl(name), client);
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode == 404) {
        await response.drain<void>();
        throw WebDavException('The remote backup file is missing', statusCode: 404);
      }
      _requireOk(response.statusCode, response.headers.value('location'));
      final bytes = <int>[];
      await for (final chunk in response.timeout(requestTimeout)) {
        bytes.addAll(chunk);
      }
      return bytes;
    } on WebDavException {
      rethrow;
    } on SocketException {
      throw const WebDavException('Could not connect to the WebDAV server');
    } on TimeoutException {
      throw const WebDavException('The WebDAV server did not respond in time');
    } finally {
      client.close(force: true);
    }
  }

  /// Downloads into [target], creating parent directories. `file not found`
  /// on the server throws before the file is touched.
  Future<File> downloadToFile(String name, File target) async {
    final bytes = await downloadBytes(name);
    await target.parent.create(recursive: true);
    return target.writeAsBytes(bytes);
  }

  /// Uploads finished container bytes under [name].
  Future<void> uploadBytes(String name, List<int> bytes) async {
    final client = _newClient();
    try {
      final request = await _open('PUT', fileUrl(name), client);
      request.headers.contentType = ContentType.binary;
      request.contentLength = bytes.length;
      request.add(bytes);
      final response = await request.close().timeout(requestTimeout);
      await response.drain<void>();
      _requireOk(response.statusCode, response.headers.value('location'));
    } on WebDavException {
      rethrow;
    } on SocketException {
      throw const WebDavException('Could not connect to the WebDAV server');
    } on TimeoutException {
      throw const WebDavException('The WebDAV server did not respond in time');
    } finally {
      client.close(force: true);
    }
  }

  /// Uploads from a local file; a missing local file throws a
  /// [WebDavException] before any request is made.
  Future<void> uploadFromFile(String name, File source) async {
    if (!await source.exists()) {
      throw WebDavException('The local backup file is missing: ${source.path}');
    }
    return uploadBytes(name, await source.readAsBytes());
  }

  static void _requireOk(int code, String? location) {
    if (code >= 200 && code < 300) return;
    if (code >= 300 && code <= 399) {
      throw WebDavException('The WebDAV server redirected to $location',
          statusCode: code);
    }
    switch (code) {
      case 401:
        throw const WebDavException('WebDAV authentication failed', statusCode: 401);
      case 403:
        throw const WebDavException('WebDAV access denied', statusCode: 403);
      case 404:
        throw const WebDavException('The WebDAV folder was not found', statusCode: 404);
      default:
        throw WebDavException('The WebDAV server returned an error ($code)',
            statusCode: code);
    }
  }
}

/// The default [WebDavChecker] used by [BoxController]. Connection failures are
/// reported as `false`, mirroring the old Kotlin `checkWebdav()` which caught
/// every error and answered a boolean.
Future<bool> defaultWebDavCheck(WebDavAccount? account) async {
  if (account == null) return false;
  final uri = account['uri'];
  if (uri is! String || uri.trim().isEmpty) return false;
  try {
    final client = WebDavClient(
      uri: uri,
      user: account['user'] is String ? account['user'] as String : '',
      password: account['password'] is String ? account['password'] as String : '',
      directory: account['fileName'] is String ? account['fileName'] as String : '',
    );
    return await client.check();
  } on WebDavException {
    return false;
  }
}
