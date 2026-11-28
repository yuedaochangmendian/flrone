// S5 juicity/naive/ssh/trusttunnel parity tests. Every expected `json`, `link`
// and `identity` below is the exact Kotlin exportToJson/toCompact, exportToLink
// and exportIdentity output for the same input, produced by the JVM oracle in
// app/src/test/java/io/nekohasekai/sagernet/outbound/S5JuicityGoParityTest.kt
// (types/{Juicity,Naive,Ssh,TrustTunnel}.kt, common/{Tls,DialFields}.kt).
//
// The Kotlin oracle cannot exercise a vector whose parse reports an import
// warning (vtr needs an Application), so the Kotlin parsers' own drop rules (an
// unknown congestion-control name, an encrypted-but-unpadded reality key) are
// pinned here as Go-only vectors.
package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func assertS5Node(t *testing.T, node profileImportedNode, wantJSON, wantLink, wantIdentity string) {
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
}

const s5JuicityUUID = "8b7e6b1a-3c4d-4e5f-9a0b-1c2d3e4f5a6b"

func TestProfileImportS5NewLinks(t *testing.T) {
	cases := []struct {
		name     string
		link     string
		json     string
		linkBack string
		identity string
	}{
		{
			name:     "juicity full",
			link:     "juicity://" + s5JuicityUUID + ":p%40ss@juicity.example.com:8443?sni=sni.example.com&alpn=h2%2Chttp%2F1.1&allowInsecure=1&fp=chrome&connect_timeout=5s#j1",
			json:     `{"connect_timeout":"5s","password":"p@ss","server":"juicity.example.com","server_port":8443,"tag":"j1","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"juicity","uuid":"` + s5JuicityUUID + `"}`,
			linkBack: "juicity://" + s5JuicityUUID + ":p%40ss@juicity.example.com:8443?security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&fp=chrome&connect_timeout=5s#j1",
			identity: `{"server":"juicity.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
		},
		{
			name:     "juicity default port",
			link:     "juicity://" + s5JuicityUUID + "@h.example.com#j0",
			json:     `{"server":"h.example.com","server_port":443,"tag":"j0","tls":{"enabled":true},"type":"juicity","uuid":"` + s5JuicityUUID + `"}`,
			linkBack: "juicity://" + s5JuicityUUID + "@h.example.com:443?security=tls#j0",
			identity: `{"server":"h.example.com","server_port":443,"tls":{"enabled":true}}`,
		},
		{
			name:     "juicity reality",
			link:     "juicity://" + s5JuicityUUID + ":pw@h.example.com:443?pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=ab&sni=sni.example.com&security=reality#jr",
			json:     `{"password":"pw","server":"h.example.com","server_port":443,"tag":"jr","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"ab"},"server_name":"sni.example.com"},"type":"juicity","uuid":"` + s5JuicityUUID + `"}`,
			linkBack: "juicity://" + s5JuicityUUID + ":pw@h.example.com:443?security=reality&sni=sni.example.com&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=ab#jr",
			identity: `{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"ab"},"server_name":"sni.example.com"}}`,
		},
		{
			name:     "naive https full",
			link:     "naive+https://alice:p%40ss@naive.example.com:8443?sni=sni.example.com&extra-headers=A%3A%201%0D%0AB%3A%202&insecure-concurrency=2&uot=1&tls_fragment=true&tls_certificate=-----BEGIN%20CERTIFICATE-----%2CMIIBAA%3D%3D%2C-----END%20CERTIFICATE-----#n1",
			json:     `{"extra_headers":{"A":"1","B":"2"},"insecure_concurrency":2,"password":"p@ss","server":"naive.example.com","server_port":8443,"tag":"n1","tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIBAA==","-----END CERTIFICATE-----"],"enabled":true,"fragment":true,"server_name":"sni.example.com"},"type":"naive","udp_over_tcp":true,"username":"alice"}`,
			linkBack: "naive+https://alice:p%40ss@naive.example.com:8443?sni=sni.example.com&extra-headers=A%3A1%0D%0AB%3A2&insecure-concurrency=2&uot=1&tls_certificate=-----BEGIN%20CERTIFICATE-----,MIIBAA%3D%3D,-----END%20CERTIFICATE-----&tls_fragment=true#n1",
			identity: `{"server":"naive.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
		{
			name:     "naive quic",
			link:     "naive+quic://u:p@h.example.com?congestion_control=bbr2&uot=true#nq",
			json:     `{"password":"p","quic":true,"quic_congestion_control":"bbr2","server":"h.example.com","server_port":443,"tag":"nq","tls":{"enabled":true},"type":"naive","udp_over_tcp":true,"username":"u"}`,
			linkBack: "naive+quic://u:p@h.example.com:443?uot=1&congestion_control=bbr2#nq",
			identity: `{"server":"h.example.com","server_port":443,"tls":{"enabled":true}}`,
		},
		{
			name:     "naive https default",
			link:     "naive+https://h.example.com:443#nd",
			json:     `{"server":"h.example.com","server_port":443,"tag":"nd","tls":{"enabled":true},"type":"naive"}`,
			linkBack: "naive+https://h.example.com:443#nd",
			identity: `{"server":"h.example.com","server_port":443,"tls":{"enabled":true}}`,
		},
		{
			name:     "ssh full",
			link:     "ssh://h.example.com:2222?user=u&password=p&private_key=LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KTUlJQkFBPT0KLS0tLS1FTkQgT1BFTlNTSCBQUklWQVRFIEtFWS0tLS0t&host_key=c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBQTBGQlFRPT0&host_key_algorithms=c3NoLWVkMjU1MTk&client_version=SSH-2.0-OpenSSH_9.0#s1",
			json:     `{"client_version":"SSH-2.0-OpenSSH_9.0","host_key":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAA0FBQQ=="],"host_key_algorithms":["ssh-ed25519"],"password":"p","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nMIIBAA==\n-----END OPENSSH PRIVATE KEY-----","server":"h.example.com","server_port":2222,"tag":"s1","type":"ssh","user":"u"}`,
			linkBack: "ssh://h.example.com:2222?user=u&password=p&private_key=LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KTUlJQkFBPT0KLS0tLS1FTkQgT1BFTlNTSCBQUklWQVRFIEtFWS0tLS0t&host_key=c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBQTBGQlFRPT0&host_key_algorithms=c3NoLWVkMjU1MTk&client_version=SSH-2.0-OpenSSH_9.0#s1",
			identity: `{"server":"h.example.com","server_port":2222}`,
		},
		{
			name:     "ssh default port",
			link:     "ssh://h.example.com#s0",
			json:     `{"server":"h.example.com","tag":"s0","type":"ssh"}`,
			linkBack: "ssh://h.example.com:0#s0",
			identity: `{"server":"h.example.com","server_port":0}`,
		},
		{
			name:     "trusttunnel full",
			link:     "tt://user:pass@tt.example.com:443?health_check=true&congestion_control=cubic&custom_sni=sni.example.com&client_random=abcdef/ffffff&connect_timeout=5s#t1",
			json:     `{"client_random":"abcdef/ffffff","connect_timeout":"5s","custom_sni":"sni.example.com","health_check":true,"password":"pass","quic":true,"quic_congestion_control":"cubic","server":"tt.example.com","server_port":443,"tag":"t1","tls":{"enabled":true},"type":"trusttunnel","username":"user"}`,
			linkBack: "tt://user:pass@tt.example.com:443?health_check=true&congestion_control=cubic&custom_sni=sni.example.com&client_random=abcdef/ffffff&security=tls&connect_timeout=5s#t1",
			identity: `{"server":"tt.example.com","server_port":443,"tls":{"enabled":true}}`,
		},
		{
			name:     "trusttunnel defaults",
			link:     "tt://user:pass@tt.example.com#t0",
			json:     `{"password":"pass","server":"tt.example.com","server_port":443,"tag":"t0","tls":{"enabled":true},"type":"trusttunnel","username":"user"}`,
			linkBack: "tt://user:pass@tt.example.com:443?security=tls#t0",
			identity: `{"server":"tt.example.com","server_port":443,"tls":{"enabled":true}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			assertS5Node(t, profileImportNode(t, tc.link), tc.json, tc.linkBack, tc.identity)
		})
	}
}

func TestProfileImportS5NewStoredJSON(t *testing.T) {
	cases := []struct {
		name  string
		doc   string
		json  string
		link  string
		ident string
	}{
		{
			name:  "juicity",
			doc:   `{"type":"juicity","tag":"jj","server":"juicity.example.com","server_port":8443,"uuid":"` + s5JuicityUUID + `","password":"pw","tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"," http/1.1 "],"insecure":true,"utls":{"enabled":true,"fingerprint":"chrome"},"fragment":false}}`,
			json:  `{"password":"pw","server":"juicity.example.com","server_port":8443,"tag":"jj","tls":{"alpn":["h2","http/1.1"],"enabled":true,"fragment":false,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"juicity","uuid":"` + s5JuicityUUID + `"}`,
			link:  "juicity://" + s5JuicityUUID + ":pw@juicity.example.com:8443?security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&tls_fragment=false&fp=chrome#jj",
			ident: `{"server":"juicity.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}`,
		},
		{
			name:  "naive",
			doc:   `{"type":"naive","tag":"nj","server":"naive.example.com","server_port":8443,"username":"u","password":"p","insecure_concurrency":3,"extra_headers":{"B":["x","y"],"A":"z"},"udp_over_tcp":{"enabled":true},"quic":true,"quic_congestion_control":"cubic","tls":{"enabled":false,"server_name":"Sni.Example","alpn":["h2"],"certificate":["-----BEGIN CERTIFICATE-----","","MIIBAA==","-----END CERTIFICATE-----"],"fragment":false,"insecure":true}}`,
			json:  `{"extra_headers":{"A":"z","B":"x"},"insecure_concurrency":3,"password":"p","quic":true,"quic_congestion_control":"cubic","server":"naive.example.com","server_port":8443,"tag":"nj","tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIBAA==","-----END CERTIFICATE-----"],"enabled":true,"fragment":false,"server_name":"Sni.Example"},"type":"naive","udp_over_tcp":true,"username":"u"}`,
			link:  "naive+quic://u:p@naive.example.com:8443?sni=Sni.Example&extra-headers=A%3Az%0D%0AB%3Ax&insecure-concurrency=3&uot=1&congestion_control=cubic&tls_certificate=-----BEGIN%20CERTIFICATE-----,MIIBAA%3D%3D,-----END%20CERTIFICATE-----&tls_fragment=false#nj",
			ident: `{"server":"naive.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"Sni.Example"}}`,
		},
		{
			name:  "ssh",
			doc:   `{"type":"ssh","tag":"sj","server":"ssh.example.com","server_port":2222,"user":"u","password":"p","private_key":["-----BEGIN OPENSSH PRIVATE KEY-----","MIIBAA==","-----END OPENSSH PRIVATE KEY-----"],"host_key":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAA0FBQQ=="],"host_key_algorithms":["ssh-ed25519"],"client_version":"SSH-2.0-X"}`,
			json:  `{"client_version":"SSH-2.0-X","host_key":["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAA0FBQQ=="],"host_key_algorithms":["ssh-ed25519"],"password":"p","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nMIIBAA==\n-----END OPENSSH PRIVATE KEY-----","server":"ssh.example.com","server_port":2222,"tag":"sj","type":"ssh","user":"u"}`,
			link:  "ssh://ssh.example.com:2222?user=u&password=p&private_key=LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KTUlJQkFBPT0KLS0tLS1FTkQgT1BFTlNTSCBQUklWQVRFIEtFWS0tLS0t&host_key=c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBQTBGQlFRPT0&host_key_algorithms=c3NoLWVkMjU1MTk&client_version=SSH-2.0-X#sj",
			ident: `{"server":"ssh.example.com","server_port":2222}`,
		},
		{
			name:  "trusttunnel",
			doc:   `{"type":"trusttunnel","tag":"tj","server":"tt.example.com","server_port":443,"username":"u","password":"p","health_check":true,"quic":true,"quic_congestion_control":" CUBIC ","custom_sni":"Sni.Example","client_random":"ab/ff","tls":{"enabled":true,"server_name":"sni.example.com"}}`,
			json:  `{"client_random":"ab/ff","custom_sni":"Sni.Example","health_check":true,"password":"p","quic":true,"quic_congestion_control":"cubic","server":"tt.example.com","server_port":443,"tag":"tj","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"trusttunnel","username":"u"}`,
			link:  "tt://u:p@tt.example.com:443?health_check=true&congestion_control=cubic&custom_sni=Sni.Example&client_random=ab/ff&security=tls&sni=sni.example.com#tj",
			ident: `{"server":"tt.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			nodes := importBody(t, tc.doc)
			if len(nodes) != 1 {
				t.Fatalf("got %d nodes", len(nodes))
			}
			assertS5Node(t, nodes[0], tc.json, tc.link, tc.ident)
		})
	}
}

func TestProfileExportS5New(t *testing.T) {
	cases := []struct {
		name     string
		document string
		typ      string
		json     string
		link     string
		identity string
	}{
		{
			name:     "juicity",
			document: `{"type":"juicity","tag":"je","server":"h.example.com","server_port":443,"uuid":"` + s5JuicityUUID + `","password":"p","tls":{"enabled":true,"server_name":"sni.example.com","insecure":true,"alpn":["h2"]}}`,
			typ:      "juicity",
			json:     `{"password":"p","server":"h.example.com","server_port":443,"tag":"je","tls":{"alpn":["h2"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"juicity","uuid":"` + s5JuicityUUID + `"}`,
			link:     "juicity://" + s5JuicityUUID + ":p@h.example.com:443?security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2#je",
			identity: `{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
		{
			name:     "juicity blank",
			document: `{"type":"juicity"}`,
			typ:      "juicity",
			json:     `{"type":"juicity"}`,
			link:     "juicity://:0",
			identity: `{"type":"juicity"}`,
		},
		{
			name:     "naive",
			document: `{"type":"naive","tag":"ne","server":"h.example.com","server_port":443,"username":"u","password":"p","extra_headers":{"B":"2","A":"1"},"insecure_concurrency":2,"udp_over_tcp":true,"quic":true,"quic_congestion_control":"bbr2","tls":{"enabled":true,"server_name":"sni.example.com","certificate":["C1","C2"],"certificate_path":"/p","fragment":true}}`,
			typ:      "naive",
			json:     `{"extra_headers":{"A":"1","B":"2"},"insecure_concurrency":2,"password":"p","quic":true,"quic_congestion_control":"bbr2","server":"h.example.com","server_port":443,"tag":"ne","tls":{"certificate":["C1","C2"],"certificate_path":"/p","enabled":true,"fragment":true,"server_name":"sni.example.com"},"type":"naive","udp_over_tcp":true,"username":"u"}`,
			link:     "naive+quic://u:p@h.example.com:443?sni=sni.example.com&extra-headers=A%3A1%0D%0AB%3A2&insecure-concurrency=2&uot=1&congestion_control=bbr2&tls_certificate=C1,C2&tls_certificate_path=/p&tls_fragment=true#ne",
			identity: `{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
		{
			name:     "naive blank",
			document: `{"type":"naive"}`,
			typ:      "naive",
			json:     `{"tls":{"enabled":true},"type":"naive"}`,
			link:     "naive+https://",
			identity: `{"tls":{"enabled":true},"type":"naive"}`,
		},
		{
			name:     "ssh",
			document: `{"type":"ssh","tag":"se","server":"h.example.com","server_port":2222,"user":"u","password":"p","private_key":"k","private_key_path":"/k","private_key_passphrase":"pp","host_key":["a","b"],"host_key_algorithms":["c"],"client_version":"SSH-2.0-X"}`,
			typ:      "ssh",
			json:     `{"client_version":"SSH-2.0-X","host_key":["a","b"],"host_key_algorithms":["c"],"password":"p","private_key":"k","private_key_passphrase":"pp","private_key_path":"/k","server":"h.example.com","server_port":2222,"tag":"se","type":"ssh","user":"u"}`,
			link:     "ssh://h.example.com:2222?user=u&password=p&private_key=aw&private_key_path=/k&private_key_passphrase=pp&host_key=YQ-Yg&host_key_algorithms=Yw&client_version=SSH-2.0-X#se",
			identity: `{"server":"h.example.com","server_port":2222}`,
		},
		{
			name:     "ssh blank",
			document: `{"type":"ssh"}`,
			typ:      "ssh",
			json:     `{"type":"ssh"}`,
			link:     "ssh://:0",
			identity: `{"type":"ssh"}`,
		},
		{
			name:     "trusttunnel",
			document: `{"type":"trusttunnel","tag":"te","server":"h.example.com","server_port":443,"username":"u","password":"p","health_check":true,"quic":true,"quic_congestion_control":"cubic","custom_sni":"Sni.Example","client_random":"ab/ff","tls":{"enabled":true,"server_name":"sni.example.com"}}`,
			typ:      "trusttunnel",
			json:     `{"client_random":"ab/ff","custom_sni":"Sni.Example","health_check":true,"password":"p","quic":true,"quic_congestion_control":"cubic","server":"h.example.com","server_port":443,"tag":"te","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"trusttunnel","username":"u"}`,
			link:     "tt://u:p@h.example.com:443?health_check=true&congestion_control=cubic&custom_sni=Sni.Example&client_random=ab/ff&security=tls&sni=sni.example.com#te",
			identity: `{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}`,
		},
		{
			name:     "trusttunnel blank",
			document: `{"type":"trusttunnel"}`,
			typ:      "trusttunnel",
			json:     `{"type":"trusttunnel"}`,
			link:     "tt://:0",
			identity: `{"type":"trusttunnel"}`,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			request, err := json.Marshal(map[string]any{"json": tc.document})
			if err != nil {
				t.Fatal(err)
			}
			raw, err := handleProfileExport(request)
			if err != nil {
				t.Fatalf("profileExport: %v", err)
			}
			reply, ok := raw.(profileExportReply)
			if !ok {
				t.Fatalf("reply type %T", raw)
			}
			if !reply.Supported {
				t.Fatalf("supported = false: %s", reply.Reason)
			}
			if reply.Type != tc.typ || reply.JSON != tc.json || reply.Link != tc.link || reply.Identity != tc.identity {
				t.Fatalf("reply:\n got  %+v\n want type=%s json=%s link=%s identity=%s", reply, tc.typ, tc.json, tc.link, tc.identity)
			}
			if reply.DisplayType != profileS5NewDisplayType(tc.typ) {
				t.Fatalf("displayType = %q", reply.DisplayType)
			}
		})
	}
}

func TestProfileImportS5NewClashAndRefusals(t *testing.T) {
	// Clash maps ssh only; the other three are refused with that reason.
	yaml := `proxies:
  - {name: ssh1, type: ssh, server: ssh.example.com, port: 2222, username: u, password: p, 'private-key': 'KEY', 'host-key': [' a ', '', 'b'], 'host-key-algorithms': c}
`
	nodes, err := profileImportClashBody(yaml)
	if err != nil {
		t.Fatalf("clash ssh: %v", err)
	}
	if len(nodes) != 1 || nodes[0].Type != "ssh" {
		t.Fatalf("nodes = %+v", nodes)
	}
	for _, entry := range []string{"juicity", "naive", "trusttunnel"} {
		_, err := profileImportClashBody("proxies: [{name: x, type: " + entry + ", server: s, port: 443}]")
		if err == nil || !strings.Contains(err.Error(), "has no Clash mapping") {
			t.Fatalf("%s: err = %v", entry, err)
		}
	}

	// Link-level refusals.
	for _, tc := range []struct {
		link   string
		reason string
	}{
		{"juicity://h.example.com:443", "no uuid"},
		{"juicity://not-a-uuid@h.example.com", "uuid"},
		{"juicity://" + s5JuicityUUID + "@h.example.com?security=reality", "requires pbk"},
		{"naive+quic://u:p@h.example.com?congestion_control=turbo", "quic_congestion_control"},
		{"ssh://h.example.com:2222?private_key=YWJjZGVm#x", "private_key"},
		{"tt://?c29tZXBheWxvYWQ", "deep links"},
		{"tt://user:pass@h.example.com?custom_sni=bad%20name", "custom_sni"},
	} {
		_, err := profileImportOneLink(tc.link)
		if err == nil {
			t.Fatalf("%s: want a refusal", tc.link)
		}
		if !strings.Contains(err.Error(), tc.reason) {
			t.Fatalf("%s: reason = %q, want %q", tc.link, err.Error(), tc.reason)
		}
	}

	// Stored-JSON refusals.
	for _, tc := range []struct {
		document string
		reason   string
	}{
		{`{"type":"juicity","server":"h.example.com","server_port":443,"future":1}`, "field not ported yet: future"},
		{`{"type":"juicity","server":"h.example.com","server_port":443,"tls":{"enabled":true,"future":"x"}}`, "tls field not ported yet"},
		{`{"type":"juicity","server":"h.example.com","server_port":0,"uuid":"` + s5JuicityUUID + `"}`, "no valid server_port"},
		{`{"type":"naive","server":"h.example.com","server_port":443,"quic":true,"quic_congestion_control":"reno-custom"}`, "quic_congestion_control"},
		{`{"type":"naive","server":"h.example.com","server_port":443,"extra_headers":["a"]}`, "extra_headers is not an object"},
		{`{"type":"trusttunnel","server":"h.example.com","server_port":443,"username":"u","password":"p","client_random":"abc"}`, "client_random"},
		{`{"type":"ssh","server":"h.example.com","server_port":22,"private_key":"ssh-ed25519 AAAA"}`, "private_key"},
	} {
		if _, err := profileImportStoredS5New(mustObject(t, tc.document), mustType(t, tc.document)); err == nil {
			t.Fatalf("%s: want a refusal", tc.document)
		} else if !strings.Contains(err.Error(), tc.reason) {
			t.Fatalf("%s: reason = %q, want %q", tc.document, err.Error(), tc.reason)
		}
	}
}

func TestProfileValidateS5New(t *testing.T) {
	cases := []struct {
		name    string
		doc     string
		ok      bool
		support *bool
		field   string
	}{
		{
			name: "juicity valid",
			doc:  `{"type":"juicity","server":"h.example.com","server_port":443,"uuid":"` + s5JuicityUUID + `","tls":{"enabled":true,"server_name":"sni.example.com"}}`,
			ok:   true,
		},
		{
			name:  "juicity uuid missing",
			doc:   `{"type":"juicity","server":"h.example.com","server_port":443}`,
			field: "uuid",
		},
		{
			name:  "juicity reality short id",
			doc:   `{"type":"juicity","server":"h.example.com","server_port":443,"uuid":"` + s5JuicityUUID + `","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"zz"}}}`,
			field: "tls.reality.short_id",
		},
		{
			name: "naive valid",
			doc:  `{"type":"naive","server":"h.example.com","server_port":443,"username":"u","extra_headers":{"A":"1"},"tls":{"enabled":true}}`,
			ok:   true,
		},
		{
			name:  "naive quic congestion",
			doc:   `{"type":"naive","server":"h.example.com","server_port":443,"quic":true,"quic_congestion_control":"x"}`,
			field: "quic_congestion_control",
		},
		{
			name: "ssh valid",
			doc:  `{"type":"ssh","server":"h.example.com","server_port":22,"user":"u","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----","client_version":"SSH-2.0-X"}`,
			ok:   true,
		},
		{
			name:  "ssh host key",
			doc:   `{"type":"ssh","server":"h.example.com","server_port":22,"host_key":["not a key"]}`,
			field: "host_key",
		},
		{
			name:  "trusttunnel credentials",
			doc:   `{"type":"trusttunnel","server":"h.example.com","server_port":443,"tls":{"enabled":true}}`,
			field: "username",
		},
		{
			name:  "trusttunnel unknown tls key",
			doc:   `{"type":"trusttunnel","server":"h.example.com","server_port":443,"username":"u","password":"p","tls":{"enabled":true,"future":"x"}}`,
			field: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			object, ok := configDecodeJSONObject(tc.doc)
			if !ok {
				t.Fatal("decode")
			}
			result, handled := handleProfileValidateS5New(object, configJSONString(object, "type"))
			if !handled {
				t.Fatal("not handled")
			}
			if result.Supported == nil {
				t.Fatal("supported not set")
			}
			if !*result.Supported {
				if tc.field != "" {
					t.Fatalf("want supported:true with issue %s", tc.field)
				}
				return
			}
			if result.OK != tc.ok {
				t.Fatalf("ok = %v, want %v (issues %+v)", result.OK, tc.ok, result.Issues)
			}
			if tc.field != "" {
				found := false
				for _, issue := range result.Issues {
					if issue.Field == tc.field {
						found = true
					}
				}
				if !found {
					t.Fatalf("issues %+v do not mention %s", result.Issues, tc.field)
				}
			}
			if result.Normalized == "" {
				t.Fatal("normalized is empty")
			}
		})
	}
}

// Go-only vectors: values Kotlin drops during an import (the warning path needs
// an Application, so the JVM oracle cannot pin them).
func TestProfileImportS5NewDropRules(t *testing.T) {
	// An unknown congestion-control name is dropped, so quic stays without a name.
	_, err := profileImportStoredS5New(mustObject(t, `{"type":"trusttunnel","server":"h.example.com","server_port":443,"username":"u","password":"p","quic":true,"quic_congestion_control":" turbo "}`), "trusttunnel")
	if err != nil {
		t.Fatalf("trusttunnel import: %v", err)
	}
	node, err := profileImportStoredS5New(mustObject(t, `{"type":"juicity","server":"h.example.com","server_port":443,"uuid":"`+s5JuicityUUID+`","tls":{"enabled":true,"min_version":"9.9","utls":{"enabled":true,"fingerprint":"nope"},"alpn":["h2, http/1.1"]}}`), "juicity")
	if err != nil {
		t.Fatalf("juicity import: %v", err)
	}
	if strings.Contains(node.JSON, "min_version") || strings.Contains(node.JSON, "nope") {
		t.Fatalf("import did not drop invalid TLS values: %s", node.JSON)
	}
	if !strings.Contains(node.JSON, `"alpn":["h2","http/1.1"]`) {
		t.Fatalf("alpn was not re-split: %s", node.JSON)
	}
}

// --- small test helpers -----------------------------------------------------

func mustObject(t *testing.T, document string) map[string]any {
	t.Helper()
	object, ok := configDecodeJSONObject(document)
	if !ok {
		t.Fatalf("not a JSON object: %s", document)
	}
	return object
}

func mustType(t *testing.T, document string) string {
	t.Helper()
	return configJSONString(mustObject(t, document), "type")
}
