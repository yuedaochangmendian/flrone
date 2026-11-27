// The auto-selector group of the config builder (ConfigGenerator's Stage 5):
// AutoSelectorPlan.cpp over the tracked groups of the Dart-owned profiles
// document, then the core `auto-selector` outbound of generate.cpp:1622-1776.
//
// The selector document is not a new file: an `autoselector` row in
// profiles.json carries its fields in outbound_json, and every group row
// carries its members through the profiles' `gid` column plus the group's
// landing / front proxies. Reading is lenient on purpose: the Kotlin
// AutoSelector.parseFromJson falls back to each member's own default for a
// value of the wrong JSON type, and a member whose stored JSON does not parse
// is skipped by the plan rather than failing the build.
//
// What the plan contributes to the config: the eligible members in rank order
// (`pool-<i>` chains, best first), the persisted pool as the ranking prior, the
// freshness window that decides which stored results count (and therefore
// which become `warm`), the pin, and the balance block. Counters such as
// `skipped` / `rankedByTest` only describe the editor's summary; they are kept
// on the plan for tests and for the future `config.build` cutover.
package mobile

import (
	"fmt"
	"regexp"
	"sort"
	"strings"
)

const (
	// configSelectorPoolChainPrefix is Tags.POOL_CHAIN_PREFIX: member i is
	// `pool-<i>-0` (its chain's ingress).
	configSelectorPoolChainPrefix = "pool"

	configSelectorMaxPoolCap    = 3000
	configSelectorMaxBuildLimit = 500

	// configSelectorCustomOutbound is Custom.CUSTOM_OUTBOUND: only a plain
	// custom outbound can be a member; a full config replaces the core config.
	configSelectorCustomOutbound = "outbound"
)

// configAutoSelector is one `autoselector` profile as AutoSelector reads it.
// Every field keeps the Kotlin member default, so a missing key or a value of
// the wrong JSON type takes that default (autoselector.h:61-95).
type configAutoSelector struct {
	gids []int64

	nameFilter         string
	countryFilter      string
	excludeUnavailable bool

	poolCap            int
	buildLimit         int
	resultValidityMins int

	testURL         string
	connectivityURL string

	intervalSec      int
	benchIntervalSec int
	watchIntervalSec int

	activeSize        int
	sampling          int
	toleranceMs       int
	maxRTTms          int
	expected          int
	dialRetries       int
	interruptOnSwitch bool

	balance            bool
	balanceMode        string
	balanceIntervalSec int

	pool         []int64
	poolRankedAt int64
	pinnedID     int64
	lastBuilt    []int64
	lastBuiltAt  int64
}

func configSelectorDefaults() configAutoSelector {
	return configAutoSelector{
		excludeUnavailable: true,
		poolCap:            1000,
		buildLimit:         300,
		resultValidityMins: 1440,
		intervalSec:        300,
		benchIntervalSec:   600,
		watchIntervalSec:   15,
		activeSize:         8,
		sampling:           10,
		toleranceMs:        300,
		expected:           3,
		dialRetries:        2,
		interruptOnSwitch:  true,
		balanceMode:        "rotate",
		balanceIntervalSec: 30,
		pinnedID:           -1,
	}
}

// normalize is AutoSelector.normalize (autoselector.h:140-167): clamps what a
// hand-edited profile could put out of range. It runs before every plan, so
// the Go builder always sees the same values the Kotlin planner does.
func (selector *configAutoSelector) normalize() {
	seen := make(map[int64]bool, len(selector.gids))
	gids := make([]int64, 0, len(selector.gids))
	for _, gid := range selector.gids {
		if gid < 0 || seen[gid] {
			continue
		}
		seen[gid] = true
		gids = append(gids, gid)
	}
	selector.gids = gids

	if selector.poolCap < 1 {
		selector.poolCap = 1
	}
	if selector.poolCap > configSelectorMaxPoolCap {
		selector.poolCap = configSelectorMaxPoolCap
	}
	if selector.buildLimit < 1 {
		selector.buildLimit = 1
	}
	if selector.buildLimit > configSelectorMaxBuildLimit {
		selector.buildLimit = configSelectorMaxBuildLimit
	}
	if selector.buildLimit > selector.poolCap {
		selector.buildLimit = selector.poolCap
	}
	if selector.resultValidityMins < 0 {
		selector.resultValidityMins = 0
	}
	if selector.intervalSec < 10 {
		selector.intervalSec = 10
	}
	if selector.benchIntervalSec < selector.intervalSec {
		selector.benchIntervalSec = selector.intervalSec
	}
	if selector.watchIntervalSec < 5 {
		selector.watchIntervalSec = 5
	}
	if selector.watchIntervalSec > selector.intervalSec {
		selector.watchIntervalSec = selector.intervalSec
	}
	if selector.activeSize < 1 {
		selector.activeSize = 1
	}
	if selector.expected < 1 {
		selector.expected = 1
	}
	// The ready set must sit inside the closely-checked set, or readiness rides
	// on stale bench data.
	if selector.activeSize < selector.expected {
		selector.activeSize = selector.expected
	}
	if selector.activeSize > selector.buildLimit {
		selector.activeSize = selector.buildLimit
	}
	if selector.sampling < 2 {
		selector.sampling = 2
	}
	if selector.sampling > 60 {
		selector.sampling = 60
	}
	if selector.toleranceMs < 0 {
		selector.toleranceMs = 0
	}
	if selector.maxRTTms < 0 {
		selector.maxRTTms = 0
	}
	if selector.expected > selector.buildLimit {
		selector.expected = selector.buildLimit
	}
	if selector.dialRetries < 0 {
		selector.dialRetries = 0
	}
	if selector.dialRetries > 5 {
		selector.dialRetries = 5
	}
	if selector.balanceIntervalSec < 5 {
		selector.balanceIntervalSec = 5
	}
	if selector.balanceMode != "connection" {
		selector.balanceMode = "rotate"
	}
}

