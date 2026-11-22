// THRN codec tests. Every fixture here is hand-built from the byte layout in
// Kotlin `ThrBackup` / `ThrBackupTest` — no device, Kotlin runtime or Room file
// needed. The `minimalLayout` and `androidMeta` expectations are copied from
// the Kotlin tests so a byte-level divergence fails loudly on the Dart side.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flrone/services/backup_store.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _u32(int v) => Uint8List.fromList([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);

Uint8List _qstring(String s) {
  final out = BytesBuilder(copy: false)..add(_u32(s.length * 2));
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    out.add([c & 0xFF, (c >> 8) & 0xFF]);
  }
  return out.takeBytes();
}

Uint8List _concat(List<List<int>> parts) {
  final out = BytesBuilder(copy: false);
  for (final p in parts) {
    out.add(p);
  }
  return out.takeBytes();
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer: for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Mirrors ThrBackupTest.container(): a raw container with optional null meta
/// and null-valued entries, so the decoder can be probed for Qt's edge cases.
Uint8List _container(
  int version,
  String? meta,
  List<(String?, List<int>?)> entries, {
  int? countOverride,
  String magic = 'THRN',
}) {
  final out = BytesBuilder(copy: false)
    ..add(utf8.encode(magic))
    ..add(_u32(version))
    ..add(meta == null ? _u32(0xFFFFFFFF) : _qstring(meta))
    ..add(_u32(countOverride ?? entries.length));
  for (final (key, value) in entries) {
    out.add(key == null ? _u32(0xFFFFFFFF) : _qstring(key));
    if (value == null) {
      out.add(_u32(0xFFFFFFFF));
    } else {
      out.add(_u32(value.length));
      out.add(value);
    }
  }
  return out.takeBytes();
}

const _sqliteHeader = 'SQLite format 3\u0000';

void main() {
  group('THRN byte layout (Kotlin fixture parity)', () {
    test('minimal container is byte-identical to ThrBackupTest.minimalLayout', () {
      // Kotlin writes {"platform":"android"} sorted; one "database" entry of
      // the 16-byte SQLite header. Expected bytes are lifted verbatim from
      // ThrBackupTest.minimalLayout(): magic, u32(2), qstring(meta), u32(1),
      // qstring("database"), u32(16), then the 16 header bytes.
      final exact = _concat([
        [0x54, 0x48, 0x52, 0x4E, 0x02, 0x00, 0x00, 0x00],
        _qstring('{"platform":"android"}'),
        _u32(1),
        _qstring('database'),
        _u32(16),
        utf8.encode(_sqliteHeader),
      ]);
      final encoded = thrnEncode(
        {'platform': 'android'},
        {thrnDatabase: utf8.encode(_sqliteHeader)},
      );
      expect(encoded, equals(exact));
    });

    test('androidMeta matches the Kotlin androidMetaIsCompactAndSorted string', () {
      final meta = thrnAndroidMeta(
        parts: const ThrnParts(routes: true),
        appVersion: '2.0',
        deviceId: 'device-id',
        deviceName: 'Pixel',
        createdAt: 'Fri Sep 4 03:43:00 2026',
      );
      expect(qtCompactJson(meta), equals(
        '{"android":{"app_version":"2.0","icons":false},"app_version":"2.0","backup_version":2,'
        '"created_at":"Fri Sep 4 03:43:00 2026","device":{"id":"device-id","name":"Pixel"},'
        '"parts":{"icons":false,"otp":false,"profiles":false,"routes":true,"settings":false},'
        '"platform":"android"}',
      ));
    });

    test('entries are ordered by UTF-16 code units (QMap order)', () {
      final files = <String, List<int>>{
        'icons/\uFFFD.png': [1],
        'icons/\uD83D\uDE00.png': [2], // 😀 surrogate pair 0xD83D < 0xFFFD
        'about.txt': [3],
        thrnDatabase: utf8.encode(_sqliteHeader),
      };
      final encoded = thrnEncode({'a': 1}, files);
      int pos(String key) => _indexOf(encoded, _qstring(key));
      final positions = [
        pos('about.txt'),
        pos(thrnDatabase),
        pos('icons/\uD83D\uDE00.png'),
        pos('icons/\uFFFD.png'),
      ];
      expect(positions, equals(positions.toList()..sort()));
    });
  });

  group('encode -> decode round trip', () {
    test('meta, all files and parts survive', () {
      final meta = thrnAndroidMeta(
        parts: const ThrnParts(profiles: true, settings: true),
        appVersion: '1.0',
        deviceId: 'dev',
        deviceName: 'Pixel',
        createdAt: 'Fri Sep 4 03:43:00 2026',
      );
      final db = Uint8List.fromList([
        ...utf8.encode(_sqliteHeader),
        ...List<int>.generate(70000, (i) => i & 0xFF),
      ]);
      final encoded = thrnEncode(meta, {
        thrnDatabase: db,
        'icons/Tun.png': [1, 2, 3],
      });
      final decoded = thrnDecode(encoded);
      expect(decoded.version, 2);
      expect(decoded.meta, equals(meta));
      expect(decoded.database, equals(db));
      expect(decoded.keys, equals({thrnDatabase, 'icons/Tun.png'}));
      expect(decoded.isAndroid, isTrue);
      expect(decoded.deviceName, 'Pixel');
      expect(decoded.parts, equals(const ThrnParts(profiles: true, settings: true)));
    });

    test('empty file map encodes and decodes (empty scope)', () {
      final encoded = thrnEncode({'parts': <String, Object?>{}}, const {});
      final decoded = thrnDecode(encoded);
      expect(decoded.files, isEmpty);
      expect(decoded.parts.any, isFalse);
    });

    test('null meta and a null-valued entry decode like Qt', () {
      // Kotlin ThrBackupTest.readsLikeQt: a null value is an empty entry, the
      // last of two equal keys wins, trailing bytes are ignored.
      final bytes = _concat([
        _container(2, '{"created_at":"Wed Sep 24 03:43:00 2026","platform":"winnt"}', [
          (thrnDatabase, [1, 2, 3]),
          ('icons/a.png', null),
          (thrnDatabase, utf8.encode(_sqliteHeader)),
        ]),
        utf8.encode('trailing'),
      ]);
      final decoded = thrnDecode(bytes);
      expect(decoded.createdAt, 'Wed Sep 24 03:43:00 2026');
      expect(decoded.platform, 'winnt');
      expect(decoded.keys, equals({thrnDatabase, 'icons/a.png'}));
      expect(decoded.database, equals(utf8.encode(_sqliteHeader)));
      expect(decoded.files['icons/a.png'], isEmpty);
    });

    test('flrone_ui unwraps a twice-nested legacy object', () {
      final bytes = thrnEncode({
        'flrone_ui': {'flrone_ui': {'preferences': {'theme': 2}}},
      }, {});
      expect(thrnDecode(bytes).flroneUi, equals({'preferences': {'theme': 2}}));
    });
  });

  group('parts from meta (ThrBackupTest.partsFromMeta)', () {
    const all = '{"parts":{"icons":true,"otp":true,"profiles":true,"routes":true,"settings":true}}';
    final db = (thrnDatabase, utf8.encode(_sqliteHeader));
    final icon = ('icons/Tun.png', [1]);

    ThrnParts partsOf(int version, String? meta, List<(String?, List<int>?)> entries) =>
        thrnDecode(_container(version, meta, entries)).parts;

    test('v2 true flags require their files', () {
      expect(partsOf(2, all, [db, icon]), equals(const ThrnParts(profiles: true, routes: true, settings: true, otp: true, icons: true)));
      expect(partsOf(2, all, [db]).icons, isFalse);
      expect(partsOf(2, all, [icon]).anyDatabase, isFalse);
      expect(partsOf(2, all, [icon]).icons, isTrue);
    });

    test('v1 and v2 without parts default to all DB parts', () {
      expect(partsOf(1, all, [db, icon]), equals(const ThrnParts(profiles: true, routes: true, settings: true, icons: true)));
      expect(partsOf(2, '{}', [db]), equals(const ThrnParts(profiles: true, routes: true, settings: true)));
      expect(partsOf(2, 'not json', [db]), equals(const ThrnParts(profiles: true, routes: true, settings: true)));
      expect(partsOf(2, null, [db]), equals(const ThrnParts(profiles: true, routes: true, settings: true)));
    });

    test('only a JSON literal true counts (QJsonValue::toBool)', () {
      const loose = '{"parts":{"profiles":1,"routes":"true","settings":true}}';
      expect(partsOf(2, loose, [db]), equals(const ThrnParts(settings: true)));
      expect(partsOf(2, '{"parts":[1]}', [db]), equals(const ThrnParts()));
    });
  });

  group('refuses what Qt refuses (ThrBackupTest.refusesWhatQtRefuses)', () {
    final db = (thrnDatabase, utf8.encode(_sqliteHeader));

    ThrnFailure failureOf(List<int> bytes) {
      try {
        thrnDecode(bytes);
        fail('expected a ThrnFormatException');
      } on ThrnFormatException catch (e) {
        return e.kind;
      }
    }

    test('bad magic', () {
      expect(failureOf(_concat([utf8.encode('THRX'), _u32(2)])), ThrnFailure.notBackup);
      expect(failureOf(utf8.encode('TH')), ThrnFailure.notBackup);
      expect(thrnHasMagic(_container(2, '{}', [db])), isTrue);
      expect(thrnHasMagic(utf8.encode('{"version":3}')), isFalse);
    });

    test('unknown version (0 and 3)', () {
      expect(failureOf(_container(3, '{}', [db])), ThrnFailure.unsupportedVersion);
      expect(failureOf(_container(0, '{}', [db])), ThrnFailure.unsupportedVersion);
    });

    test('corrupt: odd string, null key, truncation and invalid count/length', () {
      expect(
        failureOf(_concat([
          utf8.encode('THRN'), _u32(2), _u32(3), utf8.encode('abc'), _u32(0),
        ])),
        ThrnFailure.corrupt,
      );
      expect(failureOf(_container(2, '{}', [(null, [1])])), ThrnFailure.corrupt);
      final full = _container(2, '{}', [db]);
      expect(failureOf(full.sublist(0, full.length - 3)), ThrnFailure.corrupt);
      expect(
        failureOf(_concat([
          utf8.encode('THRN'), _u32(2), _qstring('{}'), _u32(1), _u32(0xFFFFFFFE),
        ])),
        ThrnFailure.corrupt,
      );
      // count == 0xFFFFFFFF is the null marker where a count is expected.
      expect(
        failureOf(_concat([
          utf8.encode('THRN'), _u32(2), _qstring('{}'), _u32(0xFFFFFFFF),
        ])),
        ThrnFailure.corrupt,
      );
    });
  });

  group('SHA-256 index digest', () {
    test('matches known vectors', () {
      // Standard FIPS 180-4 vectors, independent of Kotlin/dart:crypto.
      expect(thrnSha256Hex(utf8.encode('')), equals(
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'));
      expect(thrnSha256Hex(utf8.encode('abc')), equals(
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'));
      expect(thrnSha256Hex(utf8.encode('hello world')), equals(
        'b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9'));
    });

    test('matches a >64-byte multi-block digest', () {
      final input = List<int>.generate(200, (i) => i & 0xFF);
      // sha256sum of bytes 0..199, precomputed (no runtime dependency).
      expect(thrnSha256Hex(input), equals(
        '1901da1c9f699b48f6b2636e65cbf73abf99d0441ef67f5c540a42f7051dec6f'));
    });

    test('incremental updates match the one-shot digest', () {
      // The digest carries a sub-block tail between update() calls; drive it with chunk sizes
      // that split blocks (1, 63, 65) and leave large remainders, including empty updates.
      final input = List<int>.generate(1000, (i) => (i * 31 + 7) & 0xFF);
      final expected = thrnSha256Hex(input);
      for (final sizes in [
        <int>[1],
        <int>[63],
        <int>[65],
        <int>[64, 64, 64],
        <int>[7, 0, 200, 5000],
        <int>[999, 1],
      ]) {
        final digest = ThrnSha256();
        var offset = 0;
        var round = 0;
        while (offset < input.length) {
          final size = sizes[round++ % sizes.length];
          final end = (offset + size).clamp(0, input.length);
          digest.update(input.sublist(offset, end));
          offset = end;
        }
        final actual = digest.finalize().map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        expect(actual, equals(expected), reason: 'chunk sizes $sizes');
      }
    });

    test('hashes 1 MiB in one linear pass', () {
      // FIPS 180-4's one-million-'a' vector. With the old removeRange drain this input took
      // quadratic time (the regression this test exists to catch), so keep it going through
      // the incremental path exactly like the WebDAV index does.
      final input = List<int>.filled(1000 * 1000, 0x61);
      expect(thrnSha256Hex(input), equals(
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0'));
    });
  });
}
