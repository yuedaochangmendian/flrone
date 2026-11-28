// S5c, second half: the TLS/transport-bearing share links (vmess, vless,
// trojan, hysteria/hysteria2/hy2).
//
// Oracle: the Kotlin parsers and their exportToJson writers —
// app/src/main/java/io/nekohasekai/sagernet/outbound/types/{Vmess,Vless,Trojan,Hysteria}.kt,
// outbound/common/{Tls,Transport,Multiplex,QuicFields}.kt. The JVM test
// ProfileStoredGoParityTest pins the exact bytes this file has to emit for
// every vector the Go tests claim.
//
// Refusal contract: any link carrying a field whose Kotlin normalization has
// not been ported here — unported certificate/PEM handling, unknown uTLS
// fingerprints on uTLS-capable types, V2RayN throneExtra on the URL form,
// invalid advanced-TLS values, or an unknown transport type — is answered
// supported:false with a reason. No partially normalized node is ever
// produced.
package mobile

import (
	"encoding/hex"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
)

// S5 advanced: the query/Clash field surface below is ported from Kotlin's
// Tls/Transport/Multiplex/QuicFields and the Hysteria type. Each helper mirrors
// one Kotlin function so the stored JSON and exportIdentity stay byte-pinned.
//
// Fields that still have no Go/Kotlin-equivalent normalization (uTLS "custom"
// client hello blobs, TLS fragment/spoof tricks, cipher suites, certificate
// paths, xhttp `extra` xmux blobs) remain explicit refusals. No value is ever
// silently dropped to keep a link "supported".

var (
	advancedHex64RE    = regexp.MustCompile(`^[0-9a-fA-F]{64}$`)
	advancedPortListRE = regexp.MustCompile(`^:([\d,\-]+)`)
)

// profileHexSHA256B64 mirrors certificateSha256FromPcs: a 64-digit hex SHA-256
// (colons allowed) becomes the standard base64 form sing-box stores. A value
// Kotlin would drop is returned as false so callers can decide whether to
// refuse (link import) or skip (Clash pin list, matching Kotlin's warning).
func profileHexSHA256B64(text string) (string, bool) {
	hexText := strings.ReplaceAll(strings.TrimSpace(text), ":", "")
	if !advancedHex64RE.MatchString(hexText) {
		return "", false
	}
	raw, err := hex.DecodeString(hexText)
	if err != nil || len(raw) != 32 {
		return "", false
	}
	return profileBase64Encode(raw, false, true), true
}

// profileTLSFingerprint mirrors importTlsFingerprint: a known value is kept,
// case-only mistakes are lower-cased, anything else is a refusal.
func profileTLSFingerprint(raw string) (string, bool) {
	fingerprint := strings.TrimSpace(raw)
	if validFingerprint(fingerprint) {
		return fingerprint, true
	}
	lower := strings.ToLower(fingerprint)
	if validFingerprint(lower) {
		return lower, true
	}
	return "", false
}

// profileECHConfig mirrors Ech.normalizeConfig: a list of bare base64 config
// strings becomes one PEM block; a list already carrying a BEGIN line is kept.
func profileECHConfig(items []string) []any {
	joined := ""
	for _, item := range items {
		if strings.Contains(item, "-----BEGIN") {
			out := make([]any, 0, len(items))
			for _, value := range items {
				out = append(out, value)
			}
			return out
		}
		joined += item
	}
	joined = strings.TrimSpace(joined)
	if joined == "" {
		return nil
	}
	return []any{"-----BEGIN ECH CONFIGS-----", joined, "-----END ECH CONFIGS-----"}
}

// profileECHTarget mirrors Ech.setQueryTarget: `<domain>+<scheme://resolver>`,
// a bare resolver URL, or a bare domain.
func profileECHTarget(target string) (name, resolver string) {
	trimmed := strings.TrimSpace(target)
	if index := strings.Index(trimmed, "://"); index >= 0 {
		if plus := strings.Index(trimmed, "+"); plus > 0 && plus < index {
			return strings.TrimSpace(trimmed[:plus]), strings.TrimSpace(trimmed[plus+1:])
		}
		return "", trimmed
	}
	return trimmed, ""
}

// profileValidMLDSA mirrors isMldsa65VerifyKey: raw base64url of 1952 bytes,
// padding rejected (the core uses RawURLEncoding).
func profileValidMLDSA(key string) bool {
	key = strings.TrimSpace(key)
	if key == "" || strings.Contains(key, "=") {
		return false
	}
	decoded, ok := profileBase64Decode(key, true)
	return ok && len(decoded) == 1952
}

// profileValidDuration mirrors the subset of Validation.duration used by the
// advanced fields. Bare digit strings are rejected (Go needs a unit), a plain
// "0" is accepted. Negative values are rejected for these link fields.
func profileValidDuration(text string) bool {
	return profileImportValidDuration(text)
}

// profileValidMemoryBytes mirrors Validation.memoryBytes(text, true): a bare
// integer (possibly "0") or a decimal with a known byte unit.
func profileValidMemoryBytes(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	digits := 0
	for digits < len(trimmed) && trimmed[digits] >= '0' && trimmed[digits] <= '9' {
		digits++
	}
	if digits == len(trimmed) {
		_, err := strconv.ParseUint(trimmed, 10, 64)
		return err == nil
	}
	if digits == 0 {
		return false
	}
	remaining := strings.TrimSpace(trimmed[digits:])
	for _, unit := range []string{"b", "k", "kb", "m", "mb", "g", "gb", "t", "tb", "p", "pb", "e", "eb"} {
		if strings.EqualFold(remaining, unit) {
			return true
		}
	}
	return false
}

// profileFingerprintValues are the uTLS values Kotlin's singBoxFingerprint
// accepts, kept in one place so the link and Clash parsers cannot drift.
var profileFingerprintValues = map[string]bool{
	"": true, "chrome": true, "chrome_psk": true, "chrome_psk_shuffle": true,
	"chrome_padding_psk_shuffle": true, "chrome_pq": true, "chrome_pq_psk": true,
	"firefox": true, "edge": true, "safari": true, "360": true, "qq": true,
	"ios": true, "android": true, "random": true, "randomized": true,
	"custom": true, "unsafe": true,
}

// profileSecureCipherSuites is TLS_SECURE_CIPHER_SUITES (TLS.h): the names
// sing-box accepts. Kotlin's import drops insecure and unknown suites with a
// warning; the Go importer keeps exactly the entries Kotlin would keep.
var profileSecureCipherSuites = map[string]bool{
	"TLS_AES_128_GCM_SHA256": true, "TLS_AES_256_GCM_SHA384": true,
	"TLS_CHACHA20_POLY1305_SHA256":         true,
	"TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA": true, "TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA": true,
	"TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA": true, "TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA": true,
	"TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256": true, "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384": true,
	"TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256": true, "TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384": true,
	"TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256":   true,
	"TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256": true,
}

// profileKnownTLSCurves is TlsChecks.tlsCurve: P256/P384/P521/X25519/
// X25519MLKEM768, matched case-insensitively; unknown curves are dropped.
var profileKnownTLSCurves = map[string]bool{
	"p256": true, "p384": true, "p521": true, "x25519": true, "x25519mlkem768": true,
}

// profileSplitCipherSuites mirrors splitCipherSuites (TLS.h): commas and
// colons both separate, each item is trimmed, empty items dropped.
func profileSplitCipherSuites(value string) []string {
	parts := strings.Split(strings.ReplaceAll(value, ",", ":"), ":")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// profileImportTLSCipherSuites mirrors importTlsCipherSuites: only the secure
// names survive; unknown or insecure entries are reported and dropped.
func profileImportTLSCipherSuites(names []string) []any {
	out := make([]any, 0, len(names))
	for _, name := range names {
		if profileSecureCipherSuites[name] {
			out = append(out, name)
		}
	}
	return out
}

// profileImportTLSKnownCurves mirrors tlsKnownCurves: trim, drop empty and
// unknown names, keep the spelling as written.
func profileImportTLSKnownCurves(names []string) []any {
	out := make([]any, 0, len(names))
	for _, name := range names {
		trimmed := strings.TrimSpace(name)
		if trimmed == "" {
			continue
		}
		if profileKnownTLSCurves[strings.ToLower(trimmed)] {
			out = append(out, trimmed)
		}
	}
	return out
}

// profileStoredAdvanced is the stored form of the TLS/transport types. Its
// zero fields are omitted exactly where Kotlin's exportToJson omits them; the
// marker booleans carry the "unspecified vs explicitly false" distinction.
type profileStoredAdvanced struct {
	Type      string
	Name      string
	Server    string
	Port      int
	AuthType  string // base64/string for HTTP uot etc., not used here
	Fields    map[string]any
	TLS       map[string]any
	Transport map[string]any
	Multiplex map[string]any
	QUIC      map[string]any
	HasTLS    bool
	HasTr     bool
	HasMux    bool
	HasQUIC   bool
	// TLS links always require a TLS block in the stored form, even if empty.
	AlwaysTLS bool
}

func (node *profileStoredAdvanced) object() map[string]any {
	object := map[string]any{"type": node.Type}
	realm := profileHysteriaRealmActive(node)
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
		// Hysteria.applyRealmObject: realm replaces server/server_port/server_ports.
		delete(object, "server")
		delete(object, "server_port")
		delete(object, "server_ports")
	}
	if node.HasTLS || node.AlwaysTLS {
		object["tls"] = node.TLS
	}
	if node.HasTr {
		object["transport"] = node.Transport
	}
	if node.HasMux {
		object["multiplex"] = node.Multiplex
	}
	if node.HasQUIC {
		object["quic"] = node.QUIC
	}
	return object
}

