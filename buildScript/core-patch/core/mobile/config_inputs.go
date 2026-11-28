// Read-only inputs for a future Go config builder.
//
// The builder will generate a simple sing-box config from the same documents
// the Kotlin ConfigGenerator reads today:
//
//   - Dart owns documents/profiles.json (profiles and groups, Room column names);
//   - Go owns documents/global_route_rules.json (the single global rule table);
//   - Kotlin owns documents/settings.json (desktop-encoded key/value rows);
//   - routeprofiles/srslist.h is the read-only rule-set name to .srs URL map.
//
// This file only loads and types those inputs. It does NOT emit a sing-box
// config and it does NOT write any document: the only writer of profiles.json
// is Dart, of global_route_rules.json is Go's route action layer, and of
// settings.json is Kotlin (ADR 0006 — one file, one writer).
package mobile

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	settingsDocumentName = "settings"
	routeProfilesDirName = "routeprofiles"
	srsListFileName      = "srslist.h"
)

// serviceMode is DataStore.serviceMode (Key.SERVICE_MODE); the generated config
// needs it because only VPN mode has a tun inbound, and disable_mixed_inbound
// only applies there (DataStore.mixedInboundDisabled).
type serviceMode string

const (
	serviceModeVPN   serviceMode = "vpn"
	serviceModeProxy serviceMode = "proxy"
)

// outboundMode is FlroneMode.Mode (bbox_outbound_mode): rule keeps the route
// table, global sends everything to the selected profile, direct to direct.
type outboundMode string

const (
	outboundModeRule   outboundMode = "rule"
	outboundModeGlobal outboundMode = "global"
	outboundModeDirect outboundMode = "direct"
)

// simpleConfigProfile is one profiles.json row with only the fields a config
// build reads. The columns are Room's own names; outbound_json is the stored
// outbound object the future builder will parse.
type simpleConfigProfile struct {
	ID           int64
	Type         string
	Name         string
	GroupID      int64
	UserOrder    int64
	Latency      int
	LatencyAt    int64
	TestCountry  string
	OutboundJSON string
}

// simpleConfigGroup is one groups.json row. LandingProxyID / FrontProxyID are
// the group's landing / front proxy (CoreConfigs.groupProxies), -1 when unset.
type simpleConfigGroup struct {
	ID             int64
	Name           string
	DisplayOrder   int64
	LandingProxyID int64
	FrontProxyID   int64
	Single         bool
}

// simpleConfigSelection is the profile/group context of one build. Group is the
// selected profile's own group (CoreConfigs.buildMain calls groupProxies(
// profile.groupId)); Members is that group's nodes in list order
// (user_order, then id). CurrentGroupID is the current_group setting, exposed
// for the UI's tab context but deliberately not used to override the profile's
// group: the build follows the profile.
type simpleConfigSelection struct {
	Profile        simpleConfigProfile
	Group          simpleConfigGroup
	Members        []simpleConfigProfile
	CurrentGroupID int64
}

// simpleConfigRouteRule is one global_route_rules.json row, typed after
// RouteRule.kt / RouteJsonStore.fillRuleColumns. Disabled rules are kept in the
// input; the builder applies the same filter the Kotlin generator does.
type simpleConfigRouteRule struct {
	ID                       int64
	RuleOrder                int
	Name                     string
	Type                     int
	Disabled                 bool
	IPVersion                string
	Network                  string
	Protocol                 string
	Inbound                  []string
	Domain                   []string
	DomainSuffix             []string
	DomainKeyword            []string
	DomainRegex              []string
	SourceIPCIDR             []string
	SourceIPIsPrivate        bool
	IPCIDR                   []string
	IPIsPrivate              bool
	SourcePort               []string
	SourcePortRange          []string
	Port                     []string
	PortRange                []string
	ProcessName              []string
	ProcessPath              []string
	ProcessPathRegex         []string
	PackageName              []string
	PackageNameRegex         []string
	NetworkType              []string
	NetworkIsExpensive       bool
	WifiSSID                 []string
	WifiBSSID                []string
	RuleSet                  []string
	Invert                   bool
	OutboundID               int64
	Action                   string
	RejectMethod             string
	NoDrop                   bool
	OverrideAddress          string
	OverridePort             string
	TLSFragment              bool
	TLSFragmentFallbackDelay string
	TLSRecordFragment        bool
	TLSSpoof                 string
	TLSSpoofMethod           string
	Sniffers                 []string
	SniffOverrideDest        bool
	Strategy                 string
}

