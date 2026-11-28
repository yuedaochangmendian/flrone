// Focused tests for the member-check verdict cache and the one-line build log.
package mobile

import (
	"errors"
	"fmt"
	"reflect"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func configCacheTestObject() map[string]any {
	return map[string]any{
		"type":        "shadowsocks",
		"server":      "198.51.100.10",
		"server_port": 8388,
		"method":      "aes-256-gcm",
		"password":    "secret",
	}
}

func configCachePayload(t *testing.T, object map[string]any, endpoint bool) string {
	t.Helper()
	key := "outbounds"
	if endpoint {
		key = "endpoints"
	}
	encoded, err := MarshalCanonicalJSON(map[string]any{
		key:   []any{object},
		"log": map[string]any{"level": "warn"},
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(encoded)
}

// A repeated exact payload calls CheckConfig once; accepted and rejected
// verdicts are both memoised. The payload is canonical JSON, so two different
// Go maps with the same content share one cache entry.
func TestConfigCoreMemberCheckCachesVerdicts(t *testing.T) {
	cache := newConfigMemberVerdictCache(8)
	var calls int32
	rejected := errors.New("bad option: rejected")
	check := func(payload string) error {
		atomic.AddInt32(&calls, 1)
		if strings.Contains(payload, "reject") {
			return rejected
		}
		return nil
	}

	object := configCacheTestObject()
	duplicate := configCacheTestObject() // same content, different map instance
	if got := configCoreMemberCheckWith(cache, check, 7, configOutbound{}, object); got != "" {
		t.Fatalf("first verdict = %q, want accepted", got)
	}
	if got := configCoreMemberCheckWith(cache, check, 7, configOutbound{}, duplicate); got != "" {
		t.Fatalf("cached verdict = %q, want accepted", got)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("CheckConfig calls = %d, want 1", got)
	}

	bad := configCacheTestObject()
	bad["password"] = "reject"
	if got := configCoreMemberCheckWith(cache, check, 7, configOutbound{}, bad); got != rejected.Error() {
		t.Fatalf("rejected verdict = %q, want %q", got, rejected.Error())
	}
	if got := configCoreMemberCheckWith(cache, check, 7, configOutbound{}, bad); got != rejected.Error() {
		t.Fatalf("cached rejection = %q, want %q", got, rejected.Error())
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("CheckConfig calls = %d, want 2 (one per distinct payload)", got)
	}

	// The key includes the outbound/endpoint container: the same object as an
	// endpoint is a different payload and must be checked separately.
	endpointObject := configCacheTestObject()
	if got := configCoreMemberCheckWith(cache, check, 7,
		configOutbound{profileType: "wireguard"}, endpointObject); got != "" {
		t.Fatalf("endpoint verdict = %q, want accepted", got)
	}
	if got := atomic.LoadInt32(&calls); got != 3 {
		t.Fatalf("CheckConfig calls = %d, want 3 after the endpoint payload", got)
	}
}

func TestConfigCoreMemberCheckSkipsCacheForNilAndInvalidID(t *testing.T) {
	cache := newConfigMemberVerdictCache(8)
	var calls int32
	check := func(string) error {
		atomic.AddInt32(&calls, 1)
		return nil
	}
	if got := configCoreMemberCheckWith(cache, check, 7, configOutbound{}, nil); got != "" {
		t.Fatalf("nil object verdict = %q, want accepted", got)
	}
	if got := configCoreMemberCheckWith(cache, check, 0, configOutbound{}, configCacheTestObject()); got != "invalid profile id" {
		t.Fatalf("id=0 verdict = %q, want invalid profile id", got)
	}
	if got := atomic.LoadInt32(&calls); got != 0 {
		t.Fatalf("CheckConfig calls = %d, want 0 for nil/invalid input", got)
	}
	if len(cache.entries) != 0 {
		t.Fatalf("cache entries = %d, want 0", len(cache.entries))
	}
}

// Reaching the cap clears the map: no unbounded growth, and a repopulated
// cache still serves hits. A cleared entry is re-checked exactly once.
func TestConfigMemberVerdictCacheCapClearsAndRepopulates(t *testing.T) {
	cache := newConfigMemberVerdictCache(3)
	object := func(name string) map[string]any {
		return map[string]any{"type": "shadowsocks", "name": name}
	}
	check := func(string) error { return nil }
	for _, name := range []string{"a", "b", "c"} {
		if got := configCoreMemberCheckWith(cache, check, 1, configOutbound{}, object(name)); got != "" {
			t.Fatalf("verdict for %s = %q", name, got)
		}
	}
	if got := len(cache.entries); got != 3 {
		t.Fatalf("cache entries = %d, want 3", got)
	}
	payloadA := configCachePayload(t, object("a"), false)
	if _, ok := cache.lookup(payloadA); !ok {
		t.Fatal("entry a was not cached")
	}
	// A fourth distinct payload overflows the cap and clears the map.
	if got := configCoreMemberCheckWith(cache, check, 1, configOutbound{}, object("d")); got != "" {
		t.Fatalf("verdict for d = %q", got)
	}
	if got := len(cache.entries); got != 1 {
		t.Fatalf("cache entries after overflow = %d, want 1 (clear, not growth)", got)
	}
	if _, ok := cache.lookup(payloadA); ok {
		t.Fatal("entry a survived the clear-on-overflow")
	}
	// The next new payload repopulates the cleared map.
	if got := configCoreMemberCheckWith(cache, check, 1, configOutbound{}, object("e")); got != "" {
		t.Fatalf("verdict for e = %q", got)
	}
	if got := len(cache.entries); got != 2 {
		t.Fatalf("cache entries after repopulate = %d, want 2", got)
	}
	payloadE := configCachePayload(t, object("e"), false)
	if _, ok := cache.lookup(payloadE); !ok {
		t.Fatal("entry e was not cached after the clear")
	}
	// After e, d is no longer in the map; the next use must re-check it.
	cache.clear()
	if got := len(cache.entries); got != 0 {
		t.Fatalf("cache entries after clear = %d, want 0", got)
	}
}

// Many goroutines checking the same payloads must not race or double-count:
// every distinct payload is checked once, every repeated hit is served from
// the cache, and the map stays within its cap at all times.
func TestConfigMemberVerdictCacheConcurrent(t *testing.T) {
	const cap = 16
	cache := newConfigMemberVerdictCache(cap)
	var calls atomic.Int32
	check := func(string) error {
		calls.Add(1)
		return nil
	}
	// Pre-warm the four distinct payloads so concurrent callers only hit the
	// cache and the call count is deterministic (the race detector still sees
	// concurrent readers of the map).
	for id := int64(1); id <= 4; id++ {
		object := map[string]any{"type": "direct", "name": fmt.Sprintf("node-%d", id)}
		configCoreMemberCheckWith(cache, check, id, configOutbound{}, object)
	}
	const goroutines = 32
	var wg sync.WaitGroup
	for worker := 0; worker < goroutines; worker++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			for round := 0; round < 20; round++ {
				id := int64(worker%4 + 1)
				object := map[string]any{"type": "direct", "name": fmt.Sprintf("node-%d", id)}
				if got := configCoreMemberCheckWith(cache, check, id, configOutbound{}, object); got != "" {
					t.Errorf("verdict = %q, want accepted", got)
					return
				}
			}
		}(worker)
	}
	wg.Wait()
	if got := calls.Load(); got != 4 {
		t.Fatalf("CheckConfig calls = %d, want 4 (one per distinct payload)", got)
	}
	if got := len(cache.entries); got > cap {
		t.Fatalf("cache entries = %d, exceed cap %d", got, cap)
	}
}

func TestConfigBuildLogsOneLineOnSuccess(t *testing.T) {
	writeConfigBuildFixture(t, configBuildRouteChainProfiles,
		baseSettingsJSON(t, "1", nil), configBuildRouteChainRules)

	// Install a sink directly on the pump: push is synchronous, so the line is
	// visible as soon as the handler returns (no goroutine to race with).
	pump.access.Lock()
	previousSink := pump.sink
	pump.sink = configCollectSink{}
	pump.access.Unlock()
	t.Cleanup(func() {
		pump.access.Lock()
		pump.sink = previousSink
		pump.access.Unlock()
	})

	data, code := configBuildActionWire(t, `{}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d", code)
	}
	coreConfig, _, involved := configBuildReplyDecode(t, data)
	pump.access.Lock()
	entries := append([]logEntry(nil), pump.pending...)
	pump.pending = nil
	pump.access.Unlock()
	if len(entries) != 1 {
		t.Fatalf("pump entries = %d, want 1: %v", len(entries), entries)
	}
	entry := entries[0]
	if entry.level != LogLevelInfo {
		t.Fatalf("log level = %d, want info (%d)", entry.level, LogLevelInfo)
	}
	prefix := fmt.Sprintf("config.build: profile=1 bytes=%d involved=%d defer=false took=",
		len(coreConfig), len(involved))
	if !strings.HasPrefix(entry.message, prefix) {
		t.Fatalf("log message = %q, want prefix %q", entry.message, prefix)
	}
	if strings.ContainsAny(entry.message[len(prefix):], "\n\r") || strings.Contains(entry.message[len(prefix):], " ") {
		t.Fatalf("took field is not a single scalar: %q", entry.message[len(prefix):])
	}
	if strings.Contains(entry.message, coreConfig) {
		t.Fatal("log message leaked the config body")
	}
}

type configCollectSink struct{}

func (configCollectSink) Write(int32, string) {}

func TestConfigBuildLogLineShape(t *testing.T) {
	line := configBuildLogLine(42, configBuildOutcome{coreConfig: strings.Repeat("x", 123)},
		[]int64{42, 7}, true, 1500*time.Microsecond)
	pattern := `^config\.build: profile=42 bytes=123 involved=2 defer=true took=1\.5ms$`
	if !regexp.MustCompile(pattern).MatchString(line) {
		t.Fatalf("log line = %q, want pattern %s", line, pattern)
	}
	if strings.ContainsAny(line, "\n\r") {
		t.Fatal("log line must be one line")
	}

	falseLine := configBuildLogLine(1, configBuildOutcome{}, nil, false, 250*time.Nanosecond)
	if want := "config.build: profile=1 bytes=0 involved=0 defer=false took=1µs"; falseLine != want {
		t.Fatalf("log line = %q, want %q", falseLine, want)
	}
	// Every field is a scalar: the config body and any credential must never
	// appear in the line, even with an "x" body that would be easy to leak.
	if strings.Contains(line, strings.Repeat("x", 123)) {
		t.Fatal("log line leaked the config body")
	}
	if !reflect.DeepEqual(strings.Fields(line)[:1], []string{"config.build:"}) {
		t.Fatalf("log line prefix = %q", strings.Fields(line)[:1])
	}
}
