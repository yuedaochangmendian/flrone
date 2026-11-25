// Binary log frames from the kernel: the one Go->Dart message that does not
// carry a JSON envelope.
//
// sing-box formats a line per connection event, so the log feed was the
// highest-frequency producer of `json.Marshal` + `jsonDecode` pairs on the
// bridge. The port sink now batches a drain into one typed-data message:
//
//   "FLB1" | count u32le | (level i32le | len u32le | utf8 bytes)*
//
// A frame is capped at 256 entries on the Go side; this decoder validates every
// length before slicing so a truncated or foreign message returns null instead
// of throwing inside the port listener. Messages that are not frames (all the
// JSON events: status, speedTest, urlTestResult, ...) return null and the
// caller falls back to [decodeBridgeEvent].

import 'dart:convert';
import 'dart:typed_data';

/// One kernel log line taken out of a binary frame.
class BridgeLogEntry {
  const BridgeLogEntry(this.level, this.message);

  final int level;
  final String message;
}

const int _frameMagic = 0x31424c46; // "FLB1" read little-endian
const int _headerBytes = 8;
const int _entryHeaderBytes = 8;

/// Decodes one binary log frame, or null when [raw] is not one.
List<BridgeLogEntry>? decodeBridgeLogFrame(Object? raw) {
  if (raw is! Uint8List || raw.length < _headerBytes) return null;
  final data = ByteData.sublistView(raw);
  if (data.getUint32(0, Endian.little) != _frameMagic) return null;

  final count = data.getUint32(4, Endian.little);
  final entries = <BridgeLogEntry>[];
  var offset = _headerBytes;
  for (var index = 0; index < count; index++) {
    if (offset + _entryHeaderBytes > raw.length) return null;
    final level = data.getInt32(offset, Endian.little);
    final length = data.getUint32(offset + 4, Endian.little);
    offset += _entryHeaderBytes;
    if (length > raw.length - offset) return null;
    entries.add(BridgeLogEntry(
      level,
      utf8.decode(
        Uint8List.sublistView(raw, offset, offset + length),
        allowMalformed: true,
      ),
    ));
    offset += length;
  }
  return entries;
}
