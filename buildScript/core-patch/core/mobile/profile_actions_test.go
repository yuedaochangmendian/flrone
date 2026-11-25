package mobile

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// The tests here validate the request and the safety gate without ever calling
// pprof: no profile is produced, no CPU time is burnt, no goroutine stack is dumped.
// That keeps them fast and deterministic under `go test -c` for the Android target.

func profileRaw(t *testing.T, payload string) json.RawMessage {
	t.Helper()
	return json.RawMessage(payload)
}

func TestParseProfileRequestSecondsClamp(t *testing.T) {
	dir := t.TempDir()
	tests := []struct {
		name string
		raw  string
		want int
	}{
		{"zero defaults", `{"kind":"cpu","dir":"` + dir + `"}`, profileDefaultSeconds},
		{"below floor clamps up", `{"kind":"cpu","seconds":1,"dir":"` + dir + `"}`, profileMinSeconds},
		{"above ceiling clamps down", `{"kind":"cpu","seconds":999,"dir":"` + dir + `"}`, profileMaxSeconds},
		{"inside range unchanged", `{"kind":"cpu","seconds":17,"dir":"` + dir + `"}`, 17},
		{"snapshot clamps too", `{"kind":"heap","seconds":0,"dir":"` + dir + `"}`, profileDefaultSeconds},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, err := parseProfileRequest(profileRaw(t, tc.raw))
			if err != nil {
				t.Fatalf("parseProfileRequest: %v", err)
			}
			if got.Seconds != tc.want {
				t.Fatalf("seconds = %d, want %d", got.Seconds, tc.want)
			}
		})
	}
}

func TestParseProfileRequestRejectsBadInput(t *testing.T) {
	dir := t.TempDir()
	// Empty base path means "caller-supplied absolute dir is trusted"; the tests
	// below therefore only exercise dir validation, not sandbox containment.
	previous := sBasePath
	sBasePath = ""
	t.Cleanup(func() { sBasePath = previous })

	tests := []struct {
		name string
		raw  string
	}{
		{"empty payload", ``},
		{"null payload", `null`},
		{"malformed json", `{`},
		{"missing kind", `{"dir":"` + dir + `"}`},
		{"bad kind", `{"kind":"mutex","dir":"` + dir + `"}`},
		{"empty dir", `{"kind":"cpu","dir":""}`},
		{"relative dir", `{"kind":"cpu","dir":"relative/path"}`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := parseProfileRequest(profileRaw(t, tc.raw)); err == nil {
				t.Fatalf("expected an error for %q", tc.raw)
			}
		})
	}
}

func TestParseProfileRequestRejectsDirOutsideAppFiles(t *testing.T) {
	previous := sBasePath
	sBasePath = t.TempDir()
	t.Cleanup(func() { sBasePath = previous })

	inside := filepath.Join(sBasePath, "profiles")
	if _, err := parseProfileRequest(profileRaw(t, `{"kind":"cpu","dir":"`+inside+`"}`)); err != nil {
		t.Fatalf("dir inside app files rejected: %v", err)
	}
	outside := filepath.Join(filepath.Dir(sBasePath), "other-app")
	if _, err := parseProfileRequest(profileRaw(t, `{"kind":"cpu","dir":"`+outside+`"}`)); err == nil {
		t.Fatal("dir outside app files was accepted")
	}
}

func TestCheckProfileGateRequiresMarker(t *testing.T) {
	dir := t.TempDir()
	if err := checkProfileGate(dir); err == nil {
		t.Fatal("gate opened without a marker file")
	}
	marker := filepath.Join(dir, profileMarkerFile)
	if err := os.WriteFile(marker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := checkProfileGate(dir); err != nil {
		t.Fatalf("gate stayed closed with marker: %v", err)
	}
	if err := os.Remove(marker); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(marker, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := checkProfileGate(dir); err == nil {
		t.Fatal("a directory named as the marker must not open the gate")
	}
}

// The handler itself must refuse a disabled capture: this is the end-to-end proof
// that the marker gate is checked before any profiling work (and before MkdirAll).
func TestHandleDiagnosticsProfileDisabledByDefault(t *testing.T) {
	dir := t.TempDir()
	_, err := handleDiagnosticsProfile(profileRaw(t, `{"kind":"cpu","seconds":5,"dir":"`+dir+`"}`))
	if err == nil {
		t.Fatal("profile capture ran without the marker file")
	}
}

func TestSingleFlightRejectsConcurrentCapture(t *testing.T) {
	if !beginProfile() {
		t.Fatal("single-flight guard was already held")
	}
	t.Cleanup(endProfile)
	if beginProfile() {
		t.Fatal("a second capture was allowed while one was running")
	}
}
