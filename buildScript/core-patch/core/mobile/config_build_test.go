// Focused tests for the pieces the golden fixtures exercise only indirectly:
// the CRC32 rule-set tag, the QHostAddress prefix subtraction that produces the
// tun's route_exclude_address, and the desktop DNS address syntax.
//
// Stage 6b's buildTest port also lives here: it is test-only until a production
// consumer exists (there is none yet), so the fixture adapter
// (config_test_fixture.go) takes it as a function and the harness
// (config_test_golden_test.go) installs the seam.
package mobile

import (
	"fmt"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestConfigRuleSetTagForMatchesKotlinCRC(t *testing.T) {
	tests := []struct {
		entry string
		want  string
	}{
		{"https://raw.githubusercontent.com/example/rules/main/ads.srs", "ads-srs-73ca1fc7"},
		{"https://raw.githubusercontent.com/example/rules/main/chain-block.srs", "chain-block-srs-56a43262"},
		{"geoip-cn", "geoip-cn"},
		{"  geosite-cn  ", "geosite-cn"},
	}
	for _, test := range tests {
		if got := configRuleSetTagFor(test.entry); got != test.want {
			t.Fatalf("configRuleSetTagFor(%q) = %q, want %q", test.entry, got, test.want)
		}
	}
}

func TestConfigSubtractCIDRMatchesTunExclusion(t *testing.T) {
	ranges := []string{
		"127.0.0.0/8", "255.255.255.255/32",
		"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4",
		"fc00::/7", "fe80::/10", "ff00::/8",
	}
	want := []string{
		"127.0.0.0/8", "255.255.255.255/32", "10.0.0.0/8",
		"172.24.0.0/13", "172.20.0.0/14", "172.16.0.0/15", "172.18.0.0/16",
		"172.19.128.0/17", "172.19.64.0/18", "172.19.32.0/19", "172.19.16.0/20",
		"172.19.8.0/21", "172.19.4.0/22", "172.19.2.0/23", "172.19.1.0/24",
		"192.168.0.0/16", "169.254.0.0/16", "224.0.0.0/4", "fc00::/7", "fe80::/10", "ff00::/8",
	}
	got := configSubtractCIDR(ranges, "172.19.0.1/24")
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("configSubtractCIDR = %v\nwant %v", got, want)
	}
	// A hole inside no range keeps everything; a bare address becomes /32.
	if got := configSubtractCIDR([]string{"10.0.0.0/8"}, "203.0.113.9"); !reflect.DeepEqual(got, []string{"10.0.0.0/8"}) {
		t.Fatalf("unrelated hole changed the list: %v", got)
	}
	if !configCIDROverlap("10.0.0.0/8", "10.1.2.3") {
		t.Fatal("a bare IPv4 address must overlap its /8")
	}
}

func TestConfigParseDNSAddressMatchesDesktopSyntax(t *testing.T) {
	tests := []struct {
		address string
		want    map[string]any
	}{
		{"https://dns.google/dns-query", map[string]any{"type": "https", "server": "dns.google", "path": "/dns-query"}},
		{"223.5.5.5", map[string]any{"type": "udp", "server": "223.5.5.5"}},
		{"localhost", map[string]any{"type": "local"}},
		{"tls://1.1.1.1:853", map[string]any{"type": "tls", "server": "1.1.1.1", "server_port": 853}},
		{"dhcp://auto", map[string]any{"type": "dhcp", "interface": ""}},
	}
	for _, test := range tests {
		if got := configBuildDNSObj(test.address); !reflect.DeepEqual(got, test.want) {
			t.Fatalf("configBuildDNSObj(%q) = %#v, want %#v", test.address, got, test.want)
		}
	}
	if _, ok := configParseDNSAddress("udp://1.1.1.1/path"); ok {
		t.Fatal("a path on udp:// must be refused")
	}
	if got := configRouteExcludePrefix("10.1"); got != "" {
		t.Fatalf("routeExcludePrefix(10.1) = %q, want an empty string (not a canonical IPv4)", got)
	}
}

func TestConfigPredefinedDNSNormalization(t *testing.T) {
	entries := configParsePredefinedDNS([]string{"127.0.0.1 localhost localhost.", "::1 LocalHost"})
	if len(entries) != 1 || entries[0].domain != "localhost" {
		t.Fatalf("predefined entries = %#v", entries)
	}
	if !reflect.DeepEqual(entries[0].v4, []string{"127.0.0.1"}) || !reflect.DeepEqual(entries[0].v6, []string{"::1"}) {
		t.Fatalf("predefined answers = %#v", entries[0])
	}
	if entries := configParsePredefinedDNS([]string{"localhost"}); entries != nil {
		t.Fatalf("a line without an address must fail the parse: %#v", entries)
	}
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
			builder.collectECHQueryName, origin)
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

// --- focused tests ------------------------------------------------------------

