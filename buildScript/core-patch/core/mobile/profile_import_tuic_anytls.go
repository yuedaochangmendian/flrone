// S5 (next slice): TUIC and AnyTLS share-link, Clash, stored-JSON and stored
// validation support.
//
// The oracle is the Kotlin outbound pair, exactly as it is for the other
// advanced types:
//
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/Tuic.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/AnyTls.kt
//   - outbound/common/{Tls,QuicFields,DialFields}.kt
//   - outbound/import/ClashProxy.kt and Outbound.kt
//
// The stored JSON, identity and share link are produced by the shared
// profileStoredAdvanced helpers, so these two types cannot drift from the
// vmess/vless/trojan/hysteria path. Every query key listed here is one the
// Kotlin parser actually reads; a key it would read but this slice cannot
// normalise byte for byte is refused with supported:false, never dropped.
package mobile

import (
	"fmt"
	"strings"
)

// The two new types reuse the shared advanced stored form. Their field sets
// are the exact keys Tuic.exportToJson / AnyTls.exportToJson write on top of
// baseExportToJson (tag/server/server_port/dial fields).
var (
	profileStoredTuicFields = map[string]bool{
		"uuid": true, "password": true, "congestion_control": true,
		"udp_relay_mode": true, "udp_over_stream": true, "zero_rtt_handshake": true,
		"heartbeat": true,
		// QuicFields.exportToJson is merged flat into the tuic outbound.
		"idle_timeout": true, "keep_alive_period": true,
		"stream_receive_window": true, "connection_receive_window": true,
		"max_concurrent_streams": true, "initial_packet_size": true,
		"disable_path_mtu_discovery": true,
	}
	profileStoredAnyTLSFields = map[string]bool{
		"password": true, "idle_session_check_interval": true,
		"idle_session_timeout": true, "min_idle_session": true,
	}
	profileStoredTuicAnyTLSTypes = map[string]bool{"tuic": true, "anytls": true}
)

// profileImportTuicAnyTLS dispatches a share link of one of the two new types.
func profileImportTuicAnyTLS(scheme string, link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed " + scheme + " link")
	}
	switch scheme {
	case "tuic":
		return profileImportTuicLink(link)
	case "anytls":
		return profileImportAnyTLink(link)
	}
	return nil, profileUnsupported("scheme not handled by the tuic/anytls importer: " + scheme)
}

// profileTLSWithoutDisableSNI hands the shared TLS parser a link with
// disable_sni removed. Tls.parseFromLink accepts disable_sni for every
// protocol, but the older advanced slice deliberately refuses it; the two new
// types need it, and stripping it here keeps the other protocols' contract
// unchanged while still reusing the shared parser.
func profileTLSWithoutDisableSNI(link profileParsedLink) profileParsedLink {
	copy := link
	copy.Query = profileLinkQueryEmpty()
	for _, item := range link.Query.Items {
		if strings.EqualFold(item.Key, "disable_sni") {
			continue
		}
		copy.Query.Items = append(copy.Query.Items, item)
	}
	return copy
}

// profileTuicTLS mirrors Tls.parseFromLink followed by Tuic's forced
// tls.enabled=true, including the shared TLS fields that the older advanced
// parser only applies when security is present.
func profileTuicTLS(link profileParsedLink) (map[string]any, error) {
	original := link
	// The shared parser refuses disable_sni; strip it here and re-apply it as
	// Kotlin's Tls would.
	link = profileTLSWithoutDisableSNI(link)
	// security absent still yields a TLS block for TUIC; a present security
	// value is handled by the shared parser.
	tls, _, err := profileImportTLS(link, false, false)
	if err != nil {
		return nil, err
	}
	// Kotlin applies sni/peer, allowInsecure/alpn/fp even when security is
	// absent; the shared parser only does so for an enabled TLS block. Replay
	// those fields here so the forced enabled state matches the oracle.
	profileReplayForcedTLSFields(original, tls, false)
	tls["enabled"] = true
	return tls, nil
}

