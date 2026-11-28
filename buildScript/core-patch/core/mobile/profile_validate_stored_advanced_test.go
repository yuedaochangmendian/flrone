package mobile

import "testing"

// TestProfileValidateStoredAdvanced pins the save gate for the five
// TLS/transport types whose Kotlin validators were deleted with the model.
func TestProfileValidateStoredAdvanced(t *testing.T) {
	cases := []struct {
		name       string
		document   string
		ok         bool
		field      string
		normalized bool
	}{
		{
			name:       "vless with credentials is accepted",
			document:   `{"server":"example.com","server_port":443,"tls":{"enabled":true},"type":"vless","uuid":"u","transport":{"type":"ws"}}`,
			ok:         true,
			normalized: true,
		},
		{
			name:     "vless without uuid is rejected",
			document: `{"server":"example.com","server_port":443,"type":"vless"}`,
			ok:       false, field: "uuid", normalized: true,
		},
		{
			name:     "vless without server is rejected",
			document: `{"server_port":443,"type":"vless","uuid":"u"}`,
			ok:       false, field: "server", normalized: true,
		},
		{
			name:     "vless vision over plain tcp without tls is rejected",
			document: `{"flow":"xtls-rprx-vision","server":"example.com","server_port":443,"type":"vless","uuid":"u"}`,
			ok:       false, field: "flow", normalized: true,
		},
		{
			name:       "vless vision over tls tcp is accepted",
			document:   `{"flow":"xtls-rprx-vision","server":"example.com","server_port":443,"tls":{"enabled":true},"type":"vless","uuid":"u"}`,
			ok:         true,
			normalized: true,
		},
		{
			name:     "vless bad packet encoding is rejected",
			document: `{"packet_encoding":"bad","server":"example.com","server_port":443,"type":"vless","uuid":"u"}`,
			ok:       false, normalized: false,
		},
		{
			name:       "vmess with credentials is accepted",
			document:   `{"security":"auto","server":"example.com","server_port":443,"type":"vmess","uuid":"u"}`,
			ok:         true,
			normalized: true,
		},
		{
			name:     "vmess bad security is rejected",
			document: `{"security":"rot13","server":"example.com","server_port":443,"type":"vmess","uuid":"u"}`,
			ok:       false, field: "security", normalized: true,
		},
		{
			name:     "trojan without password is rejected",
			document: `{"server":"example.com","server_port":443,"type":"trojan"}`,
			ok:       false, field: "password", normalized: true,
		},
		{
			name:       "hysteria2 with credentials is accepted",
			document:   `{"password":"p","server":"example.com","server_port":443,"tls":{},"type":"hysteria2"}`,
			ok:         true,
			normalized: true,
		},
		{
			name:       "hysteria server_ports replace the single port",
			document:   `{"server":"example.com","server_ports":["1000:2000","443:443"],"type":"hysteria"}`,
			ok:         true,
			normalized: true,
		},
		{
			name:     "hysteria reversed port range is rejected",
			document: `{"server":"example.com","server_ports":["2000:1000"],"type":"hysteria"}`,
			ok:       false, field: "server_ports", normalized: true,
		},
		{
			name:     "hysteria bad hop interval is rejected",
			document: `{"hop_interval":"soon","server":"example.com","server_port":443,"type":"hysteria"}`,
			ok:       false, field: "hop_interval", normalized: true,
		},
		{
			name:     "hysteria realm without stun is rejected",
			document: `{"realm":{"realm_id":"id","server_url":"https://realm.example.com"},"type":"hysteria2"}`,
			ok:       false, field: "realm", normalized: true,
		},
		{
			name:       "hysteria realm with a stun server is accepted",
			document:   `{"realm":{"realm_id":"id","server_url":"https://realm.example.com","stun_servers":["stun.example.com:3478"]},"type":"hysteria2"}`,
			ok:         true,
			normalized: true,
		},
		{
			name:     "advanced type with an unported field is a supported refusal",
			document: `{"future":1,"server":"example.com","server_port":443,"type":"vless","uuid":"u"}`,
			ok:       false, normalized: false,
		},
	}
	for _, testCase := range cases {
		t.Run(testCase.name, func(t *testing.T) {
			answer, err := handleProfileValidateStored(testCase.document)
			if err != nil {
				t.Fatalf("validate %s: %v", testCase.document, err)
			}
			result, ok := answer.(profileValidateResult)
			if !ok {
				t.Fatalf("answer type = %T", answer)
			}
			if result.Supported == nil || !*result.Supported {
				t.Fatalf("the advanced type must be supported, got %+v", result)
			}
			if result.OK != testCase.ok {
				t.Fatalf("ok = %v, want %v (issues %+v)", result.OK, testCase.ok, result.Issues)
			}
			if testCase.field != "" {
				found := false
				for _, issue := range result.Issues {
					if issue.Field == testCase.field && issue.Severity == profileSeverityError {
						found = true
					}
				}
				if !found {
					t.Fatalf("no %q error in %+v", testCase.field, result.Issues)
				}
			}
			if testCase.normalized && result.Normalized == "" {
				t.Fatalf("a supported document must carry its canonical form")
			}
			if !testCase.normalized && result.Normalized != "" {
				t.Fatalf("an unported field must not carry a half-canonical form: %s", result.Normalized)
			}
		})
	}
}

// TestProfileValidateStoredAdvancedVlessRegression is the reported bug: a
// plain vless node must save through the stored validator, not fall back to a
// validator that no longer exists.
func TestProfileValidateStoredAdvancedVlessRegression(t *testing.T) {
	document := `{"server":"example.com","server_port":443,"type":"vless","uuid":"2f6a5c9e-3b1d-4c2e-9a7f-1d2b3c4d5e6f"}`
	answer, err := handleProfileValidateStored(document)
	if err != nil {
		t.Fatal(err)
	}
	result := answer.(profileValidateResult)
	if result.Supported == nil || !*result.Supported {
		t.Fatalf("vless answered unsupported: %+v", result.Issues)
	}
	if !result.OK {
		t.Fatalf("a valid vless node was refused: %+v", result.Issues)
	}
	normalized, err := handleProfileNormalizeStored(document)
	if err != nil {
		t.Fatal(err)
	}
	if result.Normalized != normalized.(profileStoredNormalizeResult).JSON {
		t.Fatalf("vless canonical = %s", result.Normalized)
	}
}