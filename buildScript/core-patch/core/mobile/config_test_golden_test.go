package mobile

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// Stage 6b of the config.build migration: the Go side of the buildTest golden
// harness.
//
// The fixtures are owned by the Kotlin oracle:
//
//	app/src/test/resources/config-test-golden/<case>/
//	    profiles.json     Dart-owned profile document (groups carry the
//	                      landing / front proxy of a candidate)
//	    settings.json     Kotlin-owned settings document
//	    build_test.json   the call: profileIds plus an optional goStage marker
//	    expected.json     the exact envelope ConfigTestGoldenTest commits:
//	                      coreConfig + SHA-256, ordered outboundTags /
//	                      tagToProfileId / fullConfigs / skipped, tunIPv4Cidr,
//	                      involvedProfileIds and error
//
// ConfigTestGoldenTest (app/src/test/java/io/nekohasekai/sagernet/bg/proto/)
// drives the production seam CoreConfigs.buildTest and is the only writer of
// expected.json (through tools/diagnostics/config_golden.py --suite test
// --update). This test compares its Go counterpart with the same file byte for
// byte: there is no fallback generator and no second expectation file.
//
// Run from a patched core tree as part of `go test`, or point
// FLRONE_CONFIG_TEST_GOLDEN_DIR at this repository's
// app/src/test/resources/config-test-golden when the patch has been copied
// elsewhere:
//
//	FLRONE_CONFIG_TEST_GOLDEN_DIR=<repo>/app/src/test/resources/config-test-golden \
//	  go test ./mobile -run TestConfigTestGoldenFixtures -count=1

// goTestConfigBuilder is the Stage-6b entry point: read one case directory and
// return the exact expected.json text of the Go buildTest envelope. Nil until
// the builder exists; the harness installs it below so the seam stays
// test-only, like goCoreConfigBuilder.
var goTestConfigBuilder func(caseDir string) (string, error)

// The builder is buildTestCoreConfig in config_build_test.go, an exact port of
// ConfigGenerator.buildTest; the adapter is config_test_fixture.go.
func init() {
	goTestConfigBuilder = func(caseDir string) (string, error) {
		return buildTestEnvelopeFromFixtureDir(caseDir, buildTestCoreConfig)
	}
}

// configTestGoldenDocument is the envelope wrapper written by
// ConfigTestGoldenTest.
type configTestGoldenDocument struct {
	Version     int    `json:"version"`
	GeneratedBy string `json:"generatedBy"`
	SHA256      string `json:"sha256"`
	CoreConfig  string `json:"coreConfig"`
}

// configTestGoldenFixtureRoot answers the fixture directory and whether it came
// from FLRONE_CONFIG_TEST_GOLDEN_DIR. The patched core tree is normally
// assembled outside this repository (CI copies the overlay into a Throne
// checkout), so the implicit path only exists when the patch is applied in
// place.
func configTestGoldenFixtureRoot(t *testing.T) (string, bool) {
	t.Helper()
	if dir := os.Getenv("FLRONE_CONFIG_TEST_GOLDEN_DIR"); dir != "" {
		return dir, true
	}
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve the config-test-golden fixture path via runtime.Caller")
	}
	// buildScript/core-patch/core/mobile -> repository root.
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "app", "src", "test", "resources", "config-test-golden"), false
}

func TestConfigTestGoldenFixtures(t *testing.T) {
	root, explicitRoot := configTestGoldenFixtureRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		if explicitRoot {
			t.Fatalf("read the config-test-golden fixtures FLRONE_CONFIG_TEST_GOLDEN_DIR points at (%s): %v", root, err)
		}
		if goTestConfigBuilder == nil {
			t.Skipf(
				"buildTest has no Go builder yet and the shared fixtures are not reachable at %s; "+
					"set FLRONE_CONFIG_TEST_GOLDEN_DIR when running the Go comparison: %v",
				root, err,
			)
		}
		t.Skipf(
			"the shared config-test-golden fixtures are not part of this assembled core tree (%s); "+
				"set FLRONE_CONFIG_TEST_GOLDEN_DIR=<repo>/app/src/test/resources/config-test-golden "+
				"to run the byte-for-byte comparison: %v",
			root, err,
		)
	}

	required := []string{"profiles.json", "settings.json", "build_test.json", "expected.json"}
	cases := 0
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		cases++
		caseDir := filepath.Join(root, entry.Name())
		for _, name := range required {
			if _, err := os.Stat(filepath.Join(caseDir, name)); err != nil {
				t.Fatalf("fixture %s is missing %s: %v", entry.Name(), name, err)
			}
		}
	}
	if cases == 0 {
		t.Fatalf("no config-test-golden fixture directories under %s", root)
	}

	if goTestConfigBuilder == nil {
		t.Skipf("buildTest has no Go builder yet; %d fixture(s) validated at %s", cases, root)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		t.Run(entry.Name(), func(t *testing.T) {
			caseDir := filepath.Join(root, entry.Name())
			// A fixture may reserve itself for a later builder stage. The oracle
			// is already committed, so the case cannot be forgotten; the Go
			// builder must remove the marker in the change that adds its support.
			var buildFile struct {
				GoStage int `json:"goStage"`
			}
			if raw, err := os.ReadFile(filepath.Join(caseDir, "build_test.json")); err == nil {
				if err := json.Unmarshal(raw, &buildFile); err != nil {
					t.Fatalf("parse build_test.json: %v", err)
				}
			}
			if buildFile.GoStage > 6 {
				t.Skipf("fixture requires buildTest builder stage %d; this builder is stage 6", buildFile.GoStage)
			}

			raw, err := os.ReadFile(filepath.Join(caseDir, "expected.json"))
			if err != nil {
				t.Fatalf("read expected.json: %v", err)
			}
			var expected configTestGoldenDocument
			if err := json.Unmarshal(raw, &expected); err != nil {
				t.Fatalf("parse expected.json: %v", err)
			}
			if expected.GeneratedBy != configTestGeneratedBy {
				t.Fatalf("expected.json was not generated by the Kotlin oracle: generatedBy=%q", expected.GeneratedBy)
			}
			if expected.SHA256 != configTestSHA256(expected.CoreConfig) {
				t.Fatalf("expected.json sha256 does not match its coreConfig (edited by hand?)")
			}

			actual, err := goTestConfigBuilder(caseDir)
			if err != nil {
				t.Fatalf("Go buildTest builder failed: %v", err)
			}
			if actual == string(raw) {
				return
			}
			offset := 0
			for offset < len(actual) && offset < len(raw) && actual[offset] == raw[offset] {
				offset++
			}
			t.Fatalf(
				"envelope differs from the Kotlin oracle at byte offset %d (actual %d bytes, expected %d bytes)\nactual:   %s\nexpected: %s",
				offset, len(actual), len(raw), configTestExcerpt(actual, offset), configTestExcerpt(string(raw), offset),
			)
		})
	}
}

// configTestExcerpt shows a small window around the first differing byte.
func configTestExcerpt(text string, offset int) string {
	start := offset - 24
	if start < 0 {
		start = 0
	}
	end := offset + 24
	if end > len(text) {
		end = len(text)
	}
	return fmt.Sprintf("%q", text[start:end])
}
