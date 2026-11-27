// The Stage-1 Go config builder: ConfigGenerator.build (BuildSingBoxConfig) for
// one selected profile and the single global route table.
//
// Sections are emitted in the Kotlin generator's order (log, ntp, certificate,
// inbounds, outbounds/endpoints, dns, route, experimental, services) and the
// object is serialised through MarshalCanonicalJSON, which is byte-compatible
// with the Kotlin JsonWriter. The first consumer is the golden harness
// (config_build_golden_test.go); nothing in production calls this yet.
//
// Scope is deliberately narrow: a build either reproduces the Kotlin sections
// exactly or returns an error naming what it cannot represent (WARP, auto
// selectors, mux presets, profile types beyond shadowsocks/direct/chain). It
// never emits a config that silently omits an input.
package mobile

import (
	"encoding/json"
	"fmt"
	"net/netip"
	"strings"
)

const (
	configDashboardPath    = "sb-dashboard"
	configEmptyRuleSetPath = "empty-rule-set.srs"
)

// configBuildRequest is build.json / ConfigGenerator.build's arguments. The
// golden harness reads it from the case directory; a production cutover would
// take the same fields from the selection state.
type configBuildRequest struct {
	profileID      int64
	landingProxyID int64
	frontProxyID   int64
	groupName      string
	deferRuleSets  bool
}

// configDomainSelectors is DomainSelectors (generate.cpp:85-95): the prefixed
// selector lists of one DNS routing target.
type configDomainSelectors struct {
	ruleSets []string
	domains  []string
	suffixes []string
	keywords []string
	regexes  []string
}

func (selectors configDomainSelectors) hasInlineConditions() bool {
	return len(selectors.domains) > 0 || len(selectors.suffixes) > 0 ||
		len(selectors.keywords) > 0 || len(selectors.regexes) > 0
}

// configConditionalDNS is one conditionalSites entry: the DNS server tag, the
// network conditions and the site selectors.
type configConditionalDNS struct {
	server     string
	conditions map[string]any
	selectors  configDomainSelectors
}

// configRuleSetDefinition is one route.rule_set entry: a tag and its download
// URL, in first-seen order.
type configRuleSetDefinition struct {
	tag string
	url string
}

// configPrerequisites is BuildPrerequisites as far as this builder generates
// them (no DNS-server hijack, no auxiliary endpoints, no address sets).
type configPrerequisites struct {
	outboundMap           map[int64]string
	routeOutboundGroups   [][]int64
	ruleSets              []configRuleSetDefinition
	ruleSetTags           map[string]bool
	directDNS             configDomainSelectors
	needDirectDNSRules    bool
	proxyDNS              configDomainSelectors
	needProxyDNSRules     bool
	conditionalDNS        []configConditionalDNS
	directIPCIDRs         []string
	bypassedPrivateRanges []string
}

// configBuildContext is the BuildContext subset the sections read. routeOwnsDNS
// is always false: the input layer has no per-profile DNS.
type configBuildContext struct {
	directDNSDisableIPv6  bool
	useDNSObject          bool
	defaultDomainStrategy string
}

func (ctx configBuildContext) directDomainStrategy() string {
	// routeOwnsDNS is false here, so the Kotlin condition
	// directDnsDisableIpv6 && (routeOwnsDns || !useDnsObject) reduces to the
	// DNS-object switch.
	if ctx.directDNSDisableIPv6 && !ctx.useDNSObject {
		return "ipv4_only"
	}
	return ctx.defaultDomainStrategy
}

// configBuilder is the per-build state of generate.cpp:180-207 that the
// sections share.
type configBuilder struct {
	inputs   *simpleConfigInputs
	request  configBuildRequest
	settings simpleConfigSettings
	vpnMode  bool
	// deferRuleSets is GeneratorSettings.deferRuleSets: request.deferRuleSets
	// mirrors the golden harness's settings.copy, and a production caller would
	// pass inputs.DeferRuleSets here.
	deferRuleSets bool
	ctx           configBuildContext

	pre       configPrerequisites
	outbounds []any
	endpoints []any
}

