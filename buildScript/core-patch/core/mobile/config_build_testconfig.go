// buildTest (ConfigGenerator.buildTest / BuildTestConfig :2544-2693) as the
// production Go implementation. The golden harness compares it with the Kotlin
// oracle's expected.json; the C ABI host call `build_test_config` hands the same
// envelope to the Kotlin test session, which no longer runs ConfigGenerator.
//
// Skipped reasons are the Kotlin texts: "Profile does not exist", the
// classifyTestCandidate skips, "Unsupported profile type: <type>" and the
// missing-hop / chain-shape errors. A candidate whose build fails is skipped
// with the builder's error, the chain is rolled back and the batch continues,
// exactly like skipFailedBuild. A *known* type whose outbound this port cannot
// reproduce fails the whole batch instead: silently skipping it would understate
// the result.
package mobile

import (
	"fmt"
	"strconv"
)

type configTestCandidate struct {
	id             int64
	landingProxyID int64
	frontProxyID   int64
	groupName      string
}

// configTestTagBucket is one outboundTags / tagToProfileId entry: the ingress
// tag of a built candidate (`proxy-<id>-0`) and its profile id.
type configTestTagBucket struct {
	tag       string
	profileID int64
}

// configTestFullConfig is one fullConfigs entry: a custom full config passed
// through with its inbounds emptied.
type configTestFullConfig struct {
	profileID int64
	config    string
}

// configTestSkip is one skipped entry: a candidate that was not built and why.
type configTestSkip struct {
	profileID int64
	reason    string
}

// configTestBuildResult is GeneratedConfig as buildTest fills it: an error is
// reported in failure (GeneratedConfig.error), with the arrays empty.
type configTestBuildResult struct {
	coreConfig         string
	outboundTags       []string
	tagToProfileID     []configTestTagBucket
	fullConfigs        []configTestFullConfig
	skipped            []configTestSkip
	tunIPv4Cidr        *string
	involvedProfileIDs []int64
	failure            *string
}

// --- buildTest (Stage 6b) -----------------------------------------------------

// tagTestChainPrefix is Tags.TEST_CHAIN_PREFIX: a test candidate is a chain
// under `proxy-<profile id>` whose ingress tag is reported in outboundTags.
const tagTestChainPrefix = "proxy"

// configTestKnownOutboundTypes is the set OutboundFactory.newByType resolves to
// a real outbound: the builtin table plus CONVENTION_CLASSES. Everything else
// (unknown strings, "extracore") yields the invalid placeholder in Kotlin, and
// buildTest then skips it as "Unsupported profile type". A known type this port
// cannot build is a hard failure instead, never a skip.
var configTestKnownOutboundTypes = map[string]bool{
	"socks":        true,
	"http":         true,
	"shadowsocks":  true,
	"vless":        true,
	"vmess":        true,
	"trojan":       true,
	"hysteria":     true,
	"tuic":         true,
	"juicity":      true,
	"trusttunnel":  true,
	"anytls":       true,
	"mieru":        true,
	"snell":        true,
	"shadowtls":    true,
	"wireguard":    true,
	"masque":       true,
	"openvpn":      true,
	"openconnect":  true,
	"ssh":          true,
	"naive":        true,
	"custom":       true,
	"direct":       true,
	"chain":        true,
	"autoselector": true,
}

// configTestCanonicalType is OutboundFactory.canonicalType, the aliases the
// factory resolves before it picks a class.
func configTestCanonicalType(profileType string) string {
	switch profileType {
	case "hysteria2":
		return "hysteria"
	case "openvpn-client":
		return "openvpn"
	}
	return profileType
}

func configTestKnownOutboundType(profileType string) bool {
	return configTestKnownOutboundTypes[configTestCanonicalType(profileType)]
}

// configGoBuildableType is the protocol matrix this builder actually emits. A
// type Kotlin knew but Go does not is skipped in a test batch (the node shows
// unmeasured) instead of failing the whole batch.
func configGoBuildableType(profileType string) bool {
	switch configTestCanonicalType(profileType) {
	case "shadowsocks", "http", "socks", "vmess", "vless", "trojan", "tuic",
		"juicity", "anytls", "shadowtls", "snell", "ssh", "mieru", "trusttunnel",
		"masque", "naive", "hysteria", "hysteria2", "wireguard", "openvpn", "openconnect",
		"direct", "custom",
		"chain", "autoselector":
		return true
	}
	return false
}

