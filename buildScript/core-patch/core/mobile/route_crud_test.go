// The route profile CRUD the routing screen drives (ADR 0002, phase 3c, restored).
//
// These handlers were deleted with the routing UI that only added rules to the
// shared pool (#70 left six of them). The screen edits profiles again, so the
// round trips are pinned here: a save that loses a column, a delete that takes
// the last profile, or a current-profile marker that does not move all fail
// silently at runtime and are invisible to `gofmt`/CI compile.
//
// The document store is exercised for real (t.TempDir + writeDocument). The
// `settings` table belongs to the host — Room is its only writer — so no test
// here watches a SQL write. The contract test at the bottom asserts the stronger
// property instead: no production Go file in this package names `settings` in
// SQL at all. A per-call foreign connection against that WAL file can
// checkpoint/truncate it under Room's reader, which is exactly what surfaced as
// SQLITE_IOERR_SHORT_READ (522) when VpnService started reading a setting.
package mobile

import (
	"encoding/json"
	"os"
	"regexp"
	"strings"
	"testing"
)

// withRouteStore points the document store at a fresh temporary directory and
// restores the base path afterwards, so one test cannot see another's files.
func withRouteStore(t *testing.T) {
	t.Helper()
	previous := sBasePath
	sBasePath = t.TempDir()
	t.Cleanup(func() { sBasePath = previous })
}

// storedProfiles reads the profiles document back, so a test asserts on what a
// later handler would read rather than on the handler's own answer.
func storedProfiles(t *testing.T) []row {
	t.Helper()
	profiles, err := readDocument(routeProfilesDoc)
	if err != nil {
		t.Fatalf("read %s: %v", routeProfilesDoc, err)
	}
	return profiles
}

func storedRules(t *testing.T) []row {
	t.Helper()
	rules, err := readDocument(routeRulesDoc)
	if err != nil {
		t.Fatalf("read %s: %v", routeRulesDoc, err)
	}
	return rules
}

// storedProfile finds one profile by id. Handlers that seed go through
// readRouteState(true), so a fresh document set already holds the Default
// profile — assertions must name the row they mean instead of indexing.
func storedProfile(t *testing.T, id int64) row {
	t.Helper()
	profile := findProfile(storedProfiles(t), id)
	if profile == nil {
		t.Fatalf("no stored profile with id %d", id)
	}
	return profile
}

func callJSON(t *testing.T, handler actionHandler, payload string) (any, error) {
	t.Helper()
	if payload == "" {
		return handler(nil)
	}
	return handler(json.RawMessage(payload))
}

// --- save --------------------------------------------------------------------

func TestSaveRouteProfileRoundTripsEveryColumn(t *testing.T) {
	withRouteStore(t)

	// A profile with a non-default outbound, a remote URL and endpoint ids: the
	// fields a "replace the whole row" bug would drop.
	saved, err := callJSON(t, handleSaveRouteProfile, `{
		"id": 0,
		"name": "  Work  ",
		"defaultOutbound": "proxy",
		"isRemote": true,
		"remoteUrl": "  https://example.test/routing  ",
		"autoUpdate": true,
		"endpointIds": [7, 11],
		"rules": "domain:example.com -> proxy\nip:10.0.0.0/8 -> direct"
	}`)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	id, ok := saved.(int64)
	if !ok || id <= 0 {
		t.Fatalf("save must answer the new profile's id, got %#v", saved)
	}

	profiles := storedProfiles(t)
	// The seed profile (readRouteState(true) writes Default first) plus the new one.
	if len(profiles) != 2 {
		t.Fatalf("want the seed profile plus the new one, got %d", len(profiles))
	}
	profile := storedProfile(t, id)
	if got := rowString(profile, "name"); got != "Work" {
		t.Fatalf("name must be trimmed: want %q, got %q", "Work", got)
	}
	if got := rowInt64(profile, "default_outbound_id"); got != OutboundProxy {
		t.Fatalf("default outbound: want %d, got %d", OutboundProxy, got)
	}
	if !rowBool(profile, "is_remote") || !rowBool(profile, "auto_update") {
		t.Fatalf("remote flags lost: is_remote=%v auto_update=%v",
			profile["is_remote"], profile["auto_update"])
	}
	if got := rowString(profile, "remote_url"); got != "https://example.test/routing" {
		t.Fatalf("remote URL must be trimmed, got %q", got)
	}
	if got := rowString(profile, "endpoint_profile_ids"); got != "[7,11]" {
		t.Fatalf("endpoint ids: want [7,11], got %q", got)
	}

	// Two rule lines, one per (prefix, outbound): the text folds by target.
	rules := rulesOfProfile(storedRules(t), id)
	if len(rules) != 2 {
		t.Fatalf("want two rules, got %d", len(rules))
	}
	if got := jsonList(rowString(rules[0], "domain_json")); len(got) != 1 || got[0] != "example.com" {
		t.Fatalf("first rule must carry example.com, got %v", got)
	}
	if got := rowInt64(rules[0], "outbound_id"); got != OutboundProxy {
		t.Fatalf("first rule outbound: want proxy, got %d", got)
	}

	// The editor seed answers the same values the store holds.
	seed, err := callJSON(t, handleGetRouteProfile, `{"id":`+itoa(id)+`}`)
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	wire := seed.(map[string]any)
	if wire["name"] != "Work" || wire["defaultOutbound"] != "proxy" {
		t.Fatalf("seed disagrees with the store: %#v", wire)
	}
	if got := wire["endpointIds"].([]int64); len(got) != 2 || got[0] != 7 || got[1] != 11 {
		t.Fatalf("seed endpoint ids: %v", got)
	}
}

