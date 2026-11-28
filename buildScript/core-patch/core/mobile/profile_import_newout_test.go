// S5 mieru/snell/shadowtls parity tests. Every expected `json`, `link` and
// `identity` below is the exact Kotlin exportToJson/toCompact, exportToLink and
// exportIdentity output for the same input, produced by the JVM oracle in
// app/src/test/java/io/nekohasekai/sagernet/outbound/NewOutboundsGoParityTest.kt
// (types/{Mieru,Snell,ShadowTls}.kt, common/{Tls,DialFields}.kt).
//
// The Kotlin oracle cannot exercise a vector whose parse reports an import
// warning (vtr needs an Application), so the Kotlin parsers' own drop rules
// (an invalid mieru port item, an invalid multiplexing level, an unpadded
// traffic pattern) are pinned here as Go-only vectors.
package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func assertNewOutboundNode(t *testing.T, node profileImportedNode, wantJSON, wantLink, wantIdentity string) {
	t.Helper()
	if node.JSON != wantJSON {
		t.Fatalf("stored JSON:\n got %s\nwant %s", node.JSON, wantJSON)
	}
	if node.Link != wantLink {
		t.Fatalf("export link:\n got %s\nwant %s", node.Link, wantLink)
	}
	if node.Identity != wantIdentity {
		t.Fatalf("identity:\n got %s\nwant %s", node.Identity, wantIdentity)
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
}

func TestProfileImportNewOutboundLinks(t *testing.T) {
	cases := []struct {
		name     string
		link     string
		json     string
		linkBack string
		identity string
	}{
		{
			name:     "mieru full",
			link:     "mierus://alice:p%40ss@mieru.example.com?port=9000&protocol=tcp&port=9010-9020&protocol=udp&port=9030&multiplexing=MULTIPLEXING_LOW&traffic-pattern=YWJj&reuse_addr=true&connect_timeout=5s#m1",
			json:     `{"connect_timeout":"5s","multiplexing":"MULTIPLEXING_LOW","password":"p@ss","reuse_addr":true,"server":"mieru.example.com","server_port":9000,"server_ports":["9010-9020","9030-9030"],"tag":"m1","traffic_pattern":"YWJj","transport":"TCP","type":"mieru","username":"alice"}`,
			linkBack: "mierus://alice:p%40ss@mieru.example.com?profile=default&port=9000&protocol=TCP&port=9010-9020&protocol=TCP&port=9030-9030&protocol=TCP&multiplexing=MULTIPLEXING_LOW&traffic-pattern=YWJj&reuse_addr=true&connect_timeout=5s#m1",
			identity: `{"server":"mieru.example.com","server_port":9000}`,
		},
		{
			name:     "mieru padding and protocol",
			link:     "mieru://u:p@h.example.com?port=8080&protocol=udp&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8",
			json:     `{"multiplexing":"MULTIPLEXING_HIGH","password":"p","server":"h.example.com","server_port":8080,"traffic_pattern":"aGVsbG8=","transport":"UDP","type":"mieru","username":"u"}`,
			linkBack: "mierus://u:p@h.example.com?profile=default&port=8080&protocol=UDP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8%3D",
			identity: `{"server":"h.example.com","server_port":8080}`,
		},
		{
			name:     "mieru discards authority port",
			link:     "mieru://u:p@mieru.example.com:9999?port=9000",
			json:     `{"password":"p","server":"mieru.example.com","server_port":9000,"transport":"TCP","type":"mieru","username":"u"}`,
			linkBack: "mierus://u:p@mieru.example.com?profile=default&port=9000&protocol=TCP",
			identity: `{"server":"mieru.example.com","server_port":9000}`,
		},
		{
			name:     "snell v6",
			link:     "snell://psk%3Avalue@snell.example.com:8443?version=6&userkey=uk&reuse=1&network=udp&mode=unshaped&connect_timeout=5s#s6",
			json:     `{"connect_timeout":"5s","mode":"unshaped","network":"udp","psk":"psk:value","reuse":true,"server":"snell.example.com","server_port":8443,"tag":"s6","type":"snell","userkey":"uk","version":6}`,
			linkBack: "snell://psk%3Avalue@snell.example.com:8443?version=6&userkey=uk&reuse=1&network=udp&mode=unshaped&connect_timeout=5s#s6",
			identity: `{"server":"snell.example.com","server_port":8443}`,
		},
		{
			name:     "snell v4 obfs",
			link:     "snell://psk@h.example.com:443?version=4&reuse=0&network=tcp&obfs=HTTP&obfs-host=cdn.example.com#s4",
			json:     `{"network":"tcp","obfs_host":"cdn.example.com","obfs_mode":"http","psk":"psk","server":"h.example.com","server_port":443,"tag":"s4","type":"snell","version":4}`,
			linkBack: "snell://psk@h.example.com:443?version=4&network=tcp&obfs=http&obfs-host=cdn.example.com#s4",
			identity: `{"server":"h.example.com","server_port":443}`,
		},
		{
			name:     "snell defaults",
			link:     "snell://psk@h.example.com:443#s0",
			json:     `{"psk":"psk","server":"h.example.com","server_port":443,"tag":"s0","type":"snell","version":4}`,
			linkBack: "snell://psk@h.example.com:443?version=4#s0",
			identity: `{"server":"h.example.com","server_port":443}`,
		},
		{
			name:     "shadowtls full",
			link:     "shadowtls://:pass@st.example.com:443?version=3&sni=sni.example.com&alpn=h2%2Chttp%2F1.1&allowInsecure=1&fp=chrome&connect_timeout=5s#st",
			json:     `{"connect_timeout":"5s","password":"pass","server":"st.example.com","server_port":443,"tag":"st","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"shadowtls","version":3}`,
			linkBack: "shadowtls://:pass@st.example.com:443?version=3&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&fp=chrome&connect_timeout=5s#st",
			identity: `{"server":"st.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}},"version":3}`,
		},
		{
			name:     "shadowtls v1 default port",
			link:     "shadowtls://st.example.com?version=1#st1",
			json:     `{"server":"st.example.com","server_port":443,"tag":"st1","tls":{"enabled":true},"type":"shadowtls","version":1}`,
			linkBack: "shadowtls://st.example.com:443?version=1&security=tls#st1",
			identity: `{"server":"st.example.com","server_port":443,"tls":{"enabled":true},"version":1}`,
		},
		{
			name:     "shadowtls reality link",
			link:     "shadowtls://:pw@st.example.com:443?version=3&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=ab&sni=sni.example.com&security=reality#sr",
			json:     `{"password":"pw","server":"st.example.com","server_port":443,"tag":"sr","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"ab"},"server_name":"sni.example.com"},"type":"shadowtls","version":3}`,
			linkBack: "shadowtls://:pw@st.example.com:443?version=3&security=reality&sni=sni.example.com&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=ab#sr",
			identity: `{"server":"st.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"ab"},"server_name":"sni.example.com"},"version":3}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assertNewOutboundNode(t, profileImportNode(t, tc.link), tc.json, tc.linkBack, tc.identity)
		})
	}
}

// The Kotlin parser drops an invalid port item, an unknown multiplexing level
// and a malformed traffic pattern with a warning; the warning needs an
// Application, so the JVM oracle cannot pin this vector.
func TestProfileImportNewOutboundMieruDrops(t *testing.T) {
	node := profileImportNode(t, "mieru://u:p@h.example.com?port=0-10&port=70000&port=abc&port=9000&port=9010-9020&port=9030")
	assertNewOutboundNode(t, node,
		`{"password":"p","server":"h.example.com","server_port":9000,"server_ports":["9010-9020","9030-9030"],"transport":"TCP","type":"mieru","username":"u"}`,
		"mierus://u:p@h.example.com?profile=default&port=9000&protocol=TCP&port=9010-9020&protocol=TCP&port=9030-9030&protocol=TCP",
		`{"server":"h.example.com","server_port":9000}`,
	)
	cleared := profileImportNode(t, "mieru://u:p@h.example.com?port=1&multiplexing=low&traffic-pattern=a")
	assertNewOutboundNode(t, cleared,
		`{"password":"p","server":"h.example.com","server_port":1,"transport":"TCP","type":"mieru","username":"u"}`,
		"mierus://u:p@h.example.com?profile=default&port=1&protocol=TCP",
		`{"server":"h.example.com","server_port":1}`,
	)
}

func TestProfileImportNewOutboundClash(t *testing.T) {
	cases := []struct {
		name string
		yaml string
		json string
	}{
		{
			name: "snell v4 obfs and udp default",
			yaml: `proxies:
  - {name: sn, type: snell, server: snell.example.com, port: 443, psk: secret, version: 4, 'obfs-opts': {mode: HTTP, host: cdn.example.com}}
`,
			json: `{"network":"tcp","obfs_host":"cdn.example.com","obfs_mode":"http","psk":"secret","server":"snell.example.com","server_port":443,"tag":"sn","type":"snell","version":4}`,
		},
		{
			name: "snell v6 udp",
			yaml: `proxies:
  - {name: snu, type: snell, server: snell.example.com, port: 443, psk: secret, version: 6, udp: true, 'obfs-opts': {mode: tls}}
`,
			json: `{"psk":"secret","server":"snell.example.com","server_port":443,"tag":"snu","type":"snell","version":6}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nodes := importClashNodes(t, tc.yaml)
			if len(nodes) != 1 || nodes[0].JSON != tc.json {
				t.Fatalf("got %+v\nwant %s", nodes, tc.json)
			}
		})
	}
}

