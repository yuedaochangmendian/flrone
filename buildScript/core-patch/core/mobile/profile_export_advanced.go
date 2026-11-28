// S5 export, advanced slice: the stored-form exporter for the five TLS/
// transport-bearing types (vmess, vless, trojan, hysteria, hysteria2).
//
// Oracle: Outbound.exportToJson/exportToLink/exportIdentity on the Kotlin
// models (outbound/types/{Vmess,Vless,Trojan,Hysteria}.kt plus outbound/common/
// {Tls,Transport,Multiplex,QuicFields}.kt) and LinkBuilder.formatQuery. The
// JVM test ProfileStoredGoParityTest pins the exact bytes this file emits.
//
// This file reads a stored JSON document (NodeRow.outbound_json) the way
// Outbound.parseFromJson does and re-emits the canonical form. It is the
// inverse of profile_import_advanced.go: a field whose Kotlin normalisation
// has not been ported here is refused with a concrete reason, never silently
// defaulted. The dispatcher in profile_export_simple.go falls back to the
// Kotlin exporter on any refusal.
package mobile

import (
	"sort"
	"strconv"
	"strings"
)

var profileExportAdvancedTypes = map[string]bool{
	"vmess": true, "vless": true, "trojan": true,
	"hysteria": true, "hysteria2": true,
}

// profileExportAdvanced is the stored outbound as this slice models it. The
// parsed map[TLS/transport/mux/quic] values are re-emitted through the same
// canonical writer the Kotlin JsonWriter uses; tri-state blocks are kept as
// maps so an explicit false survives the round-trip.
type profileExportAdvanced struct {
	Type      string
	Name      string
	Server    string
	Port      int
	Fields    map[string]any
	TLS       map[string]any
	Transport map[string]any
	Multiplex map[string]any
	QUIC      map[string]any
	HasTLS    bool
	HasTr     bool
	HasMux    bool
	HasQUIC   bool
	AlwaysTLS bool
}

func (node *profileExportAdvanced) object() map[string]any {
	object := map[string]any{"type": node.Type}
	realm := profileExportHysteriaRealmActive(node)
	if node.Name != "" {
		object["tag"] = node.Name
	}
	if node.Server != "" && !realm {
		object["server"] = node.Server
	}
	if node.Port > 0 && !realm {
		object["server_port"] = node.Port
	}
	for key, value := range node.Fields {
		if key == "realm" && node.Type != "hysteria2" {
			continue
		}
		object[key] = value
	}
	if realm {
		// Hysteria.applyRealmObject: realm replaces the server keys.
		delete(object, "server")
		delete(object, "server_port")
		delete(object, "server_ports")
	}
	if node.HasTLS || node.AlwaysTLS {
		tls := node.TLS
		if tls == nil {
			tls = map[string]any{}
		}
		object["tls"] = tls
	}
	if node.HasTr {
		object["transport"] = node.Transport
	}
	if node.HasMux {
		object["multiplex"] = node.Multiplex
	}
	if node.HasQUIC {
		for key, value := range node.QUIC {
			object[key] = value
		}
	}
	return object
}

// profileExportHysteriaRealmActive is Hysteria.realmActive for the stored
// exporter: a hysteria2 document carrying a realm object.
func profileExportHysteriaRealmActive(node *profileExportAdvanced) bool {
	if node == nil || node.Type != "hysteria2" {
		return false
	}
	_, ok := node.Fields["realm"].(map[string]any)
	return ok
}

func (node *profileExportAdvanced) json() (string, error) {
	encoded, err := MarshalCanonicalJSON(node.object())
	return string(encoded), err
}

func (node *profileExportAdvanced) clone() *profileExportAdvanced {
	copied := *node
	return &copied
}

// handleProfileExportAdvanced returns supported=false with the exact reason
// when a document carries a field this slice cannot reproduce byte-for-byte.
// The caller's reply shape deliberately omits the reason (the wire contract
// has no reason field yet), so a fallback to Kotlin still happens; the reason
// is pinned by the Go tests that call this function directly.
func handleProfileExportAdvanced(object map[string]any, nameOverride *string) (profileExportReply, bool, error) {
	rawType := configJSONString(object, "type")
	if !profileExportAdvancedTypes[rawType] {
		return profileExportReply{}, false, nil
	}
	node, err := profileExportAdvancedFromObject(rawType, object)
	if err != nil {
		return profileExportReply{Supported: false, Type: rawType}, true, err
	}
	if nameOverride != nil {
		node.Name = strings.TrimSpace(*nameOverride)
	}
	storedJSON, err := node.json()
	if err != nil {
		return profileExportReply{}, true, err
	}
	withoutTag := node.clone()
	withoutTag.Name = ""
	dedupJSON, err := withoutTag.json()
	if err != nil {
		return profileExportReply{}, true, err
	}
	identity := storedJSON
	if node.Server != "" || profileExportHysteriaRealmActive(node) {
		encoded, encodeErr := MarshalCanonicalJSON(profileExportAdvancedIdentity(node))
		if encodeErr != nil {
			return profileExportReply{}, true, encodeErr
		}
		identity = string(encoded)
	}
	link, err := profileExportAdvancedLink(node)
	if err != nil {
		return profileExportReply{}, true, err
	}
	return profileExportReply{
		Supported:   true,
		Type:        node.Type,
		Name:        node.Name,
		DisplayType: profileExportAdvancedDisplayType(node.Type),
		JSON:        storedJSON,
		Link:        link,
		JSONLink:    "throne://add/" + profileBase64Encode([]byte(storedJSON), true, false),
		Identity:    identity,
		DedupKey:    "throne://add/" + profileBase64Encode([]byte(dedupJSON), true, false),
	}, true, nil
}

func profileExportAdvancedDisplayType(profileType string) string {
	switch profileType {
	case "vmess":
		return "VMess"
	case "vless":
		return "VLESS"
	case "trojan":
		return "Trojan"
	case "hysteria", "hysteria2":
		return "Hysteria"
	}
	return profileType
}

// --- parse: from the stored row to the exportable model --------------------

func profileExportAdvancedFromObject(rawType string, object map[string]any) (*profileExportAdvanced, error) {
	node := &profileExportAdvanced{Type: rawType, Name: configJSONString(object, "tag")}
	server := configJSONString(object, "server")
	if server != "" {
		if _, valid := profileLinkNormalizeHost(server); !valid {
			return nil, profileUnsupported("profileExport: invalid server " + strconv.Quote(server))
		}
		if strings.Contains(server, "%") {
			return nil, profileUnsupported("server host needs percent-decoding")
		}
		node.Server = configToACEHost(server)
	}
	node.Port = configJSONInt(object["server_port"])
	dial, err := profileExportDialFields(object)
	if err != nil {
		return nil, err
	}
	node.Fields = dial

	switch rawType {
	case "vmess":
		if err := profileExportVMessFields(node, object); err != nil {
			return nil, err
		}
	case "vless":
		if err := profileExportVlessFields(node, object); err != nil {
			return nil, err
		}
	case "trojan":
		if err := profileExportTrojanFields(node, object); err != nil {
			return nil, err
		}
	case "hysteria", "hysteria2":
		if err := profileExportHysteriaFields(node, object, rawType == "hysteria"); err != nil {
			return nil, err
		}
	}

	// TLS, transport and multiplex are shared by all five types (hysteria
	// carries TLS + quic instead of a transport/mux block).
	if value, present := object["tls"]; present {
		tls, err := profileExportTLS(value, rawType)
		if err != nil {
			return nil, err
		}
		node.TLS, node.HasTLS = tls, true
	}
	if rawType != "hysteria" && rawType != "hysteria2" {
		if value, present := object["transport"]; present {
			transport, err := profileExportTransport(value)
			if err != nil {
				return nil, err
			}
			if len(transport) > 0 {
				node.Transport, node.HasTr = transport, true
			}
		}
		if value, present := object["multiplex"]; present {
			mux, err := profileExportMultiplex(value)
			if err != nil {
				return nil, err
			}
			if len(mux) > 0 {
				node.Multiplex, node.HasMux = mux, true
			}
		}
	}
	if rawType == "hysteria" || rawType == "hysteria2" {
		quic, err := profileExportQUIC(object)
		if err != nil {
			return nil, err
		}
		if len(quic) > 0 {
			node.QUIC, node.HasQUIC = quic, true
		}
		node.AlwaysTLS = true
	}

	// Reject unknown keys only after the known ones are parsed: each family
	// has its own allowlist so a field left unported is named precisely.
	if err := profileExportCheckUnknownKeys(object, rawType); err != nil {
		return nil, err
	}
	return node, nil
}

