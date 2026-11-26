package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

// The tests here pin the wire codecs without needing a running box: parsing is
// pure and the screen-off/doze calls are swapped for recorders.

func performanceRaw(t *testing.T, payload string) json.RawMessage {
	t.Helper()
	return json.RawMessage(payload)
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

func TestPerformanceActionMethodsAreRegistered(t *testing.T) {
	for _, method := range []Method{setScreenOffMethod, setDozeMethod} {
		if _, ok := actionHandlers[method]; !ok {
			t.Errorf("method %q is not registered", method)
		}
	}
}
