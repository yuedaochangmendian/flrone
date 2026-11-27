// Route rules, rule-set tags and URL fencing for the config builder.
//
// The rule JSON is ConfigGenerator.getRouteRules plus RouteRule.toConfigJson
// (get_rule_json): the same key presence, trimming, type ids, effective action
// and app-condition rewriting the Kotlin writer performs. RuleSets.tagFor /
// mirrorLink and RuleSets.tagFor's CRC32 tag are reproduced so a rule and its
// definition share one tag.
package mobile

import (
	"fmt"
	"hash/crc32"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

// OutboundIds (route/OutboundIds.kt).
const (
	outboundIDProxy      int64 = -1
	outboundIDDirect     int64 = -2
	outboundIDBlock      int64 = -3
	outboundIDHijackDNS  int64 = -4
	outboundIDWarpBypass int64 = -5
)

// RuleType ids (RuleType.kt).
const (
	configRuleTypeCustom           = 0
	configRuleTypeSimpleAddrProxy  = 1
	configRuleTypeSimpleAddrBypass = 2
	configRuleTypeSimpleAddrBlock  = 3
	configRuleTypeSimpleProcName   = 4
	configRuleTypeSimpleProcBypass = 5
	configRuleTypeSimpleProcBlock  = 6
	configRuleTypeSimpleProcPath   = 7
	configRuleTypeSimplePathBypass = 8
	configRuleTypeSimplePathBlock  = 9
	configRuleTypeSimpleAddrWarp   = 10
	configRuleTypeSimpleNameWarp   = 11
	configRuleTypeSimplePathWarp   = 12
	configRuleTypeEndpointPref     = 13
)

const (
	configAdblockTag = "throne-adblocksingbox"
	configAdblockURL = "https://raw.githubusercontent.com/217heidai/adblockfilters/main/rules/adblocksingbox.srs"
)

var configSelectorPrefixes = []string{"ruleset:", "domain:", "suffix:", "keyword:", "regex:", "ip:"}

var configRejectMethods = []string{"default", "drop", "reply"}

// configRouteOptionKeys are the JSON fields of RawRouteOptionsActionOptions
// that keep a route-options rule from being empty.
var configRouteOptionKeys = []string{
	"override_address", "override_port", "network_strategy", "fallback_delay", "udp_disable_domain_unmapping",
	"udp_connect", "udp_timeout", "tls_fragment", "tls_fragment_fallback_delay", "tls_record_fragment", "tls_spoof",
	"tls_spoof_method",
}

var configActionKeys = map[string]bool{
	"action": true, "outbound": true, "method": true, "no_drop": true, "override_address": true,
	"override_port": true, "tls_fragment": true, "tls_fragment_fallback_delay": true,
	"tls_record_fragment": true, "tls_spoof": true, "tls_spoof_method": true,
	"override_destination": true, "strategy": true,
}

// configQtToInt is QtStrings.toInt: surrounding whitespace tolerated, optional
// sign, ASCII digits only; 0 on any failure or overflow.
func configQtToInt(text string) int {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return 0
	}
	start := 0
	if trimmed[0] == '+' || trimmed[0] == '-' {
		start = 1
	}
	if start == len(trimmed) {
		return 0
	}
	for index := start; index < len(trimmed); index++ {
		if trimmed[index] < '0' || trimmed[index] > '9' {
			return 0
		}
	}
	value, err := strconv.ParseInt(trimmed, 10, 32)
	if err != nil {
		return 0
	}
	return int(value)
}

func configEffectiveAction(rule simpleConfigRouteRule) string {
	if rule.Action != "route" {
		return rule.Action
	}
	switch rule.OutboundID {
	case outboundIDBlock:
		return "reject"
	case outboundIDHijackDNS:
		return "hijack-dns"
	default:
		return rule.Action
	}
}

func configRuleType(ruleType int) int {
	switch ruleType {
	case configRuleTypeCustom, configRuleTypeSimpleAddrProxy, configRuleTypeSimpleAddrBypass,
		configRuleTypeSimpleAddrBlock, configRuleTypeSimpleProcName, configRuleTypeSimpleProcBypass,
		configRuleTypeSimpleProcBlock, configRuleTypeSimpleProcPath, configRuleTypeSimplePathBypass,
		configRuleTypeSimplePathBlock, configRuleTypeSimpleAddrWarp, configRuleTypeSimpleNameWarp,
		configRuleTypeSimplePathWarp, configRuleTypeEndpointPref:
		return ruleType
	default:
		return configRuleTypeCustom
	}
}

