// S5 (next slice): WireGuard and MASQUE stored-form support for the profile
// codec — share link (wireguard), Clash (masque), JSON/SIP008 and the
// profileValidate "stored" draft.
//
// The oracle is the Kotlin outbound pair:
//
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/WireGuard.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/Masque.kt
//   - outbound/common/{Tls,DialFields,QuicFields}.kt
//   - outbound/Outbound.kt (base parseFromJson/exportToJson/exportIdentity)
//   - outbound/import/{ClashProxy,ProfileImport}.kt
//
// Both types are sing-box endpoints: their `server`/`server_port` are
// vestigial for WireGuard (the peer carries the address; exportToJson never
// writes the base keys) and the live values for MASQUE. The stored document
// therefore has two different shapes and cannot go through the shared
// profileStoredAdvanced model, so this slice carries its own pair. Every
// exporter here mirrors one Kotlin function:
//
//   WireGuard.exportToJson   -> profileWgObject
//   WireGuard.exportToLink   -> profileWgLink
//   Masque.exportToJson      -> profileMasqueObject
//   WireGuard/Masque exportIdentity -> profileWgIdentity/profileMasqueIdentity
//
// Refusal contract: a document carrying a field or value whose Kotlin
// normalization is not ported here is answered supported:false with a reason;
// the caller falls back to Kotlin. Kotlin's own parse-time drops (an invalid
// reserved list, a keepalive a range cannot express, an out-of-range Amnezia
// integer that only shapes this side) are reproduced, because they are the
// oracle's normalization rather than an approximation. S1-S4 are the one case
// where Kotlin reports an Error and refuses the whole profile: that refusal is
// reproduced too.
//
// Not ported, deliberately:
//   - the wg-quick/AmneziaWG INI body (SubscriptionParser wireguardFile). It
//     needs PCIRE-compatible name extraction out of comments; a body with
//     "[Interface]"+"[Peer]" is refused with that reason.
//   - MASQUE share links: Kotlin has none (exportToLink returns "").
//   - Clash WireGuard: OutboundFactory's Clash table has no `wireguard` entry.
package mobile

import (
	"errors"
	"net/netip"
	"strconv"
	"strings"
)

// profileWgTypes is the closed set this slice owns.
var profileWgTypes = map[string]bool{"wireguard": true, "masque": true}

// profileWgMasqueDisplayType is Outbound.displayType for the two endpoints.
func profileWgMasqueDisplayType(profileType string) string {
	switch profileType {
	case "wireguard":
		return "WireGuard"
	case "masque":
		return "MASQUE"
	}
	return profileType
}

// profileMasqueDefaultSNI is the Masque constructor's TLS server name
// (masque.h:21-26); a stored document without a `tls` key keeps it.
const profileMasqueDefaultSNI = "consumer-masque.cloudflareclient.com"

// profileMasqueHTTPVersions is masqueHttpVersions.
var profileMasqueHTTPVersions = []string{"0", "2", "3"}

// profileWgDialKeys are the flat DialFields keys both documents may carry.
var profileWgDialKeys = map[string]bool{
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true,
	"tcp_multi_path": true, "udp_fragment": true, "bind_interface": true,
	"inet4_bind_address": true, "inet6_bind_address": true,
}

// profileMasqueQUICKeys are the flat QuicFields keys Masque.parseFromJson reads.
var profileMasqueQUICKeys = map[string]bool{
	"idle_timeout": true, "keep_alive_period": true,
	"stream_receive_window": true, "connection_receive_window": true,
	"max_concurrent_streams": true, "initial_packet_size": true,
	"disable_path_mtu_discovery": true,
}

// --- miniature helpers ------------------------------------------------------

// profileWgInt is QtStrings.toInt: optional sign, ASCII digits, int32 or 0.
func profileWgInt(text string) int {
	value, _ := configQtToIntOrNull(text)
	return value
}

// profileWgIntField is Validation.int over an Optional value: empty is
// allowed, anything not a whole number in [min, max] fails.
func profileWgIntField(text string, min, max int64) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	body := trimmed
	if strings.HasPrefix(body, "-") || strings.HasPrefix(body, "+") {
		body = body[1:]
	}
	if body == "" {
		return false
	}
	for index := 0; index < len(body); index++ {
		if body[index] < '0' || body[index] > '9' {
			return false
		}
	}
	value, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil {
		return false
	}
	return value >= min && value <= max
}

// profileWgKeepaliveValid is WireGuardChecks.wireguardKeepalive
// (Validation.intOrRange 0..WIREGUARD_INT_MAX): one integer or a low-high
// range, both 0..INT_MAX, low <= high.
func profileWgKeepaliveValid(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	dash := strings.IndexByte(trimmed, '-')
	low, high := trimmed, trimmed
	if dash >= 0 {
		low, high = trimmed[:dash], trimmed[dash+1:]
	}
	parts := []string{low, high}
	values := [2]int64{}
	for index, part := range parts {
		if part == "" || strings.HasPrefix(part, "-") {
			return false
		}
		body := part
		if strings.HasPrefix(body, "+") {
			body = body[1:]
		}
		if body == "" {
			return false
		}
		for char := 0; char < len(body); char++ {
			if body[char] < '0' || body[char] > '9' {
				return false
			}
		}
		value, err := strconv.ParseInt(part, 10, 64)
		if err != nil || value < 0 || value > 2147483647 {
			return false
		}
		values[index] = value
	}
	return values[0] <= values[1]
}

// profileWgBase64KeyValid is Validation.base64Key(text, bytes) for the
// standard alphabet with padding; used by the reserved string branch.
func profileWgBase64KeyValid(text string, bytes int) bool {
	trimmed := strings.TrimSpace(text)
	remainder := bytes % 3
	dataChars := bytes / 3 * 4
	if remainder != 0 {
		dataChars += remainder + 1
	}
	total := dataChars
	if remainder != 0 {
		total += 3 - remainder
	}
	if len(trimmed) != total {
		return false
	}
	for index := 0; index < total; index++ {
		char := trimmed[index]
		if index < dataChars {
			valid := (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') ||
				(char >= '0' && char <= '9') || char == '+' || char == '/'
			if !valid {
				return false
			}
		} else if char != '=' {
			return false
		}
	}
	decoded, ok := profileBase64Decode(trimmed, false)
	return ok && len(decoded) == bytes
}

// profileWgReserved is WireGuardChecks.wireguardReserved: bytes separated by
// ',' or '-', each 0..255, exactly three of them. The second result is false
// when Kotlin reports a message (the caller drops the value on import).
func profileWgReserved(text string) ([]int, bool) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return nil, false
	}
	parts := strings.Split(strings.ReplaceAll(trimmed, "-", ","), ",")
	values := make([]int, 0, len(parts))
	for _, part := range parts {
		if part == "" {
			continue
		}
		value, ok := profileNewParseLong(part)
		if !ok || value < 0 || value > 255 {
			return nil, false
		}
		values = append(values, int(value))
	}
	if len(values) != 3 {
		return nil, false
	}
	return values, true
}

