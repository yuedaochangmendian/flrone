// The gobind entry point's instance resolution (ffiMode regression).
//
// `Mobile.startSpeedTest` — the gobind surface SpeedTestRunner.kt calls — binds to
// StartSpeedTest in test.go, not to the C ABI export `throne_Mobile_startSpeedTest`.
// Only the export resolved a caller handle, so in ffiMode (Kotlin never starts an
// Instance; the driver builds the box in Go via throne_Mobile_newInstance) the gobind
// call arrived with current == nil and prepareTestEnv answered errInstanceNotRunning:
// every run died with "instance is not running".
//
// resolveSpeedTestCurrent is the seam. It reads the process-wide lastInstance and
// nothing else, so every branch is reachable without a running box. StartSpeedTest
// past prepareTestEnv needs a real box, batch and handler, so most of the contract is
// pinned on the resolver's answer plus prepareTestEnv's not-running gate.
// TestSpeedTestGobindStartSpeedTestGetsPastTheGate then pins the one line that wires
// the resolver in: a fake box has no outbound manager, so the call panics where
// prepareTestEnv reads it — and that panic is the observable proof the request was
// accepted rather than answered with errInstanceNotRunning.
//
// Shares resetLastInstance/setLastInstance with speed_test_instance_test.go.
package mobile

import (
	"errors"
	"testing"
)

func TestSpeedTestGobindResolvesTheRunningBox(t *testing.T) {
	resetLastInstance(t)

	// current == nil is what gobind sends in ffiMode: the driver holds no handle for
	// the box it built itself.
	running := &Instance{started: true}
	setLastInstance(t, running)

	got := resolveSpeedTestCurrent(nil, &TestRequest{TestCurrent: true})
	if got != running {
		t.Fatalf("want the registered box for a nil current, got %v", got)
	}
	// prepareTestEnv's TestCurrent gate is exactly this predicate, so a resolved box
	// that is running is a box that gets past it.
	if !got.running() {
		t.Fatal("the resolved box must be the running one prepareTestEnv accepts")
	}
}

func TestSpeedTestGobindKeepsErrInstanceNotRunningWhenNothingRuns(t *testing.T) {
	resetLastInstance(t)

	// Nothing registered is the "VPN is off" answer, and it must stay the answer this
	// path reported before the fallback existed.
	nothing := resolveSpeedTestCurrent(nil, &TestRequest{TestCurrent: true})
	if nothing != nil {
		t.Fatalf("no box must resolve no instance, got %v", nothing)
	}
	// The nil it returns is what prepareTestEnv turns into the same error as before.
	if _, err := prepareTestEnv(nothing, true, nil, &TestRequest{TestCurrent: true}); !errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("want errInstanceNotRunning for a nil current, got %v", err)
	}

	// A box that is registered but stopped is the same answer.
	setLastInstance(t, &Instance{})
	stopped := resolveSpeedTestCurrent(nil, &TestRequest{TestCurrent: true})
	if stopped != nil {
		t.Fatalf("a stopped box must resolve no instance, got %v", stopped)
	}
	if _, err := prepareTestEnv(stopped, true, nil, &TestRequest{TestCurrent: true}); !errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("want errInstanceNotRunning for a stopped box, got %v", err)
	}
}

func TestSpeedTestGobindLeavesAProbeRequestWithoutAnInstance(t *testing.T) {
	resetLastInstance(t)

	// An offline node's probe builds its own box from request.CoreConfig; handing it
	// the running box would measure the wrong exit.
	setLastInstance(t, &Instance{started: true})

	if got := resolveSpeedTestCurrent(nil, &TestRequest{TestCurrent: false}); got != nil {
		t.Fatalf("a probe request must resolve no instance, got %v", got)
	}
	// No request at all is not a TestCurrent request either.
	if got := resolveSpeedTestCurrent(nil, nil); got != nil {
		t.Fatalf("a nil request must resolve no instance, got %v", got)
	}
}