// simpleRuleSetEntry is one srslist.h `{"name", "url"}` pair.
type simpleRuleSetEntry struct {
	Name string
	URL  string
}

// simpleRuleSetCatalog is the read-only srslist.h catalog, first duplicate name
// winning like RuleSetCatalog.kt.
type simpleRuleSetCatalog struct {
	Path    string
	Entries []simpleRuleSetEntry
	index   map[string]string
}

func (catalog simpleRuleSetCatalog) Size() int {
	return len(catalog.Entries)
}

// Names returns the catalog names in file order.
func (catalog simpleRuleSetCatalog) Names() []string {
	names := make([]string, 0, len(catalog.Entries))
	for _, entry := range catalog.Entries {
		names = append(names, entry.Name)
	}
	return names
}

// URLOf resolves one rule-set name.
func (catalog simpleRuleSetCatalog) URLOf(name string) (string, bool) {
	url, ok := catalog.index[name]
	return url, ok
}

// Search mirrors RuleSetCatalog.search: exact, then prefix, then substring
// matches, case-insensitively, each in file order.
func (catalog simpleRuleSetCatalog) Search(query string, limit int) []simpleRuleSetEntry {
	if limit <= 0 {
		return nil
	}
	trimmed := strings.TrimSpace(query)
	if trimmed == "" {
		if limit > len(catalog.Entries) {
			limit = len(catalog.Entries)
		}
		return append([]simpleRuleSetEntry(nil), catalog.Entries[:limit]...)
	}
	lowered := strings.ToLower(trimmed)
	var exact, prefix, contains []simpleRuleSetEntry
	for _, entry := range catalog.Entries {
		name := strings.ToLower(entry.Name)
		switch {
		case name == lowered:
			exact = append(exact, entry)
		case strings.HasPrefix(name, lowered):
			prefix = append(prefix, entry)
		case strings.Contains(name, lowered):
			contains = append(contains, entry)
		}
	}
	matches := append(exact, prefix...)
	matches = append(matches, contains...)
	if len(matches) > limit {
		matches = matches[:limit]
	}
	return matches
}

// simpleConfigInputs is the complete read-only input set for one simple config
// build. DeferRuleSets mirrors the non-destructive half of
// DeferredRuleSets.consume: reading never spends a consent timestamp.
type simpleConfigInputs struct {
	Selection simpleConfigSelection
	// Profiles is every usable profiles.json row. It is deliberately not only
	// the selected group's members: route rules and chain hops can name any
	// profile id, so the builder needs the whole id -> outbound map.
	Profiles []simpleConfigProfile
	// Groups is the groups half of the same document: an auto-selector's
	// tracked groups are resolved here, with Room's column names.
	Groups         []row
	Settings       simpleConfigSettings
	Mode           serviceMode
	OutboundMode   outboundMode
	DeferRuleSets  bool
	RouteRules     []simpleConfigRouteRule
	RuleSetCatalog simpleRuleSetCatalog
	// MemberCheck is RoutingInput.memberCheck: the core's verdict on one built
	// auto-selector member (an empty string means accepted). Nil skips the core
	// check and leaves only the structural rejection, which is what the golden
	// oracle's RoutingInput does; the production action supplies CheckConfig.
	MemberCheck configMemberCheck
}

// configMemberCheck is the Go seam for RoutingInput.MemberCheck. object is the
// exact outbound/endpoint object the builder would emit for the member.
type configMemberCheck func(id int64, outbound configOutbound, object map[string]any) string

// loadSimpleConfigInputs reads the four documents from the kernel's base path.
// The caller must have called Setup first; a missing profiles.json is an error
// (Dart has not seeded it, and no other source exists), while a missing
// settings.json means defaults, a missing global route table means no rules,
// and a missing srslist.h means an empty catalog — the same meanings the Kotlin
// readers assign.
func loadSimpleConfigInputs() (*simpleConfigInputs, error) {
	return loadSimpleConfigInputsInternal(time.Now(), true)
}

