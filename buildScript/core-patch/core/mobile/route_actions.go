// The global route rules: one table, owned by the kernel (ADR 0002, phase 3c).
//
// The retired design had a profile list, a per-profile rule set, a current-profile
// marker, a global pool with per-profile opt-outs, and batch/reset conveniences.
// All of that collapsed into a single document, `global_route_rules.json`. Go is
// the only writer; the write path keeps the temp-file / Sync / rename atomicity
// from route_store.go.
//
// The rule normalisation here is the part that must not be simplified away:
// short list names land in their `_json` columns, tokens map to the stored type
// ids, and every unspecified column is preserved from the prior row on a save.
// A rule that loses a condition silently builds as a match-all.
//
// The only wire methods left are getGlobalRules / saveGlobalRules /
// deleteGlobalRule. The Dart wrappers already speak these names, so neither the
// wire format nor the gobind surface changed with the collapse.

package mobile

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
)

// The stored ids of the four built-in match targets (desktop OutboundIds).
// Kept exported: they are part of the gobind surface even though this file no
// longer parses the editor's `prefix:value -> outbound` text.
const (
	OutboundProxy      int64 = -1
	OutboundDirect     int64 = -2
	OutboundBlock      int64 = -3
	OutboundWarpBypass int64 = -5
)

// RuleType ids (RuleType.kt). Only the simple-address family is edited as text.
const (
	ruleTypeCustom           = 0
	ruleTypeSimpleAddrProxy  = 1
	ruleTypeSimpleAddrBypass = 2
	ruleTypeSimpleAddrBlock  = 3
	ruleTypeSimpleAddrWarp   = 10
)

const (
	getGlobalRulesMethod   Method = "getGlobalRules"
	saveGlobalRulesMethod  Method = "saveGlobalRules"
	deleteGlobalRuleMethod Method = "deleteGlobalRule"
)

func init() {
	register(getGlobalRulesMethod, handleGetGlobalRules)
	register(saveGlobalRulesMethod, handleSaveGlobalRules)
	register(deleteGlobalRuleMethod, handleDeleteGlobalRule)
}

// --- the single rule table ----------------------------------------------------

const globalRulesDoc = "global_route_rules"

// readGlobalRulesLocked loads the one rule table in display order.
//
// ADR compatibility path: an install written by the retired multi-profile
// build has no `global_route_rules.json` but still has `route_rules.json` (and
// the matching `route_profiles.json`). Its rules are merged into the new table
// once, in `rule_order`, with fresh ids, and written through the same atomic
// document writer. The legacy documents are left on disk untouched — no code
// path reads them again — so a downgrade still sees its own data. Checking
// file existence rather than row count matters: a user who intentionally
// emptied the global table must not get the old rows resurrected on next read.
//
// Caller holds routeStoreMu.
func readGlobalRulesLocked() ([]row, error) {
	if !documentExists(globalRulesDoc) &&
		(documentExists("route_rules") || documentExists("route_profiles")) {
		legacy, err := legacyRuleRows()
		if err != nil {
			return nil, err
		}
		if len(legacy) > 0 {
			if err := writeDocument(globalRulesDoc, legacy); err != nil {
				return nil, err
			}
		}
	}
	rows, err := readDocument(globalRulesDoc)
	if err != nil {
		return nil, err
	}
	sort.SliceStable(rows, func(i, j int) bool {
		return rowInt(rows[i], "rule_order") < rowInt(rows[j], "rule_order")
	})
	return rows, nil
}