// buildSimpleCoreConfig is ConfigGenerator.build: the exact coreConfig string
// for the selected profile, or the reason the build cannot proceed.
func buildSimpleCoreConfig(inputs *simpleConfigInputs, request configBuildRequest) (string, error) {
	if inputs == nil {
		return "", fmt.Errorf("config build has no inputs")
	}
	if inputs.Settings.EnableWarp {
		return "", fmt.Errorf("enable_warp is set; the Stage-1 Go config builder does not build the WARP hop")
	}
	profileRow := configFindProfile(inputs.Profiles, request.profileID)
	if profileRow == nil {
		return "", fmt.Errorf("Profile %d does not exist", request.profileID)
	}
	profile, err := configParseOutboundJSON(*profileRow)
	if err != nil {
		return "", err
	}
	if profile.profileType == "autoselector" {
		return "", fmt.Errorf("profile %d is an auto selector; the Stage-1 Go config builder does not build selector groups", request.profileID)
	}
	routeRules := configDropStaleOutboundRules(inputs.RouteRules, inputs.Profiles)
	route := configBuildRouteProfile(routeRules)

	builder := &configBuilder{
		inputs:        inputs,
		request:       request,
		settings:      inputs.Settings,
		vpnMode:       inputs.Mode == serviceModeVPN,
		deferRuleSets: request.deferRuleSets,
		ctx: configBuildContext{
			directDNSDisableIPv6:  inputs.Settings.DirectDNSDisableIPv6,
			useDNSObject:          inputs.Settings.UseDNSObject,
			defaultDomainStrategy: inputs.Settings.OutboundDomainStrategy,
		},
		endpoints: []any{},
		pre: configPrerequisites{
			outboundMap: map[int64]string{
				outboundIDProxy:      tagProxy,
				outboundIDDirect:     tagDirect,
				outboundIDWarpBypass: tagProxy,
			},
			ruleSetTags: make(map[string]bool),
		},
	}

	if err := builder.calculatePrerequisites(profile, route); err != nil {
		return "", err
	}

	core := map[string]any{}
	core["log"] = builder.buildLogSection()
	if ntp := builder.buildNTPSection(); ntp != nil {
		core["ntp"] = ntp
	}
	core["certificate"] = builder.buildCertificateSection()
	core["inbounds"] = builder.buildInboundSection()
	if err := builder.buildOutboundsSection(profile, route); err != nil {
		return "", err
	}
	core["endpoints"] = builder.endpoints
	core["outbounds"] = builder.outbounds
	dns, err := builder.buildDNSSection(true)
	if err != nil {
		return "", err
	}
	core["dns"] = dns
	routeObject, err := builder.buildRouteSection(route)
	if err != nil {
		return "", err
	}
	core["route"] = routeObject
	core["experimental"] = builder.buildExperimentalSection()
	if services := builder.buildServicesSection(); services != nil {
		core["services"] = services
	}
	encoded, err := MarshalCanonicalJSON(core)
	if err != nil {
		return "", fmt.Errorf("serialise the core config: %w", err)
	}
	return string(encoded), nil
}

// calculatePrerequisites is ConfigGenerator.calculatePrerequisites minus
// auxiliary endpoints, the DNS-server hijack and extra cores.
func (builder *configBuilder) calculatePrerequisites(profile configOutbound, route configRouteProfile) error {
	pre := &builder.pre

	var suffix int
	for _, id := range route.usedOutboundIDs() {
		if id < 0 {
			continue
		}
		neededRow := configFindProfile(builder.inputs.Profiles, id)
		if neededRow == nil {
			return fmt.Errorf("The routing profile is referencing outbounds that no longer exist, consider revising your settings")
		}
		needed, err := configParseOutboundJSON(*neededRow)
		if err != nil {
			return err
		}
		if needed.profileType == "chain" {
			if len(needed.hops) == 0 {
				return fmt.Errorf("Chain outbound in routing profile is empty or corrupted")
			}
			group := make([]int64, 0, len(needed.hops))
			for _, hopID := range needed.hops {
				hopRow := configFindProfile(builder.inputs.Profiles, hopID)
				if hopRow == nil {
					return fmt.Errorf("Chain outbound in routing profile contains a missing profile")
				}
				hop, err := configParseOutboundJSON(*hopRow)
				if err != nil {
					return err
				}
				if hop.profileType == "chain" {
					return fmt.Errorf("Chain hops in routing profile cannot be of type chain")
				}
				group = append(group, hopID)
			}
			pre.outboundMap[id] = configHopTag(tagRouteChainPrefix, suffix)
			reversed := make([]int64, 0, len(group))
			for index := len(group) - 1; index >= 0; index-- {
				reversed = append(reversed, group[index])
			}
			pre.routeOutboundGroups = append(pre.routeOutboundGroups, reversed)
			suffix += len(group)
		} else {
			pre.outboundMap[id] = configHopTag(tagRouteChainPrefix, suffix)
			pre.routeOutboundGroups = append(pre.routeOutboundGroups, []int64{id})
			suffix++
		}
	}

	if err := builder.collectRuleSets(route); err != nil {
		return err
	}

	if builder.settings.EnableDNSRouting {
		directSites := route.directSites()
		configParseDomainSelectors(directSites, &pre.directDNS)
		pre.needDirectDNSRules = len(directSites) > 0
		proxySites := route.proxySites()
		configParseDomainSelectors(proxySites, &pre.proxyDNS)
		pre.needProxyDNSRules = len(proxySites) > 0
		for _, entry := range route.conditionalSites() {
			selectors := configDomainSelectors{}
			configParseDomainSelectors(entry.sites, &selectors)
			server := tagDNSRemote
			if entry.outboundID == outboundIDDirect {
				server = tagDNSDirect
			}
			pre.conditionalDNS = append(pre.conditionalDNS, configConditionalDNS{
				server:     server,
				conditions: entry.conditions,
				selectors:  selectors,
			})
		}
	}

	configParseSelectorList(route.directIPs(), func(prefix, value string) {
		if prefix == "ip:" {
			pre.directIPCIDRs = append(pre.directIPCIDRs, value)
		}
	})

	if builder.settings.BypassLan() {
		hijacked := route.hijackedIPs(builder.settings.VPNPrivateRanges)
		for _, saved := range builder.settings.VPNPrivateRanges {
			if strings.TrimSpace(saved) == "" {
				continue
			}
			rangeText := configRouteExcludePrefix(saved)
			if rangeText == "" {
				continue
			}
			overlapped := false
			for _, taken := range hijacked {
				if configCIDROverlap(rangeText, taken) {
					overlapped = true
					break
				}
			}
			if !overlapped {
				pre.bypassedPrivateRanges = append(pre.bypassedPrivateRanges, rangeText)
			}
		}
	}
	return nil
}

