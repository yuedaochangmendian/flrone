// WebDAV backup folder protocol (ADR 0005 phase 4).
//
// A direct port of Kotlin `WebDavBackup`: `.thrbackup` files in a WebDAV folder
// plus a `throne_backups.json` index shared with the desktop (contract v1). The
// HTTP transport is `WebDavClient` (phase 0/1); this layer owns the folder
// listing, the index read-modify-write under ETag, and file naming. It is pure
// Dart and testable against an in-process HttpServer.
//
// The THRN container bytes themselves still come from / go to the Kotlin
// `backup.create` / `backup.restore` handlers, because filling them needs the
// Room snapshot (see docs/adr/0005 phase 4 and the note in backup_store.dart).
// This module owns everything around those bytes: where they are stored, the
// index that describes them, and integrity checks on download.

import 'dart:convert';

import '../services/backup_store.dart' show thrnSha256Hex, thrnDecode, ThrnFormatException;
import 'webdav_client.dart' show WebDavClient, WebDavException, WebDavResponse;

const String backupExtension = '.thrbackup';
const String backupIndexFile = 'throne_backups.json';

const String partProfiles = 'profiles';
const String partRoutes = 'routes';
const String partSettings = 'settings';
const String partOtp = 'otp';
const String partIcons = 'icons';

const int _indexFormat = 1;
const int _indexRounds = 4;
const int _maxIndexBytes = 4 << 20;
const int _maxEntries = 1000;
const int _displayMax = 200;

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _stampPattern = RegExp(r'\d{8}_\d{6}');
final RegExp _unsafeVersion = RegExp(r'[^A-Za-z0-9._-]');

/// Text from the server, safe to display: control characters (including line
/// breaks) become spaces and the result is capped at 200 characters — Kotlin
/// `WebDavBackup.plain`.
String webdavPlain(String text) {
  final out = StringBuffer();
  for (final rune in text.runes) {
    out.writeCharCode((rune < 0x20 || (rune >= 0x7f && rune <= 0x9f)) ? 0x20 : rune);
  }
  final trimmed = out.toString().trim();
  return trimmed.length > _displayMax ? trimmed.substring(0, _displayMax) : trimmed;
}

/// A backup in the WebDAV folder, matching Kotlin `WebDavBackup.Entry`.
class WebDavBackupEntry {
  const WebDavBackupEntry({
    required this.file,
    required this.createdAt,
    required this.size,
    required this.deviceName,
    required this.platform,
    required this.appVersion,
    required this.parts,
    required this.indexed,
    required this.thisDevice,
    this.expectedSize = -1,
    this.expectedSha256 = '',
  });

  final String file;
  final int createdAt; // epoch ms, 0 = unknown
  final int size; // -1 = unknown
  final String deviceName;
  final String platform;
  final String appVersion;
  final List<String> parts;
  final bool indexed;
  final bool thisDevice;
  final int expectedSize;
  final String expectedSha256;
}

class _Listed {
  const _Listed(this.name, this.size, this.modified);
  final String name;
  final int size;
  final int modified;
}

class _Index {
  _Index(this.root, this.entries, this.format, this.etag, this.existed);

  final Map<String, Object?> root;
  final List<Map<String, Object?>> entries;
  final int format;
  final String? etag;
  final bool existed;
}

/// What the controller needs from a WebDAV backup transport. An interface so
/// widget tests can inject a deterministic fake without standing up HTTP or
/// Room. The concrete [WebDavBackupService] implements it over [WebDavClient].
abstract class WebDavBackupTransport {
  Future<WebDavUploadResult> upload(List<int> bytes, Set<String> parts);
  Future<List<WebDavBackupEntry>> list();
  Future<List<int>> download(WebDavBackupEntry entry);
}

/// The WebDAV backup folder: listing, index and integrity checks.
class WebDavBackupService implements WebDavBackupTransport {
  WebDavBackupService(this._client, {this.deviceId = '', this.deviceName = '', this.appVersion = ''});

  final WebDavClient _client;
  final String deviceId;
  final String deviceName;
  final String appVersion;

