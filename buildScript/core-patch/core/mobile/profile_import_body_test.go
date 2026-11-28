// S5d subscription-body import tests. The single-link vectors are the Kotlin
// oracle pinned in profile_import_links_test.go / profile_import_advanced_test.go;
// body tests reuse those exact nodes and assert the all-or-nothing contract.
package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func importBody(t *testing.T, body string) []profileImportedNode {
	t.Helper()
	nodes, err := profileImportBody(body)
	if err != nil {
		t.Fatalf("profileImportBody(%q): %v", snippet(body), err)
	}
	return nodes
}

func refuseBody(t *testing.T, body string) string {
	t.Helper()
	_, err := profileImportBody(body)
	if err == nil {
		t.Fatalf("body %q should have been refused", snippet(body))
	}
	refused, ok := err.(profileImportUnsupported)
	if !ok {
		t.Fatalf("error for %q is not a refusal: %T %v", snippet(body), err, err)
	}
	return refused.Reason
}

func snippet(text string) string {
	if len(text) > 120 {
		return text[:120] + "…"
	}
	return text
}

func typesOf(nodes []profileImportedNode) []string {
	out := make([]string, 0, len(nodes))
	for _, node := range nodes {
		out = append(out, node.Type)
	}
	return out
}

// A single supported link still returns exactly one node (the old contract).
func TestProfileBodySingleLink(t *testing.T) {
	nodes := importBody(t, "http://proxy.example.com#Home")
	if len(nodes) != 1 || nodes[0].Type != "http" || nodes[0].Name != "Home" {
		t.Fatalf("nodes = %+v", nodes)
	}
	if nodes[0].JSON != `{"server":"proxy.example.com","server_port":80,"tag":"Home","type":"http"}` {
		t.Fatalf("json = %s", nodes[0].JSON)
	}
}

func TestProfileBodySingleLinkRefusal(t *testing.T) {
	reason := refuseBody(t, "https://example.com")
	if !strings.Contains(reason, "https/security=tls") {
		t.Fatalf("reason = %q", reason)
	}
}

// Multi-line body: order preserved, comments / routing skipped, every entry
// parsed by the single-link path.
func TestProfileBodyMultilineOrderAndSkips(t *testing.T) {
	body := strings.Join([]string{
		"# subscription",
		"",
		"http://a.example.com#One",
		"  # indented comment",
		"// clipboard note",
		"happ://routing/add?type=a",
		"shadowrocket://routing/add?type=b",
		"socks5://b.example.com:1081#Two",
		"ss://aes-256-gcm:secret@c.example.com:8388#Three",
	}, "\n")
	nodes := importBody(t, body)
	want := []string{"http", "socks", "shadowsocks"}
	if len(nodes) != len(want) {
		t.Fatalf("nodes = %+v", nodes)
	}
	for index, node := range nodes {
		if node.Type != want[index] {
			t.Fatalf("node %d type = %q, want %q", index, node.Type, want[index])
		}
	}
	if nodes[0].Name != "One" || nodes[1].Name != "Two" || nodes[2].Name != "Three" {
		t.Fatalf("order lost: %+v", nodes)
	}
}

// A single refusal anywhere in the body discards ALL nodes, even ones already
// parsed.
func TestProfileBodyMultilineAllOrNothing(t *testing.T) {
	for _, bad := range []string{
		"https://tls.example.com",
		"trojan://p@example.com?mux=true",
		"not-a-link",
		"vmess://eyJ2IjoiMiIsImZvbyI6ImJhciJ9",
	} {
		body := "socks5://ok.example.com\n" + bad + "\nhttp://also-ok.example.com"
		reason := refuseBody(t, body)
		if reason == "" {
			t.Fatalf("%q: empty reason", bad)
		}
	}
}

// Dedup uses the same dedupKey the exporter emits: a name-only change of the
// same outbound collapses to the first entry.
func TestProfileBodyDedup(t *testing.T) {
	nodes := importBody(t, "http://a.example.com#First\nhttp://a.example.com#Second\nsocks5://b.example.com")
	if len(nodes) != 2 {
		t.Fatalf("nodes = %+v", typesOf(nodes))
	}
	if nodes[0].Name != "First" || nodes[1].Type != "socks" {
		t.Fatalf("dedup kept the wrong entry: %+v", nodes)
	}
}