// profileReplayForcedTLSFields applies the TLS fields Tls.parseFromLink reads
// regardless of the security switch. The shared profileImportTLS skips them
// when TLS is off; the two QUIC-family types force TLS on after the parse, so
// the fields must be present in their stored TLS block.
func profileReplayForcedTLSFields(link profileParsedLink, tls map[string]any, utlsSupported bool) {
	query := link.Query
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
		raw := query.Value("fp")
		if utlsSupported {
			fingerprint := strings.TrimSpace(raw)
			if validFingerprint(fingerprint) && fingerprint != "" {
				tls["utls"] = map[string]any{"enabled": true, "fingerprint": fingerprint}
			}
		} else if raw != "" {
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": raw}
		}
	}
	if query.Has("disable_sni") && strings.ReplaceAll(query.Value("disable_sni"), "1", "true") == "true" {
		tls["disable_sni"] = true
	}
}

// profileAnyTLSTLS is AnyTls.parseFromLink's TLS block: Tls.parseFromLink then
// tls.enabled = true, with no QUIC fields.
func profileAnyTLSTLS(link profileParsedLink) (map[string]any, error) {
	original := link
	tls, _, err := profileImportTLS(profileTLSWithoutDisableSNI(link), false, true)
	if err != nil {
		return nil, err
	}
	profileReplayForcedTLSFields(original, tls, true)
	tls["enabled"] = true
	return tls, nil
}

