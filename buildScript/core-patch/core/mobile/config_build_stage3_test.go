// Focused tests for the Stage-3 pieces the golden fixtures exercise only
// indirectly: the WARP endpoint splitter and identity check, the synthetic WARP
// hop's field mapping, and the org.json-tolerant reader for custom configs.
package mobile

import (
	"reflect"
	"testing"
)

func TestConfigWarpSplitEndpoint(t *testing.T) {
	tests := []struct {
		endpoint string
		wantHost string
		wantPort int
	}{
		{"engage.cloudflareclient.com:2408", "engage.cloudflareclient.com", 2408},
		{"162.159.198.2", "162.159.198.2", 443},
		{"[2606:4700:d0::a29f:c001]:2408", "2606:4700:d0::a29f:c001", 2408},
		{"[2606:4700:d0::a29f:c001]", "2606:4700:d0::a29f:c001", 443},
		{"2606:4700:d0::a29f:c001", "2606:4700:d0::a29f:c001", 443},
		{"  engage.cloudflareclient.com:2408  ", "engage.cloudflareclient.com", 2408},
		{"host:0", "host", 443},
		{"host:65536", "host", 443},
		{"host:notaport", "host", 443},
		{"[broken", "[broken", 443},
	}
	for _, test := range tests {
		host, port := configWarpSplitEndpoint(test.endpoint, 443)
		if host != test.wantHost || port != test.wantPort {
			t.Fatalf("configWarpSplitEndpoint(%q) = %q, %d; want %q, %d",
				test.endpoint, host, port, test.wantHost, test.wantPort)
		}
	}
	if _, port := configWarpSplitEndpoint("engage.cloudflareclient.com", 2408); port != 2408 {
		t.Fatalf("the WireGuard default port must be 2408, got %d", port)
	}
}

func TestConfigWarpMissingMatchesIdentityModes(t *testing.T) {
	complete := simpleConfigSettings{
		WarpMode:       "wireguard",
		WarpEp:         "engage.cloudflareclient.com:2408",
		WarpPrivateKey: "private",
		WarpPublicKey:  "public",
		WarpIfcAddrs:   []string{"172.16.0.2/32"},
	}
	if configWarpMissing(complete) {
		t.Fatal("a complete WireGuard identity must not be missing")
	}
	withoutKey := complete
	withoutKey.WarpPrivateKey = ""
	if !configWarpMissing(withoutKey) {
		t.Fatal("an empty private key must make the identity incomplete")
	}
	amnezia := complete
	amnezia.WarpMode = "amnezia"
	if !configWarpMissing(amnezia) {
		t.Fatal("amnezia without packets must make the identity incomplete")
	}
	amnezia.WarpAmneziaPackets = []string{"aa"}
	if configWarpMissing(amnezia) {
		t.Fatal("amnezia with packets must be complete")
	}
	masque := simpleConfigSettings{
		WarpMode:                "masque",
		WarpMasqueEp:            "162.159.198.2",
		WarpMasquePrivateKey:    "private",
		WarpMasquePeerPublicKey: "public",
		WarpMasqueIfcAddrs:      []string{"172.16.0.2/32"},
	}
	if configWarpMissing(masque) {
		t.Fatal("a complete MASQUE identity must not be missing")
	}
	masque.WarpMasquePeerPublicKey = ""
	if !configWarpMissing(masque) {
		t.Fatal("a MASQUE identity without its peer key must be incomplete")
	}
}

