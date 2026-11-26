// Wire tests for the VPN sign-in challenge action bus.
//
// The handlers are deliberately thin — the core owns the endpoints — so what
// matters here is the contract at the boundary: the request keys, the answer's
// four-key shape, the push tag and the watcher's idempotence. Tests that need a
// live instance use the same local box fixture as the route CRUD tests; the
// pure codec and listener tests need no core at all.

package mobile

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestVPNStatusRequestDecoding(t *testing.T) {
	request, err := decodeVPNStatusRequest(nil)
	if err != nil || request.TimeoutMs != 0 {
		t.Fatalf("empty request = %#v, %v; want zero timeout", request, err)
	}
	request, err = decodeVPNStatusRequest(json.RawMessage(`{"timeoutMs":1500}`))
	if err != nil || request.TimeoutMs != 1500 {
		t.Fatalf("decoded = %#v, %v; want 1500", request, err)
	}
	if _, err = decodeVPNStatusRequest(json.RawMessage(`{"timeoutMs":-1}`)); err == nil {
		t.Fatal("expected a negative timeout to be rejected")
	}
}

func TestVPNChallengeAnswerShape(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want map[string]any
	}{
		{"empty acknowledges", `null`, map[string]any{}},
		{"credentials", `{"username":"alice","password":"s3cret","extra":"ignored"}`,
			map[string]any{"username": "alice", "password": "s3cret"}},
		{"secret", `{"secret":"one-time"}`,
			map[string]any{"secret": "one-time"}},
		{"form values keyed by submission_key", `{"form_values":{"username":"bob","otp":"123456"}}`,
			map[string]any{"form_values": map[string]any{"username": "bob", "otp": "123456"}}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			gotJSON, err := decodeVPNAnswer(json.RawMessage(tc.raw))
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			var got map[string]any
			if err = json.Unmarshal([]byte(gotJSON), &got); err != nil {
				t.Fatalf("answer is not valid JSON: %v", err)
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("answer = %#v, want %#v", got, tc.want)
			}
		})
	}
}

func TestVPNChallengeAnswerRejectsBadShapes(t *testing.T) {
	for _, raw := range []string{
		`{"password":7}`,
		`{"form_values":[]}`,
		`{"form_values":{"otp":true}}`,
	} {
		if _, err := decodeVPNAnswer(json.RawMessage(raw)); err == nil {
			t.Errorf("answer %s should have been rejected", raw)
		}
	}
}

func TestVPNChallengeTargetRequiresTagAndID(t *testing.T) {
	for _, raw := range []string{`{}`, `{"tag":"vpn0"}`, `{"id":"c1"}`} {
		if _, err := decodeVPNChallengeTarget(json.RawMessage(raw)); err == nil {
			t.Errorf("target %s should have been rejected", raw)
		}
	}
	target, err := decodeVPNChallengeTarget(json.RawMessage(`{"tag":"vpn0","id":"c1"}`))
	if err != nil || target.Tag != "vpn0" || target.ID != "c1" {
		t.Fatalf("target = %#v, %v", target, err)
	}
}

func TestVPNStatusListenerForwardsVerbatim(t *testing.T) {
	var got string
	listener := vpnStatusListener{emit: func(value string) { got = value }}
	status := `[{"tag":"vpn0","state":"auth-pending"}]`
	listener.OnVPNStatus(status)
	if got != status {
		t.Fatalf("emitted %q, want %q", got, status)
	}
	// A nil emitter and an empty payload are both no-ops (the core always sends
	// a JSON array, so an empty string means a broken/unknown status).
	listener = vpnStatusListener{}
	listener.OnVPNStatus(status)
	if got != status {
		t.Fatalf("nil emitter changed the captured value to %q", got)
	}
}

func TestVPNWatchStatusActionIsRegistered(t *testing.T) {
	for _, method := range []Method{
		vpnStatusMethod, submitVPNChallengeMethod, cancelVPNChallengeMethod, vpnWatchStatusMethod,
	} {
		if _, ok := actionHandlers[method]; !ok {
			t.Errorf("method %q is not registered", method)
		}
	}
}
