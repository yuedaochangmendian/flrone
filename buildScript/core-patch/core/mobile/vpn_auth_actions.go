// OpenVPN/OpenConnect sign-in challenges on the JSON action bus.
//
// The pinned core exposes four Instance methods (mobile/vpnauth.go):
//
//	VPNStatus(timeoutMs) (string, error)
//	SubmitVPNChallenge(tag, id, answerJSON) error
//	CancelVPNChallenge(tag, id) error
//	WatchVPNStatus(listener VPNStatusListener) (bool, error)
//
// This file exposes them as four bus actions. Reads and writes are Dart-driven
// (Dart -> action bus -> Go); the watch is Go-driven and pushes each status list
// as one `vpnStatus` message-port event. The service engine's KernelService
// forwards that event over the UI IPC stream, so no gobind listener has to cross
// the JNI boundary and no new MethodChannel arm is required.
//
// Wire shapes (all strings on the wire except where noted):
//
//	vpnStatus           data: {timeoutMs?: int}  -> JSON array of EndpointStatus
//	submitVPNChallenge  data: {tag, id, answer: {username?,password?,secret?,form_values?}}
//	cancelVPNChallenge  data: {tag, id}
//	vpnWatchStatus      data: {}                 -> {watching: bool}
//
// The first three need a running box (currentInstance reports that otherwise).
// vpnWatchStatus is idempotent: one listener per running instance, installed on
// the first call and left to the core until the box closes.
//
// Security: answers carry credentials. Nothing here logs the answer, the status
// JSON or the fields' prefilled values; a malformed answer is rejected with a
// generic error, never echoed back.

package mobile

import (
	"encoding/json"
	"fmt"
	"sync"

	E "github.com/sagernet/sing/common/exceptions"
)

const (
	vpnStatusMethod          Method = "vpnStatus"
	submitVPNChallengeMethod Method = "submitVPNChallenge"
	cancelVPNChallengeMethod Method = "cancelVPNChallenge"
	vpnWatchStatusMethod     Method = "vpnWatchStatus"
)

// vpnStatusPush is the event tag the Dart side consumes (KernelService ->
// service_entry IPC -> box.dart's eventBus -> the challenge sheet).
const vpnStatusPush = "vpnStatus"

func init() {
	register(vpnStatusMethod, handleVPNStatus)
	register(submitVPNChallengeMethod, handleSubmitVPNChallenge)
	register(cancelVPNChallengeMethod, handleCancelVPNChallenge)
	register(vpnWatchStatusMethod, handleVPNWatchStatus)
}

// vpnStatusRequest is optional: a missing/zero timeout means "answer at once".
type vpnStatusRequest struct {
	TimeoutMs int32 `json:"timeoutMs"`
}

func decodeVPNStatusRequest(raw json.RawMessage) (vpnStatusRequest, error) {
	var request vpnStatusRequest
	if len(raw) == 0 || string(raw) == "null" {
		return request, nil
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return request, E.New("invalid vpnStatus request")
	}
	if request.TimeoutMs < 0 {
		return request, E.New("vpnStatus timeoutMs must not be negative")
	}
	return request, nil
}

// handleVPNStatus answers with the status list as a raw JSON array (not a
// string wrapping one): json.RawMessage embeds the core's own encoding, so the
// Dart facade gets a list without a second decode step.
func handleVPNStatus(raw json.RawMessage) (any, error) {
	request, err := decodeVPNStatusRequest(raw)
	if err != nil {
		return nil, err
	}
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	statusJSON, err := instance.VPNStatus(request.TimeoutMs)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(statusJSON), nil
}

// vpnChallengeTarget is the (tag, id) pair that names one parked challenge.
type vpnChallengeTarget struct {
	Tag string `json:"tag"`
	ID  string `json:"id"`
}

func decodeVPNChallengeTarget(raw json.RawMessage) (vpnChallengeTarget, error) {
	var target vpnChallengeTarget
	if err := json.Unmarshal(raw, &target); err != nil || target.Tag == "" || target.ID == "" {
		return target, E.New("invalid challenge target: tag and id are required")
	}
	return target, nil
}

