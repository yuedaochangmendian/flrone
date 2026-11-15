// The speed test's instance resolution (ffiMode regression).
//
// `throne_Mobile_startSpeedTest` used to type-assert `handleGet(current).(*Instance)`
// directly. In ffiMode Kotlin has no handle to pass — the box lives on Dart's side of
// the process — so it sends 0, handleGet(0) answered nil, the assertion panicked, and
// guardExport turned that panic into an error message: the speed test silently never
// ran. startURLTestLive and startIPTestLive already resolved their instance through
// lastInstance; this pins the speed test's copy of that rule.
//
// speedTestInstance is the seam: it takes the handle and the request and answers the
// instance StartSpeedTest receives, so every branch is reachable without cgo and
// without a running box (the pure-Go harness supplies handleNew/lastInstance).
package mobile

import (
	"errors"
	"testing"
)

// resetLastInstance clears the process-wide box so one test cannot see another's.
func resetLastInstance(t *testing.T) {
	t.Helper()
	lastInstance.mu.Lock()
	previous := lastInstance.inst
	lastInstance.inst = nil
	lastInstance.mu.Unlock()
	t.Cleanup(func() {
		lastInstance.mu.Lock()
		lastInstance.inst = previous
		lastInstance.mu.Unlock()
	})
}

// setLastInstance installs the box the fallback looks for.
func setLastInstance(t *testing.T, inst *Instance) {
	t.Helper()
	lastInstance.mu.Lock()
	lastInstance.inst = inst
	lastInstance.mu.Unlock()
}

func TestSpeedTestInstancePrefersTheHandle(t *testing.T) {
	resetLastInstance(t)

	// A running box is also registered, so "the handle won" is a real claim: a
	// resolver that ignored the handle would answer the registered one instead.
	setLastInstance(t, &Instance{started: true})
	fromHandle := &Instance{started: true}
	handle := handleNew(fromHandle)

	got, err := speedTestInstance(handle, &TestRequest{TestCurrent: true})
	if err != nil {
		t.Fatalf("a valid handle must resolve: %v", err)
	}
	if got != fromHandle {
		t.Fatalf("want the instance the handle names, got a different one")
	}
}

func TestSpeedTestInstanceFallsBackToTheRunningBox(t *testing.T) {
	resetLastInstance(t)

	// current = 0 is what ffiMode sends: Kotlin holds no handle for Dart's box.
	running := &Instance{started: true}
	setLastInstance(t, running)

	got, err := speedTestInstance(0, &TestRequest{TestCurrent: true})
	if err != nil {
		t.Fatalf("a TestCurrent request must fall back to the running box: %v", err)
	}
	if got != running {
		t.Fatal("want the registered instance back")
	}
}

func TestSpeedTestInstanceLeavesAProbeRequestWithoutAnInstance(t *testing.T) {
	resetLastInstance(t)

	// An offline node's probe builds its own box from request.CoreConfig; handing it
	// the running box would measure the wrong exit.
	setLastInstance(t, &Instance{started: true})

	got, err := speedTestInstance(0, &TestRequest{TestCurrent: false})
	if err != nil {
		t.Fatalf("a probe request must not fail: %v", err)
	}
	if got != nil {
		t.Fatal("a probe request must resolve no instance")
	}
}

func TestSpeedTestInstanceRefusesToFallBackWithoutARunningBox(t *testing.T) {
	resetLastInstance(t)

	// Nothing registered is the "VPN is off" answer, not a nil the caller would
	// dereference later.
	got, err := speedTestInstance(0, &TestRequest{TestCurrent: true})
	if !errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("want errInstanceNotRunning for no box, got %v", err)
	}
	if got != nil {
		t.Fatal("no box must answer no instance")
	}

	// A box that is registered but stopped is the same answer.
	setLastInstance(t, &Instance{})
	if _, err := speedTestInstance(0, &TestRequest{TestCurrent: true}); !errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("want errInstanceNotRunning for a stopped box, got %v", err)
	}
}

func TestSpeedTestInstanceKeepsAStoppedHandleForPrepareTestEnv(t *testing.T) {
	resetLastInstance(t)

	// current != 0 keeps the old behaviour: a resolvable handle names the instance
	// whatever its state, and prepareTestEnv is what refuses a dead one for a
	// TestCurrent request. Answering an error here instead would change which failure
	// the caller reports.
	stopped := &Instance{}
	handle := handleNew(stopped)
	setLastInstance(t, &Instance{started: true})

	got, err := speedTestInstance(handle, &TestRequest{TestCurrent: true})
	if err != nil {
		t.Fatalf("a resolvable handle must not fail here: %v", err)
	}
	if got != stopped {
		t.Fatal("want the instance the handle names, not the fallback")
	}
}

func TestSpeedTestInstanceIgnoresAnUnknownHandle(t *testing.T) {
	resetLastInstance(t)

	// A stale handle is the other half of the ffiMode defect: it must fall through to
	// the fallback rather than panic on a nil assertion. Released rather than invented
	// so the value cannot collide with a handle another test still holds.
	stale := handleNew(&Instance{started: true})
	handleRelease(stale)
	running := &Instance{started: true}
	setLastInstance(t, running)

	got, err := speedTestInstance(stale, &TestRequest{TestCurrent: true})
	if err != nil {
		t.Fatalf("an unknown handle must fall back, not fail: %v", err)
	}
	if got != running {
		t.Fatal("an unknown handle must resolve the running box")
	}
}
