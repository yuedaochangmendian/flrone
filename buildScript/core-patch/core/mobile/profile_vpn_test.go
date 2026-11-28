// Byte-parity tests for the OpenVPN/OpenConnect slice against the Kotlin
// oracle. Every expected string below was produced by the Kotlin models in
// app/src/test/java/io/nekohasekai/sagernet/outbound/OpenVpnGoParityTest.kt,
// which pins the same literals, so a change on either side fails here or there
// instead of drifting silently.
package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func profileExportReplyForVpn(t *testing.T, document string, name *string) profileExportReply {
	t.Helper()
	payload, err := json.Marshal(map[string]any{
		"json": document, "name": name,
	})
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	reply, err := handleProfileExport(payload)
	if err != nil {
		t.Fatalf("handleProfileExport: %v", err)
	}
	return reply.(profileExportReply)
}

type vpnExportVector struct {
	name         string
	document     string
	wantJSON     string
	wantIdentity string
	wantLink     string
}

var vpnExportVectors = []vpnExportVector{
	{
		name:         "openvpn minimal",
		document:     `{"type":"openvpn"}`,
		wantJSON:     `{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openvpn"}`,
		wantIdentity: `{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openvpn"}`,
		wantLink:     "",
	},
	{
		name: "openvpn tls block",
		document: `{"type":"openvpn","tag":"Ovpn","server":"Example.COM","server_port":1194,` +
			`"username":"alice","password":"secret","mode":"tls","network":"udp",` +
			`"tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIB","-----END CERTIFICATE-----"],` +
			`"peer_fingerprint":["AA:BB"],"server_name":"vpn.example.com","server_name_type":"name",` +
			`"version_min":"1.2","version_max":"1.3","cipher":"TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256",` +
			`"groups":"x25519:secp256r1","remote_certificate_tls":"server","remote_certificate_ku":["a0"],` +
			`"remote_certificate_eku":"server","certificate_profile":"preferred","ns_certificate_type":"server",` +
			`"crl_path":"/crl.pem","control_wrap":{"type":"tls_auth","key":["k1","k2"],"direction":"client"}}}`,
		wantJSON: `{"mode":"tls","network":"udp","only_advertised_routes":true,"password":"secret",` +
			`"server":"Example.COM","server_port":1194,"tag":"Ovpn",` +
			`"tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIB","-----END CERTIFICATE-----"],` +
			`"certificate_profile":"preferred","cipher":"TLS-ECDHE-RSA-WITH-AES-128-GCM-SHA256",` +
			`"control_wrap":{"direction":"client","key":["k1","k2"],"type":"tls_auth"},"crl_path":"/crl.pem",` +
			`"groups":"x25519:secp256r1","ns_certificate_type":"server","peer_fingerprint":["AA:BB"],` +
			`"remote_certificate_eku":"server","remote_certificate_ku":["a0"],"remote_certificate_tls":"server",` +
			`"server_name":"vpn.example.com","server_name_type":"name","version_max":"1.3","version_min":"1.2"},` +
			`"tunnel_dns":"prefer","type":"openvpn","username":"alice"}`,
		wantIdentity: `{"server":"Example.COM","server_port":1194}`,
		wantLink:     "",
	},
	{
		name: "openvpn server list",
		document: `{"type":"openvpn","servers":[{"server":"a.example.com","server_port":443,"network":"tcp"},` +
			`{"server":"b.example.com","server_port":1194}],"remote_random":true,"reuse_addr":true,"connect_timeout":"5s"}`,
		wantJSON: `{"connect_timeout":"5s","only_advertised_routes":true,"remote_random":true,"reuse_addr":true,` +
			`"servers":[{"network":"tcp","server":"a.example.com","server_port":443},` +
			`{"server":"b.example.com","server_port":1194}],"tunnel_dns":"prefer","type":"openvpn"}`,
		wantIdentity: `{"connect_timeout":"5s","only_advertised_routes":true,"remote_random":true,"reuse_addr":true,` +
			`"servers":[{"network":"tcp","server":"a.example.com","server_port":443},` +
			`{"server":"b.example.com","server_port":1194}],"tunnel_dns":"prefer","type":"openvpn"}`,
		wantLink: "reuse_addr=true&connect_timeout=5s",
	},
	{
		name: "openvpn static key",
		document: `{"type":"openvpn","mode":"static_key",` +
			`"static_key":["-----BEGIN OpenVPN Static key V1-----","0011","-----END OpenVPN Static key V1-----"],` +
			`"key_direction":"client","cipher":"AES-256-CBC","address":["10.0.0.2/24"],"peer_address":"10.0.0.1"}`,
		wantJSON: `{"address":["10.0.0.2/24"],"cipher":"AES-256-CBC","key_direction":"client","mode":"static_key",` +
			`"only_advertised_routes":true,"peer_address":"10.0.0.1",` +
			`"static_key":["-----BEGIN OpenVPN Static key V1-----","0011","-----END OpenVPN Static key V1-----"],` +
			`"tunnel_dns":"prefer","type":"openvpn"}`,
		wantIdentity: `{"address":["10.0.0.2/24"],"cipher":"AES-256-CBC","key_direction":"client","mode":"static_key",` +
			`"only_advertised_routes":true,"peer_address":"10.0.0.1",` +
			`"static_key":["-----BEGIN OpenVPN Static key V1-----","0011","-----END OpenVPN Static key V1-----"],` +
			`"tunnel_dns":"prefer","type":"openvpn"}`,
		wantLink: "",
	},
	{
		name: "openvpn routing and compression",
		document: `{"type":"openvpn","server":"h","server_port":1194,"routes":["10.0.0.0/8","2001:db8::/32"],` +
			`"route_gateway":"10.0.0.1","route_metric":5,"route_no_pull":true,` +
			`"pull_filters":[{"action":"accept","text":"dhcp-option"}],"redirect_gateway":true,` +
			`"redirect_gateway_flags":["def1","bypass-dhcp"],"block_ipv6":true,"compression":"stub",` +
			`"compression_lzo":"yes","allow_compression":"no","mss_fix":1200,"mss_fix_mode":"mtu",` +
			`"fragment":1200,"replay_window":64,"replay_window_time":"60s","ping_interval":"10s",` +
			`"ping_restart":"60s","renegotiate_interval":"3600s","renegotiate_bytes":1000,` +
			`"renegotiate_packets":100,"tls_timeout":"2s","handshake_window":"60s",` +
			`"explicit_exit_notify":1,"mtu":1400,"udp_timeout":"30s","udp_mapping":"random",` +
			`"udp_filtering":"random","udp_nat_max":100}`,
		wantJSON: `{"allow_compression":"no","block_ipv6":true,"compression":"stub","compression_lzo":"yes",` +
			`"explicit_exit_notify":1,"fragment":1200,"handshake_window":"60s","mss_fix":1200,` +
			`"mss_fix_mode":"mtu","mtu":1400,"only_advertised_routes":true,"ping_interval":"10s",` +
			`"ping_restart":"60s","pull_filters":[{"action":"accept","text":"dhcp-option"}],` +
			`"redirect_gateway":true,"redirect_gateway_flags":["def1","bypass-dhcp"],` +
			`"renegotiate_bytes":1000,"renegotiate_interval":"3600s","renegotiate_packets":100,` +
			`"replay_window":64,"replay_window_time":"60s","route_gateway":"10.0.0.1","route_metric":5,` +
			`"route_no_pull":true,"routes":["10.0.0.0/8","2001:db8::/32"],"server":"h","server_port":1194,` +
			`"tls_timeout":"2s","tunnel_dns":"prefer","type":"openvpn","udp_filtering":"random",` +
			`"udp_mapping":"random","udp_nat_max":100,"udp_timeout":"30s"}`,
		wantIdentity: `{"server":"h","server_port":1194}`,
		wantLink:     "",
	},
	{
		name: "openvpn alias and legacy keys",
		document: `{"type":"openvpn-client","server":"h","server_port":1194,"otp_profile_id":3,` +
			`"block_outside_dns":true,"system":true,"name":"tun9","auth":"SHA256","auth_retry":"interact",` +
			`"static_challenge":"OTP:","static_challenge_echo":true,"topology":"subnet",` +
			`"address":["10.0.0.2/24"],"peer_address_ipv6":"2001:db8::1",` +
			`"data_ciphers":["AES-256-GCM","CHACHA20-POLY1305"],"data_ciphers_fallback":"AES-256-CBC"}`,
		wantJSON: `{"address":["10.0.0.2/24"],"auth":"SHA256","auth_retry":"interact",` +
			`"data_ciphers":["AES-256-GCM","CHACHA20-POLY1305"],"data_ciphers_fallback":"AES-256-CBC",` +
			`"name":"tun9","only_advertised_routes":true,"otp_profile_id":3,"peer_address_ipv6":"2001:db8::1",` +
			`"server":"h","server_port":1194,"static_challenge":"OTP:","static_challenge_echo":true,` +
			`"system":true,"topology":"subnet","tunnel_dns":"strict","type":"openvpn"}`,
		wantIdentity: `{"server":"h","server_port":1194}`,
		wantLink:     "",
	},
	{
		name:         "openvpn advertised routes off",
		document:     `{"type":"openvpn","server":"h","server_port":1194,"only_advertised_routes":false,"tunnel_dns":"none"}`,
		wantJSON:     `{"only_advertised_routes":false,"server":"h","server_port":1194,"tunnel_dns":"none","type":"openvpn"}`,
		wantIdentity: `{"server":"h","server_port":1194}`,
		wantLink:     "",
	},
	{
		name:         "openconnect minimal",
		document:     `{"type":"openconnect"}`,
		wantJSON:     `{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openconnect"}`,
		wantIdentity: `{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openconnect"}`,
		wantLink:     "",
	},
	{
		name:         "openconnect server and path",
		document:     `{"type":"openconnect","server":"Example.COM","server_port":8443,"server_path":"/portal","tag":"OC"}`,
		wantJSON:     `{"only_advertised_routes":true,"server":"example.com","server_path":"/portal","server_port":8443,"tag":"OC","tunnel_dns":"prefer","type":"openconnect"}`,
		wantIdentity: `{"server":"example.com","server_port":8443}`,
		wantLink:     "",
	},
	{
		name:         "openconnect server url",
		document:     `{"type":"openconnect","server":"https://VPN.example.com:9443/group"}`,
		wantJSON:     `{"only_advertised_routes":true,"server":"vpn.example.com","server_path":"/group","server_port":9443,"tunnel_dns":"prefer","type":"openconnect"}`,
		wantIdentity: `{"server":"vpn.example.com","server_port":9443}`,
		wantLink:     "",
	},
	{
		name: "openconnect token",
		document: `{"type":"openconnect","server":"vpn.example.com","server_port":8443,` +
			`"token":{"mode":"totp","secret":"ABC","pin":"1234"},"reported_os":"linux",` +
			`"user_agent":"AnyConnect","version":"4.10","local_hostname":"host"}`,
		wantJSON: `{"local_hostname":"host","only_advertised_routes":true,"reported_os":"linux",` +
			`"server":"vpn.example.com","server_port":8443,"token":{"mode":"totp","pin":"1234","secret":"ABC"},` +
			`"tunnel_dns":"prefer","type":"openconnect","user_agent":"AnyConnect","version":"4.10"}`,
		wantIdentity: `{"server":"vpn.example.com","server_port":8443}`,
		wantLink:     "",
	},
	{
		name: "openconnect nested blocks",
		document: `{"type":"openconnect","server":"h","mobile":{"platform_version":"1","device_type":"2","device_unique_id":"3"},` +
			`"csd":{"wrapper_path":"/csd"},"hip":{"wrapper_path":"/hip"},` +
			`"tncc":{"wrapper_path":"/tncc","device_id":"d","user_agent":"ua","machine_identification_enabled":true,` +
			`"certificates":[{"certificate":["CERT"],"certificate_path":"/cert"}]},` +
			`"fortinet_host_check":{"hostcheck":"x","check_virtual_desktop":"1"}}`,
		wantJSON: `{"csd":{"wrapper_path":"/csd"},"fortinet_host_check":{"check_virtual_desktop":"1","hostcheck":"x"},` +
			`"hip":{"wrapper_path":"/hip"},"mobile":{"device_type":"2","device_unique_id":"3","platform_version":"1"},` +
			`"only_advertised_routes":true,"server":"h",` +
			`"tncc":{"certificates":[{"certificate":["CERT"],"certificate_path":"/cert"}],"device_id":"d",` +
			`"machine_identification_enabled":true,"user_agent":"ua","wrapper_path":"/tncc"},` +
			`"tunnel_dns":"prefer","type":"openconnect"}`,
		wantIdentity: `{"server":"h","server_port":0}`,
		wantLink:     "",
	},
	{
		name: "openconnect tls block",
		document: `{"type":"openconnect","server":"h","tls":{"insecure":true,"server_name":"例子.测试",` +
			`"peer_fingerprint":["sha256:AB"],"system_trust_disabled":true,` +
			`"certificate_authority":["CA"],"certificate_authority_path":"/ca",` +
			`"client_certificate":["CC"],"client_certificate_path":"/cc","client_key":["CK"],` +
			`"client_key_path":"/ck","client_key_password":"kp","mca_certificate":["MCA"],` +
			`"mca_certificate_path":"/mca","mca_key":["MK"],"mca_key_path":"/mk","mca_key_password":"mkp"}}`,
		wantJSON: `{"only_advertised_routes":true,"server":"h","tls":{"certificate_authority":["CA"],` +
			`"certificate_authority_path":"/ca","client_certificate":["CC"],"client_certificate_path":"/cc",` +
			`"client_key":["CK"],"client_key_password":"kp","client_key_path":"/ck","insecure":true,` +
			`"mca_certificate":["MCA"],"mca_certificate_path":"/mca","mca_key":["MK"],` +
			`"mca_key_password":"mkp","mca_key_path":"/mk","peer_fingerprint":["sha256:AB"],` +
			`"server_name":"xn--fsqu00a.xn--0zwm56d","system_trust_disabled":true},` +
			`"tunnel_dns":"prefer","type":"openconnect"}`,
		wantIdentity: `{"server":"h","server_port":0}`,
		wantLink:     "",
	},
	{
		name: "openconnect flags and form entries",
		document: `{"type":"openconnect","server":"h","form_entries":[{"form_id":"f","name":"n","value":"v",` +
			`"submission_key":"s","promote":true}],"no_udp":true,"dtls_local_port":1234,` +
			`"compression_disabled":true,"compression_mode":"stateless","ipv6_disabled":true,` +
			`"http_keepalive_disabled":true,"xml_post_disabled":true,"external_auth_disabled":true,` +
			`"password_authentication_disabled":true,"tcp_keep_alive_enabled":true,"pfs":true,` +
			`"mtu":1400,"base_mtu":1500,"dpd_interval":"30s","reconnect_timeout":"300s",` +
			`"trojan_interval":"10s","queue_length":5,"allow_insecure_crypto":true,"tunnel_dns":"strict",` +
			`"only_advertised_routes":false,"system":true,"name":"tun0"}`,
		wantJSON: `{"allow_insecure_crypto":true,"base_mtu":1500,"compression_disabled":true,` +
			`"compression_mode":"stateless","dpd_interval":"30s","dtls_local_port":1234,` +
			`"external_auth_disabled":true,"form_entries":[{"form_id":"f","name":"n","promote":true,` +
			`"submission_key":"s","value":"v"}],"http_keepalive_disabled":true,"ipv6_disabled":true,` +
			`"mtu":1400,"name":"tun0","no_udp":true,"only_advertised_routes":false,` +
			`"password_authentication_disabled":true,"pfs":true,"queue_length":5,` +
			`"reconnect_timeout":"300s","server":"h","system":true,"tcp_keep_alive_enabled":true,` +
			`"trojan_interval":"10s","tunnel_dns":"strict","type":"openconnect","xml_post_disabled":true}`,
		wantIdentity: `{"server":"h","server_port":0}`,
		wantLink:     "",
	},
}