// legacyRuleRows folds every rule of the retired `route_rules.json` into the
// single table. All profiles are merged, ordered by their old `rule_order`;
// the profile partition key is dropped. Ids are reused when present and unique,
// otherwise allocated from the highest id seen.
func legacyRuleRows() ([]row, error) {
	old, err := readDocument("route_rules")
	if err != nil {
		return nil, err
	}
	ordered := append([]row(nil), old...)
	sort.SliceStable(ordered, func(i, j int) bool {
		return rowInt(ordered[i], "rule_order") < rowInt(ordered[j], "rule_order")
	})
	used := map[int64]bool{}
	next := int64(1)
	out := make([]row, 0, len(ordered))
	for _, legacy := range ordered {
		copied := row{}
		for key, value := range legacy {
			if key == "route_profile_id" || key == "__current" {
				continue
			}
			copied[key] = value
		}
		id := rowInt64(copied, "id")
		if id <= 0 || used[id] {
			for used[next] {
				next++
			}
			id = next
		}
		if id >= next {
			next = id + 1
		}
		used[id] = true
		copied["id"] = id
		out = append(out, copied)
	}
	for index, rule := range out {
		rule["rule_order"] = index
	}
	return out, nil
}

// globalRulesPayloadLocked renders the table for the wire: every rule carries
// its id and an `enabled` flag derived from the row's own `disabled` field.
// There is no per-profile opt-out any more, so a client cannot pass a profile
// id to change what this answers. Caller holds routeStoreMu.
func globalRulesPayloadLocked() (any, error) {
	rows, err := readGlobalRulesLocked()
	if err != nil {
		return nil, err
	}
	wire := wireRules(rows)
	for index, entry := range wire {
		reply := entry.(map[string]any)
		reply["id"] = rowInt64(rows[index], "id")
		reply["enabled"] = !rowBool(rows[index], "disabled")
	}
	return map[string]any{"rules": wire}, nil
}

// handleGetGlobalRules answers the whole table. The payload a legacy caller
// still sends (`profileId`) is deliberately ignored.
func handleGetGlobalRules(_ json.RawMessage) (any, error) {
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()
	return globalRulesPayloadLocked()
}

// handleSaveGlobalRules replaces the whole table. Rows that echo an existing
// id keep it (and keep every column the client did not send); a caller that
// does not echo ids keeps them by position. Only genuinely new rows get a
// fresh id. `rule_order` is the global display order.
func handleSaveGlobalRules(data json.RawMessage) (any, error) {
	var payload struct {
		Rules []map[string]any `json:"rules"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	existing, err := readGlobalRulesLocked()
	if err != nil {
		return nil, err
	}
	byID := map[int64]row{}
	used := map[int64]bool{}
	maxID := int64(0)
	for _, rule := range existing {
		if id := rowInt64(rule, "id"); id > 0 {
			byID[id] = rule
			used[id] = true
			if id > maxID {
				maxID = id
			}
		}
	}
	// Reserve all explicit ids before allocating new ones: a caller is allowed to
	// send rows in any order, so a later row's id must not be handed to an earlier
	// row that omitted one.
	explicit := make([]int64, len(payload.Rules))
	for index, incoming := range payload.Rules {
		if raw, ok := incoming["id"]; ok {
			if candidate := int64Of(raw); candidate > 0 {
				explicit[index] = candidate
				if candidate > maxID {
					maxID = candidate
				}
			}
		}
	}

	rows := make([]row, 0, len(payload.Rules))
	for index, incoming := range payload.Rules {
		var id int64
		var preserve row
		if candidate := explicit[index]; candidate > 0 {
			// An echoed id keeps that row's identity and every column the client
			// did not send. A brand-new id starts a fresh row.
			id, preserve = candidate, byID[candidate]
			if used[id] && preserve == nil {
				// Duplicate id in one payload: treat the later occurrence as new.
				id = 0
			}
		}
		if id == 0 && index < len(existing) {
			// Positional fallback for a client that does not echo ids.
			if candidate := rowInt64(existing[index], "id"); candidate > 0 && !used[candidate] {
				id, preserve = candidate, existing[index]
			}
		}
		if id == 0 {
			for used[maxID+1] {
				maxID++
			}
			maxID++
			id = maxID
		}
		used[id] = true
		stored := ruleRowFromWire(index, incoming, preserve)
		stored["id"] = id
		stored["rule_order"] = index
		rows = append(rows, stored)
	}
	if err := writeDocument(globalRulesDoc, rows); err != nil {
		return nil, err
	}
	return globalRulesPayloadLocked()
}

// handleDeleteGlobalRule removes one row by id and rewrites the table.
func handleDeleteGlobalRule(data json.RawMessage) (any, error) {
	var payload struct {
		ID int64 `json:"id"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		return nil, err
	}
	routeStoreMu.Lock()
	defer routeStoreMu.Unlock()

	rows, err := readGlobalRulesLocked()
	if err != nil {
		return nil, err
	}
	kept := make([]row, 0, len(rows))
	for _, rule := range rows {
		if rowInt64(rule, "id") != payload.ID {
			kept = append(kept, rule)
		}
	}
	if len(kept) == len(rows) {
		return nil, nil // unknown id: nothing to write
	}
	if err := writeDocument(globalRulesDoc, kept); err != nil {
		return nil, err
	}
	return nil, nil
}