var profileExportBaseKeys = map[string]bool{
	"type": true, "tag": true, "server": true, "server_port": true,
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true,
	"tcp_multi_path": true, "udp_fragment": true, "bind_interface": true,
	"inet4_bind_address": true, "inet6_bind_address": true,
	"tls": true, "transport": true, "multiplex": true,
	"server_ports": true, "hop_interval": true, "up_mbps": true, "down_mbps": true,
	"idle_timeout": true, "keep_alive_period": true, "stream_receive_window": true,
	"connection_receive_window": true, "max_concurrent_streams": true,
	"initial_packet_size": true, "disable_path_mtu_discovery": true,
}

func profileExportCheckUnknownKeys(object map[string]any, rawType string) error {
	allowed := map[string]bool{}
	for key := range profileExportBaseKeys {
		allowed[key] = true
	}
	switch rawType {
	case "vmess":
		for _, key := range []string{"uuid", "security", "alter_id", "global_padding", "authenticated_length", "packet_encoding"} {
			allowed[key] = true
		}
	case "vless":
		for _, key := range []string{"uuid", "flow", "encryption", "packet_encoding"} {
			allowed[key] = true
		}
	case "trojan":
		allowed["password"] = true
	case "hysteria":
		for _, key := range []string{"obfs", "auth", "auth_str", "recv_window_conn", "recv_window", "disable_mtu_discovery", "up", "down"} {
			allowed[key] = true
		}
	case "hysteria2":
		for _, key := range []string{"obfs", "password", "hop_interval_max", "bbr_profile", "disable_chrome_parrot", "realm", "obfsPassword"} {
			allowed[key] = true
		}
	}
	for key := range object {
		if !allowed[key] {
			return profileUnsupported("stored field not ported yet: " + key)
		}
	}
	return nil
}

func profileExportDialFields(object map[string]any) (map[string]any, error) {
	fields := map[string]any{}
	if configJSONBool(object, "reuse_addr") {
		fields["reuse_addr"] = true
	}
	if value := strings.TrimSpace(configJSONString(object, "connect_timeout")); value != "" {
		fields["connect_timeout"] = value
	}
	for _, key := range []string{"tcp_fast_open", "tcp_multi_path", "udp_fragment"} {
		if configJSONBool(object, key) {
			fields[key] = true
		}
	}
	for _, key := range []string{"bind_interface", "inet4_bind_address", "inet6_bind_address"} {
		if value := configJSONString(object, key); value != "" {
			fields[key] = value
		}
	}
	return fields, nil
}

// stringList is jsonStringList: a bare string is one item, a JSON array keeps
// string items, anything else is empty. Items are not trimmed by that helper.
func profileExportStringList(value any) []string {
	return configJSONStringListValue(value)
}

func profileExportVMessFields(node *profileExportAdvanced, object map[string]any) error {
	fields := node.Fields
	if uuid := configJSONString(object, "uuid"); uuid != "" {
		fields["uuid"] = uuid
	}
	if security := configJSONString(object, "security"); security != "" {
		fields["security"] = security
	}
	if alterID := configJSONInt(object["alter_id"]); alterID > 0 {
		fields["alter_id"] = alterID
	}
	if configJSONBool(object, "global_padding") {
		fields["global_padding"] = true
	}
	if configJSONBool(object, "authenticated_length") {
		fields["authenticated_length"] = true
	}
	value, present := object["packet_encoding"]
	if !present {
		return profileUnsupported("vmess requires packet_encoding")
	}
	encoding, ok := value.(string)
	if !ok {
		return profileUnsupported("packet_encoding is not a string")
	}
	if encoding != "" && encoding != "packetaddr" && encoding != "xudp" {
		return profileUnsupported("vmess packet_encoding not ported yet: " + encoding)
	}
	fields["packet_encoding"] = encoding
	return nil
}

func profileExportVlessFields(node *profileExportAdvanced, object map[string]any) error {
	fields := node.Fields
	if uuid := configJSONString(object, "uuid"); uuid != "" {
		fields["uuid"] = uuid
	}
	if flow := configJSONString(object, "flow"); flow != "" {
		fields["flow"] = flow
	}
	value, present := object["encryption"]
	if !present {
		return profileUnsupported("vless requires encryption")
	}
	encryption, ok := value.(string)
	if !ok {
		return profileUnsupported("encryption is not a string")
	}
	if encryption == "" {
		encryption = "none"
	}
	fields["encryption"] = encryption
	value, present = object["packet_encoding"]
	if !present {
		return profileUnsupported("vless requires packet_encoding")
	}
	encoding, ok := value.(string)
	if !ok {
		return profileUnsupported("packet_encoding is not a string")
	}
	if encoding != "" && encoding != "packetaddr" && encoding != "xudp" {
		return profileUnsupported("vless packet_encoding not ported yet: " + encoding)
	}
	fields["packet_encoding"] = encoding
	return nil
}

func profileExportTrojanFields(node *profileExportAdvanced, object map[string]any) error {
	if password := configJSONString(object, "password"); password != "" {
		node.Fields["password"] = password
	}
	return nil
}

func profileExportHysteriaFields(node *profileExportAdvanced, object map[string]any, v1 bool) error {
	fields := node.Fields
	if value, present := object["server_ports"]; present {
		ports := profileExportStringList(value)
		if len(ports) > 0 {
			items := make([]any, 0, len(ports))
			for _, port := range ports {
				items = append(items, hysteriaPortToPort(port))
			}
			fields["server_ports"] = items
		}
	}
	if hop := configJSONString(object, "hop_interval"); hop != "" {
		fields["hop_interval"] = hysteriaHopDuration(hop)
	}
	if up := configJSONInt(object["up_mbps"]); up > 0 {
		fields["up_mbps"] = up
	}
	if down := configJSONInt(object["down_mbps"]); down > 0 {
		fields["down_mbps"] = down
	}
	if v1 {
		if value, present := object["up"]; present {
			if mbps := configJSONInt(value); mbps > 0 {
				fields["up_mbps"] = mbps
			}
		}
		if value, present := object["down"]; present {
			if mbps := configJSONInt(value); mbps > 0 {
				fields["down_mbps"] = mbps
			}
		}
		if obfs := configJSONString(object, "obfs"); obfs != "" {
			fields["obfs"] = obfs
		}
		if auth := configJSONString(object, "auth"); auth != "" {
			fields["auth"] = auth
		}
		if auth := configJSONString(object, "auth_str"); auth != "" {
			fields["auth_str"] = auth
		}
		for _, key := range []string{"recv_window_conn", "recv_window"} {
			if value := configJSONInt(object[key]); value > 0 {
				fields[key] = value
			}
		}
		if configJSONBool(object, "disable_mtu_discovery") {
			fields["disable_mtu_discovery"] = true
		}
		return nil
	}
	// hysteria2: obfs is an object, every field is written when obfs exists.
	if value, present := object["obfs"]; present {
		obfs, ok := value.(map[string]any)
		if !ok {
			return profileUnsupported("hysteria2 obfs is not an object")
		}
		for key := range obfs {
			switch key {
			case "type", "password", "min_packet_size", "max_packet_size":
			default:
				return profileUnsupported("hysteria2 obfs field not ported yet: " + key)
			}
		}
		converted := map[string]any{
			"type":            "salamander",
			"password":        configJSONString(obfs, "password"),
			"min_packet_size": 0,
			"max_packet_size": 0,
		}
		if obfsType := strings.TrimSpace(configJSONString(obfs, "type")); obfsType != "" {
			converted["type"] = strings.ToLower(obfsType)
		}
		converted["min_packet_size"] = configJSONInt(obfs["min_packet_size"])
		converted["max_packet_size"] = configJSONInt(obfs["max_packet_size"])
		if configJSONString(converted, "password") != "" {
			fields["obfs"] = converted
		}
	}
	if obfsPassword := configJSONString(object, "obfsPassword"); obfsPassword != "" {
		obfs, ok := fields["obfs"].(map[string]any)
		if !ok {
			obfs = map[string]any{"type": "salamander", "password": "", "min_packet_size": 0, "max_packet_size": 0}
		}
		obfs["password"] = obfsPassword
		if configJSONString(obfs, "type") == "" {
			obfs["type"] = "salamander"
		}
		fields["obfs"] = obfs
	}
	if password := configJSONString(object, "password"); password != "" {
		fields["password"] = password
	}
	if hop := configJSONString(object, "hop_interval_max"); hop != "" {
		fields["hop_interval_max"] = hysteriaHopDuration(hop)
	}
	if bbr := configJSONString(object, "bbr_profile"); bbr != "" {
		fields["bbr_profile"] = bbr
	}
	if configJSONBool(object, "disable_chrome_parrot") {
		fields["disable_chrome_parrot"] = true
	}
	if value, present := object["realm"]; present && value != nil {
		realm, ok := value.(map[string]any)
		if !ok {
			return profileUnsupported("hysteria2 realm is not an object")
		}
		fields["realm"] = profileNormalizeHysteriaRealm(realm)
	}
	return nil
}

