// The auto-selector member-check verdict cache.
//
// SettingsMapper.CoreMemberCheck opens a throwaway box for every member on
// every config build. A build re-checks the same member object several times
// (the member scan, its single-hop build and the chain build), and restarting
// the app rebuilds the same config from the same documents. CheckConfig is a
// deterministic function of the exact object it is handed, so the verdict can
// be memoised. The cache is process-wide like the log pump: one action bus,
// many callers, no user of the cache owns its lifetime.
//
// Two boundaries matter:
//   - the key is the *exact canonical JSON payload* (outbound/endpoint object
//     plus the log level), never a profile id or a decoded object that could
//     alias a caller's map;
//   - the cache is bounded. On overflow it is cleared rather than grown, so a
//     user who cycles through thousands of profiles cannot pin the kernel's
//     memory. Clearing only costs a handful of repeated checks.
//
// Empty objects and blank payloads are never cached: those are the paths where
// a missing config makes CheckConfig report a transient-looking error.
package mobile

import (
	"strings"
	"sync"
)

// configMemberVerdictCacheCap is the number of distinct member payloads kept
// before the whole cache is dropped. A single auto-selector build has at most
// configSelectorMaxBuildLimit (500) members, so a large multiple of one build
// covers successive builds without letting the map grow without bound.
const configMemberVerdictCacheCap = 512

type configMemberVerdictCache struct {
	mu      sync.RWMutex
	entries map[string]string
	cap     int
}

func newConfigMemberVerdictCache(capacity int) *configMemberVerdictCache {
	if capacity < 1 {
		capacity = 1
	}
	return &configMemberVerdictCache{
		entries: make(map[string]string, capacity),
		cap:     capacity,
	}
}

func (cache *configMemberVerdictCache) lookup(payload string) (string, bool) {
	cache.mu.RLock()
	verdict, ok := cache.entries[payload]
	cache.mu.RUnlock()
	return verdict, ok
}

func (cache *configMemberVerdictCache) store(payload, verdict string) {
	cache.mu.Lock()
	if len(cache.entries) >= cache.cap {
		// Clear-on-overflow: cheap, bounded, and never evicts a single entry in
		// the middle of a build's repeated checks of the same object.
		cache.entries = make(map[string]string, cache.cap)
	}
	cache.entries[payload] = verdict
	cache.mu.Unlock()
}

func (cache *configMemberVerdictCache) clear() {
	cache.mu.Lock()
	cache.entries = make(map[string]string, cache.cap)
	cache.mu.Unlock()
}

// configMemberVerdicts is the process-wide memo. Tests that need a clean
// slate use a private cache through configCoreMemberCheckWith.
var configMemberVerdicts = newConfigMemberVerdictCache(configMemberVerdictCacheCap)

// configCheckConfig is CheckConfig's shape; the seam keeps the cache testable
// without opening a box on every case.
type configCheckConfig func(coreConfig string) error

// configCoreMemberCheckWith is configCoreMemberCheck with an explicit cache and
// check function. See configCoreMemberCheck for the wire semantics.
func configCoreMemberCheckWith(
	cache *configMemberVerdictCache, check configCheckConfig,
	id int64, outbound configOutbound, object map[string]any,
) string {
	// A missing object is the golden harness / pre-build path: no core verdict
	// exists, and no result may be cached for a blank config.
	if object == nil {
		return ""
	}
	if id <= 0 {
		return "invalid profile id"
	}
	key := "outbounds"
	if configOutboundIsEndpoint(outbound) {
		key = "endpoints"
	}
	payload := map[string]any{
		key: []any{object},
		"log": map[string]any{
			"level": "warn",
		},
	}
	encoded, err := MarshalCanonicalJSON(payload)
	if err != nil {
		return err.Error()
	}
	payloadKey := string(encoded)
	if strings.TrimSpace(payloadKey) == "" {
		return ""
	}
	if verdict, ok := cache.lookup(payloadKey); ok {
		return verdict
	}
	verdict := ""
	if err := check(payloadKey); err != nil {
		verdict = err.Error()
	}
	cache.store(payloadKey, verdict)
	return verdict
}