// loadSimpleConfigInputsForTest is the buildTest entry: a test batch may run
// with no profiles at all (the subscription-filter DNS probe calls it with an
// empty candidate list), so the selected-profile requirement does not apply.
func loadSimpleConfigInputsForTest() (*simpleConfigInputs, error) {
	return loadSimpleConfigInputsInternal(time.Now(), false)
}

func loadSimpleConfigInputsAt(now time.Time) (*simpleConfigInputs, error) {
	return loadSimpleConfigInputsInternal(now, true)
}

func loadSimpleConfigInputsInternal(now time.Time, requireSelection bool) (*simpleConfigInputs, error) {
	profiles, err := readProfilesDocument()
	if err != nil {
		return nil, err
	}

	settingsRows, _, err := readDocument(settingsDocumentName)
	if err != nil {
		return nil, fmt.Errorf("read %s.json: %w", settingsDocumentName, err)
	}
	settingsValues := settingsRowsByKey(settingsRows)
	settings := loadSimpleConfigSettingsFromValues(settingsValues)
	allProfiles, err := simpleConfigProfilesFromDocument(profiles)
	if err != nil {
		if requireSelection || err.Error() != "profiles.json has no usable profiles" {
			return nil, err
		}
		allProfiles = []simpleConfigProfile{}
	}
	// ADR 0008 P1-5: prefer Dart's selection document; fall back to the
	// settings-based selection while migration has not written it yet. A
	// malformed selection file is a fallback, never a failed build.
	selection, err := simpleConfigSelectionFromInputs(allProfiles, profiles.Groups, settingsValues, true)
	if err != nil {
		if requireSelection {
			return nil, err
		}
		selection = simpleConfigSelection{}
	}

	routeRows, err := readGlobalRulesForConfig()
	if err != nil {
		return nil, fmt.Errorf("read %s.json: %w", globalRulesDoc, err)
	}
	routeRules := make([]simpleConfigRouteRule, 0, len(routeRows))
	for _, ruleRow := range routeRows {
		routeRules = append(routeRules, simpleConfigRouteRuleFromRow(ruleRow))
	}

	catalog, err := readSimpleRuleSetCatalog()
	if err != nil {
		return nil, err
	}

	mode := serviceMode(configSettingStringValue(settingsValues, "serviceMode"))
	if mode != serviceModeVPN && mode != serviceModeProxy {
		mode = serviceModeVPN
	}
	outbound := outboundMode(configSettingStringValue(settingsValues, "bbox_outbound_mode"))
	if outbound != outboundModeRule && outbound != outboundModeGlobal && outbound != outboundModeDirect {
		outbound = outboundModeRule
	}

	return &simpleConfigInputs{
		Selection:      selection,
		Profiles:       allProfiles,
		Groups:         profiles.Groups,
		Settings:       settings,
		Mode:           mode,
		OutboundMode:   outbound,
		DeferRuleSets:  deferRuleSetsFromSetting(configSettingLongValue(settingsValues, "startWithoutRuleSets"), now),
		RouteRules:     routeRules,
		RuleSetCatalog: catalog,
	}, nil
}

func simpleConfigProfilesFromDocument(profiles *profilesDocument) ([]simpleConfigProfile, error) {
	nodes := make([]simpleConfigProfile, 0, len(profiles.Profiles))
	for _, profileRow := range profiles.Profiles {
		if profile, ok := simpleConfigProfileFromRow(profileRow); ok {
			nodes = append(nodes, profile)
		}
	}
	if len(nodes) == 0 {
		return nil, errors.New("profiles.json has no usable profiles")
	}
	return nodes, nil
}

