package mobile

import (
	stdjson "encoding/json"
	"strings"
	"testing"
)

func validateStoredProfileDocument(t *testing.T, document string) profileValidateResult {
	t.Helper()
	format := profileFormatStored
	payload, err := stdjson.Marshal(profileDocumentRequest{JSON: &document, Format: &format})
	if err != nil {
		t.Fatalf("encode payload: %v", err)
	}
	answer, err := handleProfileValidate(payload)
	if err != nil {
		t.Fatalf("handleProfileValidate(stored): %v", err)
	}
	result, ok := answer.(profileValidateResult)
	if !ok {
		t.Fatalf("handleProfileValidate answered %T, want profileValidateResult", answer)
	}
	if result.Supported == nil {
		t.Fatal("stored validation did not set the supported field")
	}
	return result
}

func TestProfileValidateStoredAcceptsValidDocuments(t *testing.T) {
	tests := []struct {
		name       string
		document   string
		normalized string
	}{
		{
			name:       "direct with dial fields",
			document:   `{"type":"direct","tag":"D","reuse_addr":true,"connect_timeout":"5s","inet4_bind_address":"127.0.0.1"}`,
			normalized: `{"connect_timeout":"5s","inet4_bind_address":"127.0.0.1","reuse_addr":true,"tag":"D","type":"direct"}`,
		},
		{
			name:       "http with credentials and headers",
			document:   `{"type":"http","server":"Example.COM","server_port":8080,"username":"u","password":"p","headers":{"B":"2","A":"1"}}`,
			normalized: `{"headers":{"A":"1","B":"2"},"password":"p","server":"Example.COM","server_port":8080,"type":"http","username":"u"}`,
		},
		{
			name:       "socks5",
			document:   `{"type":"socks","server":"127.0.0.1","server_port":1080,"username":"u","password":"p","version":"5"}`,
			normalized: `{"password":"p","server":"127.0.0.1","server_port":1080,"type":"socks","username":"u"}`,
		},
		{
			name:       "socks4a numeric version",
			document:   `{"type":"socks","server":"127.0.0.1","server_port":1080,"version":4,"uot":true}`,
			normalized: `{"server":"127.0.0.1","server_port":1080,"type":"socks","uot":true,"version":"4"}`,
		},
		{
			name:       "shadowsocks modern cipher",
			document:   `{"type":"shadowsocks","server":"example.com","server_port":8388,"method":"aes-256-gcm","password":"secret","plugin":"obfs-local","plugin_opts":"obfs=http"}`,
			normalized: `{"method":"aes-256-gcm","password":"secret","plugin":"obfs-local","plugin_opts":"obfs=http","server":"example.com","server_port":8388,"type":"shadowsocks"}`,
		},
		{
			name:       "shadowsocks 2022 method",
			document:   `{"type":"shadowsocks","server":"example.com","server_port":8388,"method":"2022-blake3-aes-128-gcm","password":"c2VjcmV0YWJjZGVmZ2hpag=="}`,
			normalized: `{"method":"2022-blake3-aes-128-gcm","password":"c2VjcmV0YWJjZGVmZ2hpag==","server":"example.com","server_port":8388,"type":"shadowsocks"}`,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, test.document)
			if *result.Supported != true {
				t.Fatalf("supported = %v", result.Supported)
			}
			if !result.OK {
				t.Fatalf("document rejected: %+v", result.Issues)
			}
			if len(result.Issues) != 0 {
				t.Fatalf("ok result carries issues: %+v", result.Issues)
			}
			if result.Normalized != test.normalized {
				t.Fatalf("normalized = %s\nwant %s", result.Normalized, test.normalized)
			}
			// Canonical form must validate to the same bytes.
			again := validateStoredProfileDocument(t, result.Normalized)
			if !again.OK || again.Normalized != result.Normalized {
				t.Fatalf("normalized document is not stable: %+v", again)
			}
		})
	}
}

