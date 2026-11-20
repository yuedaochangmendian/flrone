// THRN backup container codec (ADR 0005 phase 4).
//
// This is a byte-for-byte port of Kotlin `ThrBackup` (which is itself a port of
// the desktop's QDataStream container, dialog_basic_settings.cpp:492-835). It
// has no Room, Android or plugin dependency: the container is a pure byte
// protocol and belongs on the Dart side. The Room snapshot that fills the
// `database` entry is a separate concern and stays with Kotlin `BackupExport`
// until the data authority for those tables moves (see docs/adr/0005, phase 4).
//
// Wire layout (all integers little-endian, Qt_6_0):
//
//   "THRN"                       4 magic bytes
//   u32 version                  1..2 (FORMAT_VERSION = 2)
//   qstring metaJson             compact JSON, UTF-16LE, or 0xFFFFFFFF for null
//   u32 count                    number of file entries (0xFFFFFFFF is corrupt)
//   count * (qstring key, u32 size, size bytes of payload)
//
// `qstring` is `u32 byteLength` followed by UTF-16LE code units; 0xFFFFFFFF is
// the null marker. A QString size is even and at most 16 MiB. A file payload is
// at most 0xFFFFFFFD bytes (0xFFFFFFFE would announce a 64-bit size in Qt_6_7).
// Keys are written in ascending UTF-16 code-unit order, the order of Qt's QMap.
// Trailing bytes are ignored on read, exactly as Qt does.

import 'dart:convert';
import 'dart:typed_data';

/// BACKUP_FORMAT_VERSION from ThrBackup.kt. Only version 2 is written; 1 is
/// still read (a v1 container has no `parts` object in its meta).
const int thrnFormatVersion = 2;

/// BACKUP_CONTENT_VERSION, written into the meta, never read.
const int thrnContentVersion = 2;

const String thrnPlatformAndroid = 'android';
const String thrnDatabase = 'database';
const String thrnDesktopIcons = 'icons/';

final Uint8List _magic = Uint8List.fromList([0x54, 0x48, 0x52, 0x4E]); // THRN

const int _nullSize = 0xFFFFFFFF;
const int _maxSize = 0xFFFFFFFD;
const int _maxText = 16 << 20;

/// Why a container was refused. Matches Kotlin `ThrBackup.Kind` so callers can
/// tell "not a backup at all" (a plain document) from "a broken backup".
enum ThrnFailure { notBackup, unsupportedVersion, corrupt }

class ThrnFormatException implements Exception {
  const ThrnFormatException(this.kind, this.message, {this.version = 0});

  final ThrnFailure kind;
  final String message;
  final int version;

  @override
  String toString() => 'ThrnFormatException($kind, $message, version=$version)';
}

/// The backup parts the desktop reads from the meta. Mirrors
/// `ThrBackup.Parts`; only a JSON literal `true` counts (QJsonValue::toBool).
class ThrnParts {
  const ThrnParts({
    this.profiles = false,
    this.routes = false,
    this.settings = false,
    this.otp = false,
    this.icons = false,
  });

  final bool profiles;
  final bool routes;
  final bool settings;
  final bool otp;
  final bool icons;

  bool get anyDatabase => profiles || routes || settings || otp;
  bool get any => anyDatabase || icons;

  @override
  bool operator ==(Object other) =>
      other is ThrnParts &&
      other.profiles == profiles &&
      other.routes == routes &&
      other.settings == settings &&
      other.otp == otp &&
      other.icons == icons;

  @override
  int get hashCode => Object.hash(profiles, routes, settings, otp, icons);

  @override
  String toString() =>
      'ThrnParts(profiles: $profiles, routes: $routes, settings: $settings, otp: $otp, icons: $icons)';
}

/// A parsed container. [files] holds every entry's bytes (the codec keeps them
/// all — unlike Kotlin, which streams only `database` to disk); callers that
/// want the SQLite snapshot take `files[thrnDatabase]`.
class ThrnContainer {
  const ThrnContainer({
    required this.version,
    required this.meta,
    required this.files,
  });

  final int version;
  final Map<String, Object?> meta;
  final Map<String, Uint8List> files;

  Set<String> get keys => files.keys.toSet();
  Uint8List? get database => files[thrnDatabase];

