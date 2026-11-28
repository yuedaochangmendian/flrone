// The read-only config input layer: document loading, selection/member order,
// route-rule order, the srslist catalog and the no-write contract.
package mobile

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"
)

const configInputsProfiles = `{
  "version": 1,
  "name": "profiles",
  "nextProfileId": 4,
  "nextGroupId": 9,
  "profiles": [
    {"id": 3, "type": "vless", "name": "node-c", "gid": 7, "user_order": 1, "outbound_json": "{\"server\":\"c\"}"},
    {"id": 1, "type": "shadowsocks", "name": "node-a", "gid": 7, "user_order": 0, "outbound_json": "{\"server\":\"a\"}"},
    {"id": 2, "type": "trojan", "name": "node-b", "gid": 8, "user_order": 0, "outbound_json": "{\"server\":\"b\"}"}
  ],
  "groups": [
    {"id": 8, "name": "Other", "display_order": 2, "landing_proxy_id": -1, "front_proxy_id": -1},
    {"id": 7, "name": "Main", "display_order": 1, "landing_proxy_id": 9, "front_proxy_id": 10, "single": true}
  ]
}`

const configInputsRules = `[
  {"id": 2, "rule_order": 1, "name": "second", "type": 0, "action": "route", "outbound_id": -1,
   "domain_json": "[\"example.com\"]", "disabled": true},
  {"id": 1, "rule_order": 0, "name": "first", "type": 0, "action": "reject", "outbound_id": -3,
   "port_json": "[\"80\",\"443\"]"}
]`

const configInputsSrsList = `#pragma once
#include <array>

{"geoip-cn", "https://example.test/geoip-cn.srs"}
{"geosite-cn", "https://example.test/geosite-cn.srs"}
{"geoip-cn", "https://example.test/duplicate.srs"}
`

