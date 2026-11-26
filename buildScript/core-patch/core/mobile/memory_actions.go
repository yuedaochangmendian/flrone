// Memory/GC/log-stream actions on the Bettbox-style JSON bus (mirrors FlClash).
//
// The kernel owns its own Go heap, so the host can only ask it for numbers and
// for a collection — it cannot read runtime.MemStats across the FFI boundary.
// These three handlers expose exactly that on the existing action bus; no new
// typed C export is needed (see action.go). The Dart side enables verbose
// streaming only when its log panel is open (setLogStream), so the default
// off state keeps the high-frequency info/debug lines off the message port.
//
// Wire shapes (the Dart ActionMethod member IS the wire name):
//
//	runtimeMemory {}                     -> {"rss":N,"heapAlloc":N,"heapSys":N,
//	                                        "heapInuse":N,"heapIdle":N,"stackInuse":N,
//	                                        "runtimeOther":N,"numGC":N,"goroutines":N}
//	forceGC       {}                     -> true
//	setLogStream  {"enabled":true|false} -> true
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"runtime"
	"runtime/debug"
	"sync"

	"github.com/sagernet/sing/common/memory"
)

const (
	runtimeMemoryMethod Method = "runtimeMemory"
	forceGCMethod       Method = "forceGC"
	setLogStreamMethod  Method = "setLogStream"
)

func init() {
	register(runtimeMemoryMethod, handleRuntimeMemory)
	register(forceGCMethod, handleForceGC)
	register(setLogStreamMethod, handleSetLogStream)
}

// handleRuntimeMemory reports the Go heap from inside the kernel. It needs no
// running instance: readMemStats is a runtime-wide read and rss comes from the
// platform's own RSS probe.
func handleRuntimeMemory(_ json.RawMessage) (any, error) {
	var stats runtime.MemStats
	runtime.ReadMemStats(&stats)
	// HeapIdle counts spans the runtime has already handed back to the OS, so
	// retained-but-unused is idle minus released; clamp against uint64 underflow.
	heapIdle := uint64(0)
	if stats.HeapIdle > stats.HeapReleased {
		heapIdle = stats.HeapIdle - stats.HeapReleased
	}
	return map[string]any{
		"rss":          memory.Total(),
		"heapAlloc":    stats.HeapAlloc,
		"heapSys":      stats.HeapSys,
		"heapInuse":    stats.HeapInuse,
		"heapIdle":     heapIdle,
		"stackInuse":   stats.StackInuse,
		"runtimeOther": stats.MSpanInuse + stats.MCacheInuse + stats.BuckHashSys + stats.GCSys + stats.OtherSys,
		"numGC":        uint64(stats.NumGC),
		"goroutines":   runtime.NumGoroutine(),
	}, nil
}

// gcMu serializes forced collections with the lifecycle's deferred releases in
// instance.go. Two overlapping FreeOSMemory calls are wasteful and can hide
// each other's effect on the memory readings the UI just requested.
var gcMu sync.Mutex

func handleForceGC(_ json.RawMessage) (any, error) {
	gcMu.Lock()
	defer gcMu.Unlock()
	runtime.GC()
	debug.FreeOSMemory()
	return true, nil
}

func handleSetLogStream(raw json.RawMessage) (any, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, errors.New("setLogStream: missing payload")
	}
	var request struct {
		Enabled *bool `json:"enabled"`
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return nil, fmt.Errorf("setLogStream: parse payload: %w", err)
	}
	if request.Enabled == nil {
		return nil, errors.New("setLogStream: enabled is required")
	}
	verboseLogStream.Store(*request.Enabled)
	return true, nil
}
