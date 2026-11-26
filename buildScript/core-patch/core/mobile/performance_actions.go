// Bridge-performance actions on the Bettbox-style JSON bus.
//
// The new core pin exposes mobile.SetScreenOff(off): it tells every auto-selector
// to probe less often while the screen is off (a process-wide setting, not an
// instance one). It deliberately does NOT pause the instance: Flutter's
// paused/hidden lifecycle means the app is backgrounded, not that the device is
// in doze, and pausing here would suppress the auto-selector/URLTest/WireGuard
// periodic recovery the tunnel needs. Device doze is the separate setDoze
// action, driven by the Android host from PowerManager state.
//
// None of these need a new typed C export: Dart already has the single
// throne_invoke_action entry point, and Kotlin has Core.runAction. Keeping them
// on the bus means tools/diagnostics/action_contract.py can hold the Go/Dart
// wire names together, and symbol_audit.py's three-way export equality stays
// untouched.
//
// Wire shapes (the Dart ActionMethod member IS the wire name):
//
//	setScreenOff {"off":true}     -> true  (auto-selector only)
//	setDoze      {"enabled":true} -> true  (pause/wake instance)
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"sync/atomic"
)

const (
	setScreenOffMethod Method = "setScreenOff"
	setDozeMethod      Method = "setDoze"
)

func init() {
	register(setScreenOffMethod, handleSetScreenOff)
	register(setDozeMethod, handleSetDoze)
}

// applyScreenOff is the production seam: tests swap it for a recorder so the
// handler can be exercised without changing the process-wide auto-selector
// state. It is only assigned here and in tests; the bus never sends a function.
var applyScreenOff = SetScreenOff

// dozeMode is the desired device-doze state, independent of any instance. It is
// set by the host (PowerManager idle + screen off) and persists across instance
// creation: an instance started while the device is dozing must come up paused.
// Instance.Start reads it after a successful start and calls Instance.Pause.
var dozeMode atomic.Bool

// applyDozePause is the production seam: tests swap it for a recorder so the
// handler can be exercised without a running instance. It applies the desired
// doze state to the current instance, if any; without one it is a no-op (the
// flag itself is still durable, so a later Start picks it up).
var applyDozePause = func(enabled bool) {
	instance, err := currentInstance()
	if err != nil || instance == nil {
		return
	}
	if enabled {
		instance.Pause()
	} else {
		instance.Wake()
	}
}

// applyDozeOnStart is the seam for the persist-across-start path: production
// pauses the just-started instance; tests swap it to record the call without a
// live box. applyPersistedDoze checks dozeMode before calling this.
var applyDozeOnStart = func(i *Instance) {
	i.Pause()
}

func handleSetScreenOff(raw json.RawMessage) (any, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, errors.New("setScreenOff: missing payload")
	}
	var request struct {
		Off *bool `json:"off"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return nil, fmt.Errorf("setScreenOff: parse payload: %w", err)
	}
	if request.Off == nil {
		return nil, errors.New("setScreenOff: off is required")
	}
	applyScreenOff(*request.Off)
	return true, nil
}

// parseSetDozeRequest validates the payload strictly: enabled is required and
// must be a JSON bool. Unknown fields are tolerated (the wire is shared with
// future hosts), but a missing or mistyped value is an error and must not flip
// the doze state.
func parseSetDozeRequest(raw json.RawMessage) (bool, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return false, errors.New("setDoze: missing payload")
	}
	var request struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return false, fmt.Errorf("setDoze: parse payload: %w", err)
	}
	if request.Enabled == nil {
		return false, errors.New("setDoze: enabled is required")
	}
	return *request.Enabled, nil
}

func handleSetDoze(raw json.RawMessage) (any, error) {
	enabled, err := parseSetDozeRequest(raw)
	if err != nil {
		return nil, err
	}
	dozeMode.Store(enabled)
	applyDozePause(enabled)
	return true, nil
}

// applyPersistedDoze is called by Instance.Start after the box is up. Check the
// flag at start time, not at set time: a doze command that arrived before any
// instance existed must still take effect on the one that starts later.
func applyPersistedDoze(i *Instance) {
	if dozeMode.Load() {
		applyDozeOnStart(i)
	}
}