// profileHysteriaRealmActive is Hysteria.realmActive: a hysteria2 profile
// carrying a realm object replaces the server address entirely.
func profileHysteriaRealmActive(node *profileStoredAdvanced) bool {
	if node == nil || node.Type != "hysteria2" {
		return false
	}
	_, ok := node.Fields["realm"].(map[string]any)
	return ok
}

func profileHysteriaRealmFields(node *profileStoredAdvanced) (map[string]any, bool) {
	realm, ok := node.Fields["realm"].(map[string]any)
	return realm, ok
}

func (node *profileStoredAdvanced) json() (string, error) {
	encoded, err := MarshalCanonicalJSON(node.object())
	return string(encoded), err
}

func profileAdvancedNode(node *profileStoredAdvanced) (*profileImportedNode, error) {
	storedJSON, err := node.json()
	if err != nil {
		return nil, err
	}
	withoutTag := *node
	withoutTag.Name = ""
	dedupJSON, err := withoutTag.json()
	if err != nil {
		return nil, err
	}
	identity := storedJSON
	if node.Server != "" || profileHysteriaRealmActive(node) {
		encoded, encodeErr := MarshalCanonicalJSON(profileAdvancedIdentity(node))
		if encodeErr != nil {
			return nil, encodeErr
		}
		identity = string(encoded)
	}
	link, err := profileAdvancedLink(node)
	if err != nil {
		return nil, err
	}
	return &profileImportedNode{
		Type:     node.Type,
		Name:     node.Name,
		JSON:     storedJSON,
		Link:     link,
		Identity: identity,
		DedupKey: "throne://add/" + profileBase64Encode([]byte(dedupJSON), true, false),
	}, nil
}

// profileAdvancedIdentity is Outbound.exportIdentity for the TLS/transport
// types: server/port plus the identity-relevant TLS blocks (enabled,
// disable_sni, ACE server_name, uTLS fingerprint, ECH query target, REALITY
// keys) and the transport type. It must stay in lockstep with
// Tls.exportIdentity/Utls.exportIdentity/Ech.exportIdentity/
// Reality.exportIdentity/Transport.exportIdentity -- subscription reconcile
// hashes these bytes, so a missed field collapses distinct nodes.
func profileAdvancedIdentity(node *profileStoredAdvanced) map[string]any {
	// Hysteria overrides exportIdentity under realm: the server keys disappear
	// and the rendezvous coordinates take their place (hysteria.cpp:371-389).
	if realm, ok := profileHysteriaRealmFields(node); ok && node.Type == "hysteria2" {
		identity := map[string]any{
			"protocol_version": "2",
			"realm_server_url": profileJSONString(realm, "server_url"),
			"realm_id":         profileJSONString(realm, "realm_id"),
		}
		if tlsIdentity := profileAdvancedTLSIdentity(node.TLS); len(tlsIdentity) > 0 {
			identity["tls"] = tlsIdentity
		}
		return identity
	}
	object := map[string]any{
		"server":      node.Server,
		"server_port": node.Port,
	}
	if node.HasTLS || node.AlwaysTLS {
		if tlsIdentity := profileAdvancedTLSIdentity(node.TLS); len(tlsIdentity) > 0 {
			object["tls"] = tlsIdentity
		}
	}
	if node.HasTr {
		if transportType, _ := node.Transport["type"].(string); transportType != "" && transportType != "tcp" {
			object["transport"] = map[string]any{"type": transportType}
		}
	}
	// Hysteria overrides exportIdentity: the protocol version is always part of
	// the identity, an obfs block collapses to `obfs: true`, and listed server
	// ports are joined into one string.
	if node.Type == "hysteria" || node.Type == "hysteria2" {
		if node.Type == "hysteria" {
			object["protocol_version"] = "1"
		} else {
			object["protocol_version"] = "2"
		}
		if ports, ok := node.Fields["server_ports"]; ok {
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
		if obfs, ok := node.Fields["obfs"]; ok && obfs != nil {
			object["obfs"] = true
		}
	}
	return object
}

// profileAdvancedTLSIdentity is Tls.exportIdentity: only enabled,
// disable_sni, the ACE server name and the identity-bearing blocks.
func profileAdvancedTLSIdentity(tls map[string]any) map[string]any {
	if tls == nil {
		return nil
	}
	enabled, _ := tls["enabled"].(bool)
	if !enabled {
		return nil
	}
	identity := map[string]any{"enabled": true}
	if disableSNI, _ := tls["disable_sni"].(bool); disableSNI {
		identity["disable_sni"] = true
	}
	if serverName, _ := tls["server_name"].(string); serverName != "" {
		identity["server_name"] = configToACEHost(serverName)
	}
	if utls, ok := tls["utls"].(map[string]any); ok {
		if utlsEnabled, _ := utls["enabled"].(bool); utlsEnabled {
			if fingerprint, _ := utls["fingerprint"].(string); fingerprint != "" {
				identity["utls"] = map[string]any{"fingerprint": fingerprint}
			}
		}
	}
	if ech, ok := tls["ech"].(map[string]any); ok {
		if echEnabled, _ := ech["enabled"].(bool); echEnabled {
			echIdentity := map[string]any{"enabled": true}
			if queryName, _ := ech["query_server_name"].(string); queryName != "" {
				echIdentity["query_server_name"] = configToACEHost(queryName)
			}
			if resolver, _ := ech["resolver"].(string); resolver != "" {
				echIdentity["resolver"] = resolver
			}
			identity["ech"] = echIdentity
		}
	}
	if reality, ok := tls["reality"].(map[string]any); ok {
		realityIdentity := map[string]any{}
		if realityEnabled, _ := reality["enabled"].(bool); realityEnabled {
			realityIdentity["enabled"] = true
		}
		for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
			if value, _ := reality[key].(string); value != "" {
				realityIdentity[key] = value
			}
		}
		if len(realityIdentity) > 0 {
			identity["reality"] = realityIdentity
		}
	}
	return identity
}

// profileAdvancedLink emits the type's canonical share link from the stored
// form. It is the inverse of the parsers below, using the same helpers the
// simple exporter uses. Links are reconstructed from the parsed fields rather
// than echoing the input: a Kotlin re-export would do the same.
func profileAdvancedLink(node *profileStoredAdvanced) (string, error) {
	if profileHysteriaRealmActive(node) {
		// hysteria.cpp:264-331: no link form carries realm.
		return "", nil
	}
	if node.Server == "" {
		return "", nil
	}
	// The export slice owns the canonical link builders for the five
	// TLS/transport types; reuse them so an imported node's link is byte-equal
	// to the Kotlin export instead of a second, weaker implementation.
	if profileExportAdvancedTypes[node.Type] {
		return profileExportAdvancedLink(profileAdvancedAsExport(node))
	}
	builder := profileStoredLinkBuilder{
		scheme:      node.Type,
		host:        node.Server,
		port:        node.Port,
		fragment:    node.Name,
		hasFragment: node.Name != "",
	}
	if node.Server == "" {
		return "", nil
	}
	q := node.Fields
	switch node.Type {
	case "vmess":
		// Kotlin always exports the V2RayN JSON form. Rebuild the envelope.
		builder.scheme = "vmess"
		envelope := map[string]any{
			"v": "2", "ps": node.Name, "add": node.Server,
			"port": strconv.Itoa(node.Port),
			"id":   q["uuid"],
			"aid":  "0",
			"scy":  "auto",
			"net":  "tcp",
			"type": "none",
			"host": "", "path": "", "tls": "", "sni": "", "alpn": "", "fp": "",
		}
		if tls := node.TLS; tls != nil {
			if enabled, _ := tls["enabled"].(bool); enabled {
				envelope["tls"] = "tls"
			}
			if serverName, _ := tls["server_name"].(string); serverName != "" {
				envelope["sni"] = serverName
			}
		}
		encoded, err := MarshalCanonicalJSON(envelope)
		if err != nil {
			return "", err
		}
		return "vmess://" + profileBase64Encode(encoded, false, false), nil
	case "vless":
		builder.scheme = "vless"
		if uuid, _ := q["uuid"].(string); uuid != "" {
			builder.username, builder.hasUsername = uuid, true
		}
		builder.query = append(builder.query, profileStoredQueryItem{key: "encryption", value: profileJSONString(q, "encryption")})
		if flow, _ := q["flow"].(string); flow != "" {
			builder.query = append(builder.query, profileStoredQueryItem{key: "flow", value: flow})
		}
		builder.query = append(builder.query, profileTLSQuery(node.TLS)...)
		builder.query = append(builder.query, profileTransportQuery(node.Transport)...)
		// Kotlin's Vless.exportToLink always writes packetEncoding (xudp, or
		// "none" when the stored value is empty). The importer accepts this
		// key, so emitting it keeps the link round-trippable and byte-equal
		// to the JVM oracle -- including the migrated Xray rows in S5d.
		packetEncoding, _ := q["packet_encoding"].(string)
		if packetEncoding == "" {
			packetEncoding = "none"
		}
		builder.query = append(builder.query, profileStoredQueryItem{key: "packetEncoding", value: packetEncoding})
	case "trojan":
		builder.scheme = "trojan"
		if password, _ := q["password"].(string); password != "" {
			builder.username, builder.hasUsername = password, true
		}
		builder.query = append(builder.query, profileTLSQuery(node.TLS)...)
		builder.query = append(builder.query, profileTransportQuery(node.Transport)...)
	case "hysteria", "hysteria2":
		builder.scheme = node.Type
		if node.Type == "hysteria2" {
			if password, _ := q["password"].(string); password != "" {
				builder.username, builder.hasUsername = password, true
			}
		} else {
			if auth, _ := q["auth_str"].(string); auth != "" {
				builder.query = append(builder.query, profileStoredQueryItem{key: "auth", value: auth})
			}
		}
		builder.query = append(builder.query, profileTLSQuery(node.TLS)...)
	case "tuic":
		builder.scheme = "tuic"
		if uuid, _ := q["uuid"].(string); uuid != "" {
			builder.username, builder.hasUsername = uuid, true
		}
		if password, _ := q["password"].(string); password != "" {
			builder.password, builder.hasPassword = password, true
		}
		builder.query = append(builder.query, profileTuicLinkQuery(node)...)
		builder.query = append(builder.query, profileExportTLSQuery(node.TLS)...)
		builder.query = append(builder.query, profileQUICLinkQuery(node)...)
		builder.query = append(builder.query, profileAdvancedDialQuery(node)...)
	case "anytls":
		builder.scheme = "anytls"
		if password, _ := q["password"].(string); password != "" {
			builder.username, builder.hasUsername = password, true
		}
		if value, _ := q["idle_session_check_interval"].(string); value != "" {
			builder.query = append(builder.query, profileStoredQueryItem{key: "idle_session_check_interval", value: value})
		}
		if value, _ := q["idle_session_timeout"].(string); value != "" {
			builder.query = append(builder.query, profileStoredQueryItem{key: "idle_session_timeout", value: value})
		}
		if value := profileJSONInt(q, "min_idle_session"); value > 0 {
			builder.query = append(builder.query, profileStoredQueryItem{key: "min_idle_session", value: strconv.Itoa(value)})
		}
		builder.query = append(builder.query, profileExportTLSQuery(node.TLS)...)
		builder.query = append(builder.query, profileAdvancedDialQuery(node)...)
	}
	return builder.build(), nil
}