// simpleConfigSelectionFromInputs resolves the selection for a production
// build. `preferDocument` is true only here: the golden fixture loader calls
// simpleConfigSelectionFromProfiles directly (its case directories have no
// profile_selection.json) so fixtures stay byte-for-byte unchanged.
//
// MIGRATION SHIM (removed with profiles S4): Kotlin still writes selection to
// settings.json from paths that do not pass through Dart's dashboard/groups
// frames (widget, quick toggle, BaseService, subscription refresh, deletion
// fallback). The document is used only when its member id agrees with settings
// `profileId`, or when settings carries no selection at all (upgrade where
// settings was reset but the documents directory survived). A member-id
// disagreement means the document is stale; settings wins.
//
// The gate deliberately ignores `current_group`: settings.current_group is the
// group the UI is browsing, while the document's currentGroupId is the group
// holding the selected member — they legitimately differ, and gating on them
// would reject the document on most ordinary starts. CurrentGroupID has no
// consumer in the builder today (only the struct field and its assignment);
// when it gains one, S4 must revisit which source should win. Until then, in
// the agreement case keep the settings ids (including settings.current_group)
// verbatim; in the no-selection case use both document ids.
func simpleConfigSelectionFromInputs(nodes []simpleConfigProfile, groupRows []row, settingsValues map[string]string, preferDocument bool) (simpleConfigSelection, error) {
	selectedID := configSettingLongValue(settingsValues, "profileId")
	currentGroupID := configSettingLongValue(settingsValues, "current_group")
	if preferDocument {
		if dir, err := documentsDir(); err == nil {
			if doc, err := readProfileSelection(dir); err == nil && doc != nil {
				if selectedID <= 0 {
					// settings was reset; the document is the only source.
					selectedID = doc.SelectedProfileID
					currentGroupID = doc.CurrentGroupID
				} else if doc.SelectedProfileID == selectedID {
					// Agreement on the member that actually builds the config:
					// keep settings.current_group (the UI's browsed group). The
					// document's currentGroupId is not consulted here.
				}
				// Else: the document names a stale member against a fresher
				// Kotlin settings selection; keep the settings ids above.
			}
		}
	}
	return simpleConfigSelectionFromIDs(nodes, groupRows, selectedID, currentGroupID)
}

// simpleConfigSelectionFromProfiles resolves the selection from settings only.
// Kept as the fixture/legacy entry point; production goes through
// [simpleConfigSelectionFromInputs] so it can prefer the Dart document.
func simpleConfigSelectionFromProfiles(nodes []simpleConfigProfile, groupRows []row, settingsValues map[string]string) (simpleConfigSelection, error) {
	return simpleConfigSelectionFromIDs(nodes, groupRows,
		configSettingLongValue(settingsValues, "profileId"),
		configSettingLongValue(settingsValues, "current_group"))
}

// simpleConfigSelectionFromIDs is the shared resolver: a valid selected id
// picks that profile (a stale one falls back to the first usable profile, as
// FlroneKernel always did); the current group id is passed through for the UI.
func simpleConfigSelectionFromIDs(nodes []simpleConfigProfile, groupRows []row, selectedID, currentGroupID int64) (simpleConfigSelection, error) {
	if len(nodes) == 0 {
		return simpleConfigSelection{}, errors.New("profiles.json has no usable profiles")
	}
	// FlroneKernel.resolveProfile: selectedProxy, else the first profile. The
	// read-only layer cannot persist the fallback; it only reports the choice.
	selectedIndex := 0
	if selectedID > 0 {
		for index := range nodes {
			if nodes[index].ID == selectedID {
				selectedIndex = index
				break
			}
		}
	}
	selected := nodes[selectedIndex]

	group := simpleConfigGroup{ID: 0, LandingProxyID: -1, FrontProxyID: -1}
	if selected.GroupID > 0 {
		for _, groupRow := range groupRows {
			if rowInt64(groupRow, "id") == selected.GroupID {
				group = simpleConfigGroupFromRow(groupRow)
				break
			}
		}
	}

	members := make([]simpleConfigProfile, 0)
	if group.ID > 0 {
		for _, member := range nodes {
			if member.GroupID == group.ID {
				members = append(members, member)
			}
		}
		// profilesOfGroup sorts user_order then id; reproduce that order on the
		// already-typed rows without converting twice.
		sort.SliceStable(members, func(a, b int) bool {
			if members[a].UserOrder != members[b].UserOrder {
				return members[a].UserOrder < members[b].UserOrder
			}
			return members[a].ID < members[b].ID
		})
	}

	return simpleConfigSelection{
		Profile:        selected,
		Group:          group,
		Members:        members,
		CurrentGroupID: currentGroupID,
	}, nil
}