// configParseSelectorProfile loads one `autoselector` row. The bool is the
// Kotlin `invalid` flag: a JSON text that is not an object becomes an
// InvalidOutbound, while an empty text leaves the defaults in place (like
// ProxyEntity.parseOutbound, which skips parseFromJson for an empty object).
func configParseSelectorProfile(profile simpleConfigProfile) (configAutoSelector, bool) {
	selector := configSelectorDefaults()
	text := strings.TrimSpace(profile.OutboundJSON)
	if text == "" {
		return selector, false
	}
	object, ok := configDecodeJSONObject(text)
	if !ok {
		object, ok = configLenientJSONObject(text)
	}
	if !ok {
		return selector, true
	}
	if len(object) == 0 {
		return selector, false
	}

	if value, present := object["gids"]; present {
		items, _ := value.([]any)
		selector.gids = make([]int64, 0, len(items))
		for _, item := range items {
			if gid := configSelectorLongOr(item, -1); gid >= 0 {
				selector.gids = append(selector.gids, gid)
			}
		}
	} else if value, present := object["gid"]; present {
		if gid := configSelectorLongOr(value, -1); gid >= 0 {
			selector.gids = []int64{gid}
		}
	}
	if _, present := object["name_filter"]; present {
		selector.nameFilter = configJSONString(object, "name_filter")
	}
	if _, present := object["country_filter"]; present {
		selector.countryFilter = configJSONString(object, "country_filter")
	}
	if _, present := object["exclude_unavailable"]; present {
		selector.excludeUnavailable = configSelectorBoolOr(object["exclude_unavailable"], true)
	}
	if _, present := object["pool_cap"]; present {
		selector.poolCap = configSelectorIntOr(object["pool_cap"], 1000)
	}
	if _, present := object["build_limit"]; present {
		selector.buildLimit = configSelectorIntOr(object["build_limit"], 300)
	}
	if _, present := object["result_validity_mins"]; present {
		selector.resultValidityMins = configSelectorIntOr(object["result_validity_mins"], 1440)
	}
	if _, present := object["test_url"]; present {
		selector.testURL = configJSONString(object, "test_url")
	}
	if _, present := object["connectivity_url"]; present {
		selector.connectivityURL = configJSONString(object, "connectivity_url")
	}
	if _, present := object["interval_sec"]; present {
		selector.intervalSec = configSelectorIntOr(object["interval_sec"], 300)
	}
	if _, present := object["bench_interval_sec"]; present {
		selector.benchIntervalSec = configSelectorIntOr(object["bench_interval_sec"], 600)
	}
	if _, present := object["watch_interval_sec"]; present {
		selector.watchIntervalSec = configSelectorIntOr(object["watch_interval_sec"], 15)
	}
	if _, present := object["active_size"]; present {
		selector.activeSize = configSelectorIntOr(object["active_size"], 8)
	}
	if _, present := object["sampling"]; present {
		selector.sampling = configSelectorIntOr(object["sampling"], 10)
	}
	if _, present := object["tolerance_ms"]; present {
		selector.toleranceMs = configSelectorIntOr(object["tolerance_ms"], 300)
	}
	if _, present := object["max_rtt_ms"]; present {
		selector.maxRTTms = configSelectorIntOr(object["max_rtt_ms"], 0)
	}
	if _, present := object["expected"]; present {
		selector.expected = configSelectorIntOr(object["expected"], 3)
	}
	if _, present := object["dial_retries"]; present {
		selector.dialRetries = configSelectorIntOr(object["dial_retries"], 2)
	}
	if _, present := object["interrupt_on_switch"]; present {
		selector.interruptOnSwitch = configSelectorBoolOr(object["interrupt_on_switch"], true)
	}
	if _, present := object["balance"]; present {
		selector.balance = configSelectorBoolOr(object["balance"], false)
	}
	if _, present := object["balance_mode"]; present {
		if mode, ok := object["balance_mode"].(string); ok {
			selector.balanceMode = mode
		}
	}
	if _, present := object["balance_interval_sec"]; present {
		selector.balanceIntervalSec = configSelectorIntOr(object["balance_interval_sec"], 30)
	}
	if value, present := object["pool"]; present {
		items, _ := value.([]any)
		selector.pool = make([]int64, 0, len(items))
		for _, item := range items {
			selector.pool = append(selector.pool, configJSONInteger(item))
		}
	}
	if _, present := object["pool_ranked_at"]; present {
		selector.poolRankedAt = configSelectorLongOr(object["pool_ranked_at"], 0)
	}
	if _, present := object["pinned_id"]; present {
		selector.pinnedID = configSelectorLongOr(object["pinned_id"], -1)
	}
	if value, present := object["last_built"]; present {
		items, _ := value.([]any)
		selector.lastBuilt = make([]int64, 0, len(items))
		for _, item := range items {
			selector.lastBuilt = append(selector.lastBuilt, configJSONInteger(item))
		}
	}
	if _, present := object["last_built_at"]; present {
		selector.lastBuiltAt = configSelectorLongOr(object["last_built_at"], 0)
	}
	// `history` is only the editor's usage log; the config build never reads it.

	selector.normalize()
	return selector, false
}