  /// Builds a service from the Dart-owned account, or returns null when no
  /// account is configured. Mirrors Kotlin `WebDavBackup.configured()`.
  static WebDavBackupService? fromAccount(
    Map<String, dynamic>? account, {
    String deviceId = '',
    String deviceName = '',
    String appVersion = '',
  }) {
    final uri = account?['uri'];
    if (uri is! String || uri.trim().isEmpty) return null;
    return WebDavBackupService(
      WebDavClient(
        uri: uri,
        user: account?['user'] is String ? account!['user'] as String : '',
        password: account?['password'] is String ? account!['password'] as String : '',
        directory: account?['fileName'] is String ? account!['fileName'] as String : '',
      ),
      deviceId: deviceId,
      deviceName: deviceName,
      appVersion: appVersion,
    );
  }

  /// Ensures the folder exists, then uploads [bytes] under a fresh timestamped
  /// name and records it in the index. The PUT decides success; a failed index
  /// update is returned (not thrown) as [WebDavUploadResult.indexError].
  @override
  Future<WebDavUploadResult> upload(List<int> bytes, Set<String> parts) async {
    await _ensureDirectory();
    final now = DateTime.now().toUtc();
    final name = backupFileName(appVersion, now);
    final digest = thrnSha256Hex(bytes);
    // PUT is authoritative; a non-2xx throws a WebDavException.
    await _client.uploadBytes(name, bytes);
    final entry = <String, Object?>{
      'file': name,
      'created_at': isoUtc(now),
      'size': bytes.length,
      'sha256': digest,
      'device_id': deviceId,
      'device_name': deviceName,
      'platform': 'android',
      'app_version': appVersion,
      'parts': parts.toList(),
    };
    final indexError = await _updateSafely((entries) {
      entries.removeWhere((e) => e['file'] == name);
      entries.insert(0, entry);
    }, keep: name);
    return WebDavUploadResult(name, indexError);
  }

  /// Lists the folder's backups joined with the index, newest first. Returns
  /// an empty list when the folder does not exist.
  @override
  Future<List<WebDavBackupEntry>> list() async {
    final listed = await _listFolder();
    if (listed == null) return <WebDavBackupEntry>[];
    List<Map<String, Object?>> index;
    try {
      index = (await _readIndex()).entries;
    } on WebDavException {
      index = <Map<String, Object?>>[];
    }
    final byFile = <String, Map<String, Object?>>{};
    for (final entry in index) {
      final name = entry['file'];
      if (name is String) byFile.putIfAbsent(name, () => entry);
    }
    final self = deviceId;
    final out = listed.map((remote) {
      final indexedEntry = byFile[remote.name];
      return indexedEntry == null
          ? _synthesized(remote)
          : _indexed(indexedEntry, remote, self);
    }).toList()
      ..sort((a, b) {
        final byDate = b.createdAt.compareTo(a.createdAt);
        return byDate != 0 ? byDate : b.file.compareTo(a.file);
      });
    return out;
  }

  /// Downloads [entry], verifies its size and SHA-256 when the index has them,
  /// and returns the raw container bytes. A container that cannot be decoded
  /// throws a [WebDavException] so a corrupt remote backup never reaches restore.
  @override
  Future<List<int>> download(WebDavBackupEntry entry) async {
    final bytes = await _client.downloadBytes(entry.file);
    if (entry.expectedSize >= 0 || entry.expectedSha256.isNotEmpty) {
      final sizeOk = entry.expectedSize < 0 || entry.expectedSize == bytes.length;
      final shaOk = entry.expectedSha256.isEmpty ||
          thrnSha256Hex(bytes) == entry.expectedSha256;
      if (!sizeOk || !shaOk) {
        throw const WebDavException('The remote backup was changed or damaged');
      }
    }
    try {
      thrnDecode(bytes); // also rejects a non-THRN file in the folder
    } on ThrnFormatException catch (e) {
      throw WebDavException('The remote backup cannot be read: $e');
    }
    return bytes;
  }

  /// Deletes [entry]'s file (404 is fine) and drops it from the index.
  Future<String?> delete(WebDavBackupEntry entry) async {
    final response = await _client.send('DELETE', entry.file);
    if (response.statusCode != 404) _requireOk(response);
    return _updateSafely((entries) {
      entries.removeWhere((e) => e['file'] == entry.file);
    }, keep: null);
  }

  // ---------------------------------------------------------------------- index

  Future<String?> _updateSafely(void Function(List<Map<String, Object?>>) change, {required String? keep}) async {
    try {
      await _updateIndex(change, keep: keep);
      return null;
    } on Object catch (error) {
      return '$error';
    }
  }