func withConfigInputBase(t *testing.T) string {
	t.Helper()
	restoreSetup(t)
	base := t.TempDir()
	if err := Setup(&SetupOptions{
		BasePath:    base,
		WorkingPath: filepath.Join(base, "working"),
		TempPath:    filepath.Join(base, "temp"),
	}); err != nil {
		t.Fatal(err)
	}
	for _, dir := range []string{"documents", routeProfilesDirName} {
		if err := os.MkdirAll(filepath.Join(base, dir), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return base
}

func writeDocumentFixture(t *testing.T, base, name, content string) string {
	t.Helper()
	path := filepath.Join(base, "documents", name)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

type settingsFixtureRow struct {
	Key   string `json:"key"`
	Value string `json:"value"`
}

func settingsFixtureJSON(t *testing.T, values map[string]string) string {
	t.Helper()
	keys := make([]string, 0, len(values))
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	rows := make([]settingsFixtureRow, 0, len(keys))
	for _, key := range keys {
		rows = append(rows, settingsFixtureRow{Key: key, Value: values[key]})
	}
	payload, err := json.Marshal(map[string]any{
		"version": 1,
		"name":    "settings",
		"written": true,
		"rows":    rows,
	})
	if err != nil {
		t.Fatal(err)
	}
	return string(payload)
}

func writeSettingsFixture(t *testing.T, base string, values map[string]string) string {
	t.Helper()
	return writeDocumentFixture(t, base, settingsDocumentName+".json", settingsFixtureJSON(t, values))
}

func writeGlobalRulesFixture(t *testing.T, base, rows string) string {
	t.Helper()
	return writeDocumentFixture(t, base, globalRulesDoc+".json",
		`{"version":2,"name":"global_route_rules","rows":`+rows+`}`)
}

func writeSrsListFixture(t *testing.T, base, content string) string {
	t.Helper()
	path := filepath.Join(base, routeProfilesDirName, srsListFileName)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func profileIDs(profiles []simpleConfigProfile) []int64 {
	ids := make([]int64, 0, len(profiles))
	for _, profile := range profiles {
		ids = append(ids, profile.ID)
	}
	return ids
}

func TestLoadSimpleConfigInputs(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
	writeSettingsFixture(t, base, map[string]string{
		"profileId":            "3",
		"current_group":        "7",
		"serviceMode":          "proxy",
		"bbox_outbound_mode":   "global",
		"log_level":            "debug",
		"inbound_socks_port":   "1080",
		"vpn_mtu":              "1500",
		"remote_dns":           "https://1.1.1.1/dns-query",
		"dns_final_out":        "direct",
		"dns_predefined_rules": `["1.1.1.1 one.example"]`,
		"core_box_api_port":    "-9091",
		"core_box_clash_api":   "9090",
		"startWithoutRuleSets": "1",
	})
	writeGlobalRulesFixture(t, base, configInputsRules)
	writeSrsListFixture(t, base, configInputsSrsList)

	inputs, err := loadSimpleConfigInputsAt(time.Now())
	if err != nil {
		t.Fatalf("loadSimpleConfigInputs: %v", err)
	}

	if got := inputs.Selection.Profile; got.ID != 3 || got.Name != "node-c" || got.Type != "vless" ||
		got.GroupID != 7 || got.OutboundJSON != `{"server":"c"}` {
		t.Fatalf("selected profile = %#v", got)
	}
	if got := inputs.Selection.Group; got.ID != 7 || got.Name != "Main" ||
		got.LandingProxyID != 9 || got.FrontProxyID != 10 || !got.Single {
		t.Fatalf("selected group = %#v", got)
	}
	if got := profileIDs(inputs.Selection.Members); !reflect.DeepEqual(got, []int64{1, 3}) {
		t.Fatalf("members = %v, want [1 3] in user_order order", got)
	}
	if got := len(inputs.Profiles); got != 3 {
		t.Fatalf("all profiles = %d, want 3", got)
	}
	if inputs.Selection.CurrentGroupID != 7 {
		t.Fatalf("current group = %d", inputs.Selection.CurrentGroupID)
	}

	if inputs.Mode != serviceModeProxy {
		t.Fatalf("mode = %q", inputs.Mode)
	}
	if inputs.OutboundMode != outboundModeGlobal {
		t.Fatalf("outbound mode = %q", inputs.OutboundMode)
	}
	if !inputs.DeferRuleSets {
		t.Fatal("startWithoutRuleSets=1 must defer rule-sets")
	}
	if inputs.Settings.LogLevel != "debug" || inputs.Settings.InboundSocksPort != 1080 ||
		inputs.Settings.VPNMtu != 1500 || inputs.Settings.DNSFinalOut != "direct" ||
		inputs.Settings.CoreBoxAPIPort != -9091 || inputs.Settings.CoreBoxClashAPI != 9090 {
		t.Fatalf("settings not applied: %#v", inputs.Settings)
	}
	if !reflect.DeepEqual(inputs.Settings.DNSPredefinedRules, []string{"1.1.1.1 one.example"}) {
		t.Fatalf("dns predefined rules = %#v", inputs.Settings.DNSPredefinedRules)
	}

	if len(inputs.RouteRules) != 2 {
		t.Fatalf("route rules = %d, want 2", len(inputs.RouteRules))
	}
	if inputs.RouteRules[0].Name != "first" || inputs.RouteRules[0].RuleOrder != 0 ||
		inputs.RouteRules[0].Action != "reject" || inputs.RouteRules[0].OutboundID != -3 {
		t.Fatalf("first route rule (rule_order 0) = %#v", inputs.RouteRules[0])
	}
	if !reflect.DeepEqual(inputs.RouteRules[0].Port, []string{"80", "443"}) {
		t.Fatalf("first rule ports = %#v", inputs.RouteRules[0].Port)
	}
	if inputs.RouteRules[1].Name != "second" || inputs.RouteRules[1].RuleOrder != 1 ||
		!inputs.RouteRules[1].Disabled {
		t.Fatalf("second route rule (rule_order 1) = %#v", inputs.RouteRules[1])
	}
	if !reflect.DeepEqual(inputs.RouteRules[1].Domain, []string{"example.com"}) {
		t.Fatalf("second rule domains = %#v", inputs.RouteRules[1].Domain)
	}

	if got := inputs.RuleSetCatalog.Size(); got != 2 {
		t.Fatalf("catalog size = %d, want 2 (duplicate name kept once)", got)
	}
	if url, ok := inputs.RuleSetCatalog.URLOf("geoip-cn"); !ok || url != "https://example.test/geoip-cn.srs" {
		t.Fatalf("geoip-cn = %q, %v (the first entry must win)", url, ok)
	}
	if got := inputs.RuleSetCatalog.Names(); !reflect.DeepEqual(got, []string{"geoip-cn", "geosite-cn"}) {
		t.Fatalf("catalog names = %v", got)
	}
}

func TestLoadSimpleConfigInputsMissingOptionalDocuments(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, `{
	  "version": 1,
	  "profiles": [{"id": 5, "type": "direct", "name": "solo", "gid": 0, "outbound_json": "{}"}],
	  "groups": []
	}`)

	inputs, err := loadSimpleConfigInputsAt(time.Now())
	if err != nil {
		t.Fatalf("loadSimpleConfigInputs: %v", err)
	}
	if inputs.Selection.Profile.ID != 5 {
		t.Fatalf("selected profile = %#v", inputs.Selection.Profile)
	}
	if inputs.Selection.Group.ID != 0 || len(inputs.Selection.Members) != 0 {
		t.Fatalf("a gid-less profile must have no group/members: %#v", inputs.Selection)
	}
	if got, want := inputs.Settings, loadSimpleConfigSettings(nil); !reflect.DeepEqual(got, want) {
		t.Fatalf("missing settings.json must mean defaults:\n got %#v\nwant %#v", got, want)
	}
	if inputs.Mode != serviceModeVPN || inputs.OutboundMode != outboundModeRule {
		t.Fatalf("default mode = %q/%q", inputs.Mode, inputs.OutboundMode)
	}
	if inputs.DeferRuleSets {
		t.Fatal("missing startWithoutRuleSets must be false")
	}
	if len(inputs.RouteRules) != 0 {
		t.Fatalf("missing global rules = %d rows", len(inputs.RouteRules))
	}
	if inputs.RuleSetCatalog.Size() != 0 {
		t.Fatalf("missing srslist = %d entries", inputs.RuleSetCatalog.Size())
	}
}

func TestLoadSimpleConfigInputsMissingProfiles(t *testing.T) {
	withConfigInputBase(t)
	if _, err := loadSimpleConfigInputsAt(time.Now()); err == nil {
		t.Fatal("a missing profiles.json must be an error")
	} else if !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing profiles.json error = %v", err)
	}
}

func TestLoadSimpleConfigInputsRejectsNewerProfilesVersion(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName,
		`{"version":2,"profiles":[{"id":1,"type":"direct","gid":0,"outbound_json":"{}"}],"groups":[]}`)
	if _, err := loadSimpleConfigInputsAt(time.Now()); err == nil || !strings.Contains(err.Error(), "newer than this build") {
		t.Fatalf("newer profiles version error = %v", err)
	}
}

func TestLoadSimpleConfigInputsRejectsCorruptSettings(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName,
		`{"version":1,"profiles":[{"id":1,"type":"direct","gid":0,"outbound_json":"{}"}],"groups":[]}`)
	writeDocumentFixture(t, base, settingsDocumentName+".json", `{`)
	if _, err := loadSimpleConfigInputsAt(time.Now()); err == nil || !strings.Contains(err.Error(), "read settings.json") {
		t.Fatalf("corrupt settings error = %v", err)
	}
}

