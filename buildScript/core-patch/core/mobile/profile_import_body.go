// S5d: subscription-body import for the profileImport action.
//
// The single-link path stays authoritative for every node: a body is split,
// decoded or decoded-JSON-expanded into share links / stored outbounds, each
// entry goes through the same converters, and the reply is all-or-nothing. If
// any entry is unsupported or malformed the whole body is refused with no
// nodes, so a partially normalized subscription can never reach the document
// store.
//
// Accepted bodies (detected in this order):
//
//  1. One supported share link (the existing single-link contract).
//  2. Multi-line plain text: trimmed lines, blank / `#` / `//` comments and
//     `happ://routing/...` (or any `<scheme>://routing/...`) routing links are
//     skipped; every remaining line is imported in order.
//  3. Base64 text: standard, URL-safe or MIME-wrapped (whitespace anywhere in
//     the encoded text). Strict decode first, lenient decode second; both
//     alphabets are tried. The decoded bytes must themselves be a body (usually
//     multi-line text), are capped at 64 MiB and are never accepted on a
//     partial decode.
//  4. JSON: a single sing-box outbound object, an array of outbounds, or a
//     SIP008 `{"servers":[...]}` document. Entries are converted to the same
//     stored form the link converters emit.
//
// Clash YAML bodies are converted by `profileImportClashBody` (the S5d Clash
// importer); one hook below calls it with the same all-or-nothing contract as
// every other body path.
package mobile

import (
	"encoding/json"
	"fmt"
	"strings"
)

// profileBodyMaxDecoded caps the decoded size of a base64 subscription body.
// 64 MiB matches the subscription transport's decoded-body ceiling; anything
// larger is refused before the decoded bytes are treated as text.
const profileBodyMaxDecoded = 64 << 20

// profileImportBody is the body entry point used by the action. It first tries
// the single-link fast path (unchanged), then the multi-line / base64 / JSON
// body paths. Single-line text that is not a link is rejected by the link
// parser, never silently reinterpreted as a body.
func profileImportBody(text string) ([]profileImportedNode, error) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return nil, profileUnsupported("empty text: expected a share link or subscription body")
	}

	// A single link keeps the exact single-link behaviour and reply.
	if !strings.ContainsAny(trimmed, "\r\n") && profileBodyIsLink(trimmed) {
		node, err := profileImportOneLink(trimmed)
		if err != nil {
			return nil, err
		}
		return []profileImportedNode{*node}, nil
	}

	// JSON bodies are detected before base64 (base64 of JSON is handled by the
	// base64 path, which recurses back here).
	if looksLikeJSONBody(trimmed) {
		return profileImportJSONBody(trimmed)
	}

	// Clash YAML is detected here but not converted in this slice. When the
	// other agent's converter lands, `profileImportClashBody` is defined and
	// this hook calls it; until then the declared hook below returns a clear
	// refusal. No call site changes when the converter is wired.
	if looksLikeClashBody(trimmed) {
		return profileImportClashBody(trimmed)
	}

	if looksLikeBase64Body(trimmed) {
		return profileImportBase64Body(trimmed)
	}

	if strings.ContainsAny(trimmed, "\r\n") {
		return profileImportMultilineBody(trimmed)
	}

	// A single unrecognized line is handed to the single-link parser so the
	// refusal reason stays identical to the one-link contract.
	_, err := profileImportOneLink(trimmed)
	if err != nil {
		return nil, err
	}
	return nil, profileUnsupported("unrecognized subscription body")
}

// profileBodyIsLink is a cheap pre-check: it only routes obvious share links
// to the single-link parser. Anything else is decided by the body paths.
func profileBodyIsLink(line string) bool {
	scheme, _, ok := strings.Cut(line, "://")
	if !ok || scheme == "" {
		return false
	}
	lower := strings.ToLower(scheme)
	switch lower {
	case "http", "https", "socks", "socks5", "socks4", "socks4a", "ss",
		"vmess", "vless", "trojan", "hysteria", "hysteria2", "hy2",
		"tuic", "anytls", "mieru", "mierus", "snell", "shadowtls":
		return true
	}
	return false
}

