// Focused tests for the Stage-5 auto-selector plan: the lenient selector /
// member parsing, Normalize(), the filters, and the parts of the ranking the
// golden fixtures exercise only through whole-config bytes.
package mobile

import (
	"reflect"
	"testing"
)

func selectorTestProfile(id int64, typeName, name string, gid, order int64, jsonText string) simpleConfigProfile {
	return simpleConfigProfile{ID: id, Type: typeName, Name: name, GroupID: gid, UserOrder: order, OutboundJSON: jsonText}
}

func selectorTestMember(typeName, jsonText string) *configSelectorMember {
	return configSelectorMemberFromProfile(selectorTestProfile(1, typeName, "member", 1, 0, jsonText))
}

func TestConfigSelectorParseLenientAndNormalize(t *testing.T) {
	// Every wrong-typed value takes the Kotlin member default, gids drops
	// negative / repeated / non-numeric entries, and Normalize clamps the rest.
	profile := selectorTestProfile(1, "autoselector", "selector", 0, 0, `{
		"gids": [7, 7, -1, "x", 8],
		"pool_cap": 0,
		"build_limit": 999,
		"result_validity_mins": -5,
		"interval_sec": 3,
		"bench_interval_sec": 1,
		"watch_interval_sec": 1,
		"active_size": 0,
		"expected": 0,
		"sampling": 99,
		"tolerance_ms": -1,
		"max_rtt_ms": -2,
		"dial_retries": 9,
		"balance_interval_sec": 1,
		"balance_mode": "round-robin",
		"exclude_unavailable": "yes"
	}`)
	selector, invalid := configParseSelectorProfile(profile)
	if invalid {
		t.Fatal("a well-formed selector row must parse")
	}
	if want := []int64{7, 8}; !reflect.DeepEqual(selector.gids, want) {
		t.Fatalf("gids = %v, want %v", selector.gids, want)
	}
	if selector.poolCap != 1 || selector.buildLimit != 1 {
		t.Fatalf("pool cap / build limit = %d / %d, want 1 / 1", selector.poolCap, selector.buildLimit)
	}
	if selector.resultValidityMins != 0 || selector.sampling != 60 || selector.toleranceMs != 0 || selector.maxRTTms != 0 {
		t.Fatalf("clamped values = %#v", selector)
	}
	if selector.intervalSec != 10 || selector.benchIntervalSec != 10 || selector.watchIntervalSec != 5 {
		t.Fatalf("interval clamps = %d / %d / %d", selector.intervalSec, selector.benchIntervalSec, selector.watchIntervalSec)
	}
	if selector.activeSize != 1 || selector.expected != 1 || selector.dialRetries != 5 {
		t.Fatalf("size / retry clamps = %d / %d / %d", selector.activeSize, selector.expected, selector.dialRetries)
	}
	if selector.balanceMode != "rotate" || selector.balanceIntervalSec != 5 {
		t.Fatalf("balance = %q / %d", selector.balanceMode, selector.balanceIntervalSec)
	}
	if !selector.excludeUnavailable {
		t.Fatal("a non-boolean exclude_unavailable must keep the default true")
	}
}

func TestConfigSelectorParseInvalidJSON(t *testing.T) {
	if _, invalid := configParseSelectorProfile(selectorTestProfile(1, "autoselector", "s", 0, 0, "{not json")); !invalid {
		t.Fatal("unparsable outbound_json must report the Kotlin invalid flag")
	}
	// An empty text leaves the defaults in place and is not invalid
	// (ProxyEntity.parseOutbound skips parseFromJson for an empty object).
	selector, invalid := configParseSelectorProfile(selectorTestProfile(1, "autoselector", "s", 0, 0, ""))
	if invalid {
		t.Fatal("an empty outbound_json must not be invalid")
	}
	if selector.poolCap != 1000 || selector.pinnedID != -1 || selector.balanceMode != "rotate" {
		t.Fatalf("defaults = %#v", selector)
	}
}

func TestConfigSelectorFilters(t *testing.T) {
	filters, err := configSelectorBuildFilters(configAutoSelector{
		nameFilter:    "(?i)node",
		countryFilter: " DE, !ru ,,de ",
	})
	if err != nil {
		t.Fatal(err)
	}
	if filters.name == nil || !filters.name.MatchString("Node Alpha") || filters.name.MatchString("Landing") {
		t.Fatal("the case-insensitive name filter must match a substring")
	}
	if !filters.countries["DE"] || len(filters.countries) != 1 {
		t.Fatalf("country includes = %v", filters.countries)
	}
	if !filters.excluded["RU"] {
		t.Fatalf("country excludes = %v", filters.excluded)
	}
	// An invalid pattern filters nothing, like the Kotlin PatternSyntaxException arm.
	invalid, err := configSelectorBuildFilters(configAutoSelector{nameFilter: "["})
	if err != nil || invalid.name != nil {
		t.Fatalf("an invalid regex must not filter or fail: %v", err)
	}
	// A pattern Java accepts and RE2 refuses would drop different members in the
	// two builders, so it is a hard failure instead of a silent pass.
	for _, pattern := range []string{`(?=node)`, `(?<!x)y`, `(a)\1`, `a++`} {
		if _, err := configSelectorBuildFilters(configAutoSelector{nameFilter: pattern}); err == nil {
			t.Fatalf("Java-only pattern %q was accepted", pattern)
		}
	}
}