func TestSaveRouteProfileLeavesUntouchedFieldsAlone(t *testing.T) {
	withRouteStore(t)

	saved, err := callJSON(t, handleSaveRouteProfile,
		`{"id":0,"name":"Keep","remoteUrl":"https://example.test/p","isRemote":true}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := saved.(int64)

	// Renaming must not blank the remote URL: the editor only sends what changed.
	if _, err := callJSON(t, handleSaveRouteProfile, `{"id":`+itoa(id)+`,"name":"Renamed"}`); err != nil {
		t.Fatalf("rename: %v", err)
	}
	profile := storedProfile(t, id)
	if got := rowString(profile, "name"); got != "Renamed" {
		t.Fatalf("rename did not land: %q", got)
	}
	if got := rowString(profile, "remote_url"); got != "https://example.test/p" {
		t.Fatalf("rename blanked the remote URL: %q", got)
	}
	if !rowBool(profile, "is_remote") {
		t.Fatal("rename cleared is_remote")
	}
}

func TestSaveRouteProfileRefusesRawProfiles(t *testing.T) {
	withRouteStore(t)
	if err := writeDocument(routeProfilesDoc, []row{
		{"id": int64(1), "name": "Raw", "is_raw": true},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := callJSON(t, handleSaveRouteProfile, `{"id":1,"name":"Edited"}`); err == nil {
		t.Fatal("a raw profile must refuse the save")
	}
	if got := rowString(storedProfile(t, 1), "name"); got != "Raw" {
		t.Fatalf("a refused save must not write: %q", got)
	}
}

func TestSaveRouteProfileRejectsABadRuleLine(t *testing.T) {
	withRouteStore(t)
	saved, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"P"}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := saved.(int64)
	if _, err := callJSON(t, handleSaveRouteProfile,
		`{"id":`+itoa(id)+`,"rules":"nosuchprefix:value -> proxy"}`); err == nil {
		t.Fatal("an unknown prefix must reject the whole save")
	}
	if rules := rulesOfProfile(storedRules(t), id); len(rules) != 0 {
		t.Fatalf("a rejected save must not write rules, got %d", len(rules))
	}
}

// --- delete ------------------------------------------------------------------

func TestDeleteRouteProfileRefusesTheLastOne(t *testing.T) {
	withRouteStore(t)

	// Seeded directly: `save` would first write the Default profile, and then the
	// candidate would not be the last one.
	if err := writeDocument(routeProfilesDoc, []row{{"id": int64(1), "name": "Only"}}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := callJSON(t, handleDeleteRouteProfile, `{"id":1}`); err == nil {
		t.Fatal("deleting the last profile must be refused")
	}
	if got := len(storedProfiles(t)); got != 1 {
		t.Fatalf("the refused delete must not write, got %d profiles", got)
	}
}

func TestDeleteRouteProfileDropsItsRules(t *testing.T) {
	withRouteStore(t)

	first, err := callJSON(t, handleSaveRouteProfile,
		`{"id":0,"name":"First","rules":"domain:one.test -> proxy"}`)
	if err != nil {
		t.Fatalf("create first: %v", err)
	}
	second, err := callJSON(t, handleSaveRouteProfile,
		`{"id":0,"name":"Second","rules":"domain:two.test -> proxy"}`)
	if err != nil {
		t.Fatalf("create second: %v", err)
	}
	firstID, secondID := first.(int64), second.(int64)

	if _, err := callJSON(t, handleDeleteRouteProfile, `{"id":`+itoa(firstID)+`}`); err != nil {
		t.Fatalf("delete: %v", err)
	}
	profiles := storedProfiles(t)
	if len(profiles) != 2 || findProfile(profiles, secondID) == nil || findProfile(profiles, firstID) != nil {
		t.Fatalf("the deleted profile must be gone and the other two kept: %v", profiles)
	}
	if rules := rulesOfProfile(storedRules(t), firstID); len(rules) != 0 {
		t.Fatalf("the deleted profile's rules survived: %d", len(rules))
	}
	if rules := rulesOfProfile(storedRules(t), secondID); len(rules) != 1 {
		t.Fatalf("the surviving profile lost its rules: %d", len(rules))
	}
}

func TestDeleteRouteProfileRefusesRaw(t *testing.T) {
	withRouteStore(t)
	if err := writeDocument(routeProfilesDoc, []row{
		{"id": int64(1), "name": "Raw", "is_raw": true},
		{"id": int64(2), "name": "Mine"},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := callJSON(t, handleDeleteRouteProfile, `{"id":1}`); err == nil {
		t.Fatal("a raw profile must refuse the delete")
	}
	if got := len(storedProfiles(t)); got != 2 {
		t.Fatalf("the refused delete must not write, got %d", got)
	}
}

// --- current -----------------------------------------------------------------

// The selection is a document write and nothing else: the host owns the
// authoritative `settings.current_route_id` row and writes it over the channel
// before calling this handler (see the contract test at the bottom of the file).
func TestSetCurrentWritesOnlyTheDocumentMarker(t *testing.T) {
	withRouteStore(t)

	first, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"First"}`)
	if err != nil {
		t.Fatalf("create first: %v", err)
	}
	second, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"Second"}`)
	if err != nil {
		t.Fatalf("create second: %v", err)
	}
	firstID, secondID := first.(int64), second.(int64)

	answer, err := callJSON(t, handleSetCurrentRoute, `{"id":`+itoa(secondID)+`}`)
	if err != nil {
		t.Fatalf("set current: %v", err)
	}
	if got := answer.(map[string]any)["currentId"]; got != secondID {
		t.Fatalf("the handler must echo the selection, got %v", got)
	}
	if got := currentRouteID(storedProfiles(t)); got != secondID {
		t.Fatalf("document marker: want %d, got %d", secondID, got)
	}

	// Moving back must clear the earlier marker: two `__current` rows would make
	// the answer depend on document order.
	if _, err := callJSON(t, handleSetCurrentRoute, `{"id":`+itoa(firstID)+`}`); err != nil {
		t.Fatalf("set current back: %v", err)
	}
	marked := 0
	for _, profile := range storedProfiles(t) {
		if flag, ok := profile["__current"].(bool); ok && flag {
			marked++
		}
	}
	if marked != 1 {
		t.Fatalf("exactly one profile must carry the marker, got %d", marked)
	}
	if got := currentRouteID(storedProfiles(t)); got != firstID {
		t.Fatalf("document marker after moving back: want %d, got %d", firstID, got)
	}
}

func TestSetCurrentRefusesRawAndUnknown(t *testing.T) {
	withRouteStore(t)
	if err := writeDocument(routeProfilesDoc, []row{
		{"id": int64(1), "name": "Raw", "is_raw": true},
		{"id": int64(2), "name": "Mine"},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	for _, id := range []string{"1", "99"} {
		if _, err := callJSON(t, handleSetCurrentRoute, `{"id":`+id+`}`); err == nil {
			t.Fatalf("profile %s must not become current", id)
		}
	}
	// A refused selection leaves the document untouched: the raw row must not
	// carry a marker and no other row may have been written in its place.
	for _, profile := range storedProfiles(t) {
		if flag, ok := profile["__current"].(bool); ok && flag {
			t.Fatalf("a refused selection wrote the marker on %v", profile["id"])
		}
	}
}

func TestDeleteCurrentMovesTheMarker(t *testing.T) {
	withRouteStore(t)

	first, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"First"}`)
	if err != nil {
		t.Fatalf("create first: %v", err)
	}
	second, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"Second"}`)
	if err != nil {
		t.Fatalf("create second: %v", err)
	}
	firstID, secondID := first.(int64), second.(int64)
	if _, err := callJSON(t, handleSetCurrentRoute, `{"id":`+itoa(firstID)+`}`); err != nil {
		t.Fatalf("set current: %v", err)
	}

	if _, err := callJSON(t, handleDeleteRouteProfile, `{"id":`+itoa(firstID)+`}`); err != nil {
		t.Fatalf("delete current: %v", err)
	}
	// The survivor with the lowest id becomes current, the correction
	// `RouteManager.current()` applies on read: the seed Default row wins here,
	// not the profile the test created second.
	survivor := currentRouteID(storedProfiles(t))
	if survivor <= 0 || survivor == firstID {
		t.Fatalf("the marker must move to a surviving profile, got %d", survivor)
	}
	if marked := storedProfile(t, survivor); !rowBool(marked, "__current") {
		t.Fatalf("the survivor (%d) must carry the marker", survivor)
	}
	if findProfile(storedProfiles(t), secondID) == nil {
		t.Fatal("the other profile must survive")
	}
}

// currentRouteIDFromRoom kept its name but reads the document: the stats
// handler must answer under the pure-Go harness, where no SQLite is linked and
// a queryRows call would fail on the missing database rather than on the marker.
func TestCurrentRouteIDFromRoomReadsTheDocument(t *testing.T) {
	withRouteStore(t)
	if err := writeDocument(routeProfilesDoc, []row{
		{"id": int64(1), "name": "First"},
		{"id": int64(2), "name": "Second", "__current": true},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	got, err := currentRouteIDFromRoom()
	if err != nil {
		t.Fatalf("currentRouteIDFromRoom: %v", err)
	}
	if got != 2 {
		t.Fatalf("want the marked id 2, got %d", got)
	}

	// An unmarked document falls back to the first usable profile, like
	// currentRouteID does — never to 0, which would report no current rules.
	if err := writeDocument(routeProfilesDoc, []row{
		{"id": int64(3), "name": "Raw", "is_raw": true},
		{"id": int64(4), "name": "Usable"},
	}); err != nil {
		t.Fatalf("reseed: %v", err)
	}
	if got, err := currentRouteIDFromRoom(); err != nil || got != 4 {
		t.Fatalf("unmarked document: want 4, got %d (%v)", got, err)
	}
}

// --- batch add ---------------------------------------------------------------

func TestBatchAddRulesParsesOneRulePerLine(t *testing.T) {
	withRouteStore(t)

	saved, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"P"}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := saved.(int64)

	answer, err := callJSON(t, handleBatchAddRules, `{"id":`+itoa(id)+`,"text":`+
		jsonString("domain:one.test -> proxy\n\n  suffix:two.test -> block  \nkeyword:Three -> warp_bypass\n")+`}`)
	if err != nil {
		t.Fatalf("batch: %v", err)
	}
	if added := answer.(map[string]any)["added"]; added != 3 {
		t.Fatalf("want 3 added (blank lines skipped), got %v", added)
	}

	rules := rulesOfProfile(storedRules(t), id)
	if len(rules) != 3 {
		t.Fatalf("want one rule per line, got %d", len(rules))
	}
	// Line one: a domain rule to proxy, its value lowercased.
	if got := jsonList(rowString(rules[0], "domain_json")); len(got) != 1 || got[0] != "one.test" {
		t.Fatalf("first rule domain: %v", got)
	}
	if got := rowInt(rules[0], "type"); got != ruleTypeSimpleAddrProxy {
		t.Fatalf("first rule type: want %d, got %d", ruleTypeSimpleAddrProxy, got)
	}
	// Line two: block is a `reject` action, not an outbound id.
	if got := rowInt(rules[1], "type"); got != ruleTypeSimpleAddrBlock {
		t.Fatalf("second rule type: want %d, got %d", ruleTypeSimpleAddrBlock, got)
	}
	if got := rowString(rules[1], "action"); got != "reject" {
		t.Fatalf("a block rule must reject, got action %q", got)
	}
	// Line three: warp_bypass is accepted as an alias and the keyword lowercases.
	if got := rowInt(rules[2], "type"); got != ruleTypeSimpleAddrWarp {
		t.Fatalf("third rule type: want %d, got %d", ruleTypeSimpleAddrWarp, got)
	}
	if got := jsonList(rowString(rules[2], "domain_keyword_json")); len(got) != 1 || got[0] != "three" {
		t.Fatalf("third rule keyword: %v", got)
	}
}

func TestBatchAddRulesRejectsAnEmptyText(t *testing.T) {
	withRouteStore(t)
	saved, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"P"}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := callJSON(t, handleBatchAddRules,
		`{"id":`+itoa(saved.(int64))+`,"text":" \n\t\n"}`); err == nil {
		t.Fatal("blank text must be an error, not a silent no-op")
	}
}

func TestBatchAddRulesRefusesRaw(t *testing.T) {
	withRouteStore(t)
	if err := writeDocument(routeProfilesDoc, []row{
		{"id": int64(1), "name": "Raw", "is_raw": true},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := callJSON(t, handleBatchAddRules, `{"id":1,"text":"domain:one.test -> proxy"}`); err == nil {
		t.Fatal("a raw profile must refuse batch add")
	}
	if rules := storedRules(t); len(rules) != 0 {
		t.Fatalf("a refused batch must not write, got %d rules", len(rules))
	}
}

// --- reset -------------------------------------------------------------------

func TestResetRouteRulesRestoresTheDefaultTemplate(t *testing.T) {
	withRouteStore(t)

	saved, err := callJSON(t, handleSaveRouteProfile,
		`{"id":0,"name":"P","rules":"domain:one.test -> proxy\ndomain:two.test -> block"}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := saved.(int64)
	if got := len(rulesOfProfile(storedRules(t), id)); got != 2 {
		t.Fatalf("setup: want 2 rules, got %d", got)
	}

	answer, err := callJSON(t, handleResetRouteRules, `{"id":`+itoa(id)+`}`)
	if err != nil {
		t.Fatalf("reset: %v", err)
	}
	wire := answer.(map[string]any)["rules"].([]any)
	if len(wire) != len(defaultProfileRules()) {
		t.Fatalf("want the %d template rules, got %d", len(defaultProfileRules()), len(wire))
	}

	rules := rulesOfProfile(storedRules(t), id)
	if len(rules) != 1 {
		t.Fatalf("want the single hijack-dns template rule, got %d", len(rules))
	}
	template := defaultProfileRules()[0]
	if got := rowString(rules[0], "action"); got != template["action"] {
		t.Fatalf("template action: want %v, got %q", template["action"], got)
	}
	if got := rowString(rules[0], "protocol"); got != template["protocol"] {
		t.Fatalf("template protocol: want %v, got %q", template["protocol"], got)
	}
	if got := rowInt64(rules[0], "route_profile_id"); got != id {
		t.Fatalf("template rule must belong to %d, got %d", id, got)
	}
	// The template rows are copied, not shared: mutating the stored rule must not
	// reach the package-level template the next reset starts from.
	rules[0]["name"] = "mutated"
	if defaultProfileRules()[0]["name"] == "mutated" {
		t.Fatal("the reset template was mutated through the stored row")
	}
}