func configParseDomainSelectors(items []string, sink *configDomainSelectors) {
	configParseSelectorList(items, func(prefix, value string) {
		switch prefix {
		case "ruleset:":
			sink.ruleSets = append(sink.ruleSets, value)
		case "domain:":
			sink.domains = append(sink.domains, value)
		case "suffix:":
			sink.suffixes = append(sink.suffixes, value)
		case "keyword:":
			sink.keywords = append(sink.keywords, value)
		case "regex:":
			sink.regexes = append(sink.regexes, value)
		}
	})
}

// collectRuleSets is get_used_rule_sets / buildRuleSetArray (:1916-1936): an
// .srs URL downloads verbatim under its hashed tag, a srslist name through the
// ruleset_mirror. Unknown names fail here instead of at core start.
func (builder *configBuilder) collectRuleSets(route configRouteProfile) error {
	pre := &builder.pre
	for index, rule := range route.rules {
		if configRuleType(rule.Type) == configRuleTypeEndpointPref {
			continue
		}
		for _, raw := range rule.RuleSet {
			entry := strings.TrimSpace(raw)
			if entry == "" {
				continue
			}
			tag := configRuleSetTagFor(entry)
			if pre.ruleSetTags[tag] {
				continue
			}
			listed := ""
			if configIsRuleSetURL(entry) {
				listed = entry
			} else if entry == configAdblockTag {
				listed = configAdblockURL
			} else if catalogURL, ok := builder.inputs.RuleSetCatalog.URLOf(entry); ok {
				listed = catalogURL
			}
			if listed == "" {
				return fmt.Errorf("Unknown rule-set %q in rule %q of routing profile %q",
					entry, configRuleDisplayName(rule, index), route.name)
			}
			mirrored, err := configMirrorLink(listed, builder.settings.RuleSetMirror)
			if err != nil {
				return fmt.Errorf("Rule-set %q in rule %q of routing profile %q: %v",
					entry, configRuleDisplayName(rule, index), route.name, err)
			}
			pre.ruleSetTags[tag] = true
			pre.ruleSets = append(pre.ruleSets, configRuleSetDefinition{tag: tag, url: mirrored})
		}
	}
	return nil
}

func configRuleDisplayName(rule simpleConfigRouteRule, index int) string {
	if strings.TrimSpace(rule.Name) != "" {
		return rule.Name
	}
	return "#" + fmt.Sprint(index+1)
}

// --- sections -----------------------------------------------------------------

// buildLogSection is buildLogSection (:757-759).
func (builder *configBuilder) buildLogSection() map[string]any {
	return map[string]any{"level": builder.settings.LogLevel}
}

// buildNTPSection is buildNTPSection (:761-771).
func (builder *configBuilder) buildNTPSection() map[string]any {
	if !builder.settings.NTPEnabled {
		return nil
	}
	detour := tagDirect
	if builder.settings.NTPOutbound == tagProxy {
		detour = tagProxy
	}
	return map[string]any{
		"enabled":     true,
		"server":      builder.settings.NTPServer,
		"server_port": builder.settings.NTPServerPort,
		"interval":    builder.settings.NTPInterval,
		"detour":      detour,
	}
}

// buildCertificateSection is buildCertificateSection (:773-776).
func (builder *configBuilder) buildCertificateSection() map[string]any {
	store := "system"
	if builder.settings.UseMozillaCerts {
		store = "mozilla"
	}
	return map[string]any{"store": store}
}

// buildInboundSection is buildInboundSection (:1118-1210): dns-in, mixed-in,
// tun-in, then the custom inbounds.
func (builder *configBuilder) buildInboundSection() []any {
	inbounds := []any{}
	inbounds = append(inbounds, map[string]any{
		"tag":         tagDNSIn,
		"type":        "direct",
		"listen":      "127.0.0.1",
		"listen_port": builder.settings.CoreDNSInPort,
	})
	if builder.settings.MixedInboundEnabled(builder.inputs.Mode) {
		mixed := map[string]any{
			"tag":         tagMixedIn,
			"type":        "mixed",
			"listen":      builder.settings.InboundAddress,
			"listen_port": builder.settings.InboundSocksPort,
		}
		if builder.settings.InboundAuth {
			mixed["users"] = []any{map[string]any{
				"username": builder.settings.InboundUser,
				"password": builder.settings.InboundPass,
			}}
		}
		inbounds = append(inbounds, mixed)
	}
	if builder.vpnMode {
		inbounds = append(inbounds, builder.buildTunInbound())
	}
	custom := configParseJSONObject(builder.settings.CustomInbound)
	for _, item := range configJSONArray(custom, "inbounds") {
		inbounds = append(inbounds, item)
	}
	return inbounds
}