// buildTestCoreConfig is ConfigGenerator.buildTest (BuildTestConfig
// :2544-2693) for the Go builder. The DNS section comes first (ECH query names
// are collected up front), then log / certificate / ntp, then one chain per
// candidate under `proxy-<id>`, `direct`, and a route object with just
// auto_detect_interface and the direct domain resolver. There is no `proxy`
// tag, no inbounds, no experimental and no services section.
//
// Skipped reasons are the Kotlin texts: "Profile does not exist", the
// classifyTestCandidate skips, "Unsupported profile type: <type>" and the
// missing-hop / chain-shape errors. A candidate whose build fails is skipped
// with the builder's error, the chain is rolled back and the batch continues,
// exactly like skipFailedBuild. A *known* type whose outbound this port cannot
// reproduce fails the whole build instead (error in the envelope): silently
// skipping it would understate the oracle envelope.
func buildTestCoreConfig(inputs *simpleConfigInputs, candidates []configTestCandidate) configTestBuildResult {
	if inputs == nil {
		return configTestBuildFailure("config build has no inputs")
	}
	settings := inputs.Settings
	builder := &configBuilder{
		inputs:   inputs,
		settings: settings,
		vpnMode:  inputs.Mode == serviceModeVPN,
		forTest:  true,
		ctx: configBuildContext{
			directDNSDisableIPv6:  settings.DirectDNSDisableIPv6,
			useDNSObject:          settings.UseDNSObject,
			defaultDomainStrategy: settings.OutboundDomainStrategy,
		},
		endpoints: []any{},
		pre: configPrerequisites{
			outboundMap: map[int64]string{
				outboundIDProxy:      tagProxy,
				outboundIDDirect:     tagDirect,
				outboundIDWarpBypass: tagWarpBypass,
			},
			ruleSetTags: make(map[string]bool),
		},
		echResolvers: make(map[string]string),
	}

	// The DNS section runs before the chains, so every candidate's ECH names are
	// collected up front (:2714-2719). A missing or unparsable hop contributes
	// nothing here; the candidate loop reports it.
	for _, candidate := range candidates {
		for _, hopID := range configTestUnwrapChain(inputs.Profiles, candidate.id) {
			row := configFindProfile(inputs.Profiles, hopID)
			if row == nil {
				continue
			}
			outbound, err := configParseOutboundJSON(*row)
			if err != nil {
				continue
			}
			builder.collectECHQueryName(outbound)
		}
	}

	dns, err := builder.buildDNSSection(false)
	if err != nil {
		return configTestBuildFailure(err.Error())
	}
	core := map[string]any{"dns": dns}
	core["log"] = builder.buildLogSection()
	core["certificate"] = builder.buildCertificateSection()
	if ntp := builder.buildNTPSection(); ntp != nil {
		core["ntp"] = ntp
	}

	outboundTags := []string{}
	tagToProfileID := []configTestTagBucket{}
	fullConfigs := []configTestFullConfig{}
	skipped := []configTestSkip{}

	for _, candidate := range configTestDistinctCandidates(candidates) {
		id := candidate.id
		row := configFindProfile(inputs.Profiles, id)
		if row == nil {
			skipped = append(skipped, configTestSkip{profileID: id, reason: "Profile does not exist"})
			continue
		}
		profileType := configTestCanonicalType(row.Type)
		if reason := configTestClassifyCandidate(*row, inputs.Profiles); reason != "" {
			skipped = append(skipped, configTestSkip{profileID: id, reason: reason})
			continue
		}
		if !configTestKnownOutboundType(profileType) {
			skipped = append(skipped, configTestSkip{profileID: id, reason: "Unsupported profile type: " + profileType})
			continue
		}
		outbound, err := configParseOutboundJSON(*row)
		if err != nil {
			return configTestBuildFailure(err.Error())
		}
		if custom, ok := outbound.params.(configCustomParams); ok && custom.isFullConfig() {
			// Passed through as its own config with the inbounds emptied
			// (:2606-2612).
			object := custom.buildObject()
			object["inbounds"] = []any{}
			encoded, err := MarshalCanonicalJSON(object)
			if err != nil {
				return configTestBuildFailure(fmt.Sprintf("serialise the custom full config of profile %d: %v", id, err))
			}
			fullConfigs = append(fullConfigs, configTestFullConfig{profileID: id, config: string(encoded)})
			continue
		}

		hopIDs := make([]int64, 0, len(outbound.hops)+3)
		if candidate.landingProxyID > 0 {
			hopIDs = append(hopIDs, candidate.landingProxyID)
		}
		hopIDs = append(hopIDs, configTestUnwrapChain(inputs.Profiles, id)...)
		if candidate.frontProxyID > 0 {
			hopIDs = append(hopIDs, candidate.frontProxyID)
		}
		reason, fatal := configTestCandidateError(inputs.Profiles, settings, outbound, candidate, hopIDs)
		if fatal != nil {
			return configTestBuildFailure(fatal.Error())
		}
		if reason != "" {
			skipped = append(skipped, configTestSkip{profileID: id, reason: reason})
			continue
		}

		mark := newConfigTestBuildMark(builder)
		origin := &configHopOrigin{
			groupName: candidate.groupName,
			landingID: candidate.landingProxyID,
			frontID:   candidate.frontProxyID,
		}
		if outbound.profileType == "chain" {
			origin.profileName = outbound.name
			origin.profileHops = outbound.hops
		}
		ingress, err := configBuildChain(inputs.Profiles, settings, hopIDs,
			tagTestChainPrefix+"-"+strconv.FormatInt(id, 10), false, true, false, 0,
			&builder.outbounds, &builder.endpoints, builder.ctx.directDomainStrategy(),
			builder.collectECHQueryName, origin, builder.reads)
		if err != nil {
			// skipFailedBuild: a profile whose chain fails halfway is reported
			// failed; the rest of the batch still tests.
			skipped = append(skipped, configTestSkip{profileID: id, reason: err.Error()})
			mark.rollback()
			continue
		}
		outboundTags = append(outboundTags, ingress)
		tagToProfileID = append(tagToProfileID, configTestTagBucket{tag: ingress, profileID: id})
	}

	builder.outbounds = append(builder.outbounds, map[string]any{"type": "direct", "tag": tagDirect})
	core["outbounds"] = builder.outbounds
	core["endpoints"] = builder.endpoints
	// A running tun owns the OS resolver, so the sidecar resolves against the
	// probe box's dns-direct instead (a test box has no tun).
	core["route"] = map[string]any{
		"auto_detect_interface":   true,
		"default_domain_resolver": builder.directDomainResolver(),
	}
	core["inbounds"] = []any{}

	encoded, err := MarshalCanonicalJSON(core)
	if err != nil {
		return configTestBuildFailure(fmt.Sprintf("serialise the test core config: %v", err))
	}
	return configTestBuildResult{
		coreConfig:     string(encoded),
		outboundTags:   outboundTags,
		tagToProfileID: tagToProfileID,
		fullConfigs:    fullConfigs,
		skipped:        skipped,
	}
}

