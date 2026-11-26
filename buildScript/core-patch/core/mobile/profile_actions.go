// Debug-gated pprof capture on the JSON action bus (Phase 0/2).
//
// A profile is only useful when a developer can reproduce a problem on a device, so
// this action is deliberately inert in normal use: it refuses to run unless a marker
// file exists in the target directory. Enabling it is an explicit, local, adb-only step:
//
//	adb shell run-as com.throneflclash touch files/profile.enable
//
// and the caller passes that same app-private files directory as `dir`. The marker
// consumes no runtime resource and cannot be created by a remote config or a profile
// import — only somebody with shell access to the app's own sandbox.
//
// Wire payload:
//
//	{"kind":"cpu|heap|goroutine|allocs|block","seconds":N,"dir":"/data/user/0/com.throneflclash/files"}
//
// CPU is the only kind that spends time: it samples for `seconds` (clamped to 5..60),
// the other kinds are instantaneous snapshots of the runtime's current state. The
// handler runs on dispatchAction's goroutine, so a 60 s CPU capture never blocks the
// Dart message-port callback; a second concurrent call is rejected immediately
// (single-flight) instead of queueing behind it.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"sync/atomic"
	"time"
)

// The Method constant lives in its own block: action_contract.py treats any
// string constant that inherits a typed `Method` line as a request method, so
// mixing the marker filename in here would create a phantom "profile.enable" action.
const diagnosticsProfileMethod Method = "diagnosticsProfile"

const (
	profileMarkerFile = "profile.enable"

	profileMinSeconds     = 5
	profileMaxSeconds     = 60
	profileDefaultSeconds = 30
)

// profileKinds is the complete set of accepted `kind` values. "mutex" and
// "threadcreate" are intentionally absent: neither is useful for the UI hangs this
// debug hook was added to diagnose, and every extra kind is another profiling knob
// to keep safe.
var profileKinds = map[string]bool{
	"cpu":       true,
	"heap":      true,
	"goroutine": true,
	"allocs":    true,
	"block":     true,
}

// profileInFlight is the single-flight guard. CompareAndSwap makes a second call
// return an error at once; using a plain Mutex here would park the second action
// handler (and its reply) for the whole CPU window.
var profileInFlight atomic.Bool

func beginProfile() bool { return profileInFlight.CompareAndSwap(false, true) }
func endProfile()        { profileInFlight.Store(false) }

type profileRequest struct {
	Kind    string `json:"kind"`
	Seconds int    `json:"seconds"`
	Dir     string `json:"dir"`
}

// parseProfileRequest validates and normalises the wire payload. It performs no I/O
// except path arithmetic, so the tests can pin every rejection branch without
// producing a profile.
func parseProfileRequest(raw json.RawMessage) (profileRequest, error) {
	var request profileRequest
	if len(raw) == 0 || string(raw) == "null" {
		return request, errors.New("diagnostics.profile: missing payload")
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return request, fmt.Errorf("diagnostics.profile: parse payload: %w", err)
	}
	if !profileKinds[request.Kind] {
		return request, fmt.Errorf("diagnostics.profile: invalid kind %q (want cpu, heap, goroutine, allocs or block)", request.Kind)
	}
	if request.Seconds == 0 {
		request.Seconds = profileDefaultSeconds
	}
	if request.Seconds < profileMinSeconds {
		request.Seconds = profileMinSeconds
	} else if request.Seconds > profileMaxSeconds {
		request.Seconds = profileMaxSeconds
	}
	if request.Dir == "" {
		return request, errors.New("diagnostics.profile: dir is empty")
	}
	if !filepath.IsAbs(request.Dir) {
		return request, fmt.Errorf("diagnostics.profile: dir must be an absolute path, got %q", request.Dir)
	}
	// The base path is the app's private files directory, set by Setup from Android's
	// filesDir. When it is known, a caller must not be able to steer pprof output
	// anywhere else: a profile can contain file paths, stack traces and fragments of
	// user data, so writing one into a world-readable directory would be a leak.
	//
	// Trust assumption: when the base path is empty (a bare Go host, or a caller that has
	// not run Setup yet), the kernel cannot determine the app dir. In that case the
	// caller-supplied absolute dir is trusted — this action is already gated by the
	// on-device marker file, and the host has no other way to know the sandbox root.
	if basePath, _, _ := setupPaths(); basePath != "" {
		base, err := filepath.Abs(basePath)
		if err != nil {
			return request, fmt.Errorf("diagnostics.profile: resolve base path: %w", err)
		}
		dir, err := filepath.Abs(request.Dir)
		if err != nil {
			return request, fmt.Errorf("diagnostics.profile: resolve dir: %w", err)
		}
		rel, err := filepath.Rel(base, dir)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return request, fmt.Errorf("diagnostics.profile: dir %q is outside the app files directory", request.Dir)
		}
	}
	return request, nil
}

