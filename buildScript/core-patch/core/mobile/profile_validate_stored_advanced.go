// Stored-form validation for the five TLS/transport outbounds the Kotlin model
// used to check: vmess, vless, trojan, hysteria and hysteria2.
//
// profile_export_advanced.go owns the stored reader for these types; it already
// refuses an unported field and normalises the stored document byte-for-byte.
// The save gate adds the checks the editor cannot infer from that parse:
// the endpoint (server/port, with hysteria's server_ports and realm forms),
// the protocol credentials, the packet encoding, VLESS Vision's TLS/TCP
// requirement, and hysteria's port ranges and hop interval.
//
// TLS/transport values themselves are accepted as parsed: the exported reader
// validates their structure and rejects unknown fields, and the config builder
// is the last line for values the kernel would refuse at load time. This is a
// deliberate reduction from the old outbound classes' full TLS checks — the
// editor's save path must not refuse a document the core accepts.
package mobile

import (
	"fmt"
	"strings"
	"time"
)

// handleProfileValidateStoredAdvanced answers profileExportAdvancedTypes. The
// bool is false for every other type, so the caller keeps its dispatch.
func handleProfileValidateStoredAdvanced(object map[string]any, rawType string) (any, bool, error) {
	if !profileExportAdvancedTypes[rawType] {
		return nil, false, nil
	}
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	issues := storedIssues{}
	// The stored reader expects the model's export form (vmess/vless always
	// write their default packet encoding and vless its encryption), so the
	// canonical document is what gets parsed and checked.
	canonical, reason, err := profileStoredNormalizeAdvanced(object)
	if err != nil {
		return nil, true, err
	}
	if reason != "" {
		// The type is modeled but this document carries a field the reader
		// cannot reproduce; the editor shows the reason instead of falling back.
		issues.addError("", reason)
		return finishStoredValidation(result, issues, ""), true, nil
	}
	canonicalObject, ok := configDecodeJSONObject(canonical)
	if !ok {
		return nil, true, fmt.Errorf("profile.validate: the normalizer answered a non-object document")
	}
	node, err := profileExportAdvancedFromObject(rawType, canonicalObject)
	if err != nil {
		issues.addError("", err.Error())
		return finishStoredValidation(result, issues, canonical), true, nil
	}

	realm := profileExportHysteriaRealmActive(node)
	validateStoredAdvancedEndpoint(&issues, node, realm)
	switch rawType {
	case "vmess":
		if strings.TrimSpace(configJSONString(canonicalObject, "uuid")) == "" {
			issues.addError("uuid", "uuid is required")
		}
		if security := strings.TrimSpace(configJSONString(canonicalObject, "security")); security != "" && !vmessSecurityKnown(security) {
			issues.addError("security", "security is not a VMess cipher")
		}
		validateStoredAdvancedPacketEncoding(&issues, canonicalObject)
	case "vless":
		if strings.TrimSpace(configJSONString(canonicalObject, "uuid")) == "" {
			issues.addError("uuid", "uuid is required")
		}
		validateStoredAdvancedPacketEncoding(&issues, canonicalObject)
		validateStoredVlessFlow(&issues, canonicalObject, node)
	case "trojan":
		if strings.TrimSpace(configJSONString(canonicalObject, "password")) == "" {
			issues.addError("password", "password is required")
		}
	case "hysteria", "hysteria2":
		validateStoredHysteria(&issues, node, realm)
	}
	return finishStoredValidation(result, issues, canonical), true, nil
}

func validateStoredAdvancedEndpoint(issues *storedIssues, node *profileExportAdvanced, realm bool) {
	if realm {
		return
	}
	if strings.TrimSpace(node.Server) == "" {
		issues.addError("server", "server is required")
	}
	if node.Port <= 0 && !storedHysteriaHasPorts(node) {
		issues.addError("server_port", "server port is required")
	} else if node.Port < 0 || node.Port > 65535 {
		issues.addError("server_port", "server port must be between 1 and 65535")
	}
}