// profileWgCIDRValid is Validation.cidr: netip prefix syntax, no zone, decimal
// bits without an unnecessary leading zero, bits within the address family.
func profileWgCIDRValid(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return false
	}
	slash := strings.LastIndex(trimmed, "/")
	if slash < 0 {
		return false
	}
	address, err := netip.ParseAddr(trimmed[:slash])
	if err != nil || address.Zone() != "" {
		return false
	}
	bits := trimmed[slash+1:]
	if bits == "" || strings.Contains(bits, ".") {
		return false
	}
	if len(bits) > 1 && bits[0] == '0' {
		return false
	}
	for index := 0; index < len(bits); index++ {
		if bits[index] < '0' || bits[index] > '9' {
			return false
		}
	}
	value, err := strconv.Atoi(bits)
	if err != nil || len(bits) > 3 {
		return false
	}
	maxBits := 128
	if address.Is4() {
		maxBits = 32
	}
	return value <= maxBits
}

// profileWgSplitClean is QtStrings.splitSkipEmpty over an already
// space-stripped list; dashesVanish mirrors the local_address '-' spelling.
func profileWgSplitClean(value string, dashesVanish bool) []string {
	replaced := strings.ReplaceAll(value, " ", "")
	if dashesVanish {
		replaced = strings.ReplaceAll(replaced, "-", ",")
	}
	parts := strings.Split(replaced, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

// profileWgHostPrefixed is Masque.HostPrefixed: trim, drop blanks, add /32 or
// /128 to an address without a prefix.
func profileWgHostPrefixed(addresses []string) []string {
	out := make([]string, 0, len(addresses))
	for _, raw := range addresses {
		address := strings.TrimSpace(raw)
		if address == "" {
			continue
		}
		if !strings.Contains(address, "/") {
			if strings.Contains(address, ":") {
				address += "/128"
			} else {
				address += "/32"
			}
		}
		out = append(out, address)
	}
	return out
}

// profileWgDropBadAddresses is wireguardDropBadAddresses (only called with
// ParseDiag active, i.e. the import gate).
func profileWgDropBadAddresses(addresses []string) []string {
	out := make([]string, 0, len(addresses))
	for _, address := range addresses {
		if profileWgCIDRValid(address) {
			out = append(out, address)
		}
	}
	return out
}

// profileWgDialFields is DialFields.parseFromJson for the eight flat fields.
func profileWgDialFields(object map[string]any, importing bool) map[string]any {
	fields := map[string]any{}
	for _, key := range []string{"reuse_addr", "tcp_fast_open", "tcp_multi_path", "udp_fragment"} {
		if configJSONBool(object, key) {
			fields[key] = true
		}
	}
	if _, present := object["connect_timeout"]; present {
		value := strings.TrimSpace(configJSONString(object, "connect_timeout"))
		if value != "" && (!importing || profileImportValidDuration(value)) {
			fields["connect_timeout"] = value
		}
	}
	if value := configJSONString(object, "bind_interface"); value != "" {
		fields["bind_interface"] = value
	}
	for _, key := range []string{"inet4_bind_address", "inet6_bind_address"} {
		value := strings.TrimSpace(configJSONString(object, key))
		if value == "" {
			continue
		}
		if importing && !profileNewBindAddressValid(key, value) {
			continue
		}
		fields[key] = value
	}
	return fields
}

// profileWgDialQuery maps the flat dial fields back to DialFields.exportToLink
// order.
func profileWgDialQuery(dial map[string]any) []profileStoredQueryItem {
	simple := &profileStoredSimple{}
	if reuse, _ := dial["reuse_addr"].(bool); reuse {
		simple.ReuseAddr = true
	}
	simple.ConnectTimeout, _ = dial["connect_timeout"].(string)
	if fastOpen, _ := dial["tcp_fast_open"].(bool); fastOpen {
		simple.TCPFastOpen = true
	}
	if multiPath, _ := dial["tcp_multi_path"].(bool); multiPath {
		simple.TCPMultiPath = true
	}
	if fragment, _ := dial["udp_fragment"].(bool); fragment {
		simple.UDPFragment = true
	}
	simple.BindInterface, _ = dial["bind_interface"].(string)
	simple.Inet4Bind, _ = dial["inet4_bind_address"].(string)
	simple.Inet6Bind, _ = dial["inet6_bind_address"].(string)
	return profileStoredDialQuery(simple)
}

func profileWgStringsToAny(items []string) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		out = append(out, item)
	}
	return out
}

func profileWgIntsToAny(items []int) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		out = append(out, item)
	}
	return out
}

// --- wireguard model --------------------------------------------------------

type profileWgPeer struct {
	Address      string
	Port         int
	PublicKey    string
	PreSharedKey string
	Reserved     []int
	Keepalive    string
}

type profileWgAmnezia struct {
	enabled                bool
	jc                     int
	jmin                   int
	jmax                   int
	s1                     int
	s2                     int
	s3                     int
	s4                     int
	h1                     string
	h2                     string
	h3                     string
	h4                     string
	i1                     string
	i2                     string
	i3                     string
	i4                     string
	i5                     string
	headerProtectionKey    string
	contentPaddingAddition string
	rekeyAfterTime         string
	rekeyTimeout           string
	rejectAfterTime        string
	keepaliveTimeout       string
	maxHandshakeAttempts   string
	randomTrailers         bool
	disableCookies         bool
}

type profileWgStored struct {
	Name       string
	Server     string
	ServerPort int
	PrivateKey string
	Peer       profileWgPeer
	Address    []string
	MTU        int
	System     bool
	WorkerCount int
	UDPTimeout string
	Amnezia    profileWgAmnezia
	Dial       map[string]any
}

// profileWgPeerObject is Peer.exportToJson.
func profileWgPeerObject(peer profileWgPeer) map[string]any {
	object := map[string]any{}
	if peer.Address != "" {
		object["address"] = peer.Address
	}
	if peer.Port > 0 {
		object["port"] = peer.Port
	}
	if peer.PublicKey != "" {
		object["public_key"] = peer.PublicKey
	}
	if peer.PreSharedKey != "" {
		object["pre_shared_key"] = peer.PreSharedKey
	}
	if len(peer.Reserved) > 0 {
		object["reserved"] = profileWgIntsToAny(peer.Reserved)
	}
	profileWgWriteKeepalive(object, peer.Keepalive)
	return object
}

// profileWgWriteKeepalive is Peer.WriteKeepalive: a plain interval becomes a
// number, a digit range stays a string, anything else is dropped.
func profileWgWriteKeepalive(object map[string]any, keepalive string) {
	if keepalive == "" {
		return
	}
	if seconds, ok := configQtToIntOrNull(keepalive); ok {
		if seconds > 0 {
			object["persistent_keepalive_interval"] = seconds
		}
		return
	}
	if configWireGuardKeepaliveRange(keepalive) {
		object["persistent_keepalive_interval"] = keepalive
	}
}

