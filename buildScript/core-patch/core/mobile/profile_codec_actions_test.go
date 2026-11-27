package mobile

import (
	stdjson "encoding/json"
	"strings"
	"testing"
)

// The fixtures below are one document per protocol the kernel always registers
// (no descriptor tag needed), plus the failure shapes the editor has to explain.
// They pin the *pinned core's* acceptance: a core bump that renames an option
// field fails here first, which is the point of testing against the real option
// types instead of a hand-written list of keys.

func validateProfileDocument(t *testing.T, document string) profileValidateResult {
	t.Helper()
	payload, err := stdjson.Marshal(profileDocumentRequest{JSON: &document})
	if err != nil {
		t.Fatalf("encode payload: %v", err)
	}
	answer, err := handleProfileValidate(payload)
	if err != nil {
		t.Fatalf("handleProfileValidate(%q): %v", document, err)
	}
	result, ok := answer.(profileValidateResult)
	if !ok {
		t.Fatalf("handleProfileValidate answered %T, want profileValidateResult", answer)
	}
	return result
}

func normalizeProfileDocument(t *testing.T, document string) (string, error) {
	t.Helper()
	payload, err := stdjson.Marshal(profileDocumentRequest{JSON: &document})
	if err != nil {
		t.Fatalf("encode payload: %v", err)
	}
	answer, err := handleProfileNormalize(payload)
	if err != nil {
		return "", err
	}
	result, ok := answer.(profileJSONResult)
	if !ok {
		t.Fatalf("handleProfileNormalize answered %T, want profileJSONResult", answer)
	}
	return result.JSON, nil
}

func TestProfileValidateAcceptsProtocols(t *testing.T) {
	documents := map[string]string{
		"socks": `{"type":"socks","tag":"proxy","server":"127.0.0.1","server_port":1080,"username":"user","password":"pass"}`,
		"http": `{"type":"http","tag":"proxy","server":"example.com","server_port":8080,` +
			`"tls":{"enabled":true,"server_name":"example.com"}}`,
		"shadowsocks": `{"type":"shadowsocks","tag":"proxy","server":"example.com","server_port":8388,` +
			`"method":"2022-blake3-aes-128-gcm","password":"secret"}`,
		"vmess": `{"type":"vmess","tag":"proxy","server":"example.com","server_port":443,` +
			`"uuid":"a2b3c4d5-0000-0000-0000-000000000000","security":"auto","alter_id":0}`,
		"vless": `{"type":"vless","tag":"proxy","server":"example.com","server_port":443,` +
			`"uuid":"a2b3c4d5-0000-0000-0000-000000000000","flow":"xtls-rprx-vision",` +
			`"tls":{"enabled":true,"server_name":"example.com"}}`,
		"trojan": `{"type":"trojan","tag":"proxy","server":"example.com","server_port":443,` +
			`"password":"secret","tls":{"enabled":true,"server_name":"example.com"}}`,
		"direct": `{"type":"direct","tag":"direct"}`,
	}
	for name, document := range documents {
		t.Run(name, func(t *testing.T) {
			result := validateProfileDocument(t, document)
			if !result.OK {
				t.Fatalf("document rejected: %+v", result.Issues)
			}
			if len(result.Issues) != 0 {
				t.Fatalf("ok result carries issues: %+v", result.Issues)
			}
			if result.Normalized == "" {
				t.Fatal("ok result carries no normalized document")
			}
			// Normalization is idempotent: the canonical form must validate to the
			// same bytes, or the editor would rewrite the document on every open.
			again := validateProfileDocument(t, result.Normalized)
			if !again.OK || again.Normalized != result.Normalized {
				t.Fatalf("normalized document is not stable:\nfirst:  %s\nsecond: %s\nissues: %+v",
					result.Normalized, again.Normalized, again.Issues)
			}
		})
	}
}

func TestProfileValidateNormalizesCanonically(t *testing.T) {
	// Key order in the input does not survive: the output follows the option
	// struct's field order and is compact. This is the deterministic form the
	// action promises for one core pin (see handleProfileNormalize's limitation
	// note), so it is pinned exact on purpose — a core bump that changes it should
	// make somebody look, not slip through.
	const document = `{ "server_port": 1080, "server": "127.0.0.1", "type": "socks", "tag": "proxy" }`
	const want = `{"type":"socks","tag":"proxy","server":"127.0.0.1","server_port":1080}`
	result := validateProfileDocument(t, document)
	if !result.OK {
		t.Fatalf("document rejected: %+v", result.Issues)
	}
	if result.Normalized != want {
		t.Fatalf("normalized = %s, want %s", result.Normalized, want)
	}
}