func TestLoadSimpleConfigInputsRejectsCorruptGlobalRules(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName,
		`{"version":1,"profiles":[{"id":1,"type":"direct","gid":0,"outbound_json":"{}"}],"groups":[]}`)
	writeDocumentFixture(t, base, globalRulesDoc+".json", `{`)
	if _, err := loadSimpleConfigInputsAt(time.Now()); err == nil || !strings.Contains(err.Error(), "global_route_rules.json") {
		t.Fatalf("corrupt global rules error = %v", err)
	}
}

type fileSnapshot struct {
	Data    []byte
	Mode    os.FileMode
	Size    int64
	ModTime time.Time
}

func snapshotFiles(t *testing.T, paths []string) map[string]fileSnapshot {
	t.Helper()
	snapshots := make(map[string]fileSnapshot, len(paths))
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		snapshots[path] = fileSnapshot{Data: data, Mode: info.Mode(), Size: info.Size(), ModTime: info.ModTime()}
	}
	return snapshots
}

func directoryNames(t *testing.T, dir string) []string {
	t.Helper()
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	return names
}

// Reading the whole input set must leave every document byte-for-byte intact:
// profiles.json belongs to Dart, settings.json to Kotlin and
// global_route_rules.json to this package's route writer. A reader that
// rewrites (or even normalises) one of them would be a second writer.
func TestConfigInputsReadWritesNothing(t *testing.T) {
	base := withConfigInputBase(t)
	paths := []string{
		writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles),
		writeSettingsFixture(t, base, map[string]string{
			"profileId":            "3",
			"current_group":        "7",
			"serviceMode":          "vpn",
			"log_level":            "info",
			"dns_predefined_rules": `["127.0.0.1 localhost"]`,
		}),
		writeGlobalRulesFixture(t, base, configInputsRules),
		writeSrsListFixture(t, base, configInputsSrsList),
	}
	before := snapshotFiles(t, paths)
	documentsBefore := directoryNames(t, filepath.Join(base, "documents"))
	routeProfilesBefore := directoryNames(t, filepath.Join(base, routeProfilesDirName))

	for attempt := 0; attempt < 3; attempt++ {
		if _, err := loadSimpleConfigInputsAt(time.Now()); err != nil {
			t.Fatalf("load %d: %v", attempt, err)
		}
	}

	after := snapshotFiles(t, paths)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("reading changed the documents:\nbefore %#v\nafter  %#v", before, after)
	}
	if got := directoryNames(t, filepath.Join(base, "documents")); !reflect.DeepEqual(got, documentsBefore) {
		t.Fatalf("documents directory changed: %v -> %v", documentsBefore, got)
	}
	if got := directoryNames(t, filepath.Join(base, routeProfilesDirName)); !reflect.DeepEqual(got, routeProfilesBefore) {
		t.Fatalf("routeprofiles directory changed: %v -> %v", routeProfilesBefore, got)
	}
}