func TestConfigSelectorEligibilityReasons(t *testing.T) {
	now := int64(1_800_000_000)
	selector := configSelectorDefaults()
	selector.normalize()
	filters, err := configSelectorBuildFilters(selector)
	if err != nil {
		t.Fatal(err)
	}

	tests := []struct {
		member *configSelectorMember
		skip   configSelectorSkip
		isSkip bool
	}{
		{selectorTestMember("shadowsocks", `{"type":"shadowsocks","tag":"OK","server":"198.51.100.1","server_port":8388,"method":"aes-256-gcm","password":"p"}`), 0, false},
		{selectorTestMember("chain", `{"type":"chain","name":"Chain","list":[]}`), configSelectorSkipMetaType, true},
		{selectorTestMember("autoselector", `{"type":"autoselector","name":"Sel","gids":[]}`), configSelectorSkipMetaType, true},
		{selectorTestMember("tailscale", `{"type":"tailscale","tag":"TS"}`), configSelectorSkipTailscale, true},
		{selectorTestMember("openvpn", `{"type":"openvpn","tag":"VPN"}`), configSelectorSkipManagementEndpoint, true},
		{selectorTestMember("extracore", `{"type":"extracore","tag":"EC"}`), configSelectorSkipExtraCore, true},
		{selectorTestMember("shadowsocks", "{broken"), configSelectorSkipMalformed, true},
		{selectorTestMember("futuretype", `{"type":"futuretype","tag":"X"}`), configSelectorSkipUnsupported, true},
		{selectorTestMember("custom", `{"type":"custom","name":"Full","subtype":"fullconfig","config":"{\"log\":{}}"}`), configSelectorSkipFullConfig, true},
		{selectorTestMember("custom", `{"type":"custom","name":"Empty","subtype":"outbound","config":"not json"}`), configSelectorSkipMalformed, true},
		{selectorTestMember("custom", `{"type":"custom","name":"Custom","subtype":"outbound","config":"{\"type\":\"socks\",\"server\":\"198.51.100.2\",\"server_port\":1080}"}`), 0, false},
	}
	for _, test := range tests {
		skip, skipped := configSelectorEligibility(test.member, selector, filters, now)
		if skipped != test.isSkip || (test.isSkip && skip != test.skip) {
			t.Fatalf("%s/%s: skip = %v (skipped %v), want %v (%v)",
				test.member.typeName, test.member.name, skip, skipped, test.skip, test.isSkip)
		}
	}
}

func TestConfigSelectorCountryAndUnavailableFilters(t *testing.T) {
	now := int64(1_800_000_000)
	selector := configSelectorDefaults()
	selector.resultValidityMins = 60
	selector.countryFilter = "!RU,DE"
	selector.normalize()
	filters, err := configSelectorBuildFilters(selector)
	if err != nil {
		t.Fatal(err)
	}
	member := selectorTestMember("shadowsocks", `{"type":"shadowsocks","tag":"Node","server":"198.51.100.1","server_port":8388,"method":"aes-256-gcm","password":"p"}`)

	member.country = "de"
	if _, skipped := configSelectorEligibility(member, selector, filters, now); skipped {
		t.Fatal("DE must pass the country filter")
	}
	member.country = "RU"
	if skip, skipped := configSelectorEligibility(member, selector, filters, now); !skipped || skip != configSelectorSkipCountryFilter {
		t.Fatal("RU must be excluded")
	}
	member.country = ""
	if skip, skipped := configSelectorEligibility(member, selector, filters, now); !skipped || skip != configSelectorSkipCountryFilter {
		t.Fatal("an unknown country must be skipped")
	}

	// Only a fresh failure excludes: an old latency -1 is untested, not dead.
	noCountry := configSelectorDefaults()
	noCountry.resultValidityMins = 60
	noCountry.normalize()
	noFilters, err := configSelectorBuildFilters(noCountry)
	if err != nil {
		t.Fatal(err)
	}
	member.country = "DE"
	member.latency = -1
	member.latencyAt = now - 60
	if skip, skipped := configSelectorEligibility(member, noCountry, noFilters, now); !skipped || skip != configSelectorSkipUnavailable {
		t.Fatal("a fresh failure must be excluded")
	}
	member.latencyAt = now - 100000
	if _, skipped := configSelectorEligibility(member, noCountry, noFilters, now); skipped {
		t.Fatal("a stale failure must stay eligible")
	}
}

