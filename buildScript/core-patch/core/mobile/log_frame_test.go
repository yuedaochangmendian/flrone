// The binary log frame is the only Go->Dart message without a JSON envelope.
// These tests pin the layout the Dart decoder in `throne_ffi.dart` reads, so a
// change on one side that is not made on the other fails here first.
package mobile

import (
	"encoding/binary"
	"testing"
)

func TestEncodeLogFrameLayout(t *testing.T) {
	frame := encodeLogFrame([]logEntry{
		{level: LogLevelInfo, message: "hello"},
		{level: LogLevelError, message: "连接失败"},
	})

	if string(frame[:4]) != bridgeLogFrameMagic {
		t.Fatalf("magic = %q, want %q", frame[:4], bridgeLogFrameMagic)
	}
	if count := binary.LittleEndian.Uint32(frame[4:8]); count != 2 {
		t.Fatalf("count = %d, want 2", count)
	}

	offset := 8
	for index, want := range []logEntry{
		{level: LogLevelInfo, message: "hello"},
		{level: LogLevelError, message: "连接失败"},
	} {
		level := int32(binary.LittleEndian.Uint32(frame[offset:]))
		length := int(binary.LittleEndian.Uint32(frame[offset+4:]))
		offset += 8
		if level != want.level {
			t.Fatalf("entry %d level = %d, want %d", index, level, want.level)
		}
		if got := string(frame[offset : offset+length]); got != want.message {
			t.Fatalf("entry %d message = %q, want %q", index, got, want.message)
		}
		offset += length
	}
	if offset != len(frame) {
		t.Fatalf("frame has %d trailing bytes", len(frame)-offset)
	}
}

func TestEncodeLogFrameEmpty(t *testing.T) {
	frame := encodeLogFrame(nil)
	if len(frame) != 8 {
		t.Fatalf("an empty frame is the 8-byte header, got %d bytes", len(frame))
	}
	if count := binary.LittleEndian.Uint32(frame[4:]); count != 0 {
		t.Fatalf("count = %d, want 0", count)
	}
}
