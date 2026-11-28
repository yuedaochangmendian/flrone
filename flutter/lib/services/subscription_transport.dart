// The Dart half of the subscription fetch (ADR 0008 S6, first slice).
//
// Kotlin's `SubscriptionFetch`/`Compression`/`Metadata`/`FileName` are still the
// production path; this file is the transport the Dart queue will use once the
// parse/reconcile half can move (it depends on S5's stored-form export). The
// semantics are ported from the Kotlin readers, with the deliberate exception
// of Android-only or OkHttp-only features:
//
//   * `content://` input stays a host duty (a Dart isolate has no ContentResolver);
//   * HTTP/2 and per-request TLS-version pinning stay host duties (`dart:io`
//     exposes neither); callers can keep using the Kotlin fetch for those;
//   * the proxy endpoint/auth stays a host decision (the mixed inbound is the
//     runtime's only proxy on Android); pass it as an HttpClient factory seam.
//
// Everything else — redirect/auth policy, byte caps, unlabeled gzip/zlib,
// metadata headers/body comments, RFC 5987 filenames and error redaction — is
// reproduced here and covered by loopback tests.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The quota/metadata a subscription advertises.
///
/// Mirrors `SubUserInfo`'s fields, including `valid`: a metadata record is only
/// applied when at least one field was actually present. `serverInterval` is in
/// hours, 0 when absent.
class SubscriptionMetadata {
  const SubscriptionMetadata({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
    this.hasQuota = false,
    this.serverInterval = 0,
    this.title = '',
    this.webUrl = '',
    this.supportUrl = '',
    this.announce = '',
    this.valid = false,
  });

  final int upload;
  final int download;
  final int total;
  final int expire;
  final bool hasQuota;
  final int serverInterval;
  final String title;
  final String webUrl;
  final String supportUrl;
  final String announce;
  final bool valid;
}

/// One successful fetch.
class SubscriptionFetchResult {
  const SubscriptionFetchResult({
    required this.body,
    required this.headers,
    required this.metadata,
    required this.fileName,
    required this.statusCode,
    required this.finalUrl,
  });

  final String body;

  /// Lower-cased header names.
  final Map<String, String> headers;
  final SubscriptionMetadata metadata;
  final String fileName;
  final int statusCode;
  final String finalUrl;
}

/// A fetch failure whose message is safe to show/log (userinfo and URLs removed).
class SubscriptionTransportException implements Exception {
  const SubscriptionTransportException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The HTTP/decoding transport. No new dependency: `dart:io` only.
class SubscriptionHttpTransport {
  SubscriptionHttpTransport({
    HttpClient Function()? clientFactory,
    this.connectTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 10),
    this.maxBodyBytes = 64 * 1024 * 1024,
    this.maxDecodedBytes = 128 * 1024 * 1024,
    this.maxRedirects = 20,
  }) : _clientFactory = clientFactory ?? HttpClient.new;

  final HttpClient Function() _clientFactory;
  final Duration connectTimeout;
  final Duration idleTimeout;
  final int maxBodyBytes;
  final int maxDecodedBytes;
  final int maxRedirects;

  /// Fetches [url] as text. Throws [SubscriptionTransportException] for every
  /// failure; the message never contains credentials or the full URL.
  Future<SubscriptionFetchResult> fetch(
    String url, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final client = _clientFactory()
      ..autoUncompress = false
      ..connectionTimeout = connectTimeout
      ..idleTimeout = idleTimeout;
    try {
      return await _fetch(client, url, headers);
    } on SubscriptionTransportException {
      rethrow;
    } on Object catch (error) {
      throw SubscriptionTransportException(_redact('$error'));
    } finally {
      client.close(force: true);
    }
  }

  /// Redirect policy: the Kotlin reader refuses an HTTPS -> HTTP hop; both are
/// otherwise allowed. Exposed for the loopback redirect tests.
  static bool allowsRedirect(Uri from, Uri to) =>
      !(from.scheme == 'https' && to.scheme == 'http');

  /// The redacted form of an error message; public for the transport tests.
  static String redact(String message) => _redact(message);

