// FLS1: a fixed-width binary frame for the 1 Hz status snapshot.
//
// The JSON `status` event used to cost a map allocation, a json.Marshal with
// nine key names, a UTF-8 string copy on the Dart port, and a jsonDecode on the
// other side — every second for the whole life of the tunnel. The same numbers
// now travel as one typed-data message on the PostBytes path already used by
// FLB1 log frames. The return value of throne_status_snapshot (the heartbeat
// read) stays the original JSON map, and sendStatusJSONEvent keeps the old
// push shape available for hosts that still parse it.
//
// Wire layout (little-endian throughout, 81 bytes total):
//
//	"FLS1" | version u8 (=1) |
//	  memory i64 | goroutines i64 |
//	  connectionsIn i64 | connectionsOut i64 |
//	  uplink i64 | downlink i64 |
//	  uplinkTotal i64 | downlinkTotal i64 |
//	  trafficAvailable i64 (0/1) |
//	  flags u32 (bit 0 mirrors trafficAvailable; bits 1..31 reserved, zero)
//
// Field order is the order of the keys in the old JSON map — do not reorder or
// drop a field. Both sides pin this layout with a round-trip test
// (status_frame_test.go / bridge_status_frame_test.dart).
package mobile

import (
	"encoding/binary"
	"errors"
)

var (
	errStatusFrameLength  = errors.New("status frame: wrong length")
	errStatusFrameMagic   = errors.New("status frame: bad magic")
	errStatusFrameVersion = errors.New("status frame: unsupported version")
)

const (
	bridgeStatusFrameMagic   = "FLS1"
	bridgeStatusFrameVersion = 1
	bridgeStatusFrameBytes   = 4 + 1 + 9*8 + 4

	bridgeStatusFlagTrafficAvailable = 1 << 0
)

// statusFieldOrder is the single source of truth for the nine int64 slots.
// Keep it in the exact order of the JSON map built by throne_status_snapshot.
var statusFieldOrder = [...]string{
	"memory",
	"goroutines",
	"connectionsIn",
	"connectionsOut",
	"uplink",
	"downlink",
	"uplinkTotal",
	"downlinkTotal",
	"trafficAvailable",
}

// encodeStatusFrame writes one FLS1 frame from the same map the JSON return
// value uses. A missing key encodes as zero, so an incomplete snapshot still
// produces a decodable (but unhelpful) frame rather than a malformed one.
func encodeStatusFrame(snap map[string]int64) []byte {
	frame := make([]byte, bridgeStatusFrameBytes)
	copy(frame[0:4], bridgeStatusFrameMagic)
	frame[4] = bridgeStatusFrameVersion
	offset := 5
	for _, key := range statusFieldOrder {
		binary.LittleEndian.PutUint64(frame[offset:offset+8], uint64(snap[key]))
		offset += 8
	}
	var flags uint32
	if snap["trafficAvailable"] != 0 {
		flags |= bridgeStatusFlagTrafficAvailable
	}
	binary.LittleEndian.PutUint32(frame[offset:offset+4], flags)
	return frame
}

// decodeStatusFrame is the Go mirror of the Dart decoder. Production only
// encodes; this exists so a test can prove both sides agree on every slot.
func decodeStatusFrame(frame []byte) (map[string]int64, error) {
	if len(frame) != bridgeStatusFrameBytes {
		return nil, errStatusFrameLength
	}
	if string(frame[:4]) != bridgeStatusFrameMagic {
		return nil, errStatusFrameMagic
	}
	if frame[4] != bridgeStatusFrameVersion {
		return nil, errStatusFrameVersion
	}
	snap := make(map[string]int64, len(statusFieldOrder))
	offset := 5
	for _, key := range statusFieldOrder {
		snap[key] = int64(binary.LittleEndian.Uint64(frame[offset : offset+8]))
		offset += 8
	}
	return snap, nil
}

// emitStatusFrame is the seam tests swap for a recorder (like emitLogFrame).
// Production always posts the frame to the attached Dart message port.
var emitStatusFrame = sendStatusFrame

func sendStatusFrame(snap map[string]int64) {
	bridgeMu.Lock()
	port := messagePort
	bridgeMu.Unlock()
	if port < 0 {
		return
	}
	sendBytesToPort(port, encodeStatusFrame(snap))
}

// sendStatusJSONEvent is the retained compatibility push: the exact
// sendEvent("status", snap) shape older Dart/kernel-service builds parse. It
// is not installed as the production emitter (that would double the 1 Hz
// payload), but stays wired and tested so a host needing JSON can opt in by
// assigning it to emitStatusFrame.
func sendStatusJSONEvent(snap map[string]int64) {
	sendEvent("status", snap)
}