  String get createdAt => _string(meta['created_at']);
  String get platform => _string(meta['platform']);
  bool get isAndroid => platform == thrnPlatformAndroid;
  String get deviceName => _string((meta['device'] as Map?)?['name']);

  /// `BackupExport` embeds the UI payload under `flrone_ui`. The first version
  /// of the branch nested that object twice; unwrap it once for old backups.
  Map<String, Object?> get flroneUi {
    Map<String, Object?> ui = _objectOrEmpty(meta['flrone_ui']);
    if (ui.containsKey('flrone_ui') &&
        !ui.containsKey('preferences') &&
        !ui.containsKey('settings') &&
        !ui.containsKey('quality')) {
      ui = _objectOrEmpty(ui['flrone_ui']);
    }
    return ui;
  }

  ThrnParts get parts => thrnPartsFromMeta(version, meta, keys);

  static String _string(Object? value) => value is String ? value : '';
  static Map<String, Object?> _objectOrEmpty(Object? value) =>
      value is Map ? value.map((k, v) => MapEntry<String, Object?>('$k', v)) : <String, Object?>{};
}

/// `BackupPartsFromMeta` (dialog_basic_settings.cpp:496-515): for v2 only a
/// `parts` object is consulted and only JSON `true` counts. Without it (or for
/// v1) every database part is available whenever a `database` entry exists.
ThrnParts thrnPartsFromMeta(int version, Map<String, Object?> meta, Iterable<String> keys) {
  final hasDatabase = keys.contains(thrnDatabase);
  final hasIcons = keys.any((key) => key.startsWith(thrnDesktopIcons));
  // Kotlin checks key presence (`meta.contains("parts")`), then reads through
  // `meta.obj("parts")`, which is empty when the value is not a JSON object.
  // A present-but-wrong-typed parts value therefore means "no parts", not the
  // v1 fallback — match that exactly (ThrBackupTest.partsFromMeta).
  if (version >= 2 && meta.containsKey('parts')) {
    final parts = meta['parts'] is Map ? meta['parts'] as Map : const <Object?, Object?>{};
    bool flag(String key) => parts[key] == true;
    return ThrnParts(
      profiles: flag('profiles') && hasDatabase,
      routes: flag('routes') && hasDatabase,
      settings: flag('settings') && hasDatabase,
      otp: flag('otp') && hasDatabase,
      icons: flag('icons') && hasIcons,
    );
  }
  return ThrnParts(
    profiles: hasDatabase,
    routes: hasDatabase,
    settings: hasDatabase,
    icons: hasIcons,
  );
}

/// Whether [bytes] start with the four magic bytes. Consumes nothing (a plain
/// document is not a broken backup), matching Kotlin `ThrBackup.hasMagic`.
bool thrnHasMagic(List<int> bytes) {
  if (bytes.length < _magic.length) return false;
  for (var i = 0; i < _magic.length; i++) {
    if (bytes[i] != _magic[i]) return false;
  }
  return true;
}

/// Encodes format 2 with [files] in QMap order (ascending UTF-16 code units).
/// The meta is written with Qt's compact JSON ordering so a Dart-produced
/// container is byte-identical to the Kotlin one for the same input.
Uint8List thrnEncode(Map<String, Object?> meta, Map<String, List<int>> files, {int version = thrnFormatVersion}) {
  final out = BytesBuilder(copy: false)
    ..add(_magic)
    ..add(_u32(version));
  final metaJson = qtCompactJson(meta);
  _writeQString(out, metaJson);
  out.add(_u32(files.length));
  final keys = files.keys.toList()..sort(_compareUtf16);
  for (final key in keys) {
    final payload = files[key]!;
    if (payload.length > _maxSize) {
      // The THRN frame carries one 32-bit length per entry; a readable failure
      // beats an ArgumentError stack for what is a size limit, not an argument
      // bug (the embedded database snapshots toward it on huge profiles).
      throw StateError(
        'The "$key" entry is too large for a backup '
        '(the format allows about 4 GiB per entry); export a smaller scope',
      );
    }
    _writeQString(out, key);
    out.add(_u32(payload.length));
    out.add(payload);
  }
  return out.takeBytes();
}

