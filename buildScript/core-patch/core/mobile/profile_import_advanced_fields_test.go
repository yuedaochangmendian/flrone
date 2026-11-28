// S5 advanced-import parity: each expected JSON/identity string is the exact
// Kotlin exportToJson().toCompact() / exportIdentity().toCompact() output for
// the vector, pinned in JVM ProfileStoredGoParityTest.kt. A mismatch means the
// Go importer drifted from the Kotlin oracle.
package mobile

import (
	"strings"
	"testing"
)

const advancedTestUUID = "b831381d-6324-4d53-ad4f-8cda48b30811"
const advancedTestPin = "AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA:AA"

func assertAdvancedImport(t *testing.T, link, wantJSON, wantIdentity string) {
	t.Helper()
	node, err := profileImportOneLink(link)
	if err != nil {
		t.Fatalf("%s: %v", link, err)
	}
	if node.JSON != wantJSON {
		t.Fatalf("%s:\n  json = %s\n  want = %s", link, node.JSON, wantJSON)
	}
	if wantIdentity != "" && node.Identity != wantIdentity {
		t.Fatalf("%s:\n  identity = %s\n  want    = %s", link, node.Identity, wantIdentity)
	}
}

func TestProfileImportAdvancedTLSFields(t *testing.T) {
	assertAdvancedImport(t,
		"vless://"+advancedTestUUID+"@h.example.com:443?encryption=none&security=tls&disable_sni=1&sni=sni.example.com&alpn=h2&tls_min_version=1.2&tls_max_version=1.3&tls_certificate=A%2CB&tls_certificate_path=%2Fp&pcs="+advancedTestPin+"&tls_certificate_public_key_sha256=pk1%2Cpk2&tls_client_certificate=C&tls_client_certificate_path=%2Fcp&tls_client_key=K&tls_client_key_path=%2Fkp&fp=chrome#tls",
		`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"tls","tls":{"alpn":["h2"],"certificate":["A%2CB"],"certificate_path":"%2Fp","certificate_public_key_sha256":["pk1%2Cpk2"],"certificate_sha256":["qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="],"client_certificate":["C"],"client_certificate_path":"%2Fcp","client_key":["K"],"client_key_path":"%2Fkp","disable_sni":true,"enabled":true,"max_version":"1.3","min_version":"1.2","server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"`+advancedTestUUID+`"}`,
		`{"server":"h.example.com","server_port":443,"tls":{"disable_sni":true,"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
	)
}

func TestProfileImportAdvancedECH(t *testing.T) {
	assertAdvancedImport(t,
		"vless://"+advancedTestUUID+"@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&ech=ech.example.com%2Bhttps%3A%2F%2Fresolver.example.com&fp=chrome#ech",
		`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"ech","tls":{"ech":{"enabled":true,"query_server_name":"ech.example.com","resolver":"https://resolver.example.com"},"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"`+advancedTestUUID+`"}`,
		`{"server":"h.example.com","server_port":443,"tls":{"ech":{"enabled":true,"query_server_name":"ech.example.com","resolver":"https://resolver.example.com"},"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
	)
	assertAdvancedImport(t,
		"vless://"+advancedTestUUID+"@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&ech_config=ZWNmLWNvbmZpZw&ech_enabled=true#echcfg",
		`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"echcfg","tls":{"ech":{"config":["-----BEGIN ECH CONFIGS-----","ZWNmLWNvbmZpZw","-----END ECH CONFIGS-----"],"enabled":true},"enabled":true,"server_name":"sni.example.com"},"type":"vless","uuid":"`+advancedTestUUID+`"}`,
		`{"server":"h.example.com","server_port":443,"tls":{"ech":{"enabled":true},"enabled":true,"server_name":"sni.example.com"}}`,
	)
}

func TestProfileImportAdvancedTransports(t *testing.T) {
	for _, tc := range []struct{ link, json, identity string }{
		{
			"vless://" + advancedTestUUID + "@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws&host=cdn.example.com&headers=User-Agent%7Ctest%7CX-Other%7Cyes&max_early_data=2048&early_data_header_name=Sec-WebSocket-Protocol#ws",
			`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"ws","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"early_data_header_name":"Sec-WebSocket-Protocol","headers":{"Host":"cdn.example.com","User-Agent":"test","X-Other":"yes"},"max_early_data":2048,"path":"/ws","type":"ws"},"type":"vless","uuid":"` + advancedTestUUID + `"}`,
			`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}`,
		},
		{
			"vless://" + advancedTestUUID + "@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=httpupgrade&path=%2Fh&host=h.example.com&headers=A%7CB#hu",
			`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"hu","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"A":"B"},"host":"h.example.com","path":"/h","type":"httpupgrade"},"type":"vless","uuid":"` + advancedTestUUID + `"}`,
			`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"httpupgrade"}}`,
		},
		{
			"vless://" + advancedTestUUID + "@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=xhttp&host=x.example.com&path=%2Fx&mode=packet-up&x_padding_bytes=100-200#xh",
			`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"host":"x.example.com","mode":"packet-up","path":"/x","type":"xhttp","x_padding_bytes":"100-200"},"type":"vless","uuid":"` + advancedTestUUID + `"}`,
			`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp"}}`,
		},
		{
			"vless://" + advancedTestUUID + "@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=kcp&mtu=1350&tti=50&uplinkCapacity=20&downlinkCapacity=50&congestion=true&readBufferSize=4&writeBufferSize=4&headerType=srtp&seed=abc#kcp",
			`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"kcp","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"congestion":true,"downlink_capacity":50,"header_type":"srtp","mtu":1350,"read_buffer_size":4,"seed":"abc","tti":50,"type":"mkcp","uplink_capacity":20,"write_buffer_size":4},"type":"vless","uuid":"` + advancedTestUUID + `"}`,
			`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"mkcp"}}`,
		},
	} {
		assertAdvancedImport(t, tc.link, tc.json, tc.identity)
	}
}