// configSelectorIntOr is AutoSelector.intOr: a whole number that fits an Int
// else the member default. Our decoder gives integers int64 and other numbers
// float64, which is what the Kotlin arms distinguish.
func configSelectorIntOr(value any, fallback int) int {
	switch typed := value.(type) {
	case int64:
		if typed >= -2147483648 && typed <= 2147483647 {
			return int(typed)
		}
	case float64:
		if typed == float64(int64(typed)) && typed >= -2147483648 && typed <= 2147483647 {
			return int(typed)
		}
	}
	return fallback
}

// configSelectorLongOr is AutoSelector.longOr.
func configSelectorLongOr(value any, fallback int64) int64 {
	switch typed := value.(type) {
	case int64:
		return typed
	case float64:
		if typed == float64(int64(typed)) && typed >= -9223372036854775808.0 && typed < 9223372036854775808.0 {
			return int64(typed)
		}
	}
	return fallback
}

// configSelectorBoolOr is AutoSelector.boolOr: only a JSON boolean counts.
func configSelectorBoolOr(value any, fallback bool) bool {
	if flag, ok := value.(bool); ok {
		return flag
	}
	return fallback
}

// configSelectorGroup is GroupsRepo::GetGroup with Group::Profiles() as the
// plan reads it: the resolved landing / front proxy ids and the members in list
// order.
type configSelectorGroup struct {
	id             int64
	name           string
	landingProxyID int64
	frontProxyID   int64
	members        []*configSelectorMember
}

// configSelectorMember is one profile of a tracked group: the stored row plus
// the few outbound facts eligibility reads.
type configSelectorMember struct {
	id         int64
	profile    simpleConfigProfile
	typeName   string
	invalid    bool
	name       string
	address    string
	subtype    string
	configText string
	latency    int
	latencyAt  int64
	country    string
}

// configSelectorSkip is AutoSelectorSkip (AutoSelectorPlan.h:12-27); reason is
// the Kotlin text of AutoSelectorSkipReason (AutoSelectorPlan.cpp:225-243).
type configSelectorSkip int

const (
	configSelectorSkipMissing configSelectorSkip = iota
	configSelectorSkipMetaType
	configSelectorSkipExtraCore
	configSelectorSkipFullConfig
	configSelectorSkipMalformed
	configSelectorSkipTailscale
	configSelectorSkipManagementEndpoint
	configSelectorSkipNameFilter
	configSelectorSkipCountryFilter
	configSelectorSkipUnavailable
	configSelectorSkipUnsupported
)

func (skip configSelectorSkip) reason() string {
	switch skip {
	case configSelectorSkipMissing:
		return "missing profile"
	case configSelectorSkipMetaType:
		return "chain or auto selector"
	case configSelectorSkipExtraCore:
		return "extra-core profile"
	case configSelectorSkipFullConfig:
		return "full config profile"
	case configSelectorSkipMalformed:
		return "config does not parse"
	case configSelectorSkipTailscale:
		return "Tailscale profile"
	case configSelectorSkipManagementEndpoint:
		return "OpenVPN or OpenConnect profile"
	case configSelectorSkipNameFilter:
		return "filtered out by name"
	case configSelectorSkipCountryFilter:
		return "filtered out by country"
	case configSelectorSkipUnavailable:
		return "last test failed"
	default:
		return "type this build cannot use"
	}
}

var configSelectorSkipOrder = []configSelectorSkip{
	configSelectorSkipMissing,
	configSelectorSkipMetaType,
	configSelectorSkipExtraCore,
	configSelectorSkipFullConfig,
	configSelectorSkipMalformed,
	configSelectorSkipTailscale,
	configSelectorSkipManagementEndpoint,
	configSelectorSkipNameFilter,
	configSelectorSkipCountryFilter,
	configSelectorSkipUnavailable,
	configSelectorSkipUnsupported,
}

// configSelectorSkipCount is one `(reason, count)` pair of AutoSelectorPlan.skipped.
type configSelectorSkipCount struct {
	skip  configSelectorSkip
	count int
}

// configSelectorPlan is AutoSelectorPlan (AutoSelectorPlan.h:31-58) as far as
// the config build needs it, plus the counters that describe the same plan.
type configSelectorPlan struct {
	pool  []int64
	build []int64

	membersInGroup  int
	missingGroups   int
	eligible        int
	rankedByTest    int
	keptUnavailable int
	skipped         []configSelectorSkipCount
	truncated       bool
	poolCapUsed     int
	buildLimitUsed  int
	needsRanking    bool

	error string

	groups  []*configSelectorGroup
	byID    map[int64]*configSelectorMember
	groupOf map[int64]*configSelectorGroup
}