/// Reads a container. Trailing bytes are ignored, as Qt ignores them. Every
/// structural violation becomes a [ThrnFormatException] with the same kind as
/// the Kotlin reader, so callers can distinguish a shared document from damage.
ThrnContainer thrnDecode(List<int> bytes) {
  if (!thrnHasMagic(bytes)) {
    throw const ThrnFormatException(ThrnFailure.notBackup, 'Not a valid Throne backup file.');
  }
  final r = _Reader(bytes, offset: _magic.length);
  final version = r.u32();
  if (version < 1 || version > thrnFormatVersion) {
    throw ThrnFormatException(
      ThrnFailure.unsupportedVersion,
      'Unsupported backup format version: $version',
      version: version,
    );
  }
  final metaText = r.qstring();
  final meta = metaText == null
      ? <String, Object?>{}
      : _parseObjectOrEmpty(metaText);
  final count = r.u32();
  if (count == _nullSize) throw _corrupt('invalid entry count');
  final files = <String, Uint8List>{};
  for (var i = 0; i < count; i++) {
    final key = r.qstring();
    if (key == null) throw _corrupt('null entry name');
    final size = r.size();
    files[key] = Uint8List.fromList(r.bytes(size));
  }
  return ThrnContainer(version: version, meta: meta, files: files);
}

ThrnFormatException _corrupt(String what) =>
    ThrnFormatException(ThrnFailure.corrupt, 'Damaged backup file: $what');

Map<String, Object?> _parseObjectOrEmpty(String text) {
  try {
    final value = jsonDecode(text);
    if (value is Map) {
      return value.map((k, v) => MapEntry<String, Object?>('$k', v));
    }
  } catch (_) {
    // Kotlin falls back to an empty JsonObject for unparsable meta; a decode
    // must still succeed so `partsFromMeta` can treat it as "all DB parts".
  }
  return <String, Object?>{};
}

// ---------------------------------------------------------------------------
// bytes

