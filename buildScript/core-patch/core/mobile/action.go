// The Bettbox-style JSON action bus (ADR 0002, phase 1).
//
// The transport was already Bettbox-shaped — Dart_PostCObject_DL, a message
// port, one long-lived isolate — but every call had its own typed throne_*
// export. This file adds the missing protocol layer: one C entry point
// (`throne_invoke_action`, emitted in bridge_runtime.go) that unmarshals an
// Action, dispatches it through a registry, and answers with an ActionResult
// whose id echoes the request so Dart can correlate it with a Completer.
//
// The 424 typed exports are NOT removed. They are the handlers' implementation:
// a method below calls the same Go functions the typed ABI exposes. That keeps
// symbol_audit.py's three-way equality intact and avoids rewriting generated
// bindings.
//
// Method constants and the registry are checked against Dart's ActionMethod
// enum by tools/diagnostics/action_contract.py. Bettbox keeps those lists in
// sync only by convention and has a real drift on resetConnections; the audit
// is what stops us from copying that bug.

package mobile

import (
	"encoding/json"
	"fmt"
)

// Method is the wire name of one action. It is a string so the JSON shape is
// self-describing and so the same name can be used on both sides of the C ABI.
type Method string

const (
	// actionVersionMethod is the phase-1 smoke test: it proves the bus can
	// round-trip an id, a handler and a result without touching a real config.
	actionVersionMethod Method = "actionVersion"

	// messageMethod is the tag of an unsolicited Go->Dart push. It is not a
	// registered handler: pushes are posted with no id and never correlate.
	messageMethod Method = "message"
)

const (
	actionCodeSuccess = 0
	actionCodeError   = -1
)

// Action is one request. Id is echoed back verbatim; Method names the handler;
// Data is left as raw JSON so each handler decides its own payload shape.
type Action struct {
	Id     string          `json:"id"`
	Method Method          `json:"method"`
	Data   json.RawMessage `json:"data"`
}

// ActionResult is the reply. Port is Go-only: it is the Dart reply port the
// result must be posted to, and is deliberately not serialized.
type ActionResult struct {
	Id     string `json:"id"`
	Method Method `json:"method"`
	Data   any    `json:"data"`
	Code   int    `json:"code"`
	Port   int64  `json:"-"`
}

// JSON marshals the reply. Kept as a method so the emitter and any future
// socket transport share one encoding (Bettbox's server.go does the same).
func (result ActionResult) JSON() ([]byte, error) {
	return json.Marshal(result)
}

type actionHandler func(json.RawMessage) (any, error)

// actionHandlers is the dispatcher registry. Every Method constant that is a
// real request must appear here; action_contract.py enforces that.
var actionHandlers = map[Method]actionHandler{}

// register adds one handler. A duplicate is a programming error: keep the
// first registration and let dispatchAction's unknown-method path stay
// unreachable, rather than panicking in init (a cgo boundary must never see a
// Go panic, even during package initialization).
func register(method Method, handler actionHandler) {
	if _, exists := actionHandlers[method]; exists {
		return
	}
	actionHandlers[method] = handler
}

func init() {
	register(actionVersionMethod, handleActionVersion)
}

// handleActionVersion answers the protocol version and the kernel's own
// version string. It is the end-to-end proof in phase 1: a Dart invoke<T>
// sends an id, this handler runs, and the reply closes the matching Completer.
func handleActionVersion(_ json.RawMessage) (any, error) {
	return map[string]any{
		"protocol": 1,
		"core":     Version(),
	}, nil
}

// RunAction dispatches one action synchronously and answers its encoded
// ActionResult. It is the gobind face of the same registry `throne_invoke_action`
// feeds: the Dart path correlates by id and waits on a port, while a Kotlin
// caller has nowhere to post to and needs the answer back on its own thread.
//
// The Android side uses it for the one write it cannot do itself any more: the
// global route rules belong to the kernel, so callers save through
// `saveGlobalRules` instead of touching the documents directly.
//
// Encoded rather than a struct so the gobind surface stays one string in, one
// string out — adding a second method later does not change the AAR's Java shape.
func RunAction(actionJSON string) string {
	result := runActionSynchronously(actionJSON)
	encoded, err := result.JSON()
	if err != nil {
		return `{"code":-1,"data":"encode action result: ` + err.Error() + `"}`
	}
	return string(encoded)
}

// runActionSynchronously is RunAction with the same panic fence the exported
// handlers use: a panic here crosses a gobind (JNI) boundary, which must not
// abort the process.
func runActionSynchronously(actionJSON string) (result ActionResult) {
	defer func() {
		if r := recover(); r != nil {
			result = ActionResult{Code: actionCodeError, Data: "panic: " + fmt.Sprint(r)}
		}
	}()
	var action Action
	if err := json.Unmarshal([]byte(actionJSON), &action); err != nil {
		return ActionResult{Code: actionCodeError, Data: err.Error()}
	}
	result = ActionResult{Id: action.Id, Method: action.Method}
	handler, ok := actionHandlers[action.Method]
	if !ok {
		result.Code = actionCodeError
		result.Data = "unknown action method: " + string(action.Method)
		return result
	}
	data, err := handler(action.Data)
	if err != nil {
		result.Code = actionCodeError
		result.Data = err.Error()
	} else {
		result.Code = actionCodeSuccess
		result.Data = data
	}
	return result
}

// --- phase 3a: the speed test ------------------------------------------------

// currentInstance is the box the actions measure through. The FFI driver builds
// it in Go, so the handle registry is the authority; the gobind path registers
// the same object from its constructor.
func currentInstance() (*Instance, error) {
	lastInstance.mu.Lock()
	inst := lastInstance.inst
	lastInstance.mu.Unlock()
	if inst == nil || !inst.running() {
		return nil, errInstanceNotRunning
	}
	return inst, nil
}

// speedTestInstance resolves the instance StartSpeedTest measures through.
//
// `current` is a bridge handle: the export reads it from the caller, and in ffiMode Kotlin
// has no handle to pass (the box lives on Dart's side of the process), so it sends 0. A
// direct type assertion on handleGet(0) was the defect: handleGet answers nil for an unknown
// handle, the assertion panics, guardExport turns the panic into an error message and the
// test never starts. The URL and IP entries already resolved their instance this way
// (startURLTestLive, startIPTestLive); this is the speed test's copy of it.
//
// A handle that resolves decides on its own, so `current != 0` keeps the old behaviour
// (prepareTestEnv refuses a dead instance for a TestCurrent request). Only when nothing
// resolved does TestCurrent fall back to the box this process runs — in ffiMode that is the
// only place the instance can come from. A probe request (TestCurrent false) still answers
// nil: StartSpeedTest builds a separate box from request.CoreConfig for it.
func speedTestInstance(current int64, request *TestRequest) (*Instance, error) {
	var inst *Instance
	if current != 0 {
		if value, ok := handleGet(current).(*Instance); ok {
			inst = value
		}
	}
	if inst != nil {
		return inst, nil
	}
	if request == nil || !request.TestCurrent {
		return nil, nil
	}
	return currentInstance()
}
