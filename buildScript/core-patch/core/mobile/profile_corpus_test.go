package mobile

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"testing"
)

// Stage 0 of the S5 stored-form export/import/validate parity harness.
//
// The fixtures are owned by the Kotlin oracle (ProfileCorpusTest):
//
//	app/src/test/resources/profile-corpus/<case>/
//	    input.txt       raw oracle input (stored JSON, share link, template type)
//	    case.json       descriptor: mode, source, format, context, formats,
//	                    expectError, include
//	    expected.json   frozen envelope written by ProfileCorpusTest in update mode:
//	                    {version, generatedBy, sha256, payload}
//
// This test validates the envelope and its SHA-256, so a hand-edited or stale
// expected.json cannot pass any of the three harnesses. The newOutbound mode is
// also compared byte-for-byte against the Go action; every other mode stays a
// deliberate no-op until its Go codec lands, so the harness stays green as the
// slices arrive.
//
// Run from a patched core tree as part of `go test`, or point
// FLRONE_PROFILE_CORPUS_DIR at this repository's
// app/src/test/resources/profile-corpus when the patch has been copied elsewhere:
//
//	FLRONE_PROFILE_CORPUS_DIR=<repo>/app/src/test/resources/profile-corpus \
//		go test ./mobile/ -run TestProfileCorpusFixtures -count=1

const (
	profileCorpusGeneratedBy = "ProfileCorpusTest"
	profileCorpusVersion     = 1
)

var profileCorpusModes = map[string]bool{
	"import": true, "export": true, "validate": true, "newOutbound": true, "migrate": true,
}

type profileCorpusDescriptor struct {
	Mode        string   `json:"mode"`
	Source      string   `json:"source"`
	Format      string   `json:"format"`
	Context     string   `json:"context"`
	Formats     []string `json:"formats"`
	ExpectError bool     `json:"expectError"`
	Include     bool     `json:"include"`
}

type profileCorpusEnvelope struct {
	Version     int             `json:"version"`
	GeneratedBy string          `json:"generatedBy"`
	SHA256      string          `json:"sha256"`
	Payload     json.RawMessage `json:"payload"`
}

// profileCorpusFixtureRoot answers the fixture directory and whether it came
// from FLRONE_PROFILE_CORPUS_DIR. The patched core tree is normally assembled
// outside this repository, so the implicit path only exists when the patch is
// applied in place.
func profileCorpusFixtureRoot(t *testing.T) (string, bool) {
	t.Helper()
	if dir := os.Getenv("FLRONE_PROFILE_CORPUS_DIR"); dir != "" {
		return dir, true
	}
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve the profile-corpus fixture path via runtime.Caller")
	}
	// buildScript/core-patch/core/mobile -> repository root.
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "app", "src", "test", "resources", "profile-corpus"), false
}

// canonicalProfileCorpusJSON re-serialises the frozen payload the same way the
// Python checker does (sorted keys, no whitespace) before hashing, so an edit
// to either envelope or payload without a matching sha256 is caught.
func canonicalProfileCorpusJSON(raw json.RawMessage) ([]byte, error) {
	var value any
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, err
	}
	return canonicalJSONValue(value)
}