// profileImportMultilineBody imports every meaningful line in order. A single
// refusal discards the whole accumulated result.
func profileImportMultilineBody(text string) ([]profileImportedNode, error) {
	lines := strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n")
	meaningful := make([]string, 0, len(lines))
	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" || profileBodyIsComment(line) || profileBodyIsRoutingLink(line) {
			continue
		}
		meaningful = append(meaningful, line)
	}
	// A MIME-wrapped base64 body is several lines of base64 alphabet with no
	// share links: detect it before treating the input as plain-text links.
	if len(meaningful) > 1 && looksLikeBase64Body(strings.Join(meaningful, "")) {
		return profileImportBase64Body(strings.Join(meaningful, ""))
	}
	nodes := make([]profileImportedNode, 0, len(meaningful))
	for _, line := range meaningful {
		if profileBodyIsLink(line) {
			node, err := profileImportOneLink(line)
			if err != nil {
				return nil, err
			}
			nodes = append(nodes, *node)
			continue
		}
		// A nested body is not expected inside a multi-line subscription, but
		// if one appears (e.g. a base64 line among links) it is parsed with the
		// same rules and its nodes appended in order.
		more, err := profileImportBody(line)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, more...)
	}
	if len(nodes) == 0 {
		return nil, profileUnsupported("subscription body has no supported nodes")
	}
	return profileBodyDedup(nodes), nil
}

func profileBodyIsComment(line string) bool {
	return strings.HasPrefix(line, "#") || strings.HasPrefix(line, "//")
}

