// S5c, second half: the TLS/transport-bearing share links (vmess, vless,
// trojan, hysteria/hysteria2/hy2).
//
// Oracle: the Kotlin parsers and their exportToJson writers —
// app/src/main/java/io/nekohasekai/sagernet/outbound/types/{Vmess,Vless,Trojan,Hysteria}.kt,
// outbound/common/{Tls,Transport,Multiplex,QuicFields}.kt. The JVM test
// ProfileStoredGoParityTest pins the exact bytes this file has to emit for
// every vector the Go tests claim.
//
// Refusal contract: this file implements only the field surface its tests
// pin. Any link carrying a field whose Kotlin normalization has not been
// ported here — advanced TLS (certificates, pins, fragment, spoof, ECH config,
// ML-DSA-65), XHTTP/mKCP transports, V2RayN throneExtra, port hopping, etc. —
// is answered supported:false with a reason. No partially normalized node is
// ever produced.
package mobile

import (
	"encoding/json"
	"strconv"
	"strings"
)

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
	if node.Name != "" {
		object["tag"] = node.Name
	}
	if node.Server != "" {
		object["server"] = node.Server
	}
	if node.Port > 0 {
		object["server_port"] = node.Port
	}
	for key, value := range node.Fields {
		object[key] = value
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
	if node.Server != "" {
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
	object := map[string]any{
		"server":      node.Server,
		"server_port": node.Port,
	}
	if node.HasTLS || node.AlwaysTLS {
		tls := node.TLS
		if tls != nil {
			enabled, _ := tls["enabled"].(bool)
			if enabled {
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
				object["tls"] = identity
			}
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

// profileAdvancedLink emits the type's canonical share link from the stored
// form. It is the inverse of the parsers below, using the same helpers the
// simple exporter uses. Links are reconstructed from the parsed fields rather
// than echoing the input: a Kotlin re-export would do the same.
func profileAdvancedLink(node *profileStoredAdvanced) (string, error) {
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
	}
	return builder.build(), nil
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

// profileImportTLS parses Tls.parseFromLink (Tls.kt:780) restricted to the
// fields the parity vectors pin: security/sni/peer/allowInsecure/alpn/fp/pbk/
// sid. Every other TLS query key is a refusal so nothing is silently dropped.
func profileImportTLS(link profileParsedLink, requireTLS bool) (map[string]any, bool, error) {
	query := link.Query
	refuse := func(key string) (map[string]any, bool, error) {
		return nil, false, profileUnsupported("unsupported TLS field: " + key)
	}
	for _, key := range []string{"disable_sni", "tls_min_version", "tls_max_version", "tls_cipher_suites",
		"cs", "tls_curve_preferences", "tls_certificate", "tls_certificate_path", "pcs",
		"tls_certificate_public_key_sha256", "tls_client_certificate", "tls_client_certificate_path",
		"tls_client_key", "tls_client_key_path", "tls_fragment", "tls_fragment_fallback_delay",
		"tls_record_fragment", "tls_spoof", "tls_spoof_method", "tls_spoof_enabled", "tls_tricks",
		"ech", "ech_enabled", "ech_config", "ech_config_path", "ech_server_name", "pqv", "pinSHA256"} {
		if query.Has(key) {
			return refuse(key)
		}
	}
	security := strings.ToLower(strings.TrimSpace(query.Value("security")))
	enabled := requireTLS
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
	tls := map[string]any{}
	if !enabled {
		return tls, false, nil
	}
	tls["enabled"] = true
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
	if query.Has("fp") {
		fingerprint := strings.TrimSpace(query.Value("fp"))
		if !validFingerprint(fingerprint) {
			return refuse("fp=" + fingerprint)
		}
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fingerprint}
	}
	if query.Has("pbk") {
		publicKey := strings.TrimSpace(query.Value("pbk"))
		if strings.HasSuffix(publicKey, "=") {
			// Kotlin's importRealityPublicKey drops trailing '=' when the
			// unpadded key is a valid 32-byte base64url value.
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
		tls["reality"] = reality
	}
	return tls, true, nil
}

func profileTLSBool(value string) bool {
	return strings.ReplaceAll(value, "1", "true") == "true"
}

func validFingerprint(fingerprint string) bool {
	switch fingerprint {
	case "", "chrome", "chrome_psk", "chrome_psk_shuffle", "chrome_padding_psk_shuffle",
		"chrome_pq", "chrome_pq_psk", "firefox", "edge", "safari", "360", "qq", "ios",
		"android", "random", "randomized", "custom", "unsafe":
		return true
	}
	return false
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

// profileImportTransport parses Transport.parseFromLink (Transport.kt:170)
// restricted to ws/http/grpc/h2 (the forms the parity vectors pin), with the
// ws Host header rule from exportToJson (Transport.kt:633).
func profileImportTransport(link profileParsedLink, tlsEnabled bool) (map[string]any, bool, error) {
	query := link.Query
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
		// A plain TCP dial writes no transport block.
		if query.Has("host") || query.Has("path") || query.Has("headers") ||
			query.Has("serviceName") || query.Has("idle_timeout") || query.Has("ping_timeout") ||
			query.Has("early_data_header_name") || query.Has("max_early_data") {
			return nil, false, profileUnsupported("transport fields on a plain TCP link")
		}
		return nil, false, nil
	}
	switch kind {
	case "ws", "http", "httpupgrade", "grpc":
	default:
		return nil, false, profileUnsupported("transport type not ported yet: " + kind)
	}
	for _, key := range []string{"method", "idle_timeout", "ping_timeout", "max_early_data",
		"early_data_header_name", "extra", "mode", "x_padding_bytes", "mux", "mux_protocol",
		"mux_max_connections", "mux_min_streams", "mux_max_streams", "mux_padding",
		"brutal_enabled", "brutal_up_mbps", "brutal_down_mbps"} {
		if query.Has(key) {
			return nil, false, profileUnsupported("transport field not ported yet: " + key)
		}
	}
	transport := map[string]any{"type": kind}
	path := query.ValueFully("path")
	if kind == "grpc" {
		if query.Has("serviceName") {
			transport["service_name"] = query.ValueFully("serviceName")
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
		if kind == "ws" {
			headers, _ := transport["headers"].(map[string]any)
			if headers == nil {
				headers = map[string]any{}
			}
			headers["Host"] = aceShareHost(host)
			transport["headers"] = headers
		} else {
			transport["host"] = aceShareHost(host)
		}
	}
	return transport, true, nil
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
		"sni": true, "alpn": true, "fp": true, "scy": true, "cs": true, "allowInsecure": true}
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
			if !validFingerprint(fingerprint) {
				return nil, profileUnsupported("vmess V2RayN fp not ported yet: " + fingerprint)
			}
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": fingerprint}
		}
		if insecure := configJSONString(object, "allowInsecure"); insecure == "1" || insecure == "true" {
			tls["insecure"] = true
		}
		if cs := configJSONString(object, "cs"); cs != "" {
			return nil, profileUnsupported("vmess V2RayN cs is not ported yet")
		}
		node.TLS, node.HasTLS = tls, true
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
	for _, key := range []string{"throneExtra", "mux", "mux_protocol", "mux_max_connections", "mux_min_streams",
		"mux_max_streams", "mux_padding", "brutal_enabled", "brutal_up_mbps", "brutal_down_mbps"} {
		if link.Query.Has(key) {
			return nil, profileUnsupported("vmess field not ported yet: " + key)
		}
	}
	tls, hasTLS, err := profileImportTLS(link, false)
	if err != nil {
		return nil, err
	}
	node.TLS, node.HasTLS = tls, hasTLS
	transport, hasTransport, err := profileImportTransport(link, hasTLS)
	if err != nil {
		return nil, err
	}
	node.Transport, node.HasTr = transport, hasTransport
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
	for _, key := range []string{"throneExtra", "packetEncoding", "mux", "mux_protocol", "mux_max_connections",
		"mux_min_streams", "mux_max_streams", "mux_padding", "brutal_enabled", "brutal_up_mbps", "brutal_down_mbps"} {
		if key == "packetEncoding" {
			continue // handled below
		}
		if link.Query.Has(key) {
			return nil, profileUnsupported("vless field not ported yet: " + key)
		}
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
	tls, hasTLS, err := profileImportTLS(link, false)
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
	node := &profileStoredAdvanced{
		Type: "vless", Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(443), Fields: fields,
		TLS: tls, HasTLS: hasTLS, Transport: transport, HasTr: hasTransport,
	}
	return profileAdvancedNode(node)
}

func profileImportTrojan(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed trojan link")
	}
	for _, key := range []string{"mux", "mux_protocol", "mux_max_connections", "mux_min_streams", "mux_max_streams",
		"mux_padding", "brutal_enabled", "brutal_up_mbps", "brutal_down_mbps"} {
		if link.Query.Has(key) {
			return nil, profileUnsupported("trojan field not ported yet: " + key)
		}
	}
	fields := map[string]any{}
	if password := link.UserName; password != "" {
		fields["password"] = password
	}
	tls, hasTLS, err := profileImportTLS(link, true)
	if err != nil {
		return nil, err
	}
	transport, hasTransport, err := profileImportTransport(link, hasTLS)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "trojan", Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(443), Fields: fields,
		TLS: tls, HasTLS: hasTLS, Transport: transport, HasTr: hasTransport,
	}
	return profileAdvancedNode(node)
}

func profileImportHysteria(scheme string, link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed hysteria link")
	}
	// QUIC fields, pinning and port hopping are not ported; the per-version
	// gates below refuse them before any field is read.
	fields := map[string]any{}
	outboundType := "hysteria2"
	if scheme == "hysteria" {
		outboundType = "hysteria"
		for _, key := range []string{"quic_idle_timeout", "quic_keep_alive_period", "quic_stream_receive_window",
			"quic_connection_receive_window", "quic_max_concurrent_streams", "quic_initial_packet_size",
			"quic_disable_path_mtu_discovery", "pinSHA256", "mport", "hop_interval", "hop_interval_max",
			"bbr_profile", "disable_chrome_parrot", "min_packet_size", "max_packet_size",
			"protocol", "disable_mtu_discovery"} {
			if link.Query.Has(key) {
				return nil, profileUnsupported("hysteria field not ported yet: " + key)
			}
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
	} else {
		for _, key := range []string{"quic_idle_timeout", "quic_keep_alive_period", "quic_stream_receive_window",
			"quic_connection_receive_window", "quic_max_concurrent_streams", "quic_initial_packet_size",
			"quic_disable_path_mtu_discovery", "pinSHA256", "mport", "hop_interval", "hop_interval_max",
			"bbr_profile", "disable_chrome_parrot"} {
			if link.Query.Has(key) {
				return nil, profileUnsupported("hysteria2 field not ported yet: " + key)
			}
		}
		password := link.UserName
		if link.Password != "" {
			password += ":" + link.Password
		}
		if password != "" {
			fields["password"] = password
		}
		obfsType := strings.ToLower(strings.TrimSpace(link.Query.ValueOr("obfs", "salamander")))
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
	}
	if up := profileImportBandwidth(link.Query.ValueFully("upmbps")); up > 0 {
		fields["up_mbps"] = up
	}
	if down := profileImportBandwidth(link.Query.ValueFully("downmbps")); down > 0 {
		fields["down_mbps"] = down
	}
	tls, _, err := profileImportTLS(link, true)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: outboundType, Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(443), Fields: fields,
		TLS: tls, AlwaysTLS: true,
	}
	return profileAdvancedNode(node)
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