func canonicalJSONValue(value any) ([]byte, error) {
	switch v := value.(type) {
	case map[string]any:
		keys := make([]string, 0, len(v))
		for k := range v {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		out := []byte{'{'}
		for i, k := range keys {
			if i > 0 {
				out = append(out, ',')
			}
			encodedKey, err := canonicalProfileCorpusString(k)
			if err != nil {
				return nil, err
			}
			out = append(out, encodedKey...)
			out = append(out, ':')
			child, err := canonicalJSONValue(v[k])
			if err != nil {
				return nil, err
			}
			out = append(out, child...)
		}
		return append(out, '}'), nil
	case []any:
		out := []byte{'['}
		for i, item := range v {
			if i > 0 {
				out = append(out, ',')
			}
			child, err := canonicalJSONValue(item)
			if err != nil {
				return nil, err
			}
			out = append(out, child...)
		}
		return append(out, ']'), nil
	default:
		return canonicalProfileCorpusStringValue(v)
	}
}

// canonicalProfileCorpusString encodes a string without encoding/json's HTML
// escaping (of &, <, >). The Python checker and the Kotlin oracle both emit
// those characters verbatim, so the SHA must match their bytes.
func canonicalProfileCorpusString(s string) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

// canonicalProfileCorpusStringValue encodes an arbitrary scalar with the same
// no-HTML-escape rule, keeping integers/floats/bools/null exactly as encoding/json
// writes them.
func canonicalProfileCorpusStringValue(value any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(value); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n")), nil
}

func TestProfileCorpusFixtures(t *testing.T) {
	root, explicitRoot := profileCorpusFixtureRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		if !explicitRoot && testing.Short() {
			t.Skipf(
				"the shared profile-corpus fixtures are not reachable at %s; "+
					"set FLRONE_PROFILE_CORPUS_DIR=<repo>/app/src/test/resources/profile-corpus (or drop -short): %v",
				root, err,
			)
		}
		t.Fatalf(
			"the shared profile-corpus fixtures are not reachable at %s; "+
				"set FLRONE_PROFILE_CORPUS_DIR=<repo>/app/src/test/resources/profile-corpus: %v",
			root, err,
		)
	}

	cases := 0
	included := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		cases++
		caseDir := filepath.Join(root, entry.Name())
		t.Run(entry.Name(), func(t *testing.T) {
			input, err := os.ReadFile(filepath.Join(caseDir, "input.txt"))
			if err != nil {
				t.Fatalf("read input.txt: %v", err)
			}
			metaRaw, err := os.ReadFile(filepath.Join(caseDir, "case.json"))
			if err != nil {
				t.Fatalf("read case.json: %v", err)
			}
			var meta profileCorpusDescriptor
			if err := json.Unmarshal(metaRaw, &meta); err != nil {
				t.Fatalf("parse case.json: %v", err)
			}
			if !profileCorpusModes[meta.Mode] {
				t.Fatalf("case.json mode %q is not one of import/export/validate/newOutbound/migrate", meta.Mode)
			}
			if meta.Context != "" && meta.Context != "default" && meta.Context != "android-resources" {
				t.Fatalf("case.json context %q is not a known context", meta.Context)
			}
			if !meta.Include {
				// Excluded placeholders document cases the JVM oracle cannot
				// produce without Android resources; no expected.json is frozen.
				if _, err := os.Stat(filepath.Join(caseDir, "expected.json")); err == nil {
					t.Fatal("include=false but expected.json exists (stale fixture)")
				}
				return
			}
			included++

			raw, err := os.ReadFile(filepath.Join(caseDir, "expected.json"))
			if err != nil {
				t.Fatalf("read expected.json: %v", err)
			}
			var envelope profileCorpusEnvelope
			if err := json.Unmarshal(raw, &envelope); err != nil {
				t.Fatalf("parse expected.json: %v", err)
			}
			if envelope.Version != profileCorpusVersion {
				t.Fatalf("expected.json version = %d, want %d", envelope.Version, profileCorpusVersion)
			}
			if envelope.GeneratedBy != profileCorpusGeneratedBy {
				t.Fatalf(
					"expected.json was not produced by %s (got %q) -- hand-written or stale",
					profileCorpusGeneratedBy, envelope.GeneratedBy,
				)
			}
			payload, err := canonicalProfileCorpusJSON(envelope.Payload)
			if err != nil {
				t.Fatalf("canonicalise payload: %v", err)
			}
			sum := sha256.Sum256(payload)
			digest := hex.EncodeToString(sum[:])
			if digest != envelope.SHA256 {
				t.Fatalf("expected.json sha256 = %s, want %s (payload edited by hand?)", envelope.SHA256, digest)
			}
			if meta.ExpectError {
				var shape map[string]any
				if err := json.Unmarshal(envelope.Payload, &shape); err != nil {
					t.Fatalf("parse payload: %v", err)
				}
				if shape["error"] != true {
					t.Fatal("expectError=true but the payload pins no error")
				}
			}

			// New-outbound templates are compared against the Go action; every
			// other mode stays the no-op seam until its Go codec lands.
			compareProfileCorpusPayload(t, &meta, string(input), envelope.Payload)
		})
	}
	if cases == 0 {
		t.Fatalf("no profile-corpus fixture directories under %s", root)
	}
	if included == 0 {
		t.Fatalf("no included profile-corpus cases under %s", root)
	}
}

// compareProfileCorpusPayload is the byte-comparison seam for the Go codec.
// newOutbound is the first (and currently only) covered mode: the frozen
// payload's `json` is the Kotlin blank stored document, and profileNewOutbound
// answers exactly that byte string. Every other mode remains a no-op until its
// Go codec lands; the frozen envelope and its SHA are still validated above.
func compareProfileCorpusPayload(t *testing.T, meta *profileCorpusDescriptor, input string, payload json.RawMessage) {
	t.Helper()
	if meta.Mode != "newOutbound" {
		return
	}
	outboundType := strings.TrimSpace(input)
	payloadBytes, err := json.Marshal(profileNewOutboundRequest{Type: outboundType})
	if err != nil {
		t.Fatalf("encode newOutbound payload: %v", err)
	}
	answer, actionErr := handleProfileNewOutbound(payloadBytes)
	if meta.ExpectError {
		if actionErr == nil {
			t.Fatalf("the frozen payload pins a refusal, but Go templated %q", outboundType)
		}
		return
	}
	var frozen struct {
		Type    string `json:"type"`
		JSON    string `json:"json"`
		Invalid bool   `json:"invalid"`
	}
	if err := json.Unmarshal(payload, &frozen); err != nil {
		t.Fatalf("parse frozen newOutbound payload: %v", err)
	}
	if frozen.Invalid {
		t.Fatalf("the frozen payload is an invalid outbound: %s", payload)
	}
	if actionErr != nil {
		t.Fatalf("Go refused %q: %v", outboundType, actionErr)
	}
	result, ok := answer.(profileJSONResult)
	if !ok {
		t.Fatalf("handleProfileNewOutbound answered %T", answer)
	}
	if result.JSON != frozen.JSON {
		t.Fatalf("Go template = %s\nKotlin      %s", result.JSON, frozen.JSON)
	}
	object, ok := configDecodeJSONObject(result.JSON)
	if !ok {
		t.Fatalf("template is not a JSON object: %s", result.JSON)
	}
	if got := configJSONString(object, "type"); got != frozen.Type {
		t.Fatalf("template type = %q, Kotlin type = %q", got, frozen.Type)
	}
}