func TestResetRouteRulesRefusesRaw(t *testing.T) {
	withRouteStore(t)
	if err := writeDocument(routeProfilesDoc, []row{
		{"id": int64(1), "name": "Raw", "is_raw": true},
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := callJSON(t, handleResetRouteRules, `{"id":1}`); err == nil {
		t.Fatal("a raw profile must refuse the reset")
	}
}

// --- global pool -------------------------------------------------------------

func TestSetGlobalRuleDisabledStoresTheListOnTheProfile(t *testing.T) {
	withRouteStore(t)

	saved, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"P"}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := saved.(int64)

	if _, err := callJSON(t, handleSetGlobalRuleDisabled,
		`{"profileId":`+itoa(id)+`,"ids":[3,5]}`); err != nil {
		t.Fatalf("disable: %v", err)
	}
	profile := storedProfile(t, id)
	if got := rowString(profile, "disabled_global_rule_json"); got != "[3,5]" {
		t.Fatalf("disabled list: want [3,5], got %q", got)
	}

	// Section 1 includes 3 only; 5 stays disabled.
	if _, err := callJSON(t, handleSetGlobalRuleDisabled,
		`{"profileId":`+itoa(id)+`,"ids":[5]}`); err != nil {
		t.Fatalf("disable again: %v", err)
	}
	if got := rowString(storedProfile(t, id), "disabled_global_rule_json"); got != "[5]" {
		t.Fatalf("the list must be replaced, got %q", got)
	}

	// Clearing is an empty array, not a null: Kotlin parses it as a JSON array.
	if _, err := callJSON(t, handleSetGlobalRuleDisabled,
		`{"profileId":`+itoa(id)+`}`); err != nil {
		t.Fatalf("clear: %v", err)
	}
	if got := rowString(storedProfile(t, id), "disabled_global_rule_json"); got != "[]" {
		t.Fatalf("cleared list: want [], got %q", got)
	}
}

func TestSetGlobalRuleDisabledRefusesAnUnknownProfile(t *testing.T) {
	withRouteStore(t)
	if _, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"P"}`); err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := callJSON(t, handleSetGlobalRuleDisabled, `{"profileId":99,"ids":[1]}`); err == nil {
		t.Fatal("an unknown profile must be an error")
	}
}

func TestSaveRouteProfileKeepsTheNonEditorColumns(t *testing.T) {
	withRouteStore(t)

	// The subscription/native writers send these; a create has no earlier row to inherit them
	// from, and losing source_gid detaches the subscription from the profile it rewrites.
	saved, err := callJSON(t, handleSaveRouteProfile,
		`{"id":0,"name":"Sub","sourceGid":42,"remoteLastUpdate":1770000000}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	profile := storedProfile(t, saved.(int64))
	if got := rowInt64(profile, "source_gid"); got != 42 {
		t.Fatalf("source_gid: want 42, got %d", got)
	}
	if got := rowInt64(profile, "remote_last_update"); got != 1770000000 {
		t.Fatalf("remote_last_update: want 1770000000, got %d", got)
	}

	// Absent means untouched: a plain editor save must not reset them.
	if _, err := callJSON(t, handleSaveRouteProfile,
		`{"id":`+itoa(saved.(int64))+`,"name":"Renamed"}`); err != nil {
		t.Fatalf("rename: %v", err)
	}
	profile = storedProfile(t, saved.(int64))
	if got := rowInt64(profile, "source_gid"); got != 42 {
		t.Fatalf("a rename reset source_gid to %d", got)
	}
	if got := rowInt64(profile, "remote_last_update"); got != 1770000000 {
		t.Fatalf("a rename reset remote_last_update to %d", got)
	}
}