Uint8List _u32(int v) => Uint8List.fromList([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);

void _writeQString(BytesBuilder out, String s) {
  final units = s.length;
  out.add(_u32(units * 2));
  final buf = BytesBuilder(copy: false);
  for (var i = 0; i < units; i++) {
    final c = s.codeUnitAt(i);
    buf.add([c & 0xFF, (c >> 8) & 0xFF]);
  }
  out.add(buf.takeBytes());
}

/// Java/Kotlin String.compareTo compares UTF-16 code units. Dart's compareTo
/// does the same, but spelling it out keeps the contract obvious at the call
/// that orders QMap keys.
int _compareUtf16(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  for (var i = 0; i < n; i++) {
    final x = a.codeUnitAt(i), y = b.codeUnitAt(i);
    if (x != y) return x - y;
  }
  return a.length - b.length;
}

class _Reader {
  _Reader(this._bytes, {int offset = 0}) : _offset = offset;

  final List<int> _bytes;
  int _offset;

  void _need(int n) {
    if (n < 0 || _offset + n > _bytes.length) {
      throw _corrupt('unexpected end of file');
    }
  }

  int u32() {
    _need(4);
    final v = _bytes[_offset] |
        (_bytes[_offset + 1] << 8) |
        (_bytes[_offset + 2] << 16) |
        (_bytes[_offset + 3] << 24);
    _offset += 4;
    return v;
  }

  int size() {
    final n = u32();
    if (n == _nullSize) return 0; // handled by qstring as the null marker
    if (n > _maxSize) throw _corrupt('invalid length');
    return n;
  }

  String? qstring() {
    final n = u32();
    if (n == _nullSize) return null;
    if (n > _maxSize) throw _corrupt('invalid length');
    if (n.isOdd) throw _corrupt('odd string length');
    if (n > _maxText) throw _corrupt('string too long');
    final data = bytes(n);
    final units = List<int>.generate(n ~/ 2, (i) => data[2 * i] | (data[2 * i + 1] << 8));
    try {
      return String.fromCharCodes(units);
    } catch (_) {
      // A lone surrogate cannot be represented in a Dart String; Qt keeps it.
      // Replace it rather than losing the whole container (the keys that carry
      // such data are icons, which the restore never consumes).
      return String.fromCharCodes(units.map((u) => u >= 0xD800 && u <= 0xDFFF ? 0xFFFD : u));
    }
  }

  List<int> bytes(int n) {
    _need(n);
    final out = _bytes.sublist(_offset, _offset + n);
    _offset += n;
    return out;
  }
}

// ---------------------------------------------------------------------------
// Qt-compatible compact JSON (JsonWriter.kt / QJsonDocument::Compact)

/// Serialises [value] with the key ordering, escaping and number formatting of
/// Kotlin `JsonWriter`: keys sorted by UTF-16 code unit, no whitespace, only
/// `"` `\` and C0 controls escaped, non-ASCII emitted literally.
String qtCompactJson(Object? value) {
  final sb = StringBuffer();
  _appendJson(sb, value);
  return sb.toString();
}

void _appendJson(StringBuffer sb, Object? value) {
  if (value == null) {
    sb.write('null');
  } else if (value is bool) {
    sb.write(value ? 'true' : 'false');
  } else if (value is String) {
    _appendJsonString(sb, value);
  } else if (value is int) {
    sb.write(value);
  } else if (value is num) {
    sb.write(_qtDouble(value.toDouble()));
  } else if (value is Map) {
    sb.write('{');
    var first = true;
    final keys = value.keys.map((k) => '$k').toList()..sort(_compareUtf16);
    for (final key in keys) {
      if (!first) sb.write(',');
      first = false;
      _appendJsonString(sb, key);
      sb.write(':');
      _appendJson(sb, value[key]);
    }
    sb.write('}');
  } else if (value is Iterable) {
    sb.write('[');
    var first = true;
    for (final item in value) {
      if (!first) sb.write(',');
      first = false;
      _appendJson(sb, item);
    }
    sb.write(']');
  } else {
    throw ArgumentError.value(value, 'value', 'unsupported JSON value type');
  }
}

const String _hex = '0123456789abcdef';

void _appendJsonString(StringBuffer sb, String s) {
  sb.write('"');
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c == 0x22) {
      sb.write('\\"');
    } else if (c == 0x5C) {
      sb.write('\\\\');
    } else if (c < 0x20) {
      switch (c) {
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
          sb.write('\\u00${_hex[c >> 4]}${_hex[c & 0xF]}');
      }
    } else if (c >= 0xD800 && c <= 0xDBFF &&
        i + 1 < s.length &&
        s.codeUnitAt(i + 1) >= 0xDC00 &&
        s.codeUnitAt(i + 1) <= 0xDFFF) {
      // A valid surrogate pair is emitted verbatim (as Qt does).
      sb.write(String.fromCharCodes([c, s.codeUnitAt(i + 1)]));
      i++;
    } else if (c >= 0xD800 && c <= 0xDFFF) {
      sb.write('\\u${_hex[(c >> 12) & 0xF]}${_hex[(c >> 8) & 0xF]}${_hex[(c >> 4) & 0xF]}${_hex[c & 0xF]}');
    } else {
      sb.writeCharCode(c);
    }
  }
  sb.write('"');
}

const int _maxExactDouble = 9007199254740992; // 2^53

/// Integral doubles within +-2^53 print as integers (QJsonValue behaviour);
/// Dart's [double.toString] is already the shortest round-trip representation,
/// which is what Qt's 'g' formatting asks for. The meta schema carries only
/// ints, bools and strings, so this path is defensive rather than hot.
String _qtDouble(double d) {
  if (d.isNaN || d.isInfinite) return 'null';
  if (d == d.roundToDouble() && d.abs() <= _maxExactDouble) {
    return d.toInt().toString();
  }
  return d.toString();
}

/// `ThrBackup.androidMeta`: the fixed-shape meta an Android backup carries.
Map<String, Object?> thrnAndroidMeta({
  required ThrnParts parts,
  required String appVersion,
  required String deviceId,
  required String deviceName,
  required String createdAt,
}) =>
    <String, Object?>{
      'android': <String, Object?>{
        'app_version': appVersion,
        'icons': false,
      },
      'app_version': appVersion,
      'backup_version': thrnContentVersion,
      'created_at': createdAt,
      'device': <String, Object?>{'id': deviceId, 'name': deviceName},
      'parts': <String, Object?>{
        'icons': false,
        'otp': parts.otp,
        'profiles': parts.profiles,
        'routes': parts.routes,
        'settings': parts.settings,
      },
      'platform': thrnPlatformAndroid,
    };