// profileWgAmneziaObject is WireGuard.amneziaToJson.
func profileWgAmneziaObject(amnezia profileWgAmnezia) map[string]any {
	object := map[string]any{}
	if !amnezia.enabled {
		return object
	}
	for key, value := range map[string]int{
		"jc": amnezia.jc, "jmin": amnezia.jmin, "jmax": amnezia.jmax,
		"s1": amnezia.s1, "s2": amnezia.s2, "s3": amnezia.s3, "s4": amnezia.s4,
	} {
		if value > 0 {
			object[key] = value
		}
	}
	for key, value := range map[string]string{
		"h1": amnezia.h1, "h2": amnezia.h2, "h3": amnezia.h3, "h4": amnezia.h4,
		"i1": amnezia.i1, "i2": amnezia.i2, "i3": amnezia.i3, "i4": amnezia.i4, "i5": amnezia.i5,
		"header_protection_key":    amnezia.headerProtectionKey,
		"content_padding_addition": amnezia.contentPaddingAddition,
		"rekey_after_time":         amnezia.rekeyAfterTime,
		"rekey_timeout":            amnezia.rekeyTimeout,
		"reject_after_time":        amnezia.rejectAfterTime,
		"keepalive_timeout":        amnezia.keepaliveTimeout,
		"max_handshake_attempts":   amnezia.maxHandshakeAttempts,
	} {
		if value != "" {
			object[key] = value
		}
	}
	if amnezia.randomTrailers {
		object["random_trailers"] = true
	}
	if amnezia.disableCookies {
		object["disable_cookies"] = true
	}
	return object
}

// profileWgObject is WireGuard.exportToJson: `worker_count` (not `workers`),
// and the peer carries the address, so no base server/server_port key.
func profileWgObject(node *profileWgStored) map[string]any {
	object := map[string]any{"type": "wireguard"}
	if node.Name != "" {
		object["tag"] = node.Name
	}
	for key, value := range node.Dial {
		object[key] = value
	}
	if node.PrivateKey != "" {
		object["private_key"] = node.PrivateKey
	}
	if len(node.Address) > 0 {
		object["address"] = profileWgStringsToAny(node.Address)
	}
	if node.MTU > 0 {
		object["mtu"] = node.MTU
	}
	if node.System {
		object["system"] = true
	}
	if node.WorkerCount > 0 {
		object["worker_count"] = node.WorkerCount
	}
	if node.UDPTimeout != "" {
		object["udp_timeout"] = node.UDPTimeout
	}
	if amnezia := profileWgAmneziaObject(node.Amnezia); len(amnezia) > 0 {
		object["amnezia_wg"] = amnezia
	}
	if peer := profileWgPeerObject(node.Peer); len(peer) > 0 {
		object["peers"] = []any{peer}
	}
	return object
}

// profileWgLink is WireGuard.exportToLink.
func profileWgLink(node *profileWgStored) string {
	builder := profileStoredLinkBuilder{
		scheme:      "wg",
		host:        node.Peer.Address,
		port:        node.Peer.Port,
		fragment:    node.Name,
		hasFragment: node.Name != "",
	}
	if node.PrivateKey != "" {
		builder.query = append(builder.query, profileStoredQueryItem{key: "private_key", value: node.PrivateKey})
	}
	if len(node.Address) > 0 {
		builder.query = append(builder.query, profileStoredQueryItem{key: "local_address", value: strings.Join(node.Address, "-")})
	}
	if node.MTU > 0 && node.MTU != 1420 {
		builder.query = append(builder.query, profileStoredQueryItem{key: "mtu", value: strconv.Itoa(node.MTU)})
	}
	if node.System {
		builder.query = append(builder.query, profileStoredQueryItem{key: "use_system_interface", value: "true"})
	}
	if node.WorkerCount > 0 {
		builder.query = append(builder.query, profileStoredQueryItem{key: "workers", value: strconv.Itoa(node.WorkerCount)})
	}
	if node.UDPTimeout != "" {
		builder.query = append(builder.query, profileStoredQueryItem{key: "udp_timeout", value: node.UDPTimeout})
	}
	amnezia := node.Amnezia
	if amnezia.enabled {
		builder.query = append(builder.query, profileStoredQueryItem{key: "enable_amnezia", value: "true"})
		for _, field := range []struct {
			key   string
			value int
		}{
			{"jc", amnezia.jc}, {"jmin", amnezia.jmin}, {"jmax", amnezia.jmax},
			{"s1", amnezia.s1}, {"s2", amnezia.s2}, {"s3", amnezia.s3}, {"s4", amnezia.s4},
		} {
			if field.value > 0 {
				builder.query = append(builder.query, profileStoredQueryItem{key: field.key, value: strconv.Itoa(field.value)})
			}
		}
		for _, field := range []struct {
			key   string
			value string
		}{
			{"h1", amnezia.h1}, {"h2", amnezia.h2}, {"h3", amnezia.h3}, {"h4", amnezia.h4},
			{"i1", amnezia.i1}, {"i2", amnezia.i2}, {"i3", amnezia.i3}, {"i4", amnezia.i4}, {"i5", amnezia.i5},
			{"header_protection_key", amnezia.headerProtectionKey},
			{"content_padding_addition", amnezia.contentPaddingAddition},
			{"rekey_after_time", amnezia.rekeyAfterTime},
			{"rekey_timeout", amnezia.rekeyTimeout},
			{"reject_after_time", amnezia.rejectAfterTime},
			{"keepalive_timeout", amnezia.keepaliveTimeout},
			{"max_handshake_attempts", amnezia.maxHandshakeAttempts},
		} {
			if field.value != "" {
				builder.query = append(builder.query, profileStoredQueryItem{key: field.key, value: field.value})
			}
		}
		if amnezia.randomTrailers {
			builder.query = append(builder.query, profileStoredQueryItem{key: "random_trailers", value: "true"})
		}
		if amnezia.disableCookies {
			builder.query = append(builder.query, profileStoredQueryItem{key: "disable_cookies", value: "true"})
		}
	}
	builder.query = append(builder.query, profileWgDialQuery(node.Dial)...)
	if node.Peer.PublicKey != "" {
		builder.query = append(builder.query, profileStoredQueryItem{key: "public_key", value: node.Peer.PublicKey})
	}
	if node.Peer.PreSharedKey != "" {
		builder.query = append(builder.query, profileStoredQueryItem{key: "pre_shared_key", value: node.Peer.PreSharedKey})
	}
	if len(node.Peer.Reserved) > 0 {
		parts := make([]string, 0, len(node.Peer.Reserved))
		for _, value := range node.Peer.Reserved {
			parts = append(parts, strconv.Itoa(value))
		}
		builder.query = append(builder.query, profileStoredQueryItem{key: "reserved", value: strings.Join(parts, "-")})
	}
	if node.Peer.Keepalive != "" {
		builder.query = append(builder.query, profileStoredQueryItem{key: "persistent_keepalive_interval", value: node.Peer.Keepalive})
	}
	return builder.build()
}