func TestConfigTestEnvelopeEmptyShape(t *testing.T) {
	envelope, err := configTestEnvelope(configTestBuildResult{
		coreConfig: `{"inbounds":[]}`,
		skipped:    []configTestSkip{{profileID: 4, reason: "Skipping Tailscale conf"}},
	})
	if err != nil {
		t.Fatalf("configTestEnvelope: %v", err)
	}
	want := "{\n" +
		"  \"version\": 1,\n" +
		"  \"generatedBy\": \"ConfigTestGoldenTest\",\n" +
		"  \"sha256\": \"" + configTestSHA256(`{"inbounds":[]}`) + "\",\n" +
		"  \"coreConfig\": \"{\\\"inbounds\\\":[]}\",\n" +
		"  \"outboundTags\": [],\n" +
		"  \"tagToProfileId\": [],\n" +
		"  \"fullConfigs\": [],\n" +
		"  \"skipped\": [\n    {\"profileId\": 4, \"reason\": \"Skipping Tailscale conf\"}\n  ],\n" +
		"  \"tunIPv4Cidr\": null,\n" +
		"  \"involvedProfileIds\": [],\n" +
		"  \"error\": null\n" +
		"}\n"
	if envelope != want {
		t.Fatalf("envelope = %q\nwant %q", envelope, want)
	}
}

func TestConfigTestQuoteMatchesOrgJSON(t *testing.T) {
	cases := map[string]string{
		"plain":            `"plain"`,
		"a\"b":             `"a\"b"`,
		"a\\b":             `"a\\b"`,
		"a/b":              `"a/b"`,
		"</script>":        `"<\/script>"`,
		"line\nbreak":      `"line\nbreak"`,
		"tab\tand\x01bell": `"tab\tand\u0001bell"`,
		"c1\u0085end":      `"c1\u0085end"`,
		"中文":               `"中文"`,
	}
	for input, want := range cases {
		if got := configTestQuote(input); got != want {
			t.Fatalf("configTestQuote(%q) = %s, want %s", input, got, want)
		}
	}
}

func TestBuildTestSkipsAutoSelectorAndKeepsOrder(t *testing.T) {
	inputs := &simpleConfigInputs{
		Settings: simpleConfigSettings{DirectDNS: "223.5.5.5", DNSCacheCapacity: 65536, DNSQueryTimeout: "5s"},
		Profiles: []simpleConfigProfile{
			{ID: 1, Type: "autoselector"},
			{ID: 2, Type: "shadowsocks", OutboundJSON: `{"type":"shadowsocks","tag":"s","server":"198.51.100.33","server_port":8388,"method":"aes-256-gcm","password":"pw"}`},
		},
	}
	result := buildTestCoreConfig(inputs, []configTestCandidate{
		{id: 1, landingProxyID: -1, frontProxyID: -1},
		{id: 2, landingProxyID: -1, frontProxyID: -1},
	})
	if result.failure != nil {
		t.Fatalf("build failed: %s", *result.failure)
	}
	if len(result.skipped) != 1 || result.skipped[0].profileID != 1 ||
		result.skipped[0].reason != "Skipping auto selector conf (test its members instead)" {
		t.Fatalf("skipped = %#v", result.skipped)
	}
	if !reflect.DeepEqual(result.outboundTags, []string{"proxy-2-0"}) {
		t.Fatalf("outboundTags = %v", result.outboundTags)
	}
	if !strings.Contains(result.coreConfig, `"tag":"proxy-2-0"`) {
		t.Fatalf("coreConfig lacks the candidate tag: %s", result.coreConfig)
	}
}

func TestConfigBuildRouteProfileAppliesOutboundMode(t *testing.T) {
	rows := []simpleConfigRouteRule{
		{Name: "lan-bypass", Type: configRuleTypeSimpleAddrBypass, DomainSuffix: []string{"lan.example"}, Action: "bypass", OutboundID: outboundIDDirect},
		{Name: "proxy-all", Type: configRuleTypeCustom, DomainSuffix: []string{"example.net"}, Action: "route", OutboundID: outboundIDProxy},
		{Name: "dns-rule", Type: configRuleTypeCustom, Action: "hijack-dns"},
		{Name: "disabled-dns-rule", Type: configRuleTypeCustom, Action: "hijack-dns", Disabled: true},
	}

	rule := configBuildRouteProfile(rows, outboundModeRule)
	if rule.defaultOutboundID != outboundIDProxy {
		t.Fatalf("rule mode final = %d, want proxy", rule.defaultOutboundID)
	}
	// The default Route DNS rule survives every mode; rule mode keeps the whole table.
	if len(rule.rules) != 4 {
		t.Fatalf("rule mode kept %d rules, want 4: %#v", len(rule.rules), rule.rules)
	}
	if rule.rules[1].Action != "route" {
		t.Fatalf("rule mode did not rewrite bypass to route: %#v", rule.rules[1])
	}

	for _, test := range []struct {
		mode     outboundMode
		final    int64
		finalTag string
	}{
		{outboundModeGlobal, outboundIDProxy, "proxy"},
		{outboundModeDirect, outboundIDDirect, "direct"},
	} {
		profile := configBuildRouteProfile(rows, test.mode)
		if profile.defaultOutboundID != test.final {
			t.Fatalf("%s mode final = %d, want %d", test.mode, profile.defaultOutboundID, test.final)
		}
		if got := configOutboundName(profile.defaultOutboundID); got != test.finalTag {
			t.Fatalf("%s mode final name = %q, want %q", test.mode, got, test.finalTag)
		}
		// Only the two enabled hijack-dns rules survive; the disabled one is
		// removed by the build filter that follows the mode rewrite.
		if len(profile.rules) != 2 {
			t.Fatalf("%s mode kept %d rules, want 2: %#v", test.mode, len(profile.rules), profile.rules)
		}
		for _, kept := range profile.rules {
			if kept.Action != "hijack-dns" {
				t.Fatalf("%s mode kept a non-hijack rule: %#v", test.mode, kept)
			}
		}
	}

	// An unknown stored value already fell back to rule before this function is
	// called (FlroneMode.Mode.of / loadSimpleConfigInputs), so the rewrite treats
	// anything that is not global/direct as rule rather than inventing a mode.
	unknown := configBuildRouteProfile(rows, "auto")
	if unknown.defaultOutboundID != outboundIDProxy || len(unknown.rules) != 4 {
		t.Fatalf("unknown mode did not fall back to rule: final=%d rules=%#v",
			unknown.defaultOutboundID, unknown.rules)
	}
}