// --- the Kotlin entry point --------------------------------------------------

// RunAction is the gobind face Kotlin calls when it has nowhere to post a
// message-port reply. The route documents are kernel-owned, so `RemoteRouteUpdater`
// and the subscription router save through it; a wrong code or a lost payload here
// shows up as a silently failed remote-profile update on the device.
func TestRunActionAnswersAnEncodedResult(t *testing.T) {
	withRouteStore(t)

	answer := RunAction(`{"id":"kt-1","method":"saveRouteProfile","data":{"id":0,"name":"From Kotlin"}}`)
	decoded := ActionResult{}
	if err := json.Unmarshal([]byte(answer), &decoded); err != nil {
		t.Fatalf("the answer must be JSON: %v (%s)", err, answer)
	}
	if decoded.Code != actionCodeSuccess {
		t.Fatalf("save through RunAction failed: code=%d data=%v", decoded.Code, decoded.Data)
	}
	if decoded.Id != "kt-1" || decoded.Method != saveRouteProfileMethod {
		t.Fatalf("the answer must echo the request: %+v", decoded)
	}
	id, ok := decoded.Data.(float64) // the encoded round trip turns int64 into a JSON number
	if !ok || id <= 0 {
		t.Fatalf("save must answer the new id, got %#v", decoded.Data)
	}
	if profile := findProfile(storedProfiles(t), int64(id)); profile == nil {
		t.Fatalf("RunAction did not persist profile %v", id)
	}
}

