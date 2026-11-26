package mobile

// Xray-free compatibility shim for upstream Throne bdc8be00's new mobile/scan.go
// and mobile/warp.go. Upstream took these from mobile/xray.go, which the fork
// deletes with the Xray sidecar. Reimplement just the surface the new files use
// on top of PlatformInterface (VpnService.protect), with no Xray dependency.

import (
	"sync/atomic"
	"syscall"
)

// The last running Instance; upstream scan/warp use it to reach the live box.
var activeInstance atomic.Pointer[Instance]

var activePlatform atomic.Pointer[shimPlatform]

type shimPlatform struct {
	platform PlatformInterface
	enabled  bool
}

func installShimProtector(platform PlatformInterface) {
	if platform == nil {
		return
	}
	activePlatform.Store(&shimPlatform{
		platform: platform,
		enabled:  platform.UsePlatformAutoDetectInterfaceControl(),
	})
}

func releaseShimProtector(platform PlatformInterface) {
	if state := activePlatform.Load(); state != nil && state.platform == platform {
		activePlatform.CompareAndSwap(state, nil)
	}
}

// protectDial is control.Func (net.Dialer.Control) used by scan/warp dials.
func protectDial(_, _ string, conn syscall.RawConn) error {
	state := activePlatform.Load()
	if state == nil || !state.enabled {
		return nil
	}
	var protectErr error
	if err := conn.Control(func(fd uintptr) {
		protectErr = state.platform.AutoDetectInterfaceControl(int32(fd))
	}); err != nil {
		return err
	}
	return protectErr
}