// buildTunInbound is the tun inbound of :1141-1180 with the Android field set of
// design §2.4 (no interface_name/auto_redirect, package lists, platform
// http_proxy, explicit 1.14 dns_mode, no stack).
func (builder *configBuilder) buildTunInbound() map[string]any {
	tun := map[string]any{
		"tag":          tagTunIn,
		"type":         "tun",
		"auto_route":   true,
		"mtu":          builder.settings.VPNMtu,
		"strict_route": true,
	}
	address := []any{builder.settings.VPNTunIPv4CIDR}
	if builder.settings.VPNIPv6 {
		address = append(address, builder.settings.VPNTunIPv6CIDR)
	}
	tun["address"] = address
	tun["route_exclude_address"] = configStringsToAny(builder.routeExcludeAddresses())
	tun["dns_mode"] = "hijack"
	if builder.settings.ProxyApps {
		packages := configStringArray(configSplitLines(builder.settings.Individual))
		if len(packages) > 0 {
			if builder.settings.PerAppBypass {
				tun["exclude_package"] = packages
			} else {
				tun["include_package"] = packages
			}
		}
	}
	if builder.settings.MixedInboundEnabled(builder.inputs.Mode) && builder.settings.AppendHTTPProxy && !builder.settings.InboundAuth {
		httpProxy := map[string]any{
			"enabled":     true,
			"server":      "127.0.0.1",
			"server_port": builder.settings.InboundSocksPort,
		}
		bypass := configStringArray(configSplitLines(builder.settings.HTTPProxyBypass))
		if len(bypass) > 0 {
			httpProxy["bypass_domain"] = bypass
		}
		tun["platform"] = map[string]any{"http_proxy": httpProxy}
	}
	return tun
}

// routeExcludeAddresses is routeExcludeAddress (:1158-1178): loopback,
// broadcast and the bypassed private ranges while the bypass is on, plus the
// direct ip_cidr values with enable_tun_routing, minus the tun's own subnets.
func (builder *configBuilder) routeExcludeAddresses() []string {
	excluded := make([]string, 0)
	if builder.settings.BypassLan() {
		excluded = append(excluded, "127.0.0.0/8", "255.255.255.255/32")
		excluded = append(excluded, builder.pre.bypassedPrivateRanges...)
	}
	if builder.settings.EnableTunRouting {
		for _, item := range builder.pre.directIPCIDRs {
			text := strings.TrimSpace(item)
			zone := strings.IndexByte(text, '%')
			if zone > 0 && strings.Contains(text[:zone], ":") && !strings.Contains(text, "/") {
				text = text[:zone]
			}
			if prefix := configRouteExcludePrefix(text); prefix != "" {
				excluded = append(excluded, prefix)
			}
		}
	}
	excluded = configSubtractCIDR(excluded, builder.settings.VPNTunIPv4CIDR)
	if builder.settings.VPNIPv6 {
		excluded = configSubtractCIDR(excluded, builder.settings.VPNTunIPv6CIDR)
	}
	return excluded
}

// buildOutboundsSection is buildOutboundsSection (:1795-1911): the main chain,
// one chain per route outbound, then `direct`.
func (builder *configBuilder) buildOutboundsSection(profile configOutbound, route configRouteProfile) error {
	hopIDs := make([]int64, 0, len(profile.hops)+2)
	if builder.request.landingProxyID > 0 {
		hopIDs = append(hopIDs, builder.request.landingProxyID)
	}
	if profile.profileType == "chain" {
		hopIDs = append(hopIDs, configUnwrapChain(profile)...)
	} else {
		hopIDs = append(hopIDs, profile.id)
	}
	if builder.request.frontProxyID > 0 {
		hopIDs = append(hopIDs, builder.request.frontProxyID)
	}
	if len(hopIDs) == 0 {
		return fmt.Errorf("The chain has no hops")
	}
	if _, err := configBuildChain(builder.inputs.Profiles, builder.settings, hopIDs,
		tagMainChainPrefix, true, true, 0, &builder.outbounds); err != nil {
		return err
	}

	routeSuffix := 0
	for _, group := range builder.pre.routeOutboundGroups {
		if _, err := configBuildChain(builder.inputs.Profiles, builder.settings, group,
			tagRouteChainPrefix, false, len(group) > 1, routeSuffix, &builder.outbounds); err != nil {
			return err
		}
		routeSuffix += len(group)
	}
	builder.outbounds = append(builder.outbounds, map[string]any{"type": "direct", "tag": tagDirect})
	return nil
}