func TestProfileValidateRejectsDocuments(t *testing.T) {
	tests := []struct {
		name     string
		document string
		field    string
		want     string
	}{
		{
			name:     "unknown envelope field",
			document: `{"type":"socks","server":"x","bogus":1}`,
			field:    "bogus",
			want:     `unknown field "bogus"`,
		},
		{
			name:     "wrong field type",
			document: `{"type":"socks","server":"x","server_port":"1080"}`,
			field:    "server_port",
			want:     "cannot unmarshal string",
		},
		{
			name:     "nested wrong field type",
			document: `{"type":"http","server":"x","server_port":8080,"tls":{"enabled":"yes"}}`,
			field:    "tls.enabled",
			want:     "cannot unmarshal string",
		},
		{
			name:     "port out of range",
			document: `{"type":"socks","server":"x","server_port":70000}`,
			field:    "server_port",
			want:     "70000",
		},
		{
			name:     "missing type",
			document: `{"server":"x"}`,
			field:    "type",
			want:     `no "type" field`,
		},
		{
			name:     "empty type",
			document: `{"type":""}`,
			field:    "type",
			want:     `no "type" field`,
		},
		{
			name:     "unknown type",
			document: `{"type":"nosuch","server":"x"}`,
			field:    "type",
			want:     `unknown outbound type "nosuch"`,
		},
		{
			name:     "type is not a string",
			document: `{"type":5,"server":"x"}`,
			field:    "type",
			want:     "cannot unmarshal number",
		},
		{
			name:     "json null",
			document: `null`,
			field:    "type",
			want:     `no "type" field`,
		},
		{
			name:     "empty document",
			document: "  \n\t ",
			field:    "",
			want:     "empty",
		},
		{
			name:     "truncated document",
			document: `{"type":"socks",`,
			field:    "",
			want:     "row 1",
		},
		{
			name:     "array instead of object",
			document: `[{"type":"socks"}]`,
			field:    "",
			want:     "cannot unmarshal array",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := validateProfileDocument(t, test.document)
			if result.OK {
				t.Fatalf("document accepted: %s", test.document)
			}
			if len(result.Issues) != 1 {
				t.Fatalf("issues = %+v, want exactly one", result.Issues)
			}
			issue := result.Issues[0]
			if issue.Field != test.field {
				t.Fatalf("field = %q, want %q (message %q)", issue.Field, test.field, issue.Message)
			}
			if !strings.Contains(issue.Message, test.want) {
				t.Fatalf("message %q does not contain %q", issue.Message, test.want)
			}
			if issue.Severity != profileSeverityError {
				t.Fatalf("severity = %q, want %q", issue.Severity, profileSeverityError)
			}
			if result.Normalized != "" {
				t.Fatalf("a refused document came back normalized: %s", result.Normalized)
			}
		})
	}
}

func TestProfileValidateToleratesWhatTheCoreTolerates(t *testing.T) {
	// The core decodes the TLS container leniently, so an undeclared key inside
	// `tls` is accepted there and accepted here. This action reports the kernel's
	// acceptance, not a stricter policy of its own; the key is dropped from the
	// normalized document, which is why the editor should prefer normalize's
	// output when it saves.
	document := `{"type":"http","server":"example.com","server_port":8080,` +
		`"tls":{"enabled":true,"made_up":1}}`
	result := validateProfileDocument(t, document)
	if !result.OK {
		t.Fatalf("document rejected: %+v", result.Issues)
	}
	if strings.Contains(result.Normalized, "made_up") {
		t.Fatalf("normalized document kept an undeclared key: %s", result.Normalized)
	}
}

func TestProfileValidateAcceptsComments(t *testing.T) {
	document := "{\n  // the core decoder strips comments\n  \"type\": \"socks\",\n  \"server\": \"x\"\n}"
	result := validateProfileDocument(t, document)
	if !result.OK {
		t.Fatalf("document with a comment rejected: %+v", result.Issues)
	}
	if result.Normalized != `{"type":"socks","server":"x"}` {
		t.Fatalf("normalized = %s", result.Normalized)
	}
}

func TestProfileValidatePayload(t *testing.T) {
	if _, err := handleProfileValidate(nil); err == nil {
		t.Fatal("a missing payload was accepted")
	}
	if _, err := handleProfileValidate(stdjson.RawMessage(`{}`)); err == nil {
		t.Fatal(`a payload without "json" was accepted`)
	}
	if _, err := handleProfileValidate(stdjson.RawMessage(`{"json":`)); err == nil {
		t.Fatal("a malformed payload was accepted")
	}
}

func TestProfileValidateReplyShape(t *testing.T) {
	result := validateProfileDocument(t, `{"type":"socks","server":"x","server_port":1080}`)
	encoded, err := stdjson.Marshal(result)
	if err != nil {
		t.Fatalf("encode reply: %v", err)
	}
	var decoded map[string]any
	if err := stdjson.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("decode reply: %v", err)
	}
	if decoded["ok"] != true {
		t.Fatalf("ok = %v", decoded["ok"])
	}
	if _, isList := decoded["issues"].([]any); !isList {
		t.Fatalf("issues is not a JSON array: %s", encoded)
	}
	if _, present := decoded["normalized"]; !present {
		t.Fatalf("an accepted document has no normalized field: %s", encoded)
	}

	refused := validateProfileDocument(t, `{"type":"nosuch"}`)
	encoded, err = stdjson.Marshal(refused)
	if err != nil {
		t.Fatalf("encode refused reply: %v", err)
	}
	decoded = nil
	if err := stdjson.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("decode refused reply: %v", err)
	}
	if _, present := decoded["normalized"]; present {
		t.Fatalf("a refused document carries normalized: %s", encoded)
	}
	issues, isList := decoded["issues"].([]any)
	if !isList || len(issues) != 1 {
		t.Fatalf("issues = %v, want one element", decoded["issues"])
	}
	issue, isMap := issues[0].(map[string]any)
	if !isMap {
		t.Fatalf("issue is not an object: %v", issues[0])
	}
	for _, key := range []string{"field", "message", "severity"} {
		if _, present := issue[key]; !present {
			t.Fatalf("issue has no %q key: %s", key, encoded)
		}
	}
}