func configIsSimpleAddressRule(ruleType int) bool {
	switch ruleType {
	case configRuleTypeSimpleAddrProxy, configRuleTypeSimpleAddrBypass,
		configRuleTypeSimpleAddrBlock, configRuleTypeSimpleAddrWarp:
		return true
	}
	return false
}

func configBlankList(values []string) bool {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return false
		}
	}
	return true
}

func configPutStrings(target map[string]any, key string, values []string) {
	array := make([]any, 0, len(values))
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		array = append(array, trimmed)
	}
	if len(array) > 0 {
		target[key] = array
	}
}

func configPutInts(target map[string]any, key string, values []string) {
	array := make([]any, 0, len(values))
	for _, value := range values {
		if strings.TrimSpace(value) == "" {
			continue
		}
		array = append(array, configQtToInt(value))
	}
	if len(array) > 0 {
		target[key] = array
	}
}

// configRuleJSON is RouteRule.toRuleJson(forView = false): the rule as the core
// takes it, before the generator's TLS-spoof strip. outboundTag is the tag the
// route outbound map assigned, empty for the bare id path.
func configRuleJSON(rule simpleConfigRouteRule, outboundTag string) map[string]any {
	object := map[string]any{}
	if strings.TrimSpace(rule.IPVersion) != "" {
		object["ip_version"] = configQtToInt(rule.IPVersion)
	}
	if strings.TrimSpace(rule.Network) != "" {
		object["network"] = strings.TrimSpace(rule.Network)
	}
	if strings.TrimSpace(rule.Protocol) != "" {
		object["protocol"] = strings.TrimSpace(rule.Protocol)
	}
	configPutStrings(object, "inbound", rule.Inbound)
	configPutStrings(object, "domain", rule.Domain)
	configPutStrings(object, "domain_suffix", rule.DomainSuffix)
	configPutStrings(object, "domain_keyword", rule.DomainKeyword)
	configPutStrings(object, "domain_regex", rule.DomainRegex)
	configPutStrings(object, "source_ip_cidr", rule.SourceIPCIDR)
	if rule.SourceIPIsPrivate {
		object["source_ip_is_private"] = true
	}
	configPutStrings(object, "ip_cidr", rule.IPCIDR)
	if rule.IPIsPrivate {
		object["ip_is_private"] = true
	}
	configPutInts(object, "source_port", rule.SourcePort)
	configPutStrings(object, "source_port_range", rule.SourcePortRange)
	configPutInts(object, "port", rule.Port)
	configPutStrings(object, "port_range", rule.PortRange)
	configPutStrings(object, "process_name", rule.ProcessName)
	configPutStrings(object, "process_path", rule.ProcessPath)
	configPutStrings(object, "process_path_regex", rule.ProcessPathRegex)
	configPutStrings(object, "package_name", rule.PackageName)
	configPutStrings(object, "package_name_regex", rule.PackageNameRegex)
	configPutStrings(object, "network_type", rule.NetworkType)
	if rule.NetworkIsExpensive {
		object["network_is_expensive"] = true
	}
	configPutStrings(object, "wifi_ssid", rule.WifiSSID)
	configPutStrings(object, "wifi_bssid", rule.WifiBSSID)
	ruleSets := make([]any, 0, len(rule.RuleSet))
	for _, entry := range rule.RuleSet {
		trimmed := strings.TrimSpace(entry)
		if trimmed == "" {
			continue
		}
		ruleSets = append(ruleSets, configRuleSetTagFor(trimmed))
	}
	if len(ruleSets) > 0 {
		object["rule_set"] = ruleSets
	}
	if rule.Invert {
		object["invert"] = true
	}

	action := configEffectiveAction(rule)
	object["action"] = action
	if action == "reject" {
		method := strings.ToLower(strings.TrimSpace(rule.RejectMethod))
		if configContainsString(configRejectMethods, method) {
			object["method"] = method
		}
		if rule.NoDrop && method != "drop" {
			object["no_drop"] = true
		}
	}
	if action == "route" || action == "route-options" || action == "bypass" {
		if strings.TrimSpace(rule.OverrideAddress) != "" {
			object["override_address"] = strings.TrimSpace(rule.OverrideAddress)
		}
		if port := configQtToInt(rule.OverridePort); port > 0 {
			object["override_port"] = port
		}
		if rule.TLSFragment {
			object["tls_fragment"] = true
			if strings.TrimSpace(rule.TLSFragmentFallbackDelay) != "" {
				object["tls_fragment_fallback_delay"] = strings.TrimSpace(rule.TLSFragmentFallbackDelay)
			}
		}
		if rule.TLSRecordFragment {
			object["tls_record_fragment"] = true
		}
		if strings.TrimSpace(rule.TLSSpoof) != "" {
			object["tls_spoof"] = strings.TrimSpace(rule.TLSSpoof)
			if strings.TrimSpace(rule.TLSSpoofMethod) != "" {
				object["tls_spoof_method"] = strings.TrimSpace(rule.TLSSpoofMethod)
			}
		}
		if action == "route" || action == "bypass" {
			if outboundTag != "" {
				object["outbound"] = outboundTag
			} else {
				object["outbound"] = rule.OutboundID
			}
		}
	}
	if action == "sniff" && rule.SniffOverrideDest {
		object["override_destination"] = true
	}
	if action == "resolve" && strings.TrimSpace(rule.Strategy) != "" {
		object["strategy"] = strings.TrimSpace(rule.Strategy)
	}
	return object
}