// buildDNSSection is buildDNSSection (:873-1114) without the Tailscale,
// tunnel-DNS, extra-core and DNS-server hijack rules.
func (builder *configBuilder) buildDNSSection(useDNSObject bool) (map[string]any, error) {
	settings := builder.settings
	if builder.ctx.useDNSObject && useDNSObject {
		dns := configParseJSONObject(settings.DNSObject)
		if builder.deferRuleSets {
			if rules, ok := dns["rules"].([]any); ok {
				filtered := make([]any, 0, len(rules))
				for _, rule := range rules {
					if configReferencesRuleSet(rule) {
						continue
					}
					filtered = append(filtered, rule)
				}
				dns["rules"] = filtered
			}
		}
		return dns, nil
	}
	servers := []any{}
	rules := []any{}
	headRules := []any{}

	remoteDNS := configBuildDNSObj(settings.RemoteDNS)
	remoteDNS["tag"] = tagDNSRemote
	remoteDNS["domain_resolver"] = tagDNSLocal
	remoteDNS["detour"] = tagProxy
	servers = append(servers, remoteDNS)

	directDNS := configBuildDNSObj(settings.DirectDNS)
	directDNS["tag"] = tagDNSDirect
	directDNS["domain_resolver"] = tagDNSLocal
	servers = append(servers, directDNS)

	if guard := builder.appFamilyGuard(); guard != nil {
		headRules = append(headRules, guard)
	}

	if settings.DNSPredefinedEnable {
		predefined := configParsePredefinedDNS(settings.DNSPredefinedRules)
		for _, entry := range predefined {
			builder.emitPredefinedFamily(&headRules, entry.domain, entry.v4, "A")
			builder.emitPredefinedFamily(&headRules, entry.domain, entry.v6, "AAAA")
		}
	}

	if settings.DNSUseHosts {
		servers = append(servers, map[string]any{"tag": tagDNSHosts, "type": "hosts"})
		headRules = append(headRules, map[string]any{
			"preferred_by":  []any{tagDNSHosts},
			"query_type":    []any{"A", "AAAA"},
			"action":        "route",
			"server":        tagDNSHosts,
			"disable_cache": true,
		})
	}

	independentCache := false
	if settings.FakeDNS {
		fakeServer := map[string]any{"tag": tagDNSFake, "type": "fakeip", "inet4_range": "198.18.0.0/15"}
		if !settings.FakeIPDisableIPv6 {
			fakeServer["inet6_range"] = "2001:db8::/32"
		}
		servers = append(servers, fakeServer)
		rules = append(rules, map[string]any{
			"query_type": []any{"A", "AAAA"},
			"action":     "route",
			"server":     tagDNSFake,
		})
		independentCache = true
	}

	for _, entry := range builder.pre.conditionalDNS {
		disableIPv6 := settings.RemoteDNSDisableIPv6
		if entry.server == tagDNSDirect {
			disableIPv6 = builder.ctx.directDNSDisableIPv6
		}
		builder.appendDNSRoutingRules(&rules, entry.selectors, entry.server, disableIPv6, entry.conditions)
	}
	if builder.pre.needDirectDNSRules {
		builder.appendDNSRoutingRules(&rules, builder.pre.directDNS, tagDNSDirect, builder.ctx.directDNSDisableIPv6, nil)
	}
	useDirectFinalDNS := settings.DNSFinalOut == "direct"
	if builder.pre.needProxyDNSRules && useDirectFinalDNS {
		builder.appendDNSRoutingRules(&rules, builder.pre.proxyDNS, tagDNSRemote, settings.RemoteDNSDisableIPv6, nil)
	}
	finalServer := tagDNSRemote
	finalDisableIPv6 := settings.RemoteDNSDisableIPv6
	if useDirectFinalDNS {
		finalServer = tagDNSDirect
		finalDisableIPv6 = builder.ctx.directDNSDisableIPv6
	}
	builder.appendDNSRoute(&rules, nil, finalServer, finalDisableIPv6)

	underlying := settings.CoreBoxUnderlyingDNS
	if underlying == "" {
		underlying = "local"
	}
	localDNS := configBuildDNSObj(underlying)
	localDNS["tag"] = tagDNSLocal
	servers = append(servers, localDNS)

	allRules := make([]any, 0, len(headRules)+len(rules))
	allRules = append(allRules, headRules...)
	allRules = append(allRules, rules...)
	dns := map[string]any{
		"servers":        servers,
		"rules":          allRules,
		"cache_capacity": settings.DNSCacheCapacity,
	}
	if settings.DNSDisableCache {
		dns["disable_cache"] = true
	}
	if settings.DNSDisableExpire {
		dns["disable_expire"] = true
	}
	if settings.DNSReverseMapping {
		dns["reverse_mapping"] = true
	}
	if independentCache {
		dns["independent_cache"] = true
	}
	if timeout := configValidDuration(settings.DNSQueryTimeout); timeout != "" {
		dns["timeout"] = timeout
	}
	if settings.DNSOptimistic && !settings.DNSDisableCache && !settings.DNSDisableExpire {
		if optimisticTimeout := configValidDuration(settings.DNSOptimisticTimeout); optimisticTimeout != "" {
			dns["optimistic"] = map[string]any{"enabled": true, "timeout": optimisticTimeout}
		} else {
			dns["optimistic"] = true
		}
	}
	return dns, nil
}