// decodeVPNAnswer normalizes the Dart-side answer object into the exact JSON
// the core's vpnauth.Answer expects. Only the four known keys survive: an
// accidental extra field cannot smuggle data into the core, and a missing map
// answers "{}" (the documented acknowledgement).
func decodeVPNAnswer(raw json.RawMessage) (string, error) {
	var incoming map[string]any
	if len(raw) == 0 || string(raw) == "null" {
		return "{}", nil
	}
	if err := json.Unmarshal(raw, &incoming); err != nil {
		return "", E.New("invalid challenge answer")
	}
	out := make(map[string]any, 4)
	for _, key := range []string{"username", "password", "secret"} {
		if value, ok := incoming[key]; ok && value != nil {
			text, isString := value.(string)
			if !isString {
				return "", E.New("invalid challenge answer: " + key + " must be a string")
			}
			out[key] = text
		}
	}
	if values, ok := incoming["form_values"]; ok && values != nil {
		fields, isMap := values.(map[string]any)
		if !isMap {
			return "", E.New("invalid challenge answer: form_values must be an object")
		}
		cleaned := make(map[string]string, len(fields))
		for key, value := range fields {
			text, isString := value.(string)
			if !isString {
				return "", E.New("invalid challenge answer: form_values must contain strings")
			}
			cleaned[key] = text
		}
		out["form_values"] = cleaned
	}
	encoded, err := json.Marshal(out)
	if err != nil {
		return "", E.New("encode challenge answer")
	}
	return string(encoded), nil
}

type vpnSubmitRequest struct {
	Tag    string          `json:"tag"`
	ID     string          `json:"id"`
	Answer json.RawMessage `json:"answer"`
}

func handleSubmitVPNChallenge(raw json.RawMessage) (any, error) {
	var request vpnSubmitRequest
	if err := json.Unmarshal(raw, &request); err != nil || request.Tag == "" || request.ID == "" {
		return nil, E.New("invalid submitVPNChallenge request: tag and id are required")
	}
	answerJSON, err := decodeVPNAnswer(request.Answer)
	if err != nil {
		return nil, err
	}
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	if err = instance.SubmitVPNChallenge(request.Tag, request.ID, answerJSON); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

func handleCancelVPNChallenge(raw json.RawMessage) (any, error) {
	target, err := decodeVPNChallengeTarget(raw)
	if err != nil {
		return nil, err
	}
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	if err = instance.CancelVPNChallenge(target.Tag, target.ID); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

// vpnStatusListener adapts the core's push callback to the message port. It is
// a value with an injectable emitter so the forwarding behaviour is testable
// without a running box or an attached Dart port.
type vpnStatusListener struct {
	emit func(string)
}

func (l vpnStatusListener) OnVPNStatus(statusJSON string) {
	if l.emit == nil || statusJSON == "" {
		return
	}
	l.emit(statusJSON)
}

var vpnWatch struct {
	mu       sync.Mutex
	instance *Instance
	watching bool
}

// handleVPNWatchStatus installs one watcher per running instance. The core's
// WatchVPNStatus calls the listener once immediately and again on every change
// from one goroutine until the box closes; re-calling the action is a no-op.
func handleVPNWatchStatus(_ json.RawMessage) (any, error) {
	instance, err := currentInstance()
	if err != nil {
		return nil, err
	}
	vpnWatch.mu.Lock()
	if vpnWatch.watching && vpnWatch.instance == instance {
		vpnWatch.mu.Unlock()
		return map[string]any{"watching": true}, nil
	}
	listener := vpnStatusListener{emit: func(statusJSON string) {
		sendEvent(vpnStatusPush, json.RawMessage(statusJSON))
	}}
	watching, watchErr := instance.WatchVPNStatus(listener)
	if watchErr != nil {
		vpnWatch.mu.Unlock()
		return nil, fmt.Errorf("watch VPN status: %w", watchErr)
	}
	// A box with no openvpn/openconnect endpoint answers false and never calls
	// the listener. Do not cache that as watching: a later config reload can add one.
	if watching {
		vpnWatch.instance = instance
		vpnWatch.watching = true
	}
	vpnWatch.mu.Unlock()
	return map[string]any{"watching": watching}, nil
}