// configRuleConfigJSON is RouteRule.toConfigJson: apps and package regexes are
// one OR condition, and an unidentified-app entry becomes an inverted `.*`
// package_name_regex, all and-ed with the rule's other conditions.
func configRuleConfigJSON(rule simpleConfigRouteRule, outboundTag string) (map[string]any, error) {
	flat := configRuleJSON(rule, outboundTag)
	apps, _ := flat["package_name"].([]any)
	regexes, _ := flat["package_name_regex"].([]any)
	packages := make([]any, 0, len(apps))
	unknown := false
	for _, value := range apps {
		text, _ := value.(string)
		if text == "unknown" {
			unknown = true
			continue
		}
		packages = append(packages, text)
	}
	if !unknown && (len(packages) == 0 || len(regexes) == 0) {
		return flat, nil
	}
	delete(flat, "package_name")
	delete(flat, "package_name_regex")
	invert := flat["invert"] == true
	delete(flat, "invert")
	logical := map[string]any{"type": "logical", "mode": "and"}
	own := map[string]any{}
	for key, value := range flat {
		if configActionKeys[key] {
			logical[key] = value
		} else {
			own[key] = value
		}
	}
	appRules := make([]any, 0, 3)
	if len(packages) > 0 {
		appRules = append(appRules, map[string]any{"package_name": packages})
	}
	if len(regexes) > 0 {
		appRules = append(appRules, map[string]any{"package_name_regex": regexes})
	}
	if unknown {
		appRules = append(appRules, map[string]any{"package_name_regex": []any{".*"}, "invert": true})
	}
	var appMatch any
	if len(appRules) == 1 {
		appMatch = appRules[0]
	} else {
		appMatch = map[string]any{"type": "logical", "mode": "or", "rules": appRules}
	}
	rules := make([]any, 0, 2)
	if len(own) > 0 {
		rules = append(rules, own)
	}
	rules = append(rules, appMatch)
	logical["rules"] = rules
	if invert {
		logical["invert"] = true
	}
	return logical, nil
}

// configRuleIsEmpty is RouteRule.isEmpty judged on the effective action. For a
// custom rule it builds the JSON without any outbound tag and counts keys.
func configRuleIsEmpty(rule simpleConfigRouteRule) bool {
	ruleType := configRuleType(rule.Type)
	if ruleType != configRuleTypeCustom {
		if ruleType == configRuleTypeEndpointPref {
			return false
		}
		if configIsSimpleAddressRule(ruleType) {
			return configBlankList(rule.Domain) && configBlankList(rule.DomainSuffix) &&
				configBlankList(rule.DomainKeyword) && configBlankList(rule.DomainRegex) &&
				configBlankList(rule.RuleSet) && configBlankList(rule.IPCIDR)
		}
		return configBlankList(rule.ProcessName) && configBlankList(rule.ProcessPath)
	}
	size := len(configRuleJSON(rule, ""))
	switch configEffectiveAction(rule) {
	case "route", "route-options", "hijack-dns":
		return size <= 1
	default:
		return false
	}
}