func TestProfileImportAdvancedMultiplex(t *testing.T) {
	assertAdvancedImport(t,
		"vless://"+advancedTestUUID+"@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&mux=true&mux_protocol=smux&mux_max_connections=4&mux_min_streams=2&mux_padding=true&brutal_enabled=true&brutal_up_mbps=100&brutal_down_mbps=50#mx",
		`{"encryption":"none","multiplex":{"brutal":{"down_mbps":50,"enabled":true,"up_mbps":100},"enabled":true,"max_connections":4,"min_streams":2,"padding":true,"protocol":"smux"},"packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"mx","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"vless","uuid":"`+advancedTestUUID+`"}`,
		"",
	)
	assertAdvancedImport(t,
		"ss://YWVzLTI1Ni1nY206c2VjcmV0@h.example.com:8388?mux=true&mux_protocol=yamux&mux_max_streams=8&mux_padding=true#ssm",
		`{"method":"aes-256-gcm","multiplex":{"enabled":true,"max_streams":8,"padding":true,"protocol":"yamux"},"password":"secret","server":"h.example.com","server_port":8388,"tag":"ssm","type":"shadowsocks"}`,
		`{"server":"h.example.com","server_port":8388}`,
	)
}

func TestProfileImportAdvancedHysteria(t *testing.T) {
	assertAdvancedImport(t,
		"hysteria://h.example.com:443?auth=secret&mport=1000-2000%2C3000&hop_interval=10s&pinSHA256="+advancedTestPin+"&quic_idle_timeout=10s&quic_stream_receive_window=1m&quic_max_concurrent_streams=100&quic_initial_packet_size=1400&quic_disable_path_mtu_discovery=true&sni=sni.example.com#hy1",
		`{"auth_str":"secret","disable_path_mtu_discovery":true,"hop_interval":"10s","idle_timeout":"10s","initial_packet_size":1400,"max_concurrent_streams":100,"server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"stream_receive_window":"1m","tag":"hy1","tls":{"certificate_sha256":["qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria"}`,
		`{"protocol_version":"1","server":"h.example.com","server_port":443,"server_ports":"1000:2000,3000:3000","tls":{"enabled":true,"server_name":"sni.example.com"}}`,
	)
	assertAdvancedImport(t,
		"hysteria2://pass@h.example.com:443?mport=1000-2000%2C3000&hop_interval=10s&hop_interval_max=20s&bbr_profile=standard&disable_chrome_parrot=true&pinSHA256="+advancedTestPin+"&quic_keep_alive_period=5s&sni=sni.example.com#hy2",
		`{"bbr_profile":"standard","disable_chrome_parrot":true,"hop_interval":"10s","hop_interval_max":"20s","keep_alive_period":"5s","password":"pass","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy2","tls":{"certificate_sha256":["qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2"}`,
		`{"protocol_version":"2","server":"h.example.com","server_port":443,"server_ports":"1000:2000,3000:3000","tls":{"enabled":true,"server_name":"sni.example.com"}}`,
	)
}

