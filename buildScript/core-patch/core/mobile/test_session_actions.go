// Test-session control on the JSON action bus (ADR 0004, P4a).
//
// The long-running test session lives in Kotlin (TestSessionClient /
// SpeedTestRunner), so Go owns no session state here: every handler is a thin
// relay. It forwards the Dart action's raw JSON payload to the platform's
// `platform_request("test_session_<op>", payload)` slot and answers with the
// Kotlin result verbatim. That keeps one implementation per operation on the
// host (BboxTestSessions) and no second copy in Go.
//
// Wire shapes (the names are the Dart ActionMethod members):
//
//   speedTestSessionStart   {"kind","profileIds","testCurrent","speedMode"} -> bool
//   speedTestSessionStop    {}                                               -> true
//   speedTestSessionDismiss {}                                               -> true
//   speedTestSessionSort    {"groupId"}                                      -> bool
//   speedTestSessionRemove  {"ids"}                                          -> {"removed": N}
//
// `false` from start/sort is a verdict, not an error: it is a JSON boolean and
// reaches Dart as such. A host failure is an error string (non-zero ActionResult
// code) and surfaces as an ActionException.
//
// `visible` is not a bus method: it is the UI feed's demand signal, which stays
// on the `groups.testSession.visible` channel so it works with no core attached.
// The `testSession` push still rides that EventChannel (FlronePlatformBridge
// registers its emitter with FlroneTestSessions); moving the push itself would
// require touching the service engine, which P4a deliberately does not.

package mobile

import (
	"encoding/json"
	"fmt"
)

const (
	speedTestSessionStartMethod   Method = "speedTestSessionStart"
	speedTestSessionStopMethod    Method = "speedTestSessionStop"
	speedTestSessionDismissMethod Method = "speedTestSessionDismiss"
	speedTestSessionSortMethod    Method = "speedTestSessionSort"
	speedTestSessionRemoveMethod  Method = "speedTestSessionRemove"
)

func init() {
	register(speedTestSessionStartMethod, handleSpeedTestSessionStart)
	register(speedTestSessionStopMethod, handleSpeedTestSessionStop)
	register(speedTestSessionDismissMethod, handleSpeedTestSessionDismiss)
	register(speedTestSessionSortMethod, handleSpeedTestSessionSort)
	register(speedTestSessionRemoveMethod, handleSpeedTestSessionRemove)
}

// relayTestSession is the production seam: it sends through the four-slot
// platform_request callback. relayTestSessionWith is the pure core the unit
// tests drive with a fake sender (no cgo / core library needed).
func relayTestSession(op string, data json.RawMessage) (any, error) {
	return relayTestSessionWith(op, data, func(op, payload string) string {
		return platformRequest("test_session_"+op, json.RawMessage(payload))
	})
}

// relayTestSessionWith forwards one action's raw payload to the host and decodes
// its JSON answer. An empty answer means the platform callback was not installed
// (a foreign core); treating it as an error is honest — the caller then reports
// the failure instead of believing a session started.
func relayTestSessionWith(op string, data json.RawMessage, send func(string, string) string) (any, error) {
	payload := string(data)
	if payload == "" || payload == "null" {
		payload = "{}"
	}
	answer := send(op, payload)
	if answer == "" {
		return nil, fmt.Errorf("test session %s: platform callback unavailable", op)
	}
	var value any
	if err := json.Unmarshal([]byte(answer), &value); err != nil {
		// The host reports a failure as plain text; keep it as the action error.
		return nil, fmt.Errorf("test session %s: %s", op, answer)
	}
	return value, nil
}

func handleSpeedTestSessionStart(data json.RawMessage) (any, error) {
	return relayTestSession("start", data)
}

func handleSpeedTestSessionStop(data json.RawMessage) (any, error) {
	return relayTestSession("stop", data)
}

func handleSpeedTestSessionDismiss(data json.RawMessage) (any, error) {
	return relayTestSession("dismiss", data)
}

func handleSpeedTestSessionSort(data json.RawMessage) (any, error) {
	return relayTestSession("sort", data)
}

func handleSpeedTestSessionRemove(data json.RawMessage) (any, error) {
	return relayTestSession("remove", data)
}
