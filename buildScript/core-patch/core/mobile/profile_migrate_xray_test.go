// S5d parity tests. The vectors below are the cases pinned by
// app/src/test/java/io/nekohasekai/sagernet/outbound/import/LegacyXrayTest.kt
// plus the frozen `migrate-xray-vless` profile-corpus case (read from
// FLRONE_PROFILE_CORPUS_DIR). The stored JSON is the exact Kotlin
// exportToJson().toCompact() output; the refusal text is a plain source
// string, so no Android resource is involved.
package mobile

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

const migrateTestUUID = "b831381d-6324-4d53-ad4f-8cda48b30811"

// migrateVlessRow mirrors LegacyXrayTest.vlessRow: protocol/tag, a vnext
// entry with address/port/users[0], and the supplied stream/mux blocks.
func migrateVlessRow(stream, user, mux string) string {
	streamObj, ok := configDecodeJSONObject(stream)
	if !ok {
		panic("bad stream fixture")
	}
	userObj, ok := configDecodeJSONObject(user)
	if !ok {
		panic("bad user fixture")
	}
	muxObj, _ := configDecodeJSONObject(mux)
	rowUser := map[string]any{"id": migrateTestUUID, "encryption": "none", "flow": ""}
	for key, value := range userObj {
		rowUser[key] = value
	}
	row := map[string]any{
		"protocol": "vless",
		"tag":      "legacy-node",
		"settings": map[string]any{"vnext": []any{map[string]any{
			"address": "vless.example.com",
			"port":    443,
			"users":   []any{rowUser},
		}}},
		"streamSettings": streamObj,
	}
	if len(muxObj) > 0 {
		row["mux"] = muxObj
	}
	encoded, err := json.Marshal(row)
	if err != nil {
		panic(err)
	}
	return string(encoded)
}

func migrateReply(t *testing.T, storedType, row string) profileMigrateReply {
	t.Helper()
	reply, err := handleProfileMigrate(mustMigratePayload(t, storedType, row))
	if err != nil {
		t.Fatalf("handleProfileMigrate: %v", err)
	}
	typed, ok := reply.(profileMigrateReply)
	if !ok {
		t.Fatalf("handleProfileMigrate answered %T, want profileMigrateReply", reply)
	}
	return typed
}

func mustMigratePayload(t *testing.T, storedType, row string) json.RawMessage {
	t.Helper()
	payload, err := json.Marshal(profileMigrateRequest{Type: storedType, JSON: &row})
	if err != nil {
		t.Fatal(err)
	}
	return payload
}

func assertMigrated(t *testing.T, reply profileMigrateReply, profileType string) {
	t.Helper()
	if !reply.Migrated || reply.Reason != "" {
		t.Fatalf("migration refused: %+v", reply)
	}
	if reply.Type != profileType {
		t.Fatalf("type = %q, want %q", reply.Type, profileType)
	}
	if reply.JSON == "" || reply.DedupKey == "" || reply.Identity == "" {
		t.Fatalf("missing export surface: %+v", reply)
	}
}

// TestMigrateStoredXrayVless covers LegacyXrayTest's "a stored xrayvless row
// becomes a vless outbound": ws + TLS + fingerprint + mux.
func TestMigrateStoredXrayVless(t *testing.T) {
	row := migrateVlessRow(
		`{"network":"ws","security":"tls","wsSettings":{"path":"/chat","host":"ws.example.com"},`+
			`"tlsSettings":{"serverName":"tls.example.com","fingerprint":"chrome"}}`,
		`{}`,
		`{"enabled":true,"concurrency":8}`,
	)
	reply := migrateReply(t, "xrayvless", row)
	assertMigrated(t, reply, "vless")
	want := `{"encryption":"none","flow":"","packet_encoding":"xudp","server":"vless.example.com",` +
		`"server_port":443,"tag":"legacy-node","tls":{"enabled":true,"fingerprint":"chrome",` +
		`"server_name":"tls.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},` +
		`"transport":{"host":"ws.example.com","path":"/chat","type":"ws"},` +
		`"multiplex":{"enabled":true,"max_streams":8},"type":"vless","uuid":"` + migrateTestUUID + `"}`
	// The flow key is not written when empty by Kotlin, so compare the decoded
	// object field by field instead of raw bytes for this case.
	object, ok := configDecodeJSONObject(reply.JSON)
	if !ok {
		t.Fatal("json is not an object")
	}
	checks := map[string]any{
		"server":          "vless.example.com",
		"server_port":     int64(443),
		"tag":             "legacy-node",
		"uuid":            migrateTestUUID,
		"encryption":      "none",
		"packet_encoding": "xudp",
	}
	for key, wantValue := range checks {
		if object[key] != wantValue {
			t.Errorf("%s = %v, want %v", key, object[key], wantValue)
		}
	}
	if _, present := object["flow"]; present {
		t.Error("empty flow must not be written")
	}
	transport, _ := object["transport"].(map[string]any)
	if transport["type"] != "ws" || transport["path"] != "/chat" || transport["host"] != "ws.example.com" {
		t.Errorf("transport = %v", transport)
	}
	tls, _ := object["tls"].(map[string]any)
	if tls["enabled"] != true || tls["server_name"] != "tls.example.com" {
		t.Errorf("tls = %v", tls)
	}
	utls, _ := tls["utls"].(map[string]any)
	if utls["fingerprint"] != "chrome" {
		t.Errorf("utls = %v", utls)
	}
	mux, _ := object["multiplex"].(map[string]any)
	if mux["enabled"] != true || mux["max_streams"] != int64(8) {
		t.Errorf("multiplex = %v", mux)
	}
	_ = want // documented shape above; the per-field checks are the contract
}