func (plan *configSelectorPlan) ok() bool { return plan.error == "" }

// configSelectorOutboundTypes is OutboundFactory.ALL_TYPES, canonicalised: the
// set whose parse failure means Malformed rather than Unsupported.
var configSelectorOutboundTypes = map[string]bool{
	"socks": true, "http": true, "shadowsocks": true, "chain": true,
	"autoselector": true, "vmess": true, "trojan": true, "vless": true,
	"hysteria": true, "tuic": true, "juicity": true, "trusttunnel": true,
	"anytls": true, "mieru": true, "snell": true, "shadowtls": true,
	"wireguard": true, "masque": true, "openvpn": true, "openconnect": true,
	"tailscale": true, "ssh": true, "custom": true, "extracore": true,
	"naive": true, "direct": true,
}

// configSelectorCanonicalType is OutboundFactory.canonicalType.
func configSelectorCanonicalType(typeName string) string {
	switch typeName {
	case "hysteria2":
		return "hysteria"
	case "openvpn-client":
		return "openvpn"
	}
	return typeName
}

// configSelectorMemberFromProfile builds the eligibility view of one row. It
// never fails: problems become the plan's skip reasons, exactly like the
// Kotlin plan reading an InvalidOutbound.
func configSelectorMemberFromProfile(profile simpleConfigProfile) *configSelectorMember {
	member := &configSelectorMember{
		id:        profile.ID,
		profile:   profile,
		typeName:  configSelectorCanonicalType(profile.Type),
		latency:   profile.Latency,
		latencyAt: profile.LatencyAt,
		country:   profile.TestCountry,
	}
	text := strings.TrimSpace(profile.OutboundJSON)
	if text == "" {
		member.refreshDisplay()
		return member
	}
	object, ok := configDecodeJSONObject(text)
	if !ok {
		object, ok = configLenientJSONObject(text)
	}
	if !ok || len(object) == 0 {
		member.invalid = true
		member.refreshDisplay()
		return member
	}
	if member.typeName == "custom" {
		params := configParseCustom(object)
		member.subtype = params.subtype
		member.configText = params.config
		member.name = configJSONString(object, "name")
		member.address = configSelectorCustomAddress(params)
	} else {
		member.name = configJSONString(object, "tag")
		member.address = configSelectorDisplayAddress(member.typeName, object)
	}
	if !configSelectorOutboundTypes[member.typeName] {
		member.invalid = true
	}
	return member
}

// refreshDisplay fills the name / address fallback for an unparsed row from
// the row itself.
func (member *configSelectorMember) refreshDisplay() {
	if !configSelectorOutboundTypes[member.typeName] {
		member.invalid = true
	}
}

// displayName is Outbound.displayName: the tag, else the address (or Direct's
// bind description).
func (member *configSelectorMember) displayName() string {
	if member.name != "" {
		return member.name
	}
	return member.address
}

func configSelectorDisplayAddress(typeName string, object map[string]any) string {
	if typeName == "direct" {
		if bind := configJSONString(object, "bind_interface"); bind != "" {
			return "Bind NIC: " + bind
		}
		if inet4 := configJSONString(object, "inet4_bind_address"); inet4 != "" {
			return "Bind Addr4: " + inet4
		}
		if inet6 := configJSONString(object, "inet6_bind_address"); inet6 != "" {
			return "Bind Addr6" + inet6
		}
		return "Empty"
	}
	if typeName == "chain" || typeName == "autoselector" {
		return ""
	}
	return configSelectorHostAddress(configJSONString(object, "server"), configJSONInt(object["server_port"]))
}

func configSelectorCustomAddress(params configCustomParams) string {
	if params.subtype != configSelectorCustomOutbound {
		return ""
	}
	object := configCustomObject(params.config)
	return configSelectorHostAddress(configJSONString(object, "server"), configJSONInt(object["server_port"]))
}

// configSelectorHostAddress is Hosts.displayAddress: an IPv6 host is bracketed,
// an empty server with port 0 has no address at all.
func configSelectorHostAddress(server string, port int) string {
	if server == "" && port == 0 {
		return ""
	}
	host := server
	if configSelectorIsIPv6Address(server) {
		host = "[" + strings.TrimSuffix(strings.TrimPrefix(server, "["), "]") + "]"
	}
	return host + ":" + fmt.Sprint(port)
}

func configSelectorIsIPv6Address(text string) bool {
	trimmed := strings.TrimSuffix(strings.TrimPrefix(text, "["), "]")
	if percent := strings.Index(trimmed, "%"); percent >= 0 {
		trimmed = trimmed[:percent]
	}
	return configIsIPv6Address(trimmed)
}

// configSelectorFilters is buildFilters (AutoSelectorPlan.cpp:27-39): an
// invalid regex filters nothing (the editor refuses to save one), country
// codes are trimmed and upper-cased, "!XX" excludes.
type configSelectorFilters struct {
	name      *regexp.Regexp
	countries map[string]bool
	excluded  map[string]bool
}

