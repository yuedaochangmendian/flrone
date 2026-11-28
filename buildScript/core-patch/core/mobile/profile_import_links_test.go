// Oracle vectors for the S5c link importer.
//
// Each expected `json` below is the Kotlin parser's exportToJson output for
// that link (JsonObject writes sorted, compact keys), i.e. what a Kotlin
// import followed by profileExport would store. The Kotlin sources are named
// beside each test; a behavioural change there must be mirrored here.
package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func profileImportNode(t *testing.T, link string) profileImportedNode {
	t.Helper()
	node, err := profileImportOneLink(link)
	if err != nil {
		t.Fatalf("profileImportOneLink(%q): %v", link, err)
	}
	return *node
}

func profileImportRefusal(t *testing.T, link string) string {
	t.Helper()
	_, err := profileImportOneLink(link)
	if err == nil {
		t.Fatalf("link %q should have been refused", link)
	}
	refused, ok := err.(profileImportUnsupported)
	if !ok {
		t.Fatalf("error for %q is not a refusal: %T %v", link, err, err)
	}
	return refused.Reason
}

// Oracles: Http.kt:43 (parseFromLink), Outbound.kt:324 (base parse),
// DialFields.kt:68, profile_export_simple.go's stored form.
func TestProfileImportHTTPFromKotlinOracle(t *testing.T) {
	for _, tc := range []struct {
		link string
		json string
		name string
	}{
		{
			// Name from fragment, default port 80.
			"http://proxy.example.com#Home",
			`{"server":"proxy.example.com","server_port":80,"tag":"Home","type":"http"}`,
			"Home",
		},
		{
			// Plain user:password, path and paired headers.
			"http://u:p@example.com:8080?path=/x&headers=B,2,A,1",
			`{"headers":{"A":"1","B":"2"},"password":"p","path":"/x","server":"example.com","server_port":8080,"type":"http","username":"u"}`,
			"",
		},
		{
			// v2rayN base64 user:pass in the username (Http.kt:51-57).
			"http://dTpw@example.com/?path=/p",
			`{"password":"p","path":"/p","server":"example.com","server_port":80,"type":"http","username":"u"}`,
			"",
		},
		{
			// Password-only userinfo is copied to the username (Http.kt:59).
			"http://:token@example.com/",
			`{"password":"token","server":"example.com","server_port":80,"type":"http","username":"token"}`,
			"",
		},
		{
			// Dial fields are merged flat (DialFields.kt:68).
			"http://example.com?reuse_addr=true&tcp_fast_open=true&connect_timeout=5s",
			`{"connect_timeout":"5s","reuse_addr":true,"server":"example.com","server_port":80,"tcp_fast_open":true,"type":"http"}`,
			"",
		},
	} {
		node := profileImportNode(t, tc.link)
		if node.JSON != tc.json {
			t.Fatalf("%s:\n  json = %s\n  want = %s", tc.link, node.JSON, tc.json)
		}
		if node.Name != tc.name {
			t.Fatalf("%s: name = %q, want %q", tc.link, node.Name, tc.name)
		}
		if node.Type != "http" {
			t.Fatalf("%s: type = %q", tc.link, node.Type)
		}
	}
}