// Base64 text: standard / URL-safe / MIME-wrapped, including base64 of a JSON
// body. The decoded text is recursed through the same dispatcher.
func TestProfileBodyBase64(t *testing.T) {
	plain := "http://a.example.com#One\nsocks5://b.example.com#Two"
	for name, encoded := range map[string]string{
		"std":  profileBase64Encode([]byte(plain), false, true),
		"url":  profileBase64Encode([]byte(plain), true, true),
		"mime": wrapMIME(profileBase64Encode([]byte(plain), false, true), 16),
	} {
		t.Run(name, func(t *testing.T) {
			nodes := importBody(t, encoded)
			if len(nodes) != 2 || typesOf(nodes)[0] != "http" || typesOf(nodes)[1] != "socks" {
				t.Fatalf("nodes = %+v", nodes)
			}
			if nodes[0].Name != "One" || nodes[1].Name != "Two" {
				t.Fatalf("order lost: %+v", nodes)
			}
		})
	}
}

func TestProfileBodyBase64OfJSON(t *testing.T) {
	doc := `{"type":"socks","server":"a.example.com","server_port":1080,"tag":"S"}`
	encoded := profileBase64Encode([]byte(doc), false, false)
	nodes := importBody(t, encoded)
	if len(nodes) != 1 || nodes[0].Type != "socks" || nodes[0].Name != "S" {
		t.Fatalf("nodes = %+v", nodes)
	}
}

// A base64 body whose decoded bytes are not themselves a valid body is a
// refusal, never a partial success.
func TestProfileBodyBase64Bad(t *testing.T) {
	for _, encoded := range []string{
		profileBase64Encode([]byte("garbage that is not a link or a body"), false, false),
		profileBase64Encode([]byte("ok-link\nhttps://tls.example.com"), false, false),
		"not!valid!base64!",
	} {
		_ = refuseBody(t, encoded)
	}
}

// MIME wrapping with comments / blank lines and CRLF also decodes.
func TestProfileBodyBase64MIMEWithComments(t *testing.T) {
	plain := "ss://aes-256-gcm:secret@a.example.com:8388#S"
	encoded := wrapMIME(profileBase64Encode([]byte(plain), false, true), 12)
	body := "# subscription\r\n" + encoded + "\r\n# end"
	nodes := importBody(t, body)
	if len(nodes) != 1 || nodes[0].Type != "shadowsocks" {
		t.Fatalf("nodes = %+v", nodes)
	}
}

func wrapMIME(text string, width int) string {
	var out strings.Builder
	for index := 0; index < len(text); index += width {
		if index > 0 {
			out.WriteString("\r\n")
		}
		end := index + width
		if end > len(text) {
			end = len(text)
		}
		out.WriteString(text[index:end])
	}
	return out.String()
}

// JSON bodies: sing-box outbound object, array of outbounds, SIP008 servers.
func TestProfileBodyJSONObject(t *testing.T) {
	nodes := importBody(t, `{"type":"http","server":"a.example.com","server_port":8080,"tag":"H","username":"u","password":"p"}`)
	if len(nodes) != 1 || nodes[0].Type != "http" || nodes[0].Name != "H" {
		t.Fatalf("nodes = %+v", nodes)
	}
	if !strings.Contains(nodes[0].JSON, `"username":"u"`) {
		t.Fatalf("json = %s", nodes[0].JSON)
	}
}

func TestProfileBodyJSONArray(t *testing.T) {
	body := `[` +
		`{"type":"socks","server":"a.example.com","server_port":1080,"tag":"S"},` +
		`{"type":"shadowsocks","server":"b.example.com","server_port":8388,"method":"aes-256-gcm","password":"pw"}` +
		`]`
	nodes := importBody(t, body)
	if len(nodes) != 2 || typesOf(nodes)[0] != "socks" || typesOf(nodes)[1] != "shadowsocks" {
		t.Fatalf("nodes = %+v", nodes)
	}
}

func TestProfileBodySIP008(t *testing.T) {
	body := `{"version":1,"servers":[` +
		`{"server":"a.example.com","server_port":8388,"method":"aes-256-gcm","password":"pw","name":"A"},` +
		`{"server":"b.example.com","server_port":8388,"method":"2022-blake3-aes-128-gcm","password":"key"}` +
		`]}`
	nodes := importBody(t, body)
	if len(nodes) != 2 {
		t.Fatalf("nodes = %+v", nodes)
	}
	for _, node := range nodes {
		if node.Type != "shadowsocks" {
			t.Fatalf("type = %q", node.Type)
		}
	}
	if nodes[0].Name != "A" {
		t.Fatalf("name = %q", nodes[0].Name)
	}
}