// hysteriaPortToPort is Kotlin Hysteria.portsToPorts on one item.
func hysteriaPortToPort(port string) string {
	trimmed := strings.TrimSpace(port)
	parts := profilePortRangeParts(trimmed)
	if len(parts) == 2 {
		return parts[0] + ":" + parts[1]
	}
	return trimmed + ":" + trimmed
}

func hysteriaHopDuration(value string) string {
	trimmed := strings.TrimSpace(value)
	if trimmed != "" {
		digits := true
		for _, char := range trimmed {
			if char < '0' || char > '9' {
				digits = false
				break
			}
		}
		if digits {
			return trimmed + "s"
		}
	}
	return value
}

// --- TLS ------------------------------------------------------------------

var profileExportTLSKnownKeys = map[string]bool{
	"enabled": true, "disable_sni": true, "server_name": true, "insecure": true,
	"alpn": true, "min_version": true, "max_version": true, "cipher_suites": true,
	"curve_preferences": true, "certificate": true, "certificate_path": true,
	"certificate_sha256": true, "certificate_public_key_sha256": true,
	"client_certificate": true, "client_certificate_path": true,
	"client_key": true, "client_key_path": true, "fragment": true,
	"fragment_fallback_delay": true, "record_fragment": true,
	"spoof": true, "spoof_method": true, "spoof_enabled": true,
	"tls_tricks": true, "ech": true, "utls": true, "reality": true,
}

func profileExportTLS(value any, profileType string) (map[string]any, error) {
	raw, ok := value.(map[string]any)
	if !ok {
		return nil, profileUnsupported("tls is not an object")
	}
	for key := range raw {
		if !profileExportTLSKnownKeys[key] {
			return nil, profileUnsupported("tls field not ported yet: " + key)
		}
	}
	// A TLS block that is present but disabled exports to {} (Tls.exportToJson).
	if !configJSONBool(raw, "enabled") {
		return map[string]any{}, nil
	}
	tls := map[string]any{"enabled": true}
	if configJSONBool(raw, "disable_sni") {
		tls["disable_sni"] = true
	}
	if serverName := configJSONString(raw, "server_name"); serverName != "" {
		tls["server_name"] = configToACEHost(serverName)
	}
	if configJSONBool(raw, "insecure") {
		tls["insecure"] = true
	}
	for _, item := range []struct {
		key string
		out string
	}{
		{"alpn", "alpn"}, {"cipher_suites", "cipher_suites"},
		{"curve_preferences", "curve_preferences"}, {"certificate", "certificate"},
		{"certificate_sha256", "certificate_sha256"},
		{"certificate_public_key_sha256", "certificate_public_key_sha256"},
		{"client_certificate", "client_certificate"}, {"client_key", "client_key"},
	} {
		if value, present := raw[item.key]; present {
			list := profileExportStringList(value)
			if len(list) > 0 {
				tls[item.out] = stringListToAny(list)
			}
		}
	}
	for _, key := range []string{"certificate_path", "client_certificate_path",
		"client_key_path", "fragment_fallback_delay", "min_version", "max_version", "spoof"} {
		if configJSONString(raw, key) != "" {
			tls[key] = configJSONString(raw, key)
		}
	}
	if spoof := configJSONString(raw, "spoof"); spoof != "" {
		tls["spoof"] = spoof
		if method := strings.TrimSpace(configJSONString(raw, "spoof_method")); method != "" {
			tls["spoof_method"] = method
		}
	}
	if value, present := raw["fragment"]; present {
		enabled, ok := value.(bool)
		if !ok {
			return nil, profileUnsupported("tls.fragment is not a boolean")
		}
		tls["fragment"] = enabled
	}
	if configJSONBool(raw, "record_fragment") {
		tls["record_fragment"] = true
	}
	if value, present := raw["spoof_enabled"]; present {
		enabled, ok := value.(bool)
		if !ok {
			return nil, profileUnsupported("tls.spoof_enabled is not a boolean")
		}
		tls["spoof_enabled"] = enabled
	}
	if value, present := raw["tls_tricks"]; present {
		switch tricks := value.(type) {
		case map[string]any:
			for key := range tricks {
				if key != "mixedcase_sni" {
					return nil, profileUnsupported("tls.tls_tricks field not ported yet: " + key)
				}
			}
			tls["tls_tricks"] = map[string]any{"mixedcase_sni": configJSONBool(tricks, "mixedcase_sni")}
		case bool:
			// Plain-boolean alias used by hand-written stored JSON.
			tls["tls_tricks"] = map[string]any{"mixedcase_sni": tricks}
		default:
			return nil, profileUnsupported("tls.tls_tricks is not an object")
		}
	}
	if value, present := raw["utls"]; present {
		utls, err := profileExportUTLS(value)
		if err != nil {
			return nil, err
		}
		if len(utls) > 0 {
			tls["utls"] = utls
		}
	}
	if value, present := raw["ech"]; present {
		ech, err := profileExportECH(value)
		if err != nil {
			return nil, err
		}
		if len(ech) > 0 {
			tls["ech"] = ech
		}
	}
	if value, present := raw["reality"]; present {
		reality, err := profileExportReality(value)
		if err != nil {
			return nil, err
		}
		if len(reality) > 0 {
			tls["reality"] = reality
		}
	}
	return tls, nil
}

func profileExportUTLS(value any) (map[string]any, error) {
	raw, ok := value.(map[string]any)
	if !ok {
		return nil, profileUnsupported("tls.utls is not an object")
	}
	if !configJSONBool(raw, "enabled") {
		return map[string]any{}, nil
	}
	out := map[string]any{"enabled": true}
	if fingerprint := configJSONString(raw, "fingerprint"); fingerprint != "" {
		out["fingerprint"] = fingerprint
	}
	return out, nil
}

func profileExportECH(value any) (map[string]any, error) {
	raw, ok := value.(map[string]any)
	if !ok {
		return nil, profileUnsupported("tls.ech is not an object")
	}
	if !configJSONBool(raw, "enabled") {
		return map[string]any{}, nil
	}
	out := map[string]any{"enabled": true}
	if config := profileExportStringList(raw["config"]); len(config) > 0 {
		out["config"] = stringListToAny(config)
	}
	if path := configJSONString(raw, "config_path"); path != "" {
		out["config_path"] = path
	}
	if name := configJSONString(raw, "query_server_name"); name != "" {
		out["query_server_name"] = configToACEHost(name)
	}
	if resolver := configJSONString(raw, "resolver"); resolver != "" {
		out["resolver"] = resolver
	}
	return out, nil
}

func profileExportReality(value any) (map[string]any, error) {
	raw, ok := value.(map[string]any)
	if !ok {
		return nil, profileUnsupported("tls.reality is not an object")
	}
	if !configJSONBool(raw, "enabled") {
		return map[string]any{}, nil
	}
	out := map[string]any{"enabled": true}
	for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
		if item := configJSONString(raw, key); item != "" {
			out[key] = item
		}
	}
	return out, nil
}

func stringListToAny(items []string) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		if strings.TrimSpace(item) == "" {
			continue
		}
		out = append(out, item)
	}
	return out
}

// --- transport -------------------------------------------------------------

