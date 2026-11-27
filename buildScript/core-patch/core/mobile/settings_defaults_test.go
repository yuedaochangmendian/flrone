// The ported SettingsRegistry table and the typed settings a simple config
// build reads. These tests pin the defaults against a hand-checked table and
// the Kotlin fallback rule (missing or invalid row -> registered default).
package mobile

import (
	"reflect"
	"testing"
)

// handCheckedSettingDefaults is the encoded default of every key this layer
// reads, copied by hand from SettingsRegistry.kt (or DataStore for the
// Android-only keys). Changing the Go table must be mirrored here deliberately,
// the same way a Kotlin default change is a reviewed change.
var handCheckedSettingDefaults = map[string]string{
	"log_level":                       "warn",
	"enable_ntp":                      "false",
	"ntp_server_address":              "",
	"ntp_server_port":                 "0",
	"ntp_interval":                    "",
	"ntp_outbound":                    "direct",
	"skip_cert":                       "false",
	"use_mozilla_certs":               "false",
	"inbound_address":                 "127.0.0.1",
	"inbound_socks_port":              "2080",
	"disable_mixed_inbound":           "false",
	"random_inbound_port":             "false",
	"inbound_auth":                    "false",
	"inbound_user":                    "",
	"inbound_pass":                    "",
	"custom_inbound":                  `{"inbounds": []}`,
	"proxyApps":                       "false",
	"bypassMode":                      "true",
	"individual":                      "",
	"appendHttpProxy":                 "false",
	"httpProxyBypass":                 "",
	"vpn_mtu":                         "9000",
	"vpn_ipv6":                        "false",
	"vpn_tun_ipv4_cidr":               "172.19.0.1/24",
	"vpn_tun_ipv6_cidr":               "fdfe:dcba:9876::1/96",
	"disable_private_range_bypass":    "false",
	"vpn_private_ranges":              `["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","224.0.0.0/4","fc00::/7","fe80::/10","ff00::/8"]`,
	"enable_tun_routing":              "false",
	"enable_warp":                     "false",
	"mux_default_on":                  "false",
	"remote_dns":                      "https://8.8.8.8/dns-query",
	"remote_dns_disable_ipv6":         "false",
	"direct_dns":                      "localhost",
	"direct_dns_disable_ipv6":         "false",
	"core_box_underlying_dns":         "",
	"dns_final_out":                   "remote",
	"enable_dns_routing":              "true",
	"fakedns":                         "false",
	"fakeip_disable_ipv6":             "false",
	"dns_use_hosts":                   "false",
	"dns_predefined_enable":           "true",
	"dns_predefined_rules":            `["127.0.0.1 localhost"]`,
	"dns_cache_capacity":              "65536",
	"dns_query_timeout":               "",
	"dns_optimistic":                  "false",
	"dns_optimistic_timeout":          "",
	"dns_disable_cache":               "false",
	"dns_disable_expire":              "false",
	"dns_persist_cache":               "false",
	"dns_reverse_mapping":             "false",
	"use_dns_object":                  "false",
	"dns_object":                      "",
	"test_url":                        "https://cp.cloudflare.com/",
	"direct_test_url":                 "",
	"outbound_domain_strategy":        "",
	"domain_strategy":                 "",
	"ruleset_mirror":                  "0",
	"adblock_enable":                  "false",
	"mux_protocol":                    "smux",
	"mux_mode":                        "max_streams",
	"mux_concurrency":                 "8",
	"mux_max_connections":             "4",
	"mux_min_streams":                 "4",
	"mux_padding":                     "false",
	"mux_brutal":                      "false",
	"mux_brutal_up_mbps":              "0",
	"mux_brutal_down_mbps":            "0",
	"fragment_default_on":             "false",
	"fragment_implementation":         "built-in",
	"fragment_size":                   "10-100",
	"fragment_sleep":                  "2-5",
	"tls_tricks_default_on":           "false",
	"utlsFingerprint":                 "",
	"h2_idle_timeout":                 "",
	"h2_keep_alive_period":            "",
	"h2_stream_receive_window":        "",
	"h2_connection_receive_window":    "",
	"h2_max_concurrent_streams":       "0",
	"quic_initial_packet_size":        "0",
	"quic_disable_path_mtu_discovery": "false",
	"warp_mode":                       "wireguard",
	"warp_ep":                         "",
	"warp_private_key":                "",
	"warp_public_key":                 "",
	"warp_ifc_addrs":                  "[]",
	"warp_reserved":                   "[]",
	"warp_amnezia_packets":            "[]",
	"warp_masque_ep":                  "",
	"warp_masque_private_key":         "",
	"warp_masque_peer_public_key":     "",
	"warp_masque_ifc_addrs":           "[]",
	"warp_masque_sni":                 "consumer-masque.cloudflareclient.com",
	"warp_masque_http_mode":           "0",
	"core_box_api_port":               "9091",
	"core_box_api_secret":             "",
	"core_box_clash_api":              "-9090",
	"core_box_clash_listen_addr":      "127.0.0.1",
	"core_box_clash_api_secret":       "",
	"core_dns_in_port":                "5533",
	"serviceMode":                     "vpn",
	"bbox_outbound_mode":              "rule",
	"profileId":                       "0",
	"current_group":                   "0",
	"startWithoutRuleSets":            "0",
}

func TestSimpleConfigSettingDefaultsMatchHandCheckedTable(t *testing.T) {
	got := configSettingDefaults()
	if !reflect.DeepEqual(got, handCheckedSettingDefaults) {
		t.Fatalf("default table drifted from SettingsRegistry:\n got %#v\nwant %#v", got, handCheckedSettingDefaults)
	}
	if len(got) != len(configSettingDefinitions) {
		t.Fatalf("duplicate setting keys: %d definitions but %d distinct defaults", len(configSettingDefinitions), len(got))
	}
}

func TestSimpleConfigSettingsDefaultsStruct(t *testing.T) {
	want := simpleConfigSettings{
		LogLevel:                  "warn",
		NTPEnabled:                false,
		NTPServer:                 "",
		NTPServerPort:             0,
		NTPInterval:               "",
		NTPOutbound:               "direct",
		SkipCert:                  false,
		UseMozillaCerts:           false,
		InboundAddress:            "127.0.0.1",
		InboundSocksPort:          2080,
		DisableMixedInbound:       false,
		RandomInboundPort:         false,
		InboundAuth:               false,
		InboundUser:               "",
		InboundPass:               "",
		CustomInbound:             `{"inbounds": []}`,
		ProxyApps:                 false,
		PerAppBypass:              true,
		Individual:                "",
		AppendHTTPProxy:           false,
		HTTPProxyBypass:           "",
		VPNMtu:                    9000,
		VPNIPv6:                   false,
		VPNTunIPv4CIDR:            "172.19.0.1/24",
		VPNTunIPv6CIDR:            "fdfe:dcba:9876::1/96",
		DisablePrivateRangeBypass: false,
		VPNPrivateRanges:          []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "fc00::/7", "fe80::/10", "ff00::/8"},
		EnableTunRouting:          false,
		EnableWarp:                false,
		MuxDefaultOn:              false,
		RemoteDNS:                 "https://8.8.8.8/dns-query",
		RemoteDNSDisableIPv6:      false,
		DirectDNS:                 "localhost",
		DirectDNSDisableIPv6:      false,
		CoreBoxUnderlyingDNS:      "",
		DNSFinalOut:               "remote",
		EnableDNSRouting:          true,
		FakeDNS:                   false,
		FakeIPDisableIPv6:         false,
		DNSUseHosts:               false,
		DNSPredefinedEnable:       true,
		DNSPredefinedRules:        []string{"127.0.0.1 localhost"},
		DNSCacheCapacity:          65536,
		DNSQueryTimeout:           "",
		DNSOptimistic:             false,
		DNSOptimisticTimeout:      "",
		DNSDisableCache:           false,
		DNSDisableExpire:          false,
		DNSPersistCache:           false,
		DNSReverseMapping:         false,
		UseDNSObject:              false,
		DNSObject:                 "",
		TestURL:                   "https://cp.cloudflare.com/",
		DirectTestURL:             "",
		OutboundDomainStrategy:    "",
		DomainStrategy:            "",
		RuleSetMirror:             0,
		AdblockEnable:             false,
		MuxProtocol:               "smux",
		MuxMode:                   "max_streams",
		MuxConcurrency:            8,
		MuxMaxConnections:         4,
		MuxMinStreams:             4,
		FragmentImplementation:    "built-in",
		FragmentSize:              "10-100",
		FragmentSleep:             "2-5",
		WarpMode:                  "wireguard",
		WarpIfcAddrs:              []string{},
		WarpReserved:              []string{},
		WarpAmneziaPackets:        []string{},
		WarpMasqueIfcAddrs:        []string{},
		WarpMasqueSni:             "consumer-masque.cloudflareclient.com",
		CoreBoxAPIPort:            9091,
		CoreBoxAPISecret:          "",
		CoreBoxClashAPI:           -9090,
		CoreBoxClashListenAddr:    "127.0.0.1",
		CoreBoxClashAPISecret:     "",
		CoreDNSInPort:             5533,
	}
	got := loadSimpleConfigSettings(nil)
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("default settings struct:\n got %#v\nwant %#v", got, want)
	}
}

func TestSimpleConfigSettingDefaultsRoundTrip(t *testing.T) {
	for _, definition := range configSettingDefinitions {
		encoded, ok := configSettingEncodedDefault(definition.key)
		if !ok {
			t.Fatalf("%s has no encoded default", definition.key)
		}
		decoded, ok := decodeConfigSetting(definition.key, encoded)
		if !ok {
			t.Fatalf("%s default %q does not decode", definition.key, encoded)
		}
		want, _ := configSettingDefault(definition.key)
		if !reflect.DeepEqual(decoded, want) {
			t.Fatalf("%s default round trip = %#v, want %#v", definition.key, decoded, want)
		}
	}
}

func TestConfigSettingDecodeMatchesKotlin(t *testing.T) {
	tests := []struct {
		key     string
		raw     string
		wantOK  bool
		wantVal any
	}{
		{"log_level", "debug", true, "debug"},
		{"log_level", "verbose", false, nil},
		{"log_level", " debug", false, nil},
		{"skip_cert", "1", true, true},
		{"skip_cert", "0", true, false},
		{"skip_cert", "false", true, false},
		{"skip_cert", "TRUE", false, nil},
		{"inbound_socks_port", " 2080 ", true, 2080},
		{"inbound_socks_port", "2080.0", false, nil},
		{"inbound_socks_port", "0", false, nil},
		{"inbound_socks_port", "65536", false, nil},
		{"vpn_mtu", "1000", true, 1000},
		{"vpn_mtu", "10000", true, 10000},
		{"vpn_mtu", "999", false, nil},
		{"dns_cache_capacity", "0", true, 0},
		{"dns_cache_capacity", "-1", false, nil},
		{"profileId", "9223372036854775807", true, int64(9223372036854775807)},
		{"startWithoutRuleSets", "-5", true, int64(-5)},
		{"serviceMode", "proxy", true, "proxy"},
		{"serviceMode", "tun", false, nil},
		{"bbox_outbound_mode", "global", true, "global"},
		{"bbox_outbound_mode", "auto", false, nil},
		{"vpn_private_ranges", `["10.0.0.0/8","fc00::/7"]`, true, []string{"10.0.0.0/8", "fc00::/7"}},
		{"vpn_private_ranges", `["0.0.0.0/0"]`, false, nil},
		{"vpn_private_ranges", `["10.0.0.0/8",1]`, false, nil},
		{"warp_mode", "amnezia", true, "amnezia"},
		{"warp_mode", " Amnezia", false, nil},
		{"warp_masque_http_mode", "2", true, 2},
		{"warp_masque_http_mode", "4", false, nil},
		{"warp_ifc_addrs", `["172.16.0.2/32","fd00::2/128"]`, true, []string{"172.16.0.2/32", "fd00::2/128"}},
		{"dns_predefined_rules", `["127.0.0.1 localhost"]`, true, []string{"127.0.0.1 localhost"}},
		{"dns_predefined_rules", `["localhost"]`, false, nil},
		{"dns_predefined_rules", `not-json`, false, nil},
		{"dns_object", `{"servers": []}`, true, `{"servers": []}`},
		{"test_url", "https://cp.cloudflare.com/", true, "https://cp.cloudflare.com/"},
		{"test_url", "", false, nil},
		{"direct_test_url", "https://direct.example.test/", true, "https://direct.example.test/"},
		{"direct_test_url", "", true, ""},
	}
	for _, test := range tests {
		got, ok := decodeConfigSetting(test.key, test.raw)
		if ok != test.wantOK {
			t.Fatalf("%s(%q): ok = %v, want %v", test.key, test.raw, ok, test.wantOK)
		}
		if ok && !reflect.DeepEqual(got, test.wantVal) {
			t.Fatalf("%s(%q) = %#v, want %#v", test.key, test.raw, got, test.wantVal)
		}
	}
}

func TestInvalidAndMissingSettingsRowsFallBackToDefaults(t *testing.T) {
	defaults := loadSimpleConfigSettings(nil)

	invalid := []row{
		{"key": "log_level", "value": "loud"},
		{"key": "enable_ntp", "value": "yes"},
		{"key": "ntp_server_port", "value": "70000"},
		{"key": "ntp_interval", "value": "30 minutes"},
		{"key": "ntp_outbound", "value": "auto"},
		{"key": "skip_cert", "value": "yes"},
		{"key": "inbound_address", "value": "   "},
		{"key": "inbound_socks_port", "value": "0"},
		{"key": "vpn_mtu", "value": "999"},
		{"key": "vpn_tun_ipv4_cidr", "value": "::1/128"},
		{"key": "vpn_private_ranges", "value": `["0.0.0.0/0"]`},
		{"key": "dns_final_out", "value": "proxy"},
		{"key": "dns_predefined_rules", "value": `["localhost"]`},
		{"key": "dns_cache_capacity", "value": "-1"},
		{"key": "dns_query_timeout", "value": "5 seconds"},
		{"key": "domain_strategy", "value": "prefer_ipv7"},
		{"key": "ruleset_mirror", "value": "6"},
		{"key": "warp_mode", "value": "wireguard2"},
		{"key": "warp_masque_http_mode", "value": "3"},
		{"key": "core_box_api_port", "value": "70000"},
		{"key": "core_box_clash_api", "value": "999999"},
		{"key": "core_dns_in_port", "value": "0"},
		{"key": "serviceMode", "value": "tun"},
		{"key": "bbox_outbound_mode", "value": "auto"},
	}
	if got := loadSimpleConfigSettings(invalid); !reflect.DeepEqual(got, defaults) {
		t.Fatalf("invalid rows did not fall back:\n got %#v\nwant %#v", got, defaults)
	}

	// Missing rows are the same case: an empty document means every default.
	if got := loadSimpleConfigSettings([]row{}); !reflect.DeepEqual(got, defaults) {
		t.Fatalf("empty settings document did not use defaults:\n got %#v\nwant %#v", got, defaults)
	}
}

func TestValidSettingsRowsOverrideDefaults(t *testing.T) {
	rows := []row{
		{"key": "log_level", "value": "debug"},
		{"key": "enable_ntp", "value": "1"},
		{"key": "ntp_server_address", "value": "time.cloudflare.com"},
		{"key": "ntp_server_port", "value": "123"},
		{"key": "ntp_interval", "value": "30m"},
		{"key": "ntp_outbound", "value": "proxy"},
		{"key": "skip_cert", "value": "1"},
		{"key": "use_mozilla_certs", "value": "true"},
		{"key": "inbound_address", "value": "::"},
		{"key": "inbound_socks_port", "value": "1080"},
		{"key": "disable_mixed_inbound", "value": "1"},
		{"key": "random_inbound_port", "value": "1"},
		{"key": "inbound_auth", "value": "true"},
		{"key": "inbound_user", "value": "user"},
		{"key": "inbound_pass", "value": "pass"},
		{"key": "custom_inbound", "value": ""},
		{"key": "proxyApps", "value": "1"},
		{"key": "bypassMode", "value": "0"},
		{"key": "individual", "value": "com.example"},
		{"key": "appendHttpProxy", "value": "1"},
		{"key": "httpProxyBypass", "value": "localhost"},
		{"key": "vpn_mtu", "value": "1500"},
		{"key": "vpn_ipv6", "value": "1"},
		{"key": "vpn_tun_ipv4_cidr", "value": "10.8.0.1/16"},
		{"key": "vpn_tun_ipv6_cidr", "value": "fd00::1/64"},
		{"key": "disable_private_range_bypass", "value": "1"},
		{"key": "vpn_private_ranges", "value": `["10.0.0.0/8"]`},
		{"key": "enable_tun_routing", "value": "1"},
		{"key": "enable_warp", "value": "1"},
		{"key": "mux_default_on", "value": "1"},
		{"key": "remote_dns", "value": "https://1.1.1.1/dns-query"},
		{"key": "remote_dns_disable_ipv6", "value": "1"},
		{"key": "direct_dns", "value": "1.1.1.1"},
		{"key": "direct_dns_disable_ipv6", "value": "1"},
		{"key": "core_box_underlying_dns", "value": "8.8.8.8"},
		{"key": "dns_final_out", "value": "direct"},
		{"key": "enable_dns_routing", "value": "0"},
		{"key": "fakedns", "value": "1"},
		{"key": "fakeip_disable_ipv6", "value": "1"},
		{"key": "dns_use_hosts", "value": "1"},
		{"key": "dns_predefined_enable", "value": "0"},
		{"key": "dns_predefined_rules", "value": `["1.1.1.1 one.example"]`},
		{"key": "dns_cache_capacity", "value": "0"},
		{"key": "dns_query_timeout", "value": "5s"},
		{"key": "dns_optimistic", "value": "1"},
		{"key": "dns_optimistic_timeout", "value": "10s"},
		{"key": "dns_disable_cache", "value": "1"},
		{"key": "dns_disable_expire", "value": "1"},
		{"key": "dns_persist_cache", "value": "1"},
		{"key": "dns_reverse_mapping", "value": "1"},
		{"key": "use_dns_object", "value": "1"},
		{"key": "dns_object", "value": `{"servers":[]}`},
		{"key": "test_url", "value": "https://test.example.test/probe"},
		{"key": "direct_test_url", "value": "https://direct.example.test/probe"},
		{"key": "outbound_domain_strategy", "value": "prefer_ipv4"},
		{"key": "domain_strategy", "value": "ipv4_only"},
		{"key": "ruleset_mirror", "value": "5"},
		{"key": "adblock_enable", "value": "1"},
		{"key": "warp_mode", "value": "masque"},
		{"key": "warp_ep", "value": "engage.cloudflareclient.com:2408"},
		{"key": "warp_private_key", "value": "warp-private"},
		{"key": "warp_public_key", "value": "warp-public"},
		{"key": "warp_ifc_addrs", "value": `["172.16.0.2/32","fd00::2/128"]`},
		{"key": "warp_reserved", "value": `["1","2","3"]`},
		{"key": "warp_amnezia_packets", "value": `["0123456789abcdef"]`},
		{"key": "warp_masque_ep", "value": "162.159.198.2"},
		{"key": "warp_masque_private_key", "value": "masque-private"},
		{"key": "warp_masque_peer_public_key", "value": "masque-public"},
		{"key": "warp_masque_ifc_addrs", "value": `["172.16.0.3/32"]`},
		{"key": "warp_masque_sni", "value": "masque.example"},
		{"key": "warp_masque_http_mode", "value": "1"},
		{"key": "core_box_api_port", "value": "-9091"},
		{"key": "core_box_api_secret", "value": "api-secret"},
		{"key": "core_box_clash_api", "value": "9090"},
		{"key": "core_box_clash_listen_addr", "value": "0.0.0.0"},
		{"key": "core_box_clash_api_secret", "value": "clash-secret"},
		{"key": "core_dns_in_port", "value": "5353"},
	}
	got := loadSimpleConfigSettings(rows)
	want := simpleConfigSettings{
		LogLevel:                  "debug",
		NTPEnabled:                true,
		NTPServer:                 "time.cloudflare.com",
		NTPServerPort:             123,
		NTPInterval:               "30m",
		NTPOutbound:               "proxy",
		SkipCert:                  true,
		UseMozillaCerts:           true,
		InboundAddress:            "::",
		InboundSocksPort:          1080,
		DisableMixedInbound:       true,
		RandomInboundPort:         true,
		InboundAuth:               true,
		InboundUser:               "user",
		InboundPass:               "pass",
		CustomInbound:             "",
		ProxyApps:                 true,
		PerAppBypass:              false,
		Individual:                "com.example",
		AppendHTTPProxy:           true,
		HTTPProxyBypass:           "localhost",
		VPNMtu:                    1500,
		VPNIPv6:                   true,
		VPNTunIPv4CIDR:            "10.8.0.1/16",
		VPNTunIPv6CIDR:            "fd00::1/64",
		DisablePrivateRangeBypass: true,
		VPNPrivateRanges:          []string{"10.0.0.0/8"},
		EnableTunRouting:          true,
		EnableWarp:                true,
		MuxDefaultOn:              true,
		RemoteDNS:                 "https://1.1.1.1/dns-query",
		RemoteDNSDisableIPv6:      true,
		DirectDNS:                 "1.1.1.1",
		DirectDNSDisableIPv6:      true,
		CoreBoxUnderlyingDNS:      "8.8.8.8",
		DNSFinalOut:               "direct",
		EnableDNSRouting:          false,
		FakeDNS:                   true,
		FakeIPDisableIPv6:         true,
		DNSUseHosts:               true,
		DNSPredefinedEnable:       false,
		DNSPredefinedRules:        []string{"1.1.1.1 one.example"},
		DNSCacheCapacity:          0,
		DNSQueryTimeout:           "5s",
		DNSOptimistic:             true,
		DNSOptimisticTimeout:      "10s",
		DNSDisableCache:           true,
		DNSDisableExpire:          true,
		DNSPersistCache:           true,
		DNSReverseMapping:         true,
		UseDNSObject:              true,
		DNSObject:                 `{"servers":[]}`,
		TestURL:                   "https://test.example.test/probe",
		DirectTestURL:             "https://direct.example.test/probe",
		OutboundDomainStrategy:    "prefer_ipv4",
		DomainStrategy:            "ipv4_only",
		RuleSetMirror:             5,
		AdblockEnable:             true,
		WarpMode:                  "masque",
		WarpEp:                    "engage.cloudflareclient.com:2408",
		WarpPrivateKey:            "warp-private",
		WarpPublicKey:             "warp-public",
		WarpIfcAddrs:              []string{"172.16.0.2/32", "fd00::2/128"},
		WarpReserved:              []string{"1", "2", "3"},
		WarpAmneziaPackets:        []string{"0123456789abcdef"},
		WarpMasqueEp:              "162.159.198.2",
		WarpMasquePrivateKey:      "masque-private",
		WarpMasquePeerPublicKey:   "masque-public",
		WarpMasqueIfcAddrs:        []string{"172.16.0.3/32"},
		WarpMasqueSni:             "masque.example",
		WarpMasqueHTTPMode:        1,
		MuxProtocol:               "smux",
		MuxMode:                   "max_streams",
		MuxConcurrency:            8,
		MuxMaxConnections:         4,
		MuxMinStreams:             4,
		FragmentImplementation:    "built-in",
		FragmentSize:              "10-100",
		FragmentSleep:             "2-5",
		CoreBoxAPIPort:            -9091,
		CoreBoxAPISecret:          "api-secret",
		CoreBoxClashAPI:           9090,
		CoreBoxClashListenAddr:    "0.0.0.0",
		CoreBoxClashAPISecret:     "clash-secret",
		CoreDNSInPort:             5353,
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("valid rows:\n got %#v\nwant %#v", got, want)
	}
}

func TestSimpleConfigSettingsDerivedValues(t *testing.T) {
	settings := loadSimpleConfigSettings([]row{
		{"key": "disable_mixed_inbound", "value": "true"},
		{"key": "disable_private_range_bypass", "value": "true"},
		{"key": "core_box_clash_api", "value": "-9090"},
	})
	if settings.MixedInboundEnabled(serviceModeVPN) {
		t.Fatal("disable_mixed_inbound must disable the mixed inbound in VPN mode")
	}
	if !settings.MixedInboundEnabled(serviceModeProxy) {
		t.Fatal("proxy-only mode needs the mixed inbound even with disable_mixed_inbound set")
	}
	if settings.BypassLan() {
		t.Fatal("BypassLan must be false when disable_private_range_bypass is true")
	}
	if settings.ClashAPIEnabled() {
		t.Fatal("a negative core_box_clash_api is off")
	}
	if got := settings.ClashAPIPort(); got != 9090 {
		t.Fatalf("ClashAPIPort = %d, want 9090", got)
	}
	settings.CoreBoxClashAPI = 9091
	if !settings.ClashAPIEnabled() || settings.ClashAPIPort() != 9091 {
		t.Fatalf("positive clash api: enabled=%v port=%d", settings.ClashAPIEnabled(), settings.ClashAPIPort())
	}
}

func TestSimpleConfigTestingSettingsFallbacks(t *testing.T) {
	// A blank test_url fails SettingValidators.nonBlank and takes the registered
	// default; direct_test_url has no validator, so a blank row means blank.
	settings := loadSimpleConfigSettings([]row{
		{"key": "test_url", "value": ""},
		{"key": "direct_test_url", "value": "https://direct.example.test/health"},
	})
	if settings.TestURL != "https://cp.cloudflare.com/" {
		t.Fatalf("test_url fallback = %q", settings.TestURL)
	}
	if settings.DirectTestURL != "https://direct.example.test/health" {
		t.Fatalf("direct_test_url = %q", settings.DirectTestURL)
	}
	blank := loadSimpleConfigSettings(nil)
	if blank.TestURL != "https://cp.cloudflare.com/" || blank.DirectTestURL != "" {
		t.Fatalf("testing defaults = %q / %q", blank.TestURL, blank.DirectTestURL)
	}
}