func TestConfigWarpOutboundFieldMapping(t *testing.T) {
	settings := simpleConfigSettings{
		WarpMode:       "wireguard",
		WarpEp:         "[2606:4700:d0::a29f:c001]:2408",
		WarpPrivateKey: "private",
		WarpPublicKey:  "public",
		WarpIfcAddrs:   []string{"172.16.0.2/32", "fd00::2/128"},
		WarpReserved:   []string{"1", "x", "3"},
	}
	out := configWarpOutbound(settings)
	if out.id != configWarpProfileID || out.profileType != "wireguard" || out.name != "warp" {
		t.Fatalf("the synthetic hop = %#v", out)
	}
	params, ok := out.params.(configWireGuardParams)
	if !ok {
		t.Fatalf("params = %T", out.params)
	}
	if params.mtu != 1280 || params.privateKey != "private" {
		t.Fatalf("wireguard params = %#v", params)
	}
	wantPeer := configWireGuardPeer{
		address:             "2606:4700:d0::a29f:c001",
		port:                2408,
		publicKey:           "public",
		reserved:            []int{1, 0, 3}, // QtStrings.toInt("x") is 0
		persistentKeepalive: "10",
	}
	if !reflect.DeepEqual(params.peer, wantPeer) {
		t.Fatalf("peer = %#v, want %#v", params.peer, wantPeer)
	}

	amnezia := settings
	amnezia.WarpMode = "amnezia"
	amnezia.WarpAmneziaPackets = []string{"i1", "i2"}
	params = configWarpOutbound(amnezia).params.(configWireGuardParams)
	wantAmnezia := configWireGuardAmnezia{
		enabled: true, jc: 4, jmin: 40, jmax: 70,
		h1: "1", h2: "2", h3: "3", h4: "4",
		i1: "i1", i2: "i2",
	}
	if !reflect.DeepEqual(params.amnezia, wantAmnezia) {
		t.Fatalf("amnezia = %#v, want %#v", params.amnezia, wantAmnezia)
	}

	masque := simpleConfigSettings{
		WarpMode:                "masque",
		WarpMasqueEp:            "162.159.198.2",
		WarpMasquePrivateKey:    "private",
		WarpMasquePeerPublicKey: "public",
		WarpMasqueIfcAddrs:      []string{"172.16.0.2/32"},
		WarpMasqueSni:           "",
		WarpMasqueHTTPMode:      1,
	}
	built := configWarpOutbound(masque)
	if built.profileType != "masque" || built.server != "162.159.198.2" || built.serverPort != 443 {
		t.Fatalf("masque hop = %#v", built)
	}
	masqueParams := built.params.(configMasqueParams)
	if masqueParams.httpVersion != 3 || !masqueParams.disableVersionFallback {
		t.Fatalf("warp_masque_http_mode 1 = %#v", masqueParams)
	}
	if !masqueParams.tls.enabled || masqueParams.tls.serverName != configWarpMasqueDefaultSNI {
		t.Fatalf("the Masque constructor SNI must fill in: %#v", masqueParams.tls)
	}
}

func TestConfigCustomObjectMatchesOrgJson(t *testing.T) {
	tests := []struct {
		name string
		text string
		want map[string]any
	}{
		{"plain", `{"log":{"level":"warn"}}`, map[string]any{"log": map[string]any{"level": "warn"}}},
		{"trailing separator", `{"a":1,}`, map[string]any{"a": int64(1)}},
		{"comments", "{\n// line\n\"a\": 1, /* block */ \"b\": \"two\"\n}", map[string]any{"a": int64(1), "b": "two"}},
		{"single quotes", `{'a': 'b'}`, map[string]any{"a": "b"}},
		{"unquoted", `{a: b, c: true, d: null}`, map[string]any{"a": "b", "c": true, "d": nil}},
		{"integral double", `{"n": 443.0}`, map[string]any{"n": float64(443)}},
		{"fraction", `{"n": 1.5}`, map[string]any{"n": 1.5}},
		{"exponent", `{"n": 1e3}`, map[string]any{"n": float64(1000)}},
		{"non-ascii", `{"remarks":"Golden 全量配置"}`, map[string]any{"remarks": "Golden 全量配置"}},
		{"array top level", `[1,2]`, map[string]any{}},
		{"not json", `not json`, map[string]any{}},
		{"empty", ``, map[string]any{}},
	}
	for _, test := range tests {
		if got := configCustomObject(test.text); !reflect.DeepEqual(got, test.want) {
			t.Fatalf("%s: configCustomObject(%q) = %#v, want %#v", test.name, test.text, got, test.want)
		}
	}
	if got := configCustomObject(`{"n": 9007199254740993}`); !reflect.DeepEqual(got, map[string]any{"n": int64(9007199254740993)}) {
		t.Fatalf("an integer beyond 2^53 must stay exact: %#v", got)
	}
}

func TestConfigCustomEndpointAndFullConfig(t *testing.T) {
	endpoint := configParseCustom(map[string]any{
		"type": "custom", "subtype": "outbound", "config": `{"type":"wireguard","tag":"w"}`,
	})
	if !endpoint.isEndpoint() || endpoint.isFullConfig() {
		t.Fatalf("a raw wireguard outbound is an endpoint: %#v", endpoint)
	}
	plain := configParseCustom(map[string]any{
		"type": "custom", "subtype": "outbound", "config": `{"type":"socks","server":"198.51.100.9","server_port":1080}`,
	})
	if plain.isEndpoint() {
		t.Fatalf("a raw socks outbound is not an endpoint: %#v", plain)
	}
	full := configParseCustom(map[string]any{
		"type": "custom", "subtype": " fullconfig ", "config": `{"log":{"level":"warn"}}`,
	})
	if !full.isFullConfig() || full.isEndpoint() {
		t.Fatalf("a full config is neither chainable nor an endpoint: %#v", full)
	}
	if got := full.buildObject(); !reflect.DeepEqual(got, map[string]any{"log": map[string]any{"level": "warn"}}) {
		t.Fatalf("buildObject = %#v", got)
	}
}