// profileAdvancedAsExport maps the import-side node onto the export-side model
// so both slices share one link/identity implementation.
func profileAdvancedAsExport(node *profileStoredAdvanced) *profileExportAdvanced {
	return &profileExportAdvanced{
		Type: node.Type, Name: node.Name, Server: node.Server, Port: node.Port,
		Fields: node.Fields, TLS: node.TLS, Transport: node.Transport,
		Multiplex: node.Multiplex, QUIC: node.QUIC,
		HasTLS: node.HasTLS, HasTr: node.HasTr, HasMux: node.HasMux, HasQUIC: node.HasQUIC,
		AlwaysTLS: node.AlwaysTLS,
	}
}

// profileAdvancedDialQuery maps an advanced node's flat dial fields back to
// the share-link query items DialFields.exportToLink writes, in the same
// order as the simple exporter.
func profileAdvancedDialQuery(node *profileStoredAdvanced) []profileStoredQueryItem {
	simple := &profileStoredSimple{}
	if node == nil {
		return nil
	}
	fields := node.Fields
	if reuse, _ := fields["reuse_addr"].(bool); reuse {
		simple.ReuseAddr = true
	}
	simple.ConnectTimeout, _ = fields["connect_timeout"].(string)
	if tfo, _ := fields["tcp_fast_open"].(bool); tfo {
		simple.TCPFastOpen = true
	}
	if mptcp, _ := fields["tcp_multi_path"].(bool); mptcp {
		simple.TCPMultiPath = true
	}
	if frag, _ := fields["udp_fragment"].(bool); frag {
		simple.UDPFragment = true
	}
	simple.BindInterface, _ = fields["bind_interface"].(string)
	simple.Inet4Bind, _ = fields["inet4_bind_address"].(string)
	simple.Inet6Bind, _ = fields["inet6_bind_address"].(string)
	return profileStoredDialQuery(simple)
}

func profileJSONInt(object map[string]any, key string) int {
	if object == nil {
		return 0
	}
	return configJSONInt(object[key])
}

func profileTuicLinkQuery(node *profileStoredAdvanced) []profileStoredQueryItem {
	q := node.Fields
	query := []profileStoredQueryItem{}
	if value, _ := q["congestion_control"].(string); value != "" {
		query = append(query, profileStoredQueryItem{key: "congestion_control", value: value})
	}
	udpOverStream, _ := q["udp_over_stream"].(bool)
	if !udpOverStream {
		if value, _ := q["udp_relay_mode"].(string); value != "" {
			query = append(query, profileStoredQueryItem{key: "udp_relay_mode", value: value})
		}
	}
	if udpOverStream {
		query = append(query, profileStoredQueryItem{key: "udp_over_stream", value: "true"})
	}
	if zero, _ := q["zero_rtt_handshake"].(bool); zero {
		query = append(query, profileStoredQueryItem{key: "zero_rtt_handshake", value: "true"})
	}
	if value, _ := q["heartbeat"].(string); value != "" {
		query = append(query, profileStoredQueryItem{key: "heartbeat", value: value})
	}
	return query
}

func profileQUICLinkQuery(node *profileStoredAdvanced) []profileStoredQueryItem {
	q := node.Fields
	query := []profileStoredQueryItem{}
	for _, pair := range [][2]string{
		{"idle_timeout", "quic_idle_timeout"},
		{"keep_alive_period", "quic_keep_alive_period"},
		{"stream_receive_window", "quic_stream_receive_window"},
		{"connection_receive_window", "quic_connection_receive_window"},
	} {
		if value, _ := q[pair[0]].(string); value != "" {
			query = append(query, profileStoredQueryItem{key: pair[1], value: value})
		}
	}
	if value := profileJSONInt(q, "max_concurrent_streams"); value > 0 {
		query = append(query, profileStoredQueryItem{key: "quic_max_concurrent_streams", value: strconv.Itoa(value)})
	}
	if value := profileJSONInt(q, "initial_packet_size"); value > 0 {
		query = append(query, profileStoredQueryItem{key: "quic_initial_packet_size", value: strconv.Itoa(value)})
	}
	if value, present := q["disable_path_mtu_discovery"]; present {
		flag, _ := value.(bool)
		query = append(query, profileStoredQueryItem{key: "quic_disable_path_mtu_discovery", value: strconv.FormatBool(flag)})
	}
	return query
}

func profileJSONString(object map[string]any, key string) string {
	value, _ := object[key].(string)
	return value
}

func profileTLSQuery(tls map[string]any) []profileStoredQueryItem {
	var query []profileStoredQueryItem
	if tls == nil {
		return query
	}
	if enabled, _ := tls["enabled"].(bool); enabled {
		query = append(query, profileStoredQueryItem{key: "security", value: "tls"})
	}
	if disableSNI, _ := tls["disable_sni"].(bool); disableSNI {
		query = append(query, profileStoredQueryItem{key: "disable_sni", value: "true"})
	}
	if serverName, _ := tls["server_name"].(string); serverName != "" {
		query = append(query, profileStoredQueryItem{key: "sni", value: serverName})
	}
	if insecure, _ := tls["insecure"].(bool); insecure {
		query = append(query, profileStoredQueryItem{key: "allowInsecure", value: "true"})
	}
	if alpn, ok := tls["alpn"].([]any); ok {
		parts := make([]string, 0, len(alpn))
		for _, item := range alpn {
			if text, ok := item.(string); ok {
				parts = append(parts, text)
			}
		}
		query = append(query, profileStoredQueryItem{key: "alpn", value: strings.Join(parts, ",")})
	}
	if utls, ok := tls["utls"].(map[string]any); ok {
		if fingerprint, _ := utls["fingerprint"].(string); fingerprint != "" {
			query = append(query, profileStoredQueryItem{key: "fp", value: fingerprint})
		}
	}
	return query
}

func profileTransportQuery(transport map[string]any) []profileStoredQueryItem {
	var query []profileStoredQueryItem
	if transport == nil {
		return query
	}
	if kind, _ := transport["type"].(string); kind != "" {
		query = append(query, profileStoredQueryItem{key: "type", value: kind})
	}
	if path, _ := transport["path"].(string); path != "" {
		query = append(query, profileStoredQueryItem{key: "path", value: path})
	}
	if serviceName, _ := transport["service_name"].(string); serviceName != "" {
		query = append(query, profileStoredQueryItem{key: "serviceName", value: serviceName})
	}
	return query
}

// --- shared link field parsers ---------------------------------------------