func TestProfileNormalizeCanonicalisesShape(t *testing.T) {
	document := "{\n  // comment\n  \"type\": \"socks\",\n  \"server\": null,\n" +
		"  \"server_port\": 1080,\n  \"udp_over_tcp\": {\"enabled\": true, \"version\": 2}\n}"
	const want = `{"type":"socks","server":"","server_port":1080,"udp_over_tcp":true}`
	normalized, err := normalizeProfileDocument(t, document)
	if err != nil {
		t.Fatalf("normalize: %v", err)
	}
	if normalized != want {
		t.Fatalf("normalized = %s, want %s", normalized, want)
	}
	again, err := normalizeProfileDocument(t, normalized)
	if err != nil {
		t.Fatalf("normalize canonical form: %v", err)
	}
	if again != normalized {
		t.Fatalf("normalize is not idempotent: %s -> %s", normalized, again)
	}
}

func TestProfileNormalizeRejectsInvalidDocument(t *testing.T) {
	if _, err := normalizeProfileDocument(t, `{"type":"socks","bogus":1}`); err == nil {
		t.Fatal("an invalid document was normalized")
	} else if !strings.Contains(err.Error(), "bogus") {
		t.Fatalf("error does not name the field: %v", err)
	}
	if _, err := normalizeProfileDocument(t, `{"type":"nosuch"}`); err == nil {
		t.Fatal("an unknown outbound type was normalized")
	}
	if _, err := handleProfileNormalize(stdjson.RawMessage(`{}`)); err == nil {
		t.Fatal(`a payload without "json" was accepted`)
	}
	if _, err := normalizeProfileDocument(t, "  "); err == nil {
		t.Fatal("an empty document was normalized")
	} else if !strings.Contains(err.Error(), "empty") {
		t.Fatalf("error does not say the document is empty: %v", err)
	}
}

func TestProfileNewOutboundTemplates(t *testing.T) {
	templates := map[string]string{
		"direct": `{"type":"direct"}`,
		"http":   `{"type":"http","server":""}`,
		"socks":  `{"type":"socks","server":""}`,
	}
	for outboundType, want := range templates {
		t.Run(outboundType, func(t *testing.T) {
			payload, err := stdjson.Marshal(profileNewOutboundRequest{Type: outboundType})
			if err != nil {
				t.Fatalf("encode payload: %v", err)
			}
			answer, err := handleProfileNewOutbound(payload)
			if err != nil {
				t.Fatalf("handleProfileNewOutbound: %v", err)
			}
			result, ok := answer.(profileJSONResult)
			if !ok {
				t.Fatalf("answered %T, want profileJSONResult", answer)
			}
			if result.JSON != want {
				t.Fatalf("template = %s, want %s", result.JSON, want)
			}
			// A template the kernel would refuse would open the "new node" form
			// already red, so every one of them must validate.
			validation := validateProfileDocument(t, result.JSON)
			if !validation.OK {
				t.Fatalf("template does not validate: %+v", validation.Issues)
			}
		})
	}
}

func TestProfileNewOutboundRefusesUnsupportedTypes(t *testing.T) {
	for _, outboundType := range []string{"shadowsocks", "vmess", "nosuch"} {
		t.Run(outboundType, func(t *testing.T) {
			payload, err := stdjson.Marshal(profileNewOutboundRequest{Type: outboundType})
			if err != nil {
				t.Fatalf("encode payload: %v", err)
			}
			if _, err := handleProfileNewOutbound(payload); err == nil {
				t.Fatalf("%s was templated", outboundType)
			} else if !strings.Contains(err.Error(), "direct, http, socks") {
				t.Fatalf("error does not list the supported types: %v", err)
			}
		})
	}
	if _, err := handleProfileNewOutbound(stdjson.RawMessage(`{"type":"  "}`)); err == nil {
		t.Fatal("an empty type was templated")
	}
	if _, err := handleProfileNewOutbound(nil); err == nil {
		t.Fatal("a missing payload was accepted")
	}
}

func TestProfileCodecActionsRegistered(t *testing.T) {
	for _, method := range []Method{profileValidateMethod, profileNormalizeMethod, profileNewOutboundMethod} {
		if actionHandlers[method] == nil {
			t.Fatalf("%s has no registered handler", method)
		}
	}
}