func simpleConfigProfileFromRow(profileRow row) (simpleConfigProfile, bool) {
	id := rowInt64(profileRow, "id")
	if id <= 0 {
		return simpleConfigProfile{}, false
	}
	return simpleConfigProfile{
		ID:           id,
		Type:         rowString(profileRow, "type"),
		Name:         rowString(profileRow, "name"),
		GroupID:      rowInt64(profileRow, "gid"),
		UserOrder:    rowInt64(profileRow, "user_order"),
		Latency:      rowInt(profileRow, "latency"),
		LatencyAt:    rowInt64(profileRow, "latency_at"),
		TestCountry:  rowString(profileRow, "test_country"),
		OutboundJSON: rowString(profileRow, "outbound_json"),
	}, true
}

func simpleConfigGroupFromRow(groupRow row) simpleConfigGroup {
	return simpleConfigGroup{
		ID:             rowInt64(groupRow, "id"),
		Name:           rowString(groupRow, "name"),
		DisplayOrder:   rowInt64(groupRow, "display_order"),
		LandingProxyID: rowInt64Fallback(groupRow, "landing_proxy_id", -1),
		FrontProxyID:   rowInt64Fallback(groupRow, "front_proxy_id", -1),
		Single:         rowBool(groupRow, "single"),
	}
}

// rowInt64Fallback is JSONObject.optLong(key, fallback): an absent row, a null
// or an unparseable text cell takes the fallback instead of looking like 0.
func rowInt64Fallback(ruleRow row, key string, fallback int64) int64 {
	value, present := ruleRow[key]
	if !present || value == nil {
		return fallback
	}
	if text, ok := value.(string); ok {
		parsed, err := strconv.ParseInt(strings.TrimSpace(text), 10, 64)
		if err != nil {
			return fallback
		}
		return parsed
	}
	return rowInt64(ruleRow, key)
}

// readGlobalRulesForConfig loads the one global rule table in rule_order order.
// readGlobalRulesLocked is the writer's read half, so the same lock protects a
// build from observing a mid-save table; the read itself never writes.
func readGlobalRulesForConfig() ([]row, error) {
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()
	rows, _, err := readGlobalRulesLocked()
	return rows, err
}

func simpleConfigRouteRuleFromRow(ruleRow row) simpleConfigRouteRule {
	return simpleConfigRouteRule{
		ID:                       rowInt64(ruleRow, "id"),
		RuleOrder:                rowInt(ruleRow, "rule_order"),
		Name:                     rowString(ruleRow, "name"),
		Type:                     rowInt(ruleRow, "type"),
		Disabled:                 rowBool(ruleRow, "disabled"),
		IPVersion:                rowString(ruleRow, "ip_version"),
		Network:                  rowString(ruleRow, "network"),
		Protocol:                 rowString(ruleRow, "protocol"),
		Inbound:                  rowStringList(ruleRow, "inbound_json"),
		Domain:                   rowStringList(ruleRow, "domain_json"),
		DomainSuffix:             rowStringList(ruleRow, "domain_suffix_json"),
		DomainKeyword:            rowStringList(ruleRow, "domain_keyword_json"),
		DomainRegex:              rowStringList(ruleRow, "domain_regex_json"),
		SourceIPCIDR:             rowStringList(ruleRow, "source_ip_cidr_json"),
		SourceIPIsPrivate:        rowBool(ruleRow, "source_ip_is_private"),
		IPCIDR:                   rowStringList(ruleRow, "ip_cidr_json"),
		IPIsPrivate:              rowBool(ruleRow, "ip_is_private"),
		SourcePort:               rowStringList(ruleRow, "source_port_json"),
		SourcePortRange:          rowStringList(ruleRow, "source_port_range_json"),
		Port:                     rowStringList(ruleRow, "port_json"),
		PortRange:                rowStringList(ruleRow, "port_range_json"),
		ProcessName:              rowStringList(ruleRow, "process_name_json"),
		ProcessPath:              rowStringList(ruleRow, "process_path_json"),
		ProcessPathRegex:         rowStringList(ruleRow, "process_path_regex_json"),
		PackageName:              rowStringList(ruleRow, "package_name_json"),
		PackageNameRegex:         rowStringList(ruleRow, "package_name_regex_json"),
		NetworkType:              rowStringList(ruleRow, "network_type_json"),
		NetworkIsExpensive:       rowBool(ruleRow, "network_is_expensive"),
		WifiSSID:                 rowStringList(ruleRow, "wifi_ssid_json"),
		WifiBSSID:                rowStringList(ruleRow, "wifi_bssid_json"),
		RuleSet:                  rowStringList(ruleRow, "rule_set_json"),
		Invert:                   rowBool(ruleRow, "invert"),
		OutboundID:               rowInt64Fallback(ruleRow, "outbound_id", -1),
		Action:                   rowString(ruleRow, "action"),
		RejectMethod:             rowString(ruleRow, "reject_method"),
		NoDrop:                   rowBool(ruleRow, "no_drop"),
		OverrideAddress:          rowString(ruleRow, "override_address"),
		OverridePort:             rowString(ruleRow, "override_port"),
		TLSFragment:              rowBool(ruleRow, "tls_fragment"),
		TLSFragmentFallbackDelay: rowString(ruleRow, "tls_fragment_fallback_delay"),
		TLSRecordFragment:        rowBool(ruleRow, "tls_record_fragment"),
		TLSSpoof:                 rowString(ruleRow, "tls_spoof"),
		TLSSpoofMethod:           rowString(ruleRow, "tls_spoof_method"),
		Sniffers:                 rowStringList(ruleRow, "sniffers_json"),
		SniffOverrideDest:        rowBool(ruleRow, "sniff_override_dest"),
		Strategy:                 rowString(ruleRow, "strategy"),
	}
}