// profileImportTLS parses Tls.parseFromLink (Tls.kt:780). The field set below
// is the TLS surface Kotlin actually reads and writes; a value Kotlin would
// normalize away (unknown cipher/curve, invalid duration) is dropped exactly
// where Kotlin drops it, so the stored bytes match the JVM oracle.
//
// utlsSupported mirrors UTls.supported: Hysteria and TUIC set it false, where
// parseFromLink keeps any non-empty fp verbatim instead of validating it.
func profileImportTLS(link profileParsedLink, requireTLS bool, utlsSupported bool) (map[string]any, bool, error) {
	query := link.Query
	refuse := func(key string) (map[string]any, bool, error) {
		return nil, false, profileUnsupported("unsupported TLS field: " + key)
	}
	security := strings.ToLower(strings.TrimSpace(query.Value("security")))
	enabled := requireTLS
	securityOff := security == "none" || security == "false" || security == "0"
	if security != "" {
		switch security {
		case "tls", "true", "1", "reality":
			enabled = true
		case "none", "false", "0":
			enabled = false
		default:
			return refuse("security=" + security)
		}
	}
	// Kotlin reads the remaining TLS keys even with security off; an sni or a
	// Reality key still turns TLS on.
	if query.Has("sni") && !securityOff {
		enabled = true
	}
	if query.Has("peer") && !securityOff {
		enabled = true
	}
	// A pbk turns Reality on even when security=none/absent (Tls.parseFromLink
	// ends with `if (reality.public_key.isNotEmpty()) enabled = true`).
	if query.Has("pbk") {
		enabled = true
	}
	if !enabled {
		return map[string]any{}, false, nil
	}
	tls := map[string]any{"enabled": true}
	if profileTLSBool(query.Value("disable_sni")) {
		tls["disable_sni"] = true
	}
	if query.Has("sni") {
		tls["server_name"] = aceShareHost(query.Value("sni"))
	}
	if query.Has("peer") {
		tls["server_name"] = aceShareHost(query.Value("peer"))
	}
	if query.Has("allowInsecure") && profileTLSBool(query.Value("allowInsecure")) {
		tls["insecure"] = true
	}
	if query.Has("allow_insecure") && profileTLSBool(query.Value("allow_insecure")) {
		tls["insecure"] = true
	}
	if query.Has("insecure") && profileTLSBool(query.Value("insecure")) {
		tls["insecure"] = true
	}
	if query.Has("alpn") {
		tls["alpn"] = stringList(query.ValueFully("alpn"))
	}
	for _, field := range []struct{ link, stored string }{
		{"tls_min_version", "min_version"}, {"tls_max_version", "max_version"},
	} {
		if !query.Has(field.link) {
			continue
		}
		value := strings.TrimSpace(query.Value(field.link))
		switch value {
		case "1.0", "1.1", "1.2", "1.3":
			tls[field.stored] = value
		default:
			return refuse(field.link + "=" + value)
		}
	}
	if query.Has("tls_cipher_suites") {
		if suites := profileImportTLSCipherSuites(profileSplitCipherSuites(query.ValueFully("tls_cipher_suites"))); len(suites) > 0 {
			tls["cipher_suites"] = suites
		}
	}
	if query.Has("cs") {
		if suites := profileImportTLSCipherSuites(profileSplitCipherSuites(query.ValueFully("cs"))); len(suites) > 0 {
			tls["cipher_suites"] = suites
		} else {
			delete(tls, "cipher_suites")
		}
	}
	if query.Has("tls_curve_preferences") {
		if curves := profileImportTLSKnownCurves(strings.Split(query.Value("tls_curve_preferences"), ",")); len(curves) > 0 {
			tls["curve_preferences"] = curves
		}
	}
	if query.Has("tls_certificate") {
		tls["certificate"] = qtStringList(query.Value("tls_certificate"), ",")
	}
	if query.Has("tls_certificate_path") {
		tls["certificate_path"] = query.Value("tls_certificate_path")
	}
	if query.Has("pcs") {
		pins := profileCertificatePins(query.ValueFully("pcs"))
		if len(pins) == 0 {
			return refuse("pcs")
		}
		tls["certificate_sha256"] = pins
	}
	if query.Has("tls_certificate_public_key_sha256") {
		tls["certificate_public_key_sha256"] = stringList(query.Value("tls_certificate_public_key_sha256"))
	}
	if query.Has("tls_client_certificate") {
		tls["client_certificate"] = qtStringList(query.Value("tls_client_certificate"), ",")
	}
	if query.Has("tls_client_certificate_path") {
		tls["client_certificate_path"] = query.Value("tls_client_certificate_path")
	}
	if query.Has("tls_client_key") {
		tls["client_key"] = qtStringList(query.Value("tls_client_key"), ",")
	}
	if query.Has("tls_client_key_path") {
		tls["client_key_path"] = query.Value("tls_client_key_path")
	}
	if query.Has("tls_fragment") {
		tls["fragment"] = query.Value("tls_fragment") == "true"
	}
	if query.Has("tls_fragment_fallback_delay") {
		if value := strings.TrimSpace(query.Value("tls_fragment_fallback_delay")); profileValidDuration(value) {
			tls["fragment_fallback_delay"] = value
		}
	}
	if query.Has("tls_record_fragment") && query.Value("tls_record_fragment") == "true" {
		tls["record_fragment"] = true
	}
	if query.Has("tls_spoof") {
		if value := strings.TrimSpace(query.Value("tls_spoof")); value != "" {
			tls["spoof"] = value
		}
	}
	if query.Has("tls_spoof_method") {
		if value := strings.TrimSpace(query.Value("tls_spoof_method")); value != "" {
			if _, hasSpoof := tls["spoof"]; hasSpoof {
				tls["spoof_method"] = value
			}
		}
	}
	if query.Has("tls_spoof_enabled") {
		tls["spoof_enabled"] = query.Value("tls_spoof_enabled") == "true"
	}
	if query.Has("tls_tricks") {
		tls["tls_tricks"] = map[string]any{"mixedcase_sni": query.Value("tls_tricks") == "true"}
	}
	if query.Has("fp") {
		raw := query.Value("fp")
		if utlsSupported {
			fingerprint, ok := profileTLSFingerprint(raw)
			if !ok {
				return refuse("fp=" + strings.TrimSpace(raw))
			}
			if fingerprint != "" {
				tls["utls"] = map[string]any{"enabled": true, "fingerprint": fingerprint}
			}
		} else if raw != "" {
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": raw}
		}
	}
	// Ech.parseFromLink: the short form and the explicit fields all feed the
	// same object; exportToJson writes the Ace query name and resolver.
	ech := map[string]any{}
	if query.Has("ech") {
		value := strings.TrimSpace(query.ValueFully("ech"))
		echEnabled := value != "" && value != "0" && value != "false"
		if echEnabled {
			if value != "1" && value != "true" {
				if strings.Contains(value, "://") || strings.Contains(value, ".") {
					name, resolver := profileECHTarget(value)
					if name != "" {
						ech["query_server_name"] = aceShareHost(name)
					}
					if resolver != "" {
						ech["resolver"] = resolver
					}
				} else if config := profileECHConfig([]string{value}); config != nil {
					ech["config"] = config
				}
			}
			ech["enabled"] = true
		}
	}
	if query.Has("ech_enabled") {
		ech["enabled"] = query.Value("ech_enabled") == "true"
	}
	if query.Has("ech_config") {
		items := qtSplitSkipEmpty(query.ValueFully("ech_config"), ",")
		if config := profileECHConfig(items); config != nil {
			ech["config"] = config
		}
	}
	if query.Has("ech_config_path") {
		ech["config_path"] = query.Value("ech_config_path")
	}
	if query.Has("ech_server_name") {
		if name := query.Value("ech_server_name"); name != "" {
			ech["query_server_name"] = aceShareHost(name)
		}
	}
	if enabledValue, _ := ech["enabled"].(bool); enabledValue {
		tls["ech"] = ech
	}
	// Reality.parseFromLink plus Xray's pqv (ML-DSA-65) key.
	if query.Has("pbk") {
		publicKey := strings.TrimSpace(query.Value("pbk"))
		if strings.HasSuffix(publicKey, "=") {
			// importRealityPublicKey drops trailing '=' only when the unpadded
			// key is a valid 32-byte base64url value.
			unpadded := strings.TrimRight(publicKey, "=")
			if decoded, ok := profileBase64Decode(unpadded, true); ok && len(decoded) == 32 {
				publicKey = unpadded
			}
		}
		shortID := strings.TrimSpace(query.Value("sid"))
		reality := map[string]any{"enabled": true}
		if publicKey != "" {
			reality["public_key"] = publicKey
		}
		if shortID != "" {
			reality["short_id"] = shortID
		}
		if query.Has("pqv") {
			verify := strings.TrimSpace(query.Value("pqv"))
			if verify != "" {
				if !profileValidMLDSA(verify) {
					return refuse("pqv")
				}
				reality["mldsa65_verify"] = verify
			}
		}
		tls["reality"] = reality
		// A public key turns Reality on even when security=none/absent.
		tls["enabled"] = true
	}
	return tls, true, nil
}

// qtStringList is QtStrings.split(value, sep): every part, including empty
// ones, is kept. tlsLinkList (stringList) drops empties instead.
func qtStringList(value, sep string) []any {
	parts := strings.Split(value, sep)
	out := make([]any, 0, len(parts))
	for _, part := range parts {
		out = append(out, part)
	}
	return out
}

// qtSplitSkipEmpty is QtStrings.splitSkipEmpty.
func qtSplitSkipEmpty(value, sep string) []string {
	parts := strings.Split(value, sep)
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

// profileCertificatePins mirrors certificateSha256FromPcs: only valid 64-hex
// pins are kept, exactly as Kotlin's import does for the `pcs` link key.
func profileCertificatePins(text string) []any {
	var out []any
	for _, item := range qtSplitSkipEmpty(text, ",") {
		if pin, ok := profileHexSHA256B64(item); ok {
			out = append(out, pin)
		}
	}
	return out
}

func profileTLSBool(value string) bool {
	return strings.ReplaceAll(value, "1", "true") == "true"
}

func validFingerprint(fingerprint string) bool {
	return profileFingerprintValues[fingerprint]
}

func aceShareHost(host string) string {
	if host == "" || configIsASCII(host) {
		return host
	}
	if ace, ok := configToACE(host); ok {
		return ace
	}
	return host
}

func stringList(value string) []any {
	parts := strings.Split(value, ",")
	items := make([]any, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			items = append(items, trimmed)
		}
	}
	return items
}