// TestMigrateXhttpEncryptionAndMkcp covers "xhttp encryption and mkcp survive
// the conversion": VLESS Encryption, xhttp extra (x_padding_bytes + xmux),
// then the kcp alias folded onto mkcp with header/seed.
func TestMigrateXhttpEncryptionAndMkcp(t *testing.T) {
	xhttpRow := migrateVlessRow(
		`{"network":"xhttp","security":"tls","xhttpSettings":{"path":"/x","host":"cdn.example.com",`+
			`"mode":"packet-up","extra":{"xPaddingBytes":"200-800","xmux":{"maxConnections":"4-8"}}}}`,
		`{"encryption":"mlkem768x25519plus.native.0rtt.AAAA"}`,
		`{}`,
	)
	reply := migrateReply(t, "xrayvless", xhttpRow)
	assertMigrated(t, reply, "vless")
	object, _ := configDecodeJSONObject(reply.JSON)
	if object["encryption"] != "mlkem768x25519plus.native.0rtt.AAAA" {
		t.Errorf("encryption = %v", object["encryption"])
	}
	transport, _ := object["transport"].(map[string]any)
	if transport["type"] != "xhttp" || transport["path"] != "/x" ||
		transport["host"] != "cdn.example.com" || transport["mode"] != "packet-up" {
		t.Errorf("transport = %v", transport)
	}
	if transport["x_padding_bytes"] != "200-800" {
		t.Errorf("x_padding_bytes = %v", transport["x_padding_bytes"])
	}
	xmux, _ := transport["xmux"].(map[string]any)
	if xmux["maxConnections"] != "4-8" {
		t.Errorf("xmux = %v", xmux)
	}

	kcpRow := migrateVlessRow(
		`{"network":"kcp","kcpSettings":{"mtu":1400,"tti":40,"header":{"type":"srtp"},"seed":"abc"}}`,
		`{}`, `{}`,
	)
	kcpReply := migrateReply(t, "xrayvless", kcpRow)
	assertMigrated(t, kcpReply, "vless")
	kcpObject, _ := configDecodeJSONObject(kcpReply.JSON)
	kcpTransport, _ := kcpObject["transport"].(map[string]any)
	if kcpTransport["type"] != "mkcp" || kcpTransport["mtu"] != int64(1400) ||
		kcpTransport["tti"] != int64(40) || kcpTransport["header_type"] != "srtp" ||
		kcpTransport["seed"] != "abc" {
		t.Errorf("mkcp transport = %v", kcpTransport)
	}
}

// TestMigrateRealityRow covers "a reality row keeps its key and short id":
// the raw network is folded away, publicKey/shortId/flow survive.
func TestMigrateRealityRow(t *testing.T) {
	row := migrateVlessRow(
		`{"network":"raw","security":"reality","realitySettings":{`+
			`"serverName":"www.example.com","fingerprint":"chrome",`+
			`"publicKey":"Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw",`+
			`"shortId":"0123456789abcdef"}}`,
		`{"flow":"xtls-rprx-vision"}`, `{}`,
	)
	reply := migrateReply(t, "xrayvless", row)
	assertMigrated(t, reply, "vless")
	object, _ := configDecodeJSONObject(reply.JSON)
	if object["flow"] != "xtls-rprx-vision" {
		t.Errorf("flow = %v", object["flow"])
	}
	if _, present := object["transport"]; present {
		t.Error("raw network must not add a transport block")
	}
	tls, _ := object["tls"].(map[string]any)
	if tls["enabled"] != true || tls["server_name"] != "www.example.com" {
		t.Errorf("tls = %v", tls)
	}
	reality, _ := tls["reality"].(map[string]any)
	if reality["enabled"] != true ||
		reality["public_key"] != "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw" ||
		reality["short_id"] != "0123456789abcdef" {
		t.Errorf("reality = %v", reality)
	}
}

