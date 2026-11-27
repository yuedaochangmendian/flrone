// Outbound parsing and chain construction for the config builder.
//
// The builder supports the TCP proxy types (shadowsocks, socks, http, vmess,
// vless, trojan), the QUIC type (hysteria / hysteria2), wireguard as a sing-box
// endpoint, the built-in WARP hop (wireguard/amnezia/masque, see
// config_build_warp.go), `custom` as a raw outbound or a full config
// (config_build_custom.go), and direct / chain. Every other profile type and
// every stored field these builders do not reproduce is a hard error, never a
// silently dropped key: a config that differs from the Kotlin generator must
// fail the build, not start with missing options.
package mobile

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

const (
	tagProxy      = "proxy"
	tagDirect     = "direct"
	tagWarpBypass = "warp-bypass"

	tagDNSRemote = "dns-remote"
	tagDNSDirect = "dns-direct"
	tagDNSLocal  = "dns-local"
	tagDNSFake   = "dns-fake"
	tagDNSHosts  = "dns-hosts"

	tagDNSEchPrefix = "dns-ech"

	tagDNSIn   = "dns-in"
	tagMixedIn = "mixed-in"
	tagTunIn   = "tun-in"

	tagMainChainPrefix  = "config"
	tagRouteChainPrefix = "route"
)

func configHopTag(prefix string, index int) string {
	return prefix + "-" + strconv.Itoa(index)
}

// configDialFields is DialFields: the eight dial keys every outbound build
// emits before its own fields.
type configDialFields struct {
	reuseAddr        bool
	connectTimeout   string
	tcpFastOpen      bool
	tcpMultiPath     bool
	udpFragment      bool
	bindInterface    string
	inet4BindAddress string
	inet6BindAddress string
}

func configParseDialFields(object map[string]any) configDialFields {
	return configDialFields{
		reuseAddr:        configJSONBool(object, "reuse_addr"),
		connectTimeout:   strings.TrimSpace(configJSONString(object, "connect_timeout")),
		tcpFastOpen:      configJSONBool(object, "tcp_fast_open"),
		tcpMultiPath:     configJSONBool(object, "tcp_multi_path"),
		udpFragment:      configJSONBool(object, "udp_fragment"),
		bindInterface:    configJSONString(object, "bind_interface"),
		inet4BindAddress: strings.TrimSpace(configJSONString(object, "inet4_bind_address")),
		inet6BindAddress: strings.TrimSpace(configJSONString(object, "inet6_bind_address")),
	}
}

func (dial configDialFields) apply(target map[string]any) {
	if dial.reuseAddr {
		target["reuse_addr"] = true
	}
	if dial.connectTimeout != "" {
		target["connect_timeout"] = dial.connectTimeout
	}
	if dial.tcpFastOpen {
		target["tcp_fast_open"] = true
	}
	if dial.tcpMultiPath {
		target["tcp_multi_path"] = true
	}
	if dial.udpFragment {
		target["udp_fragment"] = true
	}
	if dial.bindInterface != "" {
		target["bind_interface"] = dial.bindInterface
	}
	if dial.inet4BindAddress != "" {
		target["inet4_bind_address"] = dial.inet4BindAddress
	}
	if dial.inet6BindAddress != "" {
		target["inet6_bind_address"] = dial.inet6BindAddress
	}
}

var configDialKeys = map[string]bool{
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true, "tcp_multi_path": true,
	"udp_fragment": true, "bind_interface": true, "inet4_bind_address": true, "inet6_bind_address": true,
}

// configOutbound is the parsed form of one profiles.json row. The generator
// needs the chain hop ids and each type's build fields; anything else is
// refused rather than approximated. params is one of the per-type structs in
// config_build_protocols.go (or configShadowsocksParams for shadowsocks).
type configOutbound struct {
	id          int64
	profileType string
	name        string

	server     string
	serverPort int
	dial       configDialFields

	hops []int64

	params any
}

// configShadowsocksParams is the Stage-1 shadowsocks subset.
type configShadowsocksParams struct {
	method     string
	password   string
	plugin     string
	pluginOpts string
	uot        bool
	muxEnabled bool
}

func configJSONNumber(value any) float64 {
	switch typed := value.(type) {
	case float64:
		return typed
	case json.Number:
		parsed, _ := typed.Float64()
		return parsed
	case int:
		return float64(typed)
	case int64:
		return float64(typed)
	}
	return 0
}

// configJSONInt is JsonObject.int / QJsonValue::toInt: only whole numbers that
// fit an int, anything else is 0.
func configJSONInt(value any) int {
	number := configJSONNumber(value)
	if number != float64(int64(number)) || number < -2147483648 || number > 2147483647 {
		return 0
	}
	return int(number)
}

// configJSONInteger is JsonValues.toInteger: whole numbers that fit a qint64.
func configJSONInteger(value any) int64 {
	number := configJSONNumber(value)
	if number != float64(int64(number)) {
		return 0
	}
	return int64(number)
}

func configJSONString(object map[string]any, key string) string {
	value, _ := object[key].(string)
	return value
}

func configJSONBool(object map[string]any, key string) bool {
	value, _ := object[key].(bool)
	return value
}

// configCanonicalOutboundType is OutboundFactory.canonicalType for the alias
// this builder needs to resolve: `openvpn-client` is both a stored row type and
// the type build() emits, and Kotlin's factory maps it to `openvpn`. The
// hysteria2 alias is deliberately NOT canonicalised here: this builder keeps
// hysteria and hysteria2 as separate parser versions.
func configCanonicalOutboundType(profileType string) string {
	if profileType == "openvpn-client" {
		return "openvpn"
	}
	return profileType
}

// configOutboundTypeKeys is the per-type key set ParseFromJson reads (on top of
// configCommonOutboundKeys and the QUIC flat keys for hysteria).
func configOutboundTypeKeys(profileType string) []string {
	switch profileType {
	case "shadowsocks":
		return []string{"server", "server_port", "method", "password", "plugin", "plugin_opts", "udp_over_tcp", "multiplex"}
	case "http":
		return []string{"server", "server_port", "username", "password", "path", "headers", "tls"}
	case "socks":
		return []string{"server", "server_port", "username", "password", "version", "uot", "udp_over_tcp"}
	case "vmess":
		return []string{
			"server", "server_port", "uuid", "security", "alter_id", "alter-id", "global_padding",
			"global-padding", "authenticated_length", "packet_encoding", "tls", "transport", "multiplex",
		}
	case "vless":
		return []string{
			"server", "server_port", "uuid", "flow", "encryption", "packet_encoding", "tls", "transport", "multiplex",
		}
	case "trojan":
		return []string{"server", "server_port", "password", "tls", "transport", "multiplex"}
	case "hysteria", "hysteria2":
		return []string{
			"server", "server_port", "server_ports", "hop_interval", "up_mbps", "down_mbps", "obfs", "up", "down",
			"auth", "auth_str", "recv_window_conn", "recv_window", "disable_mtu_discovery", "obfsPassword",
			"password", "hop_interval_max", "bbr_profile", "disable_chrome_parrot", "realm", "tls",
			"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window",
			"max_concurrent_streams", "initial_packet_size", "disable_path_mtu_discovery",
		}
	case "wireguard":
		return []string{
			"private_key", "peers", "address", "mtu", "system", "workers", "worker_count", "udp_timeout", "amnezia_wg",
		}
	case "tuic":
		return []string{
			"server", "server_port", "uuid", "password", "congestion_control", "udp_relay_mode",
			"udp_over_stream", "zero_rtt_handshake", "heartbeat", "tls",
			"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window",
			"max_concurrent_streams", "initial_packet_size", "disable_path_mtu_discovery",
		}
	case "juicity":
		return []string{"server", "server_port", "uuid", "password", "tls"}
	case "anytls":
		return []string{
			"server", "server_port", "password", "idle_session_check_interval",
			"idle_session_timeout", "min_idle_session", "tls",
		}
	case "shadowtls":
		return []string{"server", "server_port", "version", "password", "tls"}
	case "snell":
		return []string{
			"server", "server_port", "version", "psk", "userkey", "reuse", "network",
			"obfs_mode", "obfs_host", "mode",
		}
	case "ssh":
		return []string{
			"server", "server_port", "user", "password", "private_key", "private_key_path",
			"private_key_passphrase", "host_key", "host_key_algorithms", "client_version",
		}
	case "mieru":
		return []string{
			"server", "server_port", "transport", "username", "password", "multiplexing",
			"traffic_pattern", "server_ports",
		}
	case "trusttunnel":
		return []string{
			"server", "server_port", "username", "password", "health_check", "quic",
			"quic_congestion_control", "custom_sni", "client_random", "tls",
		}
	case "masque":
		return []string{
			"server", "server_port", "private_key", "peer_public_key", "address", "mtu",
			"http_version", "disable_version_fallback", "tls",
			"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window",
			"max_concurrent_streams", "initial_packet_size", "disable_path_mtu_discovery",
		}
	case "naive":
		return []string{
			"server", "server_port", "username", "password", "insecure_concurrency",
			"extra_headers", "udp_over_tcp", "quic", "quic_congestion_control", "tls",
		}
	case "openvpn", "openvpn-client":
		return []string{
			"server", "server_port", "servers", "remote_random", "mode", "network",
			"address", "peer_address", "peer_address_ipv6", "topology", "username",
			"password", "auth_retry", "static_challenge", "static_challenge_echo",
			"static_key", "static_key_path", "key_direction", "tls", "cipher",
			"data_ciphers", "data_ciphers_fallback", "auth", "mss_fix", "mss_fix_disabled",
			"mss_fix_mode", "fragment", "replay_window", "replay_window_time",
			"compression", "compression_lzo", "allow_compression", "route_no_pull",
			"pull_filters", "routes", "route_gateway", "route_metric", "redirect_gateway",
			"redirect_gateway_flags", "redirect_private", "block_ipv6", "ping_interval",
			"ping_restart", "ping_restart_disabled", "renegotiate_interval",
			"renegotiate_disabled", "renegotiate_bytes", "renegotiate_packets",
			"tls_timeout", "handshake_window", "explicit_exit_notify", "system", "name",
			"mtu", "udp_timeout", "udp_mapping", "udp_filtering", "udp_nat_max",
			"otp_profile_id", "only_advertised_routes", "tunnel_dns",
			"block_outside_dns", "use_tunnel_dns",
		}
	case "openconnect":
		return []string{
			"server", "server_port", "server_path", "flavor", "username", "password", "auth_group", "cookie",
			"token", "reported_os", "user_agent", "version", "local_hostname", "mobile", "csd", "hip", "tncc",
			"fortinet_host_check", "no_udp", "dtls_local_port", "compression_disabled", "compression_mode",
			"ipv6_disabled", "http_keepalive_disabled", "xml_post_disabled", "external_auth_disabled",
			"password_authentication_disabled", "tcp_keep_alive_enabled", "pfs", "mtu", "base_mtu", "dpd_interval",
			"reconnect_timeout", "trojan_interval", "queue_length", "allow_insecure_crypto", "tls", "form_entries",
			"system", "name", "udp_timeout", "udp_mapping", "udp_filtering", "udp_nat_max",
			"otp_profile_id", "only_advertised_routes", "tunnel_dns", "block_outside_dns", "use_tunnel_dns",
		}
	}
	return nil
}

// configParseOutboundJSON loads one stored outbound object. Unknown keys are an
// error so a field the builder does not reproduce cannot silently vanish.
func configParseOutboundJSON(profile simpleConfigProfile) (configOutbound, error) {
	outbound := configOutbound{id: profile.ID, profileType: profile.Type}
	text := strings.TrimSpace(profile.OutboundJSON)
	if text == "" || text == "{}" {
		return outbound, fmt.Errorf("profile %d has no outbound JSON", profile.ID)
	}
	var object map[string]any
	if err := json.Unmarshal([]byte(text), &object); err != nil {
		return outbound, fmt.Errorf("profile %d outbound JSON: %w", profile.ID, err)
	}
	if len(object) == 0 {
		return outbound, fmt.Errorf("profile %d has an empty outbound JSON", profile.ID)
	}
	parsedType := configJSONString(object, "type")
	if parsedType == "" {
		parsedType = profile.Type
	}
	// OutboundFactory.canonicalType resolves the two stored aliases before the
	// factory picks a class; the row type and the JSON type may differ by alias.
	canonicalType := configCanonicalOutboundType(parsedType)
	canonicalRowType := configCanonicalOutboundType(profile.Type)
	if profile.Type != "" && canonicalRowType != canonicalType {
		return outbound, fmt.Errorf("profile %d row type %q does not match its outbound JSON type %q",
			profile.ID, profile.Type, parsedType)
	}
	outbound.profileType = canonicalType

	if parsedType == "chain" {
		if err := configCheckKeys(object, configKeysAllowed("type", "name", "list"), fmt.Sprintf("profile %d (chain)", profile.ID)); err != nil {
			return outbound, err
		}
		outbound.name = configJSONString(object, "name")
		outbound.hops = make([]int64, 0)
		if list, present := object["list"]; present {
			items, ok := list.([]any)
			if !ok {
				return outbound, fmt.Errorf("profile %d chain list is not an array", profile.ID)
			}
			for _, item := range items {
				outbound.hops = append(outbound.hops, configJSONInteger(item))
			}
		}
		return outbound, nil
	}
	if parsedType == "custom" {
		// Custom.parseFromJson reads name/subtype/config only: no base fields, no
		// dial fields, and no server (the config text carries them).
		if err := configCheckKeys(object, configKeysAllowed("type", "name", "subtype", "config"),
			fmt.Sprintf("profile %d (custom)", profile.ID)); err != nil {
			return outbound, err
		}
		outbound.name = configJSONString(object, "name")
		outbound.params = configParseCustom(object)
		return outbound, nil
	}
	if parsedType != "direct" && configOutboundTypeKeys(parsedType) == nil {
		return outbound, fmt.Errorf("profile %d has type %q, which the Go config builder does not support",
			profile.ID, parsedType)
	}

	allowed := configKeysAllowed(configCommonOutboundKeys()...)
	configSetKeys(allowed, configOutboundTypeKeys(parsedType)...)
	if err := configCheckKeys(object, allowed,
		fmt.Sprintf("profile %d (%s)", profile.ID, parsedType)); err != nil {
		return outbound, err
	}

	if parsedType == "direct" {
		if tag := configJSONString(object, "tag"); tag != "" {
			outbound.name = tag
		}
		outbound.dial = configParseDialFields(object)
		return outbound, nil
	}

	if tag := configJSONString(object, "tag"); tag != "" {
		outbound.name = tag
	}
	if server := configJSONString(object, "server"); server != "" {
		outbound.server = configACEHost(server)
	}
	outbound.serverPort = configJSONInt(object["server_port"])
	// Masque.init sets the endpoint's default port before ParseFromJson runs.
	if parsedType == "masque" && outbound.serverPort == 0 {
		outbound.serverPort = 443
	}
	outbound.dial = configParseDialFields(object)

	params, err := configParseOutboundParams(parsedType, object)
	if err != nil {
		return outbound, fmt.Errorf("profile %d (%s): %w", profile.ID, parsedType, err)
	}
	outbound.params = params
	return outbound, nil
}

// configParseOutboundParams dispatches the per-type ParseFromJson.
func configParseOutboundParams(profileType string, object map[string]any) (any, error) {
	switch profileType {
	case "shadowsocks":
		params := configShadowsocksParams{
			method:     configJSONString(object, "method"),
			password:   configJSONString(object, "password"),
			plugin:     configJSONString(object, "plugin"),
			pluginOpts: configJSONString(object, "plugin_opts"),
		}
		if value, present := object["udp_over_tcp"]; present {
			if boolean, ok := value.(bool); ok {
				params.uot = boolean
			} else if nested := configJSONObjectValue(value); nested != nil {
				params.uot = configJSONBoolValue(nested["enabled"])
			}
		}
		if nested := configJSONObjectValue(object["multiplex"]); nested != nil {
			// Multiplex.parseFromJson: an object without `enabled` stays
			// unspecified (Keep Default); enabled=true is refused by the build.
			params.muxEnabled = configJSONBoolValue(nested["enabled"])
		}
		return params, nil
	case "http":
		return configParseHTTP(object)
	case "socks":
		return configParseSocks(object)
	case "vmess":
		return configParseVMess(object)
	case "vless":
		return configParseVless(object)
	case "trojan":
		return configParseTrojan(object)
	case "hysteria":
		return configParseHysteria(object, 1)
	case "hysteria2":
		return configParseHysteria(object, 2)
	case "wireguard":
		return configParseWireGuard(object)
	case "tuic":
		return configParseTuic(object)
	case "juicity":
		return configParseJuicity(object)
	case "anytls":
		return configParseAnyTLS(object)
	case "shadowtls":
		return configParseShadowTLS(object)
	case "snell":
		return configParseSnell(object)
	case "ssh":
		return configParseSSH(object)
	case "mieru":
		return configParseMieru(object)
	case "trusttunnel":
		return configParseTrustTunnel(object)
	case "masque":
		return configParseMasque(object)
	case "naive":
		return configParseNaive(object)
	case "openvpn", "openvpn-client":
		return configParseOpenVPN(object)
	case "openconnect":
		return configOCParseOpenConnect(object)
	}
	return nil, fmt.Errorf("profile type %q is not supported by the Stage-2 Go config builder", profileType)
}

// configOutboundIsEndpoint is Outbound.isEndpoint.
func configOutboundIsEndpoint(outbound configOutbound) bool {
	switch outbound.profileType {
	case "wireguard", "masque", "openvpn", "openconnect":
		return true
	case "custom":
		params, ok := outbound.params.(configCustomParams)
		return ok && params.isEndpoint()
	}
	return false
}

// configOutboundIsCustomFullConfig is TypeAccess.isCustomFullConfig: a full
// config cannot be a chain hop or a route outbound.
func configOutboundIsCustomFullConfig(outbound configOutbound) bool {
	params, ok := outbound.params.(configCustomParams)
	return ok && params.isFullConfig()
}

// configOutboundRealmActive is Hysteria.realmActive.
func configOutboundRealmActive(outbound configOutbound) bool {
	params, ok := outbound.params.(configHysteriaParams)
	return ok && params.realmActive()
}

// configOutboundResolvesViaDNSRules is resolvesHostnamesViaDnsRules: endpoints
// and plain SOCKS4 cannot resolve names themselves.
func configOutboundResolvesViaDNSRules(outbound configOutbound) bool {
	if configOutboundIsEndpoint(outbound) {
		return true
	}
	if params, ok := outbound.params.(configSocksParams); ok {
		return params.version == 4 && !params.socks4a
	}
	return false
}

// configOutboundTLS is Outbound.hasTls / getTls for the types this builder
// supports: http, vmess, vless, trojan and hysteria carry a `tls` object.
func configOutboundTLS(outbound configOutbound) (configTLSParams, bool) {
	switch params := outbound.params.(type) {
	case configHTTPParams:
		return params.tls, true
	case configVMessParams:
		return params.tls, true
	case configVlessParams:
		return params.tls, true
	case configTrojanParams:
		return params.tls, true
	case configHysteriaParams:
		return params.tls, true
	}
	return configTLSParams{}, false
}

// configBuildOutbound is Outbound.build for the supported types.
func configBuildOutbound(outbound configOutbound, settings simpleConfigSettings) (map[string]any, error) {
	switch outbound.profileType {
	case "shadowsocks":
		params, ok := outbound.params.(configShadowsocksParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no shadowsocks fields", outbound.id)
		}
		if settings.MuxDefaultOn || params.muxEnabled {
			return nil, fmt.Errorf("multiplex is on; the Go config builder does not build the shadowsocks mux preset")
		}
		return configBuildShadowsocks(outbound, params), nil
	case "direct":
		return configBuildDirect(outbound), nil
	case "http":
		params, ok := outbound.params.(configHTTPParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no http fields", outbound.id)
		}
		return configBuildHTTP(outbound, params, settings)
	case "socks":
		params, ok := outbound.params.(configSocksParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no socks fields", outbound.id)
		}
		return configBuildSocks(outbound, params, settings)
	case "vmess":
		params, ok := outbound.params.(configVMessParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no vmess fields", outbound.id)
		}
		return configBuildVMess(outbound, params, settings)
	case "vless":
		params, ok := outbound.params.(configVlessParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no vless fields", outbound.id)
		}
		return configBuildVless(outbound, params, settings)
	case "trojan":
		params, ok := outbound.params.(configTrojanParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no trojan fields", outbound.id)
		}
		return configBuildTrojan(outbound, params, settings)
	case "hysteria", "hysteria2":
		params, ok := outbound.params.(configHysteriaParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no hysteria fields", outbound.id)
		}
		return configBuildHysteria(outbound, params, settings)
	case "wireguard":
		params, ok := outbound.params.(configWireGuardParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no wireguard fields", outbound.id)
		}
		return configBuildWireGuard(outbound, params, settings)
	case "tuic":
		params, ok := outbound.params.(configTuicParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no tuic fields", outbound.id)
		}
		return configBuildTuic(outbound, params, settings)
	case "juicity":
		params, ok := outbound.params.(configJuicityParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no juicity fields", outbound.id)
		}
		return configBuildJuicity(outbound, params, settings)
	case "anytls":
		params, ok := outbound.params.(configAnyTLSParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no anytls fields", outbound.id)
		}
		return configBuildAnyTLS(outbound, params, settings)
	case "shadowtls":
		params, ok := outbound.params.(configShadowTLSParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no shadowtls fields", outbound.id)
		}
		return configBuildShadowTLS(outbound, params, settings)
	case "snell":
		params, ok := outbound.params.(configSnellParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no snell fields", outbound.id)
		}
		return configBuildSnell(outbound, params, settings)
	case "ssh":
		params, ok := outbound.params.(configSSHParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no ssh fields", outbound.id)
		}
		return configBuildSSH(outbound, params, settings)
	case "mieru":
		params, ok := outbound.params.(configMieruParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no mieru fields", outbound.id)
		}
		return configBuildMieru(outbound, params, settings)
	case "trusttunnel":
		params, ok := outbound.params.(configTrustTunnelParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no trusttunnel fields", outbound.id)
		}
		return configBuildTrustTunnel(outbound, params, settings)
	case "naive":
		params, ok := outbound.params.(configNaiveParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no naive fields", outbound.id)
		}
		return configBuildNaive(outbound, params, settings)
	case "masque":
		// Only the built-in WARP hop builds a masque endpoint; a stored masque
		// profile is refused before this point.
		params, ok := outbound.params.(configMasqueParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no masque fields", outbound.id)
		}
		return configBuildMasque(outbound, params, settings)
	case "openvpn", "openvpn-client":
		params, ok := outbound.params.(configOpenVPNParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no openvpn fields", outbound.id)
		}
		return configBuildOpenVPN(outbound, params)
	case "openconnect":
		params, ok := outbound.params.(configOpenConnectParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no openconnect fields", outbound.id)
		}
		return configBuildOpenConnect(outbound, params), nil
	case "custom":
		params, ok := outbound.params.(configCustomParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no custom fields", outbound.id)
		}
		return params.buildObject(), nil
	case "chain":
		return nil, fmt.Errorf("a chain profile cannot be built as an outbound; its hops are expanded")
	default:
		return nil, fmt.Errorf("profile type %q is not supported by the Go config builder", outbound.profileType)
	}
}

func configBuildDirect(outbound configOutbound) map[string]any {
	object := map[string]any{"type": "direct"}
	outbound.dial.apply(object)
	return object
}

func configBuildShadowsocks(outbound configOutbound, params configShadowsocksParams) map[string]any {
	plugin := params.plugin
	pluginOpts := params.pluginOpts
	if strings.Contains(plugin, ";") {
		pluginOpts = configSubstringAfter(plugin, ";")
		plugin = configSubstringBefore(plugin, ";")
	}
	object := map[string]any{"type": "shadowsocks"}
	if outbound.server != "" {
		object["server"] = outbound.server
	}
	if outbound.serverPort > 0 {
		object["server_port"] = outbound.serverPort
	}
	outbound.dial.apply(object)
	if params.method != "" {
		object["method"] = params.method
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if plugin != "" {
		object["plugin"] = plugin
	}
	if pluginOpts != "" {
		object["plugin_opts"] = pluginOpts
	}
	if params.uot {
		object["udp_over_tcp"] = true
	}
	return object
}

// configSubstringBefore/After are QtStrings.substrBefore/After: the whole string
// when the separator is absent.
func configSubstringBefore(text, separator string) string {
	if index := strings.Index(text, separator); index >= 0 {
		return text[:index]
	}
	return text
}

func configSubstringAfter(text, separator string) string {
	if index := strings.Index(text, separator); index >= 0 {
		return text[index+len(separator):]
	}
	return text
}

// configFindProfile resolves one profiles.json row by id.
func configFindProfile(profiles []simpleConfigProfile, id int64) *simpleConfigProfile {
	for index := range profiles {
		if profiles[index].ID == id {
			return &profiles[index]
		}
	}
	return nil
}

// configHopOrigin is ChainBuilder.HopOrigin: what a missing hop must name so
// the user knows which chain or group still points at a deleted profile.
type configHopOrigin struct {
	profileName string
	profileHops []int64
	groupName   string
	landingID   int64
	frontID     int64
}

// configMissingHopError is ChainBuilder.missingHopError.
func configMissingHopError(id int64, origin *configHopOrigin) error {
	if origin != nil {
		for _, hopID := range origin.profileHops {
			if hopID == id {
				return fmt.Errorf("Chain %q has a hop (profile id %d) that no longer exists, edit the chain to remove it",
					origin.profileName, id)
			}
		}
		// The front proxy is named first, exactly like the Kotlin loop.
		if origin.frontID == id {
			return fmt.Errorf("Group %q has a front proxy that has been deleted.", origin.groupName)
		}
		if origin.landingID == id {
			return fmt.Errorf("Group %q has a landing proxy that has been deleted.", origin.groupName)
		}
	}
	return fmt.Errorf("A proxy in the chain can no longer be found.")
}

// configBuildChain is ChainBuilder.buildOutboundChain for a resolved hop list
// (exit first). It returns the ingress tag. Endpoints go to the endpoints list
// like ChainBuilder.buildSingboxChain, and a hop whose next hop resolves names
// through DNS rules carries directDomainResolver.
//
// hop id configWarpProfileID resolves to the built-in WARP endpoint. With
// warpWrap hop 0 is WARP as `proxy` and hop 1 takes `warp-bypass` (the tag rules
// name to skip WARP), and WARP always dials through it.
//
// [reads] records every hop that resolves to a stored profile, which is where
// ChainBuilder.resolveHops reads them; the WARP pseudo hop is not a profile and
// is never recorded.
func configBuildChain(
	profiles []simpleConfigProfile, settings simpleConfigSettings, hops []int64,
	prefix string, includeProxy bool, link bool, warpWrap bool, startSuffix int,
	outbounds *[]any, endpoints *[]any, directStrategy string, collectECH func(configOutbound),
	origin *configHopOrigin, reads *configProfileReads,
) (string, error) {
	ingress := configHopTag(prefix, startSuffix)
	if includeProxy {
		ingress = tagProxy
	}
	resolved := make([]configOutbound, 0, len(hops))
	hasCustomFullConfig := false
	for _, id := range hops {
		if id == configWarpProfileID {
			if !settings.EnableWarp {
				return ingress, configMissingHopError(id, origin)
			}
			resolved = append(resolved, configWarpOutbound(settings))
			continue
		}
		profile := configFindProfile(profiles, id)
		if profile == nil {
			return ingress, configMissingHopError(id, origin)
		}
		reads.record(id)
		outbound, err := configParseOutboundJSON(*profile)
		if err != nil {
			return ingress, err
		}
		if outbound.profileType == "chain" {
			return ingress, fmt.Errorf("Chain in Chain is not allowed")
		}
		if outbound.profileType == "autoselector" {
			return ingress, fmt.Errorf("An auto selector cannot be used as a hop; it is not a fixed server")
		}
		if configOutboundIsCustomFullConfig(outbound) {
			hasCustomFullConfig = true
		}
		resolved = append(resolved, outbound)
	}
	if hasCustomFullConfig {
		return ingress, fmt.Errorf("Custom full config profiles cannot be used in a chain; only custom outbound profiles are chainable")
	}
	for index, outbound := range resolved {
		tag := configHopTag(prefix, startSuffix+index)
		nextTag := ""
		if index < len(resolved)-1 {
			nextTag = configHopTag(prefix, startSuffix+index+1)
		}
		if includeProxy && index == 0 {
			tag = tagProxy
		}
		if warpWrap && index == 1 {
			tag = tagWarpBypass
		}
		object, err := configBuildOutbound(outbound, settings)
		if err != nil {
			return ingress, err
		}
		object["tag"] = tag
		if collectECH != nil {
			collectECH(outbound)
		}
		if configOutboundRealmActive(outbound) {
			object["domain_resolver"] = map[string]any{"server": tagDNSDirect}
		}
		if nextTag != "" && link {
			object["detour"] = nextTag
		}
		if warpWrap && index == 0 {
			object["detour"] = tagWarpBypass
		}
		_, hasResolver := object["domain_resolver"]
		if nextTag != "" && link && !configOutboundIsEndpoint(outbound) && !hasResolver &&
			configOutboundResolvesViaDNSRules(resolved[index+1]) {
			object["domain_resolver"] = map[string]any{"server": tagDNSDirect, "strategy": directStrategy}
		}
		if configOutboundIsEndpoint(outbound) {
			*endpoints = append(*endpoints, object)
		} else {
			*outbounds = append(*outbounds, object)
		}
	}
	return ingress, nil
}

// configUnwrapChain is ChainBuilder.unwrapChain: the hop ids exit first, i.e.
// the stored in -> out list reversed.
func configUnwrapChain(profile configOutbound) []int64 {
	if profile.profileType != "chain" {
		return []int64{profile.id}
	}
	reversed := make([]int64, 0, len(profile.hops))
	for index := len(profile.hops) - 1; index >= 0; index-- {
		reversed = append(reversed, profile.hops[index])
	}
	return reversed
}