// The Kotlin path writes the row and then its rules as two actions: `saveRouteProfile` takes
// the simple-address TEXT for `rules`, so a rule array sent there is rejected before anything
// is written. The pair below is what `RouteActions.save` performs, and it must leave the
// profile's rule conditions in their columns.
func TestRunActionSavesARowThenItsRules(t *testing.T) {
	withRouteStore(t)

	created := ActionResult{}
	if err := json.Unmarshal([]byte(RunAction(
		`{"id":"kt-1","method":"saveRouteProfile","data":{"id":0,"name":"Sub","sourceGid":42}}`,
	)), &created); err != nil {
		t.Fatalf("create: %v", err)
	}
	if created.Code != actionCodeSuccess {
		t.Fatalf("create failed: code=%d data=%v", created.Code, created.Data)
	}
	id := int64(created.Data.(float64))

	// The rule array belongs to saveRouteRules, with its lists under the column names the
	// store reads (RouteActions.rulesToWire).
	saved := ActionResult{}
	if err := json.Unmarshal([]byte(RunAction(`{"id":"kt-2","method":"saveRouteRules","data":{"id":`+
		itoa(id)+`,"rules":[{"name":"CN","type":"custom","action":"route","outbound_id":-2,`+
		`"rule_set_json":["geoip-cn"]}]}}`)), &saved); err != nil {
		t.Fatalf("save rules: %v", err)
	}
	if saved.Code != actionCodeSuccess {
		t.Fatalf("save rules failed: code=%d data=%v", saved.Code, saved.Data)
	}

	rules := rulesOfProfile(storedRules(t), id)
	if len(rules) != 1 {
		t.Fatalf("want one stored rule, got %d", len(rules))
	}
	if got := jsonList(rowString(rules[0], "rule_set_json")); len(got) != 1 || got[0] != "geoip-cn" {
		t.Fatalf("rule_set_json: want [geoip-cn], got %v", got)
	}
	if got := rowInt64(storedProfile(t, id), "source_gid"); got != 42 {
		t.Fatalf("source_gid: want 42, got %d", got)
	}
}

