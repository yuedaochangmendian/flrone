// S5 TLS3: the normalization and host-parity vectors added when the remaining
// S5 refusals were closed. Every expected JSON string is the byte sequence the
// Kotlin oracle (ProfileStoredGoParityTest) pins for the same input.
package mobile

import (
	"strings"
	"testing"
)

func TestProfileQtHostNormalization(t *testing.T) {
	for _, tc := range []struct {
		raw   string
		want  string
		valid bool
	}{
		{"127.1", "127.0.0.1", true},
		{"0x7f.1", "127.0.0.1", true},
		{"032.1", "26.0.0.1", true},
		{"2130706433", "127.0.0.1", true},
		{"127.0.0.1", "127.0.0.1", true},
		{"example.com", "example.com", true},
		{"EX%41MPLE.COM", "example.com", true},
		{"a_b.example", "a_b.example", true},
		{"[::1]", "::1", true},
		{"[::ffff:1.2.3.4]", "::ffff:1.2.3.4", true},
		{"[fe80::1%25eth0]", "fe80::1%25eth0", true},
		{"[fe80::1%eth0]", "fe80::1%25eth0", true},
		{"", "", true},
		{"[::1", "", false},
		{"[fe80::1%]", "", false},
		{"1.2.3.4.5", "1.2.3.4.5", true},
	} {
		got, ok := profileHostNormalize(tc.raw)
		if ok != tc.valid || got != tc.want {
			t.Fatalf("normalize(%q) = %q,%v want %q,%v", tc.raw, got, ok, tc.want, tc.valid)
		}
	}
}

// A V2RayN body ignores keys Kotlin does not read, normalizes an unknown
// cipher and insecure cipher suites away, keeps the raw-HTTP GET transport and
// reads throneExtra exactly like Vmess.parseV2RayN.
func TestProfileImportV2RayNUnknownFieldsAndExtra(t *testing.T) {
	body := `{"v":"2","ps":"N","add":"h.example.com","port":"8443","id":"uuid","aid":"4",` +
		`"net":"tcp","type":"http","host":"cdn.example.com","path":"/a,/b","tls":"tls",` +
		`"sni":"sni.example.com","scy":"bogus","cs":"TLS_AES_128_GCM_SHA256:TLS_RSA_WITH_RC4_128_SHA",` +
		`"fp":"bogus","unknownKey":"x","throneExtra":"mux=true&mux_protocol=smux"}`
	link := "vmess://" + profileBase64Encode([]byte(body), false, true)
	node, err := profileImportOneLink(link)
	if err != nil {
		t.Fatalf("%v", err)
	}
	want := `{"alter_id":4,"multiplex":{"enabled":true,"protocol":"smux"},"packet_encoding":"xudp",` +
		`"server":"h.example.com","server_port":8443,"tag":"N",` +
		`"tls":{"cipher_suites":["TLS_AES_128_GCM_SHA256"],"enabled":true,"server_name":"sni.example.com"},` +
		`"transport":{"host":"cdn.example.com","method":"GET","path":"/a","type":"http"},` +
		`"type":"vmess","uuid":"uuid"}`
	if node.JSON != want {
		t.Fatalf("json = %s; want %s", node.JSON, want)
	}

	// The warning-free variant JVM ProfileStoredGoParityTest pins: every value
	// is valid, so the same bytes must come back.
	pinned := "vmess://eyJ2IjoiMiIsInBzIjoiTiIsImFkZCI6ImguZXhhbXBsZS5jb20iLCJwb3J0IjoiODQ0MyIsImlkIjoidXVpZCIsImFpZCI6IjQiLCJuZXQiOiJ0Y3AiLCJ0eXBlIjoiaHR0cCIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJwYXRoIjoiL2EsL2IiLCJ0bHMiOiJ0bHMiLCJzbmkiOiJzbmkuZXhhbXBsZS5jb20iLCJzY3kiOiJhdXRvIiwiY3MiOiJUTFNfQUVTXzEyOF9HQ01fU0hBMjU2IiwiZnAiOiJjaHJvbWUiLCJ1bmtub3duS2V5IjoieCIsInRocm9uZUV4dHJhIjoibXV4PXRydWUmbXV4X3Byb3RvY29sPXNtdXgifQ=="
	pinnedWant := `{"alter_id":4,"multiplex":{"enabled":true,"protocol":"smux"},"packet_encoding":"xudp",` +
		`"server":"h.example.com","server_port":8443,"tag":"N",` +
		`"tls":{"cipher_suites":["TLS_AES_128_GCM_SHA256"],"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},` +
		`"transport":{"host":"cdn.example.com","method":"GET","path":"/a","type":"http"},` +
		`"type":"vmess","uuid":"uuid"}`
	pinnedNode, err := profileImportOneLink(pinned)
	if err != nil {
		t.Fatalf("%v", err)
	}
	if pinnedNode.JSON != pinnedWant {
		t.Fatalf("pinned json = %s; want %s", pinnedNode.JSON, pinnedWant)
	}
}