func configSelectorBuildFilters(selector configAutoSelector) configSelectorFilters {
	filters := configSelectorFilters{
		countries: make(map[string]bool),
		excluded:  make(map[string]bool),
	}
	if pattern := strings.TrimSpace(selector.nameFilter); pattern != "" {
		// Pattern.CASE_INSENSITIVE | UNICODE_CASE: Go's (?i) is the equivalent
		// substring matcher for the Rust/RE2 syntax, which is what a profile's
		// filter is expected to use. Java-only constructs fail to compile and
		// filter nothing, matching the Kotlin invalid-regex arm.
		if compiled, err := regexp.Compile("(?i)" + pattern); err == nil {
			filters.name = compiled
		}
	}
	for _, item := range strings.Split(selector.countryFilter, ",") {
		code := strings.TrimSpace(item)
		exclude := strings.HasPrefix(code, "!")
		if exclude {
			code = strings.TrimSpace(code[1:])
		}
		if code == "" {
			continue
		}
		code = strings.ToUpper(code)
		if exclude {
			filters.excluded[code] = true
		} else {
			filters.countries[code] = true
		}
	}
	return filters
}

// configSelectorHasFreshResult is AutoSelectorPlanner.hasFreshResult: a stored
// result inside the trust window; rows without a timestamp are stale.
func configSelectorHasFreshResult(member *configSelectorMember, selector configAutoSelector, now int64) bool {
	if member == nil || member.latency == 0 {
		return false
	}
	if selector.resultValidityMins <= 0 {
		return false
	}
	if member.latencyAt <= 0 {
		return false
	}
	return now-member.latencyAt <= int64(selector.resultValidityMins)*60
}

// configSelectorEffectiveLatency is AutoSelectorPlanner.effectiveLatency:
// stale results count as untested (0).
func configSelectorEffectiveLatency(member *configSelectorMember, selector configAutoSelector, now int64) int {
	if configSelectorHasFreshResult(member, selector, now) {
		return member.latency
	}
	return 0
}

// configSelectorEligibility is eligibilityOf (cpp:50-82); false means eligible.
func configSelectorEligibility(member *configSelectorMember, selector configAutoSelector,
	filters configSelectorFilters, now int64,
) (configSelectorSkip, bool) {
	typeName := member.typeName
	if typeName == "chain" || typeName == "autoselector" {
		return configSelectorSkipMetaType, true
	}
	if typeName == "tailscale" {
		return configSelectorSkipTailscale, true
	}
	if typeName == "openvpn" || typeName == "openconnect" {
		return configSelectorSkipManagementEndpoint, true
	}
	if typeName == "extracore" {
		return configSelectorSkipExtraCore, true
	}
	// A known type that is still invalid is a row whose stored JSON does not parse.
	if member.invalid {
		if configSelectorOutboundTypes[typeName] {
			return configSelectorSkipMalformed, true
		}
		return configSelectorSkipUnsupported, true
	}
	if typeName == "custom" {
		if member.subtype != configSelectorCustomOutbound {
			// A full config replaces the whole core config; only a plain custom
			// outbound can be a member.
			return configSelectorSkipFullConfig, true
		}
		if len(configCustomObject(member.configText)) == 0 {
			return configSelectorSkipMalformed, true
		}
	}
	if filters.name != nil && !filters.name.MatchString(member.displayName()) {
		return configSelectorSkipNameFilter, true
	}
	if len(filters.countries) > 0 || len(filters.excluded) > 0 {
		// Unknown country is skipped either way: an exclusion cannot vouch for a
		// profile never IP-tested.
		country := strings.ToUpper(strings.TrimSpace(member.country))
		if country == "" || filters.excluded[country] ||
			(len(filters.countries) > 0 && !filters.countries[country]) {
			return configSelectorSkipCountryFilter, true
		}
	}
	// Only a fresh failure excludes a member; an old one would exile it permanently.
	if selector.excludeUnavailable && member.latency < 0 && configSelectorHasFreshResult(member, selector, now) {
		return configSelectorSkipUnavailable, true
	}
	return 0, false
}

// configFindGroupRow resolves one groups row by id; id <= 0 never resolves.
func configFindGroupRow(groups []row, id int64) *row {
	if id <= 0 {
		return nil
	}
	for index := range groups {
		if rowInt64(groups[index], "id") == id {
			return &groups[index]
		}
	}
	return nil
}

// configSelectorGroupFromRow is GroupsRepo::GetGroup: the stored landing /
// front proxy ids (non-positive means none) and the name.
func configSelectorGroupFromRow(groupRow row) *configSelectorGroup {
	return &configSelectorGroup{
		id:             rowInt64(groupRow, "id"),
		name:           rowString(groupRow, "name"),
		landingProxyID: rowInt64Fallback(groupRow, "landing_proxy_id", -1),
		frontProxyID:   rowInt64Fallback(groupRow, "front_proxy_id", -1),
	}
}

