// Stored-form validation for the five TLS/transport outbounds the Kotlin model
// used to check: vmess, vless, trojan, hysteria and hysteria2.
//
// profile_export_advanced.go owns the stored reader for these types; it already
// refuses an unported field and normalises the stored document byte-for-byte.
// The save gate adds the checks the editor cannot infer from that parse:
// the endpoint (server/port, with hysteria's server_ports and realm forms),
// the protocol credentials, VLESS encryption/Vision, the shared TLS and
// transport value checks, and hysteria's port ranges/hop/obfs/realm rules.
//
// The TLS and transport checks reuse the S5 stored validators (the same tables
// juicity/naive/ssh/wg use), so a document the old model refused is refused
// here for the same reason instead of being copied verbatim into the kernel
// config.
package mobile

import (
	"fmt"
	"net"
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

	tlsOn := configJSONBool(node.TLS, "enabled") || node.AlwaysTLS
	if tlsOn {
		profileS5ValidateTLS(&issues, node.TLS, false)
	}
	validateStoredAdvancedTransport(&issues, node, tlsOn)

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
		validateStoredVlessEncryption(&issues, canonicalObject)
		validateStoredVlessFlow(&issues, canonicalObject, node)
	case "trojan":
		if strings.TrimSpace(configJSONString(canonicalObject, "password")) == "" {
			issues.addError("password", "password is required")
		}
	case "hysteria", "hysteria2":
		validateStoredHysteria(&issues, node, realm, rawType)
	}
	return finishStoredValidation(result, issues, canonical), true, nil
}

func validateStoredAdvancedTransport(issues *storedIssues, node *profileExportAdvanced, tlsOn bool) {
	if !node.HasTr {
		return
	}
	kind := strings.TrimSpace(configJSONString(node.Transport, "type"))
	switch kind {
	case "", "tcp", "ws", "httpupgrade", "http", "grpc", "quic", "xhttp", "mkcp":
	case "raw", "h2":
		// The reader normalises these aliases to http/tcp; a raw value here is
		// a hand-written document the builder would pass through.
		issues.addError("transport.type", "transport.type is not a sing-box transport")
		return
	default:
		issues.addError("transport.type", "transport.type is not a sing-box transport")
		return
	}
	if kind == "xhttp" {
		if mode := strings.TrimSpace(configJSONString(node.Transport, "mode")); mode != "" &&
			mode != "auto" && mode != "packet-up" && mode != "stream-up" && mode != "stream-one" {
			issues.addError("transport.mode", "transport.mode must be auto, packet-up, stream-up or stream-one")
		}
	}
	if kind == "mkcp" {
		if header := strings.TrimSpace(configJSONString(node.Transport, "header_type")); header != "" &&
			header != "none" && header != "srtp" && header != "utp" && header != "wechat-video" &&
			header != "dtls" && header != "wireguard" {
			issues.addError("transport.header_type", "transport.header_type is not a sing-box KCP header")
		}
	}
	if kind == "http" || kind == "grpc" {
		for _, key := range []string{"idle_timeout", "ping_timeout"} {
			if value := strings.TrimSpace(configJSONString(node.Transport, key)); value != "" && configValidDuration(value) != "" {
				issues.addError("transport."+key, "transport."+key+" must be a duration")
			}
		}
	}
	if kind == "quic" {
		if !tlsOn {
			issues.addError("transport.type", "the quic transport requires TLS")
		}
		if reality, ok := node.TLS["reality"].(map[string]any); ok {
			if configJSONBool(reality, "enabled") || configJSONString(reality, "public_key") != "" {
				issues.addError("transport.type", "the quic transport cannot use REALITY")
			}
		}
	}
}