  Future<void> _updateIndex(void Function(List<Map<String, Object?>>) change, {required String? keep}) async {
    for (var round = 1; round <= _indexRounds; round++) {
      final index = await _readIndex();
      if (index.format > _indexFormat) return; // newer writer; leave untouched
      final folder = await _listFolder();
      final listed = folder == null
          ? <String>{}
          : folder.map((e) => e.name).toSet();
      final entries = index.entries;
      entries.removeWhere((e) {
        final name = e['file'];
        return name is! String || (name != keep && !listed.contains(name));
      });
      change(entries);
      final ordered = <Map<String, Object?>>[...entries]
        ..sort((a, b) => _parseIso(b['created_at']).compareTo(_parseIso(a['created_at'])));
      if (ordered.length > _maxEntries) ordered.removeRange(_maxEntries, ordered.length);
      index.root['format'] = _indexFormat;
      index.root['backups'] = ordered;
      final body = utf8.encode(qtIndexJson(index.root));
      final headers = <String, String>{};
      if (round < _indexRounds) {
        if (index.etag != null) {
          headers['If-Match'] = index.etag!;
        } else if (!index.existed) {
          headers['If-None-Match'] = '*';
        }
      }
      final response = await _client.send(
        'PUT',
        backupIndexFile,
        body: body,
        contentType: 'application/json',
        headers: headers,
      );
      if (response.statusCode == 412 && round < _indexRounds) continue;
      _requireOk(response);
      return;
    }
  }

  Future<_Index> _readIndex() async {
    final response = await _client.send('GET', backupIndexFile);
    if (response.statusCode == 404) {
      return _Index(<String, Object?>{}, <Map<String, Object?>>[], _indexFormat, null, false);
    }
    _requireOk(response);
    if (response.body.length > _maxIndexBytes) {
      return _Index(<String, Object?>{}, <Map<String, Object?>>[], _indexFormat, response.etag, true);
    }
    Map<String, Object?> root;
    try {
      var text = utf8.decode(response.body, allowMalformed: true);
      if (text.startsWith('\uFEFF')) text = text.substring(1);
      final parsed = jsonDecode(text);
      root = parsed is Map
          ? parsed.map((k, v) => MapEntry<String, Object?>('$k', v))
          : <String, Object?>{};
    } catch (_) {
      root = <String, Object?>{};
    }
    final format = root['format'] is int ? root['format'] as int : _indexFormat;
    final seen = <String>{};
    final entries = <Map<String, Object?>>[];
    final backups = root['backups'];
    if (backups is List) {
      for (final item in backups) {
        if (item is! Map) continue;
        final entry = item.map((k, v) => MapEntry<String, Object?>('$k', v));
        final name = entry['file'];
        if (name is String && _isSafeName(name) && seen.add(name)) entries.add(entry);
      }
    }
    return _Index(root, entries, format, response.etag, true);
  }

  // ---------------------------------------------------------------------- listing

  Future<List<_Listed>?> _listFolder() async {
    final response = await _client.propfindFolder(1);
    if (response.statusCode == 404) return null;
    _requireOk(response);
    return _parseMultistatus(utf8.decode(response.body, allowMalformed: true));
  }

  List<_Listed> _parseMultistatus(String xml) {
    // WebDAV namespace prefixes vary; match local tag names without binding a
    // namespace. Each <response> contributes one file when it is not a
    // collection and its href ends in .thrbackup.
    final out = <_Listed>[];
    for (final responseMatch in RegExp(r'<(?:[A-Za-z0-9_-]+:)?response\b[^>]*>(.*?)</(?:[A-Za-z0-9_-]+:)?response>', dotAll: true).allMatches(xml)) {
      final block = responseMatch.group(1) ?? '';
      final isCollection = RegExp(r'<(?:[A-Za-z0-9_-]+:)?collection\s*/>').hasMatch(block);
      final hrefMatch = RegExp(r'<(?:[A-Za-z0-9_-]+:)?href\b[^>]*>(.*?)</(?:[A-Za-z0-9_-]+:)?href>', dotAll: true).firstMatch(block);
      if (hrefMatch == null || isCollection) continue;
      var href = hrefMatch.group(1)!.trim();
      try {
        href = Uri.decodeFull(href);
      } catch (_) {}
      final name = href.split('/').where((s) => s.isNotEmpty).lastOrNull;
      if (name == null || !name.toLowerCase().endsWith(backupExtension)) continue;
      int size = -1;
      final sizeMatch = RegExp(r'<(?:[A-Za-z0-9_-]+:)?getcontentlength\b[^>]*>(.*?)</(?:[A-Za-z0-9_-]+:)?getcontentlength>', dotAll: true).firstMatch(block);
      if (sizeMatch != null) size = int.tryParse(sizeMatch.group(1)!.trim()) ?? -1;
      int modified = 0;
      final modifiedMatch = RegExp(r'<(?:[A-Za-z0-9_-]+:)?getlastmodified\b[^>]*>(.*?)</(?:[A-Za-z0-9_-]+:)?getlastmodified>', dotAll: true).firstMatch(block);
      if (modifiedMatch != null) modified = _parseHttpDate(modifiedMatch.group(1)!.trim());
      out.add(_Listed(name, size, modified));
    }
    // Distinct by name, first wins (Kotlin distinctBy).
    final seen = <String>{};
    return out.where((e) => seen.add(e.name)).toList();
  }