var profileExportTransportKeys = map[string]bool{
	"ws": true, "http": true, "grpc": true, "httpupgrade": true, "quic": true, "xhttp": true, "mkcp": true,
}

func profileExportTransport(value any) (map[string]any, error) {
	raw, ok := value.(map[string]any)
	if !ok {
		return nil, profileUnsupported("transport is not an object")
	}
	kind := singBoxTransportType(configJSONString(raw, "type"))
	if kind == "raw" || kind == "h2" {
		kind = "http"
	}
	if kind == "" || kind == "tcp" {
		if len(raw) > 1 {
			return nil, profileUnsupported("transport fields on a plain TCP link")
		}
		return map[string]any{}, nil
	}
	if !profileExportTransportKeys[kind] {
		return nil, profileUnsupported("transport type not ported yet: " + kind)
	}
	transport := map[string]any{"type": kind}
	switch kind {
	case "xhttp":
		return profileExportXHTTP(raw, transport)
	case "mkcp":
		return profileExportMKCP(raw, transport)
	}
	for _, key := range []string{"path", "method", "idle_timeout", "ping_timeout", "early_data_header_name", "service_name"} {
		if item := configJSONString(raw, key); item != "" {
			transport[key] = item
		}
	}
	if value := configJSONInt(raw["max_early_data"]); value > 0 {
		transport["max_early_data"] = value
	}
	if kind == "http" || kind == "httpupgrade" {
		if host := configJSONString(raw, "host"); host != "" {
			transport["host"] = configToACEHost(host)
		}
	}
	if value, present := raw["headers"]; present {
		headers, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("transport.headers is not an object")
		}
		copied := map[string]any{}
		for key, item := range headers {
			copied[key] = item
		}
		// The stored form keeps headers.Host for ws (Kotlin exportToJson writes
		// it there), but exportToLink writes `host` instead of `headers` for
		// ws. The link builder reads Host from headers below.
		if len(copied) > 0 {
			transport["headers"] = copied
		}
	}
	return transport, nil
}

func profileExportXHTTP(raw, transport map[string]any) (map[string]any, error) {
	for _, key := range []string{"host", "path", "mode"} {
		if item := configJSONString(raw, key); item != "" {
			if key == "host" {
				transport[key] = configToACEHost(item)
			} else {
				transport[key] = item
			}
		}
	}
	// The core refuses a zero range, so exportToJson always writes the default.
	if value := configJSONString(raw, "x_padding_bytes"); value != "" {
		transport["x_padding_bytes"] = value
	} else {
		transport["x_padding_bytes"] = "100-1000"
	}
	for _, key := range []string{"no_grpc_header", "no_sse_header", "x_padding_obfs_mode"} {
		if configJSONBool(raw, key) {
			transport[key] = true
		}
	}
	for _, key := range []string{"sc_max_each_post_bytes", "sc_min_posts_interval_ms", "sc_stream_up_server_secs",
		"x_padding_key", "x_padding_header", "x_padding_placement", "x_padding_method",
		"uplink_http_method", "session_placement", "session_key", "seq_placement", "seq_key",
		"uplink_data_placement", "uplink_data_key", "uplink_chunk_size", "session_id_table",
		"session_id_length", "congestion_controller"} {
		if item := configJSONString(raw, key); item != "" {
			transport[key] = item
		}
	}
	if value := configJSONInt(raw["sc_max_buffered_posts"]); value > 0 {
		transport["sc_max_buffered_posts"] = value
	}
	if value := configJSONInt(raw["cwnd"]); value > 0 {
		transport["cwnd"] = value
	}
	if value, present := raw["headers"]; present {
		headers, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("transport.headers is not an object")
		}
		if len(headers) > 0 {
			transport["headers"] = headers
		}
	}
	if value, present := raw["xmux"]; present && value != nil {
		xmux, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("transport.xhttp.xmux is not an object")
		}
		if len(xmux) > 0 {
			transport["xmux"] = xmux
		}
	}
	for key := range raw {
		if !profileExportXHTTPKnown[key] {
			return nil, profileUnsupported("transport.xhttp field not ported yet: " + key)
		}
	}
	return transport, nil
}

var profileExportXHTTPKnown = map[string]bool{
	"type": true, "host": true, "path": true, "mode": true, "x_padding_bytes": true,
	"no_grpc_header": true, "no_sse_header": true, "x_padding_obfs_mode": true,
	"sc_max_each_post_bytes": true, "sc_min_posts_interval_ms": true,
	"sc_max_buffered_posts": true, "sc_stream_up_server_secs": true,
	"x_padding_key": true, "x_padding_header": true, "x_padding_placement": true,
	"x_padding_method": true, "uplink_http_method": true, "session_placement": true,
	"session_key": true, "seq_placement": true, "seq_key": true,
	"uplink_data_placement": true, "uplink_data_key": true, "uplink_chunk_size": true,
	"session_id_table": true, "session_id_length": true, "congestion_controller": true,
	"cwnd": true, "headers": true, "xmux": true,
}

func profileExportMKCP(raw, transport map[string]any) (map[string]any, error) {
	for _, key := range []string{"mtu", "tti", "uplink_capacity", "downlink_capacity",
		"read_buffer_size", "write_buffer_size"} {
		if value := configJSONInt(raw[key]); value > 0 {
			transport[key] = value
		}
	}
	if configJSONBool(raw, "congestion") {
		transport["congestion"] = true
	}
	for _, key := range []string{"header_type", "seed"} {
		if item := configJSONString(raw, key); item != "" {
			transport[key] = item
		}
	}
	for key := range raw {
		switch key {
		case "type", "mtu", "tti", "uplink_capacity", "downlink_capacity", "congestion",
			"read_buffer_size", "write_buffer_size", "header_type", "seed":
		default:
			return nil, profileUnsupported("transport.mkcp field not ported yet: " + key)
		}
	}
	return transport, nil
}

// --- multiplex -------------------------------------------------------------

var profileExportMuxKeys = map[string]bool{
	"enabled": true, "protocol": true, "max_connections": true, "min_streams": true,
	"max_streams": true, "padding": true, "brutal": true,
}

func profileExportMultiplex(value any) (map[string]any, error) {
	raw, ok := value.(map[string]any)
	if !ok {
		return nil, profileUnsupported("multiplex is not an object")
	}
	for key := range raw {
		if !profileExportMuxKeys[key] {
			return nil, profileUnsupported("multiplex field not ported yet: " + key)
		}
	}
	// An empty block or one without "enabled" means Keep Default: Kotlin emits {}.
	enabled, present := raw["enabled"]
	if !present {
		return map[string]any{}, nil
	}
	value2, ok := enabled.(bool)
	if !ok {
		return nil, profileUnsupported("multiplex.enabled is not a boolean")
	}
	out := map[string]any{"enabled": value2}
	if !value2 {
		return out, nil
	}
	if protocol := configJSONString(raw, "protocol"); protocol != "" {
		out["protocol"] = protocol
	}
	for _, key := range []string{"max_connections", "min_streams", "max_streams"} {
		if item := configJSONInt(raw[key]); item > 0 {
			out[key] = item
		}
	}
	if configJSONBool(raw, "padding") {
		out["padding"] = true
	}
	if brutal, present := raw["brutal"]; present {
		block, ok := brutal.(map[string]any)
		if !ok {
			return nil, profileUnsupported("multiplex.brutal is not an object")
		}
		for key := range block {
			switch key {
			case "enabled", "up_mbps", "down_mbps":
			default:
				return nil, profileUnsupported("multiplex.brutal field not ported yet: " + key)
			}
		}
		if configJSONBool(block, "enabled") {
			up := configJSONInt(block["up_mbps"])
			if up <= 0 {
				up = 1
			}
			down := configJSONInt(block["down_mbps"])
			if down <= 0 {
				down = 1
			}
			out["brutal"] = map[string]any{"enabled": true, "up_mbps": up, "down_mbps": down}
		}
	}
	return out, nil
}

// --- quic ------------------------------------------------------------------

var profileExportQUICKeys = map[string]bool{
	"idle_timeout": true, "keep_alive_period": true, "stream_receive_window": true,
	"connection_receive_window": true, "max_concurrent_streams": true,
	"initial_packet_size": true, "disable_path_mtu_discovery": true,
}