// Unknown security / packet encodings normalize like vmessImportSecurity and
// *ImportPacketEncoding; the URL form ignores throneExtra and pinSHA256.
func TestProfileImportVmessVlessNormalization(t *testing.T) {
	for _, tc := range []struct{ link, json string }{
		{
			"vmess://uuid@host:443?encryption=bogus&packetEncoding=bogus&throneExtra=mux%3Dtrue&pinSHA256=abc",
			`{"packet_encoding":"xudp","server":"host","server_port":443,"type":"vmess","uuid":"uuid"}`,
		},
		{
			"vless://uuid@host:443?packetEncoding=bogus&throneExtra=mux%3Dtrue&pinSHA256=abc",
			`{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"type":"vless","uuid":"uuid"}`,
		},
	} {
		node, err := profileImportOneLink(tc.link)
		if err != nil {
			t.Fatalf("%s: %v", tc.link, err)
		}
		if node.JSON != tc.json {
			t.Fatalf("%s: json = %s; want %s", tc.link, node.JSON, tc.json)
		}
	}
}

// Stored JSON bodies carry a TLS-bearing http entry and a multiplex block now;
// a block without `enabled` stays unspecified and exports no multiplex key.
func TestProfileImportStoredTLSAndMultiplex(t *testing.T) {
	for _, tc := range []struct{ body, json string }{
		{
			`{"type":"http","server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"s"}}`,
			`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"s"},"type":"http"}`,
		},
		{
			`{"type":"vmess","server":"h","server_port":443,"uuid":"u","packet_encoding":"xudp","multiplex":{"enabled":true,"protocol":"bogus","max_streams":8}}`,
			`{"multiplex":{"enabled":true,"max_streams":8},"packet_encoding":"xudp","server":"h","server_port":443,"type":"vmess","uuid":"u"}`,
		},
		{
			`{"type":"vmess","server":"h","server_port":443,"uuid":"u","packet_encoding":"xudp","multiplex":{"protocol":"smux"}}`,
			`{"packet_encoding":"xudp","server":"h","server_port":443,"type":"vmess","uuid":"u"}`,
		},
	} {
		nodes := importBody(t, tc.body)
		if len(nodes) != 1 {
			t.Fatalf("%s: nodes = %+v", tc.body, nodes)
		}
		if nodes[0].JSON != tc.json {
			t.Fatalf("%s: json = %s; want %s", tc.body, nodes[0].JSON, tc.json)
		}
	}
}

// The imported http TLS identity keeps the canonical tls identity object.
func TestProfileImportHTTPTLSIdentity(t *testing.T) {
	node, err := profileImportOneLink("https://h.example.com")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(node.Identity, `"tls":{"enabled":true}`) {
		t.Fatalf("identity = %s", node.Identity)
	}
}