// profileImportTransport parses Transport.parseFromLink (Transport.kt:170).
// Supported: ws/http/grpc/httpupgrade/quic with their common headers/early-data
// fields, plus xhttp (including the Xray `extra` object's scalar fields, raw
// xmux and headers map) and mkcp. A transport type Kotlin does not read is
// refused rather than dropped.
func profileImportTransport(link profileParsedLink, tlsEnabled bool) (map[string]any, bool, error) {
	query := link.Query
	refuse := func(key string) (map[string]any, bool, error) {
		return nil, false, profileUnsupported("transport field not ported yet: " + key)
	}
	linkType := singBoxTransportType(query.Value("type"))
	rawHTTP := (linkType == "" || linkType == "tcp" || linkType == "raw") && query.Value("headerType") == "http"
	kind := ""
	if query.Has("type") {
		kind = linkType
		if kind == "raw" {
			kind = "tcp"
		}
	}
	if rawHTTP || kind == "h2" {
		kind = "http"
	}
	if kind == "" || kind == "tcp" {
		// A plain TCP dial writes no transport block; any transport field
		// without a type is refused rather than dropped.
		for _, key := range []string{"host", "path", "headers", "serviceName", "idle_timeout",
			"ping_timeout", "early_data_header_name", "max_early_data", "method", "mode",
			"extra", "mtu", "tti", "uplinkCapacity", "downlinkCapacity", "seed"} {
			if query.Has(key) {
				return nil, false, profileUnsupported("transport fields on a plain TCP link: " + key)
			}
		}
		return nil, false, nil
	}
	switch kind {
	case "ws", "http", "httpupgrade", "grpc", "quic", "xhttp", "mkcp":
	default:
		return nil, false, profileUnsupported("transport type not ported yet: " + kind)
	}
	// The mux* keys belong to Multiplex (parsed separately by the callers), not
	// to the transport; a caller that sees them there is a bug, so refuse.
	for _, key := range []string{"mux", "mux_protocol", "mux_max_connections", "mux_min_streams",
		"mux_max_streams", "mux_padding", "brutal_enabled", "brutal_up_mbps", "brutal_down_mbps"} {
		if query.Has(key) {
			return refuse(key)
		}
	}
	if kind == "mkcp" {
		return profileImportKCPTransport(query)
	}
	if kind == "xhttp" {
		return profileImportXHTTPTransport(query)
	}
	transport := map[string]any{"type": kind}
	path := query.ValueFully("path")
	if rawHTTP {
		path = qtSectionFirstSkipEmpty(path, ',')
	}
	if kind == "grpc" {
		if value := query.ValueFully("serviceName"); value != "" {
			transport["service_name"] = value
		}
	} else if path != "" {
		transport["path"] = path
	}
	if rawHeaders := query.ValueFully("headers"); rawHeaders != "" {
		pairs := strings.Split(rawHeaders, "|")
		if len(pairs)%2 != 0 {
			// Kotlin warns and clears the headers list; it is not a refusal.
			pairs = nil
		}
		if len(pairs) > 0 {
			headers := map[string]any{}
			for index := 0; index < len(pairs); index += 2 {
				headers[pairs[index]] = pairs[index+1]
			}
			transport["headers"] = headers
		}
	}
	host := query.ValueFully("host")
	if host != "" {
		switch kind {
		case "ws":
			headers, _ := transport["headers"].(map[string]any)
			if headers == nil {
				headers = map[string]any{}
			}
			headers["Host"] = aceShareHost(host)
			transport["headers"] = headers
		case "http", "httpupgrade":
			// Transport.exportToJson writes `host` only for these two types;
			// grpc/quic keep the parsed value on the model but drop it from the
			// stored form.
			transport["host"] = aceShareHost(host)
		}
	}
	if query.Has("method") {
		method := strings.TrimSpace(query.Value("method"))
		if !profileValidHTTPToken(method) {
			return refuse("method=" + method)
		}
		if method != "" {
			transport["method"] = method
		}
	} else if rawHTTP || kind == "h2" {
		transport["method"] = "GET"
	}
	for _, field := range []struct{ link, stored string }{
		{"idle_timeout", "idle_timeout"}, {"ping_timeout", "ping_timeout"},
	} {
		if !query.Has(field.link) {
			continue
		}
		value := strings.TrimSpace(query.Value(field.link))
		if !profileValidDuration(value) {
			return refuse(field.link + "=" + value)
		}
		if value != "" {
			transport[field.stored] = value
		}
	}
	if query.Has("max_early_data") {
		value := profileImportQtInt(query.Value("max_early_data"))
		if value < 0 {
			return refuse("max_early_data")
		}
		if value > 0 {
			transport["max_early_data"] = value
		}
	}
	if query.Has("early_data_header_name") {
		if value := query.Value("early_data_header_name"); value != "" {
			transport["early_data_header_name"] = value
		}
	}
	// Transport.exportToJson splits `?ed=` out of the ws path into the same
	// two fields; the importer must reproduce that normalization.
	if path, ok := transport["path"].(string); ok && strings.Contains(path, "?ed=") {
		parts := strings.Split(path, "?ed=")
		if len(parts) >= 2 {
			transport["path"] = parts[0]
			if value := profileImportQtInt(parts[1]); value > 0 {
				transport["max_early_data"] = value
			}
			transport["early_data_header_name"] = "Sec-WebSocket-Protocol"
		}
	}
	return transport, true, nil
}

// profileValidHTTPToken is Validation.httpToken restricted to ASCII tokens
// (the only forms a share link writes): non-empty visible ASCII minus delimiters.
func profileValidHTTPToken(text string) bool {
	if text == "" {
		return true
	}
	for _, r := range text {
		if r < 0x21 || r > 0x7e || strings.ContainsRune("()<>@,;:\\\"/[]?={} \t", r) {
			return false
		}
	}
	return true
}

func qtSectionFirstSkipEmpty(value string, separator rune) string {
	for _, part := range strings.Split(value, string(separator)) {
		if part != "" {
			return part
		}
	}
	return ""
}

// profileImportKCPTransport parses the Xray KCP link keys into the kernel's
// mkcp transport block (Transport.parseKcpLink + exportToJson).
func profileImportKCPTransport(query profileLinkQuery) (map[string]any, bool, error) {
	transport := map[string]any{"type": "mkcp"}
	for _, field := range []struct{ link, stored string }{
		{"mtu", "mtu"}, {"tti", "tti"},
		{"uplinkCapacity", "uplink_capacity"}, {"downlinkCapacity", "downlink_capacity"},
		{"readBufferSize", "read_buffer_size"}, {"writeBufferSize", "write_buffer_size"},
	} {
		if !query.Has(field.link) {
			continue
		}
		if value := profileImportQtInt(query.Value(field.link)); value > 0 {
			transport[field.stored] = value
		}
	}
	if query.Has("congestion") {
		switch strings.ToLower(strings.TrimSpace(query.Value("congestion"))) {
		case "1", "true", "yes":
			transport["congestion"] = true
		}
	}
	if query.Has("headerType") {
		if value := strings.TrimSpace(query.Value("headerType")); value != "" {
			transport["header_type"] = value
		}
	}
	if query.Has("seed") {
		if value := query.ValueFully("seed"); value != "" {
			transport["seed"] = value
		}
	}
	return transport, true, nil
}

// profileImportXHTTPTransport parses Transport.parseXhttpLink + parseXhttpExtra
// + exportToJson. The xhttp mode list and x_padding_bytes default are pinned to
// Transport.kt. The Xray `extra` object keeps every subfield Kotlin writes,
// including `xmux` (verbatim) and `headers` (as the stored headers object).
func profileImportXHTTPTransport(query profileLinkQuery) (map[string]any, bool, error) {
	transport := map[string]any{"type": "xhttp"}
	if query.Has("host") {
		transport["host"] = aceShareHost(query.ValueFully("host"))
	}
	if path := query.ValueFully("path"); path != "" {
		transport["path"] = path
	}
	if rawHeaders := query.ValueFully("headers"); rawHeaders != "" {
		if headers := profileHeaderPairs(rawHeaders); len(headers) > 0 {
			transport["headers"] = headers
		}
	}
	mode := strings.TrimSpace(query.Value("mode"))
	if query.Has("mode") && !profileXHTTPModeKnown(mode) {
		return nil, false, profileUnsupported("transport field not ported yet: mode=" + mode)
	}
	if mode != "" {
		transport["mode"] = mode
	}
	xPadding := strings.TrimSpace(query.Value("x_padding_bytes"))
	if raw := query.ValueFully("extra"); strings.TrimSpace(raw) != "" {
		var extra map[string]any
		if err := json.Unmarshal([]byte(raw), &extra); err != nil || len(extra) == 0 {
			// Kotlin warns and keeps the defaults; an unusable blob stores no
			// field, which matches the JVM oracle's exportToJson.
		} else {
			var err error
			xPadding, mode, err = profileXHTTPExtra(extra, transport, xPadding, mode)
			if err != nil {
				return nil, false, err
			}
		}
	}
	if xPadding == "" {
		xPadding = "100-1000"
	}
	// Transport.parseXhttpLink applies the explicit query key after `extra`:
	// an x_padding_bytes in the link wins over the one inside the blob.
	if query.Has("x_padding_bytes") {
		if value := strings.TrimSpace(query.Value("x_padding_bytes")); value != "" {
			xPadding = value
		}
	}
	transport["x_padding_bytes"] = xPadding
	if mode != "" {
		transport["mode"] = mode
	}
	return transport, true, nil
}

// profileHeaderPairs splits the link's `headers` value the way
// Transport.parseFromLink does: "|"-separated key/value pairs; an odd count
// clears the list (a warning, not a refusal).
func profileHeaderPairs(raw string) map[string]any {
	pairs := strings.Split(raw, "|")
	if len(pairs)%2 != 0 {
		return nil
	}
	headers := map[string]any{}
	for index := 0; index < len(pairs); index += 2 {
		headers[pairs[index]] = pairs[index+1]
	}
	return headers
}

func profileXHTTPModeKnown(mode string) bool {
	switch mode {
	case "", "auto", "packet-up", "stream-up", "stream-one":
		return true
	}
	return false
}