func validateStoredAdvancedPacketEncoding(issues *storedIssues, object map[string]any) {
	switch value := configJSONString(object, "packet_encoding"); value {
	case "", "packetaddr", "xudp":
	default:
		issues.addError("packet_encoding", "packet_encoding must be empty, packetaddr or xudp")
	}
}

func validateStoredVlessFlow(issues *storedIssues, object map[string]any, node *profileExportAdvanced) {
	flow := strings.TrimSpace(configJSONString(object, "flow"))
	if flow == "" {
		return
	}
	if flow != "xtls-rprx-vision" {
		issues.addError("flow", "flow must be empty or xtls-rprx-vision")
		return
	}
	tlsOn := configJSONBool(node.TLS, "enabled")
	kind := configJSONString(node.Transport, "type")
	if !tlsOn || !(kind == "" || kind == "tcp") {
		issues.addError("flow", "xtls-rprx-vision needs TLS over a plain TCP dial")
	}
}

func validateStoredHysteria(issues *storedIssues, node *profileExportAdvanced, realm bool) {
	version := strings.TrimSpace(configJSONString(node.Fields, "protocol_version"))
	if version == "" {
		version = "1"
	}
	if version != "1" && version != "2" {
		issues.addError("protocol_version", "protocol_version must be 1 or 2")
	}
	if realm {
		validateStoredHysteriaRealm(issues, node)
		return
	}
	for _, raw := range stringItems(node.Fields["server_ports"]) {
		item := strings.TrimSpace(raw)
		if item == "" {
			continue
		}
		parts := strings.SplitN(item, ":", 2)
		if len(parts) != 2 {
			issues.addError("server_ports", "server_ports items are port ranges like 1000:2000")
			break
		}
		from, fromOK := storedPortValue(parts[0])
		to, toOK := storedPortValue(parts[1])
		if !fromOK || !toOK || from > to {
			issues.addError("server_ports", "server_ports items are port ranges like 1000:2000")
			break
		}
	}
	if hop := strings.TrimSpace(configJSONString(node.Fields, "hop_interval")); hop != "" {
		if duration, err := time.ParseDuration(hop); err != nil || duration < 0 {
			issues.addError("hop_interval", "hop_interval is not a duration")
		}
	}
}

func validateStoredHysteriaRealm(issues *storedIssues, node *profileExportAdvanced) {
	realm, _ := node.Fields["realm"].(map[string]any)
	if strings.TrimSpace(configJSONString(realm, "server_url")) == "" ||
		strings.TrimSpace(configJSONString(realm, "realm_id")) == "" ||
		len(stringItems(realm["stun_servers"])) == 0 {
		issues.addError("realm", "the realm needs a server URL, a realm id and one STUN server")
		return
	}
	if !storedHTTPURL(strings.TrimSpace(configJSONString(realm, "server_url"))) {
		issues.addError("realm.server_url", "the realm URL must be an http(s) URL with a host")
	}
}

func storedHysteriaHasPorts(node *profileExportAdvanced) bool {
	for _, raw := range stringItems(node.Fields["server_ports"]) {
		if strings.TrimSpace(raw) != "" {
			return true
		}
	}
	return false
}

// stringItems is configJSONStringListValue without the scalar coersion:
// hysteria's server_ports/stun_servers are stored as strings.
func stringItems(value any) []string {
	list, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(list))
	for _, item := range list {
		if text, ok := item.(string); ok {
			out = append(out, text)
		}
	}
	return out
}

func storedPortValue(text string) (int, bool) {
	if text == "" {
		return 0, false
	}
	port := 0
	for _, char := range text {
		if char < '0' || char > '9' {
			return 0, false
		}
		port = port*10 + int(char-'0')
		if port > 65535 {
			return 0, false
		}
	}
	return port, port >= 1
}