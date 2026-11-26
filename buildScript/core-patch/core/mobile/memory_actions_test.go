// Compile-time/wire-shape tests for the memory/GC/log-stream actions. These run
// without a box: runtime.ReadMemStats is runtime-wide and the log filter is pure.
package mobile

import (
	"encoding/json"
	"reflect"
	"testing"
)

func memoryRaw(t *testing.T, payload string) json.RawMessage {
	t.Helper()
	return json.RawMessage(payload)
}

func TestMemoryActionMethodsAreRegistered(t *testing.T) {
	for _, method := range []Method{runtimeMemoryMethod, forceGCMethod, setLogStreamMethod} {
		if _, ok := actionHandlers[method]; !ok {
			t.Errorf("method %q is not registered", method)
		}
	}
}

func TestForceGCTwoLevelPayloads(t *testing.T) {
	// A missing payload keeps the historical full trim; an explicit `full:false`
	// must take the light path. The handlers cannot observe which branch ran
	// without instrumenting the runtime, so this pins the accepted shapes and
	// rejection (a malformed payload must not silently perform a collection).
	for _, raw := range []string{``, `null`, `{}`, `{"full":true}`, `{"full":false}`} {
		result, err := handleForceGC(memoryRaw(t, raw))
		if err != nil || result != true {
			t.Fatalf("payload %q: result = %v, err = %v", raw, result, err)
		}
	}
	for _, raw := range []string{`{`, `{"full":"yes"}`} {
		if _, err := handleForceGC(memoryRaw(t, raw)); err == nil {
			t.Errorf("expected an error for %q", raw)
		}
	}
}

func TestRuntimeMemoryKeysAndTypes(t *testing.T) {
	result, err := handleRuntimeMemory(nil)
	if err != nil {
		t.Fatalf("handleRuntimeMemory: %v", err)
	}
	values, ok := result.(map[string]any)
	if !ok {
		t.Fatalf("result type = %T, want map[string]any", result)
	}

	want := []string{
		"rss", "heapAlloc", "heapSys", "heapInuse", "heapIdle", "stackInuse",
		"runtimeOther", "numGC", "goroutines",
	}
	if len(values) != len(want) {
		t.Fatalf("result has %d keys (%v), want exactly %v", len(values), reflect.ValueOf(values).MapKeys(), want)
	}
	for _, key := range want {
		switch values[key].(type) {
		case uint64, uint32, int, int64:
			// JSON numbers; the Dart decoder accepts any num.
		default:
			t.Errorf("%s type = %T, want a numeric type", key, values[key])
		}
	}
	// The runtime must look alive: a zero goroutine count would mean the numbers
	// were never read from the live process.
	if goroutines, ok := values["goroutines"].(int); !ok || goroutines < 1 {
		t.Fatalf("goroutines = %v (%T), want int >= 1", values["goroutines"], values["goroutines"])
	}
	// The wire schema uses the Go field names, not FlClash's hyphenated ones.
	encoded, err := json.Marshal(values)
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]json.RawMessage
	if err := json.Unmarshal(encoded, &wire); err != nil {
		t.Fatal(err)
	}
	for _, key := range want {
		if _, ok := wire[key]; !ok {
			t.Errorf("wire is missing key %q", key)
		}
	}
	for _, key := range []string{"heap-idle", "runtime-other", "stack-inuse"} {
		if _, ok := wire[key]; ok {
			t.Errorf("wire unexpectedly has hyphenated key %q", key)
		}
	}
}

func TestRuntimeMemoryWorksWithoutInstance(t *testing.T) {
	if _, err := handleRuntimeMemory(memoryRaw(t, `{}`)); err != nil {
		t.Fatalf("runtimeMemory must not need a running box, got: %v", err)
	}
}

func TestHandleSetLogStreamToggle(t *testing.T) {
	previous := verboseLogStream.Load()
	t.Cleanup(func() { verboseLogStream.Store(previous) })

	for _, enabled := range []bool{true, false, true} {
		payload, err := json.Marshal(map[string]bool{"enabled": enabled})
		if err != nil {
			t.Fatal(err)
		}
		result, err := handleSetLogStream(memoryRaw(t, string(payload)))
		if err != nil || result != true {
			t.Fatalf("enabled=%v: result = %v, err = %v", enabled, result, err)
		}
		if got := verboseLogStream.Load(); got != enabled {
			t.Fatalf("verboseLogStream = %v, want %v", got, enabled)
		}
	}
}

func TestHandleSetLogStreamRejectsBadInput(t *testing.T) {
	previous := verboseLogStream.Load()
	t.Cleanup(func() { verboseLogStream.Store(previous) })
	verboseLogStream.Store(false)
	for _, raw := range []string{``, `null`, `{`, `{}`, `{"enabled":"yes"}`} {
		if _, err := handleSetLogStream(memoryRaw(t, raw)); err == nil {
			t.Errorf("expected an error for %q", raw)
		}
	}
	if verboseLogStream.Load() {
		t.Fatal("a malformed request must not change the log-stream flag")
	}
}

func TestFilterLogEntriesWarnKeptInfoDropped(t *testing.T) {
	entries := []logEntry{
		{level: LogLevelPanic, message: "panic"},
		{level: LogLevelFatal, message: "fatal"},
		{level: LogLevelError, message: "error"},
		{level: LogLevelWarn, message: "warn"},
		{level: LogLevelInfo, message: "info"},
		{level: LogLevelDebug, message: "debug"},
		{level: LogLevelTrace, message: "trace"},
	}
	filtered := filterLogEntries(entries)
	got := make([]string, 0, len(filtered))
	for _, entry := range filtered {
		got = append(got, entry.message)
	}
	if want := []string{"panic", "fatal", "error", "warn"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("filtered = %v, want %v", got, want)
	}

	// The pump reuses its backing array on the next drain; filtering must not
	// alias it, or a later overwrite would silently change the buffered frame.
	entries[0].message = "overwritten"
	if filtered[0].message != "panic" {
		t.Fatal("filterLogEntries aliased the pump's slice")
	}
}

func captureLogFrames(t *testing.T) *[]logEntry {
	t.Helper()
	previous := emitLogFrame
	var captured []logEntry
	emitLogFrame = func(entries []logEntry) {
		captured = append(captured, entries...)
	}
	t.Cleanup(func() { emitLogFrame = previous })
	return &captured
}

func TestPortLogSinkGating(t *testing.T) {
	previous := verboseLogStream.Load()
	t.Cleanup(func() { verboseLogStream.Store(previous) })
	captured := captureLogFrames(t)
	sink := portLogSink{}
	batch := []logEntry{
		{level: LogLevelWarn, message: "warn"},
		{level: LogLevelError, message: "error"},
		{level: LogLevelInfo, message: "info"},
		{level: LogLevelDebug, message: "debug"},
	}

	// Default off: only warn/error survive, both in Write and WriteBatch.
	verboseLogStream.Store(false)
	sink.Write(LogLevelInfo, "info-dropped")
	sink.Write(LogLevelError, "error-kept")
	sink.WriteBatch(batch)
	got := make([]string, 0, len(*captured))
	for _, entry := range *captured {
		got = append(got, entry.message)
	}
	if want := []string{"error-kept", "warn", "error"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("gated frames = %v, want %v", got, want)
	}

	// Filtering must not corrupt the pump's backing slice.
	if batch[0].message != "warn" {
		t.Fatal("WriteBatch modified the pump's slice")
	}

	// Verbose on: all four lines stream, and the flag is unchanged by a write.
	*captured = nil
	if _, err := handleSetLogStream(memoryRaw(t, `{"enabled":true}`)); err != nil {
		t.Fatal(err)
	}
	sink.WriteBatch(batch)
	if len(*captured) != 4 {
		t.Fatalf("verbose frames = %d, want 4", len(*captured))
	}
	if !verboseLogStream.Load() {
		t.Fatal("WriteBatch must not clear the streaming flag")
	}
}