// profileXHTTPExtra applies the fields of Xray's xhttp `extra` object.
// `xmux` is kept verbatim (a raw object the core accepts, so every subfield
// round-trips); `headers` becomes the stored headers object exactly as
// JsonValues.objectToPairList/pairListToObject would write it.
func profileXHTTPExtra(extra map[string]any, transport map[string]any, xPadding, mode string) (string, string, error) {
	str := func(keys ...string) string {
		for _, key := range keys {
			if value, ok := extra[key].(string); ok {
				return value
			}
		}
		return ""
	}
	boolean := func(keys ...string) bool {
		for _, key := range keys {
			if value, ok := extra[key].(bool); ok && value {
				return true
			}
		}
		return false
	}
	if value := str("mode"); value != "" {
		mode = strings.TrimSpace(value)
	}
	if value := str("xPaddingBytes", "x_padding_bytes"); value != "" {
		xPadding = strings.TrimSpace(value)
	}
	for _, field := range []struct {
		keys   []string
		stored string
	}{
		{[]string{"noGRPCHeader", "no_grpc_header"}, "no_grpc_header"},
		{[]string{"noSSEHeader", "no_sse_header"}, "no_sse_header"},
		{[]string{"xPaddingObfsMode", "x_padding_obfs_mode"}, "x_padding_obfs_mode"},
	} {
		if boolean(field.keys...) {
			transport[field.stored] = true
		}
	}
	stringsList := []struct {
		keys   []string
		stored string
	}{
		{[]string{"scMaxEachPostBytes", "sc_max_each_post_bytes"}, "sc_max_each_post_bytes"},
		{[]string{"scMinPostsIntervalMs", "sc_min_posts_interval_ms"}, "sc_min_posts_interval_ms"},
		{[]string{"scStreamUpServerSecs", "sc_stream_up_server_secs"}, "sc_stream_up_server_secs"},
		{[]string{"xPaddingKey", "x_padding_key"}, "x_padding_key"},
		{[]string{"xPaddingHeader", "x_padding_header"}, "x_padding_header"},
		{[]string{"xPaddingPlacement", "x_padding_placement"}, "x_padding_placement"},
		{[]string{"xPaddingMethod", "x_padding_method"}, "x_padding_method"},
		{[]string{"uplinkHTTPMethod", "uplink_http_method"}, "uplink_http_method"},
		{[]string{"sessionIDPlacement", "session_placement"}, "session_placement"},
		{[]string{"sessionIDKey", "session_key"}, "session_key"},
		{[]string{"seqPlacement", "seq_placement"}, "seq_placement"},
		{[]string{"seqKey", "seq_key"}, "seq_key"},
		{[]string{"uplinkDataPlacement", "uplink_data_placement"}, "uplink_data_placement"},
		{[]string{"uplinkDataKey", "uplink_data_key"}, "uplink_data_key"},
		{[]string{"uplinkChunkSize", "uplink_chunk_size"}, "uplink_chunk_size"},
		{[]string{"sessionIDTable", "session_id_table"}, "session_id_table"},
		{[]string{"sessionIDLength", "session_id_length"}, "session_id_length"},
		{[]string{"congestionController", "congestion_controller"}, "congestion_controller"},
	}
	for _, field := range stringsList {
		if value := strings.TrimSpace(str(field.keys...)); value != "" {
			transport[field.stored] = value
		}
	}
	for _, field := range []struct {
		keys   []string
		stored string
	}{
		{[]string{"scMaxBufferedPosts", "sc_max_buffered_posts"}, "sc_max_buffered_posts"},
		{[]string{"cwnd"}, "cwnd"},
	} {
		for _, key := range field.keys {
			if value, ok := extra[key]; ok {
				if number := configJSONInt(value); number > 0 {
					transport[field.stored] = number
				}
				break
			}
		}
	}
	// xmux: Transport.parseXhttpExtra copies the raw object; exportToJson only
	// writes it back when it is not empty.
	if value, present := extra["xmux"]; present {
		if nested, ok := value.(map[string]any); ok && len(nested) > 0 {
			transport["xmux"] = nested
		}
	}
	// headers: only when the link itself carried none (Transport.kt guard).
	if value, present := extra["headers"]; present {
		if nested, ok := value.(map[string]any); ok && len(nested) > 0 {
			if existing, _ := transport["headers"].(map[string]any); len(existing) == 0 {
				headers := map[string]any{}
				for key, item := range nested {
					if text, ok := item.(string); ok {
						headers[key] = text
					} else {
						headers[key] = ""
					}
				}
				transport["headers"] = headers
			}
		}
	}
	return xPadding, mode, nil
}

// profileImportMultiplex mirrors Multiplex.parseFromLink + exportToJson:
// `mux` marks the state (unspecified when absent, off/on when present).
// Without `mux` the settings are dropped even when the mux_* keys are present,
// exactly as Kotlin does (exportToJson returns {}).
func profileImportMultiplex(query profileLinkQuery) (map[string]any, bool, error) {
	if !query.Has("mux") {
		return nil, false, nil
	}
	enabled := query.Value("mux") == "true"
	block := map[string]any{"enabled": enabled}
	if !enabled {
		return block, true, nil
	}
	if query.Has("mux_protocol") {
		protocol := strings.TrimSpace(query.Value("mux_protocol"))
		switch protocol {
		case "smux", "yamux", "h2mux":
			block["protocol"] = protocol
		default:
			return nil, false, profileUnsupported("mux_protocol=" + protocol)
		}
	}
	for _, field := range []struct{ key, stored string }{
		{"mux_max_connections", "max_connections"},
		{"mux_min_streams", "min_streams"},
		{"mux_max_streams", "max_streams"},
	} {
		if query.Has(field.key) {
			if value := profileImportQtInt(query.Value(field.key)); value > 0 {
				block[field.stored] = value
			}
		}
	}
	if profileTLSBool(query.Value("mux_padding")) {
		block["padding"] = true
	}
	if profileTLSBool(query.Value("brutal_enabled")) {
		brutal := map[string]any{"enabled": true}
		up := profileImportQtInt(query.Value("brutal_up_mbps"))
		if up <= 0 {
			up = 1
		}
		down := profileImportQtInt(query.Value("brutal_down_mbps"))
		if down <= 0 {
			down = 1
		}
		brutal["up_mbps"] = up
		brutal["down_mbps"] = down
		block["brutal"] = brutal
	}
	return block, true, nil
}

func singBoxTransportType(value string) string {
	text := strings.ToLower(strings.TrimSpace(value))
	switch text {
	case "websocket":
		return "ws"
	case "kcp":
		return "mkcp"
	default:
		return text
	}
}

// profileImportVMessV2RayN mirrors Vmess.parseV2RayN (Vmess.kt:106) for the
// subset of the V2RayN JSON schema the parity vector exercises. A link with
// fields outside that subset is refused rather than quietly defaulted.
func profileImportVMessV2RayN(payload string) (*profileStoredAdvanced, error) {
	var object map[string]any
	if err := json.Unmarshal([]byte(payload), &object); err != nil {
		return nil, profileUnsupported("vmess base64 body is not a JSON object")
	}
	allowed := map[string]bool{"v": true, "ps": true, "add": true, "port": true, "id": true,
		"aid": true, "net": true, "type": true, "host": true, "path": true, "tls": true,
		"sni": true, "alpn": true, "fp": true, "scy": true, "cs": true, "allowInsecure": true,
		"insecure": true, "throneExtra": true}
	for key := range object {
		if !allowed[key] {
			return nil, profileUnsupported("vmess V2RayN field not ported yet: " + key)
		}
	}
	uuid := configJSONString(object, "id")
	server := configJSONString(object, "add")
	if uuid == "" || server == "" || profileHasUnsupportedHostForm(server) {
		return nil, profileUnsupported("vmess V2RayN link lacks a valid uuid or address")
	}
	port := configJSONInt(object["port"])
	if port <= 0 {
		port = 443
	}
	node := &profileStoredAdvanced{
		Type:   "vmess",
		Name:   configJSONString(object, "ps"),
		Server: aceShareHost(server),
		Port:   port,
		Fields: map[string]any{"uuid": uuid, "packet_encoding": "xudp"},
	}
	security := strings.ToLower(strings.TrimSpace(configJSONString(object, "scy")))
	if security != "" && security != "auto" {
		if !vmessSecurityKnown(security) {
			return nil, profileUnsupported("vmess security not ported yet: " + security)
		}
		node.Fields["security"] = security
	}
	if aid := configJSONInt(object["aid"]); aid > 0 {
		node.Fields["alter_id"] = aid
	}
	net := singBoxTransportType(configJSONString(object, "net"))
	if net == "raw" {
		net = "tcp"
	}
	if net == "h2" || ((net == "" || net == "tcp") && configJSONString(object, "type") == "http") {
		net = "http"
	}
	transport := map[string]any{"type": net}
	if net != "" && net != "tcp" {
		if net == "grpc" {
			if serviceName := configJSONString(object, "path"); serviceName != "" {
				transport["service_name"] = serviceName
			}
		} else if path := configJSONString(object, "path"); path != "" {
			transport["path"] = path
		}
		if host := configJSONString(object, "host"); host != "" {
			if net == "ws" {
				transport["headers"] = map[string]any{"Host": aceShareHost(host)}
			} else {
				transport["host"] = aceShareHost(host)
			}
		}
		node.Transport, node.HasTr = transport, true
	}
	if strings.EqualFold(strings.TrimSpace(configJSONString(object, "tls")), "tls") {
		tls := map[string]any{"enabled": true}
		if serverName := configJSONString(object, "sni"); serverName != "" {
			tls["server_name"] = aceShareHost(serverName)
		}
		if alpn := configJSONString(object, "alpn"); alpn != "" {
			tls["alpn"] = stringList(alpn)
		}
		if fingerprint := configJSONString(object, "fp"); fingerprint != "" {
			normalized, ok := profileTLSFingerprint(fingerprint)
			if !ok {
				return nil, profileUnsupported("vmess V2RayN fp not ported yet: " + fingerprint)
			}
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": normalized}
		}
		insecure := configJSONString(object, "allowInsecure")
		if configJSONString(object, "insecure") == "1" || configJSONString(object, "insecure") == "true" {
			insecure = "1"
		}
		if insecure == "1" || insecure == "true" {
			tls["insecure"] = true
		}
		if cs := configJSONString(object, "cs"); cs != "" {
			return nil, profileUnsupported("vmess V2RayN cs is not ported yet")
		}
		node.TLS, node.HasTLS = tls, true
	}
	// throneExtra carries the TLS/transport/multiplex fields the V2RayN JSON
	// schema has no room for; Vmess.parseV2RayN re-parses it as a query and
	// feeds the same parsers.
	if extra := configJSONString(object, "throneExtra"); extra != "" {
		extraLink := profileParsedLink{Query: profileLinkParseQuery(extra)}
		if transport, hasTransport, err := profileImportTransport(extraLink, node.HasTLS); err != nil {
			return nil, err
		} else if hasTransport {
			node.Transport, node.HasTr = transport, true
		}
		if mux, hasMux, err := profileImportMultiplex(extraLink.Query); err != nil {
			return nil, err
		} else if hasMux {
			node.Multiplex, node.HasMux = mux, true
		}
		if extraLink.Query.Has("globalPadding") && extraLink.Query.Value("globalPadding") == "true" {
			node.Fields["global_padding"] = true
		}
		if extraLink.Query.Has("authenticatedLength") && extraLink.Query.Value("authenticatedLength") == "true" {
			node.Fields["authenticated_length"] = true
		}
		if value := extraLink.Query.Value("packetEncoding"); value != "" {
			if value != "xudp" && value != "none" && value != "packetaddr" {
				return nil, profileUnsupported("vmess V2RayN throneExtra packetEncoding not ported yet: " + value)
			}
			if value == "none" {
				node.Fields["packet_encoding"] = ""
			} else {
				node.Fields["packet_encoding"] = value
			}
		}
	}
	return node, nil
}

