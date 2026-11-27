// The FLS1 status frame is the binary twin of the JSON `status` event (see
// lib/core/bridge_status_frame.dart). Go's encoder layout is pinned by
// status_frame_test.go in the core patch; these tests pin the Dart decoder and
// the magic dispatch, including the JSON fallback during the transition.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flrone/core/bridge_log_frame.dart';
import 'package:flrone/core/bridge_status_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors Go's encodeStatusFrame: nine int64 slots then flags u32, all LE.
Uint8List encodeStatusFrame(Map<String, int> status, {int version = 1}) {
  final data = ByteData(statusFrameBytes);
  final magic = utf8.encode('FLS1');
  for (var i = 0; i < 4; i++) {
    data.setUint8(i, magic[i]);
  }
  data.setUint8(4, version);
  var offset = 5;
  for (final field in statusFrameFields) {
    data.setInt64(offset, status[field] ?? 0, Endian.little);
    offset += 8;
  }
  final flags = (status['trafficAvailable'] ?? 0) == 0 ? 0 : 1;
  data.setUint32(offset, flags, Endian.little);
  return data.buffer.asUint8List();
}

const sample = <String, int>{
  'memory': 123456789,
  'goroutines': 42,
  'connectionsIn': 7,
  'connectionsOut': 9,
  'uplink': 1500,
  'downlink': 2500,
  'uplinkTotal': 9876543210,
  'downlinkTotal': 12345678901,
  'trafficAvailable': 1,
};

void main() {
  group('FLS1 status frame', () {
    test('decodes all nine fields in slot order', () {
      final decoded = decodeBridgeStatusFrame(encodeStatusFrame(sample));
      expect(decoded, isNotNull);
      expect(decoded, sample);
      expect(decoded!.keys.toList(), statusFrameFields);
    });

    test('the flags mirror trafficAvailable and do not override the slot', () {
      final off = {...sample, 'trafficAvailable': 0};
      expect(decodeBridgeStatusFrame(encodeStatusFrame(off)), off);
    });

    test('magic dispatch recognises an FLS1 frame but not FLB1 or JSON', () {
      expect(isBridgeStatusFrame(encodeStatusFrame(sample)), isTrue);
      expect(isBridgeStatusFrame(utf8.encode('{"method":"status"}')), isFalse);
      expect(isBridgeStatusFrame(null), isFalse);
      // FLB1 log frames are a different binary kind; the log listener handles them.
      final logFrame = Uint8List.fromList([
        ...utf8.encode('FLB1'),
        0, 0, 0, 0,
      ]);
      expect(decodeBridgeLogFrame(logFrame), isEmpty);
      expect(isBridgeStatusFrame(logFrame), isFalse);
    });

    test('a foreign magic, wrong version or truncated frame is not a status frame', () {
      final wrongMagic = encodeStatusFrame(sample);
      wrongMagic[0] = 0;
      expect(decodeBridgeStatusFrame(wrongMagic), isNull);
      expect(isBridgeStatusFrame(wrongMagic), isFalse);
      expect(
        decodeBridgeStatusFrame(encodeStatusFrame(sample, version: 2)),
        isNull,
      );
      expect(
        decodeBridgeStatusFrame(Uint8List.sublistView(encodeStatusFrame(sample), 0, 40)),
        isNull,
      );
    });

    test('reserved flag bits are rejected instead of decoding a foreign frame', () {
      final frame = encodeStatusFrame(sample);
      final data = ByteData.sublistView(frame);
      data.setUint32(81 - 4, 0x2, Endian.little);
      expect(decodeBridgeStatusFrame(frame), isNull);
    });

    test('the JSON status event still decodes (dual-read fallback)', () {
      // A kernel build predating FLS1 still sends sendEvent("status", snap).
      final jsonEvent = json.encode(<String, dynamic>{
        'method': 'status',
        'data': sample,
      });
      final decoded = json.decode(jsonEvent) as Map<String, dynamic>;
      expect(decoded['method'], 'status');
      expect(decoded['data'], sample);
      expect(isBridgeStatusFrame(jsonEvent), isFalse);
    });
  });
}
