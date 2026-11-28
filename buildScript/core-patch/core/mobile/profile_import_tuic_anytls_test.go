// S5 TUIC/AnyTLS parity tests. Every expected `json`, `link` and `identity`
// below is the exact Kotlin exportToJson/toCompact, exportToLink and
// exportIdentity output for the same input, produced by the JVM oracle in
// app/src/test/java/io/nekohasekai/sagernet/outbound/ProfileStoredGoParityTest.kt
// (types/Tuic.kt, types/AnyTls.kt, common/{Tls,QuicFields,DialFields}.kt).
package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

const tuicTestUUID = "b831381d-6324-4d53-ad4f-8cda48b30811"

func TestProfileImportTuicAnyTlsLinks(t *testing.T) {
	cases := []struct {
		name     string
		link     string
		json     string
		linkBack string
		identity string
	}{
		{
			name: "tuic full fields",
			link: "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:pass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=true&heartbeat=10s&sni=sni.example.com&alpn=h3&disable_sni=true&allowInsecure=1#t1",
			json: `{"congestion_control":"bbr","heartbeat":"10s","password":"pass","server":"tuic.example.com","server_port":443,"tag":"t1","tls":{"alpn":["h3"],"disable_sni":true,"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"tuic","udp_relay_mode":"native","uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","zero_rtt_handshake":true}`,
			linkBack: "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:pass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=true&heartbeat=10s&security=tls&disable_sni=true&sni=sni.example.com&allowInsecure=true&alpn=h3#t1",
			identity: `{"server":"tuic.example.com","server_port":443,"tls":{"disable_sni":true,"enabled":true,"server_name":"sni.example.com"}}`,
		},
		{
			name: "tuic userinfo percent decode and quic fields",
			link: "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:p%40ss@tuic.example.com:443?security=tls&sni=sni.example.com&fp=chrome&quic_idle_timeout=30s&quic_max_concurrent_streams=10&quic_disable_path_mtu_discovery=true#t2",
			json: `{"disable_path_mtu_discovery":true,"idle_timeout":"30s","max_concurrent_streams":10,"password":"p@ss","server":"tuic.example.com","server_port":443,"tag":"t2","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"tuic","uuid":"b831381d-6324-4d53-ad4f-8cda48b30811"}`,
			linkBack: "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:p%40ss@tuic.example.com:443?security=tls&sni=sni.example.com&fp=chrome&quic_idle_timeout=30s&quic_max_concurrent_streams=10&quic_disable_path_mtu_discovery=true#t2",
			identity: `{"server":"tuic.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
		},
		{
			name: "anytls full fields and dial",
			link: "anytls://pass@anytls.example.com:443?sni=sni.example.com&alpn=h2%2Chttp%2F1.1&fp=chrome&allowInsecure=1&idle_session_check_interval=45s&idle_session_timeout=1m&min_idle_session=3&connect_timeout=5s#a1",
			json: `{"connect_timeout":"5s","idle_session_check_interval":"45s","idle_session_timeout":"1m","min_idle_session":3,"password":"pass","server":"anytls.example.com","server_port":443,"tag":"a1","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"anytls"}`,
			linkBack: "anytls://pass@anytls.example.com:443?idle_session_check_interval=45s&idle_session_timeout=1m&min_idle_session=3&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&fp=chrome&connect_timeout=5s#a1",
			identity: `{"server":"anytls.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			node := profileImportNode(t, tc.link)
			if node.JSON != tc.json {
				t.Fatalf("stored JSON:\n got %s\nwant %s", node.JSON, tc.json)
			}
			if node.Link != tc.linkBack {
				t.Fatalf("export link:\n got %s\nwant %s", node.Link, tc.linkBack)
			}
			if node.Identity != tc.identity {
				t.Fatalf("identity:\n got %s\nwant %s", node.Identity, tc.identity)
			}
			// The dedup key must round-trip back to the stored JSON minus tag.
			decoded, ok := profileBase64Decode(strings.TrimPrefix(node.DedupKey, "throne://add/"), true)
			if !ok {
				t.Fatal("dedupKey is not valid url-safe base64")
			}
			var object map[string]any
			if err := json.Unmarshal(decoded, &object); err != nil {
				t.Fatalf("dedupKey JSON: %v", err)
			}
			if _, present := object["tag"]; present {
				t.Fatal("dedupKey still carries tag")
			}
		})
	}
}

func TestProfileImportTuicAnyTlsClash(t *testing.T) {
	cases := []struct {
		name string
		yaml string
		json string
	}{
		{
			name: "tuic",
			yaml: `proxies:
  - {name: tc, type: tuic, server: tuic.example.com, port: 443, uuid: ` + tuicTestUUID + `, password: pass, congestion-controller: bbr, 'udp-relay-mode': native, 'reduce-rtt': true, 'heartbeat-interval': 10000, sni: sni.example.com, alpn: [h3], 'skip-cert-verify': true, ip: 1.2.3.4, 'client-fingerprint': chrome}
`,
			json: `{"congestion_control":"bbr","heartbeat":"10000ms","password":"pass","server":"1.2.3.4","server_port":443,"tag":"tc","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"tuic","udp_relay_mode":"native","uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","zero_rtt_handshake":true}`,
		},
		{
			name: "anytls",
			yaml: `proxies:
  - {name: at, type: anytls, server: anytls.example.com, port: 443, password: pass, 'idle-session-check-interval': 45, 'idle-session-timeout': 60, 'min-idle-session': 3, sni: sni.example.com, alpn: [h2, http/1.1], 'skip-cert-verify': true, 'client-fingerprint': chrome}
`,
			json: `{"idle_session_check_interval":"45s","idle_session_timeout":"60s","min_idle_session":3,"password":"pass","server":"anytls.example.com","server_port":443,"tag":"at","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"anytls"}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nodes := importClashNodes(t, tc.yaml)
			if len(nodes) != 1 {
				t.Fatalf("got %d nodes", len(nodes))
			}
			if nodes[0].JSON != tc.json {
				t.Fatalf("stored JSON:\n got %s\nwant %s", nodes[0].JSON, tc.json)
			}
		})
	}
}

func TestProfileImportTuicAnyTlsStoredJSON(t *testing.T) {
	cases := []struct {
		name     string
		document string
		json     string
		linkBack string
	}{
		{
			name:     "tuic",
			document: `{"type":"tuic","tag":"tj","server":"tuic.example.com","server_port":443,"uuid":"` + tuicTestUUID + `","password":"pass","congestion_control":"bbr","udp_relay_mode":"native","zero_rtt_handshake":true,"heartbeat":"10s","tls":{"enabled":true,"server_name":"sni.example.com"}}`,
			json:     `{"congestion_control":"bbr","heartbeat":"10s","password":"pass","server":"tuic.example.com","server_port":443,"tag":"tj","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"tuic","udp_relay_mode":"native","uuid":"b831381d-6324-4d53-ad4f-8cda48b30811","zero_rtt_handshake":true}`,
			linkBack: "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:pass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=true&heartbeat=10s&security=tls&sni=sni.example.com#tj",
		},
		{
			name:     "anytls",
			document: `{"type":"anytls","tag":"aj","server":"anytls.example.com","server_port":443,"password":"pass","idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
			json:     `{"idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"password":"pass","server":"anytls.example.com","server_port":443,"tag":"aj","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"anytls"}`,
			linkBack: "anytls://pass@anytls.example.com:443?idle_session_check_interval=30s&idle_session_timeout=30s&min_idle_session=5&security=tls&sni=sni.example.com#aj",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nodes := importBody(t, tc.document)
			if len(nodes) != 1 {
				t.Fatalf("got %d nodes", len(nodes))
			}
			if nodes[0].JSON != tc.json {
				t.Fatalf("stored JSON:\n got %s\nwant %s", nodes[0].JSON, tc.json)
			}
			if nodes[0].Link != tc.linkBack {
				t.Fatalf("export link:\n got %s\nwant %s", nodes[0].Link, tc.linkBack)
			}
		})
	}
}

func TestProfileImportTuicAnyTlsRefusals(t *testing.T) {
	cases := []struct {
		name, input, reason string
		clash               bool
	}{
		{"tuic v4 clash", `proxies: [{name: x, type: tuic, server: s, port: 443}]`, "tuic v4 has no uuid", true},
		{"tuic unknown clash field", `proxies: [{name: x, type: tuic, server: s, port: 443, uuid: u, future: 1}]`, "field not ported yet: future", true},
		{"anytls unknown clash field", `proxies: [{name: x, type: anytls, server: s, port: 443, future: 1}]`, "field not ported yet: future", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var reason string
			if tc.clash {
				_, err := profileImportClashBody(tc.input)
				if err == nil {
					t.Fatal("want a refusal")
				}
				reason = err.Error()
			} else {
				reason = profileImportRefusal(t, tc.input)
			}
			if !strings.Contains(reason, tc.reason) {
				t.Fatalf("reason = %q, want %q", reason, tc.reason)
			}
		})
	}
	// Link-level unsupported fields refuse with an explicit reason.
	for _, link := range []string{
		"tuic://u:p@host:443?reduce-rtt=true#x",
		"tuic://u:p@host:443?disable_mtu_discovery=true#x",
	} {
		reason := profileImportRefusal(t, link)
		if !strings.Contains(reason, "not ported yet") {
			t.Fatalf("reason = %q", reason)
		}
	}
}