  Future<SubscriptionFetchResult> _fetch(
    HttpClient client,
    String url,
    Map<String, String> headers,
  ) async {
    final parsed = Uri.tryParse(url.trim());
    if (parsed == null || !parsed.hasScheme) {
      throw const SubscriptionTransportException('Invalid subscription URL');
    }
    var current = parsed;
    if (current.scheme != 'http' && current.scheme != 'https') {
      throw SubscriptionTransportException(
        'Unsupported subscription scheme: ${current.scheme}',
      );
    }
    var authorization = _basicAuthorization(current);
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == 'authorization') {
        authorization ??= entry.value;
        break;
      }
    }
    var requestHeaders = Map<String, String>.from(headers)
      ..removeWhere((key, _) => key.toLowerCase() == 'authorization');
    // Redirects are walked here rather than by HttpClient: the Kotlin reader
    // caps them at 20, refuses https -> http and drops URL credentials on a
    // cross-origin hop. HttpClient's automatic follow does none of those.
    for (var hop = 0; ; hop++) {
      if (requestHeaders.containsKey('authorization')) {
        requestHeaders.remove('authorization');
      }
      if (authorization != null) {
        requestHeaders['authorization'] = authorization;
      }
      final clean = current.replace(userInfo: '');
      final request = await client.getUrl(clean);
      request.followRedirects = false;
      requestHeaders.forEach(request.headers.set);
      final response = await request.close();
      final status = response.statusCode;
      if (status >= 300 && status < 400) {
        final location = _header(response.headers, 'location');
        await response.drain<void>();
        if (location == null || location.isEmpty) {
          throw SubscriptionTransportException(
            'HTTP $status without a Location header',
          );
        }
        if (hop >= maxRedirects) {
          throw SubscriptionTransportException(
            'Too many redirects (more than $maxRedirects)',
          );
        }
        final next = current.resolve(location);
        if (!allowsRedirect(current, next)) {
          throw const SubscriptionTransportException(
            'Refusing to redirect from HTTPS to HTTP',
          );
        }
        if (next.origin != current.origin) {
          // URL credentials belong to the origin that advertised them.
          authorization = null;
        }
        current = next;
        continue;
      }
      if (status < 200 || status >= 300) {
        await response.drain<void>();
        throw SubscriptionTransportException('HTTP $status');
      }
      final bytes = await _readCapped(response);
      final decoded = _decodeBody(bytes);
      final text = utf8.decode(decoded, allowMalformed: true);
      final headerMap = <String, String>{};
      response.headers.forEach((name, values) {
        headerMap[name.toLowerCase()] = values.join(',');
      });
      return SubscriptionFetchResult(
        body: text,
        headers: headerMap,
        metadata: parseMetadata(headerMap, text),
        fileName: SubscriptionFileName.fromDisposition(
          headerMap['content-disposition'],
        ),
        statusCode: status,
        finalUrl: current.toString(),
      );
    }
  }

  Future<List<int>> _readCapped(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    final done = Completer<List<int>>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.listen(
      (chunk) {
        if (bytes.length + chunk.length > maxBodyBytes) {
          subscription.cancel();
          if (!done.isCompleted) {
            done.completeError(
              const SubscriptionTransportException(
                'Subscription body exceeds the configured size limit',
              ),
            );
          }
          return;
        }
        bytes.add(chunk);
      },
      onDone: () {
        if (!done.isCompleted) done.complete(bytes.takeBytes());
      },
      onError: (Object error) {
        if (!done.isCompleted) {
          done.completeError(SubscriptionTransportException(_redact('$error')));
        }
      },
      cancelOnError: true,
    );
    return done.future;
  }

  List<int> _decodeBody(List<int> bytes) {
    final decoded = _sniffCompression(bytes);
    if (decoded.length > maxDecodedBytes) {
      throw const SubscriptionTransportException(
        'Subscription body is larger than the 128 MiB decoded limit',
      );
    }
    return decoded;
  }

  /// Labeled or unlabeled gzip (`1f8b`) / zlib (`78xx`, mod 31) decompression,
  /// with the Kotlin reader's "unknown magic means plain text" rule.
  List<int> _sniffCompression(List<int> bytes) {
    if (bytes.length < 2) return bytes;
    final first = bytes[0];
    final second = bytes[1];
    if (first == 0x1f && second == 0x8b) {
      return gzip.decode(bytes);
    }
    if (first == 0x78 && ((first << 8) + second) % 31 == 0) {
      return zlib.decode(bytes);
    }
    return bytes;
  }

  /// `Subscription-UserInfo` + header/body-comment metadata, ported from
  /// `SubscriptionMetadata.read` (header wins, the body fills the gaps).
  static SubscriptionMetadata parseMetadata(
    Map<String, String> headers,
    String body,
  ) {
    final lower = <String, String>{
      for (final entry in headers.entries) entry.key.toLowerCase(): entry.value,
    };
    String header(String name) => lower[name] ?? '';
    ParsedQuota? quota;
    var userInfoSeen = false;
    final rawUserInfo = header('subscription-userinfo');
    if (rawUserInfo.isNotEmpty) {
      quota = parseQuotaHeader(rawUserInfo);
      userInfoSeen = quota != null;
    }
    var interval = parseUpdateInterval(
      header('profile-update-interval').isEmpty
          ? header('x-profile-update-interval')
          : header('profile-update-interval'),
    );
    var title = decodeHeaderValue(header('profile-title'));
    var webUrl = header('profile-web-page-url');
    var supportUrl = header('support-url');
    var announce = decodeHeaderValue(header('announce'));

    final head = _metadataHead(body);
    final lines = head.split(RegExp(r'\r\n|\r|\n'));
    for (final raw in lines) {
      final line = _trim(raw);
      if (line.isEmpty) continue;
      if (!line.startsWith('#') && !line.startsWith('//')) break;
      final comment = _trim(
        line.startsWith('//') ? line.substring(2) : line.substring(1),
      );
      final colon = comment.indexOf(':');
      if (colon < 0) continue;
      final key = _trim(comment.substring(0, colon)).toLowerCase();
      final value = _trim(comment.substring(colon + 1));
      if (!userInfoSeen && key.startsWith('subscription-userinfo')) {
        final parsed = parseQuotaHeader(value);
        if (parsed != null) {
          quota = parsed;
          userInfoSeen = true;
        }
      } else if (interval == 0 && key.startsWith('profile-update-interval')) {
        interval = parseUpdateInterval(value);
      } else if (title.isEmpty && key.startsWith('profile-title')) {
        title = decodeHeaderValue(value);
      } else if (webUrl.isEmpty && key.startsWith('profile-web-page-url')) {
        webUrl = value;
      } else if (supportUrl.isEmpty && key.startsWith('support-url')) {
        supportUrl = value;
      } else if (announce.isEmpty &&
          (key.startsWith('announce') || key.startsWith('notice'))) {
        announce = decodeHeaderValue(value);
      }
    }

    final valid = quota != null ||
        interval > 0 ||
        title.isNotEmpty ||
        webUrl.isNotEmpty ||
        supportUrl.isNotEmpty ||
        announce.isNotEmpty;
    return SubscriptionMetadata(
      upload: quota?.upload ?? 0,
      download: quota?.download ?? 0,
      total: quota?.total ?? 0,
      expire: quota?.expire ?? 0,
      hasQuota: quota != null,
      serverInterval: interval,
      title: title,
      webUrl: webUrl,
      supportUrl: supportUrl,
      announce: announce,
      valid: valid,
    );
  }

  /// `upload=1; download=2; total=3; expire=4`; null when no field parses.
  static ParsedQuota? parseQuotaHeader(String raw) {
    var seen = false;
    var upload = 0, download = 0, total = 0, expire = 0;
    for (final part in raw.split(';')) {
      final pair = part.split('=');
      if (pair.length != 2) continue;
      final key = pair[0].trim().toLowerCase();
      final value = pair[1].trim();
      if (value.isEmpty) continue;
      final number = int.tryParse(value);
      if (number == null) continue;
      switch (key) {
        case 'upload':
          upload = number;
          seen = true;
        case 'download':
          download = number;
          seen = true;
        case 'total':
          total = number;
          seen = true;
        case 'expire':
          expire = number;
          seen = true;
      }
    }
    if (!seen) return null;
    return ParsedQuota(upload: upload, download: download, total: total, expire: expire);
  }

  /// `base64:` values use url-safe base64 first, then lenient standard; an
  /// empty/undecodable value becomes "".
  static String decodeHeaderValue(String raw) {
    final value = raw.trim();
    if (!value.toLowerCase().startsWith('base64:')) return value;
    final payload = value.substring(7).trim();
    if (payload.isEmpty) return '';
    final decoded = _tryBase64(payload, urlSafe: true) ??
        _tryBase64(payload, urlSafe: false);
    if (decoded == null || decoded.isEmpty) return '';
    return utf8.decode(decoded, allowMalformed: true).trim();
  }

  /// Hours; h/d/s suffixes tolerated, clamped to 366 days. 0 for absent/invalid.
  static int parseUpdateInterval(String raw) {
    var text = raw.trim().replaceAll('"', '').replaceAll("'", '').toLowerCase();
    var unit = 3600;
    if (text.endsWith('h')) {
      text = text.substring(0, text.length - 1);
    } else if (text.endsWith('d')) {
      text = text.substring(0, text.length - 1);
      unit = 86400;
    } else if (text.endsWith('s')) {
      text = text.substring(0, text.length - 1);
      unit = 1;
    }
    final value = int.tryParse(text.trim());
    if (value == null || value <= 0) return 0;
    const maxHours = 24 * 366;
    final hours = (value > maxHours * 3600 ? maxHours * 3600 : value) * unit ~/ 3600;
    return hours.clamp(1, maxHours);
  }

  static String _metadataHead(String body) {
    var start = 0;
    const leadingTrim = ' \t\n\r\u000B\u000C\u00A0\uFEFF';
    while (start < body.length && leadingTrim.contains(body[start])) {
      start++;
    }
    var end = body.length;
    const trailingTrim = ' \t\n\r\u000B\u000C\u00A0';
    while (end > start && trailingTrim.contains(body[end - 1])) {
      end--;
    }
    final head = body.substring(start, end < start + 16384 ? end : start + 16384);
    final compact = head.replaceAll(RegExp(r'[ \t\n\r\u000B\u000C]'), '');
    if (compact.isEmpty || !_looksLikeBase64(compact)) return head;
    final even = compact.substring(0, compact.length & ~3);
    final decoded = _tryBase64(even, urlSafe: false);
    if (decoded == null) return head;
    return utf8.decode(decoded, allowMalformed: true);
  }

  static bool _looksLikeBase64(String text) =>
      text.isNotEmpty && RegExp(r'^[A-Za-z0-9+/=_-]+$').hasMatch(text);

  static List<int>? _tryBase64(String text, {required bool urlSafe}) {
    var normalized = text.trim().replaceAll(RegExp(r'\s+'), '');
    if (urlSafe) {
      normalized = normalized.replaceAll('-', '+').replaceAll('_', '/');
    }
    final remainder = normalized.length % 4;
    if (remainder == 1) return null;
    if (remainder > 1) normalized += '=' * (4 - remainder);
    try {
      return base64.decode(normalized);
    } on FormatException {
      return null;
    }
  }

  static String? _basicAuthorization(Uri uri) {
    if (uri.userInfo.isEmpty) return null;
    final decoded = Uri.decodeComponent(uri.userInfo);
    return 'Basic ${base64.encode(utf8.encode(decoded))}';
  }

  static String? _header(HttpHeaders headers, String name) {
    final values = headers[name];
    return values == null || values.isEmpty ? null : values.join(',');
  }

  static String _trim(String value) =>
      value.replaceFirst(RegExp(r'^[ \t\n\r\u000B\u000C\u00A0\uFEFF]+'), '')
          .replaceFirst(RegExp(r'[ \t\n\r\u000B\u000C\u00A0]+$'), '');

  /// Removes credentials, URL userinfo and the URL itself from an exception
  /// message. The log must name the failure, never the secret.
  static String _redact(String message) {
    var redacted = message.replaceAllMapped(
      RegExp(r'(https?://)[^/\s:@]+(:[^/\s@]+)?@', caseSensitive: false),
      (match) => '${match[1]}***@',
    );
    redacted = redacted.replaceAll(
      RegExp(r'https?://[^\s]+', caseSensitive: false),
      '<url>',
    );
    return redacted;
  }
}

