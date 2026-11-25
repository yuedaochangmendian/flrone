// The single global rule table and its wire normalisation (ADR 0002, phase 3c).
//
// The retired design had profile CRUD, a current-profile marker, batch add,
// reset and a per-profile opt-out. All of it collapsed into one document and
// three wire methods. These tests pin the parts that fail silently at runtime
// and are invisible to gofmt/CI compile: a save that loses a column, an id that
// changes on round-trip, a short list name stored verbatim (which builds as a
// match-all rule), and a delete that misses.
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

func callJSON(t *testing.T, handler actionHandler, payload string) (any, error) {
	t.Helper()
	if payload == "" {
		return handler(nil)
	}
	return handler(json.RawMessage(payload))
}

func storedGlobalRules(t *testing.T) []row {
	t.Helper()
	rules, err := readDocument(globalRulesDoc)
	if err != nil {
		t.Fatalf("read %s: %v", globalRulesDoc, err)
	}
	return rules
}

// --- single table ------------------------------------------------------------

// A full table round trip: every column the client sends must survive save and
// come back through get, with a stable id and an `enabled` flag derived from
// the row's own `disabled` field.
func TestGlobalRulesSaveGetRoundTrip(t *testing.T) {
	withRouteStore(t)

	saved, err := callJSON(t, handleSaveGlobalRules, `{"rules":[
		{"id":1,"name":"CN","type":"custom","action":"route","outbound_id":-2,
		 "domain":["example.com"],"rule_set":["geoip-cn"],"tls_fragment":true},
		{"id":2,"name":"Block ads","type":"simple_address_block",
		 "action":"reject","domain_suffix":["ads.example"],"disabled":true}
	]}`)
	if err != nil {
		t.Fatalf("save: %v", err)
	}
	reply := saved.(map[string]any)["rules"].([]any)
	if len(reply) != 2 {
		t.Fatalf("want two rules in the save answer, got %d", len(reply))
	}

	// Read through the other handler: this is what a fresh app launch sees.
	got, err := callJSON(t, handleGetGlobalRules, "")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	wire := got.(map[string]any)["rules"].([]any)
	if len(wire) != 2 {
		t.Fatalf("want two rules, got %d", len(wire))
	}
	first := wire[0].(map[string]any)
	if first["id"] != int64(1) || first["name"] != "CN" || first["enabled"] != true {
		t.Fatalf("first rule lost its identity/enabled state: %#v", first)
	}
	if got := first["domain_json"].([]any); len(got) != 1 || got[0] != "example.com" {
		t.Fatalf("domain_json: %v", first["domain_json"])
	}
	if got := first["rule_set_json"].([]any); len(got) != 1 || got[0] != "geoip-cn" {
		t.Fatalf("rule_set_json: %v", first["rule_set_json"])
	}
	if first["tls_fragment"] != true {
		t.Fatalf("tls_fragment: %v", first["tls_fragment"])
	}
	second := wire[1].(map[string]any)
	if second["id"] != int64(2) || second["enabled"] != false {
		t.Fatalf("second rule must keep id 2 and be disabled: %#v", second)
	}
	if got := second["domain_suffix_json"].([]any); len(got) != 1 || got[0] != "ads.example" {
		t.Fatalf("domain_suffix_json: %v", second["domain_suffix_json"])
	}

	// The stored document is the authority, not the handler's own answer.
	if stored := storedGlobalRules(t); len(stored) != 2 {
		t.Fatalf("want two stored rules, got %d", len(stored))
	}
}

// A client that sends a plain rule object back by position keeps that row's
// id and every column it did not send, instead of getting a fresh identity
// with the conditions wiped.
func TestGlobalRulesSavePreservesIdsAndColumns(t *testing.T) {
	withRouteStore(t)

	if _, err := callJSON(t, handleSaveGlobalRules, `{"rules":[
		{"id":7,"name":"Kept","type":"custom","outbound_id":-2,
		 "port":["80","443"],"tls_spoof":"google"}
	]}`); err != nil {
		t.Fatalf("seed save: %v", err)
	}
	if _, err := callJSON(t, handleSaveGlobalRules, `{"rules":[
		{"id":7,"name":"Renamed","type":"custom"}
	]}`); err != nil {
		t.Fatalf("second save: %v", err)
	}

	stored := storedGlobalRules(t)
	if len(stored) != 1 {
		t.Fatalf("want one rule, got %d", len(stored))
	}
	if got := rowInt64(stored[0], "id"); got != 7 {
		t.Fatalf("id must survive a positional save, got %d", got)
	}
	if got := rowString(stored[0], "name"); got != "Renamed" {
		t.Fatalf("name did not change: %q", got)
	}
	if got := jsonList(rowString(stored[0], "port_json")); len(got) != 2 {
		t.Fatalf("port_json was wiped: %v", stored[0]["port_json"])
	}
	if got := rowString(stored[0], "tls_spoof"); got != "google" {
		t.Fatalf("tls_spoof was wiped: %q", got)
	}
}