// configTestClassifyCandidate is classifyTestCandidate (:2236-2259): the skip
// reason, or "" when the candidate is built. No outbound in this port reports
// isExtraCore (Kotlin only yields the invalid placeholder for "extracore"), so
// the chain branch cannot produce its extra-core reason; the invalid path below
// reports such a type as unsupported instead.
// configTestClassifyCandidate is classifyTestCandidate (:2236-2259): the skip
// reason, or empty when the candidate is built. Extra-core candidates and
// chains ending in one are untestable; a chain whose stored JSON does not parse
// is Kotlin's InvalidOutbound and becomes the unsupported-type skip.
func configTestClassifyCandidate(row simpleConfigProfile, profiles []simpleConfigProfile) string {
	profileType := configTestCanonicalType(row.Type)
	if profileType == "extracore" {
		return "Skipping extra-core conf"
	}
	if profileType == "chain" {
		chain, err := configParseOutboundJSON(row)
		if err != nil {
			return "Unsupported profile type: " + row.Type
		}
		for _, hopID := range chain.hops {
			hopRow := configFindProfile(profiles, hopID)
			if hopRow == nil {
				// missingHopError handles a deleted hop; it is not a skip here.
				continue
			}
			if configTestCanonicalType(hopRow.Type) == "extracore" {
				return "Skipping chain with terminal (extra-core) hop (cannot test)"
			}
		}
		return ""
	}
	if profileType == "tailscale" {
		return "Skipping Tailscale conf"
	}
	if profileType == "autoselector" {
		return "Skipping auto selector conf (test its members instead)"
	}
	if configTestKnownOutboundType(profileType) && !configGoBuildableType(profileType) {
		return "Unsupported profile type: " + row.Type
	}
	return ""
}

