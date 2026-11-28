package mobile

import (
	stdjson "encoding/json"
	"strings"
	"testing"
)

func normalizeStoredProfileDocument(t *testing.T, document string) profileStoredNormalizeResult {
	t.Helper()
	format := profileFormatStored
	payload, err := stdjson.Marshal(profileDocumentRequest{JSON: &document, Format: &format})
	if err != nil {
		t.Fatalf("encode payload: %v", err)
	}
	answer, err := handleProfileNormalize(payload)
	if err != nil {
		t.Fatalf("handleProfileNormalize(stored): %v", err)
	}
	result, ok := answer.(profileStoredNormalizeResult)
	if !ok {
		t.Fatalf("handleProfileNormalize answered %T, want profileStoredNormalizeResult", answer)
	}
	return result
}

// TestProfileNormalizeStoredCanonicalForms pins the canonical stored bytes per
// type. Every expected string is the Kotlin oracle's
// Outbound.parseFromJson -> exportToJson().toCompact() output for the same
// document (ProfileStoredGoParityTest pins the literals against the running
// model), so a Go-side normalisation change fails here before it can rewrite a
// stored row.
func TestProfileNormalizeStoredCanonicalForms(t *testing.T) {
	tests := []struct {
		name     string
		document string
		want     string
	}{
		{
			name:     "direct drops the endpoint and trims the dial fields",
			document: `{"type":"direct","tag":"D","reuse_addr":true,"connect_timeout":" 5s ","server":"ignored","server_port":1}`,
			want:     `{"connect_timeout":"5s","reuse_addr":true,"tag":"D","type":"direct"}`,
		},
		{
			name: "http keeps tls and reads non-string headers as empty",
			document: `{"type":"http","server":"Example.COM","server_port":8080,"username":"u",` +
				`"password":"p","path":"/x","headers":{"B":"2","A":1},` +
				`"tls":{"enabled":true,"server_name":"example.com"}}`,
			want: `{"headers":{"A":"","B":"2"},"password":"p","path":"/x","server":"Example.COM",` +
				`"server_port":8080,"tls":{"enabled":true,"server_name":"example.com"},"type":"http","username":"u"}`,
		},
		{
			name:     "socks version and uot",
			document: `{"type":"socks","server":"h","server_port":1080,"version":4,"udp_over_tcp":{"enabled":true}}`,
			want:     `{"server":"h","server_port":1080,"type":"socks","uot":true,"version":"4"}`,
		},
		{
			name: "shadowsocks keeps a disabled multiplex block",
			document: `{"type":"shadowsocks","server":"Host.example","server_port":8388,` +
				`"method":"aes-256-gcm","password":"secret","multiplex":{"enabled":false}}`,
			want: `{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"secret",` +
				`"server":"Host.example","server_port":8388,"type":"shadowsocks"}`,
		},
		{
			name: "vless fills the model defaults",
			document: `{"type":"vless","server":"Vless.Example","server_port":443,"uuid":"u",` +
				`"encryption":"","tls":{"enabled":true,"server_name":"Sni.Example"}}`,
			want: `{"encryption":"none","packet_encoding":"xudp","server":"Vless.Example",` +
				`"server_port":443,"tls":{"enabled":true,"server_name":"Sni.Example"},"type":"vless","uuid":"u"}`,
		},
		{
			name:     "vmess kebab-case aliases win",
			document: `{"type":"vmess","server":"h","server_port":443,"uuid":"u","alter-id":4,"global-padding":true}`,
			want:     `{"alter_id":4,"global_padding":true,"packet_encoding":"xudp","server":"h","server_port":443,"type":"vmess","uuid":"u"}`,
		},
		{
			name: "wireguard fixes the address and decodes reserved",
			document: `{"type":"wireguard","private_key":"` + wgPrivateKey + `","address":"10.0.0.2",` +
				`"peers":[{"address":"P.example.com","port":51820,"public_key":"` + wgPublicKey + `","reserved":"AQID"}],"worker_count":2}`,
			want: `{"address":["10.0.0.2/32"],"mtu":1420,"peers":[{"address":"P.example.com","port":51820,` +
				`"public_key":"` + wgPublicKey + `","reserved":[1,2,3]}],"private_key":"` + wgPrivateKey + `",` +
				`"type":"wireguard","worker_count":2}`,
		},
		{
			name:     "masque fills the endpoint defaults and clears an absent sni",
			document: `{"type":"masque","server":"M.example.com","private_key":"` + wgPrivateKey + `","address":"172.16.0.2","tls":{"enabled":true}}`,
			want: `{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"` + wgPrivateKey + `","server":"M.example.com",` +
				`"server_port":443,"tls":{"enabled":true},"type":"masque"}`,
		},
		{
			name:     "trojan keeps a disabled tls block out",
			document: `{"type":"trojan","server":"h","server_port":443,"password":"p","tls":{"enabled":false}}`,
			want:     `{"password":"p","server":"h","server_port":443,"type":"trojan"}`,
		},
		{
			name:     "hysteria always writes its tls key",
			document: `{"tls":{},"type":"hysteria"}`,
			want:     `{"tls":{},"type":"hysteria"}`,
		},
		{
			name:     "hysteria2 disabled tls canonicalises to an empty block",
			document: `{"type":"hysteria2","server":"h","server_port":443,"password":"p","tls":{"enabled":false}}`,
			want:     `{"password":"p","server":"h","server_port":443,"tls":{},"type":"hysteria2"}`,
		},
		{
			name: "tuic canonicalises congestion and relay mode",
			document: `{"type":"tuic","server":"h","server_port":443,"uuid":"u",` +
				`"congestion_control":" BBR ","udp_relay_mode":"NATIVE","heartbeat":" 5s ","idle_timeout":"30s"}`,
			want: `{"congestion_control":"bbr","heartbeat":"5s","idle_timeout":"30s","server":"h",` +
				`"server_port":443,"type":"tuic","udp_relay_mode":"native","uuid":"u"}`,
		},
		{
			name:     "juicity writes tls only when enabled",
			document: `{"type":"juicity","server":"h","server_port":443,"uuid":"u","password":"p","tls":{"enabled":true}}`,
			want:     `{"password":"p","server":"h","server_port":443,"tls":{"enabled":true},"type":"juicity","uuid":"u"}`,
		},
		{
			name:     "anytls always writes tls and the idle defaults",
			document: `{"type":"anytls","server":"h","server_port":443,"password":"p"}`,
			want:     `{"idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"password":"p","server":"h","server_port":443,"tls":{},"type":"anytls"}`,
		},
		{
			name:     "shadowtls reads a string version as a number",
			document: `{"type":"shadowtls","server":"h","server_port":443,"version":"3","password":"p","tls":{"enabled":true,"server_name":"s"}}`,
			want:     `{"password":"p","server":"h","server_port":443,"tls":{"enabled":true,"server_name":"s"},"type":"shadowtls","version":3}`,
		},
		{
			name:     "snell v6 writes mode instead of obfs fields",
			document: `{"type":"snell","server":"h","server_port":443,"version":6,"psk":"p","mode":"unsafe","obfs_mode":"http"}`,
			want:     `{"mode":"unsafe","psk":"p","server":"h","server_port":443,"type":"snell","version":6}`,
		},
		{
			name:     "mieru keeps transport text and splits server ports",
			document: `{"type":"mieru","server":"h","server_port":443,"transport":" udp ","server_ports":"9000-9999, 8000","username":"u"}`,
			want:     `{"server":"h","server_port":443,"server_ports":["9000-9999","8000"],"transport":" udp ","type":"mieru","username":"u"}`,
		},
		{
			name:     "trusttunnel canonicalises congestion and ACEs the sni",
			document: `{"type":"trusttunnel","server":"h","server_port":443,"quic":true,"quic_congestion_control":" BBR ","custom_sni":"Sni.Example"}`,
			want:     `{"custom_sni":"Sni.Example","quic":true,"quic_congestion_control":"bbr","server":"h","server_port":443,"type":"trusttunnel"}`,
		},
		{
			name:     "ssh joins private keys and drops blank host keys",
			document: `{"type":"ssh","server":"h","server_port":22,"user":"u","private_key":["line1","line2"],"host_key":[" a ","","b"]}`,
			want:     `{"host_key":["a","b"],"private_key":"line1\nline2","server":"h","server_port":22,"type":"ssh","user":"u"}`,
		},
		{
			name: "naive keeps only its TLS subset",
			document: `{"type":"naive","server":"h","server_port":443,"username":"u",` +
				`"extra_headers":{"B":["x"],"A":"y"},"udp_over_tcp":{"enabled":true},` +
				`"tls":{"enabled":false,"server_name":"S","alpn":["h2"],"fragment":false}}`,
			want: `{"extra_headers":{"A":"y","B":"x"},"server":"h","server_port":443,` +
				`"tls":{"enabled":true,"fragment":false,"server_name":"S"},"type":"naive",` +
				`"udp_over_tcp":true,"username":"u"}`,
		},
		{
			name:     "custom trims the subtype only",
			document: `{"type":"custom","name":" n ","subtype":" outbound ","config":"{}"}`,
			want:     `{"config":"{}","name":" n ","subtype":"outbound","type":"custom"}`,
		},
		{
			name:     "chain reads integer ids",
			document: `{"type":"chain","name":"c","list":[3,1.0,"x"]}`,
			want:     `{"list":[3,1,0],"name":"c","type":"chain"}`,
		},
		{
			name:     "vmess security auto is the model default and is omitted",
			document: `{"type":"vmess","server":"h","server_port":443,"security":"auto","packet_encoding":""}`,
			want:     `{"packet_encoding":"","server":"h","server_port":443,"type":"vmess"}`,
		},
		{
			name:     "vmess explicit empty security is written",
			document: `{"type":"vmess","server":"h","server_port":443,"security":"","packet_encoding":"xudp"}`,
			want:     `{"packet_encoding":"xudp","security":"","server":"h","server_port":443,"type":"vmess"}`,
		},
		{
			name:     "hysteria2 drops an obfs object without a password",
			document: `{"type":"hysteria2","server":"h","server_port":443,"obfs":{"type":" GECKO ","password":""},"tls":{"enabled":true}}`,
			want:     `{"server":"h","server_port":443,"tls":{"enabled":true},"type":"hysteria2"}`,
		},
		{
			name:     "hysteria2 lower-cases the obfs type",
			document: `{"type":"hysteria2","server":"h","server_port":443,"obfs":{"type":" GECKO ","password":"p","min_packet_size":512},"tls":{"enabled":true}}`,
			want:     `{"obfs":{"max_packet_size":0,"min_packet_size":512,"password":"p","type":"gecko"},"server":"h","server_port":443,"tls":{"enabled":true},"type":"hysteria2"}`,
		},
		{
			name:     "hysteria v1 auth_str wins over auth",
			document: `{"type":"hysteria","server":"h","server_port":443,"auth":"base64","auth_str":"string","tls":{"enabled":true}}`,
			want:     `{"auth_str":"string","server":"h","server_port":443,"tls":{"enabled":true},"type":"hysteria"}`,
		},
		{
			name:     "naive drops blank certificate lines",
			document: `{"type":"naive","server":"h","server_port":443,"tls":{"certificate":["A","","B "]}}`,
			want:     `{"server":"h","server_port":443,"tls":{"certificate":["A","B "],"enabled":true},"type":"naive"}`,
		},
		{
			name: "tls keeps min/max, splits PEM lines and drops a lone spoof method",
			document: `{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none",` +
				`"packet_encoding":"xudp","tls":{"enabled":true,"min_version":" 1.2 ","max_version":" 1.3 ",` +
				`"certificate":["-----BEGIN CERTIFICATE-----","","abc","-----END CERTIFICATE-----"],` +
				`"spoof_method":" word ","fragment_fallback_delay":" 100ms "}}`,
			want: `{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,` +
				`"tls":{"certificate":["-----BEGIN CERTIFICATE-----","abc","-----END CERTIFICATE-----"],` +
				`"enabled":true,"fragment_fallback_delay":"100ms","max_version":"1.3","min_version":"1.2"},` +
				`"type":"vless","uuid":"u"}`,
		},
		{
			name: "ech wraps a bare base64 config list",
			document: `{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none",` +
				`"packet_encoding":"xudp","tls":{"enabled":true,"ech":{"enabled":true,"config":["ZWNmLWNvbmZpZw"]}}}`,
			want: `{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,` +
				`"tls":{"ech":{"config":["-----BEGIN ECH CONFIGS-----","ZWNmLWNvbmZpZw","-----END ECH CONFIGS-----"],"enabled":true},` +
				`"enabled":true},"type":"vless","uuid":"u"}`,
		},
		{
			name: "ws host moves into headers",
			document: `{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none",` +
				`"packet_encoding":"xudp","transport":{"type":"ws","host":"Cdn.Example","path":"/ws"}}`,
			want: `{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,` +
				`"transport":{"headers":{"Host":"Cdn.Example"},"path":"/ws","type":"ws"},"type":"vless","uuid":"u"}`,
		},
		{
			name: "ws early-data path splits into three fields",
			document: `{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none",` +
				`"packet_encoding":"xudp","transport":{"type":"ws","path":"/ws?ed=2048"}}`,
			want: `{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,` +
				`"transport":{"early_data_header_name":"Sec-WebSocket-Protocol","max_early_data":2048,"path":"/ws","type":"ws"},` +
				`"type":"vless","uuid":"u"}`,
		},
		{
			name:     "autoselector normalises ids and clamps",
			document: `{"type":"autoselector","name":"a","gids":[5,5,-1],"pool_cap":10,"build_limit":20,"expected":4,"active_size":2}`,
			want: `{"active_size":4,"balance":false,"balance_interval_sec":30,"balance_mode":"rotate",` +
				`"bench_interval_sec":600,"build_limit":10,"connectivity_url":"","country_filter":"",` +
				`"dial_retries":2,"exclude_unavailable":true,"expected":4,"gid":5,"gids":[5],"history":[],` +
				`"interrupt_on_switch":true,"interval_sec":300,"last_built":[],"last_built_at":0,` +
				`"max_rtt_ms":0,"name":"a","name_filter":"","pinned_id":-1,"pool":[],"pool_cap":10,` +
				`"pool_ranked_at":0,"result_validity_mins":1440,"sampling":10,"test_url":"",` +
				`"tolerance_ms":300,"type":"autoselector","watch_interval_sec":15}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := normalizeStoredProfileDocument(t, test.document)
			if !result.Supported {
				t.Fatalf("document refused: %s", result.Reason)
			}
			if result.JSON != test.want {
				t.Fatalf("normalized = %s\nwant       %s", result.JSON, test.want)
			}
			// Canonical form is a fixed point.
			again := normalizeStoredProfileDocument(t, result.JSON)
			if !again.Supported || again.JSON != result.JSON {
				t.Fatalf("normalize is not idempotent: %+v", again)
			}
		})
	}
}

func TestProfileNormalizeStoredRefusals(t *testing.T) {
	for _, storedType := range []string{"openvpn", "openconnect"} {
		t.Run(storedType, func(t *testing.T) {
			result := normalizeStoredProfileDocument(t, `{"type":"`+storedType+`"}`)
			if result.Supported {
				t.Fatalf("%s was normalized: %s", storedType, result.JSON)
			}
			if !strings.Contains(result.Reason, storedType) || result.JSON != "" {
				t.Fatalf("reason = %q, json = %q", result.Reason, result.JSON)
			}
		})
	}
	unknown := normalizeStoredProfileDocument(t, `{"type":"nosuch"}`)
	if unknown.Supported || !strings.Contains(unknown.Reason, "nosuch") {
		t.Fatalf("unknown type answered %+v", unknown)
	}
	field := normalizeStoredProfileDocument(t, `{"type":"vless","uuid":"u","future":1}`)
	if field.Supported || !strings.Contains(field.Reason, "future") {
		t.Fatalf("unknown field answered %+v", field)
	}
}

func TestProfileNormalizeStoredErrors(t *testing.T) {
	format := profileFormatStored
	cases := []string{"", `[]`, `{"type":""}`, `{"type":"socks"`}
	for _, document := range cases {
		t.Run(document, func(t *testing.T) {
			payload, err := stdjson.Marshal(profileDocumentRequest{JSON: &document, Format: &format})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := handleProfileNormalize(payload); err == nil {
				t.Fatalf("document accepted: %s", document)
			}
		})
	}
	document := `{"type":"socks"}`
	unknown := "bogus"
	payload, err := stdjson.Marshal(profileDocumentRequest{JSON: &document, Format: &unknown})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := handleProfileNormalize(payload); err == nil || !strings.Contains(err.Error(), "unknown format") {
		t.Fatalf("unknown format was not refused: %v", err)
	}
}

func TestProfileNormalizeStoredReplyShape(t *testing.T) {
	result := normalizeStoredProfileDocument(t, `{"type":"socks"}`)
	encoded, err := stdjson.Marshal(result)
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := stdjson.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["supported"] != true || decoded["json"] != `{"type":"socks"}` {
		t.Fatalf("reply = %s", encoded)
	}
	if _, present := decoded["reason"]; present {
		t.Fatalf("a successful reply carries a reason: %s", encoded)
	}
	refused := normalizeStoredProfileDocument(t, `{"type":"openvpn"}`)
	encoded, err = stdjson.Marshal(refused)
	if err != nil {
		t.Fatal(err)
	}
	decoded = nil
	if err := stdjson.Unmarshal(encoded, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["supported"] != false {
		t.Fatalf("refused reply = %s", encoded)
	}
	if _, present := decoded["json"]; present {
		t.Fatalf("a refused reply carries json: %s", encoded)
	}
	if reason, ok := decoded["reason"].(string); !ok || reason == "" {
		t.Fatalf("a refused reply carries no reason: %s", encoded)
	}
}
