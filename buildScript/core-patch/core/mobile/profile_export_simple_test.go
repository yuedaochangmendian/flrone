package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func profileExportReplyFor(t *testing.T, document string, name *string) profileExportReply {
	t.Helper()
	payload, err := json.Marshal(profileExportRequest{JSON: &document, Name: name})
	if err != nil {
		t.Fatal(err)
	}
	reply, err := handleProfileExport(payload)
	if err != nil {
		t.Fatalf("handleProfileExport: %v", err)
	}
	return reply.(profileExportReply)
}

func TestProfileExportDirect(t *testing.T) {
	reply := profileExportReplyFor(t, `{"type":"direct","tag":"D","reuse_addr":true}`, nil)
	if !reply.Supported || reply.DisplayType != "Direct" {
		t.Fatalf("reply = %+v", reply)
	}
	if reply.JSON != `{"reuse_addr":true,"tag":"D","type":"direct"}` {
		t.Fatalf("json = %s", reply.JSON)
	}
	if reply.Link != "reuse_addr=true" {
		t.Fatalf("direct link = %q", reply.Link)
	}
	if !strings.HasPrefix(reply.DedupKey, "throne://add/") {
		t.Fatalf("dedup key = %q", reply.DedupKey)
	}
	decoded := strings.TrimPrefix(reply.DedupKey, "throne://add/")
	raw, ok := profileBase64Decode(decoded, true)
	if !ok {
		t.Fatalf("dedup key payload is not base64url: %q", decoded)
	}
	if string(raw) != `{"reuse_addr":true,"type":"direct"}` {
		t.Fatalf("dedup payload = %s", raw)
	}
}

func TestProfileExportHTTP(t *testing.T) {
	reply := profileExportReplyFor(t, `{
		"type":"http","tag":"H","server":"Example.COM","server_port":8080,
		"username":"u","password":"p","path":"/x",
		"headers":{"B":"2","A":"1"},"connect_timeout":"5s"
	}`, nil)
	if !reply.Supported || reply.DisplayType != "HTTP" {
		t.Fatalf("reply = %+v", reply)
	}
	if want := `{"connect_timeout":"5s","headers":{"A":"1","B":"2"},"password":"p","path":"/x","server":"Example.COM","server_port":8080,"tag":"H","type":"http","username":"u"}`; reply.JSON != want {
		t.Fatalf("json = %s\nwant %s", reply.JSON, want)
	}
	if want := "http://u:p@example.com:8080?path=/x&headers=A,1,B,2&connect_timeout=5s#H"; reply.Link != want {
		t.Fatalf("link = %q\nwant %q", reply.Link, want)
	}
	if want := `{"server":"Example.COM","server_port":8080}`; reply.Identity != want {
		t.Fatalf("identity = %s", reply.Identity)
	}
}

func TestProfileExportUnsupported(t *testing.T) {
	reply := profileExportReplyFor(t, `{"type":"vless","server":"host","server_port":443}`, nil)
	if reply.Supported {
		t.Fatalf("vless should be unsupported: %+v", reply)
	}
	if reply.Type != "vless" {
		t.Fatalf("type = %q", reply.Type)
	}

	tls := profileExportReplyFor(t, `{"type":"http","server":"host","server_port":443,"tls":{"enabled":true}}`, nil)
	if tls.Supported {
		t.Fatalf("http+tls should be unsupported: %+v", tls)
	}
}

func TestProfileExportNameOverride(t *testing.T) {
	name := "Renamed"
	reply := profileExportReplyFor(t, `{"type":"direct","tag":"Old"}`, &name)
	if reply.Name != "Renamed" || reply.JSON != `{"tag":"Renamed","type":"direct"}` {
		t.Fatalf("reply = %+v", reply)
	}
}

func TestProfileExportSocksVersions(t *testing.T) {
	for _, tc := range []struct {
		document string
		version  string
		link     string
	}{
		{`{"type":"socks","server":"host","server_port":1080}`, "", "socks5://host:1080"},
		{`{"type":"socks","server":"host","server_port":1080,"version":"4"}`, "4", "socks4://host:1080"},
		{`{"type":"socks","server":"host","server_port":1080,"version":"4a"}`, "4a", "socks4a://host:1080"},
		{`{"type":"socks","server":"host","server_port":1080,"uot":true}`, "", "socks5://host:1080?uot=1"},
	} {
		reply := profileExportReplyFor(t, tc.document, nil)
		if !reply.Supported || reply.Link != tc.link {
			t.Fatalf("%s: reply = %+v", tc.document, reply)
		}
		if tc.version != "" && !strings.Contains(reply.JSON, `"version":"`+tc.version+`"`) {
			t.Fatalf("%s: json = %s", tc.document, reply.JSON)
		}
	}
}

func TestProfileExportShadowsocksLink(t *testing.T) {
	reply := profileExportReplyFor(t, `{
		"type":"shadowsocks","server":"host","server_port":8388,
		"method":"aes-256-gcm","password":"secret","tag":"SS"
	}`, nil)
	if !reply.Supported {
		t.Fatalf("reply = %+v", reply)
	}
	user := profileBase64Encode([]byte("aes-256-gcm:secret"), true, true)
	if want := "ss://" + user + "@host:8388#SS"; reply.Link != want {
		t.Fatalf("link = %q\nwant %q", reply.Link, want)
	}
	if !strings.Contains(reply.JSON, `"method":"aes-256-gcm"`) ||
		!strings.Contains(reply.JSON, `"password":"secret"`) {
		t.Fatalf("json = %s", reply.JSON)
	}
}

func TestProfileExportRejectsMalformed(t *testing.T) {
	for _, document := range []string{``, `{`, `[]`} {
		payload, _ := json.Marshal(profileExportRequest{JSON: &document})
		if _, err := handleProfileExport(payload); err == nil {
			t.Fatalf("document %q should fail", document)
		}
	}
	if _, err := handleProfileExport(json.RawMessage(`{}`)); err == nil {
		t.Fatal("missing json field should fail")
	}
}
