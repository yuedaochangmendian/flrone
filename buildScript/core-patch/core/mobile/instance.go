package mobile

import (
	"context"
	"errors"
	"io"
	stdlog "log"
	"runtime"
	"runtime/debug"
	"sync"
	"sync/atomic"
	"time"

	"ThroneCore/internal/probe"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/common/trafficcontrol"
	"github.com/sagernet/sing-box/common/urltest"
	"github.com/sagernet/sing-box/experimental/clashmode"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing-box/option"
	tun "github.com/sagernet/sing-tun"
	E "github.com/sagernet/sing/common/exceptions"
	"github.com/sagernet/sing/service"
	"github.com/sagernet/sing/service/pause"
)

const boxCloseTimeout = 2 * time.Second

// FlClash's load/stop GC boundaries: a config's rule sets and the previous box's
// route tables are decoded into large, short-lived heap buffers that a plain GC
// cycle leaves retained until the next collection. Collect once before building
// a new box and release the pages back to the OS shortly after a start/stop has
// settled — but never on the caller's thread, so Start/Close stay responsive.
const (
	postStartReleaseDelay = 2 * time.Second
	postCloseReleaseDelay = 200 * time.Millisecond
)

// postLifecycleRelease serializes the deferred releases through one mutex and
// one timer. Two overlapping FreeOSMemory calls are wasteful and can hide each
// other's effect on the memory readings the UI just requested. The timer is
// replaced at the most recent boundary, so a quick stop/load cycle needs only
// one release after the last event.
//
// The slot is a pointer rather than the timer itself so the callback can clear
// the field without reading a variable that is assigned after the factory
// returns. A fired callback drops the slot — and with it the guard closure that
// captures the last Instance — from this package-level field.
type lifecycleReleaseSlot struct {
	timer lifecycleTimer
	// fired is set in the callback while holding postLifecycleRelease.mu. It
	// stops a stale callback from clearing (or stopping) a newer slot when a
	// zero/short delay lets the timer fire before the scheduler publishes it.
	fired bool
}

var postLifecycleRelease struct {
	mu      sync.Mutex
	current *lifecycleReleaseSlot
}

// lifecycleTimer is the slice of time.Timer the scheduler needs. The factory is
// a seam: tests install a manually fired timer so the epoch guard and the field
// cleanup can be checked without sleeping.
type lifecycleTimer interface {
	Stop() bool
}

var newLifecycleTimer = func(delay time.Duration, fn func()) lifecycleTimer {
	return time.AfterFunc(delay, fn)
}

// lifecycleFreeOSMemory is the deferred hand-back itself, serialized with the
// explicit forceGC action through gcMu. Kept as a seam so tests can count
// releases instead of racing the runtime's heap.
var lifecycleFreeOSMemory = func() {
	gcMu.Lock()
	debug.FreeOSMemory()
	gcMu.Unlock()
}

// schedulePostLifecycleRelease arms a single deferred OS-memory release. It is
// non-blocking, and the callback checks the supplied guard so a release planned
// by a stopped box is skipped if a new one has already started or is being
// constructed.
func schedulePostLifecycleRelease(delay time.Duration, guard func() bool) {
	slot := &lifecycleReleaseSlot{}
	slot.timer = newLifecycleTimer(delay, func() {
		// Clear our own slot first, and only if it is still current: a newer
		// boundary may have replaced us while this callback was waiting on mu.
		// Leaving the guard in the field would retain the last Instance. Mark
		// fired so a scheduler that publishes us afterwards does not re-arm a
		// slot whose callback has already run.
		postLifecycleRelease.mu.Lock()
		slot.fired = true
		if postLifecycleRelease.current == slot {
			postLifecycleRelease.current = nil
		}
		postLifecycleRelease.mu.Unlock()
		if guard() {
			lifecycleFreeOSMemory()
		}
	})
	postLifecycleRelease.mu.Lock()
	if postLifecycleRelease.current != nil && !postLifecycleRelease.current.fired {
		postLifecycleRelease.current.timer.Stop()
	}
	if !slot.fired {
		postLifecycleRelease.current = slot
	}
	postLifecycleRelease.mu.Unlock()
}

// startBoundaryGC is the collection at the start boundary, serialized with
// forceGC through gcMu. Kept as a seam so tests can prove the serialization
// without depending on runtime.GC timing.
var startBoundaryGC = func() {
	gcMu.Lock()
	runtime.GC()
	gcMu.Unlock()
}

// lifecycleEpoch advances whenever a new box construction begins. A release
// planned by the previous box must not fire while config parsing / box.New is
// running: that would add a second stop-the-world pause to the new load. The
// close-boundary guard only fires while the epoch is unchanged and no instance
// is running, so a load that is still starting suppresses the old release and
// the last stop's own release takes over.
var lifecycleEpoch atomic.Uint64