func validateStoredVlessEncryption(issues *storedIssues, object map[string]any) {
	encryption := strings.TrimSpace(configJSONString(object, "encryption"))
	if encryption == "" {
		issues.addError("encryption", "encryption is required (use none)")
		return
	}
	if encryption == "none" {
		return
	}
	parts := strings.Split(encryption, ".")
	if len(parts) < 4 || parts[0] != "mlkem768x25519plus" {
		issues.addError("encryption", "encryption must be none or mlkem768x25519plus.<mode>.<rtt>.<keys>")
		return
	}
	if parts[1] != "native" && parts[1] != "xorpub" && parts[1] != "random" {
		issues.addError("encryption", "the VLESS encryption mode must be native, xorpub or random")
		return
	}
	if parts[2] != "1rtt" && parts[2] != "0rtt" {
		issues.addError("encryption", "the VLESS encryption rtt must be 1rtt or 0rtt")
		return
	}
	// Parts shorter than 20 characters are padding specs, not keys.
	for _, part := range parts[3:] {
		if len(part) < 20 {
			continue
		}
		decoded, ok := profileBase64Decode(part, true)
		if !ok {
			decoded, ok = profileBase64Decode(part, false)
		}
		if !ok || (len(decoded) != 32 && len(decoded) != 1184) {
			issues.addError("encryption", "a VLESS encryption key must be base64 of 32 or 1184 bytes")
			return
		}
	}
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

func validateStoredHysteria(issues *storedIssues, node *profileExportAdvanced, realm bool, rawType string) {
	// The stored reader has no protocol_version field: the type name carries it
	// (hysteria2 is v2; hysteria defaults to v1 unless the document says 2).
	version := "1"
	if rawType == "hysteria2" {
		version = "2"
	} else if field := strings.TrimSpace(configJSONString(node.Fields, "protocol_version")); field == "2" {
		version = "2"
	}
	if realm {
		validateStoredHysteriaRealm(issues, node)
		return
	}
	hopping := storedHysteriaHasPorts(node)
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
	interval := strings.TrimSpace(configJSONString(node.Fields, "hop_interval"))
	intervalDuration := time.Duration(0)
	intervalOK := false
	if interval != "" {
		if duration, err := time.ParseDuration(interval); err != nil || duration < 0 {
			issues.addError("hop_interval", "hop_interval is not a duration")
		} else {
			intervalDuration, intervalOK = duration, true
			if hopping && duration > 0 && duration < 5*time.Second {
				issues.addError("hop_interval", "hop_interval must be at least 5s when hopping")
			}
		}
	}
	if maxInterval := strings.TrimSpace(configJSONString(node.Fields, "hop_interval_max")); maxInterval != "" {
		duration, err := time.ParseDuration(maxInterval)
		if err != nil || duration < 0 {
			issues.addError("hop_interval_max", "hop_interval_max is not a duration")
		} else if hopping && intervalOK && intervalDuration > 0 && intervalDuration > duration {
			issues.addError("hop_interval_max", "hop_interval_max must not be shorter than hop_interval")
		}
	}
	if version != "2" {
		return
	}
	obfs, ok := node.Fields["obfs"].(map[string]any)
	if !ok {
		return
	}
	kind := strings.ToLower(strings.TrimSpace(configJSONString(obfs, "type")))
	if kind == "" {
		kind = "salamander"
	}
	if kind != "salamander" && kind != "gecko" {
		issues.addError("obfs.type", "obfs.type must be salamander or gecko")
		return
	}
	if kind != "gecko" {
		return
	}
	minSize := configJSONInt(obfs["min_packet_size"])
	maxSize := configJSONInt(obfs["max_packet_size"])
	if minSize < 0 || maxSize < 0 || minSize > 2048 || maxSize > 2048 {
		issues.addError("obfs", "gecko packet sizes must be between 0 and 2048")
	} else if (packetSizeOr(minSize, 512)) > (packetSizeOr(maxSize, 1200)) {
		issues.addError("obfs", "gecko min_packet_size must not exceed max_packet_size")
	}
}

func packetSizeOr(value, fallback int) int {
	if value == 0 {
		return fallback
	}
	return value
}

func validateStoredHysteriaRealm(issues *storedIssues, node *profileExportAdvanced) {
	realm, _ := node.Fields["realm"].(map[string]any)
	stun := stringItems(realm["stun_servers"])
	if strings.TrimSpace(configJSONString(realm, "server_url")) == "" ||
		strings.TrimSpace(configJSONString(realm, "realm_id")) == "" ||
		len(stun) == 0 {
		issues.addError("realm", "the realm needs a server URL, a realm id and one STUN server")
		return
	}
	if !storedHTTPURL(strings.TrimSpace(configJSONString(realm, "server_url"))) {
		issues.addError("realm.server_url", "the realm URL must be an http(s) URL with a host")
	}
	for _, raw := range stun {
		item := strings.TrimSpace(raw)
		if item == "" {
			continue
		}
		host, port, err := net.SplitHostPort(item)
		if err != nil || host == "" || !storedPortValueOK(port) {
			issues.addError("realm.stun_servers", "a realm STUN server must be host:port")
			return
		}
	}
}

func storedPortValueOK(text string) bool {
	_, ok := storedPortValue(text)
	return ok
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
