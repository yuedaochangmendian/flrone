// S5d Clash-to-stored parity tests. Every expected `json` below is the exact
// output of the Kotlin parsers' exportToJson().toCompact() for the same proxies
// entry, produced by the JVM oracle in ProfileStoredGoParityTest.kt (and
// cross-checked with the standalone Kotlin Clash oracle). A mismatch means the
// Go importer has drifted from Kotlin's stored form.
package mobile

import (
	"errors"
	"strings"
	"testing"
)

func importClashNodes(t *testing.T, yaml string) []profileImportedNode {
	t.Helper()
	nodes, err := profileImportClashBody(yaml)
	if err != nil {
		t.Fatalf("profileImportClashBody: %v", err)
	}
	return nodes
}

func importClashOne(t *testing.T, yaml string) profileImportedNode {
	t.Helper()
	nodes := importClashNodes(t, yaml)
	if len(nodes) != 1 {
		t.Fatalf("want exactly 1 node, got %d (%v)", len(nodes), nodes)
	}
	return nodes[0]
}

// Table-driven conversion of the common fields of every supported type. Each
// `yaml` is a full one-proxy Clash document; `json` is the Kotlin oracle's
// exportToJson bytes.
func TestProfileImportClashFromKotlinOracle(t *testing.T) {
	const uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
	for _, tc := range []struct {
		name  string
		yaml  string
		kind  string
		json  string
		title string
	}{
		{
			"ss common fields",
			`proxies:
  - {name: ss1, type: ss, server: ss.example.com, port: 8388, cipher: AES-256-GCM, password: secret, udp-over-tcp: true}
`,
			"shadowsocks",
			`{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"secret","server":"ss.example.com","server_port":8388,"tag":"ss1","type":"shadowsocks","udp_over_tcp":true}`,
			"ss1",
		},
		{
			"socks5 username and password",
			`proxies:
  - {name: s5, type: socks5, server: socks.example.com, port: 1080, username: u, password: p}
`,
			"socks",
			`{"password":"p","server":"socks.example.com","server_port":1080,"tag":"s5","type":"socks","username":"u"}`,
			"s5",
		},
		{
			"http username and password",
			`proxies:
  - {name: h1, type: http, server: http.example.com, port: 8080, username: u, password: p}
`,
			"http",
			`{"password":"p","server":"http.example.com","server_port":8080,"tag":"h1","type":"http","username":"u"}`,
			"h1",
		},
		{
			"vmess ws tls",
			`proxies:
  - {name: v1, type: vmess, server: vmess.example.com, port: 443, uuid: ` + uuid + `, alterId: 0, cipher: auto, tls: true, servername: sni.example.com, network: ws, 'ws-opts': {path: /ws, headers: {Host: cdn.example.com}}}
`,
			"vmess",
			`{"multiplex":{"enabled":false},"packet_encoding":"","server":"vmess.example.com","server_port":443,"tag":"v1","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vmess","uuid":"` + uuid + `"}`,
			"v1",
		},
		{
			"vless grpc tls fingerprint",
			`proxies:
  - {name: vl, type: vless, server: vless.example.com, port: 443, uuid: ` + uuid + `, tls: true, servername: sni.example.com, network: grpc, 'grpc-opts': {'grpc-service-name': svc}, 'client-fingerprint': chrome}
`,
			"vless",
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"vless.example.com","server_port":443,"tag":"vl","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"service_name":"svc","type":"grpc"},"type":"vless","uuid":"` + uuid + `"}`,
			"vl",
		},
		{
			"trojan ws tls alpn insecure",
			`proxies:
  - {name: tj, type: trojan, server: trojan.example.com, port: 443, password: pass, sni: sni.example.com, alpn: [h2, http/1.1], 'skip-cert-verify': true, network: ws, 'ws-opts': {path: /ws}}
`,
			"trojan",
			`{"multiplex":{"enabled":false},"password":"pass","server":"trojan.example.com","server_port":443,"tag":"tj","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"trojan"}`,
			"tj",
		},
		{
			"hysteria v1 auth windows bandwidth",
			`proxies:
  - {name: hy, type: hysteria, server: hy.example.com, port: 443, 'auth-str': secret, up: 100 Mbps, down: '50 Mbps', 'recv-window': 20, sni: sni.example.com, alpn: [h3]}
`,
			"hysteria",
			`{"auth_str":"secret","down_mbps":50,"recv_window":20,"server":"hy.example.com","server_port":443,"tag":"hy","tls":{"alpn":["h3"],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria","up_mbps":100}`,
			"hy",
		},
		{
			"hysteria2 salamander",
			`proxies:
  - {name: hy2, type: hysteria2, server: hy2.example.com, port: 443, password: pass, obfs: salamander, 'obfs-password': obfspass, up: '100 Mbps', down: '50 Mbps', sni: sni.example.com}
`,
			"hysteria2",
			`{"down_mbps":50,"obfs":{"max_packet_size":0,"min_packet_size":0,"password":"obfspass","type":"salamander"},"password":"pass","server":"hy2.example.com","server_port":443,"tag":"hy2","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}`,
			"hy2",
		},
		{
			"vmess cipher alterId packet-encoding",
			`proxies:
  - {name: vim, type: vmess, server: vmess.example.com, port: 443, uuid: ` + uuid + `, cipher: chacha20-poly1305, alterId: 4, 'packet-encoding': packetaddr}
`,
			"vmess",
			`{"alter_id":4,"multiplex":{"enabled":false},"packet_encoding":"packetaddr","security":"chacha20-poly1305","server":"vmess.example.com","server_port":443,"tag":"vim","type":"vmess","uuid":"` + uuid + `"}`,
			"vim",
		},
		{
			"vless vision flow",
			`proxies:
  - {name: vlm, type: vless, server: vless.example.com, port: 443, uuid: u, encryption: none, flow: xtls-rprx-vision, tls: true, sni: s.example.com}
`,
			"vless",
			`{"encryption":"none","flow":"xtls-rprx-vision","multiplex":{"enabled":false},"packet_encoding":"","server":"vless.example.com","server_port":443,"tag":"vlm","tls":{"enabled":true,"server_name":"s.example.com"},"type":"vless","uuid":"u"}`,
			"vlm",
		},
		{
			"hysteria2 gecko bandwidth units",
			`proxies:
  - {name: h2t, type: hysteria2, server: h.example.com, port: 443, password: pass, obfs: gecko, 'obfs-password': secret, up: '50 MB/s', down: 100 Mbps, sni: s.example.com}
`,
			"hysteria2",
			`{"down_mbps":100,"obfs":{"max_packet_size":0,"min_packet_size":0,"password":"secret","type":"gecko"},"password":"pass","server":"h.example.com","server_port":443,"tag":"h2t","tls":{"enabled":true,"server_name":"s.example.com"},"type":"hysteria2","up_mbps":400}`,
			"h2t",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			node := importClashOne(t, tc.yaml)
			if node.JSON != tc.json {
				t.Fatalf("json:\n  got  = %s\n  want = %s", node.JSON, tc.json)
			}
			if node.Type != tc.kind {
				t.Fatalf("type = %q, want %q", node.Type, tc.kind)
			}
			if node.Name != tc.title {
				t.Fatalf("name = %q, want %q", node.Name, tc.title)
			}
		})
	}
}