func TestProfileValidateStoredRejectsInvalidDocuments(t *testing.T) {
	tests := []struct {
		name      string
		document  string
		wantField string
		wantText  string
	}{
		{
			name:      "empty",
			document:  "  \n ",
			wantField: "",
			wantText:  "empty",
		},
		{
			name:      "not an object",
			document:  `[]`,
			wantField: "",
			wantText:  "not a JSON object",
		},
		{
			name:      "bad connect timeout",
			document:  `{"type":"direct","connect_timeout":"5"}`,
			wantField: "connect_timeout",
			wantText:  "duration",
		},
		{
			name:      "negative connect timeout",
			document:  `{"type":"direct","connect_timeout":"-5s"}`,
			wantField: "connect_timeout",
			wantText:  "negative",
		},
		{
			name:      "bad inet4 bind",
			document:  `{"type":"direct","inet4_bind_address":"::1"}`,
			wantField: "inet4_bind_address",
			wantText:  "IPv4",
		},
		{
			name:      "bad inet6 bind",
			document:  `{"type":"direct","inet6_bind_address":"127.0.0.1"}`,
			wantField: "inet6_bind_address",
			wantText:  "IPv6",
		},
		{
			name:      "http missing server",
			document:  `{"type":"http","server_port":8080}`,
			wantField: "server",
			wantText:  "required",
		},
		{
			name:      "http port too high",
			document:  `{"type":"http","server":"h","server_port":70000}`,
			wantField: "server_port",
			wantText:  "65535",
		},
		{
			name:      "http port zero",
			document:  `{"type":"http","server":"h","server_port":0}`,
			wantField: "server_port",
			wantText:  "1 and 65535",
		},
		{
			name:      "socks missing port",
			document:  `{"type":"socks","server":"h"}`,
			wantField: "server_port",
			wantText:  "1 and 65535",
		},
		{
			name:      "socks bad version",
			document:  `{"type":"socks","server":"h","server_port":1080,"version":"6"}`,
			wantField: "version",
			wantText:  "4, 4a or 5",
		},
		{
			name:      "shadowsocks missing method",
			document:  `{"type":"shadowsocks","server":"h","server_port":8388,"password":"p"}`,
			wantField: "method",
			wantText:  "required",
		},
		{
			name:      "shadowsocks unknown method",
			document:  `{"type":"shadowsocks","server":"h","server_port":8388,"method":"made-up","password":"p"}`,
			wantField: "method",
			wantText:  "unknown",
		},
		{
			name:      "shadowsocks missing password",
			document:  `{"type":"shadowsocks","server":"h","server_port":8388,"method":"aes-256-gcm"}`,
			wantField: "password",
			wantText:  "required",
		},
		{
			name:      "invalid server host",
			document:  `{"type":"http","server":"bad host","server_port":8080}`,
			wantField: "server",
			wantText:  "invalid server",
		},
		{
			name:      "shadowsocks 2022 short key",
			document:  `{"type":"shadowsocks","server":"h","server_port":8388,"method":"2022-blake3-aes-128-gcm","password":"c2VjcmV0"}`,
			wantField: "password",
			wantText:  "base64 of 16 bytes",
		},
		{
			name:      "shadowsocks method is case-sensitive",
			document:  `{"type":"shadowsocks","server":"h","server_port":8388,"method":"AES-256-GCM","password":"p"}`,
			wantField: "method",
			wantText:  "unknown shadowsocks method",
		},
		{
			name:      "shadowsocks unknown plugin",
			document:  `{"type":"shadowsocks","server":"h","server_port":8388,"method":"none","plugin":"mystery"}`,
			wantField: "plugin",
			wantText:  "unknown shadowsocks plugin",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, test.document)
			if result.OK {
				t.Fatalf("document accepted: %s", test.document)
			}
			if *result.Supported != true {
				t.Fatalf("supported = %v, want true for a supported type", result.Supported)
			}
			found := false
			for _, issue := range result.Issues {
				if issue.Field == test.wantField && strings.Contains(issue.Message, test.wantText) {
					found = true
					if issue.Severity != profileSeverityError {
						t.Fatalf("severity = %q, want error", issue.Severity)
					}
				}
			}
			if !found {
				t.Fatalf("no issue for field %q containing %q: %+v", test.wantField, test.wantText, result.Issues)
			}
		})
	}
}

func TestProfileValidateStoredWarningsDoNotBlock(t *testing.T) {
	tests := []struct {
		name     string
		document string
		field    string
	}{
		{
			name:     "http password without username",
			document: `{"type":"http","server":"h","server_port":8080,"password":"p"}`,
			field:    "password",
		},
		{
			name:     "socks password without username",
			document: `{"type":"socks","server":"h","server_port":1080,"password":"p"}`,
			field:    "password",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, test.document)
			if !result.OK {
				t.Fatalf("warning refused the document: %+v", result.Issues)
			}
			if len(result.Issues) != 1 || result.Issues[0].Field != test.field ||
				result.Issues[0].Severity != profileSeverityWarning {
				t.Fatalf("issues = %+v, want one warning on %q", result.Issues, test.field)
			}
		})
	}
}