func TestProfileExportVpnParity(t *testing.T) {
	for _, vector := range vpnExportVectors {
		vector := vector
		t.Run(vector.name, func(t *testing.T) {
			reply := profileExportReplyForVpn(t, vector.document, nil)
			if !reply.Supported {
				t.Fatalf("supported=false (reason %q)", reply.Reason)
			}
			if reply.JSON != vector.wantJSON {
				t.Errorf("json mismatch\n got: %s\nwant: %s", reply.JSON, vector.wantJSON)
			}
			if reply.Identity != vector.wantIdentity {
				t.Errorf("identity mismatch\n got: %s\nwant: %s", reply.Identity, vector.wantIdentity)
			}
			if reply.Link != vector.wantLink {
				t.Errorf("link mismatch\n got: %q\nwant: %q", reply.Link, vector.wantLink)
			}
			if want := "throne://add/" + profileBase64Encode([]byte(vector.wantJSON), true, false); reply.JSONLink != want {
				t.Errorf("jsonLink mismatch\n got: %s\nwant: %s", reply.JSONLink, want)
			}
			// The dedup key drops the tag, exactly like ExportJsonLink(true).
			var withoutTag map[string]any
			if err := json.Unmarshal([]byte(vector.wantJSON), &withoutTag); err != nil {
				t.Fatalf("unmarshal expected json: %v", err)
			}
			delete(withoutTag, "tag")
			dedupJSON, err := MarshalCanonicalJSON(withoutTag)
			if err != nil {
				t.Fatalf("marshal dedup json: %v", err)
			}
			if want := "throne://add/" + profileBase64Encode(dedupJSON, true, false); reply.DedupKey != want {
				t.Errorf("dedupKey mismatch\n got: %s\nwant: %s", reply.DedupKey, want)
			}
		})
	}
}