// --- the route profile (RouteProfile.defaultProfile + the global table) ------

// configRouteProfile is the build's view of the Default profile: the Route DNS
// hijack rule RouteManager.current attaches first, then the global table with
// the disabled/bypass transformations applyBuildRuleFilters performs.
type configRouteProfile struct {
	name              string
	defaultOutboundID int64
	rules             []simpleConfigRouteRule
}

func configDefaultRouteRule() simpleConfigRouteRule {
	return simpleConfigRouteRule{
		Name:       "Route DNS",
		Type:       configRuleTypeCustom,
		Action:     "hijack-dns",
		Protocol:   "dns",
		OutboundID: outboundIDDirect,
	}
}

// configDropStaleOutboundRules is RouteManager.dropStaleOutbounds: a rule naming
// an outbound that no longer exists cannot be part of a build, so it is dropped
// instead of failing the start with a missing tag.
func configDropStaleOutboundRules(rows []simpleConfigRouteRule, profiles []simpleConfigProfile) []simpleConfigRouteRule {
	out := make([]simpleConfigRouteRule, 0, len(rows))
	for _, rule := range rows {
		if rule.OutboundID <= 0 || configFindProfile(profiles, rule.OutboundID) != nil {
			out = append(out, rule)
		}
	}
	return out
}

func configBuildRouteProfile(rows []simpleConfigRouteRule) configRouteProfile {
	rules := make([]simpleConfigRouteRule, 0, len(rows)+1)
	rules = append(rules, configDefaultRouteRule())
	rules = append(rules, rows...)
	filtered := make([]simpleConfigRouteRule, 0, len(rules))
	for _, rule := range rules {
		if rule.Disabled {
			continue
		}
		if rule.Action == "bypass" {
			rule.Action = "route"
		}
		filtered = append(filtered, rule)
	}
	return configRouteProfile{name: "Default", defaultOutboundID: outboundIDProxy, rules: filtered}
}

// configUsedOutboundIDs is RouteProfile.usedOutboundIds: deduplicated, limited
// to rules whose JSON carries an outbound.
func (profile configRouteProfile) usedOutboundIDs() []int64 {
	out := make([]int64, 0, len(profile.rules))
	seen := make(map[int64]bool)
	for _, rule := range profile.rules {
		if configRuleType(rule.Type) == configRuleTypeEndpointPref {
			continue
		}
		action := configEffectiveAction(rule)
		if action == "route" || action == "bypass" {
			if !seen[rule.OutboundID] {
				seen[rule.OutboundID] = true
				out = append(out, rule.OutboundID)
			}
		}
	}
	return out
}

func configUnconditionalRule(rule simpleConfigRouteRule) bool {
	return !rule.Invert && !configRuleMatchesByApp(rule) && len(configNetworkConditions(rule)) == 0
}

func configRuleMatchesByApp(rule simpleConfigRouteRule) bool {
	return !configBlankList(rule.PackageName) || !configBlankList(rule.PackageNameRegex)
}

func configNetworkConditions(rule simpleConfigRouteRule) map[string]any {
	conditions := map[string]any{}
	configPutStrings(conditions, "network_type", rule.NetworkType)
	if rule.NetworkIsExpensive {
		conditions["network_is_expensive"] = true
	}
	configPutStrings(conditions, "wifi_ssid", rule.WifiSSID)
	configPutStrings(conditions, "wifi_bssid", rule.WifiBSSID)
	return conditions
}