func TestConfigToACEHostMatchesKotlinPunycode(t *testing.T) {
	tests := []struct {
		host string
		want string
	}{
		// ASCII is returned untouched (QUrl::toAce shortcut), case included.
		{"DNS.Example.net", "DNS.Example.net"},
		{"example.例子.测试", "example.xn--fsqu00a.xn--0zwm56d"},
		{"MÜNCHEN.de", "xn--mnchen-3ya.de"},
		// NFKC maps full-width Latin to ASCII before the label check.
		{"ｅｘａｍｐｌｅ.测试", "example.xn--0zwm56d"},
		{"例子.", "xn--fsqu00a."},
		{"例子.com, 测试.com", "xn--fsqu00a.com,xn--0zwm56d.com"},
		// An unconvertible name is returned unchanged by toAceHost.
		{"-例子.com", "-例子.com"},
		{"例 子.com", "例 子.com"},
	}
	for _, test := range tests {
		if got := configToACEHost(test.host); got != test.want {
			t.Fatalf("configToACEHost(%q) = %q, want %q", test.host, got, test.want)
		}
	}
}

func TestConfigValidDurationMatchesSingBoxGrammar(t *testing.T) {
	valid := []string{
		"5s", "1m30s", "+5s", "0s", ".5s", "0.5s", "500ms", "1.5h", "2d",
		"1us", "1µs", "3μs", " 5s ",
	}
	for _, text := range valid {
		if got := configValidDuration(text); got == "" {
			t.Fatalf("configValidDuration(%q) rejected a valid duration", text)
		}
	}
	invalid := []string{
		"", "5", "-5s", "5 s", "1.2.3s", "1s2", "s", ".s", "1s-", "1S",
	}
	for _, text := range invalid {
		if got := configValidDuration(text); got != "" {
			t.Fatalf("configValidDuration(%q) = %q, want empty", text, got)
		}
	}
	// The settings registry is stricter than the generator: a stored value with
	// a leading '+', a bare fraction or a micro-sign unit falls back to the
	// setting default before the generator ever sees it.
	for _, text := range []string{"+5s", ".5s", "1µs", "3μs"} {
		if configDurationOrEmpty(text) {
			t.Fatalf("configDurationOrEmpty(%q) accepted a registry-invalid duration", text)
		}
	}
}

func TestBuildTestSkipsExtraCoreCandidates(t *testing.T) {
	inputs := &simpleConfigInputs{
		Settings: simpleConfigSettings{DirectDNS: "223.5.5.5", DNSCacheCapacity: 65536, DNSQueryTimeout: "5s"},
		Profiles: []simpleConfigProfile{
			{ID: 1, Type: "extracore", OutboundJSON: `{"type":"extracore"}`},
			{ID: 2, Type: "chain", OutboundJSON: `{"type":"chain","name":"c","list":[3]}`},
			{ID: 3, Type: "extracore", OutboundJSON: `{"type":"extracore"}`},
		},
	}
	result := buildTestCoreConfig(inputs, []configTestCandidate{{id: 1}, {id: 2}})
	if result.failure != nil {
		t.Fatalf("build failed: %s", *result.failure)
	}
	reasons := map[int64]string{}
	for _, skip := range result.skipped {
		reasons[skip.profileID] = skip.reason
	}
	if reasons[1] != "Skipping extra-core conf" {
		t.Fatalf("extra-core skip = %q", reasons[1])
	}
	if reasons[2] != "Skipping chain with terminal (extra-core) hop (cannot test)" {
		t.Fatalf("chain extra-core skip = %q", reasons[2])
	}
}
