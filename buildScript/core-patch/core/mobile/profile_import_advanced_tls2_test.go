// S5 TLS/transport completion slice: cipher suites/curves, fragment, spoof,
// tls_tricks, uTLS details, the quic and xhttp-extra transports, and the
// Hysteria2 realm/pin/QUIC surface.
//
// Every expected stored JSON / link / identity below is the exact Kotlin
// exportToJson().toCompact() / exportToLink() / exportIdentity().toCompact()
// output, produced by the JVM oracle in ProfileStoredGoParityTest.kt
// (`advanced tls2 …`, `advanced quic …`, `advanced xhttp …`,
// `advanced hysteria2 …`, `clash tls2 edge fields`).
package mobile

import (
	"testing"
)

const tls2UUID = "b831381d-6324-4d53-ad4f-8cda48b30811"

const (
	tls2LinkJSON = `{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"tls2","tls":{"alpn":["h2","http/1.1"],"cipher_suites":["TLS_AES_128_GCM_SHA256","TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"],"curve_preferences":["X25519","P256"],"enabled":true,"fragment":true,"fragment_fallback_delay":"500ms","max_version":"1.3","min_version":"1.2","record_fragment":true,"server_name":"sni.example.com","spoof":"example.org","spoof_enabled":true,"spoof_method":"method","tls_tricks":{"mixedcase_sni":true},"utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"` + tls2UUID + `"}`

	tls2StoredJSON = `{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"t","tls":{"alpn":["h2"],"cipher_suites":["TLS_AES_128_GCM_SHA256"],"curve_preferences":["X25519"],"enabled":true,"fragment":true,"fragment_fallback_delay":"500ms","max_version":"1.3","min_version":"1.2","record_fragment":true,"server_name":"sni.example.com","spoof":"example.org","spoof_enabled":true,"spoof_method":"method","tls_tricks":{"mixedcase_sni":true},"utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"u"}`
	tls2StoredLink = "vless://u@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&alpn=h2&tls_min_version=1.2&tls_max_version=1.3&cs=TLS_AES_128_GCM_SHA256&tls_curve_preferences=X25519&tls_fragment=true&tls_fragment_fallback_delay=500ms&tls_record_fragment=true&tls_spoof_enabled=true&tls_spoof=example.org&tls_spoof_method=method&tls_tricks=true&fp=chrome&packetEncoding=xudp#t"

	quicLinkJSON = `{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"q","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"},"type":"vless","uuid":"` + tls2UUID + `"}`

	xhttpLinkJSON = `{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"User-Agent":"test"},"host":"x.example.com","mode":"packet-up","no_sse_header":true,"path":"/x","type":"xhttp","x_padding_bytes":"200-300","xmux":{"maxConcurrency":"16-32"}},"type":"vless","uuid":"` + tls2UUID + `"}`

	realmJSON = `{"password":"pass","realm":{"ip_version":4,"port_mapping":{"enabled":true,"lifetime":"30s","timeout":"10s"},"realm_id":"rid","server_url":"https://realm.example.com","stun_servers":["stun.example.com:3478"],"token":"tok"},"tag":"realm","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2"}`
)

func TestProfileImportAdvancedTLS2Fields(t *testing.T) {
	assertAdvancedImport(t,
		"vless://"+tls2UUID+"@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&alpn=h2%2Chttp%2F1.1&tls_min_version=1.2&tls_max_version=1.3&tls_cipher_suites=TLS_AES_128_GCM_SHA256%2CTLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256&tls_curve_preferences=X25519,P256&tls_fragment=true&tls_fragment_fallback_delay=500ms&tls_record_fragment=true&tls_spoof=example.org&tls_spoof_method=method&tls_spoof_enabled=true&tls_tricks=true&fp=chrome#tls2",
		tls2LinkJSON,
		`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
	)
}

func TestProfileExportAdvancedTLS2Fields(t *testing.T) {
	assertAdvancedExport(t,
		`{"type":"vless","tag":"t","server":"h.example.com","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"],"min_version":"1.2","max_version":"1.3","cipher_suites":["TLS_AES_128_GCM_SHA256"],"curve_preferences":["X25519"],"fragment":true,"fragment_fallback_delay":"500ms","record_fragment":true,"spoof":"example.org","spoof_method":"method","spoof_enabled":true,"tls_tricks":{"mixedcase_sni":true},"utls":{"enabled":true,"fingerprint":"chrome"}}}`,
		tls2StoredJSON, tls2StoredLink,
		`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
	)
}