// checkProfileGate enforces the adb-only opt-in. The marker must live in the same
// directory the profiles are written to, so `run-as … touch files/profile.enable`
// plus `dir=files` is the whole enablement ceremony.
func checkProfileGate(dir string) error {
	path := filepath.Join(dir, profileMarkerFile)
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf(
			"diagnostics.profile: disabled (create %s to enable: adb shell run-as com.throneflclash touch files/%s)",
			path, profileMarkerFile,
		)
	}
	if err != nil {
		return fmt.Errorf("diagnostics.profile: stat %s: %w", path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("diagnostics.profile: %s is a directory, not a marker file", path)
	}
	return nil
}

// handleDiagnosticsProfile captures one profile. Errors are returned to the action
// result; no panic escapes (dispatchAction also fences, but this handler never needs
// to rely on it).
func handleDiagnosticsProfile(raw json.RawMessage) (any, error) {
	request, err := parseProfileRequest(raw)
	if err != nil {
		return nil, err
	}
	if err := checkProfileGate(request.Dir); err != nil {
		return nil, err
	}
	if !beginProfile() {
		return nil, errors.New("diagnostics.profile: another profile is already running")
	}
	defer endProfile()

	if err := os.MkdirAll(request.Dir, 0o700); err != nil {
		return nil, fmt.Errorf("diagnostics.profile: create %s: %w", request.Dir, err)
	}

	path := filepath.Join(request.Dir, request.Kind+"-"+strconv.FormatInt(time.Now().Unix(), 10)+".pprof")
	file, err := os.Create(path)
	if err != nil {
		return nil, fmt.Errorf("diagnostics.profile: create %s: %w", path, err)
	}

	// Snapshots: a heap capture reports live allocations after a GC, allocs reports
	// cumulative allocations, goroutine dumps every stack. Block sampling needs a
	// non-zero rate to have anything to report. runtime.SetBlockProfileRate has no
	// getter, so the rate stays at 1 for the rest of this process — acceptable for a
	// debug action that only runs after an explicit on-device marker is created.
	switch request.Kind {
	case "cpu":
		if err := pprof.StartCPUProfile(file); err != nil {
			file.Close()
			return nil, fmt.Errorf("diagnostics.profile: start CPU profile: %w", err)
		}
		time.Sleep(time.Duration(request.Seconds) * time.Second)
		pprof.StopCPUProfile()
	case "heap":
		runtime.GC()
		err = pprof.WriteHeapProfile(file)
	case "allocs":
		err = pprof.Lookup("allocs").WriteTo(file, 0)
	case "goroutine":
		err = pprof.Lookup("goroutine").WriteTo(file, 0)
	case "block":
		runtime.SetBlockProfileRate(1)
		err = pprof.Lookup("block").WriteTo(file, 0)
	}
	closeErr := file.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return nil, fmt.Errorf("diagnostics.profile: write %s: %w", path, err)
	}

	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("diagnostics.profile: stat %s: %w", path, err)
	}
	return map[string]any{
		"files":   []string{path},
		"kind":    request.Kind,
		"seconds": request.Seconds, // echoed even for snapshots, for a uniform reply
		"bytes":   info.Size(),
	}, nil
}