func TestConfigSelectorPlanErrorsAndOrdering(t *testing.T) {
	rows := []row{
		{"id": 1.0, "name": "One", "display_order": 0.0, "landing_proxy_id": -1.0, "front_proxy_id": -1.0},
		{"id": 2.0, "name": "Two", "display_order": 1.0, "landing_proxy_id": -1.0, "front_proxy_id": -1.0},
	}
	ss := func(id int64, latency int, latencyAt int64) simpleConfigProfile {
		profile := selectorTestProfile(id, "shadowsocks", "Node", 1, id, `{"type":"shadowsocks","tag":"Node","server":"198.51.100.1","server_port":8388,"method":"aes-256-gcm","password":"p"}`)
		profile.Latency = latency
		profile.LatencyAt = latencyAt
		return profile
	}
	now := int64(1_800_000_000)
	profiles := []simpleConfigProfile{ss(2, 50, now-120), ss(3, 10, now-100000), ss(4, 30, now-60), ss(5, 0, 0)}

	// No tracked group.
	empty := configSelectorDefaults()
	empty.normalize()
	plan := configPlanSelector(1, empty, profiles, rows, now)
	if plan.error != "Auto selector tracks no group" {
		t.Fatalf("empty gids error = %q", plan.error)
	}
	missing := configSelectorDefaults()
	missing.gids = []int64{9}
	missing.normalize()
	if plan := configPlanSelector(1, missing, profiles, rows, now); plan.error != "Auto selector points at a group that no longer exists" {
		t.Fatalf("missing group error = %q", plan.error)
	}

	// No usable members.
	onlyMeta := []simpleConfigProfile{selectorTestProfile(9, "chain", "Chain", 1, 0, `{"type":"chain","name":"Chain","list":[]}`)}
	noMembers := configSelectorDefaults()
	noMembers.gids = []int64{1}
	noMembers.normalize()
	if plan := configPlanSelector(1, noMembers, onlyMeta, rows, now); plan.error != "Auto selector has no usable members" {
		t.Fatalf("no members error = %q", plan.error)
	}

	// The persisted pool is the ranking prior; the rest follow by latency, and
	// stale results rank as untested.
	prior := configSelectorDefaults()
	prior.gids = []int64{1}
	prior.pool = []int64{4, 2}
	prior.resultValidityMins = 60
	prior.normalize()
	plan = configPlanSelector(1, prior, profiles, rows, now)
	if plan.error != "" {
		t.Fatalf("plan error = %q", plan.error)
	}
	if want := []int64{4, 2, 3, 5}; !reflect.DeepEqual(plan.build, want) {
		t.Fatalf("build order = %v, want %v", plan.build, want)
	}
	if plan.eligible != 4 || plan.rankedByTest != 2 {
		t.Fatalf("counters = eligible %d, rankedByTest %d", plan.eligible, plan.rankedByTest)
	}
	if plan.needsRanking {
		t.Fatal("buildLimit >= ordered must not need ranking")
	}
}

func TestConfigSelectorBuildLimitAndUnavailableFallback(t *testing.T) {
	rows := []row{{"id": 1.0, "name": "One", "display_order": 0.0}}
	now := int64(1_800_000_000)
	ss := func(id int64, latency int, latencyAt int64) simpleConfigProfile {
		profile := selectorTestProfile(id, "shadowsocks", "Node", 1, id, `{"type":"shadowsocks","tag":"Node","server":"198.51.100.1","server_port":8388,"method":"aes-256-gcm","password":"p"}`)
		profile.Latency = latency
		profile.LatencyAt = latencyAt
		return profile
	}
	// Every fresh result failed: an outage keeps them rather than emptying the pool.
	all := []simpleConfigProfile{ss(2, -1, now-30), ss(3, -1, now-60)}
	selector := configSelectorDefaults()
	selector.gids = []int64{1}
	selector.resultValidityMins = 60
	selector.buildLimit = 1
	selector.normalize()
	plan := configPlanSelector(1, selector, all, rows, now)
	if plan.error != "" || plan.keptUnavailable != 2 {
		t.Fatalf("outage plan = error %q, kept %d", plan.error, plan.keptUnavailable)
	}
	if len(plan.build) != 1 || len(plan.pool) != 2 {
		t.Fatalf("build limit = %d build / %d pool", len(plan.build), len(plan.pool))
	}
	if plan.needsRanking {
		t.Fatal("a failed-latency build needs no ranking")
	}
}

