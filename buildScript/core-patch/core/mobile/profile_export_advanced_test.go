// Oracle vectors for the S5 export advanced slice. Every expected string is
// the Kotlin Outbound.exportToJson/exportToLink/exportIdentity output for the
// same stored document, pinned by ProfileStoredGoParityTest.kt.
package mobile

import (
	"strings"
	"testing"
)

const (
	exportTestUUID = "b831381d-6324-4d53-ad4f-8cda48b30811"

	vmessWSJSON = `{"packet_encoding":"xudp","server":"example.com","server_port":443,"tag":"node","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vmess","uuid":"` + exportTestUUID + `"}`
	vmessWSLink = "vmess://eyJhZGQiOiJleGFtcGxlLmNvbSIsImFpZCI6IjAiLCJhbHBuIjoiaDIsaHR0cC8xLjEiLCJmcCI6ImNocm9tZSIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJpZCI6ImI4MzEzODFkLTYzMjQtNGQ1My1hZDRmLThjZGE0OGIzMDgxMSIsIm5ldCI6IndzIiwicGF0aCI6Ii93cyIsInBvcnQiOiI0NDMiLCJwcyI6Im5vZGUiLCJzY3kiOiJhdXRvIiwic25pIjoic25pLmV4YW1wbGUuY29tIiwidGhyb25lRXh0cmEiOiJ0eXBlPXdzJmhvc3Q9Y2RuLmV4YW1wbGUuY29tJnBhdGg9L3dzIiwidGxzIjoidGxzIiwidHlwZSI6Im5vbmUiLCJ2IjoiMiJ9"
	vmessWSID   = `{"server":"example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}},"transport":{"type":"ws"}}`

	vlessWSJSON = `{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"node","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"vless","uuid":"` + exportTestUUID + `"}`
	vlessWSLink = "vless://" + exportTestUUID + "@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=/ws&packetEncoding=xudp#node"
	vlessWSID   = `{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}`

	vlessRealityJSON = `{"encryption":"none","flow":"xtls-rprx-vision","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"` + exportTestUUID + `"}`
	vlessRealityLink = "vless://" + exportTestUUID + "@vless.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=sni.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&packetEncoding=xudp#r"
	vlessRealityID   = `{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`

	trojanWSJSON = `{"password":"pass","server":"trojan.example.com","server_port":443,"tag":"t","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"Host":"h.example.com"},"path":"/ws","type":"ws"},"type":"trojan"}`
	trojanWSLink = "trojan://pass@trojan.example.com:443?security=tls&sni=sni.example.com&alpn=h2,http/1.1&type=ws&host=h.example.com&path=/ws#t"
	trojanWSID   = `{"server":"trojan.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}`

	hy1JSON = `{"auth_str":"secret","down_mbps":50,"obfs":"obfs-secret","recv_window":20,"recv_window_conn":10,"server":"host.example.com","server_port":443,"tag":"hy1","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"hysteria","up_mbps":100}`
	hy1Link = "hysteria://host.example.com:443?obfsParam=obfs-secret&auth=secret&recv_window_conn=10&recv_window=20&upmbps=100&downmbps=50&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h3#hy1"
	hy1ID   = `{"obfs":true,"protocol_version":"1","server":"host.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`

	hy2JSON = `{"down_mbps":50,"obfs":{"max_packet_size":1200,"min_packet_size":512,"password":"obfs-secret","type":"gecko"},"password":"password","server":"host.example.com","server_port":443,"tag":"hy2","tls":{"alpn":["h3"],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}`
	hy2Link = "hysteria2://password@host.example.com:443?obfs=gecko&obfs-password=obfs-secret&min_packet_size=512&max_packet_size=1200&upmbps=100&downmbps=50&security=tls&sni=sni.example.com&alpn=h3#hy2"
	hy2ID   = `{"obfs":true,"protocol_version":"2","server":"host.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`
)

func assertAdvancedExport(t *testing.T, document, wantJSON, wantLink, wantID string) profileExportReply {
	t.Helper()
	reply := profileExportReplyFor(t, document, nil)
	if !reply.Supported {
		t.Fatalf("not supported: %s (reason %q)", document, reply.Reason)
	}
	if reply.JSON != wantJSON {
		t.Fatalf("json:\n  got  %s\n  want %s", reply.JSON, wantJSON)
	}
	if reply.Link != wantLink {
		t.Fatalf("link:\n  got  %s\n  want %s", reply.Link, wantLink)
	}
	if reply.Identity != wantID {
		t.Fatalf("identity:\n  got  %s\n  want %s", reply.Identity, wantID)
	}
	return reply
}

func TestProfileExportAdvancedVmess(t *testing.T) {
	reply := assertAdvancedExport(t, vmessWSJSON, vmessWSJSON, vmessWSLink, vmessWSID)
	if reply.DisplayType != "VMess" {
		t.Fatalf("displayType = %q", reply.DisplayType)
	}
}

