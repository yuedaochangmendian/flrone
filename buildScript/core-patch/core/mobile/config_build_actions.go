// The production face of the Go config builder: `configBuild`.
//
// ADR 0008 moved the core config out of Kotlin's ConfigGenerator and onto the Go
// side of the action bus. The frozen golden fixtures prove the Go builder
// reproduces the retired Kotlin generator byte for byte; this action is the
// production start path.
//
// The action is a pure read/build:
//
//   - inputs are the four documents loadSimpleConfigInputs reads (profiles,
//     settings, the global route table, the srslist catalog);
//   - the selected profile and its group's landing / front proxies come from the
//     profile selection the document itself records;
//   - `deferRuleSets` is normally Kotlin config.prepare's answer (it spent the
//     consent). The request field overrides the document's timestamp, which a
//     consumed consent clears; an absent field keeps the document's answer.
//   - nothing is written. The write side of the start (dashboard install, rule-set
//     placeholder, random port, secrets) belongs to config.prepare.
//
// Wire payload: `{}`, `{"mode": "vpn"|"proxy"}` and/or
// `{"deferRuleSets": true|false}`. An absent mode keeps the settings document's
// serviceMode.
//
// Reply: `{coreConfig, deferRuleSets, involvedProfileIds}`, with the involved
// ids in RecordingProfiles' first-read order. KernelService invokes this action
// after config.prepare and hands the reply to createInstance.
package mobile

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const configBuildMethod Method = "configBuild"

func init() {
	register(configBuildMethod, handleConfigBuild)
}

// configBuildActionRequest is the optional payload. Mode is validated here rather
// than folded blindly into the inputs: a typo would otherwise silently build for
// the wrong service mode. DeferRuleSets is config.prepare's answer: Kotlin spent
// the consent before the build, so the document's timestamp is no longer the
// source of truth (a consumed timestamp is cleared and would read false here).
type configBuildActionRequest struct {
	Mode          string `json:"mode"`
	DeferRuleSets *bool  `json:"deferRuleSets"`
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
	start := time.Now()
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
	if request.DeferRuleSets != nil {
		buildRequest.deferRuleSets = *request.DeferRuleSets
		buildRequest.deferRuleSetsSet = true
	}
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
	reply := configBuildReply{
		CoreConfig:         outcome.coreConfig,
		DeferRuleSets:      deferRuleSets,
		InvolvedProfileIDs: involved,
	}
	// Observability only: one line, no config body and no secrets (the ids and
	// the byte count describe the build, not its contents). Errors keep their
	// existing return path; this line is emitted only for a successful build.
	pump.push(LogLevelInfo, configBuildLogLine(buildRequest.profileID, outcome,
		involved, deferRuleSets, time.Since(start)))
	return reply, nil
}

// configBuildLogLine is the stable one-line observability message. The took
// field is wall time since the action started, rounded up to microseconds so
// a sub-microsecond build never reads as 0s.
func configBuildLogLine(
	profileID int64, outcome configBuildOutcome, involved []int64, deferRuleSets bool, elapsed time.Duration,
) string {
	if elapsed < time.Microsecond {
		elapsed = time.Microsecond
	}
	return "config.build: profile=" + strconv.FormatInt(profileID, 10) +
		" bytes=" + strconv.Itoa(len(outcome.coreConfig)) +
		" involved=" + strconv.Itoa(len(involved)) +
		" defer=" + strconv.FormatBool(deferRuleSets) +
		" took=" + elapsed.Round(time.Microsecond).String()
}

// configCoreMemberCheck is SettingsMapper.CoreMemberCheck: IsValid's core half
// for one auto-selector member. The builder has already built the exact object
// it would emit, so only the core's option parser can still refuse it. An empty
// string means accepted. The verdict is memoised by the exact canonical payload
// (see configCoreMemberCheckWith); a nil/blank config is never cached.
func configCoreMemberCheck(id int64, outbound configOutbound, object map[string]any) string {
	return configCoreMemberCheckWith(configMemberVerdicts, CheckConfig, id, outbound, object)
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
