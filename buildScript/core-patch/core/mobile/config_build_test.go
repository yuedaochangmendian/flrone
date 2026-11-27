// Focused tests for the pieces the golden fixtures exercise only indirectly:
// the CRC32 rule-set tag, the QHostAddress prefix subtraction that produces the
// tun's route_exclude_address, and the desktop DNS address syntax.
package mobile

import (
	"reflect"
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