/// Whether [url] can only be read by the host (a Dart isolate has no
/// ContentResolver). Front/landing-proxy groups also take the host seam; that
/// decision lives in the refresh service because it needs the group row.
bool subscriptionUrlNeedsHost(String url) =>
    url.trim().toLowerCase().startsWith('content://');

/// Parses the service engine's `subscription.fetch` host reply.
///
/// The host runs Kotlin's own `SubscriptionFetch`, so the body, metadata,
/// Content-Disposition filename and redirect/auth/cap semantics are the same
/// ones the legacy refresh saw. This class only re-shapes the reply map and
/// keeps the error-redaction contract: an error never carries a URL or a
/// credential (the host already redacted it; redacting again is harmless).
abstract final class SubscriptionHostFetchReply {
  /// True when the host explicitly said it cannot express this fetch; the
  /// caller keeps that group on the legacy Kotlin path.
  static bool isUnsupported(Object? raw) {
    final map = _stringKeyed(raw);
    return map != null && map['supported'] == false;
  }

  static SubscriptionFetchResult parse(Object? raw) {
    final map = _stringKeyed(raw);
    if (map == null) {
      throw const SubscriptionTransportException(
        'The host subscription fetch returned no result',
      );
    }
    final error = map['error'];
    if (error is String && error.isNotEmpty) {
      throw SubscriptionTransportException(SubscriptionHttpTransport.redact(error));
    }
    final body = map['body'];
    if (body is! String) {
      throw const SubscriptionTransportException(
        'The host subscription fetch returned no body',
      );
    }
    final headers = <String, String>{};
    final rawHeaders = map['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((key, value) {
        if (key is String && value is String) {
          headers[key.toLowerCase()] = value;
        }
      });
    }
    return SubscriptionFetchResult(
      body: body,
      headers: headers,
      metadata: _metadata(map['metadata']),
      fileName: map['fileName'] is String ? map['fileName'] as String : '',
      statusCode: _int(map['statusCode']),
      finalUrl: map['finalUrl'] is String ? map['finalUrl'] as String : '',
    );
  }

  static SubscriptionMetadata _metadata(Object? raw) {
    final map = _stringKeyed(raw);
    if (map == null) return const SubscriptionMetadata();
    return SubscriptionMetadata(
      upload: _int(map['upload']),
      download: _int(map['download']),
      total: _int(map['total']),
      expire: _int(map['expire']),
      hasQuota: map['hasQuota'] == true,
      serverInterval: _int(map['serverInterval']),
      title: _string(map['title']),
      webUrl: _string(map['webUrl']),
      supportUrl: _string(map['supportUrl']),
      announce: _string(map['announce']),
      valid: map['valid'] == true,
    );
  }

  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('$value') ?? 0;

  static String _string(Object? value) => value is String ? value : '';

  static Map<String, dynamic>? _stringKeyed(Object? raw) {
    if (raw is! Map) return null;
    final map = <String, dynamic>{};
    raw.forEach((key, value) {
      if (key is String) map[key] = value;
    });
    return map;
  }
}