// profileBodyIsRoutingLink matches `happ://routing/...` and any other
// `<scheme>://routing/...` line. Routing metadata is not an outbound.
func profileBodyIsRoutingLink(line string) bool {
	scheme, rest, ok := strings.Cut(line, "://")
	if !ok || scheme == "" {
		return false
	}
	for _, char := range scheme {
		if !((char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '+' || char == '-' || char == '.') {
			return false
		}
	}
	return strings.HasPrefix(strings.ToLower(rest), "routing/")
}

// profileBodyDedup keeps the first node for each dedupKey, preserving order.
func profileBodyDedup(nodes []profileImportedNode) []profileImportedNode {
	seen := make(map[string]bool, len(nodes))
	out := make([]profileImportedNode, 0, len(nodes))
	for _, node := range nodes {
		if seen[node.DedupKey] {
			continue
		}
		seen[node.DedupKey] = true
		out = append(out, node)
	}
	return out
}

// looksLikeBase64Body accepts the shapes a base64 subscription can take:
// a single run of base64 alphabet characters (with optional padding) or a
// MIME-wrapped run with whitespace between chunks. It deliberately excludes
// share links and JSON so those keep their own paths.
func looksLikeBase64Body(text string) bool {
	canonical := profileBase64Canonical(text)
	if len(canonical) < 4 || len(canonical) > profileBodyMaxDecoded*2 {
		return false
	}
	for index := 0; index < len(canonical); index++ {
		char := canonical[index]
		digit := (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') ||
			(char >= '0' && char <= '9') || char == '+' || char == '/' ||
			char == '-' || char == '_' || char == '='
		if !digit {
			return false
		}
	}
	return true
}

// profileBase64Canonical drops MIME whitespace before decoding. A body made
// only of base64 alphabet characters is unchanged.
func profileBase64Canonical(text string) string {
	var out strings.Builder
	out.Grow(len(text))
	for _, char := range text {
		switch char {
		case ' ', '\t', '\r', '\n', '\v', '\f':
			continue
		}
		out.WriteRune(char)
	}
	return out.String()
}

func profileImportBase64Body(text string) ([]profileImportedNode, error) {
	canonical := profileBase64Canonical(text)
	// Reject oversized encoded input before allocating a decoded buffer. A
	// base64 string decodes to at most 3/4 of its length, so this bound is
	// conservative and cannot accept a body above the decoded cap.
	if len(canonical)/4*3 > profileBodyMaxDecoded {
		return nil, profileUnsupported(fmt.Sprintf("base64 subscription body exceeds %d bytes decoded", profileBodyMaxDecoded))
	}
	// Try strict first (standard then URL-safe), then lenient (providers also
	// emit stray `=` mid-stream). Never treat a partially decoded body as
	// success: a decode whose text is not a valid body is refused by recursion.
	decoded, ok := profileBase64Decode(canonical, false)
	if !ok {
		decoded, ok = profileBase64Decode(canonical, true)
	}
	if !ok {
		decoded = profileBase64DecodeLenient(canonical, false)
		if len(decoded) == 0 {
			decoded = profileBase64DecodeLenient(canonical, true)
		}
	}
	if len(decoded) == 0 {
		return nil, profileUnsupported("base64 subscription body decoded to no bytes")
	}
	if len(decoded) > profileBodyMaxDecoded {
		return nil, profileUnsupported(fmt.Sprintf("base64 subscription body exceeds %d bytes decoded", profileBodyMaxDecoded))
	}
	return profileImportBody(string(decoded))
}

// looksLikeJSONBody is a cheap first-value check; the real parse happens in
// profileImportJSONBody with the repository's JSON helpers.
func looksLikeJSONBody(text string) bool {
	trimmed := strings.TrimSpace(text)
	return (strings.HasPrefix(trimmed, "{") && strings.HasSuffix(trimmed, "}")) ||
		(strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]"))
}

// profileImportJSONBody imports a JSON subscription body. The three shapes are
// distinguished by their top-level form:
//
//   - object with a `type` field: one sing-box outbound;
//   - object with a `servers` array: SIP008 document;
//   - array: a list of sing-box outbounds.
//
// Any unsupported type/field fails the whole body (no partial result).
func profileImportJSONBody(text string) ([]profileImportedNode, error) {
	if strings.HasPrefix(strings.TrimSpace(text), "[") {
		return profileImportJSONArrayBody(text)
	}
	object, ok := configDecodeJSONObject(text)
	if !ok {
		return nil, profileUnsupported("subscription body JSON is not an object")
	}
	if _, hasType := object["type"]; hasType {
		node, err := profileImportStoredOutbound(object)
		if err != nil {
			return nil, err
		}
		return []profileImportedNode{*node}, nil
	}
	if servers, present := object["servers"]; present {
		array, ok := servers.([]any)
		if !ok {
			return nil, profileUnsupported("SIP008 servers is not an array")
		}
		return profileImportSIP008(array)
	}
	return nil, profileUnsupported("JSON subscription body has neither type nor servers")
}

func profileImportJSONArrayBody(text string) ([]profileImportedNode, error) {
	trimmed := strings.TrimSpace(text)
	if !strings.HasPrefix(trimmed, "[") || !strings.HasSuffix(trimmed, "]") {
		return nil, profileUnsupported("subscription body JSON is not an array")
	}
	// configDecodeJSONObject only returns objects; decode the array with the
	// same UseNumber + normalization contract as the rest of the codec.
	decoder := json.NewDecoder(strings.NewReader(trimmed))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, profileUnsupported("subscription body JSON array is malformed")
	}
	normalized, ok := configNormalizeJSONValue(value)
	if !ok {
		return nil, profileUnsupported("subscription body JSON array is malformed")
	}
	values, ok := normalized.([]any)
	if !ok {
		return nil, profileUnsupported("subscription body JSON is not an array")
	}
	return profileImportStoredOutbounds(values)
}

// profileImportStoredOutbounds converts a list of stored outbound objects,
// preserving order and refusing the whole list on the first failure.
func profileImportStoredOutbounds(values []any) ([]profileImportedNode, error) {
	nodes := make([]profileImportedNode, 0, len(values))
	for _, value := range values {
		object, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("subscription body JSON array entry is not an object")
		}
		node, err := profileImportStoredOutbound(object)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, *node)
	}
	if len(nodes) == 0 {
		return nil, profileUnsupported("JSON subscription body has no outbounds")
	}
	return profileBodyDedup(nodes), nil
}