func TestSettingsRowsLastDuplicateWins(t *testing.T) {
	values := settingsRowsByKey([]row{
		{"key": "log_level", "value": "debug"},
		{"key": "log_level", "value": "info"},
		{"key": "", "value": "ignored"},
	})
	if values["log_level"] != "info" {
		t.Fatalf("duplicate settings row = %q, want last value info", values["log_level"])
	}
	if len(values) != 1 {
		t.Fatalf("empty key must be skipped: %#v", values)
	}
}

func TestDeferRuleSetsFromSetting(t *testing.T) {
	now := time.Date(2026, 11, 27, 12, 0, 0, 0, time.UTC)
	nowMillis := now.UnixMilli()
	tests := []struct {
		name string
		raw  int64
		want bool
	}{
		{"missing/zero", 0, false},
		{"permanent flag", 1, true},
		{"negative timestamp-ish flag", -5, true}, // DeferredRuleSets.consume's at <= 1 branch
		{"fresh timestamp", nowMillis - 60_000, true},
		{"stale timestamp", nowMillis - 6*60_000, false},
		{"future timestamp", nowMillis + 1_000, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := deferRuleSetsFromSetting(test.raw, now); got != test.want {
				t.Fatalf("deferRuleSetsFromSetting(%d) = %v, want %v", test.raw, got, test.want)
			}
		})
	}
}

func TestSimpleRuleSetCatalogSearchMatchesKotlinOrder(t *testing.T) {
	catalog := parseSimpleRuleSetCatalog("srslist.h", `
		{"geoip-cn", "https://example.test/geoip-cn.srs"}
		{"geosite-cn", "https://example.test/geosite-cn.srs"}
		{"geosite-geolocation-cn", "https://example.test/geosite-geolocation-cn.srs"}
	`)
	if got := catalog.Search("geoip-cn", 10); len(got) != 1 || got[0].Name != "geoip-cn" {
		t.Fatalf("exact search = %#v", got)
	}
	matches := catalog.Search("GEOSITE", 10)
	names := make([]string, 0, len(matches))
	for _, match := range matches {
		names = append(names, match.Name)
	}
	if !reflect.DeepEqual(names, []string{"geosite-cn", "geosite-geolocation-cn"}) {
		t.Fatalf("prefix search order = %v", names)
	}
	if got := catalog.Search("site", 1); len(got) != 1 || got[0].Name != "geosite-cn" {
		t.Fatalf("limit search = %#v", got)
	}
	if got := catalog.Search("", 2); len(got) != 2 || got[0].Name != "geoip-cn" {
		t.Fatalf("empty search = %#v", got)
	}
}