const List<String> _weekdays = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const List<String> _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `ThrBackup.textDate`: `SimpleDateFormat("EEE MMM d HH:mm:ss yyyy", Locale.US)`
/// in local time, e.g. "Fri Sep 4 03:43:00 2026" (no zero padding on the day).
String thrnTextDate(DateTime date) {
  final d = date.toLocal();
  final weekday = _weekdays[d.weekday % 7]; // Dart: Mon=1..Sun=7; Java: Sun=0
  final month = _months[d.month - 1];
  return '$weekday $month ${d.day} ${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)} ${d.year}';
}

String _two(int v) => v.toString().padLeft(2, '0');

// ---------------------------------------------------------------------------
// SHA-256 (no package dependency; the WebDAV index verifies downloaded bytes)

/// Lower-case hex SHA-256 of [bytes], matching Kotlin `WebDavBackup.hex(digest)`
/// over `MessageDigest.getInstance("SHA-256")`.
String thrnSha256Hex(List<int> bytes) {
  final digest = _Sha256()..update(bytes);
  final out = digest.finalize();
  return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

class _Sha256 {
  _Sha256() : _state = List<int>.from(_initial);

  static const int _mask = 0xFFFFFFFF;
  static const List<int> _initial = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];
  static const List<int> _k = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final List<int> _state;
  final List<int> _buffer = <int>[];
  int _length = 0;

  void update(List<int> data) {
    _buffer.addAll(data);
    _length += data.length;
    while (_buffer.length >= 64) {
      _block(_buffer.sublist(0, 64));
      _buffer.removeRange(0, 64);
    }
  }

  Uint8List finalize() {
    // Pad to a multiple of 64 with the 64-bit big-endian message length in the
    // last 8 bytes. The padding bytes are absorbed directly (not via update),
    // so _length keeps the original message size for the length field.
    final bitLength = _length * 8;
    final finalBuffer = List<int>.from(_buffer)..add(0x80);
    while (finalBuffer.length % 64 != 56) {
      finalBuffer.add(0);
    }
    for (var i = 7; i >= 0; i--) {
      finalBuffer.add((bitLength >> (8 * i)) & 0xFF);
    }
    _buffer.clear();
    while (finalBuffer.length >= 64) {
      _block(finalBuffer.sublist(0, 64));
      finalBuffer.removeRange(0, 64);
    }
    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      final v = _state[i];
      out[4 * i] = (v >> 24) & 0xFF;
      out[4 * i + 1] = (v >> 16) & 0xFF;
      out[4 * i + 2] = (v >> 8) & 0xFF;
      out[4 * i + 3] = v & 0xFF;
    }
    return out;
  }

  void _block(List<int> chunk) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      w[i] = (chunk[4 * i] << 24) |
          (chunk[4 * i + 1] << 16) |
          (chunk[4 * i + 2] << 8) |
          chunk[4 * i + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _ror(w[i - 15], 7) ^ _ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _ror(w[i - 2], 17) ^ _ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
    }
    var a = _state[0], b = _state[1], c = _state[2], d = _state[3];
    var e = _state[4], f = _state[5], g = _state[6], h = _state[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _ror(e, 6) ^ _ror(e, 11) ^ _ror(e, 25);
      final ch = (e & f) ^ ((~e) & g);
      final t1 = (h + s1 + ch + _k[i] + w[i]) & _mask;
      final s0 = _ror(a, 2) ^ _ror(a, 13) ^ _ror(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask;
      h = g; g = f; f = e; e = (d + t1) & _mask;
      d = c; c = b; b = a; a = (t1 + t2) & _mask;
    }
    _state[0] = (_state[0] + a) & _mask;
    _state[1] = (_state[1] + b) & _mask;
    _state[2] = (_state[2] + c) & _mask;
    _state[3] = (_state[3] + d) & _mask;
    _state[4] = (_state[4] + e) & _mask;
    _state[5] = (_state[5] + f) & _mask;
    _state[6] = (_state[6] + g) & _mask;
    _state[7] = (_state[7] + h) & _mask;
  }

  int _ror(int v, int n) => ((v >> n) | (v << (32 - n))) & _mask;
}