// profileWgIdentity is Outbound.exportIdentity for WireGuard: the base keys
// when a parse left a server behind, the whole stored JSON otherwise (a stored
// row never carries `server`).
func profileWgIdentity(node *profileWgStored) (string, error) {
	if node.Server == "" {
		encoded, err := MarshalCanonicalJSON(profileWgObject(node))
		return string(encoded), err
	}
	encoded, err := MarshalCanonicalJSON(map[string]any{
		"server":      node.Server,
		"server_port": node.ServerPort,
	})
	return string(encoded), err
}

// profileWgNode finishes a wireguard node the way profileAdvancedNode does:
// stored JSON, canonical link, identity and the tag-free dedup key.
func profileWgNode(node *profileWgStored) (*profileImportedNode, error) {
	storedJSON, err := MarshalCanonicalJSON(profileWgObject(node))
	if err != nil {
		return nil, err
	}
	withoutTag := *node
	withoutTag.Name = ""
	dedupJSON, err := MarshalCanonicalJSON(profileWgObject(&withoutTag))
	if err != nil {
		return nil, err
	}
	identity, err := profileWgIdentity(node)
	if err != nil {
		return nil, err
	}
	return &profileImportedNode{
		Type:     "wireguard",
		Name:     node.Name,
		JSON:     string(storedJSON),
		Link:     profileWgLink(node),
		Identity: identity,
		DedupKey: "throne://add/" + profileBase64Encode(dedupJSON, true, false),
	}, nil
}

// --- masque model -----------------------------------------------------------

type profileMasqueQUIC struct {
	IdleTimeout                        string
	KeepAlivePeriod                    string
	StreamReceiveWindow                string
	ConnectionReceiveWindow            string
	MaxConcurrentStreams               int
	InitialPacketSize                  int
	DisablePathMTUDiscovery            bool
	DisablePathMTUDiscoveryUnspecified bool
}

type profileMasqueStored struct {
	Name                   string
	Server                 string
	ServerPort             int
	PrivateKey             string
	PeerPublicKey          string
	Address                []string
	MTU                    int
	HTTPVersion            int
	DisableVersionFallback bool
	TLS                    map[string]any
	QUIC                   profileMasqueQUIC
	Dial                   map[string]any
}

// profileMasqueTLSCanonical is Tls.exportToJson over the parsed subset. The
// block is always enabled (Masque forces it), and REALITY is written only when
// it is enabled -- its public_key can still turn the block on, exactly like
// Tls.parseFromJson.
func profileMasqueTLSCanonical(parsed map[string]any) map[string]any {
	tls := map[string]any{"enabled": true}
	if configJSONBool(parsed, "disable_sni") {
		tls["disable_sni"] = true
	}
	if serverName := configJSONString(parsed, "server_name"); serverName != "" {
		tls["server_name"] = serverName
	}
	if configJSONBool(parsed, "insecure") {
		tls["insecure"] = true
	}
	if list := profileExportStringList(parsed["alpn"]); len(list) > 0 {
		tls["alpn"] = stringListToAny(list)
	}
	for _, key := range []string{"min_version", "max_version"} {
		if value := configJSONString(parsed, key); value != "" {
			tls[key] = value
		}
	}
	if utls, ok := parsed["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
		out := map[string]any{"enabled": true}
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" {
			out["fingerprint"] = fingerprint
		}
		tls["utls"] = out
	}
	if reality, ok := parsed["reality"].(map[string]any); ok && configJSONBool(reality, "enabled") {
		out := map[string]any{"enabled": true}
		for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
			if value := configJSONString(reality, key); value != "" {
				out[key] = value
			}
		}
		tls["reality"] = out
	}
	return tls
}

// profileMasqueTLSIdentity is Tls.exportIdentity: identity keeps a REALITY
// public_key even when its block is not enabled.
func profileMasqueTLSIdentity(parsed map[string]any) map[string]any {
	identity := map[string]any{"enabled": true}
	if configJSONBool(parsed, "disable_sni") {
		identity["disable_sni"] = true
	}
	if serverName := configJSONString(parsed, "server_name"); serverName != "" {
		identity["server_name"] = serverName
	}
	if utls, ok := parsed["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" {
			identity["utls"] = map[string]any{"fingerprint": fingerprint}
		}
	}
	if reality, ok := parsed["reality"].(map[string]any); ok {
		out := map[string]any{}
		if configJSONBool(reality, "enabled") {
			out["enabled"] = true
		}
		for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
			if value := configJSONString(reality, key); value != "" {
				out[key] = value
			}
		}
		if len(out) > 0 {
			identity["reality"] = out
		}
	}
	return identity
}

// profileMasqueQUICObject is QuicFields.exportToJson.
func profileMasqueQUICObject(quic profileMasqueQUIC) map[string]any {
	object := map[string]any{}
	if quic.IdleTimeout != "" {
		object["idle_timeout"] = quic.IdleTimeout
	}
	if quic.KeepAlivePeriod != "" {
		object["keep_alive_period"] = quic.KeepAlivePeriod
	}
	if quic.StreamReceiveWindow != "" {
		object["stream_receive_window"] = quic.StreamReceiveWindow
	}
	if quic.ConnectionReceiveWindow != "" {
		object["connection_receive_window"] = quic.ConnectionReceiveWindow
	}
	if quic.MaxConcurrentStreams > 0 {
		object["max_concurrent_streams"] = quic.MaxConcurrentStreams
	}
	if quic.InitialPacketSize > 0 {
		object["initial_packet_size"] = quic.InitialPacketSize
	}
	if !quic.DisablePathMTUDiscoveryUnspecified {
		object["disable_path_mtu_discovery"] = quic.DisablePathMTUDiscovery
	}
	return object
}

// profileMasqueObject is Masque.exportToJson.
func profileMasqueObject(node *profileMasqueStored) map[string]any {
	object := map[string]any{"type": "masque"}
	if node.Name != "" {
		object["tag"] = node.Name
	}
	if node.Server != "" {
		object["server"] = node.Server
	}
	if node.ServerPort > 0 {
		object["server_port"] = node.ServerPort
	}
	for key, value := range node.Dial {
		object[key] = value
	}
	if node.PrivateKey != "" {
		object["private_key"] = node.PrivateKey
	}
	if node.PeerPublicKey != "" {
		object["peer_public_key"] = node.PeerPublicKey
	}
	if len(node.Address) > 0 {
		object["address"] = profileWgStringsToAny(node.Address)
	}
	if node.MTU > 0 {
		object["mtu"] = node.MTU
	}
	if node.HTTPVersion != 0 {
		object["http_version"] = node.HTTPVersion
	}
	if node.DisableVersionFallback {
		object["disable_version_fallback"] = true
	}
	object["tls"] = profileMasqueTLSCanonical(node.TLS)
	for key, value := range profileMasqueQUICObject(node.QUIC) {
		object[key] = value
	}
	return object
}

// profileMasqueIdentity is Masque.exportIdentity: the base identity plus the
// private key (written even when empty).
func profileMasqueIdentity(node *profileMasqueStored) (string, error) {
	var identity map[string]any
	if node.Server == "" {
		identity = profileMasqueObject(node)
	} else {
		identity = map[string]any{
			"server":      node.Server,
			"server_port": node.ServerPort,
			"tls":         profileMasqueTLSIdentity(node.TLS),
		}
	}
	identity["private_key"] = node.PrivateKey
	encoded, err := MarshalCanonicalJSON(identity)
	return string(encoded), err
}

// profileMasqueNode finishes a masque node; the share link is empty because
// masque.cpp has no link form.
func profileMasqueNode(node *profileMasqueStored) (*profileImportedNode, error) {
	storedJSON, err := MarshalCanonicalJSON(profileMasqueObject(node))
	if err != nil {
		return nil, err
	}
	withoutTag := *node
	withoutTag.Name = ""
	dedupJSON, err := MarshalCanonicalJSON(profileMasqueObject(&withoutTag))
	if err != nil {
		return nil, err
	}
	identity, err := profileMasqueIdentity(node)
	if err != nil {
		return nil, err
	}
	return &profileImportedNode{
		Type:     "masque",
		Name:     node.Name,
		JSON:     string(storedJSON),
		Link:     "",
		Identity: identity,
		DedupKey: "throne://add/" + profileBase64Encode(dedupJSON, true, false),
	}, nil
}

// --- wireguard share link ---------------------------------------------------

// profileImportWireGuardLink follows WireGuard.parseFromLink (the URL form).
// The INI form is refused before reaching here (see profile_import_body.go).
func profileImportWireGuardLink(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed wireguard link")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	node := &profileWgStored{MTU: 1420, Name: link.Fragment, Dial: map[string]any{}}
	switch {
	case link.Query.Has("private_key"):
		node.PrivateKey = link.Query.ValueFully("private_key")
	case link.Query.Has("privatekey"):
		node.PrivateKey = link.Query.ValueFully("privatekey")
	case link.UserName != "":
		node.PrivateKey = link.UserName
	}
	node.Peer.Address = link.Host
	node.Peer.Port = link.PortOrDefault(51820)
	switch {
	case link.Query.Has("public_key"):
		node.Peer.PublicKey = link.Query.ValueFully("public_key")
	case link.Query.Has("publickey"):
		node.Peer.PublicKey = link.Query.ValueFully("publickey")
	case link.Query.Has("peer_public_key"):
		node.Peer.PublicKey = link.Query.ValueFully("peer_public_key")
	}
	switch {
	case link.Query.Has("pre_shared_key"):
		node.Peer.PreSharedKey = link.Query.ValueFully("pre_shared_key")
	case link.Query.Has("preshared_key"):
		node.Peer.PreSharedKey = link.Query.ValueFully("preshared_key")
	case link.Query.Has("presharedkey"):
		node.Peer.PreSharedKey = link.Query.ValueFully("presharedkey")
	case link.Query.Has("psk"):
		node.Peer.PreSharedKey = link.Query.ValueFully("psk")
	}
	if link.Query.Has("reserved") {
		// An invalid list is dropped with a warning on the Kotlin side.
		if reserved, ok := profileWgReserved(link.Query.ValueFully("reserved")); ok {
			node.Peer.Reserved = reserved
		}
	}
	for _, key := range []string{"persistent_keepalive_interval", "persistent_keepalive", "keepalive"} {
		if !link.Query.Has(key) {
			continue
		}
		value := strings.TrimSpace(link.Query.ValueFully(key))
		if profileWgKeepaliveValid(value) {
			node.Peer.Keepalive = value
		}
		break
	}
	node.Server = node.Peer.Address
	node.ServerPort = node.Peer.Port

	switch {
	case link.Query.Has("local_address"):
		node.Address = profileWgSplitClean(link.Query.ValueFully("local_address"), true)
	case link.Query.Has("address"):
		node.Address = profileWgSplitClean(link.Query.ValueFully("address"), false)
	case link.Query.Has("ip"):
		node.Address = profileWgSplitClean(link.Query.ValueFully("ip"), false)
	}
	if link.Query.Has("mtu") {
		value := strings.TrimSpace(link.Query.ValueFully("mtu"))
		if profileWgIntField(value, 0, 2147483647) {
			node.MTU = profileWgInt(value)
		}
	}
	if link.Query.Has("workers") {
		value := strings.TrimSpace(link.Query.ValueFully("workers"))
		if profileWgIntField(value, 0, 2147483647) {
			node.WorkerCount = profileWgInt(value)
		}
	}
	if link.Query.Has("use_system_interface") {
		node.System = link.Query.ValueFully("use_system_interface") == "true"
	}
	if link.Query.Has("udp_timeout") {
		value := strings.TrimSpace(link.Query.ValueFully("udp_timeout"))
		if profileImportValidDuration(value) {
			node.UDPTimeout = value
		}
	}
	if link.Query.ValueFully("enable_amnezia") == "true" {
		node.Amnezia.enabled = true
	}
	for _, field := range []struct {
		key            string
		max            int64
		mustMatch      bool
		set            func(int)
	}{
		{"jc", 2147483647, false, func(v int) { node.Amnezia.jc = v }},
		{"jmin", 2147483647, false, func(v int) { node.Amnezia.jmin = v }},
		{"jmax", 2147483647, false, func(v int) { node.Amnezia.jmax = v }},
		{"s1", 65535, true, func(v int) { node.Amnezia.s1 = v }},
		{"s2", 65535, true, func(v int) { node.Amnezia.s2 = v }},
		{"s3", 65535, true, func(v int) { node.Amnezia.s3 = v }},
		{"s4", 65535, true, func(v int) { node.Amnezia.s4 = v }},
	} {
		if !link.Query.Has(field.key) {
			continue
		}
		raw := link.Query.ValueFully(field.key)
		if !profileWgIntField(raw, 0, field.max) {
			if field.mustMatch {
				// amneziaInt reports an Error for S1-S4, refusing the profile.
				return nil, profileUnsupported("wireguard " + field.key + " must be an integer between 0 and 65535")
			}
			field.set(0)
		} else {
			field.set(profileWgInt(raw))
		}
		node.Amnezia.enabled = true
	}
	for _, field := range []struct {
		key     string
		trim    bool
		aliases []string
		set     func(string)
	}{
		{"h1", true, nil, func(v string) { node.Amnezia.h1 = v }},
		{"h2", true, nil, func(v string) { node.Amnezia.h2 = v }},
		{"h3", true, nil, func(v string) { node.Amnezia.h3 = v }},
		{"h4", true, nil, func(v string) { node.Amnezia.h4 = v }},
		{"i1", false, nil, func(v string) { node.Amnezia.i1 = v }},
		{"i2", false, nil, func(v string) { node.Amnezia.i2 = v }},
		{"i3", false, nil, func(v string) { node.Amnezia.i3 = v }},
		{"i4", false, nil, func(v string) { node.Amnezia.i4 = v }},
		{"i5", false, nil, func(v string) { node.Amnezia.i5 = v }},
		{"header_protection_key", false, []string{"headerprotectionkey"}, func(v string) { node.Amnezia.headerProtectionKey = v }},
		{"content_padding_addition", false, []string{"contentpaddingaddition"}, func(v string) { node.Amnezia.contentPaddingAddition = v }},
		{"rekey_after_time", false, nil, func(v string) { node.Amnezia.rekeyAfterTime = v }},
		{"rekey_timeout", false, nil, func(v string) { node.Amnezia.rekeyTimeout = v }},
		{"reject_after_time", false, nil, func(v string) { node.Amnezia.rejectAfterTime = v }},
		{"keepalive_timeout", false, nil, func(v string) { node.Amnezia.keepaliveTimeout = v }},
		{"max_handshake_attempts", false, nil, func(v string) { node.Amnezia.maxHandshakeAttempts = v }},
	} {
		key := field.key
		present := link.Query.Has(key)
		if !present {
			for _, alias := range field.aliases {
				if link.Query.Has(alias) {
					key = alias
					present = true
					break
				}
			}
		}
		if !present {
			continue
		}
		value := link.Query.ValueFully(key)
		if field.trim {
			value = strings.TrimSpace(value)
		}
		field.set(value)
		node.Amnezia.enabled = true
	}
	if link.Query.Has("random_trailers") {
		node.Amnezia.randomTrailers = profileWgAmneziaBool(link.Query.ValueFully("random_trailers"))
		node.Amnezia.enabled = true
	}
	if link.Query.Has("disable_cookies") {
		node.Amnezia.disableCookies = profileWgAmneziaBool(link.Query.ValueFully("disable_cookies"))
		node.Amnezia.enabled = true
	}
	node.Address = configWireGuardFixAddress(node.Address)
	node.Address = profileWgDropBadAddresses(node.Address)
	if node.PrivateKey == "" || node.Peer.PublicKey == "" || node.Server == "" {
		return nil, profileUnsupported("wireguard link needs private_key, peer public_key and a server")
	}
	return profileWgNode(node)
}

