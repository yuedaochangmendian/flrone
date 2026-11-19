// Wire tests for the test-session action relay (ADR 0004 P4a).
//
// The six handlers are deliberately thin — Go owns no session state — so what
// matters is that each action's method and raw payload reach the platform's
// test_session_<op> slot verbatim, that the host's JSON answer is returned
// unchanged (bool verdict, {"removed": N}), and that a plain-text/empty host
// answer becomes an action error rather than a false success.

package mobile

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestTestSessionRelayForwardsOpAndRawPayload(t *testing.T) {
	var gotOp, gotPayload string
	send := func(op, payload string) string {
		gotOp, gotPayload = op, payload
		return "true"
	}
	data := json.RawMessage(`{"kind":2,"profileIds":[7,8],"testCurrent":false,"speedMode":-1}`)
	value, err := relayTestSessionWith("start", data, send)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotOp != "start" {
		t.Fatalf("op = %q, want start", gotOp)
	}
	if gotPayload != string(data) {
		t.Fatalf("payload = %q, want %q", gotPayload, string(data))
	}
	if value != true {
		t.Fatalf("value = %#v, want true", value)
	}
}

func TestTestSessionRelayNormalizesEmptyPayload(t *testing.T) {
	var gotPayload string
	send := func(_, payload string) string {
		gotPayload = payload
		return "true"
	}
	if _, err := relayTestSessionWith("stop", json.RawMessage("null"), send); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotPayload != "{}" {
		t.Fatalf("payload = %q, want {}", gotPayload)
	}
}

func TestTestSessionRelayKeepsHostJSONVerbatim(t *testing.T) {
	// `remove` answers an object, not a bool; Go must not reshape it.
	send := func(_, _ string) string { return `{"removed":3}` }
	value, err := relayTestSessionWith("remove", json.RawMessage(`{"ids":[1,2]}`), send)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := map[string]any{"removed": float64(3)}
	if !reflect.DeepEqual(value, want) {
		t.Fatalf("value = %#v, want %#v", value, want)
	}
}

func TestTestSessionRelayTurnsHostErrorIntoActionError(t *testing.T) {
	send := func(_, _ string) string { return "Missing kind" }
	value, err := relayTestSessionWith("start", json.RawMessage(`{}`), send)
	if err == nil {
		t.Fatal("expected an error for a plain-text host answer")
	}
	if value != nil {
		t.Fatalf("value = %#v, want nil on error", value)
	}
	want := "test session start: Missing kind"
	if err.Error() != want {
		t.Fatalf("error = %q, want %q", err.Error(), want)
	}
}

func TestTestSessionRelayRejectsMissingPlatformCallback(t *testing.T) {
	send := func(_, _ string) string { return "" }
	if _, err := relayTestSessionWith("sort", json.RawMessage(`{"groupId":4}`), send); err == nil {
		t.Fatal("expected an error when the platform callback is unavailable")
	}
}

func TestTestSessionActionMethodsAreRegistered(t *testing.T) {
	for _, method := range []Method{
		speedTestSessionStartMethod,
		speedTestSessionStopMethod,
		speedTestSessionDismissMethod,
		speedTestSessionSortMethod,
		speedTestSessionRemoveMethod,
		speedTestSessionVisibleMethod,
	} {
		if _, ok := actionHandlers[method]; !ok {
			t.Errorf("method %q is not registered", method)
		}
	}
}
