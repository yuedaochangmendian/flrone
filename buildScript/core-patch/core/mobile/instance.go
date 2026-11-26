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
var postLifecycleRelease struct {
	mu    sync.Mutex
	timer *time.Timer
}

// schedulePostLifecycleRelease arms a single deferred OS-memory release. It is
// non-blocking, and the callback checks the supplied guard so a release planned
// by a stopped box is skipped if a new one has already started.
func schedulePostLifecycleRelease(delay time.Duration, guard func() bool) {
	postLifecycleRelease.mu.Lock()
	defer postLifecycleRelease.mu.Unlock()
	if postLifecycleRelease.timer != nil {
		postLifecycleRelease.timer.Stop()
	}
	postLifecycleRelease.timer = time.AfterFunc(delay, func() {
		if guard() {
			gcMu.Lock()
			debug.FreeOSMemory()
			gcMu.Unlock()
		}
	})
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
	// FlClash's load boundary: collect the previous box's route/rule-set decode
	// buffers before the next config is parsed. A fresh collection here makes
	// the peak of the new build lower than reusing the old heap's slack.
	runtime.GC()
	if sDebug {
		stdlog.Println("Start:", options.CoreConfig)
	}

	installShimProtector(platform)
	ctx := newBoxContext(platform, newPlatformInterfaceWrapper(platform))
	boxOptions, err := parseConfig(ctx, options.CoreConfig)
	if err != nil {
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
	// heap to the OS. Skip entirely if a new instance is already up, and never
	// block Close on the collection itself.
	if runningInstances.Load() == 0 {
		schedulePostLifecycleRelease(postCloseReleaseDelay, func() bool {
			return runningInstances.Load() == 0
		})
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
