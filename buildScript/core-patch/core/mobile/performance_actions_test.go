package mobile

import (
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"strings"
	"testing"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	N "github.com/sagernet/sing/common/network"
)

func metadataFor(network string) adapter.InboundContext {
	return adapter.InboundContext{Network: network}
}

// The tests here pin the wire codecs without needing a running box: parsing is
// pure, the screen-off call is swapped for a recorder, and the connection count
// is computed from synthetic trafficcontrol metadata.

func performanceRaw(t *testing.T, payload string) json.RawMessage {
	t.Helper()
	return json.RawMessage(payload)
}

func TestParseBatchTrafficRequest(t *testing.T) {
	tags, err := parseBatchTrafficRequest(performanceRaw(t, `{"tags":["proxy","direct","block"]}`))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got, want := strings.Join(tags, ","), "proxy,direct,block"; got != want {
		t.Fatalf("tags = %q, want %q", got, want)
	}
}

func TestParseBatchTrafficRequestRejectsBadInput(t *testing.T) {
	tests := []struct {
		name string
		raw  string
	}{
		{"empty payload", ``},
		{"null payload", `null`},
		{"malformed json", `{`},
		{"missing tags", `{}`},
		{"empty tag", `{"tags":["proxy",""]}`},
		{"newline in tag", `{"tags":["proxy\ndirect"]}`},
		{"carriage return in tag", `{"tags":["proxy\rdirect"]}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseBatchTrafficRequest(performanceRaw(t, tc.raw)); err == nil {
				t.Fatalf("expected an error for %q", tc.raw)
			}
		})
	}
}

func TestParseBatchTrafficRequestRejectsTooManyTags(t *testing.T) {
	tags := make([]string, maxBatchTrafficTags+1)
	for i := range tags {
		tags[i] = "tag"
	}
	payload, err := json.Marshal(map[string]any{"tags": tags})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parseBatchTrafficRequest(performanceRaw(t, string(payload))); err == nil {
		t.Fatal("expected an error for more than the tag limit")
	}
}

// encodeTrafficCounters is the test-side twin of TrafficReader.Read's wire
// format: 16 bytes per tag, little-endian uplink then downlink.
func encodeTrafficCounters(pairs ...[2]uint64) string {
	bytes := make([]byte, 16*len(pairs))
	for i, pair := range pairs {
		binary.LittleEndian.PutUint64(bytes[i*16:], pair[0])
		binary.LittleEndian.PutUint64(bytes[i*16+8:], pair[1])
	}
	return base64.StdEncoding.EncodeToString(bytes)
}

func TestTrafficCountersWireShape(t *testing.T) {
	encoded := encodeTrafficCounters([2]uint64{1 << 40, 7}, [2]uint64{0, 1 << 60})
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded) != 32 {
		t.Fatalf("decoded length = %d, want 32", len(decoded))
	}
	if got := binary.LittleEndian.Uint64(decoded[0:8]); got != 1<<40 {
		t.Fatalf("first uplink = %d, want %d", got, uint64(1<<40))
	}
	if got := binary.LittleEndian.Uint64(decoded[24:32]); got != 1<<60 {
		t.Fatalf("second downlink = %d, want %d", got, uint64(1<<60))
	}
}

func TestHandleSetScreenOff(t *testing.T) {
	previous := applyScreenOff
	t.Cleanup(func() { applyScreenOff = previous })
	var seen []bool
	applyScreenOff = func(off bool) { seen = append(seen, off) }

	if result, err := handleSetScreenOff(performanceRaw(t, `{"off":true}`)); err != nil || result != true {
		t.Fatalf("off=true: result = %v, err = %v", result, err)
	}
	if result, err := handleSetScreenOff(performanceRaw(t, `{"off":false}`)); err != nil || result != true {
		t.Fatalf("off=false: result = %v, err = %v", result, err)
	}
	if got := strings.Join([]string{boolString(seen[0]), boolString(seen[1])}, ","); got != "true,false" {
		t.Fatalf("applied = %q, want true,false", got)
	}
	// Screen-off (a Flutter app-backgrounding hint) must never pause the
	// instance. Device doze is the separate setDoze action: pausing here would
	// starve auto-selector/URLTest/WireGuard periodic recovery.
	if dozeMode.Load() {
		t.Fatal("setScreenOff changed the doze flag")
	}
}

// setScreenOff must not call the doze pause seam at all: install a seam that
// fails the test on any call, then drive both transitions.
func TestHandleSetScreenOffDoesNotPause(t *testing.T) {
	previousScreenOff := applyScreenOff
	previousDoze := applyDozePause
	t.Cleanup(func() {
		applyScreenOff = previousScreenOff
		applyDozePause = previousDoze
	})
	applyScreenOff = func(bool) {}
	applyDozePause = func(bool) { t.Fatal("setScreenOff applied doze pause") }
	for _, raw := range []string{`{"off":true}`, `{"off":false}`} {
		if _, err := handleSetScreenOff(performanceRaw(t, raw)); err != nil {
			t.Fatalf("%s: %v", raw, err)
		}
	}
}

func TestHandleSetDozeAppliesAndPersists(t *testing.T) {
	previousDoze := dozeMode.Load()
	previousPause := applyDozePause
	previousOnStart := applyDozeOnStart
	t.Cleanup(func() {
		dozeMode.Store(previousDoze)
		applyDozePause = previousPause
		applyDozeOnStart = previousOnStart
	})
	var applied []bool
	applyDozePause = func(enabled bool) { applied = append(applied, enabled) }

	if result, err := handleSetDoze(performanceRaw(t, `{"enabled":true}`)); err != nil || result != true {
		t.Fatalf("enabled=true: result = %v, err = %v", result, err)
	}
	if !dozeMode.Load() {
		t.Fatal("doze flag was not set")
	}
	if result, err := handleSetDoze(performanceRaw(t, `{"enabled":false}`)); err != nil || result != true {
		t.Fatalf("enabled=false: result = %v, err = %v", result, err)
	}
	if dozeMode.Load() {
		t.Fatal("doze flag was not cleared")
	}
	if got := strings.Join([]string{boolString(applied[0]), boolString(applied[1])}, ","); got != "true,false" {
		t.Fatalf("pause/wake = %q, want true,false", got)
	}
}

func TestSetDozeRejectsBadInputWithoutChangingFlag(t *testing.T) {
	previousDoze := dozeMode.Load()
	previousPause := applyDozePause
	t.Cleanup(func() {
		dozeMode.Store(previousDoze)
		applyDozePause = previousPause
	})
	dozeMode.Store(false)
	called := false
	applyDozePause = func(bool) { called = true }
	for _, raw := range []string{``, `null`, `{`, `{}`, `{"enabled":"yes"}`, `{"enabled":1}`} {
		if _, err := handleSetDoze(performanceRaw(t, raw)); err == nil {
			t.Fatalf("expected an error for %q", raw)
		}
		if dozeMode.Load() || called {
			t.Fatalf("malformed %q changed the flag or applied a pause", raw)
		}
	}
}

func TestPersistedDozeAppliedOnStart(t *testing.T) {
	previousDoze := dozeMode.Load()
	previousOnStart := applyDozeOnStart
	t.Cleanup(func() {
		dozeMode.Store(previousDoze)
		applyDozeOnStart = previousOnStart
	})
	called := 0
	applyDozeOnStart = func(*Instance) { called++ }

	// A doze command with no instance at all: the flag survives and a later
	// Start applies it.
	dozeMode.Store(true)
	applyPersistedDoze(nil)
	if called != 1 {
		t.Fatalf("paused %d times with doze set, want 1", called)
	}
	dozeMode.Store(false)
	applyPersistedDoze(nil)
	if called != 1 {
		t.Fatalf("paused %d times with doze cleared, want 1", called)
	}
}

func boolString(value bool) string {
	if value {
		return "true"
	}
	return "false"
}

func TestHandleSetScreenOffRejectsBadInput(t *testing.T) {
	previous := applyScreenOff
	t.Cleanup(func() { applyScreenOff = previous })
	called := false
	applyScreenOff = func(bool) { called = true }
	for _, raw := range []string{``, `null`, `{`, `{}`, `{"off":"yes"}`} {
		if _, err := handleSetScreenOff(performanceRaw(t, raw)); err == nil {
			t.Fatalf("expected an error for %q", raw)
		}
	}
	if called {
		t.Fatal("applyScreenOff was called for a malformed request")
	}
}

func TestCountConnectionNetworks(t *testing.T) {
	connections := []*trafficcontrol.TrackerMetadata{
		{Metadata: metadataFor(N.NetworkTCP)},
		{Metadata: metadataFor(N.NetworkTCP)},
		{Metadata: metadataFor(N.NetworkUDP)},
		nil,
		{Metadata: metadataFor("icmp")},
	}
	got := countConnectionNetworks(connections)
	if got["tcp"] != 2 || got["udp"] != 1 {
		t.Fatalf("count = %v, want tcp=2 udp=1", got)
	}
}

func TestPerformanceActionMethodsAreRegistered(t *testing.T) {
	for _, method := range []Method{batchTrafficMethod, setScreenOffMethod, setDozeMethod, queryConnectionCountMethod} {
		if _, ok := actionHandlers[method]; !ok {
			t.Errorf("method %q is not registered", method)
		}
	}
}