// appFamilyGuard is appFamilyGuard (#90): without FakeIP apps resolve names
// themselves, so the other family is answered empty instead of falling through.
func (builder *configBuilder) appFamilyGuard() map[string]any {
	if builder.settings.FakeDNS {
		return nil
	}
	var dropped string
	switch builder.settings.DomainStrategy {
	case "ipv4_only":
		dropped = "AAAA"
	case "ipv6_only":
		if builder.vpnMode && !builder.settings.VPNIPv6 {
			return nil
		}
		dropped = "A"
	default:
		return nil
	}
	return map[string]any{
		"inbound":    []any{tagDNSIn, tagMixedIn, tagTunIn},
		"query_type": []any{dropped},
		"action":     "predefined",
	}
}

// appendDNSRoutingRules is appendDnsRoutingRules (:386-399): one rule-set rule
// and one inline rule that always carries all four keys, both narrowed by the
// route rule's network conditions if it has any.
func (builder *configBuilder) appendDNSRoutingRules(
	rules *[]any, selectors configDomainSelectors, server string, disableIPv6 bool, conditions map[string]any,
) {
	if len(selectors.ruleSets) > 0 && !builder.deferRuleSets {
		merged := configCopyConditions(conditions)
		merged["rule_set"] = configStringsToAny(selectors.ruleSets)
		builder.appendDNSRoute(rules, merged, server, disableIPv6)
	}
	if selectors.hasInlineConditions() {
		merged := configCopyConditions(conditions)
		merged["domain"] = configStringsToAny(selectors.domains)
		merged["domain_suffix"] = configStringsToAny(selectors.suffixes)
		merged["domain_keyword"] = configStringsToAny(selectors.keywords)
		merged["domain_regex"] = configStringsToAny(selectors.regexes)
		builder.appendDNSRoute(rules, merged, server, disableIPv6)
	}
}

func configCopyConditions(conditions map[string]any) map[string]any {
	copied := make(map[string]any, len(conditions)+4)
	for key, value := range conditions {
		copied[key] = value
	}
	return copied
}

// configReferencesRuleSet is referencesRuleSet: a DNS rule, or a logical one's
// sub-rule, that matches a rule-set.
func configReferencesRuleSet(rule any) bool {
	object, ok := rule.(map[string]any)
	if !ok {
		return false
	}
	if _, present := object["rule_set"]; present {
		return true
	}
	if rules, ok := object["rules"].([]any); ok {
		for _, subRule := range rules {
			if configReferencesRuleSet(subRule) {
				return true
			}
		}
	}
	return false
}

// emitPredefinedFamily is emitPredefinedFamily: a family without an address is
// refused with NXDOMAIN rather than passed through.
func (builder *configBuilder) emitPredefinedFamily(rules *[]any, domain string, addresses []string, recordType string) {
	if len(addresses) == 0 {
		*rules = append(*rules, map[string]any{
			"domain":     domain,
			"action":     "predefined",
			"query_type": recordType,
			"rcode":      "NXDOMAIN",
		})
		return
	}
	answers := make([]any, 0, len(addresses))
	for _, address := range addresses {
		answers = append(answers, "*. IN "+recordType+" "+address)
	}
	*rules = append(*rules, map[string]any{
		"domain":     domain,
		"action":     "predefined",
		"query_type": recordType,
		"rcode":      "NOERROR",
		"answer":     answers,
	})
}

// appendDNSRoute is appendDnsRoute (:370-383): the AAAA guard answers empty
// instead of falling through to another server.
func (builder *configBuilder) appendDNSRoute(rules *[]any, conditions map[string]any, server string, disableIPv6 bool) {
	if disableIPv6 {
		guard := configCopyConditions(conditions)
		guard["query_type"] = []any{"AAAA"}
		guard["action"] = "predefined"
		*rules = append(*rules, guard)
	}
	route := configCopyConditions(conditions)
	route["action"] = "route"
	route["server"] = server
	*rules = append(*rules, route)
}