func TestConfigSelectorSkipCounters(t *testing.T) {
	rows := []row{{"id": 1.0, "name": "One", "display_order": 0.0}}
	ss := func(id int64, order int64, jsonText string) simpleConfigProfile {
		return selectorTestProfile(id, "shadowsocks", "Node", 1, order, jsonText)
	}
	valid := `{"type":"shadowsocks","tag":"Node","server":"198.51.100.1","server_port":8388,"method":"aes-256-gcm","password":"p"}`
	profiles := []simpleConfigProfile{
		ss(2, 0, valid),
		selectorTestProfile(3, "chain", "Chain", 1, 1, `{"type":"chain","name":"Chain","list":[2]}`),
		ss(4, 2, "{broken"),
		selectorTestProfile(5, "custom", "Full", 1, 3, `{"type":"custom","name":"Full","subtype":"fullconfig","config":"{\"log\":{}}"}`),
		selectorTestProfile(6, "openvpn", "VPN", 1, 4, `{"type":"openvpn","tag":"VPN"}`),
		selectorTestProfile(7, "socks", "Socks", 1, 5, `{"type":"socks","tag":"Socks","server":"198.51.100.2","server_port":1080}`),
	}
	selector := configSelectorDefaults()
	selector.gids = []int64{1}
	selector.normalize()
	plan := configPlanSelector(1, selector, profiles, rows, 1_800_000_000)
	if plan.error != "" {
		t.Fatalf("plan error = %q", plan.error)
	}
	if plan.membersInGroup != 6 || plan.eligible != 2 {
		t.Fatalf("counters = %d members, %d eligible", plan.membersInGroup, plan.eligible)
	}
	want := []configSelectorSkipCount{
		{skip: configSelectorSkipMetaType, count: 1},
		{skip: configSelectorSkipFullConfig, count: 1},
		{skip: configSelectorSkipMalformed, count: 1},
		{skip: configSelectorSkipManagementEndpoint, count: 1},
	}
	if !reflect.DeepEqual(plan.skipped, want) {
		t.Fatalf("skipped = %#v, want %#v", plan.skipped, want)
	}
	// The reasons are the Kotlin AutoSelectorSkipReason texts; the plan keeps
	// them for the editor summary a later config.build cutover exposes.
	reasons := map[configSelectorSkip]string{
		configSelectorSkipMetaType:           "chain or auto selector",
		configSelectorSkipFullConfig:         "full config profile",
		configSelectorSkipMalformed:          "config does not parse",
		configSelectorSkipManagementEndpoint: "OpenVPN or OpenConnect profile",
	}
	for skip, reason := range reasons {
		if skip.reason() != reason {
			t.Fatalf("%v reason = %q, want %q", skip, skip.reason(), reason)
		}
	}
}

func TestConfigSelectorMemberErrorDropsStructuralFailures(t *testing.T) {
	settings := simpleConfigSettings{DirectDNS: "223.5.5.5", DNSCacheCapacity: 65536, DNSQueryTimeout: "5s"}
	builder := &configBuilder{
		inputs: &simpleConfigInputs{Profiles: []simpleConfigProfile{
			{ID: 2, Type: "chain", OutboundJSON: `{"type":"chain"}`},
			{ID: 3, Type: "shadowsocks", OutboundJSON: `{not json`},
			{ID: 4, Type: "shadowsocks", OutboundJSON: `{"type":"shadowsocks","tag":"s","server":"198.51.100.33","server_port":8388,"method":"aes-256-gcm","password":"pw"}`},
		}},
		settings: settings,
	}

	if reason, _, _, rejected := builder.selectorMemberError(2); !rejected || reason == "" {
		t.Fatalf("a chain member must be rejected, got %q rejected=%v", reason, rejected)
	}
	if reason, _, _, rejected := builder.selectorMemberError(3); !rejected || reason == "" {
		t.Fatalf("an unparsable member must be rejected, got %q rejected=%v", reason, rejected)
	}
	reason, member, object, rejected := builder.selectorMemberError(4)
	if rejected {
		t.Fatalf("a valid member was rejected: %s", reason)
	}
	if member.profileType != "shadowsocks" || object == nil || object["tag"] != "pool-0" {
		t.Fatalf("valid member = %#v object = %#v", member, object)
	}
	if reason, _, _, rejected := builder.selectorMemberError(99); !rejected || reason == "" {
		t.Fatalf("a missing member must be rejected, got %q rejected=%v", reason, rejected)
	}
}
