// S5c advanced-link parity tests. Every expected `json` below is the exact
// Kotlin exportToJson().toCompact() output, produced by the JVM oracle
// app/src/test/java/io/nekohasekai/sagernet/outbound/ProfileStoredGoParityTest.kt
// (and cross-checked with the standalone Kotlin harness). A mismatch means the
// Go importer has drifted from Kotlin's stored form.
package mobile

import (
	"strings"
	"testing"
)

func profileImportAdvancedNode(t *testing.T, link string) profileImportedNode {
	t.Helper()
	node, err := profileImportOneLink(link)
	if err != nil {
		t.Fatalf("profileImportOneLink(%q): %v", link, err)
	}
	return *node
}

func TestProfileImportVLESSFromKotlinOracle(t *testing.T) {
	const uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
	for _, tc := range []struct {
		link string
		json string
	}{
		{
			"vless://" + uuid + "@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws#node",
			`{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"node","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"vless","uuid":"` + uuid + `"}`,
		},
		{
			"vless://" + uuid + "@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=tcp&flow=xtls-rprx-vision#v",
			`{"encryption":"none","flow":"xtls-rprx-vision","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"v","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"vless","uuid":"` + uuid + `"}`,
		},
		{
			"vless://" + uuid + "@vless.example.com:443?encryption=mlkem768x25519plus.native.0rtt.AAAA&security=tls&sni=sni.example.com&type=grpc&serviceName=svc#e",
			`{"encryption":"mlkem768x25519plus.native.0rtt.AAAA","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"e","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"service_name":"svc","type":"grpc"},"type":"vless","uuid":"` + uuid + `"}`,
		},
		{
			"vless://" + uuid + "@vless.example.com:8443?encryption=none&security=tls&sni=sni.example.com&type=ws&host=cdn.example.com&path=%2Fws&alpn=h2%2Chttp%2F1.1&fp=chrome&allowInsecure=1#a",
			`{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":8443,"tag":"a","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vless","uuid":"` + uuid + `"}`,
		},
		{
			"vless://" + uuid + "@vless.example.com:443?encryption=none&security=reality&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&fp=chrome&sni=sni.example.com&type=tcp&flow=xtls-rprx-vision#r",
			`{"encryption":"none","flow":"xtls-rprx-vision","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"` + uuid + `"}`,
		},
		{
			"vless://" + uuid + "@vless.example.com:443?encryption=none&type=http&path=%2Fh&host=h.example.com&headers=User-Agent%3Atest#h",
			`{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"h","transport":{"host":"h.example.com","path":"/h","type":"http"},"type":"vless","uuid":"` + uuid + `"}`,
		},
	} {
		node := profileImportAdvancedNode(t, tc.link)
		if node.JSON != tc.json {
			t.Fatalf("%s:\n  json = %s\n  want = %s", tc.link, node.JSON, tc.json)
		}
		if node.Type != "vless" {
			t.Fatalf("%s: type = %q", tc.link, node.Type)
		}
	}
}

func TestProfileImportVMessFromKotlinOracle(t *testing.T) {
	const uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
	for _, tc := range []struct {
		link string
		json string
	}{
		{
			"vmess://eyJ2IjoiMiIsInBzIjoibm9kZSIsImFkZCI6ImV4YW1wbGUuY29tIiwicG9ydCI6IjQ0MyIsImlkIjoiYjgzMTM4MWQtNjMyNC00ZDUzLWFkNGYtOGNkYTQ4YjMwODExIiwiYWlkIjoiMCIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0IjoiY2RuLmV4YW1wbGUuY29tIiwicGF0aCI6Ii93cyIsInRscyI6InRscyIsInNuaSI6InNuaS5leGFtcGxlLmNvbSIsImFscG4iOiJoMixodHRwLzEuMSIsImZwIjoiY2hyb21lIiwic2N5IjoiYXV0byJ9",
			`{"packet_encoding":"xudp","server":"example.com","server_port":443,"tag":"node","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vmess","uuid":"` + uuid + `"}`,
		},
		{
			"vmess://" + uuid + "@example.com:443?encryption=auto&security=tls&sni=sni.example.com&type=ws&path=%2Fws&alterId=0&packetEncoding=xudp#v",
			`{"packet_encoding":"xudp","server":"example.com","server_port":443,"tag":"v","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"vmess","uuid":"` + uuid + `"}`,
		},
	} {
		node := profileImportAdvancedNode(t, tc.link)
		if node.JSON != tc.json {
			t.Fatalf("%s:\n  json = %s\n  want = %s", tc.link, node.JSON, tc.json)
		}
	}
}

func TestProfileImportTrojanFromKotlinOracle(t *testing.T) {
	for _, tc := range []struct {
		link string
		json string
	}{
		{
			"trojan://pass@trojan.example.com:443?sni=sni.example.com&alpn=h2%2Chttp%2F1.1&type=ws&path=%2Fws&host=h.example.com#t",
			`{"password":"pass","server":"trojan.example.com","server_port":443,"tag":"t","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"Host":"h.example.com"},"path":"/ws","type":"ws"},"type":"trojan"}`,
		},
		{
			"trojan://pass@trojan.example.com:443?security=tls&sni=sni.example.com&type=grpc&serviceName=svc&allowInsecure=1#g",
			`{"password":"pass","server":"trojan.example.com","server_port":443,"tag":"g","tls":{"enabled":true,"insecure":true,"server_name":"sni.example.com"},"transport":{"service_name":"svc","type":"grpc"},"type":"trojan"}`,
		},
	} {
		node := profileImportAdvancedNode(t, tc.link)
		if node.JSON != tc.json {
			t.Fatalf("%s:\n  json = %s\n  want = %s", tc.link, node.JSON, tc.json)
		}
	}
}

