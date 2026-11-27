// The FLS1 status frame is the second binary Go->Dart message. These tests pin
// the slot order and flags against the JSON map the heartbeat still returns,
// so a field added to one side without the other fails here first. The Dart
// decoder is pinned separately in bridge_status_frame_test.dart.
package mobile

import (
	"encoding/binary"
	"encoding/json"
	"testing"
)

func sampleStatus() map[string]int64 {
	return map[string]int64{
		"memory":           123456789,
		"goroutines":       42,
		"connectionsIn":    7,
		"connectionsOut":   9,
		"uplink":           1500,
		"downlink":         2500,
		"uplinkTotal":      9876543210,
		"downlinkTotal":    12345678901,
		"trafficAvailable": 1,
	}
}

func TestStatusFrameLayoutAndRoundTrip(t *testing.T) {
	snap := sampleStatus()
	frame := encodeStatusFrame(snap)
	if len(frame) != bridgeStatusFrameBytes {
		t.Fatalf("frame length = %d, want %d", len(frame), bridgeStatusFrameBytes)
	}
	if string(frame[:4]) != bridgeStatusFrameMagic {
		t.Fatalf("magic = %q, want %q", frame[:4], bridgeStatusFrameMagic)
	}
	if frame[4] != bridgeStatusFrameVersion {
		t.Fatalf("version = %d, want %d", frame[4], bridgeStatusFrameVersion)
	}
	// Slot order must match the JSON field order of the original snapshot.
	offset := 5
	for _, key := range statusFieldOrder {
		if got := int64(binary.LittleEndian.Uint64(frame[offset : offset+8])); got != snap[key] {
			t.Fatalf("slot %q = %d, want %d", key, got, snap[key])
		}
		offset += 8
	}
	flags := binary.LittleEndian.Uint32(frame[offset : offset+4])
	if flags != bridgeStatusFlagTrafficAvailable {
		t.Fatalf("flags = %#x, want %#x", flags, bridgeStatusFlagTrafficAvailable)
	}

	decoded, err := decodeStatusFrame(frame)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded) != len(snap) {
		t.Fatalf("decoded %d fields, want %d", len(decoded), len(snap))
	}
	for key, want := range snap {
		if decoded[key] != want {
			t.Fatalf("round trip %q = %d, want %d", key, decoded[key], want)
		}
	}
}

func TestStatusFrameFlagsMirrorTrafficAvailable(t *testing.T) {
	snap := sampleStatus()
	snap["trafficAvailable"] = 0
	frame := encodeStatusFrame(snap)
	if flags := binary.LittleEndian.Uint32(frame[bridgeStatusFrameBytes-4:]); flags != 0 {
		t.Fatalf("flags = %#x, want 0 when traffic is unavailable", flags)
	}
}

func TestStatusFrameCodecRejectsMalformed(t *testing.T) {
	frame := encodeStatusFrame(sampleStatus())
	for _, tc := range []struct {
		name string
		mut  func([]byte) []byte
		want error
	}{
		{"short", func(b []byte) []byte { return b[:len(b)-1] }, errStatusFrameLength},
		{"magic", func(b []byte) []byte { b[0] = 'X'; return b }, errStatusFrameMagic},
		{"version", func(b []byte) []byte { b[4] = 2; return b }, errStatusFrameVersion},
	} {
		t.Run(tc.name, func(t *testing.T) {
			mutated := tc.mut(append([]byte(nil), frame...))
			if _, err := decodeStatusFrame(mutated); err != tc.want {
				t.Fatalf("error = %v, want %v", err, tc.want)
			}
		})
	}
}

func TestStatusFrameSlotsMatchJSONReturnValue(t *testing.T) {
	// The heartbeat's return value is still the JSON map; prove the set of keys
	// the FLS1 slots encode has not drifted from it.
	snap := sampleStatus()
	encoded, err := json.Marshal(snap)
	if err != nil {
		t.Fatal(err)
	}
	var fromJSON map[string]int64
	if err := json.Unmarshal(encoded, &fromJSON); err != nil {
		t.Fatal(err)
	}
	fromFrame, err := decodeStatusFrame(encodeStatusFrame(snap))
	if err != nil {
		t.Fatal(err)
	}
	if len(fromFrame) != len(fromJSON) {
		t.Fatalf("frame has %d fields, JSON has %d", len(fromFrame), len(fromJSON))
	}
	for key, want := range fromJSON {
		if fromFrame[key] != want {
			t.Fatalf("frame field %q = %d, JSON = %d", key, fromFrame[key], want)
		}
	}
}