// profileImportSIP008 converts a SIP008 `servers` array. SIP008's minimal
// fields map to the stored form of the type the link converters own:
//
//	{"server":"host","server_port":8388,"method":"...","password":"...",
//	 "plugin":"...","plugin_opts":"...","name":"..."}  -> shadowsocks
//
// A server object with an unported `type` or any unsupported field is refused
// whole-body; no approximation is made for unknown fields.
func profileImportSIP008(servers []any) ([]profileImportedNode, error) {
	nodes := make([]profileImportedNode, 0, len(servers))
	for _, value := range servers {
		object, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("SIP008 server entry is not an object")
		}
		node, err := profileImportSIP008Server(object)
		if err != nil {
			return nil, err
		}
		nodes = append(nodes, *node)
	}
	if len(nodes) == 0 {
		return nil, profileUnsupported("SIP008 body has no servers")
	}
	return profileBodyDedup(nodes), nil
}

func profileImportSIP008Server(object map[string]any) (*profileImportedNode, error) {
	// A server carrying an explicit `type` is a stored outbound in SIP008's
	// clothing: convert it with the same type-aware path as a JSON body entry.
	if _, hasType := object["type"]; hasType {
		return profileImportStoredOutbound(object)
	}
	// The minimal SIP008 fields are the shadowsocks ones; anything else is
	// refused instead of guessed.
	for key := range object {
		switch key {
		case "server", "server_port", "method", "password", "plugin", "plugin_opts", "name", "tag", "udp_over_tcp":
		default:
			return nil, profileUnsupported("SIP008 field not ported yet: " + key)
		}
	}
	outbound := &profileStoredSimple{
		Type:       "shadowsocks",
		Name:       sip008Name(object),
		Server:     configJSONString(object, "server"),
		Port:       configJSONInt(object["server_port"]),
		Method:     strings.ToLower(strings.TrimSpace(configJSONString(object, "method"))),
		Password:   configJSONString(object, "password"),
		Plugin:     profileImportPluginName(strings.TrimSpace(configJSONString(object, "plugin"))),
		PluginOpts: strings.TrimSpace(configJSONString(object, "plugin_opts")),
		UOT:        configJSONBool(object, "udp_over_tcp"),
	}
	if outbound.Server == "" || outbound.Port <= 0 {
		return nil, profileUnsupported("SIP008 server has no valid server/server_port")
	}
	if outbound.Method == "" || outbound.Password == "" {
		return nil, profileUnsupported("SIP008 server has no method/password")
	}
	return profileStoredSimpleNode(outbound)
}

func sip008Name(object map[string]any) string {
	if name := strings.TrimSpace(configJSONString(object, "name")); name != "" {
		return name
	}
	return configJSONString(object, "tag")
}

// profileImportStoredOutbound converts a stored sing-box outbound object into
// the same stored-form node the link converters emit. Supported types are the
// ones the Go link converters already cover:
//
//	direct / http / socks / shadowsocks  -> profileStoredSimpleFromObject
//	vmess / vless / trojan / hysteria / hysteria2 -> stored advanced node
//
// Every field of the object must be one the converter ports; unknown fields
// refuse the whole body.
func profileImportStoredOutbound(object map[string]any) (*profileImportedNode, error) {
	rawType := strings.ToLower(strings.TrimSpace(configJSONString(object, "type")))
	switch rawType {
	case "direct", "http", "socks", "shadowsocks":
		if err := profileStoredSimpleCheckFields(object, rawType); err != nil {
			return nil, err
		}
		outbound, supported, err := profileStoredSimpleFromObject(object)
		if err != nil {
			return nil, profileUnsupported("stored outbound is malformed: " + err.Error())
		}
		if !supported {
			return nil, profileUnsupported("stored outbound type/field not ported yet: " + rawType)
		}
		return profileStoredSimpleNode(outbound)
	case "vmess", "vless", "trojan", "hysteria", "hysteria2":
		return profileImportStoredAdvanced(object, rawType)
	case "tuic", "anytls":
		return profileImportStoredTuicAnyTLS(object, rawType)
	case "mieru", "snell", "shadowtls":
		return profileImportStoredNew(object, rawType)
	default:
		return nil, profileUnsupported("stored outbound type not ported yet: " + rawType)
	}
}

