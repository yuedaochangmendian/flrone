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
	"log_level":                    "warn",
	"skip_cert":                    "false",
	"use_mozilla_certs":            "false",
	"inbound_address":              "127.0.0.1",
	"inbound_socks_port":           "2080",
	"disable_mixed_inbound":        "false",
	"random_inbound_port":          "false",
	"inbound_auth":                 "false",
	"inbound_user":                 "",
	"inbound_pass":                 "",
	"custom_inbound":               `{"inbounds": []}`,
	"vpn_mtu":                      "9000",
	"vpn_ipv6":                     "false",
	"vpn_tun_ipv4_cidr":            "172.19.0.1/24",
	"vpn_tun_ipv6_cidr":            "fdfe:dcba:9876::1/96",
	"disable_private_range_bypass": "false",
	"vpn_private_ranges":           `["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16","224.0.0.0/4","fc00::/7","fe80::/10","ff00::/8"]`,
	"enable_tun_routing":           "false",
	"remote_dns":                   "https://8.8.8.8/dns-query",
	"remote_dns_disable_ipv6":      "false",
	"direct_dns":                   "localhost",
	"direct_dns_disable_ipv6":      "false",
	"core_box_underlying_dns":      "",
	"dns_final_out":                "remote",
	"enable_dns_routing":           "true",
	"fakedns":                      "false",
	"fakeip_disable_ipv6":          "false",
	"dns_use_hosts":                "false",
	"dns_predefined_enable":        "true",
	"dns_predefined_rules":         `["127.0.0.1 localhost"]`,
	"dns_cache_capacity":           "65536",
	"dns_query_timeout":            "",
	"dns_optimistic":               "false",
	"dns_optimistic_timeout":       "",
	"dns_disable_cache":            "false",
	"dns_disable_expire":           "false",
	"dns_persist_cache":            "false",
	"dns_reverse_mapping":          "false",
	"use_dns_object":               "false",
	"dns_object":                   "",
	"outbound_domain_strategy":     "",
	"domain_strategy":              "",
	"ruleset_mirror":               "0",
	"adblock_enable":               "false",
	"core_box_api_port":            "9091",
	"core_box_api_secret":          "",
	"core_box_clash_api":           "-9090",
	"core_box_clash_listen_addr":   "127.0.0.1",
	"core_box_clash_api_secret":    "",
	"core_dns_in_port":             "5533",
	"serviceMode":                  "vpn",
	"bbox_outbound_mode":           "rule",
	"profileId":                    "0",
	"current_group":                "0",
	"startWithoutRuleSets":         "0",
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
		VPNMtu:                    9000,
		VPNIPv6:                   false,
		VPNTunIPv4CIDR:            "172.19.0.1/24",
		VPNTunIPv6CIDR:            "fdfe:dcba:9876::1/96",
		DisablePrivateRangeBypass: false,
		VPNPrivateRanges:          []string{"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "fc00::/7", "fe80::/10", "ff00::/8"},
		EnableTunRouting:          false,
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
		OutboundDomainStrategy:    "",
		DomainStrategy:            "",
		RuleSetMirror:             0,
		AdblockEnable:             false,
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
		{"dns_predefined_rules", `["127.0.0.1 localhost"]`, true, []string{"127.0.0.1 localhost"}},
		{"dns_predefined_rules", `["localhost"]`, false, nil},
		{"dns_predefined_rules", `not-json`, false, nil},
		{"dns_object", `{"servers": []}`, true, `{"servers": []}`},
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
		{"key": "vpn_mtu", "value": "1500"},
		{"key": "vpn_ipv6", "value": "1"},
		{"key": "vpn_tun_ipv4_cidr", "value": "10.8.0.1/16"},
		{"key": "vpn_tun_ipv6_cidr", "value": "fd00::1/64"},
		{"key": "disable_private_range_bypass", "value": "1"},
		{"key": "vpn_private_ranges", "value": `["10.0.0.0/8"]`},
		{"key": "enable_tun_routing", "value": "1"},
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
		{"key": "outbound_domain_strategy", "value": "prefer_ipv4"},
		{"key": "domain_strategy", "value": "ipv4_only"},
		{"key": "ruleset_mirror", "value": "5"},
		{"key": "adblock_enable", "value": "1"},
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
		VPNMtu:                    1500,
		VPNIPv6:                   true,
		VPNTunIPv4CIDR:            "10.8.0.1/16",
		VPNTunIPv6CIDR:            "fd00::1/64",
		DisablePrivateRangeBypass: true,
		VPNPrivateRanges:          []string{"10.0.0.0/8"},
		EnableTunRouting:          true,
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
		OutboundDomainStrategy:    "prefer_ipv4",
		DomainStrategy:            "ipv4_only",
		RuleSetMirror:             5,
		AdblockEnable:             true,
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