// vpnProfileVectors are the profile-file imports: the Kotlin oracle parsed the
// same text with OpenVpn.parseOvpnConfig / OpenConnect.parseOpenConnectProfile
// and exported it.
type vpnProfileVector struct {
	name         string
	text         string
	wantType     string
	wantJSON     string
	wantIdentity string
}

var vpnProfileVectors = []vpnProfileVector{
	{
		name: "openvpn profile with inline certificates",
		text: "client\ndev tun\nproto udp\nremote vpn.example.com 1194\n" +
			"<ca>\n-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n</ca>\n" +
			"<cert>\nCERT\n</cert>\n<key>\nKEY\n</key>\n" +
			"remote-cert-tls server\nauth-user-pass\n",
		wantType: "openvpn",
		wantJSON: `{"network":"udp","only_advertised_routes":true,"server":"vpn.example.com","server_port":1194,` +
			`"tag":"vpn.example.com","tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIB","-----END CERTIFICATE-----"],` +
			`"client_certificate":["CERT"],"client_key":["KEY"],"remote_certificate_tls":"server"},` +
			`"tunnel_dns":"prefer","type":"openvpn"}`,
		wantIdentity: `{"server":"vpn.example.com","server_port":1194}`,
	},
	{
		name: "openvpn profile with connection blocks",
		text: "client\ndev tun\n" +
			"<connection>\nremote a.example.com 1194 udp\n</connection>\n" +
			"<connection>\nremote b.example.com 443 tcp\nproto tcp\n</connection>\n" +
			"<tls-auth>\nSTATIC\n</tls-auth>\nkey-direction 1\n",
		wantType: "openvpn",
		wantJSON: `{"only_advertised_routes":true,"servers":[{"network":"udp","server":"a.example.com","server_port":1194},` +
			`{"network":"tcp","server":"b.example.com","server_port":443}],"tag":"a.example.com",` +
			`"tls":{"control_wrap":{"direction":"client","key":["STATIC"],"type":"tls_auth"}},` +
			`"tunnel_dns":"prefer","type":"openvpn"}`,
		wantIdentity: `{"only_advertised_routes":true,"servers":[{"network":"udp","server":"a.example.com","server_port":1194},` +
			`{"network":"tcp","server":"b.example.com","server_port":443}],"tag":"a.example.com",` +
			`"tls":{"control_wrap":{"direction":"client","key":["STATIC"],"type":"tls_auth"}},` +
			`"tunnel_dns":"prefer","type":"openvpn"}`,
	},
	{
		name: "openvpn profile with routes",
		text: "client\ndev tun\nproto tcp\nremote h.example.com 443 tcp\n" +
			"route 10.0.0.0 255.0.0.0\nroute 192.168.1.0/24\nroute-ipv6 2001:db8::/32\n" +
			"route-gateway 10.0.0.1\nroute-metric 5\n",
		wantType: "openvpn",
		wantJSON: `{"network":"tcp","only_advertised_routes":true,"route_gateway":"10.0.0.1","route_metric":5,` +
			`"routes":["10.0.0.0/8","192.168.1.0/24","2001:db8::/32"],"server":"h.example.com",` +
			`"server_port":443,"tag":"h.example.com","tunnel_dns":"prefer","type":"openvpn"}`,
		wantIdentity: `{"server":"h.example.com","server_port":443}`,
	},
	{
		name:     "openconnect command line",
		text:     "openconnect --protocol=anyconnect --user=alice --server=vpn.example.com:8443/portal --authgroup=Staff --no-dtls",
		wantType: "openconnect",
		wantJSON: `{"auth_group":"Staff","flavor":"anyconnect","no_udp":true,"only_advertised_routes":true,` +
			`"server":"vpn.example.com","server_path":"/portal","server_port":8443,"tag":"vpn.example.com",` +
			`"tunnel_dns":"prefer","type":"openconnect","username":"alice"}`,
		wantIdentity: `{"server":"vpn.example.com","server_port":8443}`,
	},
	{
		name: "openconnect config file",
		text: "protocol=anyconnect\nserver=vpn.example.com/portal\nuser=alice\nauthgroup=Staff\n" +
			"certificate=/tmp/cert.pem\nsslkey=/tmp/key.pem\ncafile=/tmp/ca.pem\n",
		wantType: "openconnect",
		wantJSON: `{"auth_group":"Staff","flavor":"anyconnect","only_advertised_routes":true,` +
			`"server":"vpn.example.com","server_path":"/portal","tag":"vpn.example.com",` +
			`"tls":{"certificate_authority_path":"/tmp/ca.pem","client_certificate_path":"/tmp/cert.pem",` +
			`"client_key_path":"/tmp/key.pem"},"tunnel_dns":"prefer","type":"openconnect","username":"alice"}`,
		wantIdentity: `{"server":"vpn.example.com","server_port":0}`,
	},
	{
		name: "openconnect form entry and token",
		text: "openconnect vpn.example.com --protocol=anyconnect --form-entry=all:pin=1234 " +
			"--token-mode=totp --token-secret=ABC --os=android --compression=all " +
			"--reconnect-timeout=60 --queue-len=3",
		wantType: "openconnect",
		wantJSON: `{"compression_mode":"all","flavor":"anyconnect","form_entries":[{"form_id":"all","name":"pin","value":"1234"}],` +
			`"only_advertised_routes":true,"queue_length":3,"reconnect_timeout":"60s","reported_os":"android",` +
			`"server":"vpn.example.com","tag":"vpn.example.com","token":{"mode":"totp","secret":"ABC"},` +
			`"tunnel_dns":"prefer","type":"openconnect"}`,
		wantIdentity: `{"server":"vpn.example.com","server_port":0}`,
	},
}