func TestProfileExportAdvancedVless(t *testing.T) {
	reply := assertAdvancedExport(t, vlessWSJSON, vlessWSJSON, vlessWSLink, vlessWSID)
	if reply.DisplayType != "VLESS" {
		t.Fatalf("displayType = %q", reply.DisplayType)
	}
}

func TestProfileExportAdvancedVlessReality(t *testing.T) {
	assertAdvancedExport(t, vlessRealityJSON, vlessRealityJSON, vlessRealityLink, vlessRealityID)
}

func TestProfileExportAdvancedTrojan(t *testing.T) {
	reply := assertAdvancedExport(t, trojanWSJSON, trojanWSJSON, trojanWSLink, trojanWSID)
	if reply.DisplayType != "Trojan" {
		t.Fatalf("displayType = %q", reply.DisplayType)
	}
}

func TestProfileExportAdvancedHysteria(t *testing.T) {
	reply := assertAdvancedExport(t, hy1JSON, hy1JSON, hy1Link, hy1ID)
	if reply.DisplayType != "Hysteria" {
		t.Fatalf("displayType = %q", reply.DisplayType)
	}
}

func TestProfileExportAdvancedHysteria2(t *testing.T) {
	assertAdvancedExport(t, hy2JSON, hy2JSON, hy2Link, hy2ID)
}

func TestProfileExportAdvancedDedupAndNameOverride(t *testing.T) {
	name := "Renamed"
	reply := profileExportReplyFor(t, vlessWSJSON, &name)
	if reply.Name != name || !reply.Supported {
		t.Fatalf("reply = %+v", reply)
	}
	if !strings.Contains(reply.JSON, `"tag":"Renamed"`) {
		t.Fatalf("json = %s", reply.JSON)
	}
	payload := strings.TrimPrefix(reply.DedupKey, "throne://add/")
	raw, ok := profileBase64Decode(payload, true)
	if !ok {
		t.Fatalf("dedup key payload is not base64url: %q", payload)
	}
	if strings.Contains(string(raw), `"tag"`) {
		t.Fatalf("dedup payload should have no tag: %s", raw)
	}
	if want := strings.Replace(vlessWSJSON, `,"tag":"node"`, "", 1); string(raw) != want {
		t.Fatalf("dedup payload:\n  got  %s\n  want %s", raw, want)
	}
	if reply.JSONLink != "throne://add/"+profileBase64Encode([]byte(reply.JSON), true, false) {
		t.Fatalf("jsonLink = %q", reply.JSONLink)
	}
}

func TestProfileExportAdvancedRefusals(t *testing.T) {
	for _, tc := range []struct {
		document string
		reason   string
	}{
		{`{"type":"vmess","server":"host","server_port":443,"uuid":"u","packet_encoding":"xudp","transport":{"type":"quic"}}`, "transport type"},
		{`{"type":"vless","server":"host","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"unknown_future_field":1}}`, "tls field not ported yet"},
		{`{"type":"hysteria2","server":"host","server_port":443,"password":"p","tls":{"enabled":true},"realm":{"server_url":"https://x"}}`, "realm"},
		{`{"type":"vless","server":"host","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","transport":{"type":"quic"}}`, "transport type"},
	} {
		reply := profileExportReplyFor(t, tc.document, nil)
		if reply.Supported {
			t.Fatalf("document %s should be refused: %+v", tc.document, reply)
		}
		if tc.reason != "" && !strings.Contains(reply.Reason, tc.reason) {
			t.Fatalf("document %s: reason %q, want contains %q", tc.document, reply.Reason, tc.reason)
		}
	}
}

func TestProfileExportAdvancedRefusesMalformedFields(t *testing.T) {
	for _, document := range []string{
		`{"type":"vmess","server":"host","server_port":443,"uuid":"u","packet_encoding":"bogus"}`,
		`{"type":"vless","server":"host","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"bogus"}`,
		`{"type":"vless","server":"host","server_port":443,"uuid":"u","packet_encoding":"xudp"}`,
	} {
		reply := profileExportReplyFor(t, document, nil)
		if reply.Supported {
			t.Fatalf("document %s should be refused: %+v", document, reply)
		}
	}
}

func TestProfileExportAdvancedSimpleStillOwnsFourTypes(t *testing.T) {
	for _, tc := range []struct {
		document string
		typ      string
	}{
		{`{"type":"direct"}`, "direct"},
		{`{"type":"socks","server":"host","server_port":1080}`, "socks"},
		{`{"type":"shadowsocks","server":"host","server_port":8388,"method":"aes-256-gcm","password":"p"}`, "shadowsocks"},
	} {
		reply := profileExportReplyFor(t, tc.document, nil)
		if !reply.Supported || reply.Type != tc.typ || reply.Reason != "" {
			t.Fatalf("document %s: reply = %+v", tc.document, reply)
		}
	}
}
