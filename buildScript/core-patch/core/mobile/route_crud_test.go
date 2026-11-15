// The route profile CRUD the routing screen drives (ADR 0002, phase 3c, restored).
//
// These handlers were deleted with the routing UI that only added rules to the
// shared pool (#70 left six of them). The screen edits profiles again, so the
// round trips are pinned here: a save that loses a column, a delete that takes
// the last profile, or a current-profile marker written to only one of the two
// stores all fail silently at runtime and are invisible to `gofmt`/CI compile.
//
// The document store is exercised for real (t.TempDir + writeDocument), and the
// one SQL crossing — the `settings.current_route_id` row — is observed through
// the `roomWriteCurrentRoute` seam, because the dev box builds with CGO_ENABLED=0
// and roomExecParams lives in the cgo file.
package mobile

import (
	"encoding/json"
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

// recordingCurrentRoute swaps the settings-row writer for one that records the
// ids it was asked to persist. It answers the ids back in call order.
func recordingCurrentRoute(t *testing.T) *[]int64 {
	t.Helper()
	previous := roomWriteCurrentRoute
	written := &[]int64{}
	roomWriteCurrentRoute = func(id int64) error {
		*written = append(*written, id)
		return nil
	}
	t.Cleanup(func() { roomWriteCurrentRoute = previous })
	return written
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
	written := recordingCurrentRoute(t)
	_ = written

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
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)
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

func TestSetCurrentWritesBothStores(t *testing.T) {
	withRouteStore(t)
	written := recordingCurrentRoute(t)

	first, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"First"}`)
	if err != nil {
		t.Fatalf("create first: %v", err)
	}
	second, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"Second"}`)
	if err != nil {
		t.Fatalf("create second: %v", err)
	}
	firstID, secondID := first.(int64), second.(int64)

	if _, err := callJSON(t, handleSetCurrentRoute, `{"id":`+itoa(secondID)+`}`); err != nil {
		t.Fatalf("set current: %v", err)
	}

	// Store one: the document marker currentRouteID (and the older readers) answer.
	if got := currentRouteID(storedProfiles(t)); got != secondID {
		t.Fatalf("document marker: want %d, got %d", secondID, got)
	}
	// Store two: the settings row currentRouteIDFromRoom / DataStore read.
	if len(*written) == 0 {
		t.Fatal("no settings.current_route_id row was written")
	}
	if got := (*written)[len(*written)-1]; got != secondID {
		t.Fatalf("settings row: want %d, got %d", secondID, got)
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
	written := recordingCurrentRoute(t)
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
	if len(*written) != 0 {
		t.Fatalf("a refused selection must not write the settings row, got %v", *written)
	}
}

func TestDeleteCurrentMovesBothStores(t *testing.T) {
	withRouteStore(t)
	written := recordingCurrentRoute(t)

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
	*written = (*written)[:0]

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
	if len(*written) != 1 || (*written)[0] != survivor {
		t.Fatalf("the settings row must follow the marker (%d), got %v", survivor, *written)
	}
	if findProfile(storedProfiles(t), secondID) == nil {
		t.Fatal("the other profile must survive")
	}
}

// --- batch add ---------------------------------------------------------------

func TestBatchAddRulesParsesOneRulePerLine(t *testing.T) {
	withRouteStore(t)
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)
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
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)
	if _, err := callJSON(t, handleSaveRouteProfile, `{"id":0,"name":"P"}`); err != nil {
		t.Fatalf("create: %v", err)
	}
	if _, err := callJSON(t, handleSetGlobalRuleDisabled, `{"profileId":99,"ids":[1]}`); err == nil {
		t.Fatal("an unknown profile must be an error")
	}
}

func TestSaveRouteProfileKeepsTheNonEditorColumns(t *testing.T) {
	withRouteStore(t)
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)

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
	recordingCurrentRoute(t)
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
