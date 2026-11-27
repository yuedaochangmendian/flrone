// The production face of the Go config builder: `configBuild`.
//
// ADR 0004 moves the core config out of Kotlin's ConfigGenerator and onto the Go
// side of the action bus. The golden harness (config_build_golden_test.go) already
// proves the Go builder reproduces ConfigGenerator.build byte for byte; this action
// is the seam a later dual-run and cutover calls.
//
// The action is a pure read/build:
//
//   - inputs are the four documents loadSimpleConfigInputs reads (profiles,
//     settings, the global route table, the srslist catalog);
//   - the selected profile and its group's landing / front proxies come from the
//     profile selection the document itself records (CoreConfigs.buildMain's
//     groupProxies);
//   - `deferRuleSets` is reported from the settings' startWithoutRuleSets, without
//     spending the consent marker (DeferredRuleSets.consume is Kotlin's, and stays
//     there until the cutover);
//   - nothing is written. The write side of the start (dashboard install, rule-set
//     placeholder, random port) belongs to BoxInstance and is not part of the build.
//
// Wire payload: `{}` or `{"mode": "vpn"|"proxy"}`. An absent mode keeps the
// settings document's serviceMode; the override exists so a dual-run can rebuild
// for the other mode without rewriting a Kotlin-owned document.
//
// Reply: exactly the map KernelService reads from Kotlin's `config.build`
// (BoxInstance.loadConfig) — `{coreConfig, deferRuleSets, involvedProfileIds}`,
// with the involved ids in RecordingProfiles' first-read order. Kotlin's
// `config.build` path is untouched; this action has no production Dart caller yet.
package mobile

import (
	"encoding/json"
	"fmt"
	"strings"
)

const configBuildMethod Method = "configBuild"

func init() {
	register(configBuildMethod, handleConfigBuild)
}

// configBuildActionRequest is the optional payload. Mode is validated here rather
// than folded blindly into the inputs: a typo would otherwise silently build for
// the wrong service mode.
type configBuildActionRequest struct {
	Mode string `json:"mode"`
}

// configBuildReply is BoxInstance.loadConfig's map. Field order is irrelevant to
// the JSON consumer; the keys and their types are the contract.
type configBuildReply struct {
	CoreConfig         string  `json:"coreConfig"`
	DeferRuleSets      bool    `json:"deferRuleSets"`
	InvolvedProfileIDs []int64 `json:"involvedProfileIds"`
}

// handleConfigBuild rebuilds the config from the kernel's documents and answers
// the exact StartOptions payload Kotlin's `config.build` answers.
func handleConfigBuild(raw json.RawMessage) (any, error) {
	request, err := parseConfigBuildActionRequest(raw)
	if err != nil {
		return nil, err
	}
	inputs, err := loadSimpleConfigInputs()
	if err != nil {
		return nil, fmt.Errorf("config.build: %w", err)
	}
	if request.Mode != "" {
		// The builder reads the mode through inputs.Mode (vpnMode, the mixed
		// inbound and the family guard), so the override belongs on the inputs.
		inputs.Mode = serviceMode(request.Mode)
	}
	// SettingsMapper.routingInput attaches CoreMemberCheck in a background
	// process; the golden harness leaves it nil. Without it a member the core
	// refuses would stay in the group and fail the whole start instead of being
	// dropped the way Kotlin drops it.
	inputs.MemberCheck = configCoreMemberCheck
	buildRequest := configBuildRequestFromSelection(inputs)
	outcome, involved, err := buildSimpleCoreConfigRecorded(inputs, buildRequest)
	if err != nil {
		// The generator's own messages are Kotlin-identical (the golden harness
		// pins them); wrapping them here would break that comparison.
		return nil, err
	}
	deferRuleSets := inputs.DeferRuleSets
	if outcome.customFullConfig {
		// BoxInstance.isCustomFullConfig clears the flag before reporting: a custom
		// full config carries its own rule-sets as written, so the post-start fetch
		// must not run. Read-only either way: nothing is spent.
		deferRuleSets = false
	}
	return configBuildReply{
		CoreConfig:         outcome.coreConfig,
		DeferRuleSets:      deferRuleSets,
		InvolvedProfileIDs: involved,
	}, nil
}

// configCoreMemberCheck is SettingsMapper.CoreMemberCheck: IsValid's core half
// for one auto-selector member. The builder has already built the exact object
// it would emit, so only the core's option parser can still refuse it. An empty
// string means accepted.
func configCoreMemberCheck(id int64, outbound configOutbound, object map[string]any) string {
	if object == nil {
		return ""
	}
	if id <= 0 {
		return "invalid profile id"
	}
	key := "outbounds"
	if configOutboundIsEndpoint(outbound) {
		key = "endpoints"
	}
	payload := map[string]any{
		key: []any{object},
		"log": map[string]any{
			"level": "warn",
		},
	}
	encoded, err := MarshalCanonicalJSON(payload)
	if err != nil {
		return err.Error()
	}
	if err := CheckConfig(string(encoded)); err != nil {
		return err.Error()
	}
	return ""
}

// parseConfigBuildActionRequest accepts an absent payload (`{}`, `null`, empty)
// and the optional mode override.
func parseConfigBuildActionRequest(raw json.RawMessage) (configBuildActionRequest, error) {
	var request configBuildActionRequest
	text := strings.TrimSpace(string(raw))
	if text == "" || text == "null" {
		return request, nil
	}
	if err := json.Unmarshal(raw, &request); err != nil {
		return request, fmt.Errorf("config.build: parse payload: %w", err)
	}
	request.Mode = strings.TrimSpace(request.Mode)
	switch request.Mode {
	case "", string(serviceModeVPN), string(serviceModeProxy):
	default:
		return request, fmt.Errorf("config.build: mode must be %q or %q, not %q",
			serviceModeVPN, serviceModeProxy, request.Mode)
	}
	return request, nil
}

// configBuildRequestFromSelection is CoreConfigs.buildMain's argument set: the
// resolved selected profile plus the landing / front proxy and name of its own
// group (groupProxies). Kotlin passes -1 for an unset proxy; the builder treats
// every id <= 0 as none, so the group's own values are passed through as-is.
func configBuildRequestFromSelection(inputs *simpleConfigInputs) configBuildRequest {
	group := inputs.Selection.Group
	return configBuildRequest{
		profileID:        inputs.Selection.Profile.ID,
		landingProxyID:   group.LandingProxyID,
		frontProxyID:     group.FrontProxyID,
		groupName:        group.Name,
		deferRuleSets:    inputs.DeferRuleSets,
		deferRuleSetsSet: true,
	}
}