func configRuleSites(rule simpleConfigRouteRule) []string {
	out := make([]string, 0)
	for _, entry := range rule.RuleSet {
		trimmed := strings.TrimSpace(entry)
		if strings.HasPrefix(trimmed, "geosite-") {
			out = append(out, "ruleset:"+trimmed)
		}
	}
	configAddPrefixed(&out, "domain:", rule.Domain)
	configAddPrefixed(&out, "suffix:", rule.DomainSuffix)
	configAddPrefixed(&out, "keyword:", rule.DomainKeyword)
	configAddPrefixed(&out, "regex:", rule.DomainRegex)
	return out
}

func configAddPrefixed(out *[]string, prefix string, values []string) {
	for _, value := range values {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" {
			*out = append(*out, prefix+trimmed)
		}
	}
}

// configSites is RouteProfile.directSites / proxySites.
func (profile configRouteProfile) configSites(outboundID int64) []string {
	out := make([]string, 0)
	for _, rule := range profile.rules {
		if rule.OutboundID != outboundID || rule.Action != "route" || !configUnconditionalRule(rule) {
			continue
		}
		out = append(out, configRuleSites(rule)...)
	}
	return out
}

func (profile configRouteProfile) directSites() []string {
	return profile.configSites(outboundIDDirect)
}

func (profile configRouteProfile) proxySites() []string { return profile.configSites(outboundIDProxy) }

// configConditionalDnsSites is RouteProfile.conditionalSites: direct and proxy
// route rules that apply only on some networks, in rule order.
type configConditionalDnsSites struct {
	outboundID int64
	conditions map[string]any
	sites      []string
}

func (profile configRouteProfile) conditionalSites() []configConditionalDnsSites {
	out := make([]configConditionalDnsSites, 0)
	for _, rule := range profile.rules {
		if rule.OutboundID != outboundIDDirect && rule.OutboundID != outboundIDProxy {
			continue
		}
		if rule.Action != "route" || rule.Invert || configRuleMatchesByApp(rule) {
			continue
		}
		conditions := configNetworkConditions(rule)
		if len(conditions) == 0 {
			continue
		}
		sites := configRuleSites(rule)
		if len(sites) == 0 {
			continue
		}
		out = append(out, configConditionalDnsSites{
			outboundID: rule.OutboundID,
			conditions: conditions,
			sites:      sites,
		})
	}
	return out
}

// configDirectIPs is RouteProfile.directIps over the unconditional rules only.
func (profile configRouteProfile) directIPs() []string {
	out := make([]string, 0)
	for _, rule := range profile.rules {
		if rule.OutboundID != outboundIDDirect || rule.Action != "route" || !configUnconditionalRule(rule) {
			continue
		}
		for _, entry := range rule.RuleSet {
			trimmed := strings.TrimSpace(entry)
			if strings.HasPrefix(trimmed, "geoip-") {
				out = append(out, "ruleset:"+trimmed)
			}
		}
		configAddPrefixed(&out, "ip:", rule.IPCIDR)
	}
	return out
}

// configHijackedIPs is RouteProfile.hijackedIps: the CIDRs non-direct route and
// reject rules take away from direct.
func (profile configRouteProfile) hijackedIPs(privateRanges []string) []string {
	out := make([]string, 0)
	for _, rule := range profile.rules {
		if rule.Action == "route" && rule.OutboundID == outboundIDDirect {
			continue
		}
		if rule.Action != "route" && rule.Action != "reject" {
			continue
		}
		if rule.IPIsPrivate {
			configAddPrefixed(&out, "", privateRanges)
		}
		configAddPrefixed(&out, "", rule.IPCIDR)
	}
	return out
}

// configParseSelectorList is ConfigGenerator.parseSelectorList: the first
// prefix a trimmed item starts with takes the trimmed rest, if any.
func configParseSelectorList(items []string, sink func(prefix, value string)) {
	for _, raw := range items {
		item := strings.TrimSpace(raw)
		for _, prefix := range configSelectorPrefixes {
			if !strings.HasPrefix(item, prefix) {
				continue
			}
			value := strings.TrimSpace(item[len(prefix):])
			if value != "" {
				sink(prefix, value)
			}
			break
		}
	}
}

// --- rule-set tags, mirrors and URL fencing ---------------------------------

var configURLPattern = regexp.MustCompile(`^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)([^?#]*)`)

type configURLParts struct {
	scheme string
	host   string
	path   string
}