func profileExportQUIC(object map[string]any) (map[string]any, error) {
	out := map[string]any{}
	for key := range profileExportQUICKeys {
		if _, present := object[key]; present {
			if !profileExportQUICKeys[key] {
				return nil, profileUnsupported("quic field not ported yet: " + key)
			}
		}
	}
	for _, key := range []string{"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window"} {
		if item := configJSONString(object, key); item != "" {
			out[key] = item
		}
	}
	for _, key := range []string{"max_concurrent_streams", "initial_packet_size"} {
		if item := configJSONInt(object[key]); item > 0 {
			out[key] = item
		}
	}
	if value, present := object["disable_path_mtu_discovery"]; present {
		disabled, ok := value.(bool)
		if !ok {
			return nil, profileUnsupported("quic.disable_path_mtu_discovery is not a boolean")
		}
		out["disable_path_mtu_discovery"] = disabled
	}
	return out, nil
}

// --- identity --------------------------------------------------------------

// profileExportAdvancedIdentity mirrors Outbound.exportIdentity plus the TLS,
// transport and Hysteria overrides. It is subscription reconcile's dedup
// input, so a missed field would collapse distinct nodes.
func profileExportAdvancedIdentity(node *profileExportAdvanced) map[string]any {
	// Hysteria.exportIdentity under realm: the whole config is keyed by the
	// rendezvous coordinates because there is no server address.
	if realm, ok := node.Fields["realm"].(map[string]any); ok && node.Type == "hysteria2" {
		identity := map[string]any{
			"protocol_version": "2",
			"realm_server_url": configJSONString(realm, "server_url"),
			"realm_id":         configJSONString(realm, "realm_id"),
		}
		if tlsIdentity := profileExportTLSIdentity(node.TLS); len(tlsIdentity) > 0 {
			identity["tls"] = tlsIdentity
		}
		return identity
	}
	object := map[string]any{
		"server":      node.Server,
		"server_port": node.Port,
	}
	if node.HasTLS || node.AlwaysTLS {
		if identity := profileExportTLSIdentity(node.TLS); len(identity) > 0 {
			object["tls"] = identity
		}
	}
	if node.HasTr {
		if kind, _ := node.Transport["type"].(string); kind != "" && kind != "tcp" {
			object["transport"] = map[string]any{"type": kind}
		}
	}
	if node.Type == "hysteria" || node.Type == "hysteria2" {
		object["protocol_version"] = "1"
		if node.Type == "hysteria2" {
			object["protocol_version"] = "2"
		}
		if ports, present := node.Fields["server_ports"]; present {
			switch typed := ports.(type) {
			case string:
				if typed != "" {
					object["server_ports"] = typed
				}
			case []any:
				parts := make([]string, 0, len(typed))
				for _, item := range typed {
					if text, ok := item.(string); ok && text != "" {
						parts = append(parts, text)
					}
				}
				if len(parts) > 0 {
					object["server_ports"] = strings.Join(parts, ",")
				}
			}
		}
		if _, present := node.Fields["obfs"]; present {
			object["obfs"] = true
		}
	}
	return object
}

func profileExportTLSIdentity(tls map[string]any) map[string]any {
	if len(tls) == 0 {
		return nil
	}
	// Tls.exportIdentity returns {} unless enabled (Hysteria only forces TLS
	// on in its link/Clash parsers, not in the stored exporter).
	if !configJSONBool(tls, "enabled") {
		return nil
	}
	identity := map[string]any{"enabled": true}
	if configJSONBool(tls, "disable_sni") {
		identity["disable_sni"] = true
	}
	if name := configJSONString(tls, "server_name"); name != "" {
		identity["server_name"] = configToACEHost(name)
	}
	if utls, ok := tls["utls"].(map[string]any); ok {
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" {
			identity["utls"] = map[string]any{"fingerprint": fingerprint}
		}
	}
	if ech, ok := tls["ech"].(map[string]any); ok {
		if configJSONBool(ech, "enabled") {
			echIdentity := map[string]any{"enabled": true}
			if name := configJSONString(ech, "query_server_name"); name != "" {
				echIdentity["query_server_name"] = configToACEHost(name)
			}
			if resolver := configJSONString(ech, "resolver"); resolver != "" {
				echIdentity["resolver"] = resolver
			}
			identity["ech"] = echIdentity
		}
	}
	if reality, ok := tls["reality"].(map[string]any); ok {
		realityIdentity := map[string]any{}
		if configJSONBool(reality, "enabled") {
			realityIdentity["enabled"] = true
		}
		for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
			if value := configJSONString(reality, key); value != "" {
				realityIdentity[key] = value
			}
		}
		if len(realityIdentity) > 0 {
			identity["reality"] = realityIdentity
		}
	}
	return identity
}

// --- links -----------------------------------------------------------------

func profileExportAdvancedLink(node *profileExportAdvanced) (string, error) {
	if node.Server == "" {
		return "", nil
	}
	query := []profileStoredQueryItem{}
	switch node.Type {
	case "vmess":
		return profileExportVMessLink(node)
	case "vless":
		// Vless.exportToLink always writes these query items, even when the
		// stored values are empty (encryption=none, packetEncoding=none).
		query = append(query, profileStoredQueryItem{key: "encryption", value: configJSONString(node.Fields, "encryption")})
		if flow := configJSONString(node.Fields, "flow"); flow != "" {
			query = append(query, profileStoredQueryItem{key: "flow", value: flow})
		}
		query = append(query, profileExportTLSQuery(node.TLS)...)
		query = append(query, profileExportTransportQuery(node.Transport, node.HasTLS)...)
		query = append(query, profileExportMuxQuery(node.Multiplex)...)
		packetEncoding := configJSONString(node.Fields, "packet_encoding")
		if packetEncoding == "" {
			packetEncoding = "none"
		}
		query = append(query, profileStoredQueryItem{key: "packetEncoding", value: packetEncoding})
	case "trojan":
		if configJSONBool(node.TLS, "enabled") {
			query = append(query, profileExportTLSQuery(node.TLS)...)
		}
		if node.HasTr {
			query = append(query, profileExportTransportQuery(node.Transport, configJSONBool(node.TLS, "enabled"))...)
		}
		if node.HasMux && configJSONBool(node.Multiplex, "enabled") {
			query = append(query, profileExportMuxQuery(node.Multiplex)...)
		}
	case "hysteria", "hysteria2":
		return profileExportHysteriaLink(node)
	}
	builder := profileStoredLinkBuilder{
		scheme:      node.Type,
		host:        node.Server,
		port:        node.Port,
		fragment:    node.Name,
		hasFragment: node.Name != "",
		query:       query,
	}
	switch node.Type {
	case "vless":
		builder.scheme = "vless"
		if uuid := configJSONString(node.Fields, "uuid"); uuid != "" {
			builder.username, builder.hasUsername = uuid, true
		}
	case "trojan":
		builder.scheme = "trojan"
		if password := configJSONString(node.Fields, "password"); password != "" {
			builder.username, builder.hasUsername = password, true
		}
	}
	return builder.build(), nil
}

func profileExportVMessLink(node *profileExportAdvanced) (string, error) {
	network := ""
	if node.HasTr {
		network = singBoxTransportType(configJSONString(node.Transport, "type"))
	}
	rawHTTP := network == "http" && !configJSONBool(node.TLS, "enabled")
	switch {
	case network == "" || network == "tcp" || rawHTTP:
		network = "tcp"
	case network == "http":
		network = "h2"
	}
	path := ""
	serviceName := ""
	if node.HasTr {
		path = configJSONString(node.Transport, "path")
		serviceName = configJSONString(node.Transport, "service_name")
	}
	if network == "grpc" {
		path = serviceName
	}
	host := ""
	if node.HasTr {
		host = configJSONString(node.Transport, "host")
		if headers, ok := node.Transport["headers"].(map[string]any); ok {
			if value := configJSONString(headers, "Host"); value != "" {
				host = value
			}
		}
	}
	security := configJSONString(node.Fields, "security")
	if security == "" {
		security = "auto"
	}
	envelope := map[string]any{
		"v": "2", "ps": node.Name, "add": node.Server,
		"port": strconv.Itoa(node.Port),
		"id":   configJSONString(node.Fields, "uuid"),
		"aid":  strconv.Itoa(configJSONInt(node.Fields["alter_id"])),
		"scy":  security,
		"net":  network,
		"type": "none",
		"host": host,
		"path": path,
		"tls":  "", "sni": "", "alpn": "", "fp": "",
	}
	if rawHTTP {
		envelope["type"] = "http"
		envelope["path"] = strings.SplitN(path, ",", 2)[0]
	}
	tlsEnabled := configJSONBool(node.TLS, "enabled")
	if tlsEnabled {
		envelope["tls"] = "tls"
		envelope["sni"] = configJSONString(node.TLS, "server_name")
		envelope["alpn"] = strings.Join(profileExportStringList(node.TLS["alpn"]), ",")
		if utls, ok := node.TLS["utls"].(map[string]any); ok {
			envelope["fp"] = configJSONString(utls, "fingerprint")
		}
		if cipher := profileExportStringList(node.TLS["cipher_suites"]); len(cipher) > 0 {
			envelope["cs"] = strings.Join(cipher, ":")
		}
		if configJSONBool(node.TLS, "insecure") {
			envelope["allowInsecure"] = "1"
		}
	}
	extra := []profileStoredQueryItem{}
	if node.HasTr {
		extra = append(extra, profileExportTransportQuery(node.Transport, tlsEnabled)...)
	}
	extra = append(extra, profileExportMuxQuery(node.Multiplex)...)
	if configJSONBool(node.Fields, "global_padding") {
		extra = append(extra, profileStoredQueryItem{key: "globalPadding", value: "true"})
	}
	if configJSONBool(node.Fields, "authenticated_length") {
		extra = append(extra, profileStoredQueryItem{key: "authenticatedLength", value: "true"})
	}
	encoding := configJSONString(node.Fields, "packet_encoding")
	if encoding != "xudp" {
		if encoding == "" {
			encoding = "none"
		}
		extra = append(extra, profileStoredQueryItem{key: "packetEncoding", value: encoding})
	}
	if len(extra) > 0 {
		envelope["throneExtra"] = profileStoredFormatQuery(extra)
	}
	encoded, err := MarshalCanonicalJSON(envelope)
	if err != nil {
		return "", err
	}
	return "vmess://" + profileBase64Encode(encoded, false, false), nil
}

func profileExportHysteriaLink(node *profileExportAdvanced) (string, error) {
	if profileExportHysteriaRealmActive(node) {
		// hysteria.cpp:264-331: a realm node has no share-link form.
		return "", nil
	}
	builder := profileStoredLinkBuilder{
		scheme:      node.Type,
		host:        node.Server,
		port:        node.Port,
		fragment:    node.Name,
		hasFragment: node.Name != "",
	}
	query := []profileStoredQueryItem{}
	if node.Type == "hysteria" {
		if obfs := configJSONString(node.Fields, "obfs"); obfs != "" {
			query = append(query, profileStoredQueryItem{key: "obfsParam", value: profileLinkPercentEncodeAll(obfs), encoded: true})
		}
		if auth := configJSONString(node.Fields, "auth_str"); auth != "" {
			query = append(query, profileStoredQueryItem{key: "auth", value: auth})
		}
		if value := configJSONInt(node.Fields["recv_window_conn"]); value > 0 {
			query = append(query, profileStoredQueryItem{key: "recv_window_conn", value: strconv.Itoa(value)})
		}
		if value := configJSONInt(node.Fields["recv_window"]); value > 0 {
			query = append(query, profileStoredQueryItem{key: "recv_window", value: strconv.Itoa(value)})
		}
		if configJSONBool(node.Fields, "disable_mtu_discovery") {
			query = append(query, profileStoredQueryItem{key: "disable_mtu_discovery", value: "true"})
		}
	} else {
		password := configJSONString(node.Fields, "password")
		if index := strings.IndexByte(password, ':'); index >= 0 {
			builder.username, builder.hasUsername = password[:index], true
			builder.password, builder.hasPassword = password[index+1:], true
		} else if password != "" {
			builder.username, builder.hasUsername = password, true
		}
		if obfs, ok := node.Fields["obfs"].(map[string]any); ok && len(obfs) > 0 {
			obfsType := configJSONString(obfs, "type")
			secret := configJSONString(obfs, "password")
			query = append(query, profileStoredQueryItem{key: "obfs", value: profileLinkPercentEncodeAll(obfsType), encoded: true})
			query = append(query, profileStoredQueryItem{key: "obfs-password", value: profileLinkPercentEncodeAll(secret), encoded: true})
			if size := configJSONInt(obfs["min_packet_size"]); size > 0 {
				query = append(query, profileStoredQueryItem{key: "min_packet_size", value: strconv.Itoa(size)})
			}
			if size := configJSONInt(obfs["max_packet_size"]); size > 0 {
				query = append(query, profileStoredQueryItem{key: "max_packet_size", value: strconv.Itoa(size)})
			}
		}
		if hop := configJSONString(node.Fields, "hop_interval_max"); hop != "" {
			query = append(query, profileStoredQueryItem{key: "hop_interval_max", value: hysteriaHopDuration(hop)})
		}
		if bbr := configJSONString(node.Fields, "bbr_profile"); bbr != "" {
			query = append(query, profileStoredQueryItem{key: "bbr_profile", value: bbr})
		}
		if configJSONBool(node.Fields, "disable_chrome_parrot") {
			query = append(query, profileStoredQueryItem{key: "disable_chrome_parrot", value: "true"})
		}
	}
	if value := configJSONInt(node.Fields["up_mbps"]); value > 0 {
		query = append(query, profileStoredQueryItem{key: "upmbps", value: strconv.Itoa(value)})
	}
	if value := configJSONInt(node.Fields["down_mbps"]); value > 0 {
		query = append(query, profileStoredQueryItem{key: "downmbps", value: strconv.Itoa(value)})
	}
	if hop := configJSONString(node.Fields, "hop_interval"); hop != "" {
		query = append(query, profileStoredQueryItem{key: "hop_interval", value: hysteriaHopDuration(hop)})
	}
	query = append(query, profileExportTLSQuery(node.TLS)...)
	if node.HasQUIC {
		query = append(query, profileExportQUICQuery(node.QUIC)...)
	}
	query = append(query, profileStoredDialQueryFromFields(node.Fields)...)
	builder.query = query
	if ports, present := node.Fields["server_ports"]; present {
		if list, ok := ports.([]any); ok && len(list) > 0 {
			// Kotlin serialises the URL without a port and inserts ":a-b,c-d"
			// right after the authority (before the query/fragment).
			builder.port = -1
			prefix := builder.build()
			parts := make([]string, 0, len(list))
			for _, item := range list {
				if text, ok := item.(string); ok {
					parts = append(parts, strings.ReplaceAll(text, ":", "-"))
				}
			}
			insert := len(prefix)
			if index := strings.IndexAny(prefix, "?#"); index >= 0 {
				insert = index
			}
			return prefix[:insert] + ":" + strings.Join(parts, ",") + prefix[insert:], nil
		}
	}
	return builder.build(), nil
}

func profileStoredDialQueryFromFields(fields map[string]any) []profileStoredQueryItem {
	query := []profileStoredQueryItem{}
	if configJSONBool(fields, "reuse_addr") {
		query = append(query, profileStoredQueryItem{key: "reuse_addr", value: "true"})
	}
	if value := configJSONString(fields, "connect_timeout"); value != "" {
		query = append(query, profileStoredQueryItem{key: "connect_timeout", value: value})
	}
	for _, key := range []string{"tcp_fast_open", "tcp_multi_path", "udp_fragment"} {
		if configJSONBool(fields, key) {
			query = append(query, profileStoredQueryItem{key: key, value: "true"})
		}
	}
	for _, key := range []string{"bind_interface", "inet4_bind_address", "inet6_bind_address"} {
		if value := configJSONString(fields, key); value != "" {
			query = append(query, profileStoredQueryItem{key: key, value: value})
		}
	}
	return query
}