func TestProfileImportHysteriaFromKotlinOracle(t *testing.T) {
	for _, tc := range []struct {
		link string
		json string
	}{
		{
			"hysteria://host.example.com:443?auth=secret&obfsParam=obfs-secret&upmbps=100&downmbps=50&recv_window_conn=10&recv_window=20&sni=sni.example.com&alpn=h3&insecure=1#hy1",
			`{"auth_str":"secret","down_mbps":50,"obfs":"obfs-secret","recv_window":20,"recv_window_conn":10,"server":"host.example.com","server_port":443,"tag":"hy1","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"hysteria","up_mbps":100}`,
		},
		{
			"hysteria2://password@host.example.com:443?obfs=salamander&obfs-password=obfs-secret&upmbps=100&downmbps=50&sni=sni.example.com&alpn=h3&insecure=1#hy2",
			`{"down_mbps":50,"obfs":{"max_packet_size":0,"min_packet_size":0,"password":"obfs-secret","type":"salamander"},"password":"password","server":"host.example.com","server_port":443,"tag":"hy2","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}`,
		},
		{
			"hy2://password@host.example.com:443?obfs=gecko&obfs-password=obfs-secret&min_packet_size=512&max_packet_size=1200&upmbps=100&downmbps=50&sni=sni.example.com&alpn=h3#hy3",
			`{"down_mbps":50,"obfs":{"max_packet_size":1200,"min_packet_size":512,"password":"obfs-secret","type":"gecko"},"password":"password","server":"host.example.com","server_port":443,"tag":"hy3","tls":{"alpn":["h3"],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}`,
		},
	} {
		node := profileImportAdvancedNode(t, tc.link)
		if node.JSON != tc.json {
			t.Fatalf("%s:\n  json = %s\n  want = %s", tc.link, node.JSON, tc.json)
		}
	}
}

func TestProfileImportAdvancedRefusals(t *testing.T) {
	// What remains refused is what Kotlin itself refuses: a transport type or
	// xhttp mode Transport.validate rejects, the udp443 VLESS flow, a Hysteria
	// transport or pin, and a V2RayN body that is not a usable node.
	for _, tc := range []struct {
		link   string
		reason string
	}{
		{"vless://uuid@host:443?security=tls&type=banana", "transport type not supported by the core: banana"},
		{"vless://uuid@host:443?security=tls&type=xhttp&mode=banana", "transport mode not supported by the core: banana"},
		{"vless://uuid@host:443?flow=xtls-rprx-vision-udp443", "vless flow not supported by the core"},
		{"vmess://eyJ2IjoiMiIsImZvbyI6ImJhciJ9", "vmess V2RayN link lacks a valid uuid"},
		{"hysteria2://pass@host:443?pinSHA256=abc", "pinSHA256"},
		{"hysteria://host:443?protocol=quic", "protocol=quic"},
	} {
		_, err := profileImportOneLink(tc.link)
		if err == nil {
			t.Fatalf("link %q should have been refused", tc.link)
		}
		refused, ok := err.(profileImportUnsupported)
		if !ok {
			t.Fatalf("link %q: error is not a refusal: %T %v", tc.link, err, err)
		}
		if !strings.Contains(refused.Reason, tc.reason) {
			t.Fatalf("%q: reason = %q, want it to contain %q", tc.link, refused.Reason, tc.reason)
		}
	}
}

func TestProfileImportAdvancedActionContract(t *testing.T) {
	if actionHandlers[profileImportMethod] == nil {
		t.Fatal("profileImport has no registered handler")
	}
	// The action is unchanged: one link in, one node out.
	for _, link := range []string{
		"vless://b831381d-6324-4d53-ad4f-8cda48b30811@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws#node",
		"vmess://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443?encryption=auto&security=tls&sni=sni.example.com&type=ws&path=%2Fws#v",
		"trojan://pass@trojan.example.com:443?sni=sni.example.com#t",
		"hysteria2://password@host.example.com:443?obfs=salamander&obfs-password=x&sni=sni.example.com#h",
	} {
		node, err := profileImportOneLink(link)
		if err != nil || node == nil || node.JSON == "" || node.DedupKey == "" {
			t.Fatalf("%s: node = %+v, err = %v", link, node, err)
		}
	}
}

func TestProfileImportAdvancedIdentityFromKotlinOracle(t *testing.T) {
	const uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
	for _, tc := range []struct {
		name string
		link string
		want string
	}{
		{
			name: "vless ws tls",
			link: "vless://" + uuid + "@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws",
			want: `{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}`,
		},
		{
			name: "vless uTLS",
			link: "vless://" + uuid + "@vless.example.com:8443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws&alpn=h2%2Chttp%2F1.1&fp=chrome&allowInsecure=1",
			want: `{"server":"vless.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}},"transport":{"type":"ws"}}`,
		},
		{
			name: "vless reality",
			link: "vless://" + uuid + "@vless.example.com:443?encryption=none&security=reality&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&fp=chrome&sni=sni.example.com&type=tcp",
			want: `{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
		},
		{
			name: "hysteria2 tls",
			link: "hysteria2://password@host.example.com:443?sni=sni.example.com&alpn=h3&insecure=1",
			want: `{"protocol_version":"2","server":"host.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			node := profileImportAdvancedNode(t, tc.link)
			if node.Identity != tc.want {
				t.Fatalf("identity = %s, want %s", node.Identity, tc.want)
			}
		})
	}
}