func TestProfileImportVpnProfileParity(t *testing.T) {
	for _, vector := range vpnProfileVectors {
		vector := vector
		t.Run(vector.name, func(t *testing.T) {
			nodes, handled, err := profileImportVpnFileBody(vector.text)
			if !handled {
				t.Fatalf("the body detector did not recognise the profile")
			}
			if err != nil {
				t.Fatalf("import refused: %v", err)
			}
			if len(nodes) != 1 {
				t.Fatalf("got %d nodes, want 1", len(nodes))
			}
			node := nodes[0]
			if node.Type != vector.wantType {
				t.Errorf("type = %q, want %q", node.Type, vector.wantType)
			}
			if node.JSON != vector.wantJSON {
				t.Errorf("json mismatch\n got: %s\nwant: %s", node.JSON, vector.wantJSON)
			}
			if node.Identity != vector.wantIdentity {
				t.Errorf("identity mismatch\n got: %s\nwant: %s", node.Identity, vector.wantIdentity)
			}
		})
	}
}

func TestProfileImportVpnDetectors(t *testing.T) {
	if !profileLooksLikeOVPNConfig("client\ndev tun\nremote a 1194\n") {
		t.Error("a client profile with remote was not detected")
	}
	if profileLooksLikeOVPNConfig("remote a 1194\n") {
		t.Error("a profile without a client marker was detected")
	}
	if !profileLooksLikeOpenConnectProfile("openconnect vpn.example.com") {
		t.Error("a command line was not detected")
	}
	if !profileLooksLikeOpenConnectProfile("protocol=anyconnect\nserver=vpn.example.com\n") {
		t.Error("a config file was not detected")
	}
	if !profileLooksLikeOpenConnectProfile("<AnyConnectProfile><ServerList></ServerList></AnyConnectProfile>") {
		t.Error("an AnyConnect XML profile was not detected")
	}
	if profileLooksLikeOpenConnectProfile("protocol=wireguard\n") {
		t.Error("a non-AnyConnect protocol line was detected")
	}
}