// configSelectorGroupMembers is ProfileManager.members(gid): the group's
// profiles in list order (user_order, then id).
func configSelectorGroupMembers(groupID int64, profiles []simpleConfigProfile) []*configSelectorMember {
	rows := make([]simpleConfigProfile, 0)
	for _, profile := range profiles {
		if profile.GroupID == groupID {
			rows = append(rows, profile)
		}
	}
	sort.SliceStable(rows, func(a, b int) bool {
		if rows[a].UserOrder != rows[b].UserOrder {
			return rows[a].UserOrder < rows[b].UserOrder
		}
		return rows[a].ID < rows[b].ID
	})
	members := make([]*configSelectorMember, 0, len(rows))
	for _, profileRow := range rows {
		members = append(members, configSelectorMemberFromProfile(profileRow))
	}
	return members
}

// configPlanSelector is AutoSelectorPlanner.plan (cpp:245-284) with the clock
// supplied instead of read. selectorID is excluded from the members, missing
// groups are skipped, and the plan's error is one of the Kotlin texts.
func configPlanSelector(
	selectorID int64, selector configAutoSelector,
	profiles []simpleConfigProfile, groups []row, now int64,
) *configSelectorPlan {
	selector.normalize()
	plan := &configSelectorPlan{
		poolCapUsed:    selector.poolCap,
		buildLimitUsed: selector.buildLimit,
		byID:           make(map[int64]*configSelectorMember),
		groupOf:        make(map[int64]*configSelectorGroup),
	}

	// track(selector): the groups that exist in gids order, an id listed by
	// more than one group taken once with the first group.
	seen := make(map[int64]bool)
	trackedGroups := make([]*configSelectorGroup, 0, len(selector.gids))
	for _, gid := range selector.gids {
		if seen[gid] {
			continue
		}
		seen[gid] = true
		groupRow := configFindGroupRow(groups, gid)
		if groupRow == nil {
			plan.missingGroups++
			continue
		}
		trackedGroups = append(trackedGroups, configSelectorGroupFromRow(*groupRow))
	}
	if len(trackedGroups) == 0 {
		if len(selector.gids) == 0 {
			plan.error = "Auto selector tracks no group"
		} else {
			plan.error = "Auto selector points at a group that no longer exists"
		}
		return plan
	}
	plan.groups = trackedGroups

	tracked := make([]*configSelectorMember, 0)
	for _, group := range trackedGroups {
		group.members = configSelectorGroupMembers(group.id, profiles)
		for _, member := range group.members {
			if _, exists := plan.groupOf[member.id]; exists {
				continue
			}
			plan.groupOf[member.id] = group
			plan.byID[member.id] = member
			tracked = append(tracked, member)
		}
	}

	// eligibleMembers (cpp:139-198).
	filters := configSelectorBuildFilters(selector)
	skips := make(map[configSelectorSkip]int)
	members := make([]int64, 0)
	unavailable := make([]int64, 0)
	for _, member := range tracked {
		if member.id == selectorID {
			continue
		}
		plan.membersInGroup++
		skip, skipped := configSelectorEligibility(member, selector, filters, now)
		if skipped && skip != configSelectorSkipUnavailable {
			skips[skip]++
			continue
		}
		if skipped {
			unavailable = append(unavailable, member.id)
			continue
		}
		members = append(members, member.id)
		if configSelectorEffectiveLatency(member, selector, now) > 0 {
			plan.rankedByTest++
		}
	}
	// Every member's last test failing is an outage, not a dead subscription:
	// excluding them all would leave nothing that could discover the servers
	// came back.
	if len(members) == 0 && len(unavailable) > 0 {
		members = append(members, unavailable...)
		plan.keptUnavailable = len(unavailable)
	} else if len(unavailable) > 0 {
		skips[configSelectorSkipUnavailable] += len(unavailable)
	}
	for _, skip := range configSelectorSkipOrder {
		if count := skips[skip]; count > 0 {
			plan.skipped = append(plan.skipped, configSelectorSkipCount{skip: skip, count: count})
		}
	}
	plan.eligible = len(members)
	if len(members) == 0 {
		plan.error = "Auto selector has no usable members"
		return plan
	}

	ordered := configSelectorOrderMembers(members, selector.pool, selector, plan.byID, now, nil)
	plan.truncated = len(ordered) > selector.poolCap
	if plan.truncated {
		ordered = ordered[:selector.poolCap]
	}
	plan.pool = ordered
	if len(ordered) > selector.buildLimit {
		plan.build = ordered[:selector.buildLimit]
	} else {
		plan.build = ordered
	}
	if len(ordered) > selector.buildLimit {
		for _, id := range plan.build {
			if configSelectorEffectiveLatency(plan.byID[id], selector, now) == 0 {
				plan.needsRanking = true
				break
			}
		}
	}
	return plan
}

// configSelectorOrderMembers is orderMembers (cpp:200-222): the persisted pool
// is the core's ranking prior; newcomers follow by latency.
func configSelectorOrderMembers(
	members []int64, persistedPool []int64, selector configAutoSelector,
	byID map[int64]*configSelectorMember, now int64, untrusted map[int64]bool,
) []int64 {
	eligible := make(map[int64]bool, len(members))
	for _, id := range members {
		eligible[id] = true
	}
	placed := make(map[int64]bool, len(members))
	ordered := make([]int64, 0, len(members))
	for _, id := range persistedPool {
		if !eligible[id] || placed[id] {
			continue
		}
		placed[id] = true
		ordered = append(ordered, id)
	}
	rest := make([]int64, 0, len(members)-len(ordered))
	for _, id := range members {
		if !placed[id] {
			rest = append(rest, id)
		}
	}
	ordered = append(ordered, configSelectorSortByLatency(rest, selector, byID, now, untrusted)...)
	return ordered
}