func TestProfileImportAdvancedQUICTransport(t *testing.T) {
	assertAdvancedImport(t,
		"vless://"+tls2UUID+"@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=quic#q",
		quicLinkJSON,
		`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"}}`,
	)
}

func TestProfileExportAdvancedQUICTransport(t *testing.T) {
	assertAdvancedExport(t,
		`{"type":"vless","tag":"q","server":"h.example.com","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"}}`,
		`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"q","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"},"type":"vless","uuid":"u"}`,
		"vless://u@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=quic&packetEncoding=xudp#q",
		`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"}}`,
	)
}

func TestProfileImportAdvancedXHTTPExtra(t *testing.T) {
	assertAdvancedImport(t,
		"vless://"+tls2UUID+"@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=xhttp&host=x.example.com&path=%2Fx&mode=packet-up&headers=User-Agent%7Ctest&extra=%7B%22xPaddingBytes%22%3A%22200-300%22%2C%22noSSEHeader%22%3Atrue%2C%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%7D%2C%22headers%22%3A%7B%22X-Extra%22%3A%22yes%22%7D%7D#xh",
		xhttpLinkJSON,
		`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp"}}`,
	)
}

func TestProfileExportAdvancedXHTTPExtra(t *testing.T) {
	assertAdvancedExport(t,
		`{"type":"vless","tag":"xh","server":"h.example.com","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp","host":"x.example.com","path":"/x","mode":"packet-up","x_padding_bytes":"200-300","no_sse_header":true,"headers":{"User-Agent":"test"},"xmux":{"maxConcurrency":"16-32"}}}`,
		`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"User-Agent":"test"},"host":"x.example.com","mode":"packet-up","no_sse_header":true,"path":"/x","type":"xhttp","x_padding_bytes":"200-300","xmux":{"maxConcurrency":"16-32"}},"type":"vless","uuid":"u"}`,
		"vless://u@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=xhttp&host=x.example.com&path=/x&mode=packet-up&headers=User-Agent%7Ctest&extra=%7B%22headers%22:%7B%22User-Agent%22:%22test%22%7D,%22noSSEHeader%22:true,%22xPaddingBytes%22:%22200-300%22,%22xmux%22:%7B%22maxConcurrency%22:%2216-32%22%7D%7D&packetEncoding=xudp#xh",
		`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp"}}`,
	)
	// The stored JSON body path must emit the same node.
	nodes := importBody(t, `{"type":"vless","tag":"xh","server":"h.example.com","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp","host":"x.example.com","path":"/x","mode":"packet-up","x_padding_bytes":"200-300","no_sse_header":true,"headers":{"User-Agent":"test"},"xmux":{"maxConcurrency":"16-32"}}}`)
	if len(nodes) != 1 {
		t.Fatalf("got %d nodes", len(nodes))
	}
	if nodes[0].JSON != `{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"User-Agent":"test"},"host":"x.example.com","mode":"packet-up","no_sse_header":true,"path":"/x","type":"xhttp","x_padding_bytes":"200-300","xmux":{"maxConcurrency":"16-32"}},"type":"vless","uuid":"u"}` {
		t.Fatalf("stored json = %s", nodes[0].JSON)
	}
}