// profileWgAmneziaBool is ParseAmneziaBool.
func profileWgAmneziaBool(value string) bool {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "true", "1", "on", "yes":
		return true
	}
	return false
}

// --- stored JSON ------------------------------------------------------------

// profileWgRefusal converts either refusal type into the action reply shape;
// the unmodelled value is the shared profileNewUnmodelled the other slices use.
func profileWgRefusal(err error) (profileImportUnsupported, bool) {
	var unsupported profileImportUnsupported
	if errors.As(err, &unsupported) {
		return unsupported, true
	}
	var unmodelled profileNewUnmodelled
	if errors.As(err, &unmodelled) {
		return profileImportUnsupported{Reason: unmodelled.Reason}, true
	}
	return profileImportUnsupported{}, false
}

// profileImportStoredWg converts a stored outbound object from a JSON/SIP008
// body into the same node the link/Clash converters emit.
func profileImportStoredWg(object map[string]any, rawType string) (*profileImportedNode, error) {
	if rawType == "wireguard" {
		parsed, err := profileWgFromObject(object, profileNewImportMode)
		if err != nil {
			if refused, ok := profileWgRefusal(err); ok {
				return nil, refused
			}
			return nil, err
		}
		if len(parsed.Unknown) > 0 {
			return nil, profileUnsupported("stored wireguard field not ported yet: " + parsed.Unknown[0])
		}
		return profileWgNode(parsed.Node)
	}
	parsed, err := profileMasqueFromObject(object, profileNewImportMode)
	if err != nil {
		if refused, ok := profileWgRefusal(err); ok {
			return nil, refused
		}
		return nil, err
	}
	if len(parsed.Unknown) > 0 {
		return nil, profileUnsupported("stored masque field not ported yet: " + parsed.Unknown[0])
	}
	return profileMasqueNode(parsed.Node)
}

type profileWgParsed struct {
	Node    *profileWgStored
	Unknown []string
}

// profileMasqueParsed is the masque counterpart (the two stored shapes differ).
type profileMasqueParsed struct {
	Node    *profileMasqueStored
	Unknown []string
}

// profileWgFromObject is WireGuard.parseFromJson followed by exportToJson's
// model: `mode` selects the import gate (ParseDiag active) or a stored row.
func profileWgFromObject(object map[string]any, mode profileNewMode) (*profileWgParsed, error) {
	importing := mode == profileNewImportMode
	node := &profileWgStored{MTU: 1420, Dial: map[string]any{}}
	node.Name = configJSONString(object, "tag")
	node.Server = aceShareHost(configJSONString(object, "server"))
	node.ServerPort = configJSONInt(object["server_port"])
	node.Dial = profileWgDialFields(object, importing)
	node.PrivateKey = configJSONString(object, "private_key")
	var peerUnknown []string
	if peers, ok := object["peers"].([]any); ok && len(peers) > 0 {
		if peer, ok := peers[0].(map[string]any); ok {
			parsed, unknown, err := profileWgPeerFromObject(peer, importing)
			if err != nil {
				return nil, err
			}
			node.Peer = parsed
			for _, key := range unknown {
				peerUnknown = append(peerUnknown, "peers[0]."+key)
			}
		}
	}
	if _, present := object["address"]; present {
		node.Address = configJSONStringListValue(object["address"])
	}
	if _, present := object["mtu"]; present {
		node.MTU = configJSONInt(object["mtu"])
	}
	if _, present := object["system"]; present {
		node.System = configJSONBool(object, "system")
	}
	if _, present := object["workers"]; present {
		node.WorkerCount = configJSONInt(object["workers"])
	} else if _, present := object["worker_count"]; present {
		node.WorkerCount = configJSONInt(object["worker_count"])
	}
	if _, present := object["udp_timeout"]; present {
		value := strings.TrimSpace(configJSONString(object, "udp_timeout"))
		if !importing || profileImportValidDuration(value) {
			node.UDPTimeout = value
		}
	}
	if amnezia, ok := object["amnezia_wg"].(map[string]any); ok {
		node.Amnezia = profileWgAmneziaFromObject(amnezia)
	}
	node.Address = configWireGuardFixAddress(node.Address)
	if importing {
		node.Address = profileWgDropBadAddresses(node.Address)
	}

	allowed := map[string]bool{
		"type": true, "tag": true, "server": true, "server_port": true,
		"private_key": true, "peers": true, "address": true, "mtu": true,
		"system": true, "workers": true, "worker_count": true,
		"udp_timeout": true, "amnezia_wg": true,
	}
	for key := range profileWgDialKeys {
		allowed[key] = true
	}
	parsed := &profileWgParsed{Node: node, Unknown: peerUnknown}
	for key := range object {
		if !allowed[key] {
			parsed.Unknown = append(parsed.Unknown, key)
		}
	}
	return parsed, nil
}