// Plugin conversions: Clash's option block becomes the SIP003 plugin string.
func TestProfileImportClashShadowsocksPlugins(t *testing.T) {
	for _, tc := range []struct {
		name, yaml, json string
	}{
		{
			"v2ray-plugin options in order",
			`proxies:
  - {name: ss-v2, type: ss, server: s.example.com, port: 8388, cipher: aes-256-gcm, password: pass, plugin: v2ray-plugin, 'plugin-opts': {tls: true, host: cdn.example.com, path: /ws, mode: websocket, mux: true}}
`,
			`{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"pass","plugin":"v2ray-plugin","plugin_opts":"tls;host=cdn.example.com;path=/ws;mode=websocket;mux","server":"s.example.com","server_port":8388,"tag":"ss-v2","type":"shadowsocks"}`,
		},
		{
			"obfs plugin becomes obfs-local",
			`proxies:
  - {name: ss-obfs, type: ss, server: s.example.com, port: 8388, cipher: aes-256-gcm, password: pass, plugin: obfs, 'plugin-opts': {mode: tls, host: cdn.example.com}}
`,
			`{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"pass","plugin":"obfs-local","plugin_opts":"obfs=tls;obfs-host=cdn.example.com","server":"s.example.com","server_port":8388,"tag":"ss-obfs","type":"shadowsocks"}`,
		},
		{
			"obfs with no recognized options",
			`proxies:
  - {name: ss-obfs2, type: ss, server: s.example.com, port: 8388, cipher: aes-256-gcm, password: pass, plugin: obfs}
`,
			`{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"pass","plugin":"obfs-local","server":"s.example.com","server_port":8388,"tag":"ss-obfs2","type":"shadowsocks"}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := importClashOne(t, tc.yaml).JSON; got != tc.json {
				t.Fatalf("json:\n  got  = %s\n  want = %s", got, tc.json)
			}
		})
	}
}

// ws / http / grpc / h2 option blocks and their header placement.
func TestProfileImportClashTransports(t *testing.T) {
	for _, tc := range []struct {
		name, yaml, json string
	}{
		{
			"ws headers keep non-Host keys",
			`proxies:
  - {name: ws, type: vless, server: v.example.com, port: 443, uuid: u, tls: true, 'ws-opts': {path: /ws, headers: {Host: h.example.com, 'User-Agent': test}}}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"v.example.com","server_port":443,"tag":"ws","tls":{"enabled":true,"server_name":"v.example.com"},"transport":{"headers":{"Host":"h.example.com","User-Agent":"test"},"path":"/ws","type":"ws"},"type":"vless","uuid":"u"}`,
		},
		{
			"grpc service name",
			`proxies:
  - {name: g, type: trojan, server: t.example.com, port: 443, password: p, 'grpc-opts': {'grpc-service-name': svc}}
`,
			`{"multiplex":{"enabled":false},"password":"p","server":"t.example.com","server_port":443,"tag":"g","tls":{"enabled":true,"server_name":"t.example.com"},"transport":{"service_name":"svc","type":"grpc"},"type":"trojan"}`,
		},
		{
			"h2 host list first element",
			`proxies:
  - {name: h2, type: vless, server: v.example.com, port: 443, uuid: u, network: h2, 'h2-opts': {host: [a.example.com, b.example.com], path: /h2}}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"v.example.com","server_port":443,"tag":"h2","transport":{"host":"a.example.com","path":"/h2","type":"http"},"type":"vless","uuid":"u"}`,
		},
		{
			"http-opts host list and path",
			`proxies:
  - {name: h, type: vless, server: v.example.com, port: 443, uuid: u, network: http, 'http-opts': {method: POST, headers: {Host: [h.example.com]}, path: [/p]}}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"v.example.com","server_port":443,"tag":"h","transport":{"host":"h.example.com","method":"POST","path":"/p","type":"http"},"type":"vless","uuid":"u"}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := importClashOne(t, tc.yaml).JSON; got != tc.json {
				t.Fatalf("json:\n  got  = %s\n  want = %s", got, tc.json)
			}
		})
	}
}