func profileImportTuicLink(link profileParsedLink) (*profileImportedNode, error) {
	// Tuic.parseFromLink reads exactly these keys. A key outside this set is
	// refused: Kotlin would ignore it, but silently ignoring a field a provider
	// meant for TUIC would be worse than asking for the Kotlin path.
	for _, key := range []string{"congestion-controller", "udp-relay-mode", "reduce-rtt", "reduce_rtt",
		"heartbeat-interval", "heartbeat_interval", "disable_mtu_discovery"} {
		if link.Query.Has(key) {
			return nil, profileUnsupported("tuic link field not ported yet: " + key)
		}
	}
	// The QUIC fields are shared with hysteria through QuicFields.parseFromLink;
	// pinning and port hopping have no TUIC equivalent in this slice.
	for _, key := range []string{"pinSHA256", "mport", "hop_interval", "hop_interval_max"} {
		if link.Query.Has(key) {
			return nil, profileUnsupported("tuic link field not ported yet: " + key)
		}
	}
	uuid, password := link.UserInfoPair()
	node := &profileStoredAdvanced{
		Type: "tuic", Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(443), Fields: map[string]any{},
		TLS: map[string]any{}, HasTLS: true,
	}
	if uuid != "" {
		node.Fields["uuid"] = uuid
	}
	if password != "" {
		node.Fields["password"] = password
	}
	if link.Query.Has("congestion_control") {
		if value := tuicCongestion(link.Query.Value("congestion_control")); value != "" {
			node.Fields["congestion_control"] = value
		}
	}
	if link.Query.Has("udp_relay_mode") {
		if value := tuicRelayMode(link.Query.Value("udp_relay_mode")); value != "" {
			node.Fields["udp_relay_mode"] = value
		}
	}
	if link.Query.Has("udp_over_stream") && link.Query.Value("udp_over_stream") == "true" {
		node.Fields["udp_over_stream"] = true
	}
	if link.Query.Has("zero_rtt_handshake") && link.Query.Value("zero_rtt_handshake") == "true" {
		node.Fields["zero_rtt_handshake"] = true
	}
	if link.Query.Has("heartbeat") {
		if value := strings.TrimSpace(link.Query.Value("heartbeat")); configValidDuration(value) != "" {
			node.Fields["heartbeat"] = value
		}
	}
	quic, err := profileImportQUICFields(link)
	if err != nil {
		return nil, err
	}
	for key, value := range quic {
		node.Fields[key] = value
	}
	tls, err := profileTuicTLS(link)
	if err != nil {
		return nil, err
	}
	node.TLS = tls
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

func profileImportAnyTLink(link profileParsedLink) (*profileImportedNode, error) {
	node := &profileStoredAdvanced{
		Type: "anytls", Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(443), Fields: map[string]any{},
		TLS: map[string]any{}, HasTLS: true, AlwaysTLS: true,
	}
	if password := link.UserName; password != "" {
		node.Fields["password"] = password
	}
	node.Fields["idle_session_check_interval"] = "30s"
	node.Fields["idle_session_timeout"] = "30s"
	node.Fields["min_idle_session"] = 5
	if link.Query.Has("idle_session_check_interval") {
		node.Fields["idle_session_check_interval"] = profileAnyTLSDuration(
			"idle_session_check_interval", link.Query.Value("idle_session_check_interval"), "30s")
	}
	if link.Query.Has("idle_session_timeout") {
		node.Fields["idle_session_timeout"] = profileAnyTLSDuration(
			"idle_session_timeout", link.Query.Value("idle_session_timeout"), "30s")
	}
	if link.Query.Has("min_idle_session") {
		value := strings.TrimSpace(link.Query.Value("min_idle_session"))
		if profileAllDigits(value) {
			node.Fields["min_idle_session"] = profileImportQtInt(value)
		}
	}
	tls, err := profileAnyTLSTLS(link)
	if err != nil {
		return nil, err
	}
	node.TLS = tls
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

func profileAllDigits(text string) bool {
	if text == "" {
		return false
	}
	for _, r := range text {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// profileAnyTLSDuration is AnyTls.importDuration: a valid duration is kept
// trimmed, an invalid one leaves the current default in place.
func profileAnyTLSDuration(field, raw, current string) string {
	value := strings.TrimSpace(raw)
	if configValidDuration(value) != "" {
		return value
	}
	return current
}

// tuicCongestion is Tuic.tuicImportCongestion + canonicalTuicCongestion.
func tuicCongestion(raw string) string {
	value := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(raw)), " ", "_")
	switch value {
	case "cubic", "new_reno", "bbr":
		return value
	}
	return ""
}

// tuicRelayMode is Tuic.tuicImportRelayMode + canonicalTuicRelayMode.
func tuicRelayMode(raw string) string {
	mode := strings.ToLower(strings.TrimSpace(raw))
	if mode == "native" || mode == "quic" {
		return mode
	}
	return ""
}

// profileImportQUICFields ports QuicFields.parseFromLink for the keys the
// parity vectors pin. Invalid values keep their Kotlin defaults (dropped).
func profileImportQUICFields(link profileParsedLink) (map[string]any, error) {
	fields := map[string]any{}
	query := link.Query
	if query.Has("quic_idle_timeout") {
		if value := strings.TrimSpace(query.Value("quic_idle_timeout")); configValidDuration(value) != "" {
			fields["idle_timeout"] = value
		}
	}
	if query.Has("quic_keep_alive_period") {
		if value := strings.TrimSpace(query.Value("quic_keep_alive_period")); configValidDuration(value) != "" {
			fields["keep_alive_period"] = value
		}
	}
	for key, stored := range map[string]string{
		"quic_stream_receive_window":     "stream_receive_window",
		"quic_connection_receive_window": "connection_receive_window",
	} {
		if query.Has(key) {
			if value := strings.TrimSpace(query.Value(key)); value != "" && profileValidMemoryBytes(value) {
				fields[stored] = value
			}
		}
	}
	if query.Has("quic_max_concurrent_streams") {
		if value := profileImportQtInt(query.Value("quic_max_concurrent_streams")); value > 0 {
			fields["max_concurrent_streams"] = value
		}
	}
	if query.Has("quic_initial_packet_size") {
		if size := profileImportQtInt(query.Value("quic_initial_packet_size")); size >= 1200 && size <= 1452 {
			fields["initial_packet_size"] = size
		}
	}
	if query.Has("quic_disable_path_mtu_discovery") {
		fields["disable_path_mtu_discovery"] = query.Value("quic_disable_path_mtu_discovery") == "true"
	}
	return fields, nil
}

// profileImportAdvancedDialFields copies DialFields.parseFromLink into the
// advanced node's flat field map. The shared simple-link helper owns the same
// validation rules for the same keys.
func profileImportAdvancedDialFields(link profileParsedLink, node *profileStoredAdvanced) {
	simple := &profileStoredSimple{}
	_ = profileImportDialFields(link, simple)
	if simple.ReuseAddr {
		node.Fields["reuse_addr"] = true
	}
	if simple.ConnectTimeout != "" {
		node.Fields["connect_timeout"] = simple.ConnectTimeout
	}
	if simple.TCPFastOpen {
		node.Fields["tcp_fast_open"] = true
	}
	if simple.TCPMultiPath {
		node.Fields["tcp_multi_path"] = true
	}
	if simple.UDPFragment {
		node.Fields["udp_fragment"] = true
	}
	if simple.BindInterface != "" {
		node.Fields["bind_interface"] = simple.BindInterface
	}
	if simple.Inet4Bind != "" {
		node.Fields["inet4_bind_address"] = simple.Inet4Bind
	}
	if simple.Inet6Bind != "" {
		node.Fields["inet6_bind_address"] = simple.Inet6Bind
	}
}

// --- Clash -----------------------------------------------------------------

// clashTuic is Tuic.parseFromClash. Kotlin refuses a blank uuid (TUIC v4 has
// no uuid) and overrides the server with `ip` when present.
func clashTuic(p clashProxy) (*profileImportedNode, error) {
	if err := clashRejectUnknownFields(p, "tuic", []string{
		"type", "name", "server", "port", "uuid", "password",
		"congestion-controller", "udp-relay-mode", "reduce-rtt", "heartbeat-interval", "ip",
		"tls", "servername", "sni", "alpn", "skip-cert-verify", "fingerprint",
		"client-fingerprint", "reality-opts",
	}); err != nil {
		return nil, err
	}
	name, server, port, err := clashBase(p, "tuic")
	if err != nil {
		return nil, err
	}
	uuid := p.String("uuid")
	if strings.TrimSpace(uuid) == "" {
		return nil, profileUnsupported("clash: tuic v4 has no uuid (not ported yet)")
	}
	fields := map[string]any{"uuid": uuid}
	if password := p.String("password"); password != "" {
		fields["password"] = password
	}
	if congestion := p.String("congestion-controller"); congestion != "" {
		if value := tuicCongestion(congestion); value != "" {
			fields["congestion_control"] = value
		}
	}
	if relay := p.String("udp-relay-mode"); relay != "" {
		if value := tuicRelayMode(relay); value != "" {
			fields["udp_relay_mode"] = value
		}
	}
	if p.Bool("reduce-rtt") {
		fields["zero_rtt_handshake"] = true
	}
	if interval := p.Int("heartbeat-interval"); interval > 0 {
		fields["heartbeat"] = fmt.Sprintf("%dms", interval)
	}
	if ip := strings.TrimSpace(p.String("ip")); ip != "" {
		server = aceShareHost(ip)
	}
	tls, _, err := clashTLS(p, true, true, false)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "tuic", Name: name, Server: server, Port: port, Fields: fields,
		TLS: tls, HasTLS: true,
	}
	return profileAdvancedNode(node)
}

// clashAnyTls is AnyTls.parseFromClash: its intervals are whole seconds.
func clashAnyTls(p clashProxy) (*profileImportedNode, error) {
	if err := clashRejectUnknownFields(p, "anytls", []string{
		"type", "name", "server", "port", "password",
		"idle-session-check-interval", "idle-session-timeout", "min-idle-session",
		"tls", "servername", "sni", "alpn", "skip-cert-verify", "fingerprint",
		"client-fingerprint", "reality-opts",
	}); err != nil {
		return nil, err
	}
	name, server, port, err := clashBase(p, "anytls")
	if err != nil {
		return nil, err
	}
	fields := map[string]any{
		"idle_session_check_interval": "30s",
		"idle_session_timeout":        "30s",
		"min_idle_session":            5,
	}
	if password := p.String("password"); password != "" {
		fields["password"] = password
	}
	if interval := p.Int("idle-session-check-interval"); interval > 0 {
		fields["idle_session_check_interval"] = fmt.Sprintf("%ds", interval)
	}
	if timeout := p.Int("idle-session-timeout"); timeout > 0 {
		fields["idle_session_timeout"] = fmt.Sprintf("%ds", timeout)
	}
	if minIdle := p.Int("min-idle-session"); minIdle > 0 {
		fields["min_idle_session"] = minIdle
	}
	tls, _, err := clashTLS(p, true, true, true)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "anytls", Name: name, Server: server, Port: port, Fields: fields,
		TLS: tls, HasTLS: true,
	}
	return profileAdvancedNode(node)
}