// Guard the no-write test itself: bytes.Equal is the contract, and the
// snapshots must actually contain the fixtures rather than empty reads.
func TestConfigInputSnapshotsContainFixtureBytes(t *testing.T) {
	base := withConfigInputBase(t)
	path := writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
	snapshot := snapshotFiles(t, []string{path})[path]
	if len(snapshot.Data) == 0 || !bytes.Contains(snapshot.Data, []byte(`"profiles"`)) {
		t.Fatalf("snapshot did not read the fixture: %d bytes", len(snapshot.Data))
	}
}

// ADR 0008 P1-5: during migration the Dart-owned selection document is used
// only when its member id agrees with settings.json's profileId (or settings
// has no selection). A stale document must never override a fresher Kotlin
// settings selection from widget/quick-toggle/BaseService/subscription paths.
// current_group is deliberately not part of the gate (no builder consumer;
// settings' value is the browsed group). S4 drops this gate.

func TestProfileSelectionDocumentAgreesWithSettings(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
	writeSettingsFixture(t, base, map[string]string{
		"profileId":     "3",
		"current_group": "7",
	})
	writeDocumentFixture(t, base, profileSelectionDocumentName,
		`{"version":1,"selectedProfileId":3,"currentGroupId":7,"updatedAt":1700000000123}`)
	writeGlobalRulesFixture(t, base, `[]`)
	writeSrsListFixture(t, base, "")

	inputs, err := loadSimpleConfigInputsAt(time.Now())
	if err != nil {
		t.Fatalf("loadSimpleConfigInputs: %v", err)
	}
	if got := inputs.Selection.Profile.ID; got != 3 {
		t.Fatalf("selected profile = %d, want 3", got)
	}
	if got := inputs.Selection.CurrentGroupID; got != 7 {
		t.Fatalf("current group = %d, want 7", got)
	}
}