// rowStringList decodes one JSON text column (`*_json`) into strings. A missing
// or malformed column is an empty list, matching the row readers' lenient reads;
// non-string elements become "" like JsonValues.toStringValue.
func rowStringList(ruleRow row, key string) []string {
	values := jsonList(rowString(ruleRow, key))
	result := make([]string, 0, len(values))
	for _, value := range values {
		text, _ := value.(string)
		result = append(result, text)
	}
	return result
}

var srsListEntryPattern = regexp.MustCompile(`\{\s*"([^"]+)"\s*,\s*"([^"]+)"\s*\}`)

// readSimpleRuleSetCatalog reads `<basePath>/routeprofiles/srslist.h`. The file
// is read-only input: missing is an empty catalog (a build with no rule-sets
// still works), unreadable is an error.
func readSimpleRuleSetCatalog() (simpleRuleSetCatalog, error) {
	base, _, _ := setupPaths()
	if base == "" {
		return simpleRuleSetCatalog{}, errors.New("kernel base path is not set; the host must call setup first")
	}
	return readSimpleRuleSetCatalogFile(filepath.Join(base, routeProfilesDirName, srsListFileName))
}

func readSimpleRuleSetCatalogFile(path string) (simpleRuleSetCatalog, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return simpleRuleSetCatalog{Path: path, Entries: []simpleRuleSetEntry{}, index: map[string]string{}}, nil
	}
	if err != nil {
		return simpleRuleSetCatalog{}, fmt.Errorf("read %s: %w", path, err)
	}
	return parseSimpleRuleSetCatalog(path, string(data)), nil
}

// parseSimpleRuleSetCatalog is RuleSetCatalog.parseSrsList: one regexp scan over
// the whole text (the Kotlin comment explains why one matcher matters on 32-bit
// devices), first duplicate name wins.
func parseSimpleRuleSetCatalog(path, text string) simpleRuleSetCatalog {
	entries := make([]simpleRuleSetEntry, 0)
	index := make(map[string]string)
	for _, match := range srsListEntryPattern.FindAllStringSubmatch(text, -1) {
		name, url := match[1], match[2]
		if _, exists := index[name]; exists {
			continue
		}
		index[name] = url
		entries = append(entries, simpleRuleSetEntry{Name: name, URL: url})
	}
	return simpleRuleSetCatalog{Path: path, Entries: entries, index: index}
}

// deferRuleSetsFromSetting is the read-only half of DeferredRuleSets.consume:
// 0 is off, the Android settings screen's persistent flag 1 is on, and an epoch
// timestamp counts while inside the five-minute consent window. The timestamp
// is NOT spent here; the caller that starts the core does that exactly once.
func deferRuleSetsFromSetting(raw int64, now time.Time) bool {
	if raw == 0 {
		return false
	}
	if raw <= 1 {
		return true
	}
	age := now.UnixMilli() - raw
	return age >= 0 && age <= (5*time.Minute).Milliseconds()
}
