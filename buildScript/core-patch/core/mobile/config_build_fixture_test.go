// The fixture-facing half of the config builder: load one
// app/src/test/resources/config-golden/<case>/ directory through the existing
// read-only document readers and run the builder over it.
//
// The fixture documents sit side by side (the Kotlin oracle points its three
// stores at the case directory), so the loaders take the directory explicitly
// instead of resolving <basePath>/documents. build.json's mode / deferRuleSets
// reproduce ConfigGeneratorGoldenTest's case-level overrides.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// configFixtureBuildFile is build.json: the call arguments the Kotlin oracle
// passes to ConfigGenerator.build, plus the fixture's own determinism inputs.
type configFixtureBuildFile struct {
	SelectedProfileID int64  `json:"selectedProfileId"`
	DeferRuleSets     bool   `json:"deferRuleSets"`
	Mode              string `json:"mode"`
	LandingProxyID    *int64 `json:"landingProxyId"`
	FrontProxyID      *int64 `json:"frontProxyId"`
	GroupName         string `json:"groupName"`
	// ClockUnixSeconds pins ConfigGenerator's clock for an auto-selector case
	// (result freshness and warm-health ages); absent means wall time.
	ClockUnixSeconds *int64 `json:"clockUnixSeconds"`
	// ExpectError marks a case whose expected.json pins the failure text.
	ExpectError bool `json:"expectError"`
	// GoStage / Requires reserve a case for a later Go builder stage.
	GoStage  int      `json:"goStage"`
	Requires []string `json:"requires"`
}

// buildCoreConfigFromFixtureDir is goCoreConfigBuilder: the exact coreConfig
// string for one config-golden case directory.
func buildCoreConfigFromFixtureDir(caseDir string) (string, error) {
	inputs, request, err := loadConfigBuildFixture(caseDir)
	if err != nil {
		return "", err
	}
	return buildSimpleCoreConfig(inputs, request)
}

func loadConfigBuildFixture(caseDir string) (*simpleConfigInputs, configBuildRequest, error) {
	buildFile, err := readConfigFixtureBuildFile(caseDir)
	if err != nil {
		return nil, configBuildRequest{}, err
	}
	if buildFile.SelectedProfileID <= 0 {
		return nil, configBuildRequest{}, fmt.Errorf("build.json selectedProfileId must be a profile id")
	}
	mode := serviceMode("")
	switch buildFile.Mode {
	case "":
		// The settings document's serviceMode wins.
	case string(serviceModeVPN), string(serviceModeProxy):
		mode = serviceMode(buildFile.Mode)
	default:
		return nil, configBuildRequest{}, fmt.Errorf("build.json mode must be %q or %q, not %q",
			serviceModeVPN, serviceModeProxy, buildFile.Mode)
	}

	profiles, err := readProfilesDocumentAt(caseDir)
	if err != nil {
		return nil, configBuildRequest{}, err
	}
	settingsRows, _, err := readDocumentAt(caseDir, settingsDocumentName)
	if err != nil {
		return nil, configBuildRequest{}, fmt.Errorf("read %s.json: %w", settingsDocumentName, err)
	}
	settingsValues := settingsRowsByKey(settingsRows)
	if buildFile.Mode != "" {
		// ConfigGeneratorGoldenTest.applyServiceMode rewrites the settings row
		// before DataStore reads it, so mixedInboundDisabled derives from it too.
		settingsValues["serviceMode"] = buildFile.Mode
	}
	settings := loadSimpleConfigSettingsFromValues(settingsValues)
	allProfiles, err := simpleConfigProfilesFromDocument(profiles)
	if err != nil {
		return nil, configBuildRequest{}, err
	}
	selection, err := simpleConfigSelectionFromProfiles(allProfiles, profiles.Groups, settingsValues)
	if err != nil {
		return nil, configBuildRequest{}, err
	}

	routeRows, _, err := readGlobalRulesIn(caseDir)
	if err != nil {
		return nil, configBuildRequest{}, fmt.Errorf("read %s.json: %w", globalRulesDoc, err)
	}
	routeRules := make([]simpleConfigRouteRule, 0, len(routeRows))
	for _, ruleRow := range routeRows {
		routeRules = append(routeRules, simpleConfigRouteRuleFromRow(ruleRow))
	}
	catalog, err := readSimpleRuleSetCatalogFile(filepath.Join(caseDir, routeProfilesDirName, srsListFileName))
	if err != nil {
		return nil, configBuildRequest{}, err
	}

	if buildFile.Mode == "" {
		documentMode := serviceMode(configSettingStringValue(settingsValues, "serviceMode"))
		if documentMode == serviceModeVPN || documentMode == serviceModeProxy {
			mode = documentMode
		}
	}
	if mode != serviceModeVPN && mode != serviceModeProxy {
		mode = serviceModeVPN
	}
	outbound := outboundMode(configSettingStringValue(settingsValues, "bbox_outbound_mode"))
	if outbound != outboundModeRule && outbound != outboundModeGlobal && outbound != outboundModeDirect {
		outbound = outboundModeRule
	}

	landing := int64(-1)
	if buildFile.LandingProxyID != nil {
		landing = *buildFile.LandingProxyID
	}
	front := int64(-1)
	if buildFile.FrontProxyID != nil {
		front = *buildFile.FrontProxyID
	}
	request := configBuildRequest{
		profileID:      buildFile.SelectedProfileID,
		landingProxyID: landing,
		frontProxyID:   front,
		groupName:      buildFile.GroupName,
		deferRuleSets:  buildFile.DeferRuleSets,
	}
	if buildFile.ClockUnixSeconds != nil {
		request.clock = *buildFile.ClockUnixSeconds
		request.clockSet = true
	}
	inputs := &simpleConfigInputs{
		Selection:      selection,
		Profiles:       allProfiles,
		Groups:         profiles.Groups,
		Settings:       settings,
		Mode:           mode,
		OutboundMode:   outbound,
		DeferRuleSets:  buildFile.DeferRuleSets,
		RouteRules:     routeRules,
		RuleSetCatalog: catalog,
	}
	return inputs, request, nil
}

func readConfigFixtureBuildFile(caseDir string) (configFixtureBuildFile, error) {
	var buildFile configFixtureBuildFile
	data, err := os.ReadFile(filepath.Join(caseDir, "build.json"))
	if errors.Is(err, os.ErrNotExist) {
		return buildFile, fmt.Errorf("build.json is missing in %s", caseDir)
	}
	if err != nil {
		return buildFile, fmt.Errorf("read build.json: %w", err)
	}
	if err := json.Unmarshal(data, &buildFile); err != nil {
		return buildFile, fmt.Errorf("parse build.json: %w", err)
	}
	return buildFile, nil
}