// profileStoredSimpleCheckFields refuses an object carrying a field the
// stored-simple codec does not consume. profileStoredSimpleFromObject is
// deliberately forgiving (it is the profileExport path); subscription import
// is not -- an unknown field must fail the whole body.
func profileStoredSimpleCheckFields(object map[string]any, rawType string) error {
	allowed := map[string]bool{
		"type": true, "tag": true, "server": true, "server_port": true,
		"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true,
		"tcp_multi_path": true, "udp_fragment": true, "bind_interface": true,
		"inet4_bind_address": true, "inet6_bind_address": true,
	}
	switch rawType {
	case "http":
		allowed["tls"] = true
		allowed["username"] = true
		allowed["password"] = true
		allowed["path"] = true
		allowed["headers"] = true
	case "socks":
		allowed["username"] = true
		allowed["password"] = true
		allowed["uot"] = true
		allowed["version"] = true
	case "shadowsocks":
		allowed["multiplex"] = true
		allowed["method"] = true
		allowed["password"] = true
		allowed["plugin"] = true
		allowed["plugin_opts"] = true
		allowed["uot"] = true
		allowed["udp_over_tcp"] = true
	}
	for key := range object {
		if !allowed[key] {
			return profileUnsupported("stored " + rawType + " field not ported yet: " + key)
		}
	}
	return nil
}

// profileStoredSimpleNode finishes a simple stored outbound the same way
// profileImportKnownScheme does (stored JSON, share link, identity, dedupKey).
func profileStoredSimpleNode(outbound *profileStoredSimple) (*profileImportedNode, error) {
	storedJSON, err := profileStoredSimpleJSON(outbound)
	if err != nil {
		return nil, err
	}
	withoutTag := profileStoredSimpleWithoutTag(outbound)
	dedupJSON, err := profileStoredSimpleJSON(withoutTag)
	if err != nil {
		return nil, err
	}
	identity := storedJSON
	if outbound.Server != "" {
		encoded, encodeErr := MarshalCanonicalJSON(map[string]any{
			"server":      outbound.Server,
			"server_port": outbound.Port,
		})
		if encodeErr != nil {
			return nil, encodeErr
		}
		identity = string(encoded)
	}
	return &profileImportedNode{
		Type:     outbound.Type,
		Name:     outbound.Name,
		JSON:     storedJSON,
		Link:     profileStoredSimpleLink(outbound),
		Identity: identity,
		DedupKey: "throne://add/" + profileBase64Encode([]byte(dedupJSON), true, false),
	}, nil
}

// profileImportStoredAdvanced builds an advanced stored node from a JSON
// outbound object. The accepted field set mirrors what the link converters
// emit (see profileStoredAdvanced.object); a field outside it is a refusal.
func profileImportStoredAdvanced(object map[string]any, rawType string) (*profileImportedNode, error) {
	server := configJSONString(object, "server")
	if server == "" || profileHasUnsupportedHostForm(server) {
		return nil, profileUnsupported("stored " + rawType + " has no valid server")
	}
	port := configJSONInt(object["server_port"])
	if port <= 0 {
		return nil, profileUnsupported("stored " + rawType + " has no valid server_port")
	}
	node := &profileStoredAdvanced{
		Type:   rawType,
		Name:   configJSONString(object, "tag"),
		Server: aceShareHost(server),
		Port:   port,
		Fields: map[string]any{},
	}
	// Validate the field sets before storing anything: an unknown key refuses
	// the whole body.
	fieldKeys := profileAdvancedFieldKeys(rawType)
	for key := range object {
		switch key {
		case "type", "tag", "server", "server_port", "tls", "transport", "multiplex", "quic":
			continue
		}
		if !fieldKeys[key] {
			return nil, profileUnsupported("stored " + rawType + " field not ported yet: " + key)
		}
		switch value := object[key].(type) {
		case string:
			node.Fields[key] = value
		case bool:
			node.Fields[key] = value
		case int64, float64:
			node.Fields[key] = configJSONInt(value)
		default:
			return nil, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
		}
	}
	if err := profileImportStoredAdvancedBlocks(object, node); err != nil {
		return nil, err
	}
	// TLS links always require a TLS block; for trojan/hysteria the link
	// converters always emit one.
	switch rawType {
	case "trojan", "hysteria", "hysteria2":
		node.AlwaysTLS = true
	}
	if node.TLS == nil {
		node.TLS = map[string]any{}
	}
	return profileAdvancedNode(node)
}