func TestProfileExportAdvancedHysteria2Realm(t *testing.T) {
	assertAdvancedExport(t,
		`{"type":"hysteria2","tag":"realm","password":"pass","realm":{"server_url":"https://realm.example.com","token":"tok","realm_id":"rid","stun_servers":["stun.example.com:3478"],"ip_version":4,"port_mapping":{"enabled":true,"timeout":"10s","lifetime":"30s"}},"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		realmJSON, "",
		`{"protocol_version":"2","realm_id":"rid","realm_server_url":"https://realm.example.com","tls":{"enabled":true,"server_name":"sni.example.com"}}`,
	)
	// The same document through the JSON-body importer must produce the same node.
	nodes := importBody(t, `{"type":"hysteria2","tag":"realm","password":"pass","realm":{"server_url":"https://realm.example.com","token":"tok","realm_id":"rid","stun_servers":["stun.example.com:3478"],"ip_version":4,"port_mapping":{"enabled":true,"timeout":"10s","lifetime":"30s"}},"tls":{"enabled":true,"server_name":"sni.example.com"}}`)
	if len(nodes) != 1 {
		t.Fatalf("got %d nodes", len(nodes))
	}
	if nodes[0].JSON != realmJSON {
		t.Fatalf("stored json:\n got %s\nwant %s", nodes[0].JSON, realmJSON)
	}
	if nodes[0].Identity != `{"protocol_version":"2","realm_id":"rid","realm_server_url":"https://realm.example.com","tls":{"enabled":true,"server_name":"sni.example.com"}}` {
		t.Fatalf("identity = %s", nodes[0].Identity)
	}
	if nodes[0].Link != "" {
		t.Fatalf("link = %q, want empty (realm has no link form)", nodes[0].Link)
	}
}

func TestProfileImportAdvancedHysteria2PortHoppingAndUTLS(t *testing.T) {
	assertAdvancedImport(t,
		"hysteria2://pass@h.example.com:443?mport=1000-2000%2C3000&hop_interval=10&hop_interval_max=20&bbr_profile=standard&fp=banana&sni=sni.example.com#hy",
		`{"bbr_profile":"standard","hop_interval":"10s","hop_interval_max":"20s","password":"pass","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"banana"}},"type":"hysteria2"}`,
		`{"protocol_version":"2","server":"h.example.com","server_port":443,"server_ports":"1000:2000,3000:3000","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"banana"}}}`,
	)
}

func TestProfileExportAdvancedHysteria2PortHopping(t *testing.T) {
	assertAdvancedExport(t,
		`{"type":"hysteria2","tag":"hy","server":"h.example.com","server_port":443,"password":"pass","server_ports":["1000:2000","3000:3000"],"hop_interval":"10s","hop_interval_max":"20s","bbr_profile":"standard","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"banana"}}}`,
		`{"bbr_profile":"standard","hop_interval":"10s","hop_interval_max":"20s","password":"pass","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"banana"}},"type":"hysteria2"}`,
		"hysteria2://pass@h.example.com:1000-2000,3000-3000?hop_interval_max=20s&bbr_profile=standard&hop_interval=10s&security=tls&sni=sni.example.com&fp=banana#hy",
		`{"protocol_version":"2","server":"h.example.com","server_port":443,"server_ports":"1000:2000,3000:3000","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"banana"}}}`,
	)
}

func TestProfileImportAdvancedClashTLSEdgeFields(t *testing.T) {
	for _, tc := range []struct{ yaml, want string }{
		{
			`proxies:
  - {name: t, type: tuic, server: t.example.com, port: 443, uuid: u, password: p, 'client-fingerprint': none, sni: sni.example.com}
`,
			`{"password":"p","server":"t.example.com","server_port":443,"tag":"t","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"tuic","uuid":"u"}`,
		},
		{
			`proxies:
  - {name: hu, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, network: ws, 'ws-opts': {path: '/ws?ed=2048', headers: {Host: cdn.example.com}}, 'client-fingerprint': chrome}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"hu","tls":{"enabled":true,"server_name":"h.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"early_data_header_name":"Sec-WebSocket-Protocol","headers":{"Host":"cdn.example.com"},"max_early_data":2048,"path":"/ws","type":"ws"},"type":"vless","uuid":"u"}`,
		},
		{
			`proxies:
  - {name: hp, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, network: ws, 'ws-opts': {'v2ray-http-upgrade': true, path: /hu, headers: {Host: cdn.example.com}}}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"hp","tls":{"enabled":true,"server_name":"h.example.com"},"transport":{"host":"cdn.example.com","path":"/hu","type":"httpupgrade"},"type":"vless","uuid":"u"}`,
		},
		{
			// A REALITY key turns TLS on even when the entry wrote tls: false.
			`proxies:
  - {name: r, type: vless, server: h.example.com, port: 443, uuid: u, 'reality-opts': {'public-key': abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI, 'short-id': abc}}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI","short_id":"abc"},"server_name":"h.example.com"},"type":"vless","uuid":"u"}`,
		},
	} {
		nodes, err := profileImportClashBody(tc.yaml)
		if err != nil {
			t.Fatalf("clash import: %v\n%s", err, tc.yaml)
		}
		if len(nodes) != 1 {
			t.Fatalf("got %d nodes", len(nodes))
		}
		if nodes[0].JSON != tc.want {
			t.Fatalf("clash:\n  json = %s\n  want = %s", nodes[0].JSON, tc.want)
		}
	}
}