func vmessSecurityKnown(security string) bool {
	switch security {
	case "auto", "none", "zero", "aes-128-gcm", "chacha20-poly1305", "aes-128-cfb":
		return true
	}
	return false
}

// profileImportAdvanced dispatches a share link to one of the advanced types.
func profileImportAdvanced(scheme string, link profileParsedLink, raw string) (*profileImportedNode, error) {
	switch scheme {
	case "vmess":
		return profileImportVMess(link, raw)
	case "vless":
		return profileImportVLESS(link)
	case "trojan":
		return profileImportTrojan(link)
	case "hysteria", "hysteria2", "hy2":
		return profileImportHysteria(scheme, link)
	}
	return nil, profileUnsupported("scheme not handled by the advanced importer: " + scheme)
}

func profileImportVMess(link profileParsedLink, raw string) (*profileImportedNode, error) {
	// Vmess.kt:81: the V2RayN base64 JSON form is tried before the URL form.
	payload := raw
	if index := strings.Index(payload, "vmess://"); index >= 0 {
		payload = payload[index+len("vmess://"):]
	}
	if hash := strings.IndexByte(payload, '#'); hash >= 0 {
		payload = payload[:hash]
	}
	if decoded, ok := profileBase64Decode(payload, false); ok && len(decoded) > 0 {
		if node, err := profileImportVMessV2RayN(string(decoded)); err == nil {
			return profileAdvancedNode(node)
		} else if refused, ok := err.(profileImportUnsupported); ok && strings.Contains(refused.Reason, "vmess V2RayN field not ported yet") {
			return nil, err
		}
		// A non-JSON base64 body falls through to the URL form, as Kotlin does.
	}
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed vmess link")
	}
	node := &profileStoredAdvanced{
		Type:   "vmess",
		Name:   link.Fragment,
		Server: link.Host,
		Port:   link.PortOrDefault(443),
		Fields: map[string]any{"uuid": link.UserName, "packet_encoding": "xudp"},
	}
	if security := link.Query.Value("encryption"); security != "" {
		lower := strings.ToLower(strings.TrimSpace(security))
		if !vmessSecurityKnown(lower) {
			return nil, profileUnsupported("vmess security not ported yet: " + security)
		}
		if lower != "auto" {
			node.Fields["security"] = lower
		}
	}
	if link.Query.Has("alterId") {
		if alterID := profileImportQtInt(link.Query.Value("alterId")); alterID > 0 {
			node.Fields["alter_id"] = alterID
		}
	}
	if link.Query.Has("globalPadding") && link.Query.Value("globalPadding") == "true" {
		node.Fields["global_padding"] = true
	}
	if link.Query.Has("authenticatedLength") && link.Query.Value("authenticatedLength") == "true" {
		node.Fields["authenticated_length"] = true
	}
	if value := link.Query.Value("packetEncoding"); value != "" {
		trimmed := strings.TrimSpace(value)
		if trimmed != "xudp" && trimmed != "none" && trimmed != "packetaddr" && trimmed != "" {
			return nil, profileUnsupported("vmess packetEncoding not ported yet: " + value)
		}
		if trimmed == "none" {
			node.Fields["packet_encoding"] = ""
		} else if trimmed != "" {
			node.Fields["packet_encoding"] = trimmed
		}
	}
	if link.Query.Has("throneExtra") {
		return nil, profileUnsupported("vmess field not ported yet: throneExtra")
	}
	if link.Query.Has("pinSHA256") {
		return nil, profileUnsupported("vmess field not ported yet: pinSHA256")
	}
	tls, hasTLS, err := profileImportTLS(link, false, true)
	if err != nil {
		return nil, err
	}
	node.TLS, node.HasTLS = tls, hasTLS
	transport, hasTransport, err := profileImportTransport(link, hasTLS)
	if err != nil {
		return nil, err
	}
	node.Transport, node.HasTr = transport, hasTransport
	mux, hasMux, err := profileImportMultiplex(link.Query)
	if err != nil {
		return nil, err
	}
	node.Multiplex, node.HasMux = mux, hasMux
	return profileAdvancedNode(node)
}

func profileImportQtInt(value string) int {
	text := strings.TrimSpace(value)
	if text == "" {
		return 0
	}
	number, err := strconv.Atoi(text)
	if err != nil {
		return 0
	}
	return number
}

func profileImportVLESS(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed vless link")
	}
	if link.Query.Has("throneExtra") {
		return nil, profileUnsupported("vless field not ported yet: throneExtra")
	}
	if link.Query.Has("pinSHA256") {
		return nil, profileUnsupported("vless field not ported yet: pinSHA256")
	}
	encryption := strings.TrimSpace(link.Query.Value("encryption"))
	if encryption == "" || strings.EqualFold(encryption, "none") {
		encryption = "none"
	}
	packetEncoding := "xudp"
	if value := link.Query.Value("packetEncoding"); value != "" {
		trimmed := strings.TrimSpace(value)
		if trimmed != "xudp" && trimmed != "none" && trimmed != "packetaddr" && trimmed != "" {
			return nil, profileUnsupported("vless packetEncoding not ported yet: " + value)
		}
		if trimmed == "none" {
			packetEncoding = ""
		} else if trimmed != "" {
			packetEncoding = trimmed
		}
	}
	fields := map[string]any{"encryption": encryption, "packet_encoding": packetEncoding}
	if uuid := link.UserName; uuid != "" {
		fields["uuid"] = uuid
	}
	if flow := strings.TrimSpace(link.Query.Value("flow")); flow != "" {
		if flow != "xtls-rprx-vision" && flow != "xtls-rprx-vision-udp443" {
			return nil, profileUnsupported("vless flow not ported yet: " + flow)
		}
		fields["flow"] = flow
	}
	tls, hasTLS, err := profileImportTLS(link, false, true)
	if err != nil {
		return nil, err
	}
	transport, hasTransport, err := profileImportTransport(link, hasTLS)
	if err != nil {
		return nil, err
	}
	// VLESS flow is valid only on TLS/no transport. Kotlin drops an invalid
	// flow with a warning; refusing keeps a partial node out of the store.
	if _, hasFlow := fields["flow"]; hasFlow && (!hasTLS || hasTransport && transport["type"] != "tcp") {
		return nil, profileUnsupported("vless flow requires TLS without a transport")
	}
	mux, hasMux, err := profileImportMultiplex(link.Query)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "vless", Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(443), Fields: fields,
		TLS: tls, HasTLS: hasTLS, Transport: transport, HasTr: hasTransport,
		Multiplex: mux, HasMux: hasMux,
	}
	return profileAdvancedNode(node)
}

func profileImportTrojan(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed trojan link")
	}
	if link.Query.Has("pinSHA256") {
		return nil, profileUnsupported("trojan field not ported yet: pinSHA256")
	}
	fields := map[string]any{}
	if password := link.UserName; password != "" {
		fields["password"] = password
	}
	tls, hasTLS, err := profileImportTLS(link, true, true)
	if err != nil {
		return nil, err
	}
	transport, hasTransport, err := profileImportTransport(link, hasTLS)
	if err != nil {
		return nil, err
	}
	mux, hasMux, err := profileImportMultiplex(link.Query)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "trojan", Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(443), Fields: fields,
		TLS: tls, HasTLS: hasTLS, Transport: transport, HasTr: hasTransport,
		Multiplex: mux, HasMux: hasMux,
	}
	return profileAdvancedNode(node)
}