  WebDavBackupEntry _indexed(Map<String, Object?> o, _Listed listed, String self) {
    final expectedSize = o['size'] is int && (o['size'] as int) >= 0 ? o['size'] as int : -1;
    final device = o['device_id'];
    final sha = o['sha256'];
    final shaText = sha is String ? sha.toLowerCase() : '';
    return WebDavBackupEntry(
      file: listed.name,
      createdAt: _parseIso(o['created_at']) > 0 ? _parseIso(o['created_at']) : listed.modified,
      size: expectedSize >= 0 ? expectedSize : listed.size,
      deviceName: webdavPlain(o['device_name'] is String ? o['device_name'] as String : ''),
      platform: webdavPlain(o['platform'] is String ? o['platform'] as String : ''),
      appVersion: webdavPlain(o['app_version'] is String ? o['app_version'] as String : ''),
      parts: (o['parts'] is List)
          ? (o['parts'] as List).whereType<String>().map(webdavPlain).toList()
          : <String>[],
      indexed: true,
      thisDevice: device is String && device.isNotEmpty && device == self,
      expectedSize: expectedSize,
      expectedSha256: _sha256Pattern.hasMatch(shaText) ? shaText : '',
    );
  }

  WebDavBackupEntry _synthesized(_Listed listed) => WebDavBackupEntry(
        file: listed.name,
        createdAt: listed.modified > 0 ? listed.modified : _stampTime(listed.name),
        size: listed.size,
        deviceName: '',
        platform: '',
        appVersion: '',
        parts: const <String>[],
        indexed: false,
        thisDevice: false,
      );

  // ---------------------------------------------------------------------- folder

  Future<void> _ensureDirectory() async {
    // `check()` already does PROPFIND Depth 0 + MKCOL per segment in the
    // transport; reuse it so the two paths cannot drift.
    await _client.check();
  }

  // ---------------------------------------------------------------------- helpers

  static void _requireOk(WebDavResponse response) {
    final code = response.statusCode;
    // 207 Multi-Status is the successful PROPFIND answer and falls in this range.
    if (code >= 200 && code < 300) return;
    final location = response.headers['location'];
    throw WebDavException(_describeStatus(code, location), statusCode: code);
  }

  static String _describeStatus(int code, String? location) {
    if (code >= 300 && code <= 399) return 'The WebDAV server redirected to $location';
    switch (code) {
      case 401:
        return 'WebDAV authentication failed';
      case 403:
        return 'WebDAV access denied';
      case 404:
        return 'The WebDAV folder was not found';
      default:
        return 'The WebDAV server returned an error ($code)';
    }
  }
}

class WebDavUploadResult {
  const WebDavUploadResult(this.file, this.indexError);

  final String file;
  final String? indexError;
}

/// The seam the controller uses for WebDAV backup transport. Injectable so
/// widget tests exercise the page without an HTTP server or Room. [account] is
/// the Dart-owned map; [appVersion] is the app version used for file naming.
/// Returning null means "no account configured" (the old `configured()` null).
typedef WebDavBackupFactory = WebDavBackupTransport? Function(
  Map<String, dynamic>? account, {
  String appVersion,
});

/// The default factory used in production.
WebDavBackupService? defaultWebDavBackupFactory(
  Map<String, dynamic>? account, {
  String appVersion = '',
}) =>
    WebDavBackupService.fromAccount(account, appVersion: appVersion);