// TLS servername/sni fallback, ALPN, fingerprint, certificate pin and REALITY.
func TestProfileImportClashTLS(t *testing.T) {
	for _, tc := range []struct {
		name, yaml, json string
	}{
		{
			"servername wins over sni and server",
			`proxies:
  - {name: r, type: vless, server: v.example.com, port: 443, uuid: u, tls: true, servername: actual.example.com, sni: ignored.example.com, 'skip-cert-verify': true, alpn: [h2, 'http/1.1'], 'client-fingerprint': firefox}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"v.example.com","server_port":443,"tag":"r","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"actual.example.com","utls":{"enabled":true,"fingerprint":"firefox"}},"type":"vless","uuid":"u"}`,
		},
		{
			"server as certificate name fallback",
			`proxies:
  - {name: f, type: trojan, server: fallback.example.com, port: 443, password: p}
`,
			`{"multiplex":{"enabled":false},"password":"p","server":"fallback.example.com","server_port":443,"tag":"f","tls":{"enabled":true,"server_name":"fallback.example.com"},"type":"trojan"}`,
		},
		{
			"certificate pin hex to base64",
			`proxies:
  - {name: p, type: trojan, server: t.example.com, port: 443, password: p, tls: true, fingerprint: 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'}
`,
			`{"multiplex":{"enabled":false},"password":"p","server":"t.example.com","server_port":443,"tag":"p","tls":{"certificate_sha256":["qrvM3e7/ABEiM0RVZneImaq7zN3u/wARIjNEVWZ3iJk="],"enabled":true,"server_name":"t.example.com"},"type":"trojan"}`,
		},
		{
			"reality opts",
			`proxies:
  - {name: rz, type: vless, server: v.example.com, port: 443, uuid: u, tls: true, 'reality-opts': {'public-key': abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI, 'short-id': abc}}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"v.example.com","server_port":443,"tag":"rz","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI","short_id":"abc"},"server_name":"v.example.com"},"type":"vless","uuid":"u"}`,
		},
		{
			"client-fingerprint none becomes unsafe",
			`proxies:
  - {name: n, type: vless, server: v.example.com, port: 443, uuid: u, tls: true, 'client-fingerprint': 'none'}
`,
			`{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"v.example.com","server_port":443,"tag":"n","tls":{"enabled":true,"server_name":"v.example.com","utls":{"enabled":true,"fingerprint":"unsafe"}},"type":"vless","uuid":"u"}`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := importClashOne(t, tc.yaml).JSON; got != tc.json {
				t.Fatalf("json:\n  got  = %s\n  want = %s", got, tc.json)
			}
		})
	}
}