func TestProfileImportAdvancedClashFields(t *testing.T) {
	for _, tc := range []struct{ yaml, want string }{
		{
			`proxies:
  - {name: xh, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, network: xhttp, 'xhttp-opts': {path: /x, mode: stream-up, host: x.example.com, 'x-padding-bytes': '100-200', 'no-grpc-header': true, headers: {A: B}}}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"h.example.com"},"transport":{"headers":{"A":"B"},"host":"x.example.com","mode":"stream-up","no_grpc_header":true,"path":"/x","type":"xhttp","x_padding_bytes":"100-200"},"type":"vless","uuid":"u"}`,
		},
		{
			`proxies:
  - {name: kc, type: vmess, server: h.example.com, port: 443, uuid: u, cipher: auto, tls: true, network: kcp, 'kcp-opts': {mtu: 1350, tti: 50, 'uplink-capacity': 20, 'downlink-capacity': 50, congestion: true, 'header-type': srtp, seed: abc}}
`,
			`{"multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"kc","tls":{"enabled":true,"server_name":"h.example.com"},"transport":{"congestion":true,"downlink_capacity":50,"header_type":"srtp","mtu":1350,"seed":"abc","tti":50,"type":"mkcp","uplink_capacity":20},"type":"vmess","uuid":"u"}`,
		},
		{
			`proxies:
  - {name: sm, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, smux: {enabled: true, protocol: smux, 'max-connections': 4, 'min-streams': 2, padding: true}}
`,
			`{"encryption":"none","multiplex":{"enabled":true,"max_connections":4,"min_streams":2,"padding":true,"protocol":"smux"},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"sm","tls":{"enabled":true,"server_name":"h.example.com"},"type":"vless","uuid":"u"}`,
		},
		{
			`proxies:
  - {name: hy, type: hysteria, server: h.example.com, port: 443, 'auth-str': s, ports: '1000-2000,3000', 'hop-interval': '10', sni: sni.example.com}
`,
			`{"auth_str":"s","hop_interval":"10s","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria"}`,
		},
		{
			`proxies:
  - {name: hy2, type: hysteria2, server: h.example.com, port: 443, password: p, ports: '1000-2000,3000', 'hop-interval': '10', sni: sni.example.com}
`,
			`{"hop_interval":"10s","password":"p","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy2","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2"}`,
		},
	} {
		nodes, err := profileImportClashBody(tc.yaml)
		if err != nil {
			t.Fatalf("clash import: %v\n%s", err, tc.yaml)
		}
		if len(nodes) != 1 {
			t.Fatalf("clash import: got %d nodes, want 1", len(nodes))
		}
		if nodes[0].JSON != tc.want {
			t.Fatalf("clash:\n  json = %s\n  want = %s", nodes[0].JSON, tc.want)
		}
	}
}