func TestProfileImportNewOutboundStoredJSON(t *testing.T) {
	cases := []struct {
		name     string
		document string
		json     string
		linkBack string
	}{
		{
			name:     "mieru",
			document: `{"type":"mieru","tag":"mj","server":"mieru.example.com","server_port":8080,"transport":" tcp","username":"u","password":"p","multiplexing":"MULTIPLEXING_HIGH","traffic_pattern":"aGVsbG8","server_ports":"9000-9010, 9020-9030","reuse_addr":true,"connect_timeout":"5s"}`,
			json:     `{"connect_timeout":"5s","multiplexing":"MULTIPLEXING_HIGH","password":"p","reuse_addr":true,"server":"mieru.example.com","server_port":8080,"server_ports":["9000-9010","9020-9030"],"tag":"mj","traffic_pattern":"aGVsbG8=","transport":"TCP","type":"mieru","username":"u"}`,
			linkBack: "mierus://u:p@mieru.example.com?profile=default&port=8080&protocol=TCP&port=9000-9010&protocol=TCP&port=9020-9030&protocol=TCP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8%3D&reuse_addr=true&connect_timeout=5s#mj",
		},
		{
			name:     "mieru server_ports only",
			document: `{"type":"mieru","server":"h.example.com","server_port":0,"username":"u","password":"p","server_ports":["9000-9010"]}`,
			json:     `{"password":"p","server":"h.example.com","server_ports":["9000-9010"],"transport":"TCP","type":"mieru","username":"u"}`,
			linkBack: "mierus://u:p@h.example.com?profile=default&port=9000-9010&protocol=TCP",
		},
		{
			name:     "snell v6",
			document: `{"type":"snell","tag":"sj","server":"snell.example.com","server_port":443,"version":6,"psk":"secret","userkey":"uk","reuse":true,"network":["tcp","udp"],"mode":" unshaped ","obfs_mode":"http","obfs_host":"x"}`,
			json:     `{"mode":"unshaped","psk":"secret","reuse":true,"server":"snell.example.com","server_port":443,"tag":"sj","type":"snell","userkey":"uk","version":6}`,
			linkBack: "snell://secret@snell.example.com:443?version=6&userkey=uk&reuse=1&mode=unshaped#sj",
		},
		{
			name:     "snell v4 network case",
			document: `{"type":"snell","server":"snell.example.com","server_port":443,"psk":"secret","network":"TCP","obfs_mode":"TLS","obfs_host":"cdn.example.com"}`,
			json:     `{"network":"tcp","obfs_host":"cdn.example.com","obfs_mode":"tls","psk":"secret","server":"snell.example.com","server_port":443,"type":"snell","version":4}`,
			linkBack: "snell://secret@snell.example.com:443?version=4&network=tcp&obfs=tls&obfs-host=cdn.example.com",
		},
		{
			name:     "shadowtls version string and alpn trim",
			document: `{"type":"shadowtls","tag":"sj","server":"st.example.com","server_port":8443,"version":"2","password":"pw","tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"," http/1.1 "]}}`,
			json:     `{"password":"pw","server":"st.example.com","server_port":8443,"tag":"sj","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com"},"type":"shadowtls","version":2}`,
			linkBack: "shadowtls://:pw@st.example.com:8443?version=2&security=tls&sni=sni.example.com&alpn=h2,http/1.1#sj",
		},
		{
			name:     "shadowtls reality",
			document: `{"type":"shadowtls","server":"st.example.com","server_port":443,"version":3,"password":"pw","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":" ab "}}}`,
			json:     `{"password":"pw","server":"st.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"ab"}},"type":"shadowtls","version":3}`,
			linkBack: "shadowtls://:pw@st.example.com:443?version=3&security=reality&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=ab",
		},
		{
			name:     "shadowtls versions",
			document: `{"type":"shadowtls","server":"st.example.com","server_port":443,"version":1,"tls":{"enabled":true,"min_version":"1.2","max_version":"1.3"}}`,
			json:     `{"server":"st.example.com","server_port":443,"tls":{"enabled":true,"max_version":"1.3","min_version":"1.2"},"type":"shadowtls","version":1}`,
			linkBack: "shadowtls://st.example.com:443?version=1&security=tls&tls_min_version=1.2&tls_max_version=1.3",
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

func TestProfileImportNewOutboundRefusals(t *testing.T) {
	// Link-level refusals.
	for _, tc := range []struct {
		link   string
		reason string
	}{
		{"snell://psk@h.example.com:443?version=5#x", "snell version is not supported"},
		{"snell://psk@h.example.com:443?version=abc#x", "snell version is not supported"},
		{"shadowtls://h.example.com?version=4#x", "between 0 and 3"},
		{"shadowtls://h.example.com?version=abc#x", "between 0 and 3"},
		{"shadowtls://h.example.com?security=reality#x", "requires pbk"},
		{"shadowtls://h.example.com:443?version=3&tls_cipher_suites=TLS_AES_128_GCM_SHA256#x", "unsupported TLS field"},
		{"mieru://u:p@h.example.com", "no query"},
	} {
		reason := profileImportRefusal(t, tc.link)
		if !strings.Contains(reason, tc.reason) {
			t.Fatalf("%q: reason = %q, want it to contain %q", tc.link, reason, tc.reason)
		}
	}

	// Clash refusals: Snell's version/obfs gates and the two types Kotlin's
	// Clash table does not list.
	for _, tc := range []struct {
		yaml   string
		reason string
	}{
		{"proxies: [{name: x, type: snell, server: s, port: 443, version: 5}]", "snell version is not supported"},
		{"proxies: [{name: x, type: snell, server: s, port: 443, 'obfs-opts': {mode: shadow-tls}}]", "obfs mode is not supported"},
		{"proxies: [{name: x, type: snell, server: s, port: 443, future: 1}]", "field not ported yet: future"},
		{"proxies: [{name: x, type: mieru, server: s, port: 443}]", "has no Clash mapping"},
		{"proxies: [{name: x, type: shadowtls, server: s, port: 443}]", "has no Clash mapping"},
	} {
		_, err := profileImportClashBody(tc.yaml)
		if err == nil {
			t.Fatalf("%s: want a refusal", tc.yaml)
		}
		if !strings.Contains(err.Error(), tc.reason) {
			t.Fatalf("%s: reason = %q, want %q", tc.yaml, err.Error(), tc.reason)
		}
	}

	// Stored-JSON refusals.
	for _, tc := range []struct {
		document string
		reason   string
	}{
		{`{"type":"snell","server":"h.example.com","server_port":443,"version":5}`, "snell version is not supported"},
		{`{"type":"snell","server":"h.example.com","server_port":443,"future":1}`, "field not ported yet: future"},
		{`{"type":"snell","server":"h.example.com","server_port":443,"psk":1}`, "unsupported value: psk"},
		{`{"type":"mieru","server":"h.example.com","server_port":8080,"server_ports":5}`, "server_ports has unsupported value"},
		{`{"type":"mieru","server":"h.example.com","server_port":8080,"server_ports":"9000"}`, ""},
		{`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":{"enabled":true,"certificate":"x"}}`, "tls field not ported yet: certificate"},
		{`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":"x"}`, "not an object"},
		{`{"type":"shadowtls","server":"h.example.com","server_port":0,"version":1}`, "no valid server_port"},
		{`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":{"enabled":false,"reality":{"enabled":false,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"}}}`, "public_key without enabled"},
		{`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"mldsa65_verify":"bad"}}}`, "not a valid ML-DSA-65"},
	} {
		if tc.reason == "" {
			// A single "9000" server_ports entry is stored as written here; the
			// validator reports the range problem, so the importer accepts it.
			nodes := importBody(t, tc.document)
			if len(nodes) != 1 {
				t.Fatalf("%s: got %d nodes", tc.document, len(nodes))
			}
			continue
		}
		reason := refuseBody(t, tc.document)
		if !strings.Contains(reason, tc.reason) {
			t.Fatalf("%s: reason = %q, want %q", tc.document, reason, tc.reason)
		}
	}
}

func TestProfileExportNewOutbound(t *testing.T) {
	cases := []struct {
		name     string
		document string
		typ      string
		json     string
		link     string
		identity string
	}{
		{
			name:     "mieru",
			document: `{"type":"mieru","tag":"me","server":"mieru.example.com","server_port":8080,"transport":"UDP","username":"u","password":"p","multiplexing":"MULTIPLEXING_HIGH","traffic_pattern":"aGVsbG8=","server_ports":["9000-9010"],"reuse_addr":true}`,
			typ:      "mieru",
			json:     `{"multiplexing":"MULTIPLEXING_HIGH","password":"p","reuse_addr":true,"server":"mieru.example.com","server_port":8080,"server_ports":["9000-9010"],"tag":"me","traffic_pattern":"aGVsbG8=","transport":"UDP","type":"mieru","username":"u"}`,
			link:     "mierus://u:p@mieru.example.com?profile=default&port=8080&protocol=UDP&port=9000-9010&protocol=UDP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8%3D&reuse_addr=true#me",
			identity: `{"server":"mieru.example.com","server_port":8080}`,
		},
		{
			name:     "snell",
			document: `{"type":"snell","tag":"se","server":"s.example.com","server_port":443,"version":6,"psk":"secret","network":"udp","mode":"unshaped","reuse":true,"userkey":"uk"}`,
			typ:      "snell",
			json:     `{"mode":"unshaped","network":"udp","psk":"secret","reuse":true,"server":"s.example.com","server_port":443,"tag":"se","type":"snell","userkey":"uk","version":6}`,
			link:     "snell://secret@s.example.com:443?version=6&userkey=uk&reuse=1&network=udp&mode=unshaped#se",
			identity: `{"server":"s.example.com","server_port":443}`,
		},
		{
			name:     "shadowtls",
			document: `{"type":"shadowtls","tag":"sh","server":"s.example.com","server_port":443,"version":3,"password":"pw","tls":{"enabled":true,"server_name":"sni.example.com","insecure":true,"alpn":["h2"]}}`,
			typ:      "shadowtls",
			json:     `{"password":"pw","server":"s.example.com","server_port":443,"tag":"sh","tls":{"alpn":["h2"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"shadowtls","version":3}`,
			link:     "shadowtls://:pw@s.example.com:443?version=3&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2#sh",
			identity: `{"server":"s.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"version":3}`,
		},
		{
			name:     "shadowtls disabled TLS",
			document: `{"type":"shadowtls","server":"s.example.com","server_port":443,"version":1,"tls":{"enabled":false,"server_name":"sni.example.com"}}`,
			typ:      "shadowtls",
			json:     `{"server":"s.example.com","server_port":443,"type":"shadowtls","version":1}`,
			link:     "shadowtls://s.example.com:443?version=1",
			identity: `{"server":"s.example.com","server_port":443,"version":1}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reply := profileExportReplyFor(t, tc.document, nil)
			if !reply.Supported || reply.Type != tc.typ {
				t.Fatalf("reply = %+v", reply)
			}
			if reply.JSON != tc.json {
				t.Fatalf("json:\n got %s\nwant %s", reply.JSON, tc.json)
			}
			if reply.Link != tc.link {
				t.Fatalf("link:\n got %s\nwant %s", reply.Link, tc.link)
			}
			if reply.Identity != tc.identity {
				t.Fatalf("identity:\n got %s\nwant %s", reply.Identity, tc.identity)
			}
			if reply.DisplayType != profileNewOutboundDisplayType(tc.typ) {
				t.Fatalf("displayType = %q", reply.DisplayType)
			}
		})
	}

	name := "Renamed"
	renamed := profileExportReplyFor(t,
		`{"type":"snell","tag":"se","server":"s.example.com","server_port":443,"version":6,"psk":"secret"}`, &name)
	if !renamed.Supported || renamed.Name != name || !strings.Contains(renamed.JSON, `"tag":"Renamed"`) {
		t.Fatalf("name override reply = %+v", renamed)
	}
	if strings.Contains(decodeDedupPayload(t, renamed.DedupKey), `"tag"`) {
		t.Fatal("dedup payload should have no tag")
	}

	for _, tc := range []struct {
		document string
		reason   string
	}{
		{`{"type":"snell","server":"h.example.com","server_port":443,"version":5}`, "snell version is not supported"},
		{`{"type":"mieru","server":"h.example.com","server_port":8080,"future":1}`, "field not ported yet: future"},
		{`{"type":"mieru","server":"h.example.com","server_port":8080,"transport":"é"}`, "not ASCII"},
		{`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":{"enabled":true,"certificate":"x"}}`, "tls field not ported yet: certificate"},
	} {
		reply := profileExportReplyFor(t, tc.document, nil)
		if reply.Supported {
			t.Fatalf("%s: want supported:false, got %+v", tc.document, reply)
		}
		if !strings.Contains(reply.Reason, tc.reason) {
			t.Fatalf("%s: reason = %q, want %q", tc.document, reply.Reason, tc.reason)
		}
	}
}

func decodeDedupPayload(t *testing.T, dedupKey string) string {
	t.Helper()
	decoded, ok := profileBase64Decode(strings.TrimPrefix(dedupKey, "throne://add/"), true)
	if !ok {
		t.Fatalf("dedup key payload is not base64url: %q", dedupKey)
	}
	return string(decoded)
}

func TestProfileValidateNewOutbound(t *testing.T) {
	valid := []struct {
		name       string
		document   string
		normalized string
	}{
		{
			name:       "mieru",
			document:   `{"type":"mieru","tag":"m","server":"mieru.example.com","server_port":9000,"username":"u","password":"p","transport":"UDP","multiplexing":"MULTIPLEXING_LOW","server_ports":"9010-9020","traffic_pattern":"YWJj","reuse_addr":true}`,
			normalized: `{"multiplexing":"MULTIPLEXING_LOW","password":"p","reuse_addr":true,"server":"mieru.example.com","server_port":9000,"server_ports":["9010-9020"],"tag":"m","traffic_pattern":"YWJj","transport":"UDP","type":"mieru","username":"u"}`,
		},
		{
			name:       "mieru server_ports only",
			document:   `{"type":"mieru","server":"h.example.com","server_port":0,"username":"u","password":"p","server_ports":["9000-9010"]}`,
			normalized: `{"password":"p","server":"h.example.com","server_ports":["9000-9010"],"transport":"TCP","type":"mieru","username":"u"}`,
		},
		{
			name:       "snell v6",
			document:   `{"type":"snell","server":"s.example.com","server_port":443,"version":6,"psk":"p","mode":"unsafe-raw","network":"udp"}`,
			normalized: `{"mode":"unsafe-raw","network":"udp","psk":"p","server":"s.example.com","server_port":443,"type":"snell","version":6}`,
		},
		{
			name:       "shadowtls",
			document:   `{"type":"shadowtls","server":"s.example.com","server_port":443,"version":3,"password":"pw","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"},"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"abcd"}}}`,
			normalized: `{"password":"pw","server":"s.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"abcd"},"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"shadowtls","version":3}`,
		},
	}
	for _, tc := range valid {
		t.Run(tc.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, tc.document)
			if !*result.Supported || !result.OK {
				t.Fatalf("result = %+v", result)
			}
			if len(result.Issues) != 0 {
				t.Fatalf("issues = %+v", result.Issues)
			}
			if result.Normalized != tc.normalized {
				t.Fatalf("normalized:\n got %s\nwant %s", result.Normalized, tc.normalized)
			}
		})
	}

	invalid := []struct {
		name     string
		document string
		issues   []string
	}{
		{"mieru required", `{"type":"mieru","server":"h.example.com","server_port":9000,"transport":"sctp","multiplexing":"low","server_ports":"9000","traffic_pattern":"a"}`, []string{"username", "password", "transport", "multiplexing", "server_ports", "traffic_pattern"}},
		{"snell v4", `{"type":"snell","server":"h.example.com","server_port":443,"obfs_mode":"bogus","mode":"default"}`, []string{"psk", "obfs_mode", "mode"}},
		{"snell v6", `{"type":"snell","server":"h.example.com","server_port":443,"version":6,"psk":"p","mode":"shaped"}`, []string{"mode"}},
		{"shadowtls version", `{"type":"shadowtls","server":"h.example.com","server_port":443,"version":9,"password":"p"}`, []string{"version"}},
		{"shadowtls password", `{"type":"shadowtls","server":"h.example.com","server_port":443,"version":2}`, []string{"password"}},
		{"shadowtls reality", `{"type":"shadowtls","server":"h.example.com","server_port":443,"version":1,"tls":{"enabled":true,"min_version":"1.1","max_version":"1.0","reality":{"enabled":true,"public_key":"bad","short_id":"xyz"}}}`, []string{"tls.max_version", "tls.reality.public_key", "tls.reality.short_id"}},
	}
	for _, tc := range invalid {
		t.Run(tc.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, tc.document)
			if !*result.Supported || result.OK {
				t.Fatalf("result = %+v", result)
			}
			var fields []string
			for _, issue := range result.Issues {
				fields = append(fields, issue.Field)
			}
			for _, want := range tc.issues {
				found := false
				for _, field := range fields {
					if field == want {
						found = true
						break
					}
				}
				if !found {
					t.Fatalf("fields = %v, want %q", fields, want)
				}
			}
		})
	}

	// Warnings do not block saving.
	warned := validateStoredProfileDocument(t,
		`{"type":"snell","server":"h.example.com","server_port":443,"version":6,"psk":"p","obfs_host":"cdn.example.com"}`)
	if !*warned.Supported || !warned.OK {
		t.Fatalf("result = %+v", warned)
	}
	if len(warned.Issues) != 1 || warned.Issues[0].Severity != profileSeverityWarning {
		t.Fatalf("issues = %+v", warned.Issues)
	}

	// Unmodelled fields fall back to Kotlin instead of a verdict.
	for _, document := range []string{
		`{"type":"mieru","server":"h.example.com","server_port":9000,"future":1}`,
		`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":{"enabled":true,"certificate":"x"}}`,
		`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":{"utls":{"enabled":true,"custom":"x"}}}`,
		`{"type":"shadowtls","server":"h.example.com","server_port":443,"tls":{"enabled":false,"reality":{"enabled":false,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"}}}`,
	} {
		result := validateStoredProfileDocument(t, document)
		if result.Supported == nil || *result.Supported {
			t.Fatalf("%s: want supported:false, got %+v", document, result)
		}
		if result.OK {
			t.Fatalf("%s: unsupported document must not answer ok:true", document)
		}
	}
}
