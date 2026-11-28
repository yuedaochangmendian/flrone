// S5 WireGuard/MASQUE parity tests. Every expected `json`, `link` and
// `identity` below is the exact Kotlin exportToJson/toCompact, exportToLink and
// exportIdentity output for the same input, produced by the JVM oracle in
// app/src/test/java/io/nekohasekai/sagernet/outbound/WgMasqueGoParityTest.kt
// (types/{WireGuard,Masque}.kt, common/{Tls,DialFields,QuicFields}.kt,
// Outbound.kt, import/{ClashProxy,ProfileImport}.kt).
//
// The Kotlin oracle cannot exercise a vector whose parse reports an import
// warning (vtr needs an Application), so the parsers' own drop rules (an
// invalid reserved list, an unparsable keepalive, an out-of-range mtu) are
// pinned here as Go-only vectors.
package mobile

import (
	"strings"
	"testing"
)

const (
	wgPrivateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
	wgPublicKey  = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
	wgPSK        = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="
	wgPercentKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA%3D"
	wgPercentPub = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB%3D"
	wgPercentPSK = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC%3D"
)

func assertWgMasqueNode(t *testing.T, node profileImportedNode, wantJSON, wantLink, wantIdentity string) {
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
	decoded, ok := profileBase64Decode(strings.TrimPrefix(node.DedupKey, "throne://add/"), true)
	if !ok {
		t.Fatal("dedupKey is not valid url-safe base64")
	}
	if strings.Contains(string(decoded), `"tag"`) {
		t.Fatal("dedupKey payload should have no tag")
	}
}