func TestSpeedTestGobindKeepsACallerSuppliedInstance(t *testing.T) {
	resetLastInstance(t)

	// A caller that does hold an instance keeps deciding on its own, whatever its
	// state: prepareTestEnv is what refuses a dead one, and answering the fallback
	// here would silently measure the wrong box.
	setLastInstance(t, &Instance{started: true})
	stopped := &Instance{}

	if got := resolveSpeedTestCurrent(stopped, &TestRequest{TestCurrent: true}); got != stopped {
		t.Fatalf("want the caller's instance, got %v", got)
	}
	// A probe request carrying an instance is also left alone.
	if got := resolveSpeedTestCurrent(stopped, &TestRequest{TestCurrent: false}); got != stopped {
		t.Fatalf("want the caller's instance for a probe request, got %v", got)
	}
}

// speedTestHandler is the minimal SpeedTestHandler: StartSpeedTest only stores it.
type speedTestHandler struct{}

func (speedTestHandler) OnResult(result *SpeedTestResult) {}
func (speedTestHandler) OnDone()                          {}

// TestSpeedTestGobindStartSpeedTestGetsPastTheGate pins the wiring inside
// StartSpeedTest, not just the resolver. A bare &Instance{started: true} is enough
// for the not-running gate but has no outbound manager, so prepareTestEnv panics on
// it. That panic is the assertion: the request got past the gate. Without the
// `current = resolveSpeedTestCurrent(...)` line the same call returns
// errInstanceNotRunning instead, which this test rejects — only that error is a
// failure here, and the fake box is why nothing else can be asserted.
func TestSpeedTestGobindStartSpeedTestGetsPastTheGate(t *testing.T) {
	resetLastInstance(t)
	setLastInstance(t, &Instance{started: true})

	if _, err := prepareTestEnv(nil, true, nil, &TestRequest{TestCurrent: true}); !errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("the premise: a nil current must be refused, got %v", err)
	}

	request := &TestRequest{TestCurrent: true, TestDownload: true}
	defer func() {
		if recover() == nil {
			t.Fatal("the fake box must not have produced a working env; the gate was skipped")
		}
		// The resolver reached prepareTestEnv, which dereferenced the fake box.
	}()
	if err := StartSpeedTest(nil, nil, request, speedTestHandler{}); errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("StartSpeedTest must resolve the running box, got %v", err)
	}
}

// urlTestHandler is the minimal URLTestHandler: StartURLTest only stores it.
type urlTestHandler struct{}

func (urlTestHandler) OnResult(tag string, latencyMs int32, err string)                 {}
func (urlTestHandler) OnDone()                                                          {}
func (urlTestHandler) OnVPNStatus(tag string, connected bool, state string, err string) {}

// TestURLTestGobindStartURLTestGetsPastTheGate is the URL test's copy of the test above.
//
// The delay-test button builds its request through urlTestSpec, which marks a single node equal
// to the running profile as TestCurrent. In ffiMode the gobind entry then arrives with
// current == nil, and before StartURLTest resolved it the call answered errInstanceNotRunning:
// clicking the latency test of the node you are running through did nothing at all, while groups
// of other nodes worked. Same gate, same assertion shape as StartSpeedTest.
func TestURLTestGobindStartURLTestGetsPastTheGate(t *testing.T) {
	resetLastInstance(t)
	setLastInstance(t, &Instance{started: true})

	if _, err := prepareTestEnv(nil, true, nil, &TestRequest{TestCurrent: true}); !errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("the premise: a nil current must be refused, got %v", err)
	}

	request := &TestRequest{TestCurrent: true}
	defer func() {
		if recover() == nil {
			t.Fatal("the fake box must not have produced a working env; the gate was skipped")
		}
		// The resolver reached prepareTestEnv, which dereferenced the fake box.
	}()
	if err := StartURLTest(nil, nil, request, urlTestHandler{}); errors.Is(err, errInstanceNotRunning) {
		t.Fatalf("StartURLTest must resolve the running box, got %v", err)
	}
}