func profileImportHysteria(scheme string, link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() && !link.InvalidPortOnly() || link.Host == "" {
		return nil, profileUnsupported("malformed hysteria link")
	}
	fields := map[string]any{}
	outboundType := "hysteria2"
	if scheme == "hysteria" {
		outboundType = "hysteria"
		// v1 rejects any `protocol` other than udp (Kotlin rejectTransport).
		if protocol := strings.TrimSpace(link.Query.Value("protocol")); protocol != "" && !strings.EqualFold(protocol, "udp") {
			return nil, profileUnsupported("hysteria field not ported yet: protocol=" + protocol)
		}
		if auth := link.Query.Value("auth"); auth != "" {
			fields["auth_str"] = auth
		}
		if obfs := link.Query.ValueFully("obfsParam"); obfs != "" {
			fields["obfs"] = obfs
		}
		if value := link.Query.Value("recv_window_conn"); value != "" {
			if window := profileImportQtInt(value); window > 0 {
				fields["recv_window_conn"] = window
			}
		}
		if value := link.Query.Value("recv_window"); value != "" {
			if window := profileImportQtInt(value); window > 0 {
				fields["recv_window"] = window
			}
		}
		if profileTLSBool(link.Query.Value("disable_mtu_discovery")) {
			fields["disable_mtu_discovery"] = true
		}
	} else {
		password := link.UserName
		if link.Password != "" {
			password += ":" + link.Password
		}
		if password != "" {
			fields["password"] = password
		}
		obfsType := strings.ToLower(strings.TrimSpace(link.Query.ValueOr("obfs", "salamander")))
		if link.Query.Has("min_packet_size") || link.Query.Has("max_packet_size") {
			obfsType = "gecko"
		}
		minSize := 0
		maxSize := 0
		if value := link.Query.Value("min_packet_size"); value != "" {
			minSize = profileImportQtInt(value)
		}
		if value := link.Query.Value("max_packet_size"); value != "" {
			maxSize = profileImportQtInt(value)
		}
		if obfs := link.Query.ValueFully("obfs-password"); obfs != "" {
			fields["obfs"] = map[string]any{
				"type":            obfsType,
				"password":        obfs,
				"min_packet_size": minSize,
				"max_packet_size": maxSize,
			}
		}
		for _, field := range []struct{ key, stored string }{
			{"hop_interval_max", "hop_interval_max"}, {"bbr_profile", "bbr_profile"},
		} {
			if !link.Query.Has(field.key) {
				continue
			}
			value := profileHopDuration(strings.TrimSpace(link.Query.Value(field.key)))
			if field.key == "bbr_profile" {
				switch value {
				case "standard", "conservative", "aggressive":
					fields[field.stored] = value
				default:
					return nil, profileUnsupported("hysteria2 field not ported yet: bbr_profile=" + value)
				}
			} else if profileValidDuration(value) {
				fields[field.stored] = value
			} else {
				return nil, profileUnsupported("hysteria2 field not ported yet: " + field.key + "=" + value)
			}
		}
		if profileTLSBool(link.Query.Value("disable_chrome_parrot")) {
			fields["disable_chrome_parrot"] = true
		}
	}
	if up := profileImportBandwidth(link.Query.ValueFully("upmbps")); up > 0 {
		fields["up_mbps"] = up
	}
	if down := profileImportBandwidth(link.Query.ValueFully("downmbps")); down > 0 {
		fields["down_mbps"] = down
	}
	if link.Query.Has("hop_interval") {
		value := profileHopDuration(strings.TrimSpace(link.Query.Value("hop_interval")))
		if !profileValidDuration(value) {
			return nil, profileUnsupported("hysteria field not ported yet: hop_interval=" + value)
		}
		fields["hop_interval"] = value
	}
	if link.Query.Has("mport") {
		ports := profilePortsToPorts(qtSplitSkipEmpty(link.Query.ValueFully("mport"), ","))
		anyPorts := make([]any, 0, len(ports))
		for _, value := range ports {
			anyPorts = append(anyPorts, value)
		}
		fields["server_ports"] = anyPorts
	}
	tls, _, err := profileImportTLS(link, true, false)
	if err != nil {
		return nil, err
	}
	// pinSHA256 is TLS.certificate_sha256 in the stored form; the Hysteria
	// link key pins a hex/base64 SHA-256, converted exactly as parsePinSha256.
	if link.Query.Has("pinSHA256") {
		pins, err := profileHysteriaPins(link.Query.ValueFully("pinSHA256"))
		if err != nil {
			return nil, err
		}
		existing, _ := tls["certificate_sha256"].([]any)
		for _, pin := range pins {
			duplicate := false
			for _, value := range existing {
				if value == pin {
					duplicate = true
					break
				}
			}
			if !duplicate {
				existing = append(existing, pin)
			}
		}
		tls["certificate_sha256"] = existing
	}
	// QuicFields.parseFromLink writes flat keys into the Hysteria stored form
	// (Kotlin merges quic.exportToJson() into the outbound object).
	if err := profileImportQuicFields(link.Query, fields); err != nil {
		return nil, err
	}
	port := link.PortOrDefault(443)
	if port == 0 && len(qtSplitSkipEmpty(link.Query.ValueFully("mport"), ",")) == 0 {
		port = 443
	}
	node := &profileStoredAdvanced{
		Type: outboundType, Name: link.Fragment, Server: link.Host,
		Port: port, Fields: fields,
		TLS: tls, AlwaysTLS: true,
	}
	return profileAdvancedNode(node)
}

func profileHopDuration(value string) string {
	if value != "" && strings.Trim(value, "0123456789") == "" {
		return value + "s"
	}
	return value
}

func profilePortsToPorts(ports []string) []string {
	out := make([]string, 0, len(ports))
	for _, raw := range ports {
		value := strings.TrimSpace(raw)
		if value == "" {
			continue
		}
		parts := profilePortRangeParts(value)
		if len(parts) == 2 {
			out = append(out, parts[0]+":"+parts[1])
		} else {
			out = append(out, value+":"+value)
		}
	}
	return out
}

// profilePortRangeParts is Hysteria.portsToPorts' Regex("[:-]").split: split
// on the separator family present, with Java's trailing-empty trimming.
func profilePortRangeParts(value string) []string {
	var parts []string
	switch {
	case strings.Contains(value, ":"):
		parts = strings.Split(value, ":")
	case strings.Contains(value, "-"):
		parts = strings.Split(value, "-")
	default:
		return nil
	}
	for len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	return parts
}

// profileHysteriaPins mirrors Hysteria.parsePinSha256: comma-separated hex
// (colons/dashes stripped) or base64 values, deduplicated in order.
func profileHysteriaPins(text string) ([]any, error) {
	var out []any
	for _, raw := range qtSplitSkipEmpty(text, ",") {
		pin := strings.TrimSpace(raw)
		if hash, ok := profileHexSHA256B64(pin); ok {
			out = append(out, hash)
			continue
		}
		clean := strings.TrimSpace(strings.ReplaceAll(strings.ReplaceAll(pin, ":", ""), "-", ""))
		if hash, ok := profileHexSHA256B64(clean); ok {
			out = append(out, hash)
			continue
		}
		urlSafe := strings.ContainsAny(pin, "-_")
		if decoded, ok := profileBase64Decode(pin, urlSafe); ok && len(decoded) == 32 {
			out = append(out, profileBase64Encode(decoded, false, true))
			continue
		}
		return nil, profileUnsupported("hysteria field not ported yet: pinSHA256=" + pin)
	}
	return out, nil
}

// profileImportQuicFields mirrors QuicFields.parseFromLink + exportToJson,
// writing flat keys into the Hysteria stored object.
func profileImportQuicFields(query profileLinkQuery, fields map[string]any) error {
	for _, field := range []struct{ link, stored string }{
		{"quic_idle_timeout", "idle_timeout"}, {"quic_keep_alive_period", "keep_alive_period"},
	} {
		if !query.Has(field.link) {
			continue
		}
		value := strings.TrimSpace(query.Value(field.link))
		if !profileValidDuration(value) {
			return profileUnsupported("hysteria field not ported yet: " + field.link + "=" + value)
		}
		fields[field.stored] = value
	}
	for _, field := range []struct{ link, stored string }{
		{"quic_stream_receive_window", "stream_receive_window"},
		{"quic_connection_receive_window", "connection_receive_window"},
	} {
		if !query.Has(field.link) {
			continue
		}
		value := strings.TrimSpace(query.Value(field.link))
		if !profileValidMemoryBytes(value) {
			return profileUnsupported("hysteria field not ported yet: " + field.link + "=" + value)
		}
		fields[field.stored] = value
	}
	if query.Has("quic_max_concurrent_streams") {
		if value := profileImportQtInt(query.Value("quic_max_concurrent_streams")); value > 0 {
			fields["max_concurrent_streams"] = value
		}
	}
	if query.Has("quic_initial_packet_size") {
		value := profileImportQtInt(query.Value("quic_initial_packet_size"))
		if value != 0 && (value < 1200 || value > 1452) {
			return profileUnsupported("hysteria field not ported yet: quic_initial_packet_size=" + query.Value("quic_initial_packet_size"))
		}
		if value > 0 {
			fields["initial_packet_size"] = value
		}
	}
	if query.Has("quic_disable_path_mtu_discovery") {
		fields["disable_path_mtu_discovery"] = query.Value("quic_disable_path_mtu_discovery") == "true"
	}
	return nil
}

// profileImportBandwidth is Hysteria.clashBandwidthToMbps for the common
// bare-number and <n>Mbps forms; 0 means Kotlin would drop the field.
func profileImportBandwidth(text string) int {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return 0
	}
	lower := strings.ToLower(trimmed)
	for _, suffix := range []string{"mbps", "mbit", "mb", "m"} {
		if strings.HasSuffix(lower, suffix) {
			trimmed = strings.TrimSpace(trimmed[:len(trimmed)-len(suffix)])
			break
		}
	}
	value, err := strconv.ParseFloat(trimmed, 64)
	if err != nil || value <= 0 {
		return 0
	}
	return int(value + 0.5)
}