// clashRejectUnknownFields refuses any Clash key the Kotlin parser of one of
// the two new types does not read. The existing advanced converters accept
// unknown keys (Kotlin ignores them too); these two use the stricter contract
// the slice promises for new protocols: no field is ever silently dropped.
func clashRejectUnknownFields(p clashProxy, kind string, allowed []string) error {
	set := make(map[string]bool, len(allowed))
	for _, key := range allowed {
		set[key] = true
	}
	for key := range p.Node {
		if !set[strings.ToLower(strings.TrimSpace(key))] {
			return profileUnsupported(fmt.Sprintf("clash: %s field not ported yet: %s", kind, key))
		}
	}
	return nil
}

// --- stored JSON -----------------------------------------------------------

// profileImportStoredTuicAnyTLS converts a stored outbound object from a
// JSON/SIP008 body into the same node the link/Clash converters emit.
func profileImportStoredTuicAnyTLS(object map[string]any, rawType string) (*profileImportedNode, error) {
	node, unknown, err := profileParseStoredTuicAnyTLS(object, rawType)
	if err != nil {
		return nil, err
	}
	if len(unknown) > 0 {
		return nil, profileUnsupported(fmt.Sprintf("stored %s field not ported yet: %s", rawType, unknown[0]))
	}
	return profileAdvancedNode(node)
}

func profileParseStoredTuicAnyTLS(object map[string]any, rawType string) (node *profileStoredAdvanced, unknown []string, err error) {
	server := configJSONString(object, "server")
	if server == "" {
		return nil, nil, profileUnsupported("stored " + rawType + " has no valid server")
	}
	port := configJSONInt(object["server_port"])
	if port <= 0 {
		return nil, nil, profileUnsupported("stored " + rawType + " has no valid server_port")
	}
	fields := map[string]any{}
	allowed := profileStoredTuicFields
	if rawType == "anytls" {
		allowed = profileStoredAnyTLSFields
	}
	for key := range object {
		switch key {
		case "type", "tag", "server", "server_port", "tls":
			continue
		}
		if !allowed[key] {
			unknown = append(unknown, key)
			continue
		}
		switch value := object[key].(type) {
		case string:
			fields[key] = value
		case bool:
			fields[key] = value
		case int64, float64:
			fields[key] = configJSONInt(value)
		default:
			return nil, nil, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
		}
	}
	if rawType == "tuic" {
		profileNormalizeStoredFlatQUIC(fields)
	}
	if rawType == "anytls" {
		if _, present := fields["tcp_fast_open"]; present {
			return nil, nil, profileUnsupported("stored anytls tcp_fast_open is not supported (Kotlin drops it)")
		}
		// AnyTls.parseFromJson starts from these defaults and only overwrites
		// them when the stored key is present.
		if _, present := fields["idle_session_check_interval"]; !present {
			fields["idle_session_check_interval"] = "30s"
		}
		if _, present := fields["idle_session_timeout"]; !present {
			fields["idle_session_timeout"] = "30s"
		}
		if _, present := fields["min_idle_session"]; !present {
			fields["min_idle_session"] = 5
		}
	}
	node = &profileStoredAdvanced{
		Type: rawType, Name: configJSONString(object, "tag"),
		Server: aceShareHost(server), Port: port, Fields: fields,
		TLS: map[string]any{}, HasTLS: true,
	}
	if value, present := object["tls"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored tls block is not an object")
		}
		for key := range block {
			if !profileStoredTLSKeys[key] && key != "disable_sni" {
				unknown = append(unknown, "tls."+key)
			}
		}
		profileNormalizeStoredTLSBlock(block)
		node.TLS = block
		node.HasTLS = true
	}
	return node, unknown, nil
}