// Unsupported shapes must be refused with a typed reason: no node, no partial
// conversion. The body-level test checks that a refusal does not stop other
// entries from being converted.
func TestProfileImportClashRefusals(t *testing.T) {
	for _, tc := range []struct {
		name, yaml, reason string
	}{
		{"no proxies", `proxy-providers: {sub: {type: http}}`, "no proxies sequence"},
		{"empty proxies", `proxies: []`, "no proxies entries"},
		{"unsupported type", `proxies: [{name: x, type: tuic, server: s, port: 443}]`, "proxy type not ported yet"},
		{"unknown ss plugin", `proxies: [{name: x, type: ss, server: s, port: 8388, plugin: shadow-tls}]`, "plugin not ported yet"},
		{"http tls", `proxies: [{name: x, type: http, server: s, port: 443, tls: true}]`, "http TLS is not ported yet"},
		{"xhttp mode", `proxies: [{name: x, type: vless, server: s, port: 443, network: xhttp, 'xhttp-opts': {path: /x, mode: banana}}]`, "xhttp mode not ported yet"},
		{"unknown fingerprint", `proxies: [{name: x, type: vless, server: s, port: 443, tls: true, 'client-fingerprint': banana}]`, "client-fingerprint not ported yet"},
		{"smux protocol", `proxies: [{name: x, type: vless, server: s, port: 443, smux: {enabled: true, protocol: bogus}}]`, "smux protocol not ported yet"},
		{"hysteria protocol", `proxies: [{name: x, type: hysteria, server: s, port: 443, protocol: quic}]`, "protocol not ported yet"},
		{"reality mldsa65", `proxies: [{name: x, type: vless, server: s, port: 443, tls: true, 'reality-opts': {'public-key': abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI, 'mldsa65-verify': xyz}}]`, "mldsa65-verify is not valid"},
		{"no server", `proxies: [{name: x, type: ss, port: 8388}]`, "no server"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			_, err := profileImportClashBody(tc.yaml)
			if err == nil {
				t.Fatal("want a refusal, got no error")
			}
			var refused profileImportUnsupported
			if !errors.As(err, &refused) {
				t.Fatalf("want profileImportUnsupported, got %T: %v", err, err)
			}
			if !strings.Contains(refused.Reason, tc.reason) {
				t.Fatalf("reason = %q, want substring %q", refused.Reason, tc.reason)
			}
		})
	}
}

func TestProfileImportClashBodyIsAllOrNothing(t *testing.T) {
	// One unported proxy refuses the whole body: the caller must fall back to
	// Kotlin instead of storing a partial subscription.
	yaml := `proxies:
  - {name: keep, type: socks5, server: s.example.com, port: 1080, username: u}
  - {name: skip, type: tuic, server: s, port: 443}
  - {name: keep2, type: http, server: h.example.com, port: 80}
`
	nodes, err := profileImportClashBody(yaml)
	if err == nil {
		t.Fatalf("want a whole-body refusal, got %d nodes", len(nodes))
	}
	if nodes != nil {
		t.Fatalf("refusal must not emit nodes, got %+v", nodes)
	}
	var refused profileImportUnsupported
	if !errors.As(err, &refused) {
		t.Fatalf("want profileImportUnsupported, got %T: %v", err, err)
	}
	if !strings.Contains(refused.Reason, "proxy type not ported yet") {
		t.Fatalf("reason = %q", refused.Reason)
	}
}

func TestProfileImportClashBodyConvertsEveryEntry(t *testing.T) {
	yaml := `proxies:
  - {name: a, type: socks5, server: s.example.com, port: 1080, username: u}
  - {name: b, type: http, server: h.example.com, port: 80}
`
	nodes, err := profileImportClashBody(yaml)
	if err != nil {
		t.Fatalf("profileImportClashBody: %v", err)
	}
	if len(nodes) != 2 || nodes[0].Name != "a" || nodes[1].Name != "b" {
		t.Fatalf("want both nodes in order, got %+v", nodes)
	}
}

func TestClashBandwidthMbps(t *testing.T) {
	for _, tc := range []struct {
		text string
		want int
	}{
		{"100", 100}, {"100 Mbps", 100}, {"50MB/s", 400}, {"1 Gbps", 1000},
		{"500 Kbps", 1}, {"100 Mbps/s", 0}, {"", 0}, {"abc", 0},
	} {
		if got := clashBandwidthMbps(tc.text); got != tc.want {
			t.Errorf("clashBandwidthMbps(%q) = %d, want %d", tc.text, got, tc.want)
		}
	}
}