/// `throne_backup_<version>_<UTC yyyyMMdd_HHmmss>_<4 hex>.thrbackup` — the
/// random suffix lets two devices upload in the same second.
String backupFileName(String version, DateTime utc) {
  final safe = version.replaceAll(_unsafeVersion, '-');
  final stamp = '${_four(utc.year)}${_two(utc.month)}${_two(utc.day)}_'
      '${_two(utc.hour)}${_two(utc.minute)}${_two(utc.second)}';
  // No dart:math: derive 4 hex digits from the name and clock, deterministic
  // enough to avoid a dependency while still separating same-second uploads.
  final seed = '$safe$stamp${utc.microsecondsSinceEpoch}';
  var hash = 0x811c9dc5;
  for (final c in seed.codeUnits) {
    hash = ((hash ^ c) * 0x01000193) & 0xFFFFFFFF;
  }
  return 'throne_backup_${safe}_${stamp}_${hash.toRadixString(16).padLeft(8, '0').substring(0, 4)}$backupExtension';
}

String isoUtc(DateTime utc) =>
    '${_four(utc.year)}-${_two(utc.month)}-${_two(utc.day)}T'
    '${_two(utc.hour)}:${_two(utc.minute)}:${_two(utc.second)}Z';

String _four(int v) => v.toString().padLeft(4, '0');
String _two(int v) => v.toString().padLeft(2, '0');

int _parseIso(Object? value) {
  if (value is! String || value.isEmpty) return 0;
  final parsed = DateTime.tryParse(value);
  if (parsed == null) return 0;
  return parsed.toUtc().millisecondsSinceEpoch;
}

int _parseHttpDate(String text) {
  // RFC 1123: "EEE, dd MMM yyyy HH:mm:ss zzz".
  final match = RegExp(r'^\w+,\s*(\d{1,2})\s+(\w+)\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})').firstMatch(text);
  if (match == null) return 0;
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final month = months.indexOf(match.group(2)!);
  if (month < 0) return 0;
  return DateTime.utc(
    int.parse(match.group(3)!), month + 1, int.parse(match.group(1)!),
    int.parse(match.group(4)!), int.parse(match.group(5)!), int.parse(match.group(6)!),
  ).millisecondsSinceEpoch;
}

int _stampTime(String name) {
  final match = _stampPattern.firstMatch(name);
  if (match == null) return 0;
  final stamp = match.group(0)!;
  return DateTime.utc(
    int.parse(stamp.substring(0, 4)), int.parse(stamp.substring(4, 6)), int.parse(stamp.substring(6, 8)),
    int.parse(stamp.substring(9, 11)), int.parse(stamp.substring(11, 13)), int.parse(stamp.substring(13, 15)),
  ).millisecondsSinceEpoch;
}

bool _isSafeName(String name) =>
    !name.contains('/') &&
    !name.contains('\\') &&
    name != '.' &&
    name != '..' &&
    name.toLowerCase().endsWith(backupExtension);

/// Compact, sorted-key JSON for the index (Qt-compatible, same writer as the
/// THRN meta). Imported lazily to keep the two services independent.
String qtIndexJson(Map<String, Object?> root) {
  final buffer = StringBuffer();
  void write(Object? value) {
    if (value == null) {
      buffer.write('null');
    } else if (value is bool) {
      buffer.write(value ? 'true' : 'false');
    } else if (value is String) {
      _writeString(buffer, value);
    } else if (value is int) {
      buffer.write(value);
    } else if (value is num) {
      buffer.write(value);
    } else if (value is Map) {
      buffer.write('{');
      var first = true;
      final keys = value.keys.map((k) => '$k').toList()..sort();
      for (final key in keys) {
        if (!first) buffer.write(',');
        first = false;
        _writeString(buffer, key);
        buffer.write(':');
        write(value[key]);
      }
      buffer.write('}');
    } else if (value is Iterable) {
      buffer.write('[');
      var first = true;
      for (final item in value) {
        if (!first) buffer.write(',');
        first = false;
        write(item);
      }
      buffer.write(']');
    }
  }

  write(root);
  return buffer.toString();
}

void _writeString(StringBuffer sb, String s) {
  sb.write('"');
  for (final code in s.codeUnits) {
    switch (code) {
      case 0x22:
        sb.write('\\"');
      case 0x5C:
        sb.write('\\\\');
      case 0x08:
        sb.write('\\b');
      case 0x09:
        sb.write('\\t');
      case 0x0A:
        sb.write('\\n');
      case 0x0C:
        sb.write('\\f');
      case 0x0D:
        sb.write('\\r');
      default:
        if (code < 0x20) {
          sb.write('\\u00${code.toRadixString(16).padLeft(2, '0')}');
        } else {
          sb.writeCharCode(code);
        }
    }
  }
  sb.write('"');
}