// Oracles: Socks.kt:51 (parseFromLink), Socks.kt:41 (parseVersion).
func TestProfileImportSocksFromKotlinOracle(t *testing.T) {
	for _, tc := range []struct {
		link string
		json string
	}{
		{
			"socks5://host#Node",
			`{"server":"host","server_port":1080,"tag":"Node","type":"socks"}`,
		},
		{
			"socks://host:1081",
			`{"server":"host","server_port":1081,"type":"socks"}`,
		},
		{
			"socks4://host",
			`{"server":"host","server_port":1080,"type":"socks","version":"4"}`,
		},
		{
			"socks4a://host:1082",
			`{"server":"host","server_port":1082,"type":"socks","version":"4a"}`,
		},
		{
			// The explicit version query wins over the scheme (Socks.kt:56).
			"socks4://host?version=5",
			`{"server":"host","server_port":1080,"type":"socks"}`,
		},
		{
			// uot value semantics: "true" or a positive int (Socks.kt:75).
			"socks5://host?uot=true",
			`{"server":"host","server_port":1080,"type":"socks","uot":true}`,
		},
		{
			"socks5://host?uot=3",
			`{"server":"host","server_port":1080,"type":"socks","uot":true}`,
		},
		{
			"socks5://host?uot=0",
			`{"server":"host","server_port":1080,"type":"socks"}`,
		},
		{
			// v2rayN base64 user:pass in username (Socks.kt:66).
			"socks5://dTpw@host",
			`{"password":"p","server":"host","server_port":1080,"type":"socks","username":"u"}`,
		},
	} {
		node := profileImportNode(t, tc.link)
		if node.JSON != tc.json {
			t.Fatalf("%s:\n  json = %s\n  want = %s", tc.link, node.JSON, tc.json)
		}
	}
}

// Oracles: Shadowsocks.kt:146 (parseFromLink), 37 (decode), 41 (methodName),
// 44 (pluginName), profile_export_simple.go's stored form.
func TestProfileImportShadowsocksFromKotlinOracle(t *testing.T) {
	legacyUser := profileBase64Encode([]byte("aes-256-gcm:secret"), true, true)
	for _, tc := range []struct {
		link string
		json string
	}{
		{
			// SIP002 plain method:password userinfo.
			"ss://aes-256-gcm:secret@host:8388#SS",
			`{"method":"aes-256-gcm","password":"secret","server":"host","server_port":8388,"tag":"SS","type":"shadowsocks"}`,
		},
		{
			// Legacy base64 userinfo (url-safe, padded).
			"ss://" + legacyUser + "@host:8388",
			`{"method":"aes-256-gcm","password":"secret","server":"host","server_port":8388,"type":"shadowsocks"}`,
		},
		{
			// 2022 method:key is plain userinfo too.
			"ss://2022-blake3-aes-128-gcm:key@host:443",
			`{"method":"2022-blake3-aes-128-gcm","password":"key","server":"host","server_port":443,"type":"shadowsocks"}`,
		},
		{
			// Method names are trimmed/lowercased; plugin names normalize.
			"ss://AES-256-GCM:secret@host:8388?plugin=simple-obfs%3Bobfs%3Dhttp",
			`{"method":"aes-256-gcm","password":"secret","plugin":"obfs-local","plugin_opts":"obfs=http","server":"host","server_port":8388,"type":"shadowsocks"}`,
		},
		{
			// plugin-opts overrides the plugin spec's options (Shadowsocks.kt:190).
			"ss://aes-256-gcm:secret@host:8388?plugin=obfs-local&plugin-opts=mode%3Dtls",
			`{"method":"aes-256-gcm","password":"secret","plugin":"obfs-local","plugin_opts":"mode=tls","server":"host","server_port":8388,"type":"shadowsocks"}`,
		},
		{
			"ss://aes-256-gcm:secret@host:8388?uot=1",
			`{"method":"aes-256-gcm","password":"secret","server":"host","server_port":8388,"type":"shadowsocks","udp_over_tcp":true}`,
		},
	} {
		node := profileImportNode(t, tc.link)
		if node.JSON != tc.json {
			t.Fatalf("%s:\n  json = %s\n  want = %s", tc.link, node.JSON, tc.json)
		}
	}
}

