// The `configBuild` action: registration, the exact BoxInstance.loadConfig
// reply shape, the RecordingProfiles port (involvedProfileIds), the mode
// override, the custom-full-config defer flag and the no-write contract.
package mobile

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"testing"
	"time"
)

// configBuildActionWire sends one action through the real dispatcher (RunAction)
// and answers the decoded data object plus the result code. An error reply is
// decoded by configBuildActionError instead, since its data is a JSON string.
func configBuildActionWire(t *testing.T, payload string) (map[string]json.RawMessage, int) {
	t.Helper()
	encoded := RunAction(`{"id":"build-1","method":"configBuild","data":` + payload + `}`)
	var answer struct {
		ID   string          `json:"id"`
		Code int             `json:"code"`
		Data json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal([]byte(encoded), &answer); err != nil {
		t.Fatalf("decode action result: %v (%s)", err, encoded)
	}
	if answer.ID != "build-1" {
		t.Fatalf("action result id = %q, want build-1", answer.ID)
	}
	if answer.Code != actionCodeSuccess {
		return nil, answer.Code
	}
	var data map[string]json.RawMessage
	if err := json.Unmarshal(answer.Data, &data); err != nil {
		t.Fatalf("decode configBuild reply: %v (%s)", err, answer.Data)
	}
	return data, answer.Code
}

// configBuildActionError is configBuildActionWire for a reply that must fail,
// returning the dispatcher's message.
func configBuildActionError(t *testing.T, payload string) string {
	t.Helper()
	encoded := RunAction(`{"id":"build-1","method":"configBuild","data":` + payload + `}`)
	var answer struct {
		Code int    `json:"code"`
		Data string `json:"data"`
	}
	if err := json.Unmarshal([]byte(encoded), &answer); err != nil {
		t.Fatalf("decode action result: %v (%s)", err, encoded)
	}
	if answer.Code != actionCodeError {
		t.Fatalf("action code = %d, want an error (%s)", answer.Code, encoded)
	}
	return answer.Data
}

// configBuildReplyDecode decodes one successful reply into the Kotlin
// StartOptions shape.
func configBuildReplyDecode(t *testing.T, data map[string]json.RawMessage) (string, bool, []int64) {
	t.Helper()
	var reply configBuildReply
	encoded, err := json.Marshal(data)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(encoded, &reply); err != nil {
		t.Fatalf("decode configBuildReply: %v (%s)", err, encoded)
	}
	return reply.CoreConfig, reply.DeferRuleSets, reply.InvolvedProfileIDs
}

func writeConfigBuildFixture(t *testing.T, profiles string, settings map[string]string, rules string) string {
	t.Helper()
	base := withConfigInputBase(t)
	writeDocumentFixture(t, base, profilesDocumentName, profiles)
	writeSettingsFixture(t, base, settings)
	// The production action reads the selection document only (ADR 0008 S4).
	// The fixture's settings profile id is the settled selection Dart would
	// have projected; current_group defaults to 0 when the case sets none.
	if selected := settings["profileId"]; selected != "" {
		group := settings["current_group"]
		if group == "" {
			group = "0"
		}
		writeDocumentFixture(t, base, profileSelectionDocumentName,
			`{"version":1,"selectedProfileId":`+selected+`,"currentGroupId":`+group+`,"updatedAt":1700000000123}`)
	}
	writeGlobalRulesFixture(t, base, rules)
	writeSrsListFixture(t, base, "")
	return base
}

// baseSettingsJSON builds a settings row for the action fixture.
func baseSettingsJSON(t *testing.T, profileID string, extra map[string]string) map[string]string {
	t.Helper()
	values := map[string]string{
		"profileId":          profileID,
		"serviceMode":        "proxy",
		"inbound_socks_port": "1080",
		"log_level":          "info",
	}
	for key, value := range extra {
		values[key] = value
	}
	return values
}

const configBuildRouteChainProfiles = `{
  "version": 1,
  "nextProfileId": 7,
  "nextGroupId": 8,
  "profiles": [
    {"id": 1, "type": "shadowsocks", "name": "Selected", "gid": 7, "user_order": 0,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.10\",\"server_port\":8388,\"method\":\"aes-256-gcm\",\"password\":\"selected\"}"},
    {"id": 2, "type": "shadowsocks", "name": "Hop A", "gid": 0, "user_order": 1,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.11\",\"server_port\":8389,\"method\":\"aes-256-gcm\",\"password\":\"hop-a\"}"},
    {"id": 3, "type": "shadowsocks", "name": "Hop B", "gid": 0, "user_order": 2,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.12\",\"server_port\":8390,\"method\":\"aes-256-gcm\",\"password\":\"hop-b\"}"},
    {"id": 4, "type": "chain", "name": "Route chain", "gid": 0, "user_order": 3,
     "outbound_json": "{\"type\":\"chain\",\"list\":[2,3]}"},
    {"id": 5, "type": "http", "name": "Landing", "gid": 0, "user_order": 4,
     "outbound_json": "{\"type\":\"http\",\"server\":\"198.51.100.13\",\"server_port\":8443,\"username\":\"user\",\"password\":\"pass\"}"},
    {"id": 6, "type": "socks", "name": "Front", "gid": 0, "user_order": 5,
     "outbound_json": "{\"type\":\"socks\",\"server\":\"198.51.100.14\",\"server_port\":1080,\"version\":\"5\"}"}
  ],
  "groups": [
    {"id": 7, "name": "Main", "display_order": 0, "landing_proxy_id": 5, "front_proxy_id": 6}
  ]
}`

const configBuildRouteChainRules = `[
  {"id": 1, "rule_order": 0, "name": "chain route", "type": 0, "action": "route",
   "outbound_id": 4, "domain_json": "[\"example.com\"]"}
]`

const configBuildSelectedChainProfiles = `{
  "version": 1,
  "nextProfileId": 7,
  "nextGroupId": 8,
  "profiles": [
    {"id": 1, "type": "chain", "name": "Selected chain", "gid": 7, "user_order": 0,
     "outbound_json": "{\"type\":\"chain\",\"list\":[2,3]}"},
    {"id": 2, "type": "shadowsocks", "name": "Hop A", "gid": 0, "user_order": 1,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.11\",\"server_port\":8389,\"method\":\"aes-256-gcm\",\"password\":\"hop-a\"}"},
    {"id": 3, "type": "shadowsocks", "name": "Hop B", "gid": 0, "user_order": 2,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.12\",\"server_port\":8390,\"method\":\"aes-256-gcm\",\"password\":\"hop-b\"}"},
    {"id": 5, "type": "http", "name": "Landing", "gid": 0, "user_order": 3,
     "outbound_json": "{\"type\":\"http\",\"server\":\"198.51.100.13\",\"server_port\":8443,\"username\":\"user\",\"password\":\"pass\"}"},
    {"id": 6, "type": "socks", "name": "Front", "gid": 0, "user_order": 4,
     "outbound_json": "{\"type\":\"socks\",\"server\":\"198.51.100.14\",\"server_port\":1080,\"version\":\"5\"}"}
  ],
  "groups": [
    {"id": 7, "name": "Main", "display_order": 0, "landing_proxy_id": 5, "front_proxy_id": 6}
  ]
}`

const configBuildSelectorProfiles = `{
  "version": 1,
  "nextProfileId": 10,
  "nextGroupId": 3,
  "profiles": [
    {"id": 1, "type": "autoselector", "name": "Selector", "gid": 0, "user_order": 0,
     "outbound_json": "{\"type\":\"autoselector\",\"gids\":[1,2]}"},
    {"id": 2, "type": "shadowsocks", "name": "Node Alpha", "gid": 1, "user_order": 0,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.21\",\"server_port\":8388,\"method\":\"aes-256-gcm\",\"password\":\"alpha\"}"},
    {"id": 3, "type": "shadowsocks", "name": "Node Bravo", "gid": 1, "user_order": 1,
     "outbound_json": "{\"type\":\"shadowsocks\",\"server\":\"198.51.100.22\",\"server_port\":8389,\"method\":\"aes-256-gcm\",\"password\":\"bravo\"}"},
    {"id": 4, "type": "http", "name": "Node Charlie", "gid": 2, "user_order": 0,
     "outbound_json": "{\"type\":\"http\",\"server\":\"198.51.100.23\",\"server_port\":8443,\"username\":\"user\",\"password\":\"pass\"}"},
    {"id": 5, "type": "http", "name": "Not a member", "gid": 0, "user_order": 1,
     "outbound_json": "{\"type\":\"http\",\"server\":\"198.51.100.24\",\"server_port\":8443,\"username\":\"user\",\"password\":\"pass\"}"},
    {"id": 6, "type": "http", "name": "Landing One", "gid": 0, "user_order": 2,
     "outbound_json": "{\"type\":\"http\",\"server\":\"198.51.100.25\",\"server_port\":8443,\"username\":\"user\",\"password\":\"pass\"}"},
    {"id": 7, "type": "socks", "name": "Front One", "gid": 0, "user_order": 3,
     "outbound_json": "{\"type\":\"socks\",\"server\":\"198.51.100.26\",\"server_port\":1080,\"version\":\"5\"}"},
    {"id": 8, "type": "http", "name": "Landing Two", "gid": 0, "user_order": 4,
     "outbound_json": "{\"type\":\"http\",\"server\":\"198.51.100.27\",\"server_port\":8443,\"username\":\"user\",\"password\":\"pass\"}"},
    {"id": 9, "type": "socks", "name": "Front Two", "gid": 0, "user_order": 5,
     "outbound_json": "{\"type\":\"socks\",\"server\":\"198.51.100.28\",\"server_port\":1080,\"version\":\"5\"}"}
  ],
  "groups": [
    {"id": 1, "name": "Group One", "display_order": 0, "landing_proxy_id": 6, "front_proxy_id": 7},
    {"id": 2, "name": "Group Two", "display_order": 1, "landing_proxy_id": 8, "front_proxy_id": 9}
  ]
}`

func TestConfigBuildActionIsRegistered(t *testing.T) {
	if configBuildMethod != Method("configBuild") {
		t.Fatalf("wire name = %q, want configBuild", configBuildMethod)
	}
	if actionHandlers[configBuildMethod] == nil {
		t.Fatal("configBuild has no registered handler")
	}
}

func TestConfigBuildActionReplyShape(t *testing.T) {
	writeConfigBuildFixture(t, `{
	  "version": 1,
	  "profiles": [{"id": 1, "type": "direct", "name": "direct out", "gid": 0, "outbound_json": "{\"type\":\"direct\"}"}],
	  "groups": []
	}`, baseSettingsJSON(t, "1", nil), `[]`)

	data, code := configBuildActionWire(t, `{}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d", code)
	}

	// Exactly the three keys BoxInstance.loadConfig reports; no routeId, no extras.
	keys := make([]string, 0, len(data))
	for key := range data {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	if want := []string{"coreConfig", "deferRuleSets", "involvedProfileIds"}; !reflect.DeepEqual(keys, want) {
		t.Fatalf("reply keys = %v, want %v", keys, want)
	}
	var coreConfig string
	if err := json.Unmarshal(data["coreConfig"], &coreConfig); err != nil || coreConfig == "" {
		t.Fatalf("coreConfig = %q (err %v)", coreConfig, err)
	}
	var deferRuleSets bool
	if err := json.Unmarshal(data["deferRuleSets"], &deferRuleSets); err != nil {
		t.Fatalf("deferRuleSets is not a bool: %s", data["deferRuleSets"])
	}
	if deferRuleSets {
		t.Fatal("startWithoutRuleSets is absent; deferRuleSets must be false")
	}
	var involved []int64
	if err := json.Unmarshal(data["involvedProfileIds"], &involved); err != nil {
		t.Fatalf("involvedProfileIds is not an int list: %s", data["involvedProfileIds"])
	}
	if want := []int64{1}; !reflect.DeepEqual(involved, want) {
		t.Fatalf("involvedProfileIds = %v, want %v", involved, want)
	}
	if encoded := string(data["involvedProfileIds"]); encoded == "null" {
		t.Fatal("involvedProfileIds must be an array, never null")
	}
}

// The action's coreConfig must be the golden builder's bytes: it calls the same
// builder over the same inputs.
func TestConfigBuildActionMatchesGoldenBuilder(t *testing.T) {
	writeConfigBuildFixture(t, configBuildRouteChainProfiles,
		baseSettingsJSON(t, "1", map[string]string{"startWithoutRuleSets": "1"}),
		configBuildRouteChainRules)

	data, code := configBuildActionWire(t, `{}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d", code)
	}
	actionConfig, deferRuleSets, _ := configBuildReplyDecode(t, data)

	inputs, err := loadSimpleConfigInputsAt(time.Now())
	if err != nil {
		t.Fatal(err)
	}
	golden, err := buildSimpleCoreConfig(inputs, configBuildRequestFromSelection(inputs))
	if err != nil {
		t.Fatalf("golden builder: %v", err)
	}
	if actionConfig != golden {
		t.Fatalf("configBuild coreConfig differs from buildSimpleCoreConfig (%d vs %d bytes)", len(actionConfig), len(golden))
	}
	if !deferRuleSets || !inputs.DeferRuleSets {
		t.Fatalf("deferRuleSets = %v/%v, want true from startWithoutRuleSets", deferRuleSets, inputs.DeferRuleSets)
	}
}

// Every route outbound and its chain hops are read during the prerequisites,
// then the main chain's landing / front pair: RecordingProfiles' first-read
// order, exactly.
func TestConfigBuildInvolvedProfilesRouteChainAndGroupProxies(t *testing.T) {
	writeConfigBuildFixture(t, configBuildRouteChainProfiles, baseSettingsJSON(t, "1", nil), configBuildRouteChainRules)

	data, code := configBuildActionWire(t, `{}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d", code)
	}
	_, _, involved := configBuildReplyDecode(t, data)
	if want := []int64{1, 4, 2, 3, 5, 6}; !reflect.DeepEqual(involved, want) {
		t.Fatalf("involvedProfileIds = %v, want %v", involved, want)
	}
}

// A selected chain contributes its hops in exit-first order, after the group's
// landing proxy.
func TestConfigBuildInvolvedProfilesSelectedChain(t *testing.T) {
	writeConfigBuildFixture(t, configBuildSelectedChainProfiles, baseSettingsJSON(t, "1", nil), `[]`)

	data, code := configBuildActionWire(t, `{}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d", code)
	}
	_, _, involved := configBuildReplyDecode(t, data)
	if want := []int64{1, 5, 3, 2, 6}; !reflect.DeepEqual(involved, want) {
		t.Fatalf("involvedProfileIds = %v, want %v", involved, want)
	}
}

// An auto selector records every build member first (rejectedMembers reads them
// all before any chain is built), then each member's own group landing / front
// pair. Non-members never appear.
func TestConfigBuildInvolvedProfilesAutoSelector(t *testing.T) {
	writeConfigBuildFixture(t, configBuildSelectorProfiles, baseSettingsJSON(t, "1", nil), `[]`)

	data, code := configBuildActionWire(t, `{}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d", code)
	}
	_, _, involved := configBuildReplyDecode(t, data)
	if want := []int64{1, 2, 3, 4, 6, 7, 8, 9}; !reflect.DeepEqual(involved, want) {
		t.Fatalf("involvedProfileIds = %v, want %v", involved, want)
	}
}

// A custom full config is the whole core config: only the selected profile is
// read, and BoxInstance reports deferRuleSets=false even when the setting asks
// for a deferred start.
func TestConfigBuildActionCustomFullConfig(t *testing.T) {
	const profiles = `{
	  "version": 1,
	  "profiles": [{"id": 1, "type": "custom", "name": "Full", "gid": 0, "outbound_json":
	    "{\"type\":\"custom\",\"subtype\":\"fullconfig\",\"config\":\"{\\\"log\\\":{\\\"level\\\":\\\"warn\\\"}}\"}"}],
	  "groups": []
	}`
	writeConfigBuildFixture(t, profiles,
		baseSettingsJSON(t, "1", map[string]string{"startWithoutRuleSets": "1"}), `[]`)

	data, code := configBuildActionWire(t, `{}`)
	if code != actionCodeSuccess {
		t.Fatalf("action code = %d", code)
	}
	coreConfig, deferRuleSets, involved := configBuildReplyDecode(t, data)
	if deferRuleSets {
		t.Fatal("a custom full config must report deferRuleSets=false")
	}
	if want := []int64{1}; !reflect.DeepEqual(involved, want) {
		t.Fatalf("involvedProfileIds = %v, want %v", involved, want)
	}
	var core map[string]any
	if err := json.Unmarshal([]byte(coreConfig), &core); err != nil {
		t.Fatalf("coreConfig is not JSON: %v", err)
	}
	if log, _ := core["log"].(map[string]any); log["level"] != "warn" {
		t.Fatalf("coreConfig is not the custom full config: %s", coreConfig)
	}
}

// The optional mode override changes only the service mode the builder sees:
// the same documents build the proxy (mixed inbound, no tun) or the VPN
// (tun inbound) config.
func TestConfigBuildActionModeOverride(t *testing.T) {
	writeConfigBuildFixture(t, `{
	  "version": 1,
	  "profiles": [{"id": 1, "type": "direct", "name": "direct out", "gid": 0, "outbound_json": "{\"type\":\"direct\"}"}],
	  "groups": []
	}`, baseSettingsJSON(t, "1", map[string]string{
		"serviceMode":           "vpn",
		"disable_mixed_inbound": "true",
	}), `[]`)

	inboundTags := func(payload string) []string {
		t.Helper()
		data, code := configBuildActionWire(t, payload)
		if code != actionCodeSuccess {
			t.Fatalf("%s: action code = %d", payload, code)
		}
		coreConfig, _, _ := configBuildReplyDecode(t, data)
		var core struct {
			Inbounds []struct {
				Tag string `json:"tag"`
			} `json:"inbounds"`
		}
		if err := json.Unmarshal([]byte(coreConfig), &core); err != nil {
			t.Fatalf("%s: coreConfig is not JSON: %v", payload, err)
		}
		tags := make([]string, 0, len(core.Inbounds))
		for _, inbound := range core.Inbounds {
			tags = append(tags, inbound.Tag)
		}
		sort.Strings(tags)
		return tags
	}

	if got := inboundTags(`{}`); !reflect.DeepEqual(got, []string{tagDNSIn, tagTunIn}) {
		t.Fatalf("vpn-mode inbounds = %v, want [%s %s]", got, tagDNSIn, tagTunIn)
	}
	if got := inboundTags(`{"mode":"proxy"}`); !reflect.DeepEqual(got, []string{tagDNSIn, tagMixedIn}) {
		t.Fatalf("proxy-mode inbounds = %v, want [%s %s]", got, tagDNSIn, tagMixedIn)
	}
}

func TestConfigBuildActionRejectsUnknownMode(t *testing.T) {
	writeConfigBuildFixture(t, `{
	  "version": 1,
	  "profiles": [{"id": 1, "type": "direct", "name": "direct out", "gid": 0, "outbound_json": "{\"type\":\"direct\"}"}],
	  "groups": []
	}`, baseSettingsJSON(t, "1", nil), `[]`)

	message := configBuildActionError(t, `{"mode":"tun"}`)
	if want := `config.build: mode must be "vpn" or "proxy", not "tun"`; message != want {
		t.Fatalf("error = %q, want %q", message, want)
	}
}

// Requirement: `deferRuleSets` is read from the inputs without consuming the
// consent marker, and the whole action writes nothing. The document keeps its
// fresh timestamp and every file keeps its bytes, mode and mtime.
func TestConfigBuildActionReadsWithoutWriting(t *testing.T) {
	base := withConfigInputBase(t)
	fresh := time.Now().UnixMilli()
	paths := []string{
		writeDocumentFixture(t, base, profilesDocumentName, configBuildRouteChainProfiles),
		writeSettingsFixture(t, base, baseSettingsJSON(t, "1", map[string]string{
			"startWithoutRuleSets": strconv.FormatInt(fresh, 10),
		})),
		writeDocumentFixture(t, base, profileSelectionDocumentName,
			`{"version":1,"selectedProfileId":1,"currentGroupId":7,"updatedAt":1700000000123}`),
		writeGlobalRulesFixture(t, base, configBuildRouteChainRules),
		writeSrsListFixture(t, base, ""),
	}
	before := snapshotFiles(t, paths)
	documentsBefore := directoryNames(t, filepath.Join(base, documentsDirName))
	routeProfilesBefore := directoryNames(t, filepath.Join(base, routeProfilesDirName))

	for attempt := 0; attempt < 3; attempt++ {
		data, code := configBuildActionWire(t, `{}`)
		if code != actionCodeSuccess {
			t.Fatalf("call %d: action code = %d", attempt, code)
		}
		_, deferRuleSets, _ := configBuildReplyDecode(t, data)
		if !deferRuleSets {
			t.Fatalf("call %d: a fresh consent timestamp must report deferRuleSets=true", attempt)
		}
	}

	after := snapshotFiles(t, paths)
	if !reflect.DeepEqual(before, after) {
		t.Fatalf("configBuild changed the documents:\nbefore %#v\nafter  %#v", before, after)
	}
	if got := directoryNames(t, filepath.Join(base, documentsDirName)); !reflect.DeepEqual(got, documentsBefore) {
		t.Fatalf("documents directory changed: %v -> %v", documentsBefore, got)
	}
	if got := directoryNames(t, filepath.Join(base, routeProfilesDirName)); !reflect.DeepEqual(got, routeProfilesBefore) {
		t.Fatalf("routeprofiles directory changed: %v -> %v", routeProfilesBefore, got)
	}
}

// A successful build that cannot reproduce Kotlin's involved set answers the
// typed error instead of an empty or guessed list.
func TestConfigInvolvedProfilesSnapshotRefusesIncompleteRecords(t *testing.T) {
	var missing *configProfileReads
	if _, err := missing.snapshot(1); !errors.Is(err, errConfigInvolvedProfiles) {
		t.Fatalf("nil recorder error = %v, want errConfigInvolvedProfiles", err)
	}

	empty := newConfigProfileReads()
	if _, err := empty.snapshot(1); !errors.Is(err, errConfigInvolvedProfiles) {
		t.Fatalf("empty recorder error = %v, want errConfigInvolvedProfiles", err)
	}

	wrongFirst := newConfigProfileReads()
	wrongFirst.record(2)
	if _, err := wrongFirst.snapshot(1); !errors.Is(err, errConfigInvolvedProfiles) {
		t.Fatalf("wrong-first-read error = %v, want errConfigInvolvedProfiles", err)
	}

	valid := newConfigProfileReads()
	valid.record(1)
	valid.record(4)
	valid.record(1)
	ids, err := valid.snapshot(1)
	if err != nil {
		t.Fatalf("valid snapshot: %v", err)
	}
	if want := []int64{1, 4}; !reflect.DeepEqual(ids, want) {
		t.Fatalf("snapshot = %v, want %v (first-read order, no duplicates)", ids, want)
	}
}

func TestConfigBuildActionRequestDefer(t *testing.T) {
	request, err := parseConfigBuildActionRequest([]byte(`{"deferRuleSets":true}`))
	if err != nil {
		t.Fatal(err)
	}
	if request.DeferRuleSets == nil || !*request.DeferRuleSets {
		t.Fatalf("deferRuleSets = %#v", request.DeferRuleSets)
	}
	// Absent means "use the document's answer" (config.prepare did not run or
	// the caller is the golden harness); an explicit false must survive.
	absent, err := parseConfigBuildActionRequest([]byte(`{}`))
	if err != nil || absent.DeferRuleSets != nil {
		t.Fatalf("absent deferRuleSets = %#v (err %v)", absent.DeferRuleSets, err)
	}
	explicitFalse, err := parseConfigBuildActionRequest([]byte(`{"deferRuleSets":false}`))
	if err != nil || explicitFalse.DeferRuleSets == nil || *explicitFalse.DeferRuleSets {
		t.Fatalf("false deferRuleSets = %#v (err %v)", explicitFalse.DeferRuleSets, err)
	}
}