func TestProfileImportWireGuardLinks(t *testing.T) {
	cases := []struct {
		name     string
		link     string
		json     string
		linkBack string
		identity string
	}{
		{
			name:     "full fields",
			link:     "wg://" + wgPrivateKey + "@wg.example.com?public_key=" + wgPublicKey + "&pre_shared_key=" + wgPSK + "&reserved=1-2-3&persistent_keepalive_interval=25&local_address=10.0.0.2,fd00::2&mtu=1280&workers=2&udp_timeout=30s&use_system_interface=true&enable_amnezia=true&jc=4&jmin=40&jmax=70&s1=30&s2=40&h1=1&h2=2&h3=3&h4=4&i1=%3Cb%200x1234%3E#w1",
			json:     `{"address":["10.0.0.2/32","fd00::2/128"],"amnezia_wg":{"h1":"1","h2":"2","h3":"3","h4":"4","i1":"<b 0x1234>","jc":4,"jmax":70,"jmin":40,"s1":30,"s2":40},"mtu":1280,"peers":[{"address":"wg.example.com","persistent_keepalive_interval":25,"port":51820,"pre_shared_key":"` + wgPSK + `","public_key":"` + wgPublicKey + `","reserved":[1,2,3]}],"private_key":"` + wgPrivateKey + `","system":true,"tag":"w1","type":"wireguard","udp_timeout":"30s","worker_count":2}`,
			linkBack: "wg://wg.example.com:51820?private_key=" + wgPercentKey + "&local_address=10.0.0.2/32-fd00::2/128&mtu=1280&use_system_interface=true&workers=2&udp_timeout=30s&enable_amnezia=true&jc=4&jmin=40&jmax=70&s1=30&s2=40&h1=1&h2=2&h3=3&h4=4&i1=%3Cb%200x1234%3E&public_key=" + wgPercentPub + "&pre_shared_key=" + wgPercentPSK + "&reserved=1-2-3&persistent_keepalive_interval=25#w1",
			identity: `{"server":"wg.example.com","server_port":51820}`,
		},
		{
			name:     "defaults",
			link:     "wg://h.example.com?private_key=" + wgPrivateKey + "&public_key=" + wgPublicKey + "#n",
			json:     `{"mtu":1420,"peers":[{"address":"h.example.com","port":51820,"public_key":"` + wgPublicKey + `"}],"private_key":"` + wgPrivateKey + `","tag":"n","type":"wireguard"}`,
			linkBack: "wg://h.example.com:51820?private_key=" + wgPercentKey + "&public_key=" + wgPercentPub + "#n",
			identity: `{"server":"h.example.com","server_port":51820}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assertWgMasqueNode(t, profileImportNode(t, tc.link), tc.json, tc.linkBack, tc.identity)
		})
	}
}

// The Kotlin parser drops an invalid reserved list, an unparsable mtu/workers
// value and an out-of-range Jc/Jmin/Jmax with a warning; the warning needs an
// Application, so the JVM oracle cannot pin this vector.
func TestProfileImportWireGuardLinkDrops(t *testing.T) {
	node := profileImportNode(t, "wg://h.example.com?private_key="+wgPrivateKey+
		"&public_key="+wgPublicKey+"&reserved=1-2&keepalive=abc&mtu=abc&workers=abc&jc=abc")
	assertWgMasqueNode(t, node,
		`{"mtu":1420,"peers":[{"address":"h.example.com","port":51820,"public_key":"`+wgPublicKey+`"}],"private_key":"`+wgPrivateKey+`","type":"wireguard"}`,
		"wg://h.example.com:51820?private_key="+wgPercentKey+"&enable_amnezia=true&public_key="+wgPercentPub,
		`{"server":"h.example.com","server_port":51820}`,
	)
	// enable_amnezia alone is kept even when every Amnezia value is dropped.
	amnezia := profileImportNode(t, "wg://h.example.com?private_key="+wgPrivateKey+
		"&public_key="+wgPublicKey+"&enable_amnezia=true")
	assertWgMasqueNode(t, amnezia,
		`{"mtu":1420,"peers":[{"address":"h.example.com","port":51820,"public_key":"`+wgPublicKey+`"}],"private_key":"`+wgPrivateKey+`","type":"wireguard"}`,
		"wg://h.example.com:51820?private_key="+wgPercentKey+"&enable_amnezia=true&public_key="+wgPercentPub,
		`{"server":"h.example.com","server_port":51820}`,
	)
}

func TestProfileImportWireGuardStoredJSON(t *testing.T) {
	cases := []struct {
		name     string
		document string
		json     string
		linkBack string
		identity string
	}{
		{
			name: "address string reserved base64 and server keys",
			document: `{"type":"wireguard","tag":"wj","server":"ignored.example.com","server_port":444,"private_key":"` + wgPrivateKey + `",` +
				`"peers":[{"address":"peer.example.com","port":51820,"public_key":"` + wgPublicKey + `","pre_shared_key":"` + wgPSK + `","reserved":"AQID","persistent_keepalive_interval":"22-30"}],` +
				`"address":"10.1.0.2","mtu":1300,"system":true,"worker_count":2,"udp_timeout":" 15s "}`,
			json: `{"address":["10.1.0.2/32"],"mtu":1300,"peers":[{"address":"peer.example.com","persistent_keepalive_interval":"22-30","port":51820,"pre_shared_key":"` + wgPSK + `","public_key":"` + wgPublicKey + `","reserved":[1,2,3]}],"private_key":"` + wgPrivateKey + `","system":true,"tag":"wj","type":"wireguard","udp_timeout":"15s","worker_count":2}`,
			linkBack: "wg://peer.example.com:51820?private_key=" + wgPercentKey + "&local_address=10.1.0.2/32&mtu=1300&use_system_interface=true&workers=2&udp_timeout=15s&public_key=" + wgPercentPub + "&pre_shared_key=" + wgPercentPSK + "&reserved=1-2-3&persistent_keepalive_interval=22-30#wj",
			identity: `{"server":"ignored.example.com","server_port":444}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nodes := importBody(t, tc.document)
			if len(nodes) != 1 {
				t.Fatalf("got %d nodes", len(nodes))
			}
			assertWgMasqueNode(t, nodes[0], tc.json, tc.linkBack, tc.identity)
		})
	}
}

