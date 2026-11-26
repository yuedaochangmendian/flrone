package mobile

import (
	"encoding/json"
	"strings"
	"testing"
)

func scanRaw(t *testing.T, payload string) json.RawMessage {
	t.Helper()
	return json.RawMessage(payload)
}

func TestDecodeScanCheckRequestAcceptsTargets(t *testing.T) {
	request, err := decodeScanCheckRequest(scanRaw(t,
		`{"targets":["1.1.1.1:53","example.com:443"],"timeout_ms":3000}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got, want := strings.Join(request.Targets, ","), "1.1.1.1:53,example.com:443"; got != want {
		t.Fatalf("targets = %q, want %q", got, want)
	}
	if request.TimeoutMs != 3000 || request.DNS {
		t.Fatalf("timeout/dns = %d/%v, want 3000/false", request.TimeoutMs, request.DNS)
	}
}

func TestDecodeScanCheckRequestAcceptsDNSResolvers(t *testing.T) {
	request, err := decodeScanCheckRequest(scanRaw(t,
		`{"dns":true,"system_resolvers":["1.1.1.1","2606:4700:4700::1111"]}`))
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !request.DNS || len(request.SystemResolvers) != 2 {
		t.Fatalf("dns/resolvers = %v/%v", request.DNS, request.SystemResolvers)
	}
}

func TestDecodeScanCheckRequestRejectsBadInput(t *testing.T) {
	tests := []struct {
		name string
		raw  string
	}{
		{"empty payload", ``},
		{"null payload", `null`},
		{"malformed json", `{`},
		{"no targets", `{}`},
		{"dns with no resolvers", `{"dns":true}`},
		{"target without port", `{"targets":["1.1.1.1"]}`},
		{"empty target", `{"targets":[""]}`},
		{"resolver is a hostname", `{"dns":true,"system_resolvers":["dns.google"]}`},
		{"empty resolver", `{"dns":true,"system_resolvers":[""]}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := decodeScanCheckRequest(scanRaw(t, tc.raw)); err == nil {
				t.Fatalf("expected an error for %q", tc.raw)
			}
		})
	}
}

func TestDecodeScanCheckRequestRejectsTooManyEntries(t *testing.T) {
	targets := make([]string, maxCheckTargets+1)
	for i := range targets {
		targets[i] = "1.1.1.1:53"
	}
	payload, _ := json.Marshal(map[string]any{"targets": targets})
	if _, err := decodeScanCheckRequest(scanRaw(t, string(payload))); err == nil {
		t.Fatal("expected an error for more than the target limit")
	}
	resolvers := make([]string, maxCheckResolvers+1)
	for i := range resolvers {
		resolvers[i] = "1.1.1.1"
	}
	payload, _ = json.Marshal(map[string]any{"dns": true, "system_resolvers": resolvers})
	if _, err := decodeScanCheckRequest(scanRaw(t, string(payload))); err == nil {
		t.Fatal("expected an error for more than the resolver limit")
	}
}

func TestHandleScanCheckNetworkFoldsCoreVerdict(t *testing.T) {
	previous := invokeScanCheckNetwork
	t.Cleanup(func() { invokeScanCheckNetwork = previous })
	var seen string
	invokeScanCheckNetwork = func(requestJSON string) string {
		seen = requestJSON
		return `{"up":true,"error":"","system_resolvers":["1.1.1.1"]}`
	}
	result, err := handleScanCheckNetwork(scanRaw(t,
		`{"dns":true,"system_resolvers":["1.1.1.1"],"timeout_ms":2500}`))
	if err != nil {
		t.Fatalf("handle: %v", err)
	}
	response, ok := result.(scanCheckNetworkResponse)
	if !ok {
		t.Fatalf("result type = %T", result)
	}
	if !response.Up || response.Error != "" || len(response.SystemResolvers) != 1 || response.SystemResolvers[0] != "1.1.1.1" {
		t.Fatalf("response = %+v", response)
	}
	// The core is handed valid JSON with the same keys it decodes.
	var forwarded map[string]any
	if err := json.Unmarshal([]byte(seen), &forwarded); err != nil {
		t.Fatalf("forwarded request is not JSON: %v", err)
	}
	if forwarded["dns"] != true {
		t.Fatalf("forwarded dns = %v, want true", forwarded["dns"])
	}
}

func TestHandleScanCheckNetworkNormalizesResolverList(t *testing.T) {
	previous := invokeScanCheckNetwork
	t.Cleanup(func() { invokeScanCheckNetwork = previous })
	invokeScanCheckNetwork = func(string) string { return `{"up":false,"error":"no resolver answered"}` }
	result, err := handleScanCheckNetwork(scanRaw(t,
		`{"dns":true,"system_resolvers":["1.1.1.1"]}`))
	if err != nil {
		t.Fatalf("handle: %v", err)
	}
	response := result.(scanCheckNetworkResponse)
	if response.Up || response.Error == "" || response.SystemResolvers == nil || len(response.SystemResolvers) != 0 {
		t.Fatalf("response = %+v", response)
	}
}

func TestHandleScanCheckNetworkReportsCoreErrorJSONAsSuccess(t *testing.T) {
	previous := invokeScanCheckNetwork
	t.Cleanup(func() { invokeScanCheckNetwork = previous })
	invokeScanCheckNetwork = func(string) string {
		return `{"up":false,"error":"no network check target answered: dial tcp: x","system_resolvers":[]}`
	}
	result, err := handleScanCheckNetwork(scanRaw(t, `{"targets":["1.1.1.1:53"]}`))
	if err != nil {
		t.Fatalf("handle: %v", err)
	}
	response := result.(scanCheckNetworkResponse)
	if response.Up || !strings.Contains(response.Error, "no network check target answered") {
		t.Fatalf("response = %+v", response)
	}
}

func TestHandleScanCheckNetworkRejectsBadRequestWithoutCallingCore(t *testing.T) {
	previous := invokeScanCheckNetwork
	t.Cleanup(func() { invokeScanCheckNetwork = previous })
	called := false
	invokeScanCheckNetwork = func(string) string { called = true; return "{}" }
	for _, raw := range []string{``, `null`, `{`, `{}`, `{"targets":["1.1.1.1"]}`} {
		if _, err := handleScanCheckNetwork(scanRaw(t, raw)); err == nil {
			t.Fatalf("expected an error for %q", raw)
		}
	}
	if called {
		t.Fatal("the core check was invoked for a malformed request")
	}
}

func TestScanCheckNetworkMethodIsRegistered(t *testing.T) {
	if _, ok := actionHandlers[scanCheckNetworkMethod]; !ok {
		t.Fatalf("method %q is not registered", scanCheckNetworkMethod)
	}
}