// configSelectorSortByLatency is sortByLatency (cpp:149-159): each effective
// latency read once up front, untrusted members as untested, then a stable sort.
func configSelectorSortByLatency(
	ids []int64, selector configAutoSelector, byID map[int64]*configSelectorMember,
	now int64, untrusted map[int64]bool,
) []int64 {
	latency := make(map[int64]int, len(ids))
	for _, id := range ids {
		if untrusted[id] {
			latency[id] = 0
			continue
		}
		latency[id] = configSelectorEffectiveLatency(byID[id], selector, now)
	}
	sorted := append([]int64(nil), ids...)
	sort.SliceStable(sorted, func(left, right int) bool {
		leftLatency := latency[sorted[left]]
		rightLatency := latency[sorted[right]]
		leftRank := configSelectorLatencyRank(leftLatency)
		rightRank := configSelectorLatencyRank(rightLatency)
		if leftRank != rightRank {
			return leftRank < rightRank
		}
		if leftRank == 0 {
			return leftLatency < rightLatency
		}
		return false
	})
	return sorted
}

// configSelectorLatencyRank is latencyRank (cpp:110-116): untested (1)
// outranks failed (2) so a fresh subscription still gets explored.
func configSelectorLatencyRank(latency int) int {
	if latency > 0 {
		return 0
	}
	if latency == 0 {
		return 1
	}
	return 2
}

// buildAutoSelectorGroup is ConfigGenerator.buildAutoSelectorGroup
// (:1622-1776): per member of the plan's build a chain `[landing?, member,
// front?]` with the landing / front proxy of the member's own group under
// `pool-<i>` (ingress `pool-<i>-0`), then the core `auto-selector` outbound
// over the members with the warm health of fresh results and the pin. It is
// `proxy`, or `warp-bypass` when WARP takes `proxy`.
func (builder *configBuilder) buildAutoSelectorGroup(selector configAutoSelector, plan *configSelectorPlan) error {
	if !plan.ok() {
		return fmt.Errorf("%s", plan.error)
	}
	groupTag := tagProxy
	if builder.settings.EnableWarp {
		groupTag = tagWarpBypass
	}

	// Kotlin rejectedMembers: one member the core rejects would fail the whole
	// group's start, so drop it instead of emitting a pool chain for it. The
	// golden harness has no core member check (its JVM oracle builds RoutingInput
	// without one), so only the structural verdict runs there; the production
	// action supplies inputs.MemberCheck.
	fragmentError := ""
	if err := configFragmentSettingsError(builder.settings); err != nil {
		fragmentError = err.Error()
	}
	buildIDs := make([]int64, 0, len(plan.build))
	for _, id := range plan.build {
		reason, member, object, rejected := builder.selectorMemberError(id)
		if !rejected && builder.inputs.MemberCheck != nil && object != nil {
			if verdict := builder.inputs.MemberCheck(id, member, object); verdict != "" {
				reason, rejected = verdict, true
			}
		}
		if rejected {
			// A bad global fragment setting is not the member's fault: the real
			// chain build below reports it and fails the whole build.
			if fragmentError != "" && reason == fragmentError {
				buildIDs = append(buildIDs, id)
			}
			continue
		}
		buildIDs = append(buildIDs, id)
	}

	type plannedMember struct {
		member *configSelectorMember
		group  *configSelectorGroup
		hopIDs []int64
	}
	planned := make([]plannedMember, 0, len(buildIDs))
	for _, id := range buildIDs {
		member := plan.byID[id]
		if member == nil {
			continue
		}
		group := plan.groupOf[id]
		if group == nil {
			continue
		}
		if configFindProfile(builder.inputs.Profiles, id) == nil {
			continue
		}
		hopIDs := make([]int64, 0, 3)
		if group.landingProxyID > 0 {
			hopIDs = append(hopIDs, group.landingProxyID)
		}
		hopIDs = append(hopIDs, id)
		if group.frontProxyID > 0 {
			hopIDs = append(hopIDs, group.frontProxyID)
		}
		planned = append(planned, plannedMember{member: member, group: group, hopIDs: hopIDs})
	}

	builtAt := builder.clock
	warm := make([]any, 0)
	pinnedTag := ""
	memberTags := make([]string, 0, len(planned))
	for index, entry := range planned {
		origin := &configHopOrigin{
			groupName: entry.group.name,
			landingID: entry.group.landingProxyID,
			frontID:   entry.group.frontProxyID,
		}
		tag, err := configBuildChain(builder.inputs.Profiles, builder.settings, entry.hopIDs,
			configHopTag(configSelectorPoolChainPrefix, index), false, true, false, 0,
			&builder.outbounds, &builder.endpoints, builder.ctx.directDomainStrategy(),
			builder.collectECHQueryName, origin)
		if err != nil {
			return err
		}
		memberTags = append(memberTags, tag)
		member := entry.member
		if member.id == selector.pinnedID {
			pinnedTag = tag
		}
		if member.latency != 0 && member.latencyAt > 0 && selector.resultValidityMins > 0 {
			age := builtAt - member.latencyAt
			if age >= 0 && age <= int64(selector.resultValidityMins)*60 {
				// rtt 0 is how the core reads "known bad" rather than "never measured".
				rtt := member.latency
				if rtt < 0 {
					rtt = 0
				}
				warm = append(warm, map[string]any{"tag": tag, "rtt": rtt, "age": age})
			}
		}
	}
	if len(memberTags) == 0 {
		return fmt.Errorf("Auto selector produced no usable members")
	}

	group := map[string]any{
		"type":                        "auto-selector",
		"tag":                         groupTag,
		"outbounds":                   memberTags,
		"url":                         configSelectorTestURL(selector, builder.settings),
		"interval":                    fmt.Sprintf("%ds", selector.intervalSec),
		"bench_interval":              fmt.Sprintf("%ds", selector.benchIntervalSec),
		"watch_interval":              fmt.Sprintf("%ds", selector.watchIntervalSec),
		"active_size":                 selector.activeSize,
		"sampling":                    selector.sampling,
		"tolerance":                   selector.toleranceMs,
		"expected":                    selector.expected,
		"dial_retries":                selector.dialRetries,
		"interrupt_exist_connections": selector.interruptOnSwitch,
	}
	if len(warm) > 0 {
		group["warm"] = warm
	}
	if pinnedTag != "" {
		group["pinned"] = pinnedTag
	}
	if selector.maxRTTms > 0 {
		group["max_rtt"] = fmt.Sprintf("%dms", selector.maxRTTms)
	}
	// Never the latency test URL: that one is fetched through the proxy and is
	// routinely blocked directly.
	connectivityURL := configSelectorConnectivityURL(selector, builder.settings)
	if connectivityURL != "" {
		group["connectivity_url"] = connectivityURL
	}
	if selector.balance {
		group["balance"] = true
		group["balance_mode"] = selector.balanceMode
		group["balance_interval"] = fmt.Sprintf("%ds", selector.balanceIntervalSec)
	}
	builder.outbounds = append(builder.outbounds, group)
	return nil
}

