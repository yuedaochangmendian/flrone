// The per-type registry of the config builder: one entry per stored outbound
// type with its accepted key set, ParseFromJson adapter and Build adapter.
//
// The builder's dispatch, the test-config skip list and the coverage test read
// this table instead of maintaining parallel switches. Types whose parse/build
// happen before the table (direct, custom, chain, autoselector) stay in
// config_build_outbound.go.
package mobile

import "fmt"

type configOutboundSpec struct {
	keys  []string
	parse func(map[string]any) (any, error)
	build func(configOutbound, any, simpleConfigSettings) (map[string]any, error)
}

// configOutboundSpecFor resolves the factory string to a spec. The
// `openvpn-client` alias is the only stored value that needs canonicalising
// here; hysteria2 keeps its own parser entry because it selects version 2.
func configOutboundSpecFor(profileType string) (configOutboundSpec, bool) {
	if profileType == "openvpn-client" {
		profileType = "openvpn"
	}
	spec, ok := configOutboundSpecs[profileType]
	return spec, ok
}

var configOutboundSpecs = map[string]configOutboundSpec{
	"shadowsocks": {
		keys: []string{"server", "server_port", "method", "password", "plugin", "plugin_opts", "udp_over_tcp", "multiplex"},
		parse: func(object map[string]any) (any, error) {
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
				params.muxEnabled = configJSONBoolValue(nested["enabled"])
			}
			return params, nil
		},
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configShadowsocksParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no shadowsocks fields", out.id)
			}
			return configBuildShadowsocks(out, typed), nil
		},
	},
	"http": {
		keys:  []string{"server", "server_port", "username", "password", "path", "headers", "tls"},
		parse: func(object map[string]any) (any, error) { return configParseHTTP(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configHTTPParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no http fields", out.id)
			}
			return configBuildHTTP(out, typed, settings)
		},
	},
	"socks": {
		keys:  []string{"server", "server_port", "username", "password", "version", "uot", "udp_over_tcp"},
		parse: func(object map[string]any) (any, error) { return configParseSocks(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configSocksParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no socks fields", out.id)
			}
			return configBuildSocks(out, typed, settings)
		},
	},
	"vmess": {
		keys: []string{
			"server", "server_port", "uuid", "security", "alter_id", "alter-id", "global_padding",
			"global-padding", "authenticated_length", "packet_encoding", "tls", "transport", "multiplex",
		},
		parse: func(object map[string]any) (any, error) { return configParseVMess(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configVMessParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no vmess fields", out.id)
			}
			return configBuildVMess(out, typed, settings)
		},
	},
	"vless": {
		keys: []string{
			"server", "server_port", "uuid", "flow", "encryption", "packet_encoding", "tls", "transport", "multiplex",
		},
		parse: func(object map[string]any) (any, error) { return configParseVless(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configVlessParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no vless fields", out.id)
			}
			return configBuildVless(out, typed, settings)
		},
	},
	"trojan": {
		keys:  []string{"server", "server_port", "password", "tls", "transport", "multiplex"},
		parse: func(object map[string]any) (any, error) { return configParseTrojan(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configTrojanParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no trojan fields", out.id)
			}
			return configBuildTrojan(out, typed, settings)
		},
	},
	"hysteria": {
		keys: []string{
			"server", "server_port", "server_ports", "hop_interval", "up_mbps", "down_mbps", "obfs", "up", "down",
			"auth", "auth_str", "recv_window_conn", "recv_window", "disable_mtu_discovery", "obfsPassword",
			"password", "hop_interval_max", "bbr_profile", "disable_chrome_parrot", "realm", "tls",
			"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window",
			"max_concurrent_streams", "initial_packet_size", "disable_path_mtu_discovery",
		},
		parse: func(object map[string]any) (any, error) { return configParseHysteria(object, 1) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configHysteriaParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no hysteria fields", out.id)
			}
			return configBuildHysteria(out, typed, settings)
		},
	},
	"hysteria2": {
		keys: []string{
			"server", "server_port", "server_ports", "hop_interval", "up_mbps", "down_mbps", "obfs", "up", "down",
			"auth", "auth_str", "recv_window_conn", "recv_window", "disable_mtu_discovery", "obfsPassword",
			"password", "hop_interval_max", "bbr_profile", "disable_chrome_parrot", "realm", "tls",
			"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window",
			"max_concurrent_streams", "initial_packet_size", "disable_path_mtu_discovery",
		},
		parse: func(object map[string]any) (any, error) { return configParseHysteria(object, 2) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configHysteriaParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no hysteria fields", out.id)
			}
			return configBuildHysteria(out, typed, settings)
		},
	},
	"wireguard": {
		keys: []string{
			"private_key", "peers", "address", "mtu", "system", "workers", "worker_count", "udp_timeout", "amnezia_wg",
		},
		parse: func(object map[string]any) (any, error) { return configParseWireGuard(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configWireGuardParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no wireguard fields", out.id)
			}
			return configBuildWireGuard(out, typed, settings)
		},
	},
	"tuic": {
		keys: []string{
			"server", "server_port", "uuid", "password", "congestion_control", "udp_relay_mode",
			"udp_over_stream", "zero_rtt_handshake", "heartbeat", "tls",
			"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window",
			"max_concurrent_streams", "initial_packet_size", "disable_path_mtu_discovery",
		},
		parse: func(object map[string]any) (any, error) { return configParseTuic(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configTuicParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no tuic fields", out.id)
			}
			return configBuildTuic(out, typed, settings)
		},
	},
	"juicity": {
		keys:  []string{"server", "server_port", "uuid", "password", "tls"},
		parse: func(object map[string]any) (any, error) { return configParseJuicity(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configJuicityParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no juicity fields", out.id)
			}
			return configBuildJuicity(out, typed, settings)
		},
	},
	"anytls": {
		keys: []string{
			"server", "server_port", "password", "idle_session_check_interval",
			"idle_session_timeout", "min_idle_session", "tls",
		},
		parse: func(object map[string]any) (any, error) { return configParseAnyTLS(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configAnyTLSParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no anytls fields", out.id)
			}
			return configBuildAnyTLS(out, typed, settings)
		},
	},
	"shadowtls": {
		keys:  []string{"server", "server_port", "version", "password", "tls"},
		parse: func(object map[string]any) (any, error) { return configParseShadowTLS(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configShadowTLSParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no shadowtls fields", out.id)
			}
			return configBuildShadowTLS(out, typed, settings)
		},
	},
	"snell": {
		keys: []string{
			"server", "server_port", "version", "psk", "userkey", "reuse", "network",
			"obfs_mode", "obfs_host", "mode",
		},
		parse: func(object map[string]any) (any, error) { return configParseSnell(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configSnellParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no snell fields", out.id)
			}
			return configBuildSnell(out, typed, settings)
		},
	},
	"ssh": {
		keys: []string{
			"server", "server_port", "user", "password", "private_key", "private_key_path",
			"private_key_passphrase", "host_key", "host_key_algorithms", "client_version",
		},
		parse: func(object map[string]any) (any, error) { return configParseSSH(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configSSHParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no ssh fields", out.id)
			}
			return configBuildSSH(out, typed, settings)
		},
	},
	"mieru": {
		keys: []string{
			"server", "server_port", "transport", "username", "password", "multiplexing",
			"traffic_pattern", "server_ports",
		},
		parse: func(object map[string]any) (any, error) { return configParseMieru(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configMieruParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no mieru fields", out.id)
			}
			return configBuildMieru(out, typed, settings)
		},
	},
	"trusttunnel": {
		keys: []string{
			"server", "server_port", "username", "password", "health_check", "quic",
			"quic_congestion_control", "custom_sni", "client_random", "tls",
		},
		parse: func(object map[string]any) (any, error) { return configParseTrustTunnel(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configTrustTunnelParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no trusttunnel fields", out.id)
			}
			return configBuildTrustTunnel(out, typed, settings)
		},
	},
	"masque": {
		keys: []string{
			"server", "server_port", "private_key", "peer_public_key", "address", "mtu",
			"http_version", "disable_version_fallback", "tls",
			"idle_timeout", "keep_alive_period", "stream_receive_window", "connection_receive_window",
			"max_concurrent_streams", "initial_packet_size", "disable_path_mtu_discovery",
		},
		parse: func(object map[string]any) (any, error) { return configParseMasque(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configMasqueParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no masque fields", out.id)
			}
			return configBuildMasque(out, typed, settings)
		},
	},
	"naive": {
		keys: []string{
			"server", "server_port", "username", "password", "insecure_concurrency",
			"extra_headers", "udp_over_tcp", "quic", "quic_congestion_control", "tls",
		},
		parse: func(object map[string]any) (any, error) { return configParseNaive(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configNaiveParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no naive fields", out.id)
			}
			return configBuildNaive(out, typed, settings)
		},
	},
	"openvpn": {
		keys: []string{
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
		},
		parse: func(object map[string]any) (any, error) { return configParseOpenVPN(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configOpenVPNParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no openvpn fields", out.id)
			}
			return configBuildOpenVPN(out, typed)
		},
	},
	"openconnect": {
		keys: []string{
			"server", "server_port", "server_path", "flavor", "username", "password", "auth_group", "cookie",
			"token", "reported_os", "user_agent", "version", "local_hostname", "mobile", "csd", "hip", "tncc",
			"fortinet_host_check", "no_udp", "dtls_local_port", "compression_disabled", "compression_mode",
			"ipv6_disabled", "http_keepalive_disabled", "xml_post_disabled", "external_auth_disabled",
			"password_authentication_disabled", "tcp_keep_alive_enabled", "pfs", "mtu", "base_mtu", "dpd_interval",
			"reconnect_timeout", "trojan_interval", "queue_length", "allow_insecure_crypto", "tls", "form_entries",
			"system", "name", "udp_timeout", "udp_mapping", "udp_filtering", "udp_nat_max",
			"otp_profile_id", "only_advertised_routes", "tunnel_dns", "block_outside_dns", "use_tunnel_dns",
		},
		parse: func(object map[string]any) (any, error) { return configOCParseOpenConnect(object) },
		build: func(out configOutbound, params any, settings simpleConfigSettings) (map[string]any, error) {
			typed, ok := params.(configOpenConnectParams)
			if !ok {
				return nil, fmt.Errorf("profile %d has no openconnect fields", out.id)
			}
			return configBuildOpenConnect(out, typed), nil
		},
	},
}