// profileWgPeerFromObject is Peer.parseFromJson. `allowed_ips` is accepted and
// ignored: Kotlin never reads it (Peer.build writes the catch-all), so refusing
// it would reject a plain sing-box document Kotlin imports fine.
func profileWgPeerFromObject(object map[string]any, importing bool) (profileWgPeer, []string, error) {
	peer := profileWgPeer{}
	allowed := map[string]bool{
		"address": true, "port": true, "public_key": true, "pre_shared_key": true,
		"reserved": true, "persistent_keepalive_interval": true, "allowed_ips": true,
	}
	var unknown []string
	for key := range object {
		if !allowed[key] {
			unknown = append(unknown, key)
		}
	}
	peer.Address = configJSONString(object, "address")
	peer.Port = configJSONInt(object["port"])
	peer.PublicKey = configJSONString(object, "public_key")
	peer.PreSharedKey = configJSONString(object, "pre_shared_key")
	if value, present := object["reserved"]; present {
		peer.Reserved = profileWgReservedJSON(value, importing)
	}
	if value, present := object["persistent_keepalive_interval"]; present {
		text := ""
		if typed, ok := value.(string); ok {
			text = typed
		} else {
			text = strconv.Itoa(configJSONInt(value))
		}
		if !importing || profileWgKeepaliveValid(text) {
			peer.Keepalive = text
		}
	}
	return peer, unknown, nil
}

// profileWgReservedJSON is Peer.parseFromJson's reserved branch: a string is
// decoded when it is not already a valid 3-byte base64 value, a list keeps its
// numeric items; the import gate then drops whatever is not three bytes.
func profileWgReservedJSON(value any, importing bool) []int {
	if text, ok := value.(string); ok {
		var reserved []int
		if profileWgBase64KeyValid(text, 3) {
			// Go decodes a JSON string into []uint8 as base64.
			decoded := profileBase64DecodeLenient(text, false)
			reserved = make([]int, 0, len(decoded))
			for _, item := range decoded {
				reserved = append(reserved, int(item))
			}
		}
		if importing && (len(reserved) > 0 || text != "") {
			if checked, ok := profileWgReserved(joinInts(reserved, ",")); ok {
				return checked
			}
			return nil
		}
		return reserved
	}
	items, _ := value.([]any)
	reserved := make([]int, 0, len(items))
	for _, item := range items {
		reserved = append(reserved, configJSONInt(item))
	}
	if importing && len(reserved) > 0 {
		if checked, ok := profileWgReserved(joinInts(reserved, ",")); ok {
			return checked
		}
		return nil
	}
	return reserved
}

func joinInts(values []int, separator string) string {
	parts := make([]string, 0, len(values))
	for _, value := range values {
		parts = append(parts, strconv.Itoa(value))
	}
	return strings.Join(parts, separator)
}

// profileWgAmneziaFromObject is WireGuard.amneziaFromJson: any non-empty block
// switches AmneziaWG on.
func profileWgAmneziaFromObject(object map[string]any) profileWgAmnezia {
	amnezia := profileWgAmnezia{}
	if len(object) == 0 {
		return amnezia
	}
	amnezia.enabled = true
	amnezia.jc = configJSONInt(object["jc"])
	amnezia.jmin = configJSONInt(object["jmin"])
	amnezia.jmax = configJSONInt(object["jmax"])
	amnezia.s1 = configJSONInt(object["s1"])
	amnezia.s2 = configJSONInt(object["s2"])
	amnezia.s3 = configJSONInt(object["s3"])
	amnezia.s4 = configJSONInt(object["s4"])
	amnezia.h1 = strings.TrimSpace(configJSONString(object, "h1"))
	amnezia.h2 = strings.TrimSpace(configJSONString(object, "h2"))
	amnezia.h3 = strings.TrimSpace(configJSONString(object, "h3"))
	amnezia.h4 = strings.TrimSpace(configJSONString(object, "h4"))
	amnezia.i1 = configJSONString(object, "i1")
	amnezia.i2 = configJSONString(object, "i2")
	amnezia.i3 = configJSONString(object, "i3")
	amnezia.i4 = configJSONString(object, "i4")
	amnezia.i5 = configJSONString(object, "i5")
	amnezia.headerProtectionKey = configJSONString(object, "header_protection_key")
	for key, target := range map[string]*string{
		"content_padding_addition": &amnezia.contentPaddingAddition,
		"rekey_after_time":         &amnezia.rekeyAfterTime,
		"rekey_timeout":            &amnezia.rekeyTimeout,
		"reject_after_time":        &amnezia.rejectAfterTime,
		"keepalive_timeout":        &amnezia.keepaliveTimeout,
		"max_handshake_attempts":   &amnezia.maxHandshakeAttempts,
	} {
		if value, present := object[key]; present {
			*target = profileWgAmneziaRangeText(value)
		}
	}
	amnezia.randomTrailers = configJSONBool(object, "random_trailers")
	amnezia.disableCookies = configJSONBool(object, "disable_cookies")
	return amnezia
}

// profileWgAmneziaRangeText is AmneziaRangeFromJson: a string verbatim,
// anything else through JsonValues.toInt().toString().
func profileWgAmneziaRangeText(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return strconv.Itoa(configJSONInt(value))
}

// profileMasqueFromObject is Masque.parseFromJson followed by exportToJson's
// model.
func profileMasqueFromObject(object map[string]any, mode profileNewMode) (*profileMasqueParsed, error) {
	importing := mode == profileNewImportMode
	// Masque's constructor already sets the endpoint defaults; parseFromJson only
	// overwrites them when the key is present (an explicit 0 is kept).
	node := &profileMasqueStored{MTU: 1280, ServerPort: 443, Dial: map[string]any{}}
	node.Name = configJSONString(object, "tag")
	node.Server = aceShareHost(configJSONString(object, "server"))
	if _, present := object["server_port"]; present {
		node.ServerPort = configJSONInt(object["server_port"])
	}
	node.Dial = profileWgDialFields(object, importing)
	node.PrivateKey = configJSONString(object, "private_key")
	node.PeerPublicKey = configJSONString(object, "peer_public_key")
	if _, present := object["address"]; present {
		node.Address = profileWgHostPrefixed(configJSONStringListValue(object["address"]))
		if importing {
			filtered := make([]string, 0, len(node.Address))
			for _, address := range node.Address {
				if profileWgCIDRValid(address) {
					filtered = append(filtered, address)
				}
			}
			node.Address = filtered
		}
	}
	if _, present := object["mtu"]; present {
		node.MTU = configJSONInt(object["mtu"])
	}
	if _, present := object["http_version"]; present {
		version := configJSONInt(object["http_version"])
		if !importing || profileNewOneOf(strconv.Itoa(version), profileMasqueHTTPVersions, false) {
			node.HTTPVersion = version
		}
	}
	if _, present := object["disable_version_fallback"]; present {
		node.DisableVersionFallback = configJSONBool(object, "disable_version_fallback")
	}
	tls, err := profileMasqueTLSFromObject(object, mode)
	if err != nil {
		return nil, err
	}
	node.TLS = tls
	node.QUIC = profileMasqueQUICFromObject(object, importing)

	allowed := map[string]bool{
		"type": true, "tag": true, "server": true, "server_port": true,
		"private_key": true, "peer_public_key": true, "address": true, "mtu": true,
		"http_version": true, "disable_version_fallback": true, "tls": true,
	}
	for key := range profileWgDialKeys {
		allowed[key] = true
	}
	for key := range profileMasqueQUICKeys {
		allowed[key] = true
	}
	parsed := &profileMasqueParsed{Node: node}
	for key := range object {
		if !allowed[key] {
			parsed.Unknown = append(parsed.Unknown, key)
		}
	}
	return parsed, nil
}

