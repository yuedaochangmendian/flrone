// The speed-test progress feed avoids re-sending all 11 fields at 5 Hz. These
// tests pin the wire shape (first frame full, then only changed fields) and the
// per-port/per-tag lifecycle. The Dart merge side is pinned by
// speed_test_delta_test.dart; together they preserve the last-frame semantics.
package mobile

import (
	"encoding/json"
	"testing"
)

func speedResult(tag string, tweak func(*SpeedTestResult)) *SpeedTestResult {
	r := &SpeedTestResult{
		Tag: tag, DlSpeed: "1.00 M", UlSpeed: "2.00 M", Latency: 10,
		ServerName: "server", ServerCountry: "CN", Error: "",
		Cancelled: false, DlBytes: 100, UlBytes: 200, Running: true,
	}
	if tweak != nil {
		tweak(r)
	}
	return r
}

func decodeDelta(t *testing.T, payload any) map[string]any {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(b, &decoded); err != nil {
		t.Fatal(err)
	}
	return decoded
}

func TestSpeedDeltaFirstFrameIsFull(t *testing.T) {
	clearSpeedTestDelta(9001)
	payload := encodeSpeedTestDelta(9001, speedResult("proxy", nil))
	r, ok := payload.(*SpeedTestResult)
	if !ok {
		t.Fatalf("first frame type = %T, want *SpeedTestResult", payload)
	}
	full := decodeDelta(t, r)
	for _, key := range []string{
		"Tag", "DlSpeed", "UlSpeed", "Latency", "ServerName", "ServerCountry",
		"Error", "Cancelled", "DlBytes", "UlBytes", "Running",
	} {
		if _, present := full[key]; !present {
			t.Fatalf("full frame missing field %q", key)
		}
	}
}

func TestSpeedDeltaContainsOnlyChangedFields(t *testing.T) {
	port := int64(9002)
	clearSpeedTestDelta(port)
	encodeSpeedTestDelta(port, speedResult("proxy", nil))
	// Only the download speed and cumulative bytes changed.
	next := speedResult("proxy", func(r *SpeedTestResult) {
		r.DlSpeed = "3.00 M"
		r.DlBytes = 250
	})
	payload := encodeSpeedTestDelta(port, next)
	frame := decodeDelta(t, payload)
	if frame["tag"] != "proxy" {
		t.Fatalf("delta tag = %v, want proxy", frame["tag"])
	}
	delta, ok := frame["delta"].(map[string]any)
	if !ok {
		t.Fatalf("delta payload = %T, want map", frame["delta"])
	}
	if len(delta) != 2 {
		t.Fatalf("delta fields = %v, want exactly DlSpeed + DlBytes", delta)
	}
	if delta["DlSpeed"] != "3.00 M" || delta["DlBytes"] != float64(250) {
		t.Fatalf("delta values = %v", delta)
	}
}

func TestSpeedDeltaIdenticalFrameIsSkipped(t *testing.T) {
	port := int64(9003)
	clearSpeedTestDelta(port)
	encodeSpeedTestDelta(port, speedResult("proxy", nil))
	if payload := encodeSpeedTestDelta(port, speedResult("proxy", nil)); payload != nil {
		t.Fatalf("identical frame produced a payload: %v", payload)
	}
}

func TestSpeedDeltaCancelledFrameIsFullAndResets(t *testing.T) {
	port := int64(9004)
	clearSpeedTestDelta(port)
	encodeSpeedTestDelta(port, speedResult("proxy", nil))
	encodeSpeedTestDelta(port, speedResult("proxy", func(r *SpeedTestResult) { r.DlSpeed = "9 M" }))
	terminal := speedResult("proxy", func(r *SpeedTestResult) {
		r.Cancelled = true
		r.Running = false
	})
	payload := encodeSpeedTestDelta(port, terminal)
	if _, ok := payload.(*SpeedTestResult); !ok {
		t.Fatalf("cancelled frame type = %T, want full *SpeedTestResult", payload)
	}
	clearSpeedTestDelta(port)
	// A new run on the same port starts with a full frame again.
	if again := encodeSpeedTestDelta(port, speedResult("proxy", nil)); again == nil {
		t.Fatal("a new run must start with a full frame")
	} else if _, ok := again.(*SpeedTestResult); !ok {
		t.Fatalf("new run first frame = %T, want full", again)
	}
}

func TestSpeedDeltaIsPerPortAndPerTag(t *testing.T) {
	clearSpeedTestDelta(9101)
	clearSpeedTestDelta(9102)
	first := speedResult("A", nil)
	encodeSpeedTestDelta(9101, first)
	encodeSpeedTestDelta(9102, first) // different port: first frame is full too
	if payload := encodeSpeedTestDelta(9101, speedResult("B", nil)); payload == nil {
		t.Fatal("a new tag must start with a full frame")
	} else if _, ok := payload.(*SpeedTestResult); !ok {
		t.Fatalf("new tag frame = %T, want full", payload)
	}
	// A tag on port 9102 that was already announced with no changes is skipped.
	if payload := encodeSpeedTestDelta(9102, speedResult("A", nil)); payload != nil {
		t.Fatalf("unchanged frame on port 9102 produced a payload: %v", payload)
	}
}