func TestProfileImportVpnRefusals(t *testing.T) {
	cases := map[string]string{
		"a server configuration":               "client\ndev tun\nremote a 1194\nserver 10.8.0.0 255.255.255.0\n",
		"TAP mode":                             "client\ndev tap0\nproto udp\nremote a 1194\n",
		"a PKCS#12 bundle":                     "client\ndev tun\nproto udp\nremote a 1194\npkcs12 bundle.p12\n",
		"a client certificate without its key": "client\ndev tun\nproto udp\nremote a 1194\n<ca>\nCA\n</ca>\n<cert>\nCERT\n</cert>\n",
		"has no remote server":                 "client\ndev tun\nproto udp\n<ca>\nCA\n</ca>\n",
	}
	for want, text := range cases {
		_, handled, err := profileImportVpnFileBody(text)
		if !handled {
			t.Errorf("%q: not detected at all", want)
			continue
		}
		if err == nil {
			t.Errorf("%q: expected a refusal", want)
			continue
		}
		refused, ok := profileNewRefusal(err)
		if !ok {
			t.Errorf("%q: refusal is not an unsupported value: %v", want, err)
			continue
		}
		if !strings.Contains(refused.Reason, want) {
			t.Errorf("%q: refusal reason %q does not name the problem", want, refused.Reason)
		}
	}
}

func TestProfileImportVpnEmptyProfile(t *testing.T) {
	if _, err := profileImportOpenConnectFileBody("   \n"); err == nil {
		t.Fatal("an empty OpenConnect profile should be refused")
	}
	model := newProfileOpenVPN()
	if profileOpenVPNParseConfig(model, "   \n", nil) {
		t.Fatal("an empty OpenVPN profile should be refused")
	}
}