func profileExportTLSQuery(tls map[string]any) []profileStoredQueryItem {
	query := []profileStoredQueryItem{}
	if len(tls) == 0 || !configJSONBool(tls, "enabled") {
		return query
	}
	security := "tls"
	if reality, ok := tls["reality"].(map[string]any); ok && configJSONBool(reality, "enabled") {
		security = "reality"
	}
	query = append(query, profileStoredQueryItem{key: "security", value: security})
	if configJSONBool(tls, "disable_sni") {
		query = append(query, profileStoredQueryItem{key: "disable_sni", value: "true"})
	}
	if name := configJSONString(tls, "server_name"); name != "" {
		query = append(query, profileStoredQueryItem{key: "sni", value: name})
	}
	if configJSONBool(tls, "insecure") {
		query = append(query, profileStoredQueryItem{key: "allowInsecure", value: "true"})
	}
	if alpn := profileExportStringList(tls["alpn"]); len(alpn) > 0 {
		query = append(query, profileStoredQueryItem{key: "alpn", value: strings.Join(alpn, ",")})
	}
	if value := configJSONString(tls, "min_version"); value != "" {
		query = append(query, profileStoredQueryItem{key: "tls_min_version", value: value})
	}
	if value := configJSONString(tls, "max_version"); value != "" {
		query = append(query, profileStoredQueryItem{key: "tls_max_version", value: value})
	}
	if suites := profileExportStringList(tls["cipher_suites"]); len(suites) > 0 {
		query = append(query, profileStoredQueryItem{key: "cs", value: strings.Join(suites, ":")})
	}
	if curves := profileExportStringList(tls["curve_preferences"]); len(curves) > 0 {
		query = append(query, profileStoredQueryItem{key: "tls_curve_preferences", value: strings.Join(curves, ",")})
	}
	if certs := profileExportStringList(tls["certificate"]); len(certs) > 0 {
		query = append(query, profileStoredQueryItem{key: "tls_certificate", value: strings.Join(certs, ",")})
	}
	if value := configJSONString(tls, "certificate_path"); value != "" {
		query = append(query, profileStoredQueryItem{key: "tls_certificate_path", value: value})
	}
	if pins := profileExportStringList(tls["certificate_sha256"]); len(pins) > 0 {
		query = append(query, profileStoredQueryItem{key: "pcs", value: profileExportPCS(pins)})
	}
	if pins := profileExportStringList(tls["certificate_public_key_sha256"]); len(pins) > 0 {
		query = append(query, profileStoredQueryItem{key: "tls_certificate_public_key_sha256", value: strings.Join(pins, ",")})
	}
	if certs := profileExportStringList(tls["client_certificate"]); len(certs) > 0 {
		query = append(query, profileStoredQueryItem{key: "tls_client_certificate", value: strings.Join(certs, ",")})
	}
	if value := configJSONString(tls, "client_certificate_path"); value != "" {
		query = append(query, profileStoredQueryItem{key: "tls_client_certificate_path", value: value})
	}
	if certs := profileExportStringList(tls["client_key"]); len(certs) > 0 {
		query = append(query, profileStoredQueryItem{key: "tls_client_key", value: strings.Join(certs, ",")})
	}
	if value := configJSONString(tls, "client_key_path"); value != "" {
		query = append(query, profileStoredQueryItem{key: "tls_client_key_path", value: value})
	}
	if value, present := tls["fragment"]; present {
		enabled, _ := value.(bool)
		query = append(query, profileStoredQueryItem{key: "tls_fragment", value: strconv.FormatBool(enabled)})
	}
	if value := configJSONString(tls, "fragment_fallback_delay"); value != "" {
		query = append(query, profileStoredQueryItem{key: "tls_fragment_fallback_delay", value: value})
	}
	if configJSONBool(tls, "record_fragment") {
		query = append(query, profileStoredQueryItem{key: "tls_record_fragment", value: "true"})
	}
	if value, present := tls["spoof_enabled"]; present {
		enabled, _ := value.(bool)
		query = append(query, profileStoredQueryItem{key: "tls_spoof_enabled", value: strconv.FormatBool(enabled)})
	}
	if value := configJSONString(tls, "spoof"); value != "" {
		query = append(query, profileStoredQueryItem{key: "tls_spoof", value: value})
		if method := configJSONString(tls, "spoof_method"); method != "" {
			query = append(query, profileStoredQueryItem{key: "tls_spoof_method", value: method})
		}
	}
	if value, present := tls["tls_tricks"]; present {
		switch tricks := value.(type) {
		case map[string]any:
			query = append(query, profileStoredQueryItem{key: "tls_tricks", value: strconv.FormatBool(configJSONBool(tricks, "mixedcase_sni"))})
		case bool:
			query = append(query, profileStoredQueryItem{key: "tls_tricks", value: strconv.FormatBool(tricks)})
		}
	}
	if ech, ok := tls["ech"].(map[string]any); ok && configJSONBool(ech, "enabled") {
		query = append(query, profileExportECHQuery(ech)...)
	}
	if utls, ok := tls["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" {
			query = append(query, profileStoredQueryItem{key: "fp", value: fingerprint})
		}
	}
	if reality, ok := tls["reality"].(map[string]any); ok && configJSONBool(reality, "enabled") {
		query = append(query, profileStoredQueryItem{key: "pbk", value: configJSONString(reality, "public_key")})
		query = append(query, profileStoredQueryItem{key: "sid", value: configJSONString(reality, "short_id")})
		if verify := configJSONString(reality, "mldsa65_verify"); verify != "" {
			query = append(query, profileStoredQueryItem{key: "pqv", value: verify})
		}
	}
	return query
}

func profileExportECHQuery(ech map[string]any) []profileStoredQueryItem {
	query := []profileStoredQueryItem{{key: "ech_enabled", value: "true"}}
	config := profileExportStringList(ech["config"])
	b64 := strings.Join(config, "")
	if b64 != "" {
		query = append(query, profileStoredQueryItem{key: "ech_config", value: b64})
	}
	if path := configJSONString(ech, "config_path"); path != "" {
		query = append(query, profileStoredQueryItem{key: "ech_config_path", value: path})
	}
	name := configJSONString(ech, "query_server_name")
	resolver := configJSONString(ech, "resolver")
	if name != "" {
		query = append(query, profileStoredQueryItem{key: "ech_server_name", value: name})
	}
	switch {
	case name != "" && resolver != "":
		query = append(query, profileStoredQueryItem{key: "ech", value: name + "+" + resolver})
	case name == "" && b64 != "":
		query = append(query, profileStoredQueryItem{key: "ech", value: b64})
	case name == "" && resolver != "":
		query = append(query, profileStoredQueryItem{key: "ech", value: resolver})
	}
	return query
}

func profileExportPCS(pins []string) string {
	parts := make([]string, 0, len(pins))
	for _, pin := range pins {
		decoded, ok := profileBase64Decode(strings.TrimSpace(pin), false)
		if !ok || len(decoded) != 32 {
			continue
		}
		const lower = "0123456789abcdef"
		var text strings.Builder
		text.Grow(64)
		for _, value := range decoded {
			text.WriteByte(lower[value>>4])
			text.WriteByte(lower[value&0xF])
		}
		parts = append(parts, text.String())
	}
	return strings.Join(parts, ",")
}