// --- rule normalisation -------------------------------------------------------

// ruleStringColumns are the rule columns the editor round-trips as plain strings.
var ruleStringColumns = []string{
	"ip_version", "network", "protocol", "reject_method", "override_address",
	"override_port", "tls_fragment_fallback_delay", "tls_spoof", "tls_spoof_method", "strategy",
}

// ruleListColumns are the rule columns the editor round-trips as arrays.
var ruleListColumns = []string{
	"inbound_json", "domain_json", "domain_suffix_json", "domain_keyword_json",
	"domain_regex_json", "source_ip_cidr_json", "ip_cidr_json", "source_port_json",
	"source_port_range_json", "port_json", "port_range_json", "process_name_json",
	"process_path_json", "process_path_regex_json", "package_name_json",
	"package_name_regex_json", "network_type_json", "wifi_ssid_json", "wifi_bssid_json",
	"rule_set_json", "sniffers_json",
}

// ruleBoolColumns are the rule columns the editor round-trips as booleans.
var ruleBoolColumns = []string{
	"source_ip_is_private", "ip_is_private", "tls_fragment", "tls_record_fragment",
	"invert", "no_drop", "sniff_override_dest", "network_is_expensive",
}

// wireRules renders stored rows as the editor's rule objects. Both the column-shaped names
// (BboxRoutes.ruleToMap's STRING/LIST/BOOL field groups) and the shorthand the routing screen
// reads are present, so neither caller has to guess which spelling it got.
func wireRules(rows []row) []any {
	out := make([]any, 0, len(rows))
	for _, r := range rows {
		wire := map[string]any{
			"name":        rowString(r, "name"),
			"type":        ruleTypeToken(rowInt(r, "type")),
			"disabled":    rowBool(r, "disabled"),
			"action":      rowString(r, "action"),
			"outbound_id": rowIntOr(r, "outbound_id", OutboundDirect),
		}
		for _, column := range ruleStringColumns {
			wire[column] = rowString(r, column)
		}
		for _, column := range ruleListColumns {
			wire[column] = jsonList(rowString(r, column))
		}
		for _, column := range ruleBoolColumns {
			wire[column] = rowBool(r, column)
		}
		// The shorthand names the routing screen reads.
		if column, ok := shorthandColumn("domain"); ok {
			wire["domain"] = wire[column]
		}
		if column, ok := shorthandColumn("domain_suffix"); ok {
			wire["domain_suffix"] = wire[column]
		}
		if column, ok := shorthandColumn("ip_cidr"); ok {
			wire["ip_cidr"] = wire[column]
		}
		if column, ok := shorthandColumn("process_name"); ok {
			wire["process_name"] = wire[column]
		}
		if column, ok := shorthandColumn("network_type"); ok {
			wire["network_type"] = wire[column]
		}
		out = append(out, wire)
	}
	return out
}

// ruleTypeToken is RuleType's token for an id (RuleType.values().firstOrNull { it.id == … }).
func ruleTypeToken(id int) string {
	switch id {
	case ruleTypeSimpleAddrProxy:
		return "simple_address_proxy"
	case ruleTypeSimpleAddrBypass:
		return "simple_address_bypass"
	case ruleTypeSimpleAddrBlock:
		return "simple_address_block"
	case ruleTypeSimpleAddrWarp:
		return "simple_address_warp_bypass"
	case 4:
		return "simple_process_name_proxy"
	case 5:
		return "simple_process_name_bypass"
	case 6:
		return "simple_process_name_block"
	case 7:
		return "simple_process_path_proxy"
	case 8:
		return "simple_process_path_bypass"
	case 9:
		return "simple_process_path_block"
	case 11:
		return "simple_process_name_warp_bypass"
	case 12:
		return "simple_process_path_warp_bypass"
	}
	return "custom"
}