// profileMasqueTLSFromObject is the `tls` half of Masque.parseFromJson: the
// constructor default applies only when the key is absent, an absent
// server_name clears it, and enabled is forced on afterwards.
func profileMasqueTLSFromObject(object map[string]any, mode profileNewMode) (map[string]any, error) {
	value, present := object["tls"]
	if !present {
		return map[string]any{"enabled": true, "server_name": profileMasqueDefaultSNI}, nil
	}
	block, ok := value.(map[string]any)
	if !ok {
		// obj.obj("tls") of a non-object is the empty block: every field keeps
		// its default and the missing server_name clears the constructor's.
		block = map[string]any{}
	}
	var (
		parsed map[string]any
		err    error
	)
	if mode == profileNewImportMode {
		parsed, _, err = profileNewTLSImport(block)
	} else {
		parsed, err = profileNewTLSDraft(block)
	}
	if err != nil {
		return nil, err
	}
	parsed["enabled"] = true
	if _, hasServerName := block["server_name"]; !hasServerName {
		delete(parsed, "server_name")
	}
	return parsed, nil
}

// profileMasqueQUICFromObject is QuicFields.parseFromJson over the flat keys.
func profileMasqueQUICFromObject(object map[string]any, importing bool) profileMasqueQUIC {
	quic := profileMasqueQUIC{DisablePathMTUDiscoveryUnspecified: true}
	for _, field := range []struct {
		key   string
		store *string
	}{
		{"idle_timeout", &quic.IdleTimeout},
		{"keep_alive_period", &quic.KeepAlivePeriod},
	} {
		if _, present := object[field.key]; !present {
			continue
		}
		value := strings.TrimSpace(configJSONString(object, field.key))
		if !importing || profileImportValidDuration(value) {
			*field.store = value
		}
	}
	for _, field := range []struct {
		key   string
		store *string
	}{
		{"stream_receive_window", &quic.StreamReceiveWindow},
		{"connection_receive_window", &quic.ConnectionReceiveWindow},
	} {
		if _, present := object[field.key]; !present {
			continue
		}
		value, valid := profileMasqueMemoryBytesText(object[field.key])
		if !valid {
			// memoryBytesText dropped the value with a warning; "" is accepted
			// by memoryBytes(allowBareInteger=true), so the field clears.
			value = ""
		}
		if importing && !profileValidMemoryBytes(value) {
			continue
		}
		*field.store = value
	}
	if _, present := object["max_concurrent_streams"]; present {
		quic.MaxConcurrentStreams = configJSONInt(object["max_concurrent_streams"])
	}
	if _, present := object["initial_packet_size"]; present {
		value := configJSONInt(object["initial_packet_size"])
		text := strconv.Itoa(value)
		if !importing || profileMasqueInitialPacketSizeValid(text) {
			quic.InitialPacketSize = value
		}
	}
	if _, present := object["disable_path_mtu_discovery"]; present {
		quic.DisablePathMTUDiscovery = configJSONBool(object, "disable_path_mtu_discovery")
		quic.DisablePathMTUDiscoveryUnspecified = false
	}
	return quic
}

// profileMasqueMemoryBytesText is memoryBytesText: a JSON number becomes its
// decimal digits, a negative or fractional one is reported and dropped, a
// string is kept as written.
func profileMasqueMemoryBytesText(value any) (string, bool) {
	switch typed := value.(type) {
	case int64:
		if typed >= 0 {
			return strconv.FormatInt(typed, 10), true
		}
		return "", false
	case float64:
		if typed == float64(int64(typed)) && typed >= 0 && typed < 9.223372036854775807e18 {
			return strconv.FormatInt(int64(typed), 10), true
		}
		return "", false
	case string:
		return typed, true
	}
	return "", true
}

// profileMasqueInitialPacketSizeValid is QuicChecks.quicInitialPacketSize.
func profileMasqueInitialPacketSizeValid(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	value, ok := profileNewParseLong(trimmed)
	if !ok {
		return false
	}
	if value == 0 {
		// An empty/zero/blank override is allowed.
		return true
	}
	return value >= 1200 && value <= 1452
}

// --- clash ---------------------------------------------------------------

// clashMasque is Masque.parseFromClash. Masque has a Clash mapping
// (OutboundFactory.PROTOCOLS); mihomo never falls back between carriers, so
// `network: h2` pins HTTP/2 and anything else HTTP/3.
func clashMasque(p clashProxy) (*profileImportedNode, error) {
	if err := clashRejectUnknownFields(p, "masque", []string{
		"type", "name", "server", "port", "private-key", "public-key", "ip", "ipv6",
		"mtu", "sni", "skip-cert-verify", "network",
	}); err != nil {
		return nil, err
	}
	name, server, port, err := clashBase(p, "masque")
	if err != nil {
		return nil, err
	}
	node := &profileMasqueStored{
		Name: name, Server: server, ServerPort: port, MTU: 1280,
		TLS: map[string]any{"enabled": true, "server_name": profileMasqueDefaultSNI},
		QUIC: profileMasqueQUIC{DisablePathMTUDiscoveryUnspecified: true},
		Dial: map[string]any{},
	}
	if node.ServerPort == 0 {
		node.ServerPort = 443
	}
	node.PrivateKey = p.String("private-key")
	node.PeerPublicKey = p.String("public-key")
	node.Address = profileWgHostPrefixed([]string{p.String("ip"), p.String("ipv6")})
	if mtu := p.Int("mtu"); mtu > 0 {
		node.MTU = mtu
	}
	if sni := p.String("sni"); sni != "" {
		node.TLS["server_name"] = aceShareHost(sni)
	}
	if p.Bool("skip-cert-verify") {
		node.TLS["insecure"] = true
	}
	if p.String("network") == "h2" {
		node.HTTPVersion = 2
		node.DisableVersionFallback = false
	} else {
		node.HTTPVersion = 3
		node.DisableVersionFallback = true
	}
	if node.PrivateKey == "" {
		// Masque.parseFromClash returns false without a private key.
		return nil, profileUnsupported("clash: masque needs a private-key")
	}
	return profileMasqueNode(node)
}