func TestProfileImportReplyFields(t *testing.T) {
	node := profileImportNode(t, "http://u:p@example.com:8080#H")
	if !strings.HasPrefix(node.DedupKey, "throne://add/") {
		t.Fatalf("dedup key = %q", node.DedupKey)
	}
	if node.Identity != `{"server":"example.com","server_port":8080}` {
		t.Fatalf("identity = %s", node.Identity)
	}
	if node.Link != "http://u:p@example.com:8080#H" {
		t.Fatalf("link = %q", node.Link)
	}
	// The stored JSON and the dedup payload must use the exporter's own
	// canonical form: decoding the key drops the name.
	decoded, ok := profileBase64Decode(strings.TrimPrefix(node.DedupKey, "throne://add/"), true)
	if !ok {
		t.Fatal("dedup key payload is not base64url")
	}
	if string(decoded) != `{"password":"p","server":"example.com","server_port":8080,"type":"http","username":"u"}` {
		t.Fatalf("dedup payload = %s", decoded)
	}
}

func TestProfileImportRefusals(t *testing.T) {
	for _, tc := range []struct {
		link   string
		reason string
	}{
		{"http://example.com?security=tls", "https/security=tls"},
		{"https://example.com", "https/security=tls"},
		{"http://example.com?headers=A,1,B", "odd number of http headers"},
		{"ss://YWVzLTI1Ni1nY206c2VjcmV0@host:8388?mux=true", "multiplex"},
		{"ss://not!base64@host:8388", "not valid base64"},
		{"vmess://eyJ2IjoiMiJ9", "not ported yet"},
		{"vless://uuid@host:443?security=tls", "not ported yet"},
		{"trojan://pass@host:443", "not ported yet"},
		{"hysteria2://pass@host:443", "not ported yet"},
		{"http://exa mple.com", "malformed link"},
		{"not-a-link", "no URL scheme"},
		{"", "empty text"},
		{"http://a\nhttp://b", "multiple lines"},
	} {
		reason := profileImportRefusal(t, tc.link)
		if !strings.Contains(reason, tc.reason) {
			t.Fatalf("%q: reason = %q, want it to contain %q", tc.link, reason, tc.reason)
		}
	}
}

// The v2rayN all-base64 SS body has no '@' before the fragment.
func TestProfileImportRefusesBase64Body(t *testing.T) {
	body := profileBase64Encode([]byte("aes-256-gcm:secret@host:8388"), true, true)
	reason := profileImportRefusal(t, "ss://"+body+"#N")
	if !strings.Contains(reason, "base64-body") {
		t.Fatalf("reason = %q", reason)
	}
}

// Host forms Qt would rewrite differently are refused, not approximated.
func TestProfileImportRefusesUnportedHostForms(t *testing.T) {
	for _, link := range []string{
		"http://127.1/",              // C-style IPv4 shorthand
		"http://0x7f.1/",             // hex C-number shorthand
		"http://[::ffff:192.0.2.1]/", // embedded IPv4
		"http://[fe80::1%25eth0]/",   // bracketed zone
	} {
		_ = profileImportRefusal(t, link)
	}
}

func TestProfileImportActionContract(t *testing.T) {
	if actionHandlers[profileImportMethod] == nil {
		t.Fatal("profileImport has no registered handler")
	}
	payload, err := json.Marshal(profileImportRequest{Text: "socks5://host"})
	if err != nil {
		t.Fatal(err)
	}
	reply, err := handleProfileImport(payload)
	if err != nil {
		t.Fatal(err)
	}
	accepted, ok := reply.(profileImportReply)
	if !ok || !accepted.Supported || len(accepted.Nodes) != 1 {
		t.Fatalf("reply = %+v", reply)
	}
	refusal, err := handleProfileImport(json.RawMessage(`{"text":"trojan://p@host"}`))
	if err != nil {
		t.Fatal(err)
	}
	rejected, ok := refusal.(profileImportReply)
	if !ok || rejected.Supported || len(rejected.Nodes) != 0 || rejected.Reason == "" {
		t.Fatalf("refusal = %+v", rejected)
	}
	if _, err := handleProfileImport(json.RawMessage(`{}`)); err == nil {
		t.Fatal("missing text field was accepted")
	}
}
