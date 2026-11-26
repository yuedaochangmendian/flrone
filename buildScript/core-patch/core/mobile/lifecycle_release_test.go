// Tests for the deferred OS-memory release around Start/Close. The two seams
// (newLifecycleTimer, lifecycleFreeOSMemory) let these run without sleeping or
// racing the runtime's heap: a fake timer fires on demand and a counter stands
// in for debug.FreeOSMemory.
package mobile

import (
	"runtime"
	"sync"
	"testing"
	"time"
)

type manualTimer struct {
	delay   time.Duration
	fn      func()
	stopped bool
	mu      sync.Mutex
}

func (m *manualTimer) Stop() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	wasStopped := m.stopped
	m.stopped = true
	return !wasStopped
}

func (m *manualTimer) fire() {
	m.mu.Lock()
	if m.stopped {
		m.mu.Unlock()
		return
	}
	m.stopped = true
	fn := m.fn
	m.mu.Unlock()
	if fn != nil {
		fn()
	}
}

// installLifecycleSeams swaps in a manual timer and a release counter for the
// duration of one test. Tests using it must not run in parallel.
func installLifecycleSeams(t *testing.T) (*[]*manualTimer, *int) {
	t.Helper()
	oldFactory := newLifecycleTimer
	oldFree := lifecycleFreeOSMemory

	var timers []*manualTimer
	releases := 0
	newLifecycleTimer = func(delay time.Duration, fn func()) lifecycleTimer {
		m := &manualTimer{delay: delay, fn: fn}
		timers = append(timers, m)
		return m
	}
	lifecycleFreeOSMemory = func() { releases++ }

	// A new test always starts from an empty slot.
	postLifecycleRelease.mu.Lock()
	if postLifecycleRelease.current != nil {
		postLifecycleRelease.current.timer.Stop()
		postLifecycleRelease.current = nil
	}
	postLifecycleRelease.mu.Unlock()

	t.Cleanup(func() {
		newLifecycleTimer = oldFactory
		lifecycleFreeOSMemory = oldFree
		postLifecycleRelease.mu.Lock()
		if postLifecycleRelease.current != nil {
			postLifecycleRelease.current.timer.Stop()
			postLifecycleRelease.current = nil
		}
		postLifecycleRelease.mu.Unlock()
	})
	return &timers, &releases
}

func TestCloseReleaseSkippedWhenNewLoadBegins(t *testing.T) {
	timers, releases := installLifecycleSeams(t)
	epoch := beginLifecycleEpoch()

	// Close schedules a release guarded by the epoch captured at stop time.
	schedulePostLifecycleRelease(postCloseReleaseDelay, closeReleaseGuard(epoch))

	// A new box construction begins before the timer fires. It is not counted in
	// runningInstances yet (still parsing config / box.New), so an
	// instance-count-only guard would wrongly allow the release.
	beginLifecycleEpoch()

	(*timers)[0].fire()
	if *releases != 0 {
		t.Fatalf("stale close release fired during a new load: %d releases", *releases)
	}
}

func TestCloseReleaseFiresWhenEpochAndInstancesUnchanged(t *testing.T) {
	timers, releases := installLifecycleSeams(t)
	epoch := beginLifecycleEpoch()
	schedulePostLifecycleRelease(postCloseReleaseDelay, closeReleaseGuard(epoch))
	(*timers)[0].fire()
	if *releases != 1 {
		t.Fatalf("releases = %d, want 1", *releases)
	}
}

