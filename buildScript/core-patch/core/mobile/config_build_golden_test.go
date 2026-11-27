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
//	    build.json              build call overrides (selectedProfileId / mode / clock / expectError)
//	    expected.json           exact coreConfig string produced by ConfigGeneratorGoldenTest
//
// ConfigGeneratorGoldenTest (app/src/test/java/io/nekohasekai/sagernet/outbound/config/)
// generates and asserts expected.json; this test compares the Go builder's output with the same
// file byte for byte. There is no fallback generator and no second expectation file. An
// expectError case pins the generator's failure text instead (with an empty coreConfig).
//
// Run from a patched core tree as part of `go test`, or point FLRONE_CONFIG_GOLDEN_DIR at this
// repository's app/src/test/resources/config-golden when the patch has been copied elsewhere:
//
//	FLRONE_CONFIG_GOLDEN_DIR=<repo>/app/src/test/resources/config-golden go test ./core/mobile -run TestConfigBuildGoldenFixtures

// goCoreConfigBuilder is the Stage-3 entry point. It must read the case directory's
// profiles.json / settings.json / global_route_rules.json / build.json and return the exact
// coreConfig string the Go builder produces. Nil until the builder exists.
var goCoreConfigBuilder func(caseDir string) (string, error)

// Stage 2: the Go builder is in place. The adapter lives in non-test code
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
	// Error is set for an expectError case: the Kotlin generator's failure text,
	// with coreConfig empty.
	Error string `json:"error"`
}

// configGoBuilderStage is the highest builder stage this tree implements. A
// fixture's goStage is a reservation, not a version: a case is skipped until
// the stage that adds its support is in, and the PR that adds the support
// removes the marker. Stages 0-4 are already in (Stage 3 = WARP and custom full
// configs, Stage 4 = the DNS / route surface), Stage 5 adds auto-selectors.
const configGoBuilderStage = 5

// configGoBuilderRequirements maps a fixture's optional `requires` tokens onto
// what this builder implements. A token that is not listed skips the case, so a
// future cross-cutting requirement cannot silently pass.
var configGoBuilderRequirements = map[string]bool{
	"warp":     true,
	"c4":       true,
	"selector": true,
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
					"set FLRONE_CONFIG_GOLDEN_DIR when running the Go comparison: %v",
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
			// A fixture may reserve itself for a later builder stage. The oracle is
			// still committed now, so the case cannot be forgotten; the Go builder
			// must remove the marker in the PR that adds its support. Stages 0-2
			// and 4 are implemented here, stage 3 (WARP, custom full configs) is
			// now too, and stage 5 adds the auto-selector group.
			var buildMeta struct {
				GoStage  int      `json:"goStage"`
				Requires []string `json:"requires"`
			}
			if raw, err := os.ReadFile(filepath.Join(caseDir, "build.json")); err == nil {
				if err := json.Unmarshal(raw, &buildMeta); err != nil {
					t.Fatalf("parse build.json: %v", err)
				}
			}
			if buildMeta.GoStage > configGoBuilderStage {
				t.Skipf("fixture requires config builder stage %d; this builder is stage %d",
					buildMeta.GoStage, configGoBuilderStage)
			}
			for _, requirement := range buildMeta.Requires {
				if !configGoBuilderRequirements[requirement] {
					t.Skipf("fixture requires %q, which this builder does not implement", requirement)
				}
			}
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

			actual, buildErr := goCoreConfigBuilder(caseDir)
			if expected.Error != "" {
				// An expectError case pins the failure text, not a config; the
				// builder must fail with exactly the Kotlin oracle's message.
				if buildErr == nil {
					t.Fatalf("fixture expects the Kotlin error %q, but the Go builder returned %d bytes of config",
						expected.Error, len(actual))
				}
				if buildErr.Error() != expected.Error {
					t.Fatalf("Go builder error differs from the Kotlin oracle\nactual:   %q\nexpected: %q",
						buildErr.Error(), expected.Error)
				}
				return
			}
			if buildErr != nil {
				t.Fatalf("Go config builder failed: %v", buildErr)
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