// buildRouteSection is buildRouteSection (:1957-2146) for the global table.
func (builder *configBuilder) buildRouteSection(route configRouteProfile) (map[string]any, error) {
	profileRules, err := builder.getRouteRules(route)
	if err != nil {
		return nil, err
	}
	rules := []any{}
	rules = append(rules, map[string]any{"action": "sniff"})
	if builder.settings.DomainStrategy != "" {
		rules = append(rules, map[string]any{
			"inbound":  []any{tagMixedIn, tagTunIn},
			"action":   "resolve",
			"strategy": builder.settings.DomainStrategy,
		})
	}
	rules = append(rules, map[string]any{"protocol": "dns", "action": "hijack-dns"})
	rules = append(rules, map[string]any{"inbound": tagDNSIn, "action": "reject"})
	rules = append(rules, profileRules...)

	defaultOutbound := route.defaultOutboundID
	if defaultOutbound == outboundIDBlock {
		rules = append(rules, map[string]any{"action": "reject"})
	}
	ruleSetArray, err := builder.buildRuleSetArray()
	if err != nil {
		return nil, err
	}
	final := configOutboundName(defaultOutbound)
	switch defaultOutbound {
	case outboundIDBlock:
		final = tagDirect
	case outboundIDWarpBypass:
		if builder.settings.EnableWarp {
			final = tagWarpBypass
		} else {
			final = tagProxy
		}
	}
	routeObject := map[string]any{
		"rules":                   rules,
		"rule_set":                ruleSetArray,
		"final":                   final,
		"default_domain_resolver": builder.directDomainResolver(),
	}
	if builder.settings.TrafficStatsAlwaysOn() {
		routeObject["find_process"] = true
	}
	if builder.vpnMode {
		routeObject["auto_detect_interface"] = true
	}
	return routeObject, nil
}

// configOutboundName is OutboundIds.toName.
func configOutboundName(id int64) string {
	switch id {
	case outboundIDProxy:
		return "proxy"
	case outboundIDDirect:
		return "direct"
	case outboundIDBlock:
		return "block"
	case outboundIDWarpBypass:
		return "warp-bypass"
	default:
		return "unknown"
	}
}

func (builder *configBuilder) directDomainResolver() map[string]any {
	return map[string]any{
		"server":   tagDNSDirect,
		"strategy": builder.ctx.directDomainStrategy(),
	}
}

// getRouteRules is getRouteRules(false, outboundMap) with get_rule_json: simple
// rules without a condition are skipped and the adblock reject goes in front of
// the first `route` rule, else last.
func (builder *configBuilder) getRouteRules(route configRouteProfile) ([]any, error) {
	out := []any{}
	addedAdblock := false
	for _, rule := range route.rules {
		ruleType := configRuleType(rule.Type)
		if ruleType == configRuleTypeEndpointPref {
			continue
		}
		if ruleType != configRuleTypeCustom && configRuleIsEmpty(rule) {
			continue
		}
		ruleJSON, err := configRuleConfigJSON(rule, builder.pre.outboundMap[rule.OutboundID])
		if err != nil {
			return nil, err
		}
		if len(ruleJSON) == 0 {
			return nil, fmt.Errorf("Aborted generating routing section, an error has occurred")
		}
		_, stripped := ruleJSON["tls_spoof"]
		delete(ruleJSON, "tls_spoof")
		delete(ruleJSON, "tls_spoof_method")
		if fallback, present := ruleJSON["tls_fragment_fallback_delay"].(string); present &&
			configValidDuration(fallback) == "" {
			delete(ruleJSON, "tls_fragment_fallback_delay")
			stripped = true
		}
		if ruleJSON["action"] == "route-options" {
			if _, fragment := ruleJSON["tls_fragment"]; fragment {
				if _, record := ruleJSON["tls_record_fragment"]; record {
					delete(ruleJSON, "tls_record_fragment")
				}
			}
		}
		if stripped && ruleJSON["action"] == "route-options" && !configHasRouteOption(ruleJSON) {
			continue
		}
		if !addedAdblock && builder.settings.AdblockEnable && ruleJSON["action"] == "route" {
			out = append(out, builder.adblockRule())
			addedAdblock = true
		}
		out = append(out, ruleJSON)
	}
	if !addedAdblock && builder.settings.AdblockEnable {
		out = append(out, builder.adblockRule())
	}
	return out, nil
}

func configHasRouteOption(ruleJSON map[string]any) bool {
	for _, key := range configRouteOptionKeys {
		if _, present := ruleJSON[key]; present {
			return true
		}
	}
	return false
}

func (builder *configBuilder) adblockRule() map[string]any {
	return map[string]any{"action": "reject", "rule_set": []any{configAdblockTag}}
}

// buildRuleSetArray is buildRuleSetArray (:1916-1955): the profile's sets, then
// adblock; always present.
func (builder *configBuilder) buildRuleSetArray() ([]any, error) {
	out := make([]any, 0, len(builder.pre.ruleSets)+1)
	for _, definition := range builder.pre.ruleSets {
		out = append(out, builder.remoteRuleSet(definition.tag, definition.url))
	}
	if builder.settings.AdblockEnable && !builder.pre.ruleSetTags[configAdblockTag] {
		mirrored, err := configMirrorLink(configAdblockURL, builder.settings.RuleSetMirror)
		if err != nil {
			return nil, err
		}
		out = append(out, builder.remoteRuleSet(configAdblockTag, mirrored))
	}
	return out, nil
}