func TestProfileSelectionDocumentDisagreesWithSettings(t *testing.T) {
	// The migration gate compares only the member id. A differing
	// currentGroupId is legitimate (settings.current_group is the browsed tab;
	// the document's currentGroupId is the selected member's group) and must
	// NOT reject the document: member 3 is used, settings group 7 is retained.
	t.Run("group differs but member agrees", func(t *testing.T) {
		base := withConfigInputBase(t)
		writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
		writeSettingsFixture(t, base, map[string]string{
			"profileId":     "3",
			"current_group": "7",
		})
		writeDocumentFixture(t, base, profileSelectionDocumentName,
			`{"version":1,"selectedProfileId":3,"currentGroupId":8,"updatedAt":1700000000123}`)
		writeGlobalRulesFixture(t, base, `[]`)
		writeSrsListFixture(t, base, "")

		inputs, err := loadSimpleConfigInputsAt(time.Now())
		if err != nil {
			t.Fatalf("loadSimpleConfigInputs: %v", err)
		}
		if got := inputs.Selection.Profile.ID; got != 3 {
			t.Fatalf("selected profile = %d, want 3 (member agrees)", got)
		}
		if got := inputs.Selection.CurrentGroupID; got != 7 {
			t.Fatalf("current group = %d, want 7 from settings (UI browsed group)", got)
		}
	})

	// A stale member id is the one real disagreement: settings wins.
	for _, tc := range []struct {
		name     string
		document string
	}{
		{"member differs", `{"version":1,"selectedProfileId":1,"currentGroupId":7,"updatedAt":1700000000123}`},
		{"both differ", `{"version":1,"selectedProfileId":1,"currentGroupId":8,"updatedAt":1700000000123}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base := withConfigInputBase(t)
			writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
			writeSettingsFixture(t, base, map[string]string{
				"profileId":     "3",
				"current_group": "7",
			})
			writeDocumentFixture(t, base, profileSelectionDocumentName, tc.document)
			writeGlobalRulesFixture(t, base, `[]`)
			writeSrsListFixture(t, base, "")

			inputs, err := loadSimpleConfigInputsAt(time.Now())
			if err != nil {
				t.Fatalf("loadSimpleConfigInputs: %v", err)
			}
			if got := inputs.Selection.Profile.ID; got != 3 {
				t.Fatalf("selected profile = %d, want 3 from settings (document is stale)", got)
			}
			if got := inputs.Selection.CurrentGroupID; got != 7 {
				t.Fatalf("current group = %d, want 7 from settings (document is stale)", got)
			}
		})
	}
}

func TestProfileSelectionDocumentWithEmptySettings(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
	writeSettingsFixture(t, base, map[string]string{
		// No profileId / current_group: an upgrade where settings was reset but
		// the documents directory survived. The document wins.
	})
	writeDocumentFixture(t, base, profileSelectionDocumentName,
		`{"version":1,"selectedProfileId":1,"currentGroupId":7,"updatedAt":1700000000123}`)
	writeGlobalRulesFixture(t, base, `[]`)
	writeSrsListFixture(t, base, "")

	inputs, err := loadSimpleConfigInputsAt(time.Now())
	if err != nil {
		t.Fatalf("loadSimpleConfigInputs: %v", err)
	}
	if got := inputs.Selection.Profile.ID; got != 1 {
		t.Fatalf("selected profile = %d, want 1 from the document", got)
	}
	if got := inputs.Selection.CurrentGroupID; got != 7 {
		t.Fatalf("current group = %d, want 7 from the document", got)
	}
}

func TestProfileSelectionDocumentFallback(t *testing.T) {
	for _, tc := range []struct {
		name     string
		document string
	}{
		{"absent", ""},
		{"malformed JSON", `{`},
		{"wrong version", `{"version":2,"selectedProfileId":3,"currentGroupId":7,"updatedAt":1}`},
		{"missing selected id", `{"version":1,"currentGroupId":7,"updatedAt":1}`},
		{"negative selected id", `{"version":1,"selectedProfileId":-1,"currentGroupId":7,"updatedAt":1}`},
		{"negative current group", `{"version":1,"selectedProfileId":3,"currentGroupId":-1,"updatedAt":1}`},
		{"missing updatedAt", `{"version":1,"selectedProfileId":3,"currentGroupId":7}`},
		{"zero updatedAt", `{"version":1,"selectedProfileId":3,"currentGroupId":7,"updatedAt":0}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			base := withConfigInputBase(t)
			writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
			writeSettingsFixture(t, base, map[string]string{
				"profileId":     "3",
				"current_group": "7",
			})
			if tc.document != "" {
				writeDocumentFixture(t, base, profileSelectionDocumentName, tc.document)
			}
			writeGlobalRulesFixture(t, base, `[]`)
			writeSrsListFixture(t, base, "")

			inputs, err := loadSimpleConfigInputsAt(time.Now())
			if err != nil {
				t.Fatalf("malformed selection must not fail the build: %v", err)
			}
			if got := inputs.Selection.Profile.ID; got != 3 {
				t.Fatalf("selected profile = %d, want 3 from settings fallback", got)
			}
			if got := inputs.Selection.CurrentGroupID; got != 7 {
				t.Fatalf("current group = %d, want 7 from settings fallback", got)
			}
		})
	}
}

func TestProfileSelectionDocumentMissingProfileFallsBackToFirst(t *testing.T) {
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, configInputsProfiles)
	writeSettingsFixture(t, base, map[string]string{
		// No settings selection; a valid document naming a missing profile is
		// treated like the settings case today: fall back to the first usable
		// profile.
	})
	writeDocumentFixture(t, base, profileSelectionDocumentName,
		`{"version":1,"selectedProfileId":999,"currentGroupId":8,"updatedAt":1}`)
	writeGlobalRulesFixture(t, base, `[]`)
	writeSrsListFixture(t, base, "")

	inputs, err := loadSimpleConfigInputsAt(time.Now())
	if err != nil {
		t.Fatalf("loadSimpleConfigInputs: %v", err)
	}
	// profiles.json's first usable row is node-c (id 3) in the fixture.
	if got := inputs.Selection.Profile.ID; got != 3 {
		t.Fatalf("selected profile = %d, want first usable profile 3", got)
	}
}