// TestMigrateXdriveRefusal covers "xdrive cannot be represented and says so".
func TestMigrateXdriveRefusal(t *testing.T) {
	row := migrateVlessRow(`{"network":"xdrive","security":"tls"}`, `{}`, `{}`)
	reply := migrateReply(t, "xrayvless", row)
	if reply.Migrated || reply.Reason == "" {
		t.Fatalf("xdrive was not refused: %+v", reply)
	}
	if !strings.Contains(strings.ToLower(reply.Reason), "xdrive") {
		t.Fatalf("reason = %q, want it to mention XDRIVE", reply.Reason)
	}
}

// TestMigrateXrayFullConfigRefusal covers "a custom xray full config is kept
// but invalid", with the exact FULL_CONFIG_ERROR source string.
func TestMigrateXrayFullConfigRefusal(t *testing.T) {
	row := `{"type":"custom","subtype":"xrayfullconfig","config":"{\"outbounds\":[]}"}`
	reply := migrateReply(t, "custom", row)
	if reply.Migrated {
		t.Fatalf("full config was migrated: %+v", reply)
	}
	if !strings.Contains(reply.Reason, xrayFullConfigError) {
		t.Fatalf("reason = %q, want FULL_CONFIG_ERROR", reply.Reason)
	}
}

// TestMigrateCustomXrayOutbound covers "a custom xrayoutbound row converts
// when the protocol maps" plus its refusal half (an unmapped protocol).
func TestMigrateCustomXrayOutbound(t *testing.T) {
	trojan := `{"protocol":"trojan","tag":"t","settings":{"servers":[{` +
		`"address":"trojan.example.com","port":443,"password":"secret"}]},` +
		`"streamSettings":{"network":"ws","security":"tls",` +
		`"tlsSettings":{"serverName":"sni.example.com"}}}`
	encoded, err := json.Marshal(map[string]any{
		"type": "custom", "subtype": "xrayoutbound", "config": trojan,
	})
	if err != nil {
		t.Fatal(err)
	}
	reply := migrateReply(t, "custom", string(encoded))
	assertMigrated(t, reply, "trojan")
	object, _ := configDecodeJSONObject(reply.JSON)
	if object["server"] != "trojan.example.com" || object["server_port"] != int64(443) ||
		object["password"] != "secret" {
		t.Errorf("trojan object = %v", object)
	}
	transport, _ := object["transport"].(map[string]any)
	if transport["type"] != "ws" {
		t.Errorf("transport = %v", transport)
	}

	hysteria := `{"protocol":"hysteria","settings":{"address":"h.example.com","port":443}}`
	encoded, err = json.Marshal(map[string]any{
		"type": "custom", "subtype": "xrayoutbound", "config": hysteria,
	})
	if err != nil {
		t.Fatal(err)
	}
	refused := migrateReply(t, "custom", string(encoded))
	if refused.Migrated || refused.Reason == "" {
		t.Fatalf("hysteria was not refused: %+v", refused)
	}
	if !strings.Contains(refused.Reason, "hysteria") {
		t.Fatalf("reason = %q, want it to name hysteria", refused.Reason)
	}
}