// An http document with TLS and a shadowsocks document with a multiplex block
// are both modelled: the validator returns a verdict and the canonical
// normalized document.
func TestProfileValidateStoredTLSAndMultiplex(t *testing.T) {
	for _, tc := range []struct{ document, normalized string }{
		{
			`{"type":"http","server":"h","server_port":443,"tls":{"enabled":true}}`,
			`{"server":"h","server_port":443,"tls":{"enabled":true},"type":"http"}`,
		},
		{
			`{"type":"shadowsocks","server":"h","server_port":8388,"method":"aes-256-gcm","password":"p","multiplex":{"enabled":true,"protocol":"smux"}}`,
			`{"method":"aes-256-gcm","multiplex":{"enabled":true,"protocol":"smux"},"password":"p","server":"h","server_port":8388,"type":"shadowsocks"}`,
		},
	} {
		result := validateStoredProfileDocument(t, tc.document)
		if !result.OK || result.Supported == nil || !*result.Supported {
			t.Fatalf("%s: result = %+v", tc.document, result)
		}
		if result.Normalized != tc.normalized {
			t.Fatalf("%s: normalized = %s, want %s", tc.document, result.Normalized, tc.normalized)
		}
	}
}

func TestProfileValidateStoredUnsupportedDocuments(t *testing.T) {
	tests := []struct {
		name     string
		document string
		wantType string
	}{
		{
			name:     "unknown type",
			document: `{"type":"no-such-type","server":"h","server_port":443}`,
			wantType: "no-such-type",
		},
		{
			name:     "non-string headers",
			document: `{"type":"http","server":"h","server_port":8080,"headers":{"X":1}}`,
			wantType: "http",
		},
		{
			name:     "percent escaped host",
			document: `{"type":"http","server":"ex%61mple.com","server_port":8080}`,
			wantType: "http",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, test.document)
			if result.OK {
				t.Fatalf("unsupported document accepted: %s", test.document)
			}
			if result.Supported == nil || *result.Supported {
				t.Fatalf("supported = %v, want false", result.Supported)
			}
			if result.Normalized != "" {
				t.Fatalf("unsupported document came back normalized: %s", result.Normalized)
			}
			if len(result.Issues) != 1 {
				t.Fatalf("issues = %+v, want one fallback issue", result.Issues)
			}
			if !strings.Contains(result.Issues[0].Message, test.wantType) {
				t.Fatalf("issue does not name %q: %s", test.wantType, result.Issues[0].Message)
			}
		})
	}
}

func TestProfileValidateStoredReplyShape(t *testing.T) {
	result := validateStoredProfileDocument(t, `{"type":"socks","server":"x","server_port":1080}`)
	encoded, err := stdjson.Marshal(result)
	if err != nil {
		t.Fatalf("encode reply: %v", err)
	}
	var decoded map[string]any
	if err := stdjson.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("decode reply: %v", err)
	}
	for _, key := range []string{"ok", "issues", "supported", "normalized"} {
		if _, present := decoded[key]; !present {
			t.Fatalf("reply has no %q key: %s", key, encoded)
		}
	}
	if decoded["supported"] != true {
		t.Fatalf("supported = %v", decoded["supported"])
	}
}

func TestProfileValidateFormatSelector(t *testing.T) {
	document := `{"type":"socks","server":"x","server_port":1080}`
	kernelFormat := profileFormatKernel
	payload, err := stdjson.Marshal(profileDocumentRequest{JSON: &document, Format: &kernelFormat})
	if err != nil {
		t.Fatal(err)
	}
	answer, err := handleProfileValidate(payload)
	if err != nil {
		t.Fatalf("kernel format: %v", err)
	}
	kernelResult := answer.(profileValidateResult)
	if kernelResult.Supported != nil {
		t.Fatal("kernel format must not set supported")
	}
	// Explicit "kernel" is byte-identical to the default path.
	defaultResult := validateProfileDocument(t, document)
	kernelJSON, _ := stdjson.Marshal(kernelResult)
	defaultJSON, _ := stdjson.Marshal(defaultResult)
	if string(kernelJSON) != string(defaultJSON) {
		t.Fatalf("explicit kernel differs from default:\n%s\n%s", kernelJSON, defaultJSON)
	}

	unknown := "bogus"
	payload, err = stdjson.Marshal(profileDocumentRequest{JSON: &document, Format: &unknown})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := handleProfileValidate(payload); err == nil || !strings.Contains(err.Error(), "unknown format") {
		t.Fatalf("unknown format was not refused: %v", err)
	}
}