// configTestCandidateError is ChainBuilder.candidateError: the hop walk of
// resolveHops plus the chain-shape checks, then one dry build per hop. The
// returned reason is the Kotlin skip text; a non-nil error means this port
// cannot reproduce the candidate and the whole build fails.
func configTestCandidateError(
	profiles []simpleConfigProfile, settings simpleConfigSettings,
	candidateOutbound configOutbound, candidate configTestCandidate, hopIDs []int64,
) (string, error) {
	hops := make([]configOutbound, 0, len(hopIDs))
	hasCustomFullConfig := false
	for _, hopID := range hopIDs {
		if hopID == configWarpProfileID {
			// A test ChainBuilder has no WARP hop, so the id reads as missing.
			return configTestMissingHopError(candidateOutbound, candidate, hopID), nil
		}
		row := configFindProfile(profiles, hopID)
		if row == nil {
			return configTestMissingHopError(candidateOutbound, candidate, hopID), nil
		}
		profileType := configTestCanonicalType(row.Type)
		if !configTestKnownOutboundType(profileType) {
			return fmt.Sprintf("Profile %d has a type this build cannot use: %s", hopID, profileType), nil
		}
		if profileType == "chain" {
			return "Chain in Chain is not allowed", nil
		}
		if profileType == "autoselector" {
			return "An auto selector cannot be used as a hop; it is not a fixed server", nil
		}
		hop, err := configParseOutboundJSON(*row)
		if err != nil {
			return "", fmt.Errorf("profile %d cannot be built by the Go test config builder: %w", hopID, err)
		}
		if configOutboundIsCustomFullConfig(hop) {
			hasCustomFullConfig = true
		}
		hops = append(hops, hop)
	}
	if hasCustomFullConfig {
		return "Custom full config profiles cannot be used in a chain; only custom outbound profiles are chainable", nil
	}
	if len(hops) == 0 {
		return "The profile has no hops", nil
	}
	for _, hop := range hops {
		if _, err := configBuildOutbound(hop, settings); err != nil {
			return "", fmt.Errorf("profile %d cannot be built by the Go test config builder: %w", hop.id, err)
		}
	}
	return "", nil
}

// configTestMissingHopError is ChainBuilder.missingHopError: the setting that
// still points at a deleted profile, so the user knows what to amend.
func configTestMissingHopError(profile configOutbound, candidate configTestCandidate, id int64) string {
	if profile.profileType == "chain" {
		for _, hopID := range profile.hops {
			if hopID == id {
				return "Chain \"" + profile.name + "\" has a hop (profile id " +
					strconv.FormatInt(id, 10) + ") that no longer exists, edit the chain to remove it"
			}
		}
	}
	if candidate.frontProxyID == id {
		return "Group \"" + candidate.groupName + "\" has a front proxy that has been deleted."
	}
	if candidate.landingProxyID == id {
		return "Group \"" + candidate.groupName + "\" has a landing proxy that has been deleted."
	}
	return "A proxy in the chain can no longer be found."
}