// TestProfileParseVpnStaticKeyProfile pins a `.ovpn` static-key profile the body
// detector does not classify (it has no client marker, exactly as in Kotlin):
// the parser is what has to reproduce the oracle.
func TestProfileParseVpnStaticKeyProfile(t *testing.T) {
	model := newProfileOpenVPN()
	if !profileOpenVPNParseConfig(model, "secret static.key 1\nifconfig 10.0.0.2 10.0.0.1\nremote 10.9.9.9\ncipher AES-256-CBC\n", nil) {
		t.Fatal("the static-key profile was refused")
	}
	stored, err := MarshalCanonicalJSON(profileOpenVPNExportJSON(model))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	want := `{"address":["10.0.0.2/32"],"cipher":"AES-256-CBC","key_direction":"client","mode":"static_key",` +
		`"only_advertised_routes":true,"peer_address":"10.0.0.1","server":"10.9.9.9","server_port":1194,` +
		`"static_key_path":"static.key","tag":"10.9.9.9","tunnel_dns":"prefer","type":"openvpn"}`
	if string(stored) != want {
		t.Errorf("json mismatch\n got: %s\nwant: %s", stored, want)
	}
}

func TestProfileImportStoredVpn(t *testing.T) {
	body := `[{"type":"openvpn","server":"h.example.com","server_port":1194},` +
		`{"type":"openconnect","server":"oc.example.com","server_port":8443,"server_path":"/p"}]`
	nodes, err := profileImportBody(body)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(nodes) != 2 {
		t.Fatalf("got %d nodes, want 2", len(nodes))
	}
	if nodes[0].Type != "openvpn" || nodes[1].Type != "openconnect" {
		t.Errorf("types = %q/%q", nodes[0].Type, nodes[1].Type)
	}
	if nodes[0].JSON != `{"only_advertised_routes":true,"server":"h.example.com","server_port":1194,"tunnel_dns":"prefer","type":"openvpn"}` {
		t.Errorf("openvpn json = %s", nodes[0].JSON)
	}
	if nodes[1].JSON != `{"only_advertised_routes":true,"server":"oc.example.com","server_path":"/p","server_port":8443,"tunnel_dns":"prefer","type":"openconnect"}` {
		t.Errorf("openconnect json = %s", nodes[1].JSON)
	}
}

func TestProfileValidateVpnChecks(t *testing.T) {
	validate := func(document string) profileValidateResult {
		t.Helper()
		payload, err := json.Marshal(map[string]any{"json": document, "format": "stored"})
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		answer, err := handleProfileValidate(payload)
		if err != nil {
			t.Fatalf("profile.validate: %v", err)
		}
		return answer.(profileValidateResult)
	}
	hasIssue := func(result profileValidateResult, field, fragment string) bool {
		for _, issue := range result.Issues {
			if issue.Field == field && strings.Contains(issue.Message, fragment) {
				return true
			}
		}
		return false
	}

	// A TLS-mode profile that also carries a static-key-only field.
	result := validate(`{"type":"openvpn","server":"h","server_port":1194,"mode":"tls",` +
		`"tls":{"certificate":["CA"]},"key_direction":"client","cipher":"AES-256-CBC"}`)
	if result.OK {
		t.Error("key_direction and cipher are static-key only")
	}
	if !hasIssue(result, "key_direction", "only used in static-key mode") {
		t.Errorf("key_direction issue missing: %v", result.Issues)
	}
	if !hasIssue(result, "cipher", "only used in static-key mode") {
		t.Errorf("cipher issue missing: %v", result.Issues)
	}

	// Static-key mode refuses the TLS and authentication fields.
	result = validate(`{"type":"openvpn","mode":"static_key","static_key":["K"],"cipher":"AES-256-CBC",` +
		`"address":["10.0.0.2/24"],"peer_address":"10.0.0.1","server":"10.9.9.9","server_port":1194,` +
		`"username":"u","tls":{"server_name":"sni","control_wrap":{"type":"tls_auth","key":["K"]}}}`)
	if result.OK {
		t.Error("a static-key profile must refuse username and tls fields")
	}
	if !hasIssue(result, "username", "not used in static-key mode") {
		t.Errorf("username issue missing: %v", result.Issues)
	}
	if !hasIssue(result, "tls.control_wrap", "not used in static-key mode") {
		t.Errorf("control_wrap issue missing: %v", result.Issues)
	}

	// A control-channel direction only belongs on tls-auth.
	result = validate(`{"type":"openvpn","server":"h","server_port":1194,"tls":{"certificate":["CA"],` +
		`"control_wrap":{"type":"tls_crypt","key":["K"],"direction":"client"}}}`)
	if !hasIssue(result, "tls.control_wrap.direction", "only tls-auth") {
		t.Errorf("direction issue missing: %v", result.Issues)
	}

	// Routes are CIDR prefixes; a bare IP is not one.
	result = validate(`{"type":"openvpn","server":"h","server_port":1194,"tls":{"certificate":["CA"]},"routes":["10.0.0.1"]}`)
	if !hasIssue(result, "routes", "CIDR") {
		t.Errorf("route issue missing: %v", result.Issues)
	}

	// version_max below version_min.
	result = validate(`{"type":"openvpn","server":"h","server_port":1194,"tls":{"certificate":["CA"],` +
		`"version_min":"1.3","version_max":"1.2"}}`)
	if !hasIssue(result, "tls.version_max", "must not be lower") {
		t.Errorf("version issue missing: %v", result.Issues)
	}

	// mss_fix_disabled together with a value.
	result = validate(`{"type":"openvpn","server":"h","server_port":1194,"tls":{"certificate":["CA"]},` +
		`"mss_fix_disabled":true,"mss_fix":1200}`)
	if !hasIssue(result, "mss_fix", "mss_fix_disabled") {
		t.Errorf("mss_fix issue missing: %v", result.Issues)
	}

	// A valid TLS profile passes with no issues at all.
	result = validate(`{"type":"openvpn","server":"h","server_port":1194,"mode":"tls",` +
		`"tls":{"certificate":["CA"],"remote_certificate_tls":"server"}}`)
	if !result.OK || len(result.Issues) != 0 {
		t.Errorf("a valid TLS profile produced %v", result.Issues)
	}

	// OpenConnect server paths must not carry a query.
	result = validate(`{"type":"openconnect","server":"h","server_path":"/portal?x=1"}`)
	if !hasIssue(result, "server_path", "query") {
		t.Errorf("server_path issue missing: %v", result.Issues)
	}
	// Peer fingerprints are checked by the core's own rules.
	result = validate(`{"type":"openconnect","server":"h","tls":{"peer_fingerprint":["nonsense"]}}`)
	if !hasIssue(result, "tls.peer_fingerprint", "hex digits") {
		t.Errorf("fingerprint issue missing: %v", result.Issues)
	}
	// A form entry needs a submission key or both form_id and name.
	result = validate(`{"type":"openconnect","server":"h","form_entries":[{"form_id":"f","value":"v"}]}`)
	if !hasIssue(result, "form_entries[0]", "submission_key") {
		t.Errorf("form entry issue missing: %v", result.Issues)
	}
	// compression_mode=all with compression disabled.
	result = validate(`{"type":"openconnect","server":"h","compression_disabled":true,"compression_mode":"all"}`)
	if !hasIssue(result, "compression_mode", "compression") {
		t.Errorf("compression issue missing: %v", result.Issues)
	}
}