func TestProfileImportAdvancedRealityMLDSA65(t *testing.T) {
	key := profileBase64Encode(make([]byte, 1952), true, false)
	reality := `"enabled":true,"mldsa65_verify":"` + key + `","public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"`
	assertAdvancedImport(t,
		"vless://u@h.example.com:443?encryption=none&security=reality&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&pqv="+key+"&sni=sni.example.com",
		`{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tls":{"enabled":true,"reality":{`+reality+`},"server_name":"sni.example.com"},"type":"vless","uuid":"u"}`,
		`{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"reality":{`+reality+`},"server_name":"sni.example.com"}}`,
	)
	yaml := "proxies:\n  - {name: r, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, 'reality-opts': {'public-key': abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK, 'short-id': abc, 'mldsa65-verify': '" + key + "'}}\n"
	nodes, err := profileImportClashBody(yaml)
	if err != nil {
		t.Fatalf("clash mldsa import: %v", err)
	}
	want := `{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{` + reality + `},"server_name":"h.example.com"},"type":"vless","uuid":"u"}`
	if nodes[0].JSON != want {
		t.Fatalf("clash mldsa:\n  json = %s\n  want = %s", nodes[0].JSON, want)
	}
}

// Values Kotlin drops or normalizes are no longer refused: an unknown security
// or uTLS fingerprint, an invalid TLS version or PCS, an invalid transport
// method/duration, a mux protocol, a bbr profile, a hop interval and a QUIC
// field all fall back to the corresponding default.
func TestProfileImportAdvancedNormalizationDrops(t *testing.T) {
	for _, tc := range []struct{ link, json string }{
		{
			"vless://uuid@host:443?security=bogus",
			`{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"type":"vless","uuid":"uuid"}`,
		},
		{
			"vless://uuid@host:443?security=tls&sni=s.example.com&fp=getd-browser",
			`{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"tls":{"enabled":true,"server_name":"s.example.com"},"type":"vless","uuid":"uuid"}`,
		},
		{
			"vless://uuid@host:443?security=tls&sni=s.example.com&fp=CHROME",
			`{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"tls":{"enabled":true,"server_name":"s.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"uuid"}`,
		},
		{
			"vless://uuid@host:443?security=tls&tls_min_version=9.9&tls_max_version=9.9&pcs=",
			`{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"tls":{"enabled":true},"type":"vless","uuid":"uuid"}`,
		},
		{
			"vless://uuid@host:443?security=tls&sni=s.example.com&type=ws&method=BAD%20TOKEN&idle_timeout=abc&max_early_data=-1",
			`{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"tls":{"enabled":true,"server_name":"s.example.com"},"transport":{"type":"ws"},"type":"vless","uuid":"uuid"}`,
		},
		{
			"vless://uuid@host:443?security=tls&sni=s.example.com&mux=true&mux_protocol=bogus",
			`{"encryption":"none","multiplex":{"enabled":true},"packet_encoding":"xudp","server":"host","server_port":443,"tls":{"enabled":true,"server_name":"s.example.com"},"type":"vless","uuid":"uuid"}`,
		},
		{
			"vless://uuid@host:443?security=tls&type=ws&flow=xtls-rprx-vision",
			`{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"tls":{"enabled":true},"transport":{"type":"ws"},"type":"vless","uuid":"uuid"}`,
		},
		{
			"trojan://pass@host:443?pinSHA256=abc",
			`{"password":"pass","server":"host","server_port":443,"tls":{"enabled":true},"type":"trojan"}`,
		},
		{
			"hysteria2://pass@host:443?bbr_profile=bogus&hop_interval=abc&quic_idle_timeout=abc&quic_stream_receive_window=abc&quic_initial_packet_size=2000",
			`{"password":"pass","server":"host","server_port":443,"tls":{"enabled":true},"type":"hysteria2"}`,
		},
	} {
		assertAdvancedImport(t, tc.link, tc.json, "")
	}
}

// What is still refused is what Kotlin's own validation refuses.
func TestProfileImportAdvancedRemainingRefusals(t *testing.T) {
	for _, tc := range []struct{ link, reason string }{
		{"vless://uuid@host:443?security=tls&type=banana", "transport type not supported by the core: banana"},
		{"vless://uuid@host:443?security=tls&type=xhttp&mode=banana", "transport mode not supported by the core: banana"},
		{"vless://uuid@host:443?flow=xtls-rprx-vision-udp443", "vless flow not supported by the core"},
		{"hysteria2://pass@host:443?pinSHA256=bogus", "pinSHA256"},
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