// A reserved string that is not a 3-byte base64 value and an unparsable
// keepalive are dropped with a warning; the warning needs an Application, so
// the JVM oracle cannot pin this vector.
func TestProfileImportWireGuardStoredJSONDrops(t *testing.T) {
	nodes := importBody(t, `{"type":"wireguard","private_key":"`+wgPrivateKey+`",`+
		`"peers":[{"address":"peer.example.com","port":51820,"public_key":"`+wgPublicKey+`","reserved":"not base64!","persistent_keepalive_interval":"abc"}]}`)
	if len(nodes) != 1 {
		t.Fatalf("got %d nodes", len(nodes))
	}
	assertWgMasqueNode(t, nodes[0],
		`{"mtu":1420,"peers":[{"address":"peer.example.com","port":51820,"public_key":"`+wgPublicKey+`"}],"private_key":"`+wgPrivateKey+`","type":"wireguard"}`,
		"wg://peer.example.com:51820?private_key="+wgPercentKey+"&public_key="+wgPercentPub,
		`{"mtu":1420,"peers":[{"address":"peer.example.com","port":51820,"public_key":"`+wgPublicKey+`"}],"private_key":"`+wgPrivateKey+`","type":"wireguard"}`,
	)
}

func TestProfileImportMasqueClash(t *testing.T) {
	cases := []struct {
		name     string
		yaml     string
		json     string
		identity string
	}{
		{
			name: "h2 with sni",
			yaml: `proxies:
  - {name: m1, type: masque, server: consumer.example.com, port: 443, 'private-key': ` + wgPrivateKey + `, 'public-key': ` + wgPublicKey + `, ip: 172.16.0.2, ipv6: 'fd00::2', mtu: 1280, sni: sni.example.com, skip-cert-verify: true, network: h2}
`,
			json:     `{"address":["172.16.0.2/32","fd00::2/128"],"http_version":2,"mtu":1280,"peer_public_key":"` + wgPublicKey + `","private_key":"` + wgPrivateKey + `","server":"consumer.example.com","server_port":443,"tag":"m1","tls":{"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"masque"}`,
			identity: `{"private_key":"` + wgPrivateKey + `","server":"consumer.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
		{
			name: "h3 default port and sni",
			yaml: `proxies:
  - {name: m3, type: masque, server: consumer.example.com, 'private-key': ` + wgPrivateKey + `, ip: 172.16.0.2}
`,
			json:     `{"address":["172.16.0.2/32"],"disable_version_fallback":true,"http_version":3,"mtu":1280,"private_key":"` + wgPrivateKey + `","server":"consumer.example.com","server_port":443,"tag":"m3","tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}`,
			identity: `{"private_key":"` + wgPrivateKey + `","server":"consumer.example.com","server_port":443,"tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nodes := importClashNodes(t, tc.yaml)
			if len(nodes) != 1 {
				t.Fatalf("got %d nodes", len(nodes))
			}
			assertWgMasqueNode(t, nodes[0], tc.json, "", tc.identity)
		})
	}
}

func TestProfileImportMasqueStoredJSON(t *testing.T) {
	cases := []struct {
		name     string
		document string
		json     string
		identity string
	}{
		{
			name: "full document",
			document: `{"type":"masque","tag":"mj","server":"consumer.example.com","server_port":443,"private_key":"` + wgPrivateKey + `",` +
				`"peer_public_key":"` + wgPublicKey + `","address":["172.16.0.2"],"mtu":1280,"http_version":2,"disable_version_fallback":true,` +
				`"tls":{"enabled":true,"server_name":"sni.example.com","insecure":true},"idle_timeout":"30s","initial_packet_size":1400}`,
			json: `{"address":["172.16.0.2/32"],"disable_version_fallback":true,"http_version":2,"idle_timeout":"30s","initial_packet_size":1400,"mtu":1280,"peer_public_key":"` + wgPublicKey + `","private_key":"` + wgPrivateKey + `","server":"consumer.example.com","server_port":443,"tag":"mj","tls":{"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"masque"}`,
			identity: `{"private_key":"` + wgPrivateKey + `","server":"consumer.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
		{
			name:     "tls block without server_name clears the default sni",
			document: `{"type":"masque","tag":"md","private_key":"` + wgPrivateKey + `","address":["172.16.0.2"],"tls":{"enabled":true}}`,
			json:     `{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"` + wgPrivateKey + `","server_port":443,"tag":"md","tls":{"enabled":true},"type":"masque"}`,
			identity: `{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"` + wgPrivateKey + `","server_port":443,"tag":"md","tls":{"enabled":true},"type":"masque"}`,
		},
		{
			name:     "no tls key keeps the constructor sni",
			document: `{"type":"masque","tag":"mt","private_key":"` + wgPrivateKey + `","address":["172.16.0.2"]}`,
			json:     `{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"` + wgPrivateKey + `","server_port":443,"tag":"mt","tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}`,
			identity: `{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"` + wgPrivateKey + `","server_port":443,"tag":"mt","tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nodes := importBody(t, tc.document)
			if len(nodes) != 1 {
				t.Fatalf("got %d nodes", len(nodes))
			}
			assertWgMasqueNode(t, nodes[0], tc.json, "", tc.identity)
		})
	}
}

func TestProfileExportWgMasque(t *testing.T) {
	cases := []struct {
		name     string
		document string
		typ      string
		json     string
		link     string
		identity string
	}{
		{
			name:     "wireguard",
			document: `{"type":"wireguard","tag":"we","private_key":"` + wgPrivateKey + `","address":["10.0.0.2/32"],"mtu":1280,"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `","reserved":[1,2,3],"persistent_keepalive_interval":"22-30"}]}`,
			typ:      "wireguard",
			json:     `{"address":["10.0.0.2/32"],"mtu":1280,"peers":[{"address":"p.example.com","persistent_keepalive_interval":"22-30","port":51820,"public_key":"` + wgPublicKey + `","reserved":[1,2,3]}],"private_key":"` + wgPrivateKey + `","tag":"we","type":"wireguard"}`,
			link:     "wg://p.example.com:51820?private_key=" + wgPercentKey + "&local_address=10.0.0.2/32&mtu=1280&public_key=" + wgPercentPub + "&reserved=1-2-3&persistent_keepalive_interval=22-30#we",
			identity: `{"address":["10.0.0.2/32"],"mtu":1280,"peers":[{"address":"p.example.com","persistent_keepalive_interval":"22-30","port":51820,"public_key":"` + wgPublicKey + `","reserved":[1,2,3]}],"private_key":"` + wgPrivateKey + `","tag":"we","type":"wireguard"}`,
		},
		{
			name:     "masque",
			document: `{"type":"masque","tag":"me","server":"s.example.com","server_port":443,"private_key":"` + wgPrivateKey + `","address":"172.16.0.2","mtu":900,"http_version":3,"disable_version_fallback":true,"tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"]},"reuse_addr":true,"idle_timeout":"10s"}`,
			typ:      "masque",
			json:     `{"address":["172.16.0.2/32"],"disable_version_fallback":true,"http_version":3,"idle_timeout":"10s","mtu":900,"private_key":"` + wgPrivateKey + `","reuse_addr":true,"server":"s.example.com","server_port":443,"tag":"me","tls":{"alpn":["h2"],"enabled":true,"server_name":"sni.example.com"},"type":"masque"}`,
			link:     "",
			identity: `{"private_key":"` + wgPrivateKey + `","server":"s.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
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
			if reply.DisplayType != profileWgMasqueDisplayType(tc.typ) {
				t.Fatalf("displayType = %q", reply.DisplayType)
			}
			if !strings.HasPrefix(reply.JSONLink, "throne://add/") || reply.DedupKey == "" {
				t.Fatalf("reply = %+v", reply)
			}
		})
	}

	name := "Renamed"
	renamed := profileExportReplyFor(t,
		`{"type":"wireguard","private_key":"`+wgPrivateKey+`","peers":[{"address":"p.example.com","port":51820,"public_key":"`+wgPublicKey+`"}]}`, &name)
	if !renamed.Supported || renamed.Name != name || !strings.Contains(renamed.JSON, `"tag":"Renamed"`) {
		t.Fatalf("name override reply = %+v", renamed)
	}
	if strings.Contains(decodeDedupPayload(t, renamed.DedupKey), `"tag"`) {
		t.Fatal("dedup payload should have no tag")
	}
}

