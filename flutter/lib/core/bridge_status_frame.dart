// Binary status frames from the kernel: the FLS1 counterpart of bridge_log_frame.dart.
//
// The 1 Hz snapshot used to arrive as a JSON `status` event (map with nine ints)
// while the same map was also returned by throne_status_snapshot for the
// heartbeat. Go now posts this fixed-width typed-data frame on the same
// PostBytes path FLB1 uses; Dart turns it back into the exact same status map
// shape so KernelService._onKernelStatus needs no change.
//
// Wire layout (little-endian, 81 bytes total):
//
//   "FLS1" | version u8 (=1) |
//     memory i64 | goroutines i64 |
//     connectionsIn i64 | connectionsOut i64 |
//     uplink i64 | downlink i64 |
//     uplinkTotal i64 | downlinkTotal i64 |
//     trafficAvailable i64 (0/1) |
//     flags u32 (bit 0 mirrors trafficAvailable; bits 1..31 reserved, zero)
//
// The field order is pinned by statusFieldOrder in status_frame.go — do not
// reorder or drop a slot. Both sides' tests pin the layout independently.

import 'dart:typed_data';

const int _statusFrameMagic = 0x31534c46; // "FLS1" read little-endian
const int _statusFrameVersion = 1;
const int statusFrameBytes = 4 + 1 + 9 * 8 + 4;

/// The canonical status field names, in wire slot order.
const List<String> statusFrameFields = <String>[
  'memory',
  'goroutines',
  'connectionsIn',
  'connectionsOut',
  'uplink',
  'downlink',
  'uplinkTotal',
  'downlinkTotal',
  'trafficAvailable',
];

/// Decodes one FLS1 status frame into the same map shape as the old JSON event.
///
/// Returns null for a foreign magic, a wrong version, a truncated frame or any
/// other non-frame message; the caller then falls back to the JSON path. The
/// `flags` slot is decoded for validation but does not override the explicit
/// trafficAvailable int, which stays byte-for-byte compatible with the JSON map.
Map<String, int>? decodeBridgeStatusFrame(Object? raw) {
  if (raw is! Uint8List || raw.length != statusFrameBytes) return null;
  final data = ByteData.sublistView(raw);
  if (data.getUint32(0, Endian.little) != _statusFrameMagic) return null;
  if (data.getUint8(4) != _statusFrameVersion) return null;

  final status = <String, int>{};
  var offset = 5;
  for (final field in statusFrameFields) {
    // int64 slots can be negative in theory; signed reads keep the exact
    // two's-complement value the Go side wrote.
    status[field] = data.getInt64(offset, Endian.little);
    offset += 8;
  }
  // Read the flags even though the explicit slot is authoritative: a frame
  // with reserved bits set is not one this decoder understands.
  final flags = data.getUint32(offset, Endian.little);
  const knownFlags = 0x1;
  if (flags & ~knownFlags != 0) return null;
  return status;
}

/// True when [raw] is an FLS1 frame (used by the port listener for magic
/// dispatch before decoding). A frame that fails validation is still a frame:
/// the caller must not hand it to jsonDecode as a string.
bool isBridgeStatusFrame(Object? raw) =>
    raw is Uint8List &&
    raw.length >= 4 &&
    ByteData.sublistView(raw).getUint32(0, Endian.little) == _statusFrameMagic;