// configParseURLText is UrlText.parse: the scheme, the authority's host
// (lower-cased) and the path.
func configParseURLText(text string) (configURLParts, bool) {
	match := configURLPattern.FindStringSubmatch(text)
	if match == nil {
		return configURLParts{}, false
	}
	authority := match[2]
	if at := strings.LastIndexByte(authority, '@'); at >= 0 {
		authority = authority[at+1:]
	}
	host := authority
	if strings.HasPrefix(authority, "[") {
		if closeIndex := strings.Index(authority, "]"); closeIndex >= 0 {
			host = authority[:closeIndex+1]
		} else {
			host = authority
		}
	} else if colon := strings.IndexByte(authority, ':'); colon >= 0 {
		host = authority[:colon]
	}
	return configURLParts{scheme: strings.ToLower(match[1]), host: strings.ToLower(host), path: match[3]}, true
}

// configURLFileName is UrlText.fileName: the last path segment, fully decoded.
func configURLFileName(text string) string {
	parts, ok := configParseURLText(text)
	if !ok {
		return ""
	}
	segment := parts.path
	if slash := strings.LastIndexByte(segment, '/'); slash >= 0 {
		segment = segment[slash+1:]
	}
	return configURLPercentDecode(segment)
}

func configURLPercentDecode(text string) string {
	if !strings.Contains(text, "%") {
		return text
	}
	var out []byte
	for index := 0; index < len(text); index++ {
		if text[index] == '%' && index+2 < len(text) {
			high, highOK := configHexDigit(text[index+1])
			low, lowOK := configHexDigit(text[index+2])
			if highOK && lowOK {
				out = append(out, byte(high*16+low))
				index += 2
				continue
			}
		}
		out = append(out, text[index])
	}
	return string(out)
}

func configHexDigit(character byte) (int, bool) {
	switch {
	case character >= '0' && character <= '9':
		return int(character - '0'), true
	case character >= 'a' && character <= 'f':
		return int(character-'a') + 10, true
	case character >= 'A' && character <= 'F':
		return int(character-'A') + 10, true
	}
	return 0, false
}

// configIsRuleSetURL is RuleSets.isUrl: an http(s) URL whose file name contains
// ".srs" (get_rule_set_name).
func configIsRuleSetURL(entry string) bool {
	parts, ok := configParseURLText(strings.TrimSpace(entry))
	if !ok || (parts.scheme != "http" && parts.scheme != "https") {
		return false
	}
	return strings.Contains(configURLFileName(strings.TrimSpace(entry)), ".srs")
}

// configRuleSetTagFor is RuleSets.tagFor: names unchanged; URLs become
// `<file with .srs -> -srs>-<crc32 of the URL>`.
func configRuleSetTagFor(entry string) string {
	trimmed := strings.TrimSpace(entry)
	if !configIsRuleSetURL(trimmed) {
		return trimmed
	}
	crc := crc32.ChecksumIEEE([]byte(trimmed))
	name := strings.ReplaceAll(configURLFileName(trimmed), ".srs", "-srs")
	digest := strconv.FormatUint(uint64(crc), 16)
	if len(digest) < 8 {
		digest = strings.Repeat("0", 8-len(digest)) + digest
	}
	return name + "-" + digest
}

// configMirrorLink is RuleSets.mirrorLink: raw.githubusercontent.com URLs
// through the chosen jsDelivr mirror, validated at both ends.
func configMirrorLink(url string, mirror int) (string, error) {
	checked, err := configRequirePublicHTTP(url)
	if err != nil {
		return "", err
	}
	if mirror == 0 {
		return checked, nil
	}
	parts, ok := configParseURLText(checked)
	if !ok || parts.host != "raw.githubusercontent.com" {
		return checked, nil
	}
	var prefix string
	switch mirror {
	case 2:
		prefix = "https://gcore.jsdelivr.net/gh"
	case 3:
		prefix = "https://quantil.jsdelivr.net/gh"
	case 4:
		prefix = "https://fastly.jsdelivr.net/gh"
	case 5:
		prefix = "https://cdn.jsdelivr.net/gh"
	default:
		prefix = "https://testingcf.jsdelivr.net/gh"
	}
	var builder strings.Builder
	builder.WriteString(prefix)
	index := 0
	for _, segment := range strings.Split(parts.path, "/") {
		if segment == "" {
			continue
		}
		if index == 2 {
			builder.WriteString("@")
		} else {
			builder.WriteString("/")
		}
		builder.WriteString(segment)
		index++
	}
	return configRequirePublicHTTP(builder.String())
}