/// The parsed `subscription-userinfo` fields.
class ParsedQuota {
  const ParsedQuota({
    required this.upload,
    required this.download,
    required this.total,
    required this.expire,
  });

  final int upload;
  final int download;
  final int total;
  final int expire;
}

/// RFC 5987 `Content-Disposition` filename (FlClash's getFileNameForDisposition).
class SubscriptionFileName {
  static final _star = RegExp(
    r'(?:^|;)\s*filename\*\s*=\s*([^;]*)',
    caseSensitive: false,
  );
  static final _plain = RegExp(
    r'(?:^|;)\s*filename\s*=\s*([^;]*)',
    caseSensitive: false,
  );

  static String fromDisposition(String? header) {
    if (header == null || header.trim().isEmpty) return '';
    final extended = _star.firstMatch(header)?.group(1)?.trim();
    if (extended != null && extended.isNotEmpty) {
      final decoded = _decodeExtended(extended);
      if (decoded.isNotEmpty) return _clean(decoded);
    }
    final plain = _plain.firstMatch(header)?.group(1)?.trim();
    return plain == null ? '' : _clean(plain);
  }

  static String _decodeExtended(String value) {
    final trimmed = value.trim().replaceAll(RegExp(r'^"|"$'), '');
    final parts = trimmed.split("'");
    final encoded = parts.length == 3 ? parts[2] : trimmed;
    try {
      return Uri.decodeComponent(encoded.replaceAll('+', '%2B'));
    } on FormatException {
      return '';
    }
  }

  static String _clean(String value) {
    var name = value.trim().replaceAll(RegExp(r'^"|"$'), '').trim();
    final slash = name.lastIndexOf(RegExp(r'[/\\]'));
    if (slash >= 0) name = name.substring(slash + 1);
    return name.trim();
  }
}