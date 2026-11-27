// Focused tests for the pieces the golden fixtures exercise only indirectly:
// the CRC32 rule-set tag, the QHostAddress prefix subtraction that produces the
// tun's route_exclude_address, and the desktop DNS address syntax. The
// buildTest port itself now lives in config_build_testconfig.go (production);
// these tests still drive it through the fixture seam.
package mobile

import (
	"reflect"
	"strings"
	"testing"
)

func TestConfigRuleSetTagForMatchesKotlinCRC(t *testing.T) {
	tests := []struct {
		entry string
		want  string
	}{
		{"https://raw.githubusercontent.com/example/rules/main/ads.srs", "ads-srs-73ca1fc7"},
		{"https://raw.githubusercontent.com/example/rules/main/chain-block.srs", "chain-block-srs-56a43262"},
		{"geoip-cn", "geoip-cn"},
		{"  geosite-cn  ", "geosite-cn"},
	}
	for _, test := range tests {
		if got := configRuleSetTagFor(test.entry); got != test.want {
			t.Fatalf("configRuleSetTagFor(%q) = %q, want %q", test.entry, got, test.want)
		}
	}
}

func TestConfigSubtractCIDRMatchesTunExclusion(t *testing.T) {
	ranges := []string{
		"127.0.0.0/8", "255.255.255.255/32",
		"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4",
		"fc00::/7", "fe80::/10", "ff00::/8",
	}
	want := []string{
		"127.0.0.0/8", "255.255.255.255/32", "10.0.0.0/8",
		"172.24.0.0/13", "172.20.0.0/14", "172.16.0.0/15", "172.18.0.0/16",
		"172.19.128.0/17", "172.19.64.0/18", "172.19.32.0/19", "172.19.16.0/20",
		"172.19.8.0/21", "172.19.4.0/22", "172.19.2.0/23", "172.19.1.0/24",
		"192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "fc00::/7", "fe80::/10", "ff00::/8",
	}
	got := configSubtractCIDR(ranges, "172.19.0.1/24")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("configSubtractCIDR = %v\nwant %v", got, want)
	}
	// A hole inside no range keeps everything; a bare address becomes /32.
	if got := configSubtractCIDR([]string{"10.0.0.0/8"}, "203.0.113.9"); !reflect.DeepEqual(got, []string{"10.0.0.0/8"}) {
		t.Fatalf("unrelated hole changed the list: %v", got)
	}
	if !configCIDROverlap("10.0.0.0/8", "10.1.2.3") {
		t.Fatal("a bare IPv4 address must overlap its /8")
	}
}

func TestConfigParseDNSAddressMatchesDesktopSyntax(t *testing.T) {
	tests := []struct {
		address string
		want    map[string]any
	}{
		{"https://dns.google/dns-query", map[string]any{"type": "https", "server": "dns.google", "path": "/dns-query"}},
		{"223.5.5.5", map[string]any{"type": "udp", "server": "223.5.5.5"}},
		{"localhost", map[string]any{"type": "local"}},
		{"tls://1.1.1.1:853", map[string]any{"type": "tls", "server": "1.1.1.1", "server_port": 853}},
		{"dhcp://auto", map[string]any{"type": "dhcp", "interface": ""}},
	}
	for _, test := range tests {
		if got := configBuildDNSObj(test.address); !reflect.DeepEqual(got, test.want) {
			t.Fatalf("configBuildDNSObj(%q) = %#v, want %#v", test.address, got, test.want)
		}
	}
	if _, ok := configParseDNSAddress("udp://1.1.1.1/path"); ok {
		t.Fatal("a path on udp:// must be refused")
	}
	if got := configRouteExcludePrefix("10.1"); got != "" {
		t.Fatalf("routeExcludePrefix(10.1) = %q, want an empty string (not a canonical IPv4)", got)
	}
}

func TestConfigPredefinedDNSNormalization(t *testing.T) {
	entries := configParsePredefinedDNS([]string{"127.0.0.1 localhost localhost.", "::1 LocalHost"})
	if len(entries) != 1 || entries[0].domain != "localhost" {
		t.Fatalf("predefined entries = %#v", entries)
	}
	if !reflect.DeepEqual(entries[0].v4, []string{"127.0.0.1"}) || !reflect.DeepEqual(entries[0].v6, []string{"::1"}) {
		t.Fatalf("predefined answers = %#v", entries[0])
	}
	if entries := configParsePredefinedDNS([]string{"localhost"}); entries != nil {
		t.Fatalf("a line without an address must fail the parse: %#v", entries)
	}
}

// --- focused tests ------------------------------------------------------------

func TestConfigTestEnvelopeEmptyShape(t *testing.T) {
	envelope, err := configTestEnvelope(configTestBuildResult{
		coreConfig: `{"inbounds":[]}`,
		skipped:    []configTestSkip{{profileID: 4, reason: "Skipping Tailscale conf"}},
	})
	if err != nil {
		t.Fatalf("configTestEnvelope: %v", err)
	}
	want := "{\n" +
		"  \"version\": 1,\n" +
		"  \"generatedBy\": \"ConfigTestGoldenTest\",\n" +
		"  \"sha256\": \"" + configTestSHA256(`{"inbounds":[]}`) + "\",\n" +
		"  \"coreConfig\": \"{\\\"inbounds\\\":[]}\",\n" +
		"  \"outboundTags\": [],\n" +
		"  \"tagToProfileId\": [],\n" +
		"  \"fullConfigs\": [],\n" +
		"  \"skipped\": [\n    {\"profileId\": 4, \"reason\": \"Skipping Tailscale conf\"}\n  ],\n" +
		"  \"tunIPv4Cidr\": null,\n" +
		"  \"involvedProfileIds\": [],\n" +
		"  \"error\": null\n" +
		"}\n"
	if envelope != want {
		t.Fatalf("envelope = %q\nwant %q", envelope, want)
	}
}

func TestConfigTestQuoteMatchesOrgJSON(t *testing.T) {
	cases := map[string]string{
		"plain":            `"plain"`,
		"a\"b":             `"a\"b"`,
		"a\\b":             `"a\\b"`,
		"a/b":              `"a/b"`,
		"</script>":        `"<\/script>"`,
		"line\nbreak":      `"line\nbreak"`,
		"tab\tand\x01bell": `"tab\tand\u0001bell"`,
		"c1\u0085end":      `"c1\u0085end"`,
		"中文":               `"中文"`,
	}
	for input, want := range cases {
		if got := configTestQuote(input); got != want {
			t.Fatalf("configTestQuote(%q) = %s, want %s", input, got, want)
		}
	}
}

func TestBuildTestSkipsAutoSelectorAndKeepsOrder(t *testing.T) {
	inputs := &simpleConfigInputs{
		Settings: simpleConfigSettings{DirectDNS: "223.5.5.5", DNSCacheCapacity: 65536, DNSQueryTimeout: "5s"},
		Profiles: []simpleConfigProfile{
			{ID: 1, Type: "autoselector"},
			{ID: 2, Type: "shadowsocks", OutboundJSON: `{"type":"shadowsocks","tag":"s","server":"198.51.100.33","server_port":8388,"method":"aes-256-gcm","password":"pw"}`},
		},
	}
	result := buildTestCoreConfig(inputs, []configTestCandidate{
		{id: 1, landingProxyID: -1, frontProxyID: -1},
		{id: 2, landingProxyID: -1, frontProxyID: -1},
	})
	if result.failure != nil {
		t.Fatalf("build failed: %s", *result.failure)
	}
	if len(result.skipped) != 1 || result.skipped[0].profileID != 1 ||
		result.skipped[0].reason != "Skipping auto selector conf (test its members instead)" {
		t.Fatalf("skipped = %#v", result.skipped)
	}
	if !reflect.DeepEqual(result.outboundTags, []string{"proxy-2-0"}) {
		t.Fatalf("outboundTags = %v", result.outboundTags)
	}
	if !strings.Contains(result.coreConfig, `"tag":"proxy-2-0"`) {
		t.Fatalf("coreConfig lacks the candidate tag: %s", result.coreConfig)
	}
}

func TestConfigBuildRouteProfileAppliesOutboundMode(t *testing.T) {
	rows := []simpleConfigRouteRule{
		{Name: "lan-bypass", Type: configRuleTypeSimpleAddrBypass, DomainSuffix: []string{"lan.example"}, Action: "bypass", OutboundID: outboundIDDirect},
		{Name: "proxy-all", Type: configRuleTypeCustom, DomainSuffix: []string{"example.net"}, Action: "route", OutboundID: outboundIDProxy},
		{Name: "dns-rule", Type: configRuleTypeCustom, Action: "hijack-dns"},
		{Name: "disabled-dns-rule", Type: configRuleTypeCustom, Action: "hijack-dns", Disabled: true},
	}

	rule := configBuildRouteProfile(rows, outboundModeRule)
	if rule.defaultOutboundID != outboundIDProxy {
		t.Fatalf("rule mode final = %d, want proxy", rule.defaultOutboundID)
	}
	// The default Route DNS rule survives every mode; rule mode keeps the whole table.
	if len(rule.rules) != 4 {
		t.Fatalf("rule mode kept %d rules, want 4: %#v", len(rule.rules), rule.rules)
	}
	if rule.rules[1].Action != "route" {
		t.Fatalf("rule mode did not rewrite bypass to route: %#v", rule.rules[1])
	}

	for _, test := range []struct {
		mode     outboundMode
		final    int64
		finalTag string
	}{
		{outboundModeGlobal, outboundIDProxy, "proxy"},
		{outboundModeDirect, outboundIDDirect, "direct"},
	} {
		profile := configBuildRouteProfile(rows, test.mode)
		if profile.defaultOutboundID != test.final {
			t.Fatalf("%s mode final = %d, want %d", test.mode, profile.defaultOutboundID, test.final)
		}
		if got := configOutboundName(profile.defaultOutboundID); got != test.finalTag {
			t.Fatalf("%s mode final name = %q, want %q", test.mode, got, test.finalTag)
		}
		// Only the two enabled hijack-dns rules survive; the disabled one is
		// removed by the build filter that follows the mode rewrite.
		if len(profile.rules) != 2 {
			t.Fatalf("%s mode kept %d rules, want 2: %#v", test.mode, len(profile.rules), profile.rules)
		}
		for _, kept := range profile.rules {
			if kept.Action != "hijack-dns" {
				t.Fatalf("%s mode kept a non-hijack rule: %#v", test.mode, kept)
			}
		}
	}

	// An unknown stored value already fell back to rule before this function is
	// called (FlroneMode.Mode.of / loadSimpleConfigInputs), so the rewrite treats
	// anything that is not global/direct as rule rather than inventing a mode.
	unknown := configBuildRouteProfile(rows, "auto")
	if unknown.defaultOutboundID != outboundIDProxy || len(unknown.rules) != 4 {
		t.Fatalf("unknown mode did not fall back to rule: final=%d rules=%#v",
			unknown.defaultOutboundID, unknown.rules)
	}
}

func TestConfigToACEHostMatchesKotlinPunycode(t *testing.T) {
	tests := []struct {
		host string
		want string
	}{
		// ASCII is returned untouched (QUrl::toAce shortcut), case included.
		{"DNS.Example.net", "DNS.Example.net"},
		{"example.例子.测试", "example.xn--fsqu00a.xn--0zwm56d"},
		{"MÜNCHEN.de", "xn--mnchen-3ya.de"},
		// NFKC maps full-width Latin to ASCII before the label check.
		{"ｅｘａｍｐｌｅ.测试", "example.xn--0zwm56d"},
		{"例子.", "xn--fsqu00a."},
		{"例子.com, 测试.com", "xn--fsqu00a.com,xn--0zwm56d.com"},
		// An unconvertible name is returned unchanged by toAceHost.
		{"-例子.com", "-例子.com"},
		{"例 子.com", "例 子.com"},
	}
	for _, test := range tests {
		if got := configToACEHost(test.host); got != test.want {
			t.Fatalf("configToACEHost(%q) = %q, want %q", test.host, got, test.want)
		}
	}
}

func TestConfigValidDurationMatchesSingBoxGrammar(t *testing.T) {
	valid := []string{
		"5s", "1m30s", "+5s", "0s", ".5s", "0.5s", "500ms", "1.5h", "2d",
		"1us", "1µs", "3μs", " 5s ",
	}
	for _, text := range valid {
		if got := configValidDuration(text); got == "" {
			t.Fatalf("configValidDuration(%q) rejected a valid duration", text)
		}
	}
	invalid := []string{
		"", "5", "-5s", "5 s", "1.2.3s", "1s2", "s", ".s", "1s-", "1S",
	}
	for _, text := range invalid {
		if got := configValidDuration(text); got != "" {
			t.Fatalf("configValidDuration(%q) = %q, want empty", text, got)
		}
	}
	// The settings registry is stricter than the generator: a stored value with
	// a leading '+', a bare fraction or a micro-sign unit falls back to the
	// setting default before the generator ever sees it.
	for _, text := range []string{"+5s", ".5s", "1µs", "3μs"} {
		if configDurationOrEmpty(text) {
			t.Fatalf("configDurationOrEmpty(%q) accepted a registry-invalid duration", text)
		}
	}
}

func TestBuildTestSkipsExtraCoreCandidates(t *testing.T) {
	inputs := &simpleConfigInputs{
		Settings: simpleConfigSettings{DirectDNS: "223.5.5.5", DNSCacheCapacity: 65536, DNSQueryTimeout: "5s"},
		Profiles: []simpleConfigProfile{
			{ID: 1, Type: "extracore", OutboundJSON: `{"type":"extracore"}`},
			{ID: 2, Type: "chain", OutboundJSON: `{"type":"chain","name":"c","list":[3]}`},
			{ID: 3, Type: "extracore", OutboundJSON: `{"type":"extracore"}`},
		},
	}
	result := buildTestCoreConfig(inputs, []configTestCandidate{{id: 1}, {id: 2}})
	if result.failure != nil {
		t.Fatalf("build failed: %s", *result.failure)
	}
	reasons := map[int64]string{}
	for _, skip := range result.skipped {
		reasons[skip.profileID] = skip.reason
	}
	if reasons[1] != "Skipping extra-core conf" {
		t.Fatalf("extra-core skip = %q", reasons[1])
	}
	if reasons[2] != "Skipping chain with terminal (extra-core) hop (cannot test)" {
		t.Fatalf("chain extra-core skip = %q", reasons[2])
	}
}