var configBlockedHostNames = map[string]bool{
	"localhost": true, "localhost.localdomain": true, "ip6-localhost": true, "ip6-loopback": true, "metadata": true,
}

var configURLAuthorityPattern = regexp.MustCompile(`^([A-Za-z][A-Za-z0-9+.-]*)://([^/?#]*)`)

// configRequirePublicHTTP is UrlSafety.requirePublicHttp: scheme, userinfo and
// the host as written, with no DNS work. A rule-set URL is importable input, so
// loopback/LAN literals must never reach the downloader.
func configRequirePublicHTTP(url string) (string, error) {
	trimmed := strings.TrimSpace(url)
	if trimmed == "" {
		return "", fmt.Errorf("the URL is empty")
	}
	match := configURLAuthorityPattern.FindStringSubmatch(trimmed)
	if match == nil {
		return "", fmt.Errorf("the URL is not parseable")
	}
	scheme := strings.ToLower(match[1])
	if scheme != "http" && scheme != "https" {
		return "", fmt.Errorf("only http and https URLs are allowed, not %q", match[1])
	}
	authority := match[2]
	if authority == "" {
		return "", fmt.Errorf("the URL has no host")
	}
	if strings.Contains(authority, "@") {
		return "", fmt.Errorf("the URL must not carry credentials")
	}
	host := authority
	if strings.HasPrefix(authority, "[") {
		closeIndex := strings.Index(authority, "]")
		if closeIndex < 0 {
			return "", fmt.Errorf("the URL has no host")
		}
		host = authority[:closeIndex+1]
	} else if colon := strings.IndexByte(authority, ':'); colon >= 0 {
		host = authority[:colon]
	}
	if host == "" {
		return "", fmt.Errorf("the URL has no host")
	}
	if err := configRequirePublicHost(host); err != nil {
		return "", err
	}
	return trimmed, nil
}

func configRequirePublicHost(host string) error {
	lower := strings.ToLower(strings.Trim(host, "[]"))
	if configBlockedHostNames[lower] {
		return fmt.Errorf("the URL points at %q, which is this device", lower)
	}
	if strings.HasSuffix(lower, ".localhost") {
		return fmt.Errorf("the URL points at %q, which is loopback", lower)
	}
	if !strings.Contains(lower, ".") && !strings.Contains(lower, ":") {
		return fmt.Errorf("the URL host %q is not a public name", lower)
	}
	looksV4 := lower != ""
	for _, character := range lower {
		if (character < '0' || character > '9') && character != '.' {
			looksV4 = false
			break
		}
	}
	looksV6 := strings.Contains(lower, ":")
	if !looksV4 && !looksV6 {
		return nil
	}
	address, err := netip.ParseAddr(lower)
	if err != nil {
		return fmt.Errorf("the URL points at a non-public address (%s)", lower)
	}
	if !configIsPublicAddress(address) {
		return fmt.Errorf("the URL points at a non-public address (%s)", lower)
	}
	return nil
}

func configIsPublicAddress(address netip.Addr) bool {
	if address.IsUnspecified() || address.IsLoopback() || address.IsLinkLocalUnicast() ||
		address.IsMulticast() || address.IsPrivate() {
		return false
	}
	if address.Is4() {
		octets := address.As4()
		if octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127 {
			return false
		}
		if octets[0] == 198 && (octets[1] == 18 || octets[1] == 19) {
			return false
		}
		if octets[0] >= 240 {
			return false
		}
		return true
	}
	bytes := address.As16()
	if bytes[0]&0xFE == 0xFC {
		return false
	}
	mapped := true
	for index := 0; index < 10; index++ {
		if bytes[index] != 0 {
			mapped = false
			break
		}
	}
	if mapped && bytes[10] == 0xFF && bytes[11] == 0xFF {
		return configIsPublicAddress(netip.AddrFrom4([4]byte{bytes[12], bytes[13], bytes[14], bytes[15]}))
	}
	return true
}