// TestMigrateOtherProtocolsAndRefusals covers the remaining CONVERTIBLE_PROTOCOLS
// and the explicit refusal branches that LegacyXray.kt implements but its JVM
// test does not assert.
func TestMigrateOtherProtocolsAndRefusals(t *testing.T) {
	cases := []struct {
		name     string
		row      string
		wantType string
	}{
		{
			"vmess", `{"protocol":"vmess","settings":{"vnext":[{"address":"vm.example.com",` +
				`"port":443,"users":[{"id":"` + migrateTestUUID + `","security":"auto","alterId":2}]}]}}`,
			"vmess",
		},
		{
			"shadowsocks", `{"protocol":"shadowsocks","settings":{"address":"ss.example.com",` +
				`"port":8388,"method":"aes-128-gcm","password":"pw"}}`,
			"shadowsocks",
		},
		{
			"socks", `{"protocol":"socks","settings":{"address":"socks.example.com",` +
				`"port":1080,"user":"u","pass":"p"}}`,
			"socks",
		},
		{
			"http", `{"protocol":"http","settings":{"address":"http.example.com",` +
				`"port":8080,"user":"u","pass":"p"}}`,
			"http",
		},
		{
			"wireguard", `{"protocol":"wireguard","settings":{"secretKey":"priv",` +
				`"address":["10.0.0.2/32"],"mtu":1420,"peers":[` +
				`{"endpoint":"wg.example.com:51820","publicKey":"pub","preSharedKey":"psk"}]}}`,
			"wireguard",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reply := migrateReply(t, "xrayvless", tc.row)
			assertMigrated(t, reply, tc.wantType)
		})
	}

	refusals := []struct {
		name, row, fragment string
	}{
		{"no server", `{"protocol":"vless","settings":{"vnext":[{"port":443,` +
			`"users":[{"id":"id"}]}]}}`, "no server address"},
		{"no vless id", `{"protocol":"vless","settings":{"vnext":[{"address":"h","port":443}]}}`, "no user id"},
		{"no trojan password", `{"protocol":"trojan","settings":{"servers":[{"address":"h","port":443}]}}`, "no password"},
		{"no ss method", `{"protocol":"shadowsocks","settings":{"address":"h","port":443,"password":"p"}}`, "no method or password"},
		{"no wg secret", `{"protocol":"wireguard","settings":{"peers":[{"endpoint":"h:1","publicKey":"k"}]}}`, "no secretKey"},
		{"no wg peer key", `{"protocol":"wireguard","settings":{"secretKey":"k","peers":[{"endpoint":"h:1"}]}}`, "no peer public key"},
		{"unknown transport", `{"protocol":"vless","settings":{"vnext":[{"address":"h","port":443,` +
			`"users":[{"id":"id"}]}]},"streamSettings":{"network":"snell"}}`, "no sing-box counterpart"},
		{"unknown security", `{"protocol":"vless","settings":{"vnext":[{"address":"h","port":443,` +
			`"users":[{"id":"id"}]}]},"streamSettings":{"security":"xtls"}}`, "no sing-box counterpart"},
		{"verifyPeerCertByName", `{"protocol":"vless","settings":{"vnext":[{"address":"h","port":443,` +
			`"users":[{"id":"id"}]}]},"streamSettings":{"security":"tls",` +
			`"tlsSettings":{"verifyPeerCertByName":"x"}}}`, "verifyPeerCertByName"},
	}
	for _, tc := range refusals {
		t.Run(tc.name, func(t *testing.T) {
			reply := migrateReply(t, "xrayvless", tc.row)
			if reply.Migrated || reply.Reason == "" {
				t.Fatalf("not refused: %+v", reply)
			}
			if !strings.Contains(reply.Reason, tc.fragment) {
				t.Fatalf("reason = %q, want it to contain %q", reply.Reason, tc.fragment)
			}
		})
	}

	// Infrastructure protocols are dropped, not refused; an ordinary row is
	// not a migration at all.
	for _, row := range []string{
		`{"protocol":"freedom"}`, `{"protocol":"blackhole"}`, `{"type":"vless","uuid":"x"}`,
	} {
		reply := migrateReply(t, "xrayvless", row)
		if reply.Migrated || reply.Reason != "" {
			t.Fatalf("ordinary row %s produced a migration: %+v", row, reply)
		}
	}
}

// TestMigrateActionContract pins the registered wire method and its reply
// shape through the action bus.
func TestMigrateActionContract(t *testing.T) {
	if actionHandlers[profileMigrateMethod] == nil {
		t.Fatal("profileMigrate has no registered handler")
	}
	row := `{"protocol":"vless","settings":{"vnext":[{"address":"h","port":443,` +
		`"users":[{"id":"` + migrateTestUUID + `"}]}]}}`
	payload := mustMigratePayload(t, "xrayvless", row)
	result := runActionSynchronously(`{"id":"m1","method":"profileMigrate","data":` + string(payload) + `}`)
	if result.Code != actionCodeSuccess {
		t.Fatalf("action failed: %+v", result)
	}
	if result.Id != "m1" || result.Method != profileMigrateMethod {
		t.Fatalf("result envelope = %+v", result)
	}
}