func TestProfileImportVpnLinkAndClashRefusals(t *testing.T) {
	// Neither type is in OutboundFactory's scheme table, so a scheme of either
	// name is refused by the single-link path.
	for _, text := range []string{"openvpn://vpn.example.com:1194", "openconnect://vpn.example.com"} {
		if _, err := profileImportBody(text); err == nil {
			t.Errorf("%s: expected a refusal", text)
		}
	}
	// A Clash entry of either type has no Kotlin mapping; the body is refused
	// whole with that reason instead of being half-mapped.
	for _, proxyType := range []string{"openvpn", "openconnect"} {
		document := "proxies:\n  - name: a\n    type: " + proxyType + "\n    server: h\n    port: 1194\n"
		if _, err := profileImportBody(document); err == nil {
			t.Errorf("clash %s: expected a refusal", proxyType)
		} else if !strings.Contains(err.Error(), "no Clash mapping in Kotlin") {
			t.Errorf("clash %s: reason %q does not name the missing mapping", proxyType, err.Error())
		}
	}
}

// TestProfileImportVpnAnyConnectXML pins the XML branch, which the JVM oracle
// cannot cover (XmlPullParserFactory is not mocked there). The expectations
// follow vpnfiApplyHostEntry: the IPsec entry is refused, and a UserGroup
// overrides the URL path whichever came first.
func TestProfileImportVpnAnyConnectXML(t *testing.T) {
	profile := `<?xml version="1.0" encoding="UTF-8"?>
<AnyConnectProfile><ServerList>
<HostEntry><HostName>vpn1</HostName><HostAddress>vpn1.example.com</HostAddress><UserGroup>Staff</UserGroup><PrimaryProtocol>IPsec</PrimaryProtocol></HostEntry>
<HostEntry><HostName>vpn2</HostName><HostAddress>vpn2.example.com:8443/portal</HostAddress><UserGroup>Students</UserGroup><PrimaryProtocol>SSL</PrimaryProtocol><CertificateHash>sha256:AB</CertificateHash></HostEntry>
</ServerList></AnyConnectProfile>`
	nodes, err := profileImportOpenConnectFileBody(profile)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	if len(nodes) != 1 {
		t.Fatalf("got %d nodes, want 1 (the IPsec entry is refused)", len(nodes))
	}
	want := `{"flavor":"anyconnect","only_advertised_routes":true,"server":"vpn2.example.com",` +
		`"server_path":"Students","server_port":8443,"tag":"vpn2","tls":{"peer_fingerprint":["sha256:AB"]},` +
		`"tunnel_dns":"prefer","type":"openconnect"}`
	if nodes[0].JSON != want {
		t.Errorf("json mismatch\n got: %s\nwant: %s", nodes[0].JSON, want)
	}

	// Two entries yield two profiles: an entry without HostAddress falls back to
	// its HostName as the address, exactly like vpnfiApplyHostEntry.
	multi := `<?xml version="1.0" encoding="UTF-8"?>
<AnyConnectProfile><ServerList>
<HostEntry><HostName>a</HostName><HostAddress>a.example.com</HostAddress></HostEntry>
<HostEntry><HostName>b.example.com</HostName></HostEntry>
</ServerList></AnyConnectProfile>`
	nodes, err = profileImportOpenConnectFileBody(multi)
	if err != nil {
		t.Fatalf("multi import: %v", err)
	}
	if len(nodes) != 2 || nodes[0].Name != "a" || nodes[1].Name != "b.example.com" {
		t.Fatalf("got %d nodes (%q/%q), want a and b.example.com", len(nodes), nodes[0].Name, nodes[len(nodes)-1].Name)
	}

	// A DTD is refused before any entity is resolved.
	withDTD := `<?xml version="1.0"?><!DOCTYPE foo [<!ENTITY x "y">]>` +
		`<AnyConnectProfile><ServerList><HostEntry><HostAddress>a.example.com</HostAddress></HostEntry></ServerList></AnyConnectProfile>`
	if _, err := profileImportOpenConnectFileBody(withDTD); err == nil {
		t.Error("a profile with a DTD should be refused")
	}
}