func beginLifecycleEpoch() uint64 {
	return lifecycleEpoch.Add(1)
}

// closeReleaseGuard is the guard attached to a post-Close release. Factored out
// so the epoch/instance conditions can be tested without constructing a box.
func closeReleaseGuard(epoch uint64) func() bool {
	return func() bool {
		return lifecycleEpoch.Load() == epoch && runningInstances.Load() == 0
	}
}

// restoreFailedLoadRelease re-arms the stop-boundary release when a new load
// fails before Start. beginLifecycleEpoch invalidated the previous box's
// deferred release; there may be no further Close to schedule one (a stopped
// box stays stopped, and the failed box never counted as an instance), so the
// last stop's heap would otherwise never be handed back to the OS.
func restoreFailedLoadRelease() {
	if runningInstances.Load() == 0 {
		schedulePostLifecycleRelease(postCloseReleaseDelay, closeReleaseGuard(lifecycleEpoch.Load()))
	}
}

// Main boxes past Start and not yet closed; probe boxes are not Instances.
var runningInstances atomic.Int32

type StartOptions struct {
	CoreConfig string
}

var _ probe.Box = (*boxHandle)(nil)

// The ctx handed to box.New is the box's service context (box.Context registers into the caller's
// registry and New reuses it), so no Box.Context() accessor is needed.
type boxHandle struct {
	ctx context.Context
	*box.Box
}

func (h *boxHandle) Context() context.Context {
	return h.ctx
}

type Instance struct {
	platform         PlatformInterface
	handle           *boxHandle
	cancel           context.CancelFunc
	interfaceMonitor tun.DefaultInterfaceMonitor

	pauseManager   pause.Manager
	outbounds      adapter.OutboundManager
	connections    adapter.ConnectionManager
	traffic        *trafficcontrol.Manager
	clashMode      *clashmode.Manager
	cacheFile      adapter.CacheFile
	urlTestHistory *urltest.HistoryStorage
	logFactory     log.Factory
	// The route rules the router was built from, in its order, for TestRoute.
	routeRules []option.Rule

	stateAccess     sync.Mutex
	started         bool
	closed          bool
	counted         bool
	localDNSFailure *LocalDNSFailure

	statusAccess      sync.Mutex
	statusSampled     bool
	lastUplinkTotal   int64
	lastDownlinkTotal int64

	outboundTrafficAccess sync.Mutex
	outboundTraffic       map[string]pendingTraffic
}

// Mirrors rpc.Start + boxmain.Create without the sidecars: build the box, then start it.
func NewInstance(platform PlatformInterface, options *StartOptions) (*Instance, error) {
	if platform == nil {
		return nil, E.New("nil platform interface")
	}
	if options == nil {
		return nil, E.New("nil start options")
	}
	// A new load supersedes any OS-memory release the previous box's Close
	// scheduled. Incrementing the epoch makes that timer skip itself even if it
	// fires while we parse the config / build the box (before this instance is
	// counted by runningInstances) — otherwise two stop-the-world pauses would
	// overlap the new build. The boundary GC below is serialized with the
	// deferred release through gcMu for the same reason.
	beginLifecycleEpoch()
	if setupDebug() {
		stdlog.Println("Start:", options.CoreConfig)
	}
	startBoundaryGC()

	installShimProtector(platform)
	ctx := newBoxContext(platform, newPlatformInterfaceWrapper(platform))
	boxOptions, err := parseConfig(ctx, options.CoreConfig)
	if err != nil {
		restoreFailedLoadRelease()
		return nil, err
	}
	ctx, cancel := context.WithCancel(ctx)
	urlTestHistory := urltest.NewHistoryStorage()
	ctx = service.ContextWithPtr(ctx, urlTestHistory)
	boxInstance, err := box.New(box.Options{
		Context:           ctx,
		Options:           boxOptions,
		PlatformLogWriter: newPlatformLogWriter(boxOptions.Log),
	})
	if err != nil {
		cancel()
		urlTestHistory.Close()
		restoreFailedLoadRelease()
		return nil, E.Cause(err, "create service")
	}
	var routeRules []option.Rule
	if boxOptions.Route != nil {
		routeRules = boxOptions.Route.Rules
	}
	instance := &Instance{
		platform:         platform,
		handle:           &boxHandle{ctx: ctx, Box: boxInstance},
		interfaceMonitor: boxInstance.Network().InterfaceMonitor(),
		cancel:           cancel,
		pauseManager:     service.FromContext[pause.Manager](ctx),
		outbounds:        service.FromContext[adapter.OutboundManager](ctx),
		connections:      service.FromContext[adapter.ConnectionManager](ctx),
		traffic:          service.PtrFromContext[trafficcontrol.Manager](ctx),
		clashMode:        service.PtrFromContext[clashmode.Manager](ctx),
		cacheFile:        service.FromContext[adapter.CacheFile](ctx),
		urlTestHistory:   urlTestHistory,
		logFactory:       boxInstance.LogFactory(),
		routeRules:       routeRules,
	}
	return instance, nil
}