func ruleTypeID(token string) (int, bool) {
	switch token {
	case "simple_address_proxy":
		return ruleTypeSimpleAddrProxy, true
	case "simple_address_bypass":
		return ruleTypeSimpleAddrBypass, true
	case "simple_address_block":
		return ruleTypeSimpleAddrBlock, true
	case "simple_address_warp_bypass":
		return ruleTypeSimpleAddrWarp, true
	case "simple_process_name_proxy":
		return 4, true
	case "simple_process_name_bypass":
		return 5, true
	case "simple_process_name_block":
		return 6, true
	case "simple_process_path_proxy":
		return 7, true
	case "simple_process_path_bypass":
		return 8, true
	case "simple_process_path_block":
		return 9, true
	case "simple_process_name_warp_bypass":
		return 11, true
	case "simple_process_path_warp_bypass":
		return 12, true
	case "custom":
		return ruleTypeCustom, true
	}
	return ruleTypeCustom, false
}

// shorthandColumn maps the routing screen's short field names onto the stored columns.
func shorthandColumn(key string) (string, bool) {
	switch key {
	case "domain":
		return "domain_json", true
	case "domain_suffix":
		return "domain_suffix_json", true
	case "ip_cidr":
		return "ip_cidr_json", true
	case "process_name":
		return "process_name_json", true
	case "network_type":
		return "network_type_json", true
	}
	return "", false
}

// ruleListColumnOf maps ANY short list name that has a known column onto that column.
//
// The five names above are the ones the routing screen reads back as shorthand, but a writer
// can spell any of the twenty-one list conditions the short way. Only the columns are read
// again (Kotlin's RouteJsonStore, the config generator), so a short name stored verbatim is a
// condition that silently does not exist — it would build as a match-all rule.
func ruleListColumnOf(key string) (string, bool) {
	if column, ok := shorthandColumn(key); ok {
		return column, true
	}
	column := key + "_json"
	for _, known := range ruleListColumns {
		if known == column {
			return column, true
		}
	}
	return "", false
}

// ruleRowFromWire turns one editor rule into a stored row.
//
// [preserve] carries the row this rule already had (nil for a new one): every column the
// editor does not send is copied from it rather than reset, so a rule with port ranges,
// keyword lists or TLS options does not come back with those conditions wiped.
//
// There is no profile partition any more; the caller assigns `id` and `rule_order`.
func ruleRowFromWire(order int, rule map[string]any, preserve row) row {
	out := row{}
	for key, value := range preserve {
		if key == "__current" {
			continue
		}
		out[key] = value
	}
	for key, value := range rule {
		switch key {
		case "name", "action":
			out[key] = fmt.Sprint(value)
		case "type":
			if token, ok := value.(string); ok {
				ruleType, known := ruleTypeID(token)
				if !known && token != "" {
					// An unknown token is a custom rule, which is what BboxRoutes did.
					ruleType = ruleTypeCustom
				}
				out["type"] = ruleType
			} else {
				out["type"] = intOf(value)
			}
		case "disabled", "invert", "no_drop", "sniff_override_dest", "network_is_expensive",
			"tls_fragment", "tls_record_fragment", "source_ip_is_private", "ip_is_private":
			out[key] = boolOf(value)
		case "outbound_id":
			out[key] = int64Of(value)
		default:
			if strings.HasSuffix(key, "_json") {
				if encoded, err := json.Marshal(value); err == nil {
					out[key] = string(encoded)
				}
				continue
			}
			if column, ok := ruleListColumnOf(key); ok {
				if encoded, err := json.Marshal(value); err == nil {
					out[column] = string(encoded)
				}
				continue
			}
			out[key] = value
		}
	}
	out["rule_order"] = order
	return out
}