func TestProfileImportVpnImportDrops(t *testing.T) {
	// Values Kotlin's import drops (an unsupported data cipher, an unreadable
	// route, a sub-68 fragment, a sub-second ping interval) never reach the
	// stored form; `cipher` itself is read verbatim by the Kotlin parser.
	body := `{"type":"openvpn","server":"h","server_port":1194,"cipher":"NOT-A-CIPHER",` +
		`"data_ciphers":["AES-256-GCM","BOGUS"],"routes":["nonsense"],` +
		`"ping_interval":"500ms","fragment":10,"tunnel_dns":"prefer"}`
	nodes, err := profileImportBody(body)
	if err != nil {
		t.Fatalf("import: %v", err)
	}
	want := `{"cipher":"NOT-A-CIPHER","data_ciphers":["AES-256-GCM"],"only_advertised_routes":true,"server":"h","server_port":1194,"tunnel_dns":"prefer","type":"openvpn"}`
	if nodes[0].JSON != want {
		t.Errorf("json mismatch\n got: %s\nwant: %s", nodes[0].JSON, want)
	}
}

func TestProfileExportVpnRefusals(t *testing.T) {
	cases := map[string]string{
		"unmodeled field":    `{"type":"openvpn","server":"h","server_port":1194,"bogus_field":1}`,
		"unmodeled tls":      `{"type":"openvpn","server":"h","server_port":1194,"tls":{"bogus":1}}`,
		"non-string":         `{"type":"openvpn","server":42,"server_port":1194}`,
		"unmodeled oc field": `{"type":"openconnect","server":"h","bogus":true}`,
		"oc non-object tls":  `{"type":"openconnect","server":"h","tls":"x"}`,
	}
	for name, document := range cases {
		reply := profileExportReplyForVpn(t, document, nil)
		if reply.Supported {
			t.Errorf("%s: answered supported:true", name)
		}
		if reply.Reason == "" {
			t.Errorf("%s: no reason", name)
		}
	}
}

func TestProfileValidateVpnStored(t *testing.T) {
	validate := func(document string) profileValidateResult {
		t.Helper()
		payload, err := json.Marshal(map[string]any{"json": document, "format": "stored"})
		if err != nil {
			t.Fatalf("marshal: %v", err)
		}
		answer, err := handleProfileValidate(payload)
		if err != nil {
			t.Fatalf("profile.validate: %v", err)
		}
		return answer.(profileValidateResult)
	}

	// A TLS profile without a CA or a peer fingerprint: the Kotlin check refuses it.
	result := validate(`{"type":"openvpn","server":"h","server_port":1194,"mode":"tls"}`)
	if result.Supported == nil || !*result.Supported {
		t.Fatalf("supported = %v, want true", result.Supported)
	}
	if result.OK {
		t.Error("a TLS profile without tls.certificate should not pass")
	}
	if !strings.Contains(result.Issues[0].Message, "CA certificate") {
		t.Errorf("first issue = %q, want the TLS verification message", result.Issues[0].Message)
	}

	// Static-key mode needs the secret, the cipher and the addresses.
	result = validate(`{"type":"openvpn","server":"h","server_port":1194,"mode":"static_key"}`)
	if result.OK {
		t.Error("an empty static-key profile should not pass")
	}

	// A valid static-key profile passes and keeps its canonical form.
	result = validate(`{"type":"openvpn","mode":"static_key","static_key":["K"],"cipher":"AES-256-CBC",` +
		`"address":["10.0.0.2/24"],"peer_address":"10.0.0.1","server":"10.9.9.9","server_port":1194}`)
	if !result.OK {
		t.Errorf("a valid static-key profile failed: %v", result.Issues)
	}
	if result.Normalized == "" {
		t.Error("no normalized document")
	}

	// OpenConnect: server is required, the port is optional.
	result = validate(`{"type":"openconnect"}`)
	if result.OK {
		t.Error("an OpenConnect profile without a server should not pass")
	}
	result = validate(`{"type":"openconnect","server":"vpn.example.com","tls":{"client_certificate":["C"]}}`)
	if result.OK {
		t.Error("a certificate without its key should not pass")
	}
	result = validate(`{"type":"openconnect","server":"vpn.example.com","mobile":{"device_type":"2"}}`)
	if result.OK {
		t.Error("a partial mobile block should not pass")
	}
	result = validate(`{"type":"openconnect","server":"vpn.example.com","token":{"mode":"hotp","secret":"S","counter":5}}`)
	if !result.OK {
		t.Errorf("a valid hotp token failed: %v", result.Issues)
	}
	// Warnings do not block saving: a sub-576 MTU is raised by the core.
	result = validate(`{"type":"openconnect","server":"vpn.example.com","mtu":500}`)
	if !result.OK {
		t.Errorf("an MTU warning should not block saving: %v", result.Issues)
	}
	if len(result.Issues) != 1 || result.Issues[0].Severity != profileSeverityWarning {
		t.Errorf("issues = %v, want one warning", result.Issues)
	}

	// An unmodelled field answers supported:false and no verdict.
	result = validate(`{"type":"openvpn","server":"h","server_port":1194,"bogus":1}`)
	if result.Supported == nil || *result.Supported {
		t.Errorf("supported = %v, want false", result.Supported)
	}
	if result.OK {
		t.Error("an unsupported document must not be ok")
	}
}