// configTestUnwrapChain is ChainBuilder.unwrapChain: the hop ids exit first
// (the stored in -> out list reversed). A missing or unparsable chain
// contributes nothing, like Kotlin's empty cast result.
func configTestUnwrapChain(profiles []simpleConfigProfile, id int64) []int64 {
	row := configFindProfile(profiles, id)
	if row == nil {
		return nil
	}
	if configTestCanonicalType(row.Type) != "chain" {
		return []int64{id}
	}
	outbound, err := configParseOutboundJSON(*row)
	if err != nil {
		return nil
	}
	return configUnwrapChain(outbound)
}

// configTestDistinctCandidates is candidates.distinctBy { it.id }: a repeated
// candidate would repeat its id-derived tags.
func configTestDistinctCandidates(candidates []configTestCandidate) []configTestCandidate {
	seen := make(map[int64]bool, len(candidates))
	out := make([]configTestCandidate, 0, len(candidates))
	for _, candidate := range candidates {
		if seen[candidate.id] {
			continue
		}
		seen[candidate.id] = true
		out = append(out, candidate)
	}
	return out
}

// configTestBuildMark is ChainBuildMark: what one candidate's chain build left
// behind, so a failed chain is dropped from the batch.
type configTestBuildMark struct {
	builder       *configBuilder
	outbounds     int
	endpoints     int
	echQueryNames int
	echResolvers  map[string]bool
}

func newConfigTestBuildMark(builder *configBuilder) configTestBuildMark {
	resolvers := make(map[string]bool, len(builder.echResolvers))
	for name := range builder.echResolvers {
		resolvers[name] = true
	}
	return configTestBuildMark{
		builder:       builder,
		outbounds:     len(builder.outbounds),
		endpoints:     len(builder.endpoints),
		echQueryNames: len(builder.echQueryNames),
		echResolvers:  resolvers,
	}
}

func (mark configTestBuildMark) rollback() {
	builder := mark.builder
	if len(builder.outbounds) > mark.outbounds {
		builder.outbounds = builder.outbounds[:mark.outbounds]
	}
	if len(builder.endpoints) > mark.endpoints {
		builder.endpoints = builder.endpoints[:mark.endpoints]
	}
	if len(builder.echQueryNames) > mark.echQueryNames {
		builder.echQueryNames = builder.echQueryNames[:mark.echQueryNames]
	}
	for name := range builder.echResolvers {
		if !mark.echResolvers[name] {
			delete(builder.echResolvers, name)
		}
	}
}

// configTestBuildFailure is GeneratedConfig.failure: no core config and all
// arrays empty, with the reason in error.
func configTestBuildFailure(message string) configTestBuildResult {
	reason := message
	return configTestBuildResult{
		outboundTags:       []string{},
		tagToProfileID:     []configTestTagBucket{},
		fullConfigs:        []configTestFullConfig{},
		skipped:            []configTestSkip{},
		involvedProfileIDs: []int64{},
		failure:            &reason,
	}
}

// configTestResultPayload is the JSON shape the Kotlin test session reads from
// the `build_test_config` host call: GeneratedConfig's fields, with the id-keyed
// maps written as JSON objects (Kotlin parses String keys back to Long).
func configTestResultPayload(result configTestBuildResult) map[string]any {
	tags := make(map[string]int64, len(result.tagToProfileID))
	for _, bucket := range result.tagToProfileID {
		tags[bucket.tag] = bucket.profileID
	}
	fullConfigs := make(map[string]string, len(result.fullConfigs))
	for _, full := range result.fullConfigs {
		fullConfigs[strconv.FormatInt(full.profileID, 10)] = full.config
	}
	skipped := make(map[string]string, len(result.skipped))
	for _, skip := range result.skipped {
		skipped[strconv.FormatInt(skip.profileID, 10)] = skip.reason
	}
	payload := map[string]any{
		"coreConfig":         result.coreConfig,
		"outboundTags":       result.outboundTags,
		"tagToProfileId":     tags,
		"fullConfigs":        fullConfigs,
		"skipped":            skipped,
		"tunIPv4Cidr":        nil,
		"involvedProfileIds": result.involvedProfileIDs,
		"error":              nil,
	}
	if result.tunIPv4Cidr != nil {
		payload["tunIPv4Cidr"] = *result.tunIPv4Cidr
	}
	if result.failure != nil {
		payload["error"] = *result.failure
	}
	return payload
}