func TestDeleteGlobalRuleRemovesById(t *testing.T) {
	withRouteStore(t)

	if _, err := callJSON(t, handleSaveGlobalRules, `{"rules":[
		{"id":1,"name":"First"},{"id":2,"name":"Second"},{"id":3,"name":"Third"}
	]}`); err != nil {
		t.Fatalf("save: %v", err)
	}
	if _, err := callJSON(t, handleDeleteGlobalRule, `{"id":2}`); err != nil {
		t.Fatalf("delete: %v", err)
	}

	got, err := callJSON(t, handleGetGlobalRules, "")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	wire := got.(map[string]any)["rules"].([]any)
	if len(wire) != 2 {
		t.Fatalf("want two survivors, got %d", len(wire))
	}
	for _, entry := range wire {
		id := entry.(map[string]any)["id"]
		if id == int64(2) {
			t.Fatal("the deleted id is still in the table")
		}
	}
	if stored := storedGlobalRules(t); len(stored) != 2 {
		t.Fatalf("want two stored survivors, got %d", len(stored))
	}

	// Deleting an absent id is a no-op, not a rewrite that disturbs the table.
	if _, err := callJSON(t, handleDeleteGlobalRule, `{"id":404}`); err != nil {
		t.Fatalf("delete of an unknown id: %v", err)
	}
	if stored := storedGlobalRules(t); len(stored) != 2 {
		t.Fatalf("a no-op delete changed the table: %d", len(stored))
	}
}

// --- ADR compatibility migration ---------------------------------------------

// An install from the multi-profile build has only the old documents. The
// first read must fold every old rule into the single table, drop the profile
// partition key, and never resurrect the rows once the new table exists (even
// if it was intentionally emptied).
func TestGlobalRulesMigrateLegacyDocumentsOnce(t *testing.T) {
	withRouteStore(t)

	if err := writeDocument("route_profiles", []row{{"id": int64(1), "name": "Default"}}); err != nil {
		t.Fatalf("legacy profiles: %v", err)
	}
	if err := writeDocument("route_rules", []row{
		{"route_profile_id": int64(1), "rule_order": 5, "name": "From P1", "type": 0, "id": int64(9)},
		{"route_profile_id": int64(2), "rule_order": 2, "name": "From P2", "type": 0, "id": int64(3)},
	}); err != nil {
		t.Fatalf("legacy rules: %v", err)
	}

	got, err := callJSON(t, handleGetGlobalRules, "")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	wire := got.(map[string]any)["rules"].([]any)
	if len(wire) != 2 {
		t.Fatalf("want both legacy rules, got %d", len(wire))
	}
	if first := wire[0].(map[string]any); first["name"] != "From P2" {
		t.Fatalf("rules must migrate in rule_order, got %#v", first)
	}
	stored := storedGlobalRules(t)
	for _, rule := range stored {
		if _, ok := rule["route_profile_id"]; ok {
			t.Fatalf("the profile partition key survived: %v", rule)
		}
		if rowInt64(rule, "id") <= 0 {
			t.Fatalf("a migrated rule has no id: %v", rule)
		}
	}

	// An intentionally empty table stays empty: the legacy rows are not replayed.
	if err := writeDocument(globalRulesDoc, []row{}); err != nil {
		t.Fatalf("empty table: %v", err)
	}
	got, err = callJSON(t, handleGetGlobalRules, "")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if wire := got.(map[string]any)["rules"].([]any); len(wire) != 0 {
		t.Fatalf("legacy rows were resurrected: %v", wire)
	}
}

// A legacy caller still sends profileId; the collapsed reader ignores it.
func TestGetGlobalRulesIgnoresProfileId(t *testing.T) {
	withRouteStore(t)
	if _, err := callJSON(t, handleSaveGlobalRules, `{"rules":[{"id":1,"name":"Only"}]}`); err != nil {
		t.Fatalf("save: %v", err)
	}
	first, err := callJSON(t, handleGetGlobalRules, "")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	second, err := callJSON(t, handleGetGlobalRules, `{"profileId":42,"ids":[1]}`)
	if err != nil {
		t.Fatalf("get with legacy payload: %v", err)
	}
	firstJSON, _ := json.Marshal(first)
	secondJSON, _ := json.Marshal(second)
	if string(firstJSON) != string(secondJSON) {
		t.Fatalf("a stale profileId changed the answer:\n%s\n%s", firstJSON, secondJSON)
	}
}

// --- the Kotlin entry point --------------------------------------------------

// RunAction is the gobind face Kotlin calls when it has nowhere to post a
// message-port reply. The global rules are kernel-owned, so Kotlin writes them
// through the action bus; a wrong code or a lost payload here shows up as a
// silently failed update on the device.
func TestRunActionAnswersAnEncodedResult(t *testing.T) {
	withRouteStore(t)

	answer := RunAction(`{"id":"kt-1","method":"saveGlobalRules","data":{"rules":[{"id":1,"name":"From Kotlin"}]}}`)
	decoded := ActionResult{}
	if err := json.Unmarshal([]byte(answer), &decoded); err != nil {
		t.Fatalf("the answer must be JSON: %v (%s)", err, answer)
	}
	if decoded.Code != actionCodeSuccess {
		t.Fatalf("save through RunAction failed: code=%d data=%v", decoded.Code, decoded.Data)
	}
	if decoded.Id != "kt-1" || decoded.Method != saveGlobalRulesMethod {
		t.Fatalf("the answer must echo the request: %+v", decoded)
	}
	rules := storedGlobalRules(t)
	if len(rules) != 1 || rowString(rules[0], "name") != "From Kotlin" {
		t.Fatalf("RunAction did not persist the rule: %v", rules)
	}
}

func TestRunActionReportsFailuresAsCodes(t *testing.T) {
	withRouteStore(t)
	for _, action := range []string{
		`{"id":"a","method":"nosuchMethod"}`,
		`{"id":"b","method":"saveGlobalRules","data":{"rules":"not an array"}}`,
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
// name outside the five the routing screen aliased used to be stored verbatim: the rule then
// built as a match-all, which is the routing loss this pins.
func TestRuleRowFromWireNormalisesEveryListColumn(t *testing.T) {
	for _, key := range []string{"rule_set", "domain_keyword", "port", "sniffers", "inbound"} {
		stored := ruleRowFromWire(0, map[string]any{key: []any{"v1"}}, nil)
		if _, verbatim := stored[key]; verbatim {
			t.Fatalf("%s must not be stored verbatim", key)
		}
		if got := jsonList(rowString(stored, key+"_json")); len(got) != 1 || got[0] != "v1" {
			t.Fatalf("%s: want %s_json=[v1], got %v", key, key, got)
		}
	}
	// The five aliases keep landing in the column they always did.
	stored := ruleRowFromWire(0, map[string]any{"domain": []any{"example.com"}}, nil)
	if got := jsonList(rowString(stored, "domain_json")); len(got) != 1 || got[0] != "example.com" {
		t.Fatalf("domain: want domain_json=[example.com], got %v", got)
	}
}

// The stored row read back through the wire carries the value under the column name, which is
// what the rule list renders and what an editor round trip re-reads.
func TestWireRulesEchoesANormalisedShorthand(t *testing.T) {
	stored := ruleRowFromWire(0, map[string]any{"rule_set": []any{"geoip-cn"}}, nil)
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
func TestSaveGlobalRulesStoresShorthandConditions(t *testing.T) {
	withRouteStore(t)
	if _, err := callJSON(t, handleSaveGlobalRules, `{"rules":[
		{"id":1,"name":"CN","type":"custom","action":"route","outbound_id":-2,
		 "rule_set":["geoip-cn","geosite-cn"],"domain_keyword":["baidu"]}
	]}`); err != nil {
		t.Fatalf("save rules: %v", err)
	}
	rules := storedGlobalRules(t)
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
// like `delete(rule, "disabled")` from pairing with a table name much later.
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
	split := stringLiterals("delete(rule, \"disabled\")\nconst other = \"settings\"")
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