func (builder *configBuilder) remoteRuleSet(tag, url string) map[string]any {
	ruleSet := map[string]any{
		"type":         "remote",
		"tag":          tag,
		"format":       "binary",
		"url":          url,
		"initial_path": configEmptyRuleSetPath,
	}
	if builder.deferRuleSets {
		ruleSet["http_client"] = map[string]any{"detour": tagProxy}
	}
	return ruleSet
}

// buildExperimentalSection is buildExperimentalSection (:2133-2155).
func (builder *configBuilder) buildExperimentalSection() map[string]any {
	experimental := map[string]any{}
	if clashAPI := builder.clashAPIObject(); clashAPI != nil {
		experimental["clash_api"] = clashAPI
	}
	experimental["cache_file"] = map[string]any{
		"enabled":      true,
		"store_fakeip": builder.settings.DNSPersistCache || builder.settings.FakeDNS,
		"store_dns":    builder.settings.DNSPersistCache,
	}
	return experimental
}

// clashAPIObject is ConfigGenerator.clashApiObject: null when the API is off,
// and also when it is on without a secret.
func (builder *configBuilder) clashAPIObject() map[string]any {
	settings := builder.settings
	if !settings.ClashAPIEnabled() {
		return nil
	}
	if strings.TrimSpace(settings.CoreBoxClashAPISecret) == "" {
		return nil
	}
	listenHost := strings.TrimSpace(settings.CoreBoxClashListenAddr)
	if listenHost == "" {
		listenHost = "127.0.0.1"
	}
	if strings.Contains(listenHost, ":") && !strings.HasPrefix(listenHost, "[") &&
		!configIsIPv6Address(configSubstringBefore(listenHost, "%")) {
		listenHost = "[" + listenHost + "]"
	}
	clashAPI := map[string]any{
		"external_controller": listenHost + ":" + fmt.Sprint(settings.ClashAPIPort()),
		"secret":              settings.CoreBoxClashAPISecret,
	}
	externalUI := "dashboard"
	if externalUI != "" {
		clashAPI["external_ui"] = externalUI
	}
	return clashAPI
}

func configIsIPv6Address(text string) bool {
	address, err := netip.ParseAddr(text)
	return err == nil && address.Is6()
}

// buildServicesSection is buildServicesSection (:2186-2212): the core builds
// the traffic tracker from the presence of an api service; with a port it also
// serves the bundled dashboard.
func (builder *configBuilder) buildServicesSection() []any {
	dashboard := builder.settings.CoreBoxAPIPort > 0
	if !dashboard && !builder.settings.TrafficStatsAlwaysOn() {
		return nil
	}
	listenPort := 0
	if dashboard {
		listenPort = builder.settings.CoreBoxAPIPort
	}
	api := map[string]any{
		"type":        "api",
		"listen":      "127.0.0.1",
		"listen_port": listenPort,
		"secret":      builder.settings.CoreBoxAPISecret,
	}
	if dashboard {
		api["access_control_allow_origin"] = []any{"http://127.0.0.1:" + fmt.Sprint(builder.settings.CoreBoxAPIPort)}
		api["dashboard"] = map[string]any{"enabled": true, "path": configDashboardPath}
	}
	return []any{api}
}

// TrafficStatsAlwaysOn mirrors GeneratorSettings.trafficStats: the enable_stats
// toggle was removed, so core accounting (route.find_process and the api
// service) is always on.
func (settings simpleConfigSettings) TrafficStatsAlwaysOn() bool { return true }

// --- small helpers ------------------------------------------------------------

// configParseJSONObject is JsonInput.parseObject: an empty object on any
// failure or when the text is not an object.
func configParseJSONObject(text string) map[string]any {
	if strings.TrimSpace(text) == "" {
		return map[string]any{}
	}
	var value any
	if err := json.Unmarshal([]byte(text), &value); err != nil {
		return map[string]any{}
	}
	object, ok := value.(map[string]any)
	if !ok {
		return map[string]any{}
	}
	return object
}

func configJSONArray(object map[string]any, key string) []any {
	value, _ := object[key].([]any)
	return value
}

func configStringsToAny(values []string) []any {
	array := make([]any, 0, len(values))
	for _, value := range values {
		array = append(array, value)
	}
	return array
}

// configStringArray is JsonValues.stringArray: trailing blanks dropped, empty
// array when nothing is left.
func configStringArray(values []string) []any {
	array := make([]any, 0, len(values))
	for _, value := range values {
		if strings.TrimSpace(value) == "" {
			continue
		}
		array = append(array, value)
	}
	return array
}

// configSplitLines is GeneratorSettings.splitLines: a newline separated list
// with blanks and `#` comments dropped.
func configSplitLines(text string) []string {
	lines := strings.Split(text, "\n")
	out := make([]string, 0, len(lines))
	for _, line := range lines {
		trimmed := strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		out = append(out, trimmed)
	}
	return out
}

// configValidDuration is ConfigGenerator.isValidDuration: the sing-box duration
// grammar, not empty.
func configValidDuration(text string) string {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" || !configDurationPattern.MatchString(trimmed) {
		return ""
	}
	return trimmed
}