// A rule array sent to saveRouteProfile is refused outright: `Rules` is the simple-address
// text there, and the unmarshal failing first is why nothing was ever written.
func TestSaveRouteProfileRefusesARuleArray(t *testing.T) {
	withRouteStore(t)
	if _, err := callJSON(t, handleSaveRouteProfile,
		`{"id":0,"name":"Nope","rules":[{"rule_set_json":["geoip-cn"]}]}`); err == nil {
		t.Fatal("a rule array must not be accepted as the simple-address rules text")
	}
	if profiles := storedProfiles(t); len(profiles) != 0 {
		t.Fatalf("a refused save must not write, got %d profiles", len(profiles))
	}
}

func TestRunActionReportsFailuresAsCodes(t *testing.T) {
	withRouteStore(t)
	for _, action := range []string{
		`{"id":"a","method":"nosuchMethod"}`,
		`{"id":"b","method":"deleteRouteProfile","data":{"id":404}}`,
		`not json at all`,
	} {
		decoded := ActionResult{}
		if err := json.Unmarshal([]byte(RunAction(action)), &decoded); err != nil {
			t.Fatalf("a failure must still answer JSON: %v", err)
		}
		if decoded.Code == actionCodeSuccess {
			t.Fatalf("%s must fail, got code 0", action)
		}
	}
}

// --- rule columns ------------------------------------------------------------

// A list condition sent under its short name must land in its `_json` column.
//
// Only the columns are read back (Kotlin's RouteJsonStore, the config generator), so a short
// name outside the five the routing screen aliases used to be stored verbatim: the rule then
// built as a match-all, which is the routing loss this pins.
func TestRuleRowFromWireNormalisesEveryListColumn(t *testing.T) {
	for _, key := range []string{"rule_set", "domain_keyword", "port", "sniffers", "inbound"} {
		stored := ruleRowFromWire(7, 0, map[string]any{key: []any{"v1"}}, nil)
		if _, verbatim := stored[key]; verbatim {
			t.Fatalf("%s must not be stored verbatim", key)
		}
		if got := jsonList(rowString(stored, key+"_json")); len(got) != 1 || got[0] != "v1" {
			t.Fatalf("%s: want %s_json=[v1], got %v", key, key, got)
		}
	}
	// The five aliases keep landing in the column they always did.
	stored := ruleRowFromWire(7, 0, map[string]any{"domain": []any{"example.com"}}, nil)
	if got := jsonList(rowString(stored, "domain_json")); len(got) != 1 || got[0] != "example.com" {
		t.Fatalf("domain: want domain_json=[example.com], got %v", got)
	}
}

// The stored row read back through the wire carries the value under the column name, which is
// what the rule list renders and what an editor round trip re-reads.
func TestWireRulesEchoesANormalisedShorthand(t *testing.T) {
	stored := ruleRowFromWire(1, 0, map[string]any{"rule_set": []any{"geoip-cn"}}, nil)
	wire := wireRules([]row{stored})[0].(map[string]any)
	got, ok := wire["rule_set_json"].([]any)
	if !ok || len(got) != 1 || got[0] != "geoip-cn" {
		t.Fatalf("want rule_set_json=[geoip-cn], got %#v", wire["rule_set_json"])
	}
	if _, verbatim := wire["rule_set"]; verbatim {
		t.Fatal("wireRules aliases only five conditions; rule_set must not be one")
	}
}

// End to end through the handler the routing screen and the import path both call.
func TestSaveRouteRulesStoresShorthandConditions(t *testing.T) {
	withRouteStore(t)
	saved, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"Bypass China"}`)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	id := saved.(int64)
	if _, err := callJSON(t, handleSaveRouteRules, `{"id":`+itoa(id)+`,"rules":[
		{"name":"CN","type":"custom","action":"route","outbound_id":-2,
		 "rule_set":["geoip-cn","geosite-cn"],"domain_keyword":["baidu"]}
	]}`); err != nil {
		t.Fatalf("save rules: %v", err)
	}
	rules := rulesOfProfile(storedRules(t), id)
	if len(rules) != 1 {
		t.Fatalf("want one rule, got %d", len(rules))
	}
	if got := jsonList(rowString(rules[0], "rule_set_json")); len(got) != 2 || got[0] != "geoip-cn" {
		t.Fatalf("rule_set_json: want [geoip-cn geosite-cn], got %v", got)
	}
	if got := jsonList(rowString(rules[0], "domain_keyword_json")); len(got) != 1 || got[0] != "baidu" {
		t.Fatalf("domain_keyword_json: want [baidu], got %v", got)
	}
	for _, key := range []string{"rule_set", "domain_keyword"} {
		if _, verbatim := rules[0][key]; verbatim {
			t.Fatalf("%s must not be stored verbatim", key)
		}
	}
}

// --- the settings-table contract ---------------------------------------------

// settingsSQL is an SQL statement against the host's `settings` table. It is
// matched inside the concatenated string literals of a file (see stringLiterals),
// never across two unrelated literals, and the gap is bounded so a SELECT far
// above a table name cannot pair with it.
var settingsSQL = regexp.MustCompile(`(?i)\b(select|insert|replace|update|delete)\b[^\x00]{0,400}?\bsettings\b`)

// settingsKey is the row the routing selection used to write from Go. It only
// has to appear inside a literal to be real SQL: an identifier of that name
// would be snake_case in a camelCase codebase.
var settingsKey = regexp.MustCompile(`current_route_id`)

// stringLiterals returns every string literal in a Go file, with comments and
// all other code elided. Literals joined by `+` (the usual way a long SQL
// statement is spelled) are concatenated too, so a statement split across lines
// or into a table name of its own still reads as one; `\x00` separates literals
// that are not concatenated, which is what bounds [settingsSQL]'s gap.
//
// Scanning literals rather than the file is what keeps a doc comment that names
// the table (all of them do now) from tripping the test, and what keeps Go code
// like `delete(profile, "__current")` from pairing with a table name much later.
func stringLiterals(src string) string {
	var (
		out  strings.Builder
		gap  strings.Builder // the code since the previous literal ended
		seen bool
		i    int
	)
	flushGap := func() {
		if !seen {
			gap.Reset()
			return
		}
		// Only a `+` chain continues the same statement: anything else (a comma
		// in a composite literal, a new statement) is a different string.
		if strings.Trim(gap.String(), " \t\r\n+") != "" {
			out.WriteByte(0)
		}
		gap.Reset()
	}
	for i < len(src) {
		switch c := src[i]; c {
		case '/':
			if i+1 < len(src) && src[i+1] == '/' {
				for i < len(src) && src[i] != '\n' {
					i++
				}
				gap.WriteByte('\n')
				continue
			}
			if i+1 < len(src) && src[i+1] == '*' {
				end := strings.Index(src[i+2:], "*/")
				if end < 0 {
					i = len(src)
					continue
				}
				i += 2 + end + 2
				gap.WriteByte('\n')
				continue
			}
			gap.WriteByte(c)
			i++
		case '"', '\'':
			quote := c
			flushGap()
			seen = true
			i++
			for i < len(src) {
				if src[i] == '\\' && i+1 < len(src) {
					out.WriteByte(src[i])
					i++
					out.WriteByte(src[i])
					i++
					continue
				}
				if src[i] == quote {
					i++
					break
				}
				out.WriteByte(src[i])
				i++
			}
		case '`':
			flushGap()
			seen = true
			i++
			for i < len(src) && src[i] != '`' {
				out.WriteByte(src[i])
				i++
			}
			i++
		default:
			gap.WriteByte(c)
			i++
		}
	}
	return out.String()
}

