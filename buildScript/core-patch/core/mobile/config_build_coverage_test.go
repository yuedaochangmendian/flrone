package mobile

import "testing"

// TestConfigBuilderCoversKotlinOutboundTypes pins the protocol matrix: every
// type OutboundFactory can build must have a Go key set and test-config
// builder, so a new Kotlin type cannot silently become a startup failure.
// tailscale and extracore are InvalidOutbound in Kotlin too.
func TestConfigBuilderCoversKotlinOutboundTypes(t *testing.T) {
	supported := []string{
		"socks", "http", "shadowsocks", "chain", "autoselector", "vmess", "trojan",
		"vless", "hysteria", "hysteria2", "tuic", "juicity", "trusttunnel", "anytls",
		"mieru", "snell", "shadowtls", "wireguard", "masque", "openvpn", "openvpn-client",
		"openconnect", "ssh", "custom", "naive", "direct",
	}
	for _, typeName := range supported {
		if !configGoBuildableType(typeName) {
			t.Fatalf("%s is Kotlin-buildable but missing from configGoBuildableType", typeName)
		}
		// chain/autoselector/direct/custom are dispatched before the key-set
		// lookup and intentionally have no per-type key list.
		switch typeName {
		case "chain", "autoselector", "direct", "custom":
			continue
		}
		if configOutboundTypeKeys(typeName) == nil {
			t.Fatalf("%s has no Go key set", typeName)
		}
	}
	for _, typeName := range []string{"tailscale", "extracore"} {
		if configOutboundTypeKeys(typeName) != nil {
			t.Fatalf("%s is InvalidOutbound in Kotlin but has Go keys", typeName)
		}
	}
}