func profileExportTransportQuery(transport map[string]any, tlsEnabled bool) []profileStoredQueryItem {
	query := []profileStoredQueryItem{}
	if len(transport) == 0 {
		return query
	}
	kind := configJSONString(transport, "type")
	if kind == "" || kind == "tcp" {
		return query
	}
	switch kind {
	case "mkcp":
		query = append(query, profileStoredQueryItem{key: "type", value: "kcp"})
		for _, pair := range [][2]string{
			{"mtu", "mtu"}, {"tti", "tti"}, {"uplink_capacity", "uplinkCapacity"},
			{"downlink_capacity", "downlinkCapacity"}, {"read_buffer_size", "readBufferSize"},
			{"write_buffer_size", "writeBufferSize"},
		} {
			if value := configJSONInt(transport[pair[0]]); value > 0 {
				query = append(query, profileStoredQueryItem{key: pair[1], value: strconv.Itoa(value)})
			}
		}
		if configJSONBool(transport, "congestion") {
			query = append(query, profileStoredQueryItem{key: "congestion", value: "1"})
		}
		if value := configJSONString(transport, "header_type"); value != "" {
			query = append(query, profileStoredQueryItem{key: "headerType", value: value})
		}
		if value := configJSONString(transport, "seed"); value != "" {
			query = append(query, profileStoredQueryItem{key: "seed", value: value})
		}
		return query
	case "xhttp":
		query = append(query, profileStoredQueryItem{key: "type", value: "xhttp"})
		for _, key := range []string{"host", "path", "mode"} {
			if value := configJSONString(transport, key); value != "" {
				query = append(query, profileStoredQueryItem{key: key, value: value})
			}
		}
		if headers, ok := transport["headers"].(map[string]any); ok && len(headers) > 0 {
			query = append(query, profileStoredQueryItem{key: "headers", value: profileExportHeaderPairs(headers)})
		}
		if extra := profileExportXHTTPExtra(transport); len(extra) > 0 {
			if encoded, err := MarshalCanonicalJSON(extra); err == nil {
				query = append(query, profileStoredQueryItem{key: "extra", value: string(encoded)})
			}
		}
		return query
	}
	if kind == "http" && !tlsEnabled {
		query = append(query, profileStoredQueryItem{key: "type", value: "tcp"})
		query = append(query, profileStoredQueryItem{key: "headerType", value: "http"})
	} else {
		query = append(query, profileStoredQueryItem{key: "type", value: kind})
	}
	host := configJSONString(transport, "host")
	headersForQuery := map[string]any{}
	if headers, ok := transport["headers"].(map[string]any); ok {
		for key, value := range headers {
			headersForQuery[key] = value
		}
		if kind == "ws" {
			// Transport.parseFromJson moves a ws Host header into `host` and
			// removes it from the headers list.
			if value := configJSONString(headersForQuery, "Host"); value != "" {
				if host == "" {
					host = value
				}
				delete(headersForQuery, "Host")
			}
		}
	}
	if host != "" {
		query = append(query, profileStoredQueryItem{key: "host", value: host})
	}
	for _, key := range []string{"path", "method"} {
		if value := configJSONString(transport, key); value != "" {
			query = append(query, profileStoredQueryItem{key: key, value: value})
		}
	}
	if len(headersForQuery) > 0 {
		query = append(query, profileStoredQueryItem{key: "headers", value: profileExportHeaderPairs(headersForQuery)})
	}
	for _, key := range []string{"idle_timeout", "ping_timeout"} {
		if value := configJSONString(transport, key); value != "" {
			query = append(query, profileStoredQueryItem{key: key, value: value})
		}
	}
	if value := configJSONInt(transport["max_early_data"]); value > 0 {
		query = append(query, profileStoredQueryItem{key: "max_early_data", value: strconv.Itoa(value)})
	}
	if value := configJSONString(transport, "early_data_header_name"); value != "" {
		query = append(query, profileStoredQueryItem{key: "early_data_header_name", value: value})
	}
	if value := configJSONString(transport, "service_name"); value != "" {
		query = append(query, profileStoredQueryItem{key: "serviceName", value: value})
	}
	return query
}

// profileExportXHTTPExtra is Transport.xhttpExtraJson: Xray's camelCase
// extra object, including the headers map and the raw xmux object.
func profileExportXHTTPExtra(transport map[string]any) map[string]any {
	obj := map[string]any{}
	if value := configJSONString(transport, "x_padding_bytes"); value != "" {
		obj["xPaddingBytes"] = value
	}
	for _, key := range []string{"no_grpc_header", "no_sse_header", "x_padding_obfs_mode"} {
		if configJSONBool(transport, key) {
			camel := map[string]string{
				"no_grpc_header": "noGRPCHeader", "no_sse_header": "noSSEHeader",
				"x_padding_obfs_mode": "xPaddingObfsMode",
			}[key]
			obj[camel] = true
		}
	}
	for _, pair := range [][2]string{
		{"sc_max_each_post_bytes", "scMaxEachPostBytes"},
		{"sc_min_posts_interval_ms", "scMinPostsIntervalMs"},
		{"sc_stream_up_server_secs", "scStreamUpServerSecs"},
		{"x_padding_key", "xPaddingKey"},
		{"x_padding_header", "xPaddingHeader"},
		{"x_padding_placement", "xPaddingPlacement"},
		{"x_padding_method", "xPaddingMethod"},
		{"uplink_http_method", "uplinkHTTPMethod"},
		{"session_placement", "sessionIDPlacement"},
		{"session_key", "sessionIDKey"},
		{"seq_placement", "seqPlacement"},
		{"seq_key", "seqKey"},
		{"uplink_data_placement", "uplinkDataPlacement"},
		{"uplink_data_key", "uplinkDataKey"},
		{"uplink_chunk_size", "uplinkChunkSize"},
		{"session_id_table", "sessionIDTable"},
		{"session_id_length", "sessionIDLength"},
		{"congestion_controller", "congestionController"},
	} {
		if value := configJSONString(transport, pair[0]); value != "" {
			obj[pair[1]] = value
		}
	}
	if value := configJSONInt(transport["sc_max_buffered_posts"]); value > 0 {
		obj["scMaxBufferedPosts"] = value
	}
	if value := configJSONInt(transport["cwnd"]); value > 0 {
		obj["cwnd"] = value
	}
	if headers, ok := transport["headers"].(map[string]any); ok && len(headers) > 0 {
		obj["headers"] = headers
	}
	if xmux, ok := transport["xmux"].(map[string]any); ok && len(xmux) > 0 {
		obj["xmux"] = xmux
	}
	return obj
}

func profileExportHeaderPairs(headers map[string]any) string {
	keys := make([]string, 0, len(headers))
	for key := range headers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	parts := make([]string, 0, len(keys)*2)
	for _, key := range keys {
		parts = append(parts, key, configJSONString(headers, key))
	}
	return strings.Join(parts, "|")
}

func profileExportMuxQuery(mux map[string]any) []profileStoredQueryItem {
	query := []profileStoredQueryItem{}
	if len(mux) == 0 {
		return query
	}
	enabled, present := mux["enabled"]
	if !present {
		return query
	}
	on, _ := enabled.(bool)
	query = append(query, profileStoredQueryItem{key: "mux", value: strconv.FormatBool(on)})
	if !on {
		return query
	}
	if value := configJSONString(mux, "protocol"); value != "" {
		query = append(query, profileStoredQueryItem{key: "mux_protocol", value: value})
	}
	for _, key := range []string{"max_connections", "min_streams", "max_streams"} {
		if value := configJSONInt(mux[key]); value > 0 {
			query = append(query, profileStoredQueryItem{key: "mux_" + key, value: strconv.Itoa(value)})
		}
	}
	if configJSONBool(mux, "padding") {
		query = append(query, profileStoredQueryItem{key: "mux_padding", value: "true"})
	}
	if brutal, ok := mux["brutal"].(map[string]any); ok && configJSONBool(brutal, "enabled") {
		query = append(query, profileStoredQueryItem{key: "brutal_enabled", value: "true"})
		if value := configJSONInt(brutal["up_mbps"]); value > 0 {
			query = append(query, profileStoredQueryItem{key: "brutal_up_mbps", value: strconv.Itoa(value)})
		}
		if value := configJSONInt(brutal["down_mbps"]); value > 0 {
			query = append(query, profileStoredQueryItem{key: "brutal_down_mbps", value: strconv.Itoa(value)})
		}
	}
	return query
}

func profileExportQUICQuery(quic map[string]any) []profileStoredQueryItem {
	query := []profileStoredQueryItem{}
	for _, pair := range [][2]string{
		{"idle_timeout", "quic_idle_timeout"}, {"keep_alive_period", "quic_keep_alive_period"},
		{"stream_receive_window", "quic_stream_receive_window"},
		{"connection_receive_window", "quic_connection_receive_window"},
	} {
		if value := configJSONString(quic, pair[0]); value != "" {
			query = append(query, profileStoredQueryItem{key: pair[1], value: value})
		}
	}
	for _, pair := range [][2]string{
		{"max_concurrent_streams", "quic_max_concurrent_streams"},
		{"initial_packet_size", "quic_initial_packet_size"},
	} {
		if value := configJSONInt(quic[pair[0]]); value > 0 {
			query = append(query, profileStoredQueryItem{key: pair[1], value: strconv.Itoa(value)})
		}
	}
	if value, present := quic["disable_path_mtu_discovery"]; present {
		disabled, _ := value.(bool)
		query = append(query, profileStoredQueryItem{key: "quic_disable_path_mtu_discovery", value: strconv.FormatBool(disabled)})
	}
	return query
}