// TestStringLiteralsKeepsStatementsWhole pins the scan's two properties: a
// statement split into concatenated literals reads as one, and a literal in one
// statement cannot pair with a name in the next.
func TestStringLiteralsKeepsStatementsWhole(t *testing.T) {
	joined := stringLiterals("const q = \"INSERT OR REPLACE INTO `set\" +\n\t\"tings` (`key`, `value\")")
	if !settingsSQL.MatchString(joined) {
		t.Fatalf("a concatenated statement must read as one, got %q", joined)
	}
	split := stringLiterals("delete(profile, \"__current\")\nconst other = \"settings\"")
	if settingsSQL.MatchString(split) {
		t.Fatalf("unrelated literals must not pair, got %q", split)
	}
	commented := stringLiterals("// SELECT `value` FROM `settings` WHERE `key` = 'x'\nconst v = 1")
	if settingsSQL.MatchString(commented) {
		t.Fatalf("a comment must not count as SQL, got %q", commented)
	}
	// A statement spelled inside a comment must still be caught when it is really
	// code, so the helper must not have eaten the literal that follows.
	if got := stringLiterals("const a = 1 // hint\nconst b = \"current_route_id\""); !settingsKey.MatchString(got) {
		t.Fatalf("a literal after a comment must survive, got %q", got)
	}
}

// TestNoGoFileWritesTheSettingsTable is the regression guard for SQLite error
// 522: Go must never open its own connection against `sager_net.db` to touch
// `settings`.
//
// Room is the only writer of that table, and the framework connection reads it
// (VpnService calls SettingsStore.getBoolean on start). A per-call foreign
// connection close can checkpoint and truncate the shared WAL file while that
// reader is mid-page, which surfaced as SQLITE_IOERR_SHORT_READ (522) in
// `SettingsStore.getBoolean` right after a route selection. The fix removed the
// one `INSERT OR REPLACE INTO settings` this package had; this test keeps it
// gone — a reintroduction is otherwise invisible until a device crashes.
func TestNoGoFileWritesTheSettingsTable(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatalf("read the package directory: %v", err)
	}
	scanned := 0
	for _, entry := range entries {
		name := entry.Name()
		if entry.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		raw, err := os.ReadFile(name)
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		scanned++
		literals := stringLiterals(string(raw))
		if match := settingsSQL.FindString(literals); match != "" {
			t.Errorf("%s performs SQL against the settings table: %q", name, strings.TrimSpace(match))
		}
		if settingsKey.MatchString(literals) {
			t.Errorf("%s names the settings.current_route_id row in SQL; the host writes it", name)
		}
	}
	if scanned == 0 {
		t.Fatal("the scan found no Go files; it is looking in the wrong directory")
	}
}

// --- helpers -----------------------------------------------------------------

func itoa(id int64) string {
	return strings.TrimSpace(strings.Join([]string{jsonNumber(id)}, ""))
}

func jsonNumber(id int64) string {
	encoded, err := json.Marshal(id)
	if err != nil {
		return "0"
	}
	return string(encoded)
}

func jsonString(value string) string {
	encoded, err := json.Marshal(value)
	if err != nil {
		return `""`
	}
	return string(encoded)
}
