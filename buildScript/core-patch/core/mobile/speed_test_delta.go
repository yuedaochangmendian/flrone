// Delta encoding for the 5 Hz speed-test progress feed.
//
// Before this, portSpeedTest.OnResult posted the full 11-field SpeedTestResult
// JSON every 200 ms (50-150 frames per run). Only a couple of fields usually
// change between ticks. The handler now keeps the last state it announced per
// tag and posts either:
//
//   - a FULL frame — the unchanged SpeedTestResult JSON object with Go field
//     names (the first frame for a tag, and every Cancelled frame so a loss of
//     an earlier delta cannot leave the UI stale), or
//   - a DELTA frame — {"tag": <Tag>, "delta": {<field>: <new value>, ...}}
//     containing only the fields that changed since the last announced frame.
//
// The event envelope (`{"method":"speedTestResult","data":...}`) and the
// `speedTestDone` / error paths are untouched. Dart detects the lowercase
// `tag`/`delta` shape, merges the delta into its last full frame for that tag,
// and delivers the merged full frame to the UI (see
// flutter/lib/core/speed_test_delta.dart). Full frames remain readable by an
// older Dart build that knows no delta format.
//
// State is keyed by (reply port, tag): each C ABI test call gets its own port,
// and a fresh run clears the port's state in OnDone, deltas never leak from one
// run into another.
package mobile

import (
	"reflect"
	"sync"
)

// speedTestResultFields is the one source of truth for the wire field names.
// It intentionally uses the Go struct names — that is what json.Marshal emits
// for a full frame, and what the Dart merger must overwrite.
func speedTestResultFields(result *SpeedTestResult) map[string]any {
	if result == nil {
		return nil
	}
	return map[string]any{
		"Tag":           result.Tag,
		"DlSpeed":       result.DlSpeed,
		"UlSpeed":       result.UlSpeed,
		"Latency":       result.Latency,
		"ServerName":    result.ServerName,
		"ServerCountry": result.ServerCountry,
		"Error":         result.Error,
		"Cancelled":     result.Cancelled,
		"DlBytes":       result.DlBytes,
		"UlBytes":       result.UlBytes,
		"Running":       result.Running,
	}
}

var speedDeltaState struct {
	sync.Mutex
	last map[int64]map[string]*SpeedTestResult
}

// encodeSpeedTestDelta returns the payload for one OnResult: either the full
// SpeedTestResult (a *SpeedTestResult, as before) or a delta map. It returns
// nil when the frame carries no new information and can be skipped entirely.
func encodeSpeedTestDelta(port int64, result *SpeedTestResult) any {
	if result == nil {
		return nil
	}
	speedDeltaState.Lock()
	defer speedDeltaState.Unlock()
	if speedDeltaState.last == nil {
		speedDeltaState.last = make(map[int64]map[string]*SpeedTestResult)
	}
	byTag := speedDeltaState.last[port]
	if byTag == nil {
		byTag = make(map[string]*SpeedTestResult)
		speedDeltaState.last[port] = byTag
	}

	// A cancelled terminal frame is always full: it must be self-contained even
	// if an earlier delta was dropped on the port.
	prior := byTag[result.Tag]
	if prior == nil || result.Cancelled {
		announced := *result
		byTag[result.Tag] = &announced
		return result
	}

	current := speedTestResultFields(result)
	previous := speedTestResultFields(prior)
	delta := make(map[string]any)
	for key, value := range current {
		if !reflect.DeepEqual(value, previous[key]) {
			delta[key] = value
		}
	}
	if len(delta) == 0 {
		return nil
	}
	announced := *result
	byTag[result.Tag] = &announced
	return map[string]any{"tag": result.Tag, "delta": delta}
}

// clearSpeedTestDelta drops the baseline for a reply port. Called by OnDone so
// a new run on the same port starts with a full frame again.
func clearSpeedTestDelta(port int64) {
	speedDeltaState.Lock()
	defer speedDeltaState.Unlock()
	delete(speedDeltaState.last, port)
}

// postSpeedTestDelta is the production seam OnResult calls; it keeps the
// original method name and error-free postTo path.
func postSpeedTestDelta(port int64, result *SpeedTestResult) {
	payload := encodeSpeedTestDelta(port, result)
	if payload == nil {
		return
	}
	postTo(port, "speedTestResult", payload)
}
