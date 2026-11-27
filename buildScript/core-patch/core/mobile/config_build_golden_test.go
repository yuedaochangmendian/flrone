package mobile

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// Stage 0 of the config.build migration: the Go side of the golden harness.
//
// The fixtures are owned by the Kotlin oracle:
//
//	app/src/test/resources/config-golden/<case>/
//	    profiles.json           Dart-owned profile document
//	    settings.json           Kotlin-owned settings document
//	    global_route_rules.json Go-owned global rule table
//	    build.json              selectedProfileId / deferRuleSets / mode overrides
//	    expected.json           exact coreConfig string produced by ConfigGeneratorGoldenTest
//
// ConfigGeneratorGoldenTest (app/src/test/java/io/nekohasekai/sagernet/outbound/config/)
// generates and asserts expected.json today. This skeleton is deliberately inert: when the Go
// config builder lands, set goCoreConfigBuilder and this test compares its output with the same
// expected.json byte for byte. There is no fallback generator and no second expectation file.
//
// Run from a patched core tree as part of `go test`, or point FLRONE_CONFIG_GOLDEN_DIR at this
// repository's app/src/test/resources/config-golden when the patch has been copied elsewhere:
//
//	FLRONE_CONFIG_GOLDEN_DIR=<repo>/app/src/test/resources/config-golden go test ./core/mobile -run TestConfigBuildGoldenFixtures

// goCoreConfigBuilder is the Stage-1 entry point. It must read the case directory's
// profiles.json / settings.json / global_route_rules.json / build.json and return the exact
// coreConfig string the Go builder produces. Nil until the builder exists.
var goCoreConfigBuilder func(caseDir string) (string, error)

// Stage 1: the Go builder is in place. The adapter lives in non-test code
// (config_build_fixture.go); this file only installs it for the harness, which
// keeps the seam test-only without a production wire-up.
func init() {
	goCoreConfigBuilder = buildCoreConfigFromFixtureDir
}

// configGoldenDocument is the oracle wrapper written by ConfigGeneratorGoldenTest and copied to
// expected.json by tools/diagnostics/config_golden.py --update.
type configGoldenDocument struct {
	Version     int    `json:"version"`
	GeneratedBy string `json:"generatedBy"`
	SHA256      string `json:"sha256"`
	CoreConfig  string `json:"coreConfig"`
}

// configGoldenFixtureRoot answers the fixture directory and whether it came
// from FLRONE_CONFIG_GOLDEN_DIR. The patched core tree is normally assembled
// outside this repository (CI copies the overlay into a Throne checkout), so
// the implicit path only exists when the patch is applied in place.
func configGoldenFixtureRoot(t *testing.T) (string, bool) {
	t.Helper()
	if dir := os.Getenv("FLRONE_CONFIG_GOLDEN_DIR"); dir != "" {
		return dir, true
	}
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot resolve the config-golden fixture path via runtime.Caller")
	}
	// buildScript/core-patch/core/mobile -> repository root.
	return filepath.Join(filepath.Dir(file), "..", "..", "..", "..", "app", "src", "test", "resources", "config-golden"), false
}

func TestConfigBuildGoldenFixtures(t *testing.T) {
	root, explicitRoot := configGoldenFixtureRoot(t)
	entries, err := os.ReadDir(root)
	if err != nil {
		if explicitRoot {
			t.Fatalf("read the config-golden fixtures FLRONE_CONFIG_GOLDEN_DIR points at (%s): %v", root, err)
		}
		if goCoreConfigBuilder == nil {
			t.Skipf(
				"config.build has no Go builder yet (Stage 0) and the shared fixtures are not reachable at %s; "+
					"set FLRONE_CONFIG_GOLDEN_DIR when running the Stage-1 comparison: %v",
				root, err,
			)
		}
		t.Skipf(
			"the shared config-golden fixtures are not part of this assembled core tree (%s); "+
				"set FLRONE_CONFIG_GOLDEN_DIR=<repo>/app/src/test/resources/config-golden to run the byte-for-byte comparison: %v",
			root, err,
		)
	}

	required := []string{"profiles.json", "settings.json", "global_route_rules.json", "build.json", "expected.json"}
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
		t.Fatalf("no config-golden fixture directories under %s", root)
	}

	if goCoreConfigBuilder == nil {
		t.Skipf(
			"config.build has no Go builder yet (Stage 0); %d fixture(s) validated at %s, "+
				"expected.json is the Kotlin ConfigGeneratorGoldenTest oracle and will be the byte-for-byte comparison target",
			cases, root,
		)
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		t.Run(entry.Name(), func(t *testing.T) {
			caseDir := filepath.Join(root, entry.Name())
			raw, err := os.ReadFile(filepath.Join(caseDir, "expected.json"))
			if err != nil {
				t.Fatalf("read expected.json: %v", err)
			}
			var expected configGoldenDocument
			if err := json.Unmarshal(raw, &expected); err != nil {
				t.Fatalf("parse expected.json: %v", err)
			}
			if expected.GeneratedBy != "ConfigGeneratorGoldenTest" {
				t.Fatalf("expected.json was not generated by the Kotlin oracle: generatedBy=%q", expected.GeneratedBy)
			}

			actual, err := goCoreConfigBuilder(caseDir)
			if err != nil {
				t.Fatalf("Go config builder failed: %v", err)
			}
			if actual == expected.CoreConfig {
				return
			}
			offset := 0
			for offset < len(actual) && offset < len(expected.CoreConfig) && actual[offset] == expected.CoreConfig[offset] {
				offset++
			}
			t.Fatalf(
				"coreConfig differs from the Kotlin oracle at byte offset %d (actual %d bytes, expected %d bytes)\nactual:   %s\nexpected: %s",
				offset, len(actual), len(expected.CoreConfig), excerpt(actual, offset), excerpt(expected.CoreConfig, offset),
			)
		})
	}
}

// excerpt shows a small window around the first differing byte.
func excerpt(text string, offset int) string {
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
