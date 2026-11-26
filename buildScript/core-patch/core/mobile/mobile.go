// Package mobile is the gomobile-bound surface of ThroneCore for Android. It owns the sing-box
// instance (the fork's root box.New over a context this package builds), mirroring internal/rpc
// and internal/boxmain without their IPC, signal and desktop-only wiring; none of those packages
// may be imported here.
package mobile

import (
	"os"
	"runtime"
	"sync"

	C "github.com/sagernet/sing-box/constant"
	E "github.com/sagernet/sing/common/exceptions"

	// Pins the gomobile bind runtime in go.mod the same way the sing-box fork does.
	_ "github.com/sagernet/gomobile"
)

type SetupOptions struct {
	BasePath    string
	WorkingPath string
	TempPath    string
	LogMaxLines int32
	Debug       bool
}

// The setup globals are written once by Setup (possibly from a different
// goroutine than the action handlers) and read from many handlers. They are
// guarded by setupMu so no handler can observe a half-updated path pair — e.g.
// a new sBasePath with the previous sWorkingPath/sTempPath. All readers go
// through the accessors below; direct field reads are reserved for tests that
// intentionally install a temporary value under t.Cleanup (single-threaded).
var setupMu sync.RWMutex

var (
	sBasePath    string
	sWorkingPath string
	sTempPath    string
	sDebug       bool
)

// setupPaths returns the path trio as one consistent snapshot.
func setupPaths() (base, working, temp string) {
	setupMu.RLock()
	defer setupMu.RUnlock()
	return sBasePath, sWorkingPath, sTempPath
}

// setupDebug reports the debug flag read under the same lock as Setup.
func setupDebug() bool {
	setupMu.RLock()
	defer setupMu.RUnlock()
	return sDebug
}

func Setup(options *SetupOptions) error {
	if options == nil {
		return E.New("nil setup options")
	}
	// Create the directories before publishing the paths: a handler reading the
	// snapshot must never see a path that Setup has not prepared yet.
	for _, dir := range []string{options.BasePath, options.WorkingPath, options.TempPath} {
		if dir == "" {
			continue
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return E.Cause(err, "create ", dir)
		}
	}
	setupMu.Lock()
	sBasePath = options.BasePath
	sWorkingPath = options.WorkingPath
	sTempPath = options.TempPath
	sDebug = options.Debug
	setupMu.Unlock()
	pump.setLimit(int(options.LogMaxLines))
	return nil
}

func Version() string {
	return C.Version
}

func GoVersion() string {
	return runtime.Version() + ", " + runtime.GOOS + "/" + runtime.GOARCH
}