func (i *Instance) Start() error {
	i.stateAccess.Lock()
	if i.closed {
		i.stateAccess.Unlock()
		return E.New("instance closed")
	}
	if i.started {
		i.stateAccess.Unlock()
		return E.New("instance already started")
	}
	i.started = true
	i.stateAccess.Unlock()
	if err := i.handle.Start(); err != nil {
		var dnsErr *localDNSError
		if errors.As(err, &dnsErr) {
			i.stateAccess.Lock()
			i.localDNSFailure = &LocalDNSFailure{Servers: dnsErr.servers}
			i.stateAccess.Unlock()
		}
		_ = i.Close()
		return E.Cause(err, "start service")
	}
	i.stateAccess.Lock()
	if !i.closed {
		i.counted = true
		runningInstances.Add(1)
		activeInstance.Store(i)
	}
	i.stateAccess.Unlock()
	// Device doze may have been requested while no instance existed (e.g. an
	// always-on VPN starting from a background/tile path). Apply the persisted
	// desired state now that a live box can be paused; a no-op when not dozing.
	applyPersistedDoze(i)
	// FlClash's load boundary (after the box has settled): let the runtime hand
	// the post-config decode buffers back to the OS. Async so Start never waits.
	schedulePostLifecycleRelease(postStartReleaseDelay, i.running)
	return nil
}

// LocalDNSFailure describes a start that failed because the local DNS server got no answer.
type LocalDNSFailure struct {
	// Servers lists the default network's DNS servers that were asked, empty when Android's resolver was.
	Servers string
}

// LocalDNSFailure is non-nil once Start has failed on the local DNS server.
func (i *Instance) LocalDNSFailure() *LocalDNSFailure {
	i.stateAccess.Lock()
	defer i.stateAccess.Unlock()
	return i.localDNSFailure
}

func (i *Instance) Close() error {
	i.stateAccess.Lock()
	if i.closed {
		i.stateAccess.Unlock()
		return nil
	}
	// Capture the load generation at stop time — before the (potentially
	// 2-second) box teardown. A new NewInstance that begins during teardown
	// advances the epoch and must invalidate our deferred release.
	epochAtClose := lifecycleEpoch.Load()
	i.closed = true
	if i.counted {
		i.counted = false
		runningInstances.Add(-1)
		activeInstance.CompareAndSwap(i, nil)
	}
	i.stateAccess.Unlock()
	err := closeBoxWithTimeout(i.cancel, i.handle.Box, boxCloseTimeout, true)
	i.urlTestHistory.Close()
	releaseShimProtector(i.platform)
	// FlClash's stop boundary: once no box is running, return the closed box's
	// heap to the OS. The guard also checks the epoch captured here: if a new
	// load starts before the timer fires, that load bumps the epoch and the
	// release is skipped so its own start-boundary collection is not doubled.
	// When that new box later stops, its Close arms a fresh release, so the last
	// stop still frees memory.
	if runningInstances.Load() == 0 {
		schedulePostLifecycleRelease(postCloseReleaseDelay, closeReleaseGuard(epochAtClose))
	}
	return err
}

func (i *Instance) running() bool {
	i.stateAccess.Lock()
	defer i.stateAccess.Unlock()
	return i.started && !i.closed
}

func (i *Instance) Pause() {
	if i.running() && i.pauseManager != nil {
		i.pauseManager.DevicePause()
	}
}

func (i *Instance) Wake() {
	if i.running() && i.pauseManager != nil {
		i.pauseManager.DeviceWake()
	}
}

func (i *Instance) NeedWIFIState() bool {
	if !i.running() {
		return false
	}
	return i.handle.Network().NeedWIFIState()
}

func (i *Instance) UpdateWIFIState() {
	if i.running() {
		i.handle.Network().UpdateWIFIState(i.handle.ctx)
	}
}

func (i *Instance) ResetNetwork() {
	if i.running() {
		i.handle.Network().ResetNetwork(i.handle.ctx)
	}
}

// boxmain.Box.CloseWithTimeout's semantics: cancel and Close on a goroutine, warn once the timer fires,
// and only a blocking caller learns the close error.
func closeBoxWithTimeout(cancel context.CancelFunc, closer io.Closer, timeout time.Duration, block bool) error {
	start := time.Now()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	done := make(chan struct{})
	var closeErr error
	go func() {
		cancel()
		closeErr = closer.Close()
		close(done)
	}()
	select {
	case <-done:
	case <-timer.C:
		stdlog.Println("[Warning] sing-box close takes longer than expected")
		if !block {
			return nil
		}
		<-done
	}
	stdlog.Printf("[Info] sing-box closed in %d ms", time.Since(start).Milliseconds())
	return closeErr
}