func TestProfileValidateKernelPathUnchanged(t *testing.T) {
	// The default format is still the kernel decoder: unknown envelope fields
	// are errors there, and the local semantic checks apply only to stored.
	result := validateProfileDocument(t, `{"type":"socks","server":"x","bogus":1}`)
	if result.OK || len(result.Issues) != 1 || result.Issues[0].Field != "bogus" {
		t.Fatalf("kernel decoder shape changed: %+v", result)
	}
	if !strings.Contains(result.Issues[0].Message, `unknown field "bogus"`) {
		t.Fatalf("kernel message changed: %s", result.Issues[0].Message)
	}
	// A stored document that is semantically invalid still passes the kernel
	// decoder — the two paths are independent. Missing credentials are a
	// stored-only check; the kernel's option struct accepts them.
	stored := validateStoredProfileDocument(t, `{"type":"shadowsocks","server":"h","server_port":8388,"method":"aes-256-gcm"}`)
	if stored.OK {
		t.Fatalf("stored validation accepted a missing password: %+v", stored.Issues)
	}
	kernel := validateProfileDocument(t, `{"type":"shadowsocks","server":"h","server_port":8388,"method":"aes-256-gcm"}`)
	if !kernel.OK {
		t.Fatalf("kernel decoder unexpectedly rejected missing credentials: %+v", kernel.Issues)
	}
}

func TestProfileValidateStoredTuicAnyTls(t *testing.T) {
	valid := []struct {
		name, document, normalized string
	}{
		{
			name:       "tuic",
			document:   `{"type":"tuic","server":"tuic.example.com","server_port":443,"uuid":"` + tuicTestUUID + `","password":"pass","congestion_control":"bbr","tls":{"enabled":true}}`,
			normalized: `{"congestion_control":"bbr","password":"pass","server":"tuic.example.com","server_port":443,"tls":{"enabled":true},"type":"tuic","uuid":"` + tuicTestUUID + `"}`,
		},
		{
			name:       "anytls",
			document:   `{"type":"anytls","server":"anytls.example.com","server_port":443,"password":"pass","tls":{"enabled":true}}`,
			normalized: `{"idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"password":"pass","server":"anytls.example.com","server_port":443,"tls":{"enabled":true},"type":"anytls"}`,
		},
	}
	for _, tc := range valid {
		t.Run(tc.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, tc.document)
			if *result.Supported != true || !result.OK || len(result.Issues) != 0 {
				t.Fatalf("valid document rejected: %+v", result)
			}
			if result.Normalized != tc.normalized {
				t.Fatalf("normalized = %s\nwant %s", result.Normalized, tc.normalized)
			}
		})
	}
	invalid := []struct {
		name, document, field, text string
	}{
		{"tuic missing uuid", `{"type":"tuic","server":"h","server_port":443}`, "uuid", "required"},
		{"tuic bad uuid", `{"type":"tuic","server":"h","server_port":443,"uuid":"nope"}`, "uuid", "valid UUID"},
		{"tuic bad heartbeat", `{"type":"tuic","server":"h","server_port":443,"uuid":"` + tuicTestUUID + `","heartbeat":"5"}`, "heartbeat", "duration"},
		{"tuic unknown congestion", `{"type":"tuic","server":"h","server_port":443,"uuid":"` + tuicTestUUID + `","congestion_control":"cubic-x"}`, "congestion_control", "cubic"},
		{"anytls missing password", `{"type":"anytls","server":"h","server_port":443}`, "password", "required"},
		{"anytls bad duration", `{"type":"anytls","server":"h","server_port":443,"password":"p","idle_session_timeout":" soon "}`, "idle_session_timeout", "duration"},
	}
	for _, tc := range invalid {
		t.Run(tc.name, func(t *testing.T) {
			result := validateStoredProfileDocument(t, tc.document)
			if *result.Supported != true || result.OK {
				t.Fatalf("invalid document accepted: %+v", result)
			}
			found := false
			for _, issue := range result.Issues {
				if issue.Field == tc.field && strings.Contains(issue.Message, tc.text) {
					found = true
				}
			}
			if !found {
				t.Fatalf("issues = %+v, want %s containing %q", result.Issues, tc.field, tc.text)
			}
		})
	}
	// Unknown fields answer supported:false, never a Go verdict.
	unsupported := validateStoredProfileDocument(t, `{"type":"tuic","server":"h","server_port":443,"uuid":"`+tuicTestUUID+`","future":1}`)
	if *unsupported.Supported != false || unsupported.OK {
		t.Fatalf("unknown field should fall back to Kotlin: %+v", unsupported)
	}
}