// configSelectorTestURL is selector.testURL.ifEmpty { settings.testUrl }.
func configSelectorTestURL(selector configAutoSelector, settings simpleConfigSettings) string {
	if selector.testURL != "" {
		return selector.testURL
	}
	return settings.TestURL
}

// configSelectorConnectivityURL is selector.connectivityURL.ifEmpty { settings.directTestUrl }.
func configSelectorConnectivityURL(selector configAutoSelector, settings simpleConfigSettings) string {
	if selector.connectivityURL != "" {
		return selector.connectivityURL
	}
	return settings.DirectTestURL
}

// selectorMemberError is ChainBuilder.candidateError(listOf(id)) for one
// auto-selector member: the hop walk's refusals plus a single-hop build. The
// built outbound is returned (when it exists) for inputs.MemberCheck, which is
// the core's half of the Kotlin invalidProfileIDs check. The error text is not
// part of the config; it only decides whether the member is dropped.
func (builder *configBuilder) selectorMemberError(id int64) (string, configOutbound, map[string]any, bool) {
	row := configFindProfile(builder.inputs.Profiles, id)
	if row == nil {
		return "A proxy in the chain can no longer be found.", configOutbound{}, nil, true
	}
	outbound, err := configParseOutboundJSON(*row)
	if err != nil {
		return err.Error(), configOutbound{}, nil, true
	}
	if outbound.profileType == "chain" {
		return "Chain in Chain is not allowed", outbound, nil, true
	}
	if outbound.profileType == "autoselector" {
		return "An auto selector cannot be used as a hop; it is not a fixed server", outbound, nil, true
	}
	if configOutboundIsCustomFullConfig(outbound) {
		return "Custom full config profiles cannot be used in a chain; only custom outbound profiles are chainable",
			outbound, nil, true
	}
	outbounds := []any{}
	endpoints := []any{}
	if _, err := configBuildChain(builder.inputs.Profiles, builder.settings, []int64{id},
		configSelectorPoolChainPrefix, false, true, false, 0, &outbounds, &endpoints,
		builder.ctx.directDomainStrategy(), nil, nil); err != nil {
		return err.Error(), outbound, nil, true
	}
	object := map[string]any(nil)
	if len(outbounds) > 0 {
		object, _ = outbounds[0].(map[string]any)
	} else if len(endpoints) > 0 {
		object, _ = endpoints[0].(map[string]any)
	}
	return "", outbound, object, false
}

// buildWarpInFrontOfSelector is buildWarpInFrontOfSelector (:1779-1792): the
// group holds warp-bypass, so WARP is `proxy` dialing through it.
func (builder *configBuilder) buildWarpInFrontOfSelector() error {
	warp := configWarpOutbound(builder.settings)
	object, err := configBuildOutbound(warp, builder.settings)
	if err != nil {
		return err
	}
	object["tag"] = tagProxy
	object["detour"] = tagWarpBypass
	if configOutboundIsEndpoint(warp) {
		builder.endpoints = append(builder.endpoints, object)
	} else {
		builder.outbounds = append(builder.outbounds, object)
	}
	return nil
}