func TestProfileBodySIP008WithType(t *testing.T) {
	body := `{"servers":[` +
		`{"type":"vless","server":"a.example.com","server_port":443,"uuid":"u","encryption":"none"},` +
		`{"type":"shadowsocks","server":"b.example.com","server_port":8388,"method":"aes-256-gcm","password":"pw"}` +
		`]}`
	nodes := importBody(t, body)
	if len(nodes) != 2 || nodes[0].Type != "vless" || nodes[1].Type != "shadowsocks" {
		t.Fatalf("nodes = %+v", nodes)
	}
}

func TestProfileBodyJSONSingBoxAdvanced(t *testing.T) {
	body := `{"type":"vless","server":"v.example.com","server_port":443,` +
		`"uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","encryption":"none",` +
		`"tag":"V","tls":{"enabled":true,"server_name":"sni.example.com"},` +
		`"transport":{"type":"ws","path":"/ws"}}`
	nodes := importBody(t, body)
	if len(nodes) != 1 || nodes[0].Type != "vless" || nodes[0].Name != "V" {
		t.Fatalf("nodes = %+v", nodes)
	}
	if !strings.Contains(nodes[0].JSON, `"server_name":"sni.example.com"`) ||
		!strings.Contains(nodes[0].JSON, `"path":"/ws"`) {
		t.Fatalf("json = %s", nodes[0].JSON)
	}
}

func TestProfileBodyJSONUnsupportedType(t *testing.T) {
	for _, body := range []string{
		`{"type":"anytls","server":"a.example.com","server_port":443}`,
		`{"type":"vless","server":"a.example.com","server_port":443,"uuid":"u","unknown":1}`,
		`{"type":"socks","server":"a.example.com","server_port":1080,"future_field":true}`,
		`{"type":"vmess","server":"a.example.com","server_port":443,"uuid":"u","tls":{"enabled":true,"certificate":"x"}}`,
		`{"servers":[{"server":"a.example.com","server_port":8388,"method":"aes-256-gcm","password":"p","weird":1}]}`,
		`{"servers":{}}`,
		`{"outbounds":[]}`,
		`[{"type":"http","server":"a.example.com","server_port":80},{"type":"mieru","server":"b.example.com","server_port":443}]`,
	} {
		_ = refuseBody(t, body)
	}
}

// A JSON body with one supported and one unsupported entry emits no nodes.
func TestProfileBodyJSONAllOrNothing(t *testing.T) {
	body := `[{"type":"http","server":"a.example.com","server_port":80},` +
		`{"type":"tuic","server":"b.example.com","server_port":443}]`
	_ = refuseBody(t, body)
}

// The Clash hook refuses clearly until the other agent's converter is wired.
func TestProfileBodyClashHook(t *testing.T) {
	reason := refuseBody(t, "proxies:\n  - name: a\n    type: ss\n    server: a.example.com\n    port: 8388")
	if !strings.Contains(strings.ToLower(reason), "clash") {
		t.Fatalf("reason = %q", reason)
	}
}

// Oversized base64 bodies are refused before decoding. 64 MiB of decoded
// bytes needs ~85 MiB of encoded input, so a body that large trips the cap.
func TestProfileBodyBase64Cap(t *testing.T) {
	// 4/3 of the decoded cap plus slack: decoding this would exceed 64 MiB.
	const encodedLen = profileBodyMaxDecoded/3*4 + 8
	body := strings.Repeat("A", encodedLen)
	reason := refuseBody(t, body)
	if !strings.Contains(reason, "exceeds") {
		t.Fatalf("reason = %q", reason)
	}
}

// The action contract keeps the same reply shape for bodies: a supported body
// returns nodes, a refusal returns only a reason.
func TestProfileBodyActionContract(t *testing.T) {
	payload, err := json.Marshal(profileImportRequest{Text: "socks5://h1.example.com\nsocks5://h2.example.com"})
	if err != nil {
		t.Fatal(err)
	}
	reply, err := handleProfileImport(payload)
	if err != nil {
		t.Fatal(err)
	}
	accepted, ok := reply.(profileImportReply)
	if !ok || !accepted.Supported || len(accepted.Nodes) != 2 {
		t.Fatalf("reply = %+v", reply)
	}

	refusal, err := handleProfileImport(json.RawMessage(`{"text":"socks5://ok.example.com\nhttps://tls.example.com"}`))
	if err != nil {
		t.Fatal(err)
	}
	rejected, ok := refusal.(profileImportReply)
	if !ok || rejected.Supported || len(rejected.Nodes) != 0 || rejected.Reason == "" {
		t.Fatalf("refusal = %+v", rejected)
	}
}