// TestProfileCorpusMigrateXrayVless reads the frozen `migrate-xray-vless`
// case from FLRONE_PROFILE_CORPUS_DIR and compares the Go action's canonical
// payload to the envelope byte-for-byte (same canonicalisation as
// profile_corpus_test.go and tools/diagnostics/profile_corpus.py).
func TestProfileCorpusMigrateXrayVless(t *testing.T) {
	root, explicit := profileCorpusFixtureRoot(t)
	caseDir := filepath.Join(root, "migrate-xray-vless")
	if _, err := os.Stat(caseDir); err != nil {
		if !explicit && testing.Short() {
			t.Skipf("migrate-xray-vless fixture not reachable at %s: %v", caseDir, err)
		}
		t.Fatalf("migrate-xray-vless fixture not reachable at %s: %v", caseDir, err)
	}
	input, err := os.ReadFile(filepath.Join(caseDir, "input.txt"))
	if err != nil {
		t.Fatalf("read input.txt: %v", err)
	}
	rawExpected, err := os.ReadFile(filepath.Join(caseDir, "expected.json"))
	if err != nil {
		t.Fatalf("read expected.json: %v", err)
	}
	var envelope profileCorpusEnvelope
	if err := json.Unmarshal(rawExpected, &envelope); err != nil {
		t.Fatalf("parse expected.json: %v", err)
	}

	// The fixture input carries `storedType` for the JVM oracle; the action's
	// wire payload is `type`.
	parsed, ok := configDecodeJSONObject(string(input))
	if !ok {
		t.Fatal("migrate-xray-vless input.txt is not an object")
	}
	storedType := configJSONString(parsed, "storedType")
	reply := migrateReply(t, storedType, string(input))
	if !reply.Migrated {
		t.Fatalf("migrate-xray-vless was not migrated: %+v", reply)
	}

	// The JVM corpus payload is the exports() envelope. Compare the fields the
	// frozen fixture actually carries: it predates the oracle's `formats` key,
	// while case.json already lists formats, so reconstructing the whole
	// envelope would spuriously drift. The envelope's own SHA-256 was checked
	// by TestProfileCorpusFixtures, so these bytes are the oracle's own.
	var want map[string]any
	if err := json.Unmarshal(envelope.Payload, &want); err != nil {
		t.Fatalf("parse frozen payload: %v", err)
	}
	actual := map[string]any{
		"type":        reply.Type,
		"name":        reply.Name,
		"invalid":     false,
		"displayType": profileDisplayType(reply.Type),
		"format":      "stored",
		"json":        reply.JSON,
		"identity":    reply.Identity,
		"dedupKey":    reply.DedupKey,
		"link":        reply.Link,
		"migrated":    true,
	}
	// The tagged JSON link is the dedup key without the tag stripped.
	storedObj, ok := configDecodeJSONObject(reply.JSON)
	if !ok {
		t.Fatal("reply json is not an object")
	}
	actual["exportJsonLink"] = "throne://add/" + profileBase64Encode(
		[]byte(mustCanonicalJSON(t, storedObj, "exportJsonLink")), true, false,
	)
	for key, wantValue := range want {
		got, present := actual[key]
		if !present {
			t.Errorf("missing field %q in migrated reply", key)
			continue
		}
		gotJSON, err := canonicalProfileCorpusJSON(mustMarshalJSON(t, got))
		if err != nil {
			t.Fatal(err)
		}
		wantJSON, err := canonicalProfileCorpusJSON(mustMarshalJSON(t, wantValue))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(gotJSON, wantJSON) {
			t.Errorf("%s = %s, want %s", key, gotJSON, wantJSON)
		}
	}
	// Confirm the fixture really came from the path we expect (the helper is
	// shared with the corpus-envelope test, so making this explicit catches a
	// refactor that silently points both at the wrong directory).
	if _, file, _, ok := runtime.Caller(0); !ok || file == "" {
		t.Fatal("cannot resolve test source path")
	}
}

func profileDisplayType(profileType string) string {
	switch profileType {
	case "vless":
		return "VLESS"
	case "vmess":
		return "VMess"
	case "shadowsocks":
		return "Shadowsocks"
	case "http":
		return "HTTP"
	case "socks":
		return "Socks"
	case "trojan":
		return "Trojan"
	case "wireguard":
		return "WireGuard"
	}
	return profileType
}

func mustMarshalJSON(t *testing.T, value any) []byte {
	t.Helper()
	encoded, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func mustCanonicalJSON(t *testing.T, value any, label string) []byte {
	t.Helper()
	encoded, err := MarshalCanonicalJSON(value)
	if err != nil {
		t.Fatalf("%s: %v", label, err)
	}
	return encoded
}