func TestProfileImportWgMasqueRefusals(t *testing.T) {
	// Link-level refusals.
	for _, tc := range []struct {
		link   string
		reason string
	}{
		{"wg://h.example.com?public_key=" + wgPublicKey, "needs private_key"},
		{"wg://h.example.com?private_key=" + wgPrivateKey, "needs private_key"},
		{"wg://?private_key=" + wgPrivateKey + "&public_key=" + wgPublicKey, "malformed wireguard link"},
		{"wg://h.example.com?private_key=" + wgPrivateKey + "&public_key=" + wgPublicKey + "&s1=70000", "s1 must be an integer"},
		{"masque://h.example.com", "masque has no share link"},
	} {
		reason := profileImportRefusal(t, tc.link)
		if !strings.Contains(reason, tc.reason) {
			t.Fatalf("%q: reason = %q, want it to contain %q", tc.link, reason, tc.reason)
		}
	}

	// The wg-quick INI body is a precise refusal: its profile name comes from
	// comment extraction this slice does not port.
	ini := "[Interface]\nPrivateKey = " + wgPrivateKey + "\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = " + wgPublicKey + "\nEndpoint = wg.example.com:51820\n"
	if reason := refuseBody(t, ini); !strings.Contains(reason, "wireguard ini configuration is not ported yet") {
		t.Fatalf("ini reason = %q", reason)
	}

	// Clash: neither endpoint has a WireGuard mapping; masque needs a key.
	for _, tc := range []struct {
		yaml   string
		reason string
	}{
		{"proxies: [{name: x, type: wireguard, server: s, port: 51820, private-key: k, public-key: p}]", "has no Clash mapping"},
		{"proxies: [{name: x, type: masque, server: s, ip: 172.16.0.2}]", "masque needs a private-key"},
		{"proxies: [{name: x, type: masque, server: s, 'private-key': k, future: 1}]", "field not ported yet: future"},
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
		{`{"type":"wireguard","private_key":"x","future":1}`, "field not ported yet: future"},
		{`{"type":"wireguard","private_key":"x","peers":[{"address":"p","public_key":"k","future":1}]}`, "peers[0].future"},
		{`{"type":"masque","private_key":"x","future":1}`, "field not ported yet: future"},
		{`{"type":"masque","private_key":"x","tls":{"enabled":true,"certificate":"x"}}`, "tls field not ported yet: certificate"},
		{`{"type":"masque","private_key":"x","tls":{"enabled":true,"reality":{"enabled":true,"future":1}}}`, "tls.reality field not ported yet: future"},
	} {
		reason := refuseBody(t, tc.document)
		if !strings.Contains(reason, tc.reason) {
			t.Fatalf("%s: reason = %q, want %q", tc.document, reason, tc.reason)
		}
	}

	// Export refusals keep the supported:false reply shape.
	for _, tc := range []struct {
		document string
		reason   string
	}{
		{`{"type":"wireguard","private_key":"x","future":1}`, "field not ported yet: future"},
		{`{"type":"masque","private_key":"x","tls":{"enabled":true,"utls":{"enabled":true,"custom":"x"}}}`, "tls.utls field not ported yet: custom"},
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

func TestProfileValidateWgMasque(t *testing.T) {
	valid := []struct {
		name       string
		document   string
		normalized string
	}{
		{
			name:       "wireguard",
			document:   `{"type":"wireguard","private_key":"` + wgPrivateKey + `","address":["10.0.0.2/32"],"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `"}]}`,
			normalized: `{"address":["10.0.0.2/32"],"mtu":1420,"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `"}],"private_key":"` + wgPrivateKey + `","type":"wireguard"}`,
		},
		{
			name:       "wireguard amnezia",
			document:   `{"type":"wireguard","private_key":"` + wgPrivateKey + `","address":["10.0.0.2/32"],"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `"}],"amnezia_wg":{"jc":4,"jmin":40,"jmax":70,"s1":30,"s2":40,"s3":30,"s4":40,"h1":"100","h2":"200","h3":"300","h4":"400","i1":"<b 0x1234><r 10>","header_protection_key":"` + wgPrivateKey + `"}}`,
			normalized: `{"address":["10.0.0.2/32"],"amnezia_wg":{"h1":"100","h2":"200","h3":"300","h4":"400","header_protection_key":"` + wgPrivateKey + `","i1":"<b 0x1234><r 10>","jc":4,"jmax":70,"jmin":40,"s1":30,"s2":40,"s3":30,"s4":40},"mtu":1420,"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `"}],"private_key":"` + wgPrivateKey + `","type":"wireguard"}`,
		},
		{
			name:       "masque",
			document:   `{"type":"masque","server":"consumer.example.com","private_key":"` + wgPrivateKey + `","address":["172.16.0.2/32"],"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
			normalized: `{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"` + wgPrivateKey + `","server":"consumer.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"type":"masque"}`,
		},
	}
	for _, tc := range valid {
		t.Run(tc.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, tc.document)
			if !*result.Supported || !result.OK || len(result.Issues) != 0 {
				t.Fatalf("result = %+v", result)
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
		{
			name:     "wireguard keys and endpoint",
			document: `{"type":"wireguard","peers":[{"address":"p.example.com","public_key":"short","reserved":[1,2]}],"address":["10.0.0.300/32"]}`,
			issues:   []string{"private_key", "public_key", "reserved", "server_port", "address"},
		},
		{
			name:     "wireguard reserved keepalive timeout",
			document: `{"type":"wireguard","private_key":"` + wgPrivateKey + `","address":["10.0.0.2/32"],"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `","reserved":[1,2],"persistent_keepalive_interval":"abc"}],"udp_timeout":"abc"}`,
			issues:   []string{"reserved", "persistent_keepalive_interval", "udp_timeout"},
		},
		{
			name:     "wireguard amnezia",
			document: `{"type":"wireguard","private_key":"` + wgPrivateKey + `","address":["10.0.0.2/32"],"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `"}],"amnezia_wg":{"s1":70000,"s2":10,"h1":"100-200","h2":"150","i1":"<z>","content_padding_addition":"abc","jmin":60,"jmax":50}}`,
			issues:   []string{"s1", "h1", "i1", "content_padding_addition", "jmin"},
		},
		{
			name:     "masque fields",
			document: `{"type":"masque","private_key":"short","peer_public_key":"short","http_version":5}`,
			issues:   []string{"private_key", "peer_public_key", "address", "http_version"},
		},
		{
			name:     "masque quic",
			document: `{"type":"masque","private_key":"` + wgPrivateKey + `","address":["172.16.0.2/32"],"idle_timeout":"abc","initial_packet_size":1000}`,
			issues:   []string{"idle_timeout", "initial_packet_size"},
		},
		{
			name:     "masque tls",
			document: `{"type":"masque","private_key":"` + wgPrivateKey + `","address":["172.16.0.2/32"],"tls":{"enabled":true,"min_version":"1.3","max_version":"1.2","utls":{"enabled":true,"fingerprint":"bogus"},"reality":{"enabled":true,"public_key":"bad","short_id":"xyz"}}}`,
			issues:   []string{"tls.max_version", "tls.utls.fingerprint", "tls.reality.public_key", "tls.reality.short_id"},
		},
	}
	for _, tc := range invalid {
		t.Run(tc.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, tc.document)
			if !*result.Supported || result.OK {
				t.Fatalf("result = %+v", result)
			}
			fields := map[string]bool{}
			for _, issue := range result.Issues {
				fields[issue.Field] = true
			}
			for _, want := range tc.issues {
				if !fields[want] {
					t.Fatalf("fields = %v, want %q", fields, want)
				}
			}
		})
	}

	// Warnings do not block saving.
	for _, document := range []string{
		`{"type":"wireguard","private_key":"` + wgPrivateKey + `","address":["10.0.0.2/32"],"peers":[{"address":"p.example.com","port":51820,"public_key":"` + wgPublicKey + `"}],"amnezia_wg":{"jmin":60,"jmax":50}}`,
		`{"type":"masque","server":"consumer.example.com","private_key":"` + wgPrivateKey + `","address":["172.16.0.2/32"],"tls":{"enabled":true,"server_name":"bad name"}}`,
	} {
		result := validateStoredProfileDocument(t, document)
		if !*result.Supported || !result.OK {
			t.Fatalf("%s: result = %+v", document, result)
		}
		if len(result.Issues) != 1 || result.Issues[0].Severity != profileSeverityWarning {
			t.Fatalf("%s: issues = %+v", document, result.Issues)
		}
	}

	// Unmodelled fields fall back to Kotlin instead of a verdict.
	for _, document := range []string{
		`{"type":"wireguard","private_key":"x","future":1}`,
		`{"type":"masque","private_key":"x","future":1}`,
		`{"type":"masque","private_key":"x","tls":{"enabled":true,"certificate":"x"}}`,
		`{"type":"masque","private_key":"x","tls":{"enabled":true,"utls":{"enabled":true,"custom":"x"}}}`,
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