func profileImportStoredAdvancedBlocks(object map[string]any, node *profileStoredAdvanced) error {
	if value, present := object["tls"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return profileUnsupported("stored tls block is not an object")
		}
		for key := range block {
			if !profileStoredTLSKeys[key] {
				return profileUnsupported("stored tls field not ported yet: " + key)
			}
		}
		node.TLS, node.HasTLS = block, true
	}
	if value, present := object["transport"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return profileUnsupported("stored transport block is not an object")
		}
		for key := range block {
			if !profileStoredTransportKeys[key] {
				return profileUnsupported("stored transport field not ported yet: " + key)
			}
		}
		node.Transport, node.HasTr = block, true
	}
	if value, present := object["multiplex"]; present {
		block, ok := value.(map[string]any)
		if !ok || len(block) > 0 {
			return profileUnsupported("stored multiplex is not ported yet")
		}
		node.Multiplex, node.HasMux = block, true
	}
	if value, present := object["quic"]; present {
		block, ok := value.(map[string]any)
		if !ok || len(block) > 0 {
			return profileUnsupported("stored quic fields are not ported yet")
		}
		node.QUIC, node.HasQUIC = block, true
	}
	return nil
}

func profileAdvancedFieldKeys(rawType string) map[string]bool {
	switch rawType {
	case "vmess":
		return map[string]bool{
			"uuid": true, "security": true, "alter_id": true, "global_padding": true,
			"authenticated_length": true, "packet_encoding": true,
		}
	case "vless":
		return map[string]bool{
			"uuid": true, "flow": true, "encryption": true, "packet_encoding": true,
		}
	case "trojan":
		return map[string]bool{"password": true}
	case "hysteria":
		return map[string]bool{
			"auth_str": true, "obfs": true, "recv_window_conn": true,
			"recv_window": true, "up_mbps": true, "down_mbps": true,
		}
	case "hysteria2":
		return map[string]bool{
			"password": true, "obfs": true, "up_mbps": true, "down_mbps": true,
		}
	}
	return nil
}

var (
	profileStoredTLSKeys = map[string]bool{
		"enabled": true, "server_name": true, "insecure": true, "alpn": true,
		"utls": true, "reality": true,
	}
	profileStoredTransportKeys = map[string]bool{
		"type": true, "path": true, "host": true, "headers": true, "service_name": true,
	}
)

// --- detection helpers (kept local so this slice is self-contained) --------

// looksLikeClashBody recognizes the common Clash YAML shapes without parsing
// YAML: a top-level `proxies:`/`proxy-providers:`/`proxy-groups:`/`rules:` key
// anywhere in the document. Panels commonly put `port:` before `proxies:`, so
// checking only the first meaningful line missed them.
func looksLikeClashBody(text string) bool {
	if strings.ContainsAny(text, "\r\n") {
		for _, line := range strings.Split(strings.ReplaceAll(text, "\r\n", "\n"), "\n") {
			if len(line) == 0 || line[0] == ' ' || line[0] == '\t' {
				continue
			}
			trimmed := strings.TrimSpace(line)
			if strings.HasPrefix(trimmed, "proxies:") ||
				strings.HasPrefix(trimmed, "proxy-providers:") ||
				strings.HasPrefix(trimmed, "proxy-groups:") ||
				strings.HasPrefix(trimmed, "rules:") {
				return true
			}
		}
		return false
	}
	trimmed := strings.TrimSpace(text)
	return strings.HasPrefix(trimmed, "proxies:") ||
		strings.HasPrefix(trimmed, "proxy-providers:")
}