func TestScheduleReplacesPendingTimerAndClearsFiredSlot(t *testing.T) {
	timers, releases := installLifecycleSeams(t)
	epoch := beginLifecycleEpoch()

	schedulePostLifecycleRelease(postCloseReleaseDelay, closeReleaseGuard(epoch))
	first := (*timers)[0]
	schedulePostLifecycleRelease(postStartReleaseDelay, closeReleaseGuard(epoch))
	second := (*timers)[1]

	// The first timer was stopped by the replacement schedule.
	first.fire()
	if *releases != 0 {
		t.Fatal("a replaced timer still fired")
	}

	second.fire()
	if *releases != 1 {
		t.Fatalf("releases = %d, want 1", *releases)
	}
	// The fired callback must clear the package-level slot, so the guard
	// closure (which captures the last Instance) is no longer retained.
	postLifecycleRelease.mu.Lock()
	cleared := postLifecycleRelease.current == nil
	postLifecycleRelease.mu.Unlock()
	if !cleared {
		t.Fatal("fired release timer was not cleared from the slot")
	}
}

// A failed load (parse/box.New error) must not strand the last stop's release:
// NewInstance invalidated it with a new epoch, so the error path re-arms it.
func TestFailedLoadReArmsCloseRelease(t *testing.T) {
	timers, releases := installLifecycleSeams(t)
	epoch := beginLifecycleEpoch()
	schedulePostLifecycleRelease(postCloseReleaseDelay, closeReleaseGuard(epoch))
	first := (*timers)[0]

	// A new load bumps the epoch and fails; the old timer is invalidated.
	beginLifecycleEpoch()
	restoreFailedLoadRelease()

	first.fire()
	if *releases != 0 {
		t.Fatal("stale release fired after a failed load")
	}
	if len(*timers) != 2 {
		t.Fatalf("failed load did not re-arm a timer: %d timers", len(*timers))
	}
	(*timers)[1].fire()
	if *releases != 1 {
		t.Fatalf("re-armed release did not fire: %d releases", *releases)
	}
}

// A timer that fires before the scheduler publishes its slot must not clear a
// newer slot nor leave the stale guard retained in the field.
func TestFastFiringTimerDoesNotClearNewerSlot(t *testing.T) {
	oldFactory := newLifecycleTimer
	oldFree := lifecycleFreeOSMemory
	releases := 0
	lifecycleFreeOSMemory = func() { releases++ }
	// Fire each timer inline, before schedulePostLifecycleRelease can publish it.
	newLifecycleTimer = func(delay time.Duration, fn func()) lifecycleTimer {
		m := &manualTimer{fn: fn}
		m.fire()
		return m
	}
	postLifecycleRelease.mu.Lock()
	postLifecycleRelease.current = nil
	postLifecycleRelease.mu.Unlock()
	t.Cleanup(func() {
		newLifecycleTimer = oldFactory
		lifecycleFreeOSMemory = oldFree
		postLifecycleRelease.mu.Lock()
		postLifecycleRelease.current = nil
		postLifecycleRelease.mu.Unlock()
	})

	epoch := beginLifecycleEpoch()
	schedulePostLifecycleRelease(0, closeReleaseGuard(epoch))
	if releases != 1 {
		t.Fatalf("releases = %d, want 1", releases)
	}
	postLifecycleRelease.mu.Lock()
	cleared := postLifecycleRelease.current == nil
	postLifecycleRelease.mu.Unlock()
	if !cleared {
		t.Fatal("a slot that fired before publication was kept in the field")
	}
}

func TestStartBoundaryGCSerializedWithForceGC(t *testing.T) {
	// Exercise the real seam NewInstance calls. Holding gcMu must block it,
	// exactly as it blocks handleForceGC, so two stop-the-world passes cannot
	// overlap regardless of which entry point asked for one.
	old := startBoundaryGC
	startBoundaryGC = func() {
		gcMu.Lock()
		runtime.GC()
		gcMu.Unlock()
	}
	t.Cleanup(func() { startBoundaryGC = old })

	gcMu.Lock()
	done := make(chan struct{})
	go func() {
		startBoundaryGC()
		close(done)
	}()
	select {
	case <-done:
		gcMu.Unlock()
		t.Fatal("start-boundary GC did not wait for gcMu")
	case <-time.After(10 * time.Millisecond):
	}
	gcMu.Unlock()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("start-boundary GC never acquired gcMu")
	}
}
