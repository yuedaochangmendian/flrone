// The binary log frame is the only Go->Dart message without a JSON envelope
// (see lib/core/bridge_log_frame.dart). The Go encoder's layout is pinned by
// log_frame_test.go in the core patch; these tests pin the Dart side, including
// the malformed frames a truncated port message would produce.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flrone/core/bridge_log_frame.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List encodeFrame(List<(int, String)> entries) {
  final body = BytesBuilder(copy: false);
  for (final (level, message) in entries) {
    final text = utf8.encode(message);
    final head = ByteData(8)
      ..setInt32(0, level, Endian.little)
      ..setUint32(4, text.length, Endian.little);
    body
      ..add(head.buffer.asUint8List())
      ..add(text);
  }
  final payload = body.takeBytes();
  final header = ByteData(8)
    ..setUint32(0, 0x31424c46, Endian.little)
    ..setUint32(4, entries.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), ...payload]);
}

void main() {
  test('decodes the level and UTF-8 message of every entry', () {
    final entries = decodeBridgeLogFrame(encodeFrame([
      (5, 'hello'),
      (3, '连接失败'),
      (4, ''),
    ]));
    expect(entries, isNotNull);
    expect(entries!.map((entry) => entry.level), [5, 3, 4]);
    expect(entries.map((entry) => entry.message), ['hello', '连接失败', '']);
  });

  test('an empty frame decodes to an empty list', () {
    expect(decodeBridgeLogFrame(encodeFrame(const [])), isEmpty);
  });

  test('anything that is not a frame keeps the JSON path', () {
    expect(decodeBridgeLogFrame('{"method":"log"}'), isNull);
    expect(decodeBridgeLogFrame(null), isNull);
    expect(decodeBridgeLogFrame(Uint8List(0)), isNull);
    expect(decodeBridgeLogFrame(Uint8List.fromList([0x46, 0x4c, 0x42])), isNull);
  });

  test('a foreign magic is not treated as a frame', () {
    final frame = encodeFrame([(4, 'x')]);
    frame[0] = 0;
    expect(decodeBridgeLogFrame(frame), isNull);
  });

  test('a truncated entry or text returns null instead of throwing', () {
    final frame = encodeFrame([(4, 'hello'), (4, 'world')]);
    // Cut the last message short: the declared length no longer fits.
    expect(decodeBridgeLogFrame(Uint8List.sublistView(frame, 0, frame.length - 2)), isNull);
    // Cut into the entry header.
    expect(decodeBridgeLogFrame(Uint8List.sublistView(frame, 0, 12)), isNull);
    // A count larger than the bytes present.
    final header = ByteData.sublistView(Uint8List.fromList(frame))
      ..setUint32(4, 99, Endian.little);
    expect(decodeBridgeLogFrame(header.buffer.asUint8List()), isNull);
  });
}
