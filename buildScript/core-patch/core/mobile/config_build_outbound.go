// Outbound parsing and chain construction for the config builder.
//
// The builder supports the TCP proxy types (shadowsocks, socks, http, vmess,
// vless, trojan), the QUIC type (hysteria / hysteria2), wireguard as a sing-box
// endpoint, the built-in WARP hop (wireguard/amnezia/masque, see
// config_build_warp.go), `custom` as a raw outbound or a full config
// (config_build_custom.go), and direct / chain. Every other profile type and
// every stored field these builders do not reproduce is a hard error, never a
// silently dropped key: a config that differs from the Kotlin generator must
// fail the build, not start with missing options.
package mobile

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

const (
	tagProxy      = "proxy"
	tagDirect     = "direct"
	tagWarpBypass = "warp-bypass"

	tagDNSRemote = "dns-remote"
	tagDNSDirect = "dns-direct"
	tagDNSLocal  = "dns-local"
	tagDNSFake   = "dns-fake"
	tagDNSHosts  = "dns-hosts"

	tagDNSEchPrefix = "dns-ech"

	tagDNSIn   = "dns-in"
	tagMixedIn = "mixed-in"
	tagTunIn   = "tun-in"

	tagMainChainPrefix  = "config"
	tagRouteChainPrefix = "route"
)

func configHopTag(prefix string, index int) string {
	return prefix + "-" + strconv.Itoa(index)
}

// configDialFields is DialFields: the eight dial keys every outbound build
// emits before its own fields.
type configDialFields struct {
	reuseAddr        bool
	connectTimeout   string
	tcpFastOpen      bool
	tcpMultiPath     bool
	udpFragment      bool
	bindInterface    string
	inet4BindAddress string
	inet6BindAddress string
}

func configParseDialFields(object map[string]any) configDialFields {
	return configDialFields{
		reuseAddr:        configJSONBool(object, "reuse_addr"),
		connectTimeout:   strings.TrimSpace(configJSONString(object, "connect_timeout")),
		tcpFastOpen:      configJSONBool(object, "tcp_fast_open"),
		tcpMultiPath:     configJSONBool(object, "tcp_multi_path"),
		udpFragment:      configJSONBool(object, "udp_fragment"),
		bindInterface:    configJSONString(object, "bind_interface"),
		inet4BindAddress: strings.TrimSpace(configJSONString(object, "inet4_bind_address")),
		inet6BindAddress: strings.TrimSpace(configJSONString(object, "inet6_bind_address")),
	}
}

func (dial configDialFields) apply(target map[string]any) {
	if dial.reuseAddr {
		target["reuse_addr"] = true
	}
	if dial.connectTimeout != "" {
		target["connect_timeout"] = dial.connectTimeout
	}
	if dial.tcpFastOpen {
		target["tcp_fast_open"] = true
	}
	if dial.tcpMultiPath {
		target["tcp_multi_path"] = true
	}
	if dial.udpFragment {
		target["udp_fragment"] = true
	}
	if dial.bindInterface != "" {
		target["bind_interface"] = dial.bindInterface
	}
	if dial.inet4BindAddress != "" {
		target["inet4_bind_address"] = dial.inet4BindAddress
	}
	if dial.inet6BindAddress != "" {
		target["inet6_bind_address"] = dial.inet6BindAddress
	}
}

var configDialKeys = map[string]bool{
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true, "tcp_multi_path": true,
	"udp_fragment": true, "bind_interface": true, "inet4_bind_address": true, "inet6_bind_address": true,
}

// configOutbound is the parsed form of one profiles.json row. The generator
// needs the chain hop ids and each type's build fields; anything else is
// refused rather than approximated. params is one of the per-type structs in
// config_build_protocols.go (or configShadowsocksParams for shadowsocks).
type configOutbound struct {
	id          int64
	profileType string
	name        string

	server     string
	serverPort int
	dial       configDialFields

	hops []int64

	params any
}

// configShadowsocksParams is the Stage-1 shadowsocks subset.
type configShadowsocksParams struct {
	method     string
	password   string
	plugin     string
	pluginOpts string
	uot        bool
	muxEnabled bool
}

func configJSONNumber(value any) float64 {
	switch typed := value.(type) {
	case float64:
		return typed
	case json.Number:
		parsed, _ := typed.Float64()
		return parsed
	case int:
		return float64(typed)
	case int64:
		return float64(typed)
	}
	return 0
}

// configJSONInt is JsonObject.int / QJsonValue::toInt: only whole numbers that
// fit an int, anything else is 0.
func configJSONInt(value any) int {
	number := configJSONNumber(value)
	if number != float64(int64(number)) || number < -2147483648 || number > 2147483647 {
		return 0
	}
	return int(number)
}

// configJSONInteger is JsonValues.toInteger: whole numbers that fit a qint64.
func configJSONInteger(value any) int64 {
	number := configJSONNumber(value)
	if number != float64(int64(number)) {
		return 0
	}
	return int64(number)
}

func configJSONString(object map[string]any, key string) string {
	value, _ := object[key].(string)
	return value
}

func configJSONBool(object map[string]any, key string) bool {
	value, _ := object[key].(bool)
	return value
}

// configCanonicalOutboundType is OutboundFactory.canonicalType for the alias
// this builder needs to resolve: `openvpn-client` is both a stored row type and
// the type build() emits, and Kotlin's factory maps it to `openvpn`. The
// hysteria2 alias is deliberately NOT canonicalised here: this builder keeps
// hysteria and hysteria2 as separate parser versions.
func configCanonicalOutboundType(profileType string) string {
	if profileType == "openvpn-client" {
		return "openvpn"
	}
	return profileType
}

// configOutboundTypeKeys is the per-type key set ParseFromJson reads (on top of
// configCommonOutboundKeys and the QUIC flat keys for hysteria).
func configOutboundTypeKeys(profileType string) []string {
	spec, ok := configOutboundSpecFor(profileType)
	if !ok {
		return nil
	}
	return spec.keys
}

func configParseOutboundJSON(profile simpleConfigProfile) (configOutbound, error) {
	outbound := configOutbound{id: profile.ID, profileType: profile.Type}
	text := strings.TrimSpace(profile.OutboundJSON)
	if text == "" || text == "{}" {
		return outbound, fmt.Errorf("profile %d has no outbound JSON", profile.ID)
	}
	var object map[string]any
	if err := json.Unmarshal([]byte(text), &object); err != nil {
		return outbound, fmt.Errorf("profile %d outbound JSON: %w", profile.ID, err)
	}
	if len(object) == 0 {
		return outbound, fmt.Errorf("profile %d has an empty outbound JSON", profile.ID)
	}
	parsedType := configJSONString(object, "type")
	if parsedType == "" {
		parsedType = profile.Type
	}
	// OutboundFactory.canonicalType resolves the two stored aliases before the
	// factory picks a class; the row type and the JSON type may differ by alias.
	canonicalType := configCanonicalOutboundType(parsedType)
	canonicalRowType := configCanonicalOutboundType(profile.Type)
	if profile.Type != "" && canonicalRowType != canonicalType {
		return outbound, fmt.Errorf("profile %d row type %q does not match its outbound JSON type %q",
			profile.ID, profile.Type, parsedType)
	}
	outbound.profileType = canonicalType

	if parsedType == "chain" {
		if err := configCheckKeys(object, configKeysAllowed("type", "name", "list"), fmt.Sprintf("profile %d (chain)", profile.ID)); err != nil {
			return outbound, err
		}
		outbound.name = configJSONString(object, "name")
		outbound.hops = make([]int64, 0)
		if list, present := object["list"]; present {
			items, ok := list.([]any)
			if !ok {
				return outbound, fmt.Errorf("profile %d chain list is not an array", profile.ID)
			}
			for _, item := range items {
				outbound.hops = append(outbound.hops, configJSONInteger(item))
			}
		}
		return outbound, nil
	}
	if parsedType == "custom" {
		// Custom.parseFromJson reads name/subtype/config only: no base fields, no
		// dial fields, and no server (the config text carries them).
		if err := configCheckKeys(object, configKeysAllowed("type", "name", "subtype", "config"),
			fmt.Sprintf("profile %d (custom)", profile.ID)); err != nil {
			return outbound, err
		}
		outbound.name = configJSONString(object, "name")
		outbound.params = configParseCustom(object)
		return outbound, nil
	}
	if parsedType != "direct" && configOutboundTypeKeys(parsedType) == nil {
		return outbound, fmt.Errorf("profile %d has type %q, which the Go config builder does not support",
			profile.ID, parsedType)
	}

	allowed := configKeysAllowed(configCommonOutboundKeys()...)
	configSetKeys(allowed, configOutboundTypeKeys(parsedType)...)
	if err := configCheckKeys(object, allowed,
		fmt.Sprintf("profile %d (%s)", profile.ID, parsedType)); err != nil {
		return outbound, err
	}

	if parsedType == "direct" {
		if tag := configJSONString(object, "tag"); tag != "" {
			outbound.name = tag
		}
		outbound.dial = configParseDialFields(object)
		return outbound, nil
	}

	if tag := configJSONString(object, "tag"); tag != "" {
		outbound.name = tag
	}
	if server := configJSONString(object, "server"); server != "" {
		outbound.server = configACEHost(server)
	}
	outbound.serverPort = configJSONInt(object["server_port"])
	// Masque.init sets the endpoint's default port before ParseFromJson runs.
	if parsedType == "masque" && outbound.serverPort == 0 {
		outbound.serverPort = 443
	}
	outbound.dial = configParseDialFields(object)

	params, err := configParseOutboundParams(parsedType, object)
	if err != nil {
		return outbound, fmt.Errorf("profile %d (%s): %w", profile.ID, parsedType, err)
	}
	outbound.params = params
	return outbound, nil
}

// configParseOutboundParams dispatches the per-type ParseFromJson.
func configParseOutboundParams(profileType string, object map[string]any) (any, error) {
	spec, ok := configOutboundSpecFor(profileType)
	if !ok {
		return nil, fmt.Errorf("profile type %q is not supported by the Go config builder", profileType)
	}
	return spec.parse(object)
}

func configOutboundIsEndpoint(outbound configOutbound) bool {
	switch outbound.profileType {
	case "wireguard", "masque", "openvpn", "openconnect":
		return true
	case "custom":
		params, ok := outbound.params.(configCustomParams)
		return ok && params.isEndpoint()
	}
	return false
}

// configOutboundIsCustomFullConfig is TypeAccess.isCustomFullConfig: a full
// config cannot be a chain hop or a route outbound.
func configOutboundIsCustomFullConfig(outbound configOutbound) bool {
	params, ok := outbound.params.(configCustomParams)
	return ok && params.isFullConfig()
}

// configOutboundRealmActive is Hysteria.realmActive.
func configOutboundRealmActive(outbound configOutbound) bool {
	params, ok := outbound.params.(configHysteriaParams)
	return ok && params.realmActive()
}

// configOutboundResolvesViaDNSRules is resolvesHostnamesViaDnsRules: endpoints
// and plain SOCKS4 cannot resolve names themselves.
func configOutboundResolvesViaDNSRules(outbound configOutbound) bool {
	if configOutboundIsEndpoint(outbound) {
		return true
	}
	if params, ok := outbound.params.(configSocksParams); ok {
		return params.version == 4 && !params.socks4a
	}
	return false
}

// configOutboundTLS is Outbound.hasTls / getTls for the types this builder
// supports: http, vmess, vless, trojan and hysteria carry a `tls` object.
func configOutboundTLS(outbound configOutbound) (configTLSParams, bool) {
	switch params := outbound.params.(type) {
	case configHTTPParams:
		return params.tls, true
	case configVMessParams:
		return params.tls, true
	case configVlessParams:
		return params.tls, true
	case configTrojanParams:
		return params.tls, true
	case configHysteriaParams:
		return params.tls, true
	}
	return configTLSParams{}, false
}

// configBuildOutbound is Outbound.build for the supported types.
func configBuildOutbound(outbound configOutbound, settings simpleConfigSettings) (map[string]any, error) {
	switch outbound.profileType {
	case "direct":
		return configBuildDirect(outbound), nil
	case "custom":
		params, ok := outbound.params.(configCustomParams)
		if !ok {
			return nil, fmt.Errorf("profile %d has no custom fields", outbound.id)
		}
		return params.buildObject(), nil
	case "chain":
		return nil, fmt.Errorf("a chain profile cannot be built as an outbound; its hops are expanded")
	}
	spec, ok := configOutboundSpecFor(outbound.profileType)
	if !ok {
		return nil, fmt.Errorf("profile type %q is not supported by the Go config builder", outbound.profileType)
	}
	return spec.build(outbound, outbound.params, settings)
}

func configBuildDirect(outbound configOutbound) map[string]any {
	object := map[string]any{"type": "direct"}
	outbound.dial.apply(object)
	return object
}

func configBuildShadowsocks(outbound configOutbound, params configShadowsocksParams) map[string]any {
	plugin := params.plugin
	pluginOpts := params.pluginOpts
	if strings.Contains(plugin, ";") {
		pluginOpts = configSubstringAfter(plugin, ";")
		plugin = configSubstringBefore(plugin, ";")
	}
	object := map[string]any{"type": "shadowsocks"}
	if outbound.server != "" {
		object["server"] = outbound.server
	}
	if outbound.serverPort > 0 {
		object["server_port"] = outbound.serverPort
	}
	outbound.dial.apply(object)
	if params.method != "" {
		object["method"] = params.method
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if plugin != "" {
		object["plugin"] = plugin
	}
	if pluginOpts != "" {
		object["plugin_opts"] = pluginOpts
	}
	if params.uot {
		object["udp_over_tcp"] = true
	}
	return object
}

// configSubstringBefore/After are QtStrings.substrBefore/After: the whole string
// when the separator is absent.
func configSubstringBefore(text, separator string) string {
	if index := strings.Index(text, separator); index >= 0 {
		return text[:index]
	}
	return text
}

func configSubstringAfter(text, separator string) string {
	if index := strings.Index(text, separator); index >= 0 {
		return text[index+len(separator):]
	}
	return text
}

// configFindProfile resolves one profiles.json row by id.
func configFindProfile(profiles []simpleConfigProfile, id int64) *simpleConfigProfile {
	for index := range profiles {
		if profiles[index].ID == id {
			return &profiles[index]
		}
	}
	return nil
}

// configHopOrigin is ChainBuilder.HopOrigin: what a missing hop must name so
// the user knows which chain or group still points at a deleted profile.
type configHopOrigin struct {
	profileName string
	profileHops []int64
	groupName   string
	landingID   int64
	frontID     int64
}

// configMissingHopError is ChainBuilder.missingHopError.
func configMissingHopError(id int64, origin *configHopOrigin) error {
	if origin != nil {
		for _, hopID := range origin.profileHops {
			if hopID == id {
				return fmt.Errorf("Chain %q has a hop (profile id %d) that no longer exists, edit the chain to remove it",
					origin.profileName, id)
			}
		}
		// The front proxy is named first, exactly like the Kotlin loop.
		if origin.frontID == id {
			return fmt.Errorf("Group %q has a front proxy that has been deleted.", origin.groupName)
		}
		if origin.landingID == id {
			return fmt.Errorf("Group %q has a landing proxy that has been deleted.", origin.groupName)
		}
	}
	return fmt.Errorf("A proxy in the chain can no longer be found.")
}

// configBuildChain is ChainBuilder.buildOutboundChain for a resolved hop list
// (exit first). It returns the ingress tag. Endpoints go to the endpoints list
// like ChainBuilder.buildSingboxChain, and a hop whose next hop resolves names
// through DNS rules carries directDomainResolver.
//
// hop id configWarpProfileID resolves to the built-in WARP endpoint. With
// warpWrap hop 0 is WARP as `proxy` and hop 1 takes `warp-bypass` (the tag rules
// name to skip WARP), and WARP always dials through it.
//
// [reads] records every hop that resolves to a stored profile, which is where
// ChainBuilder.resolveHops reads them; the WARP pseudo hop is not a profile and
// is never recorded.
func configBuildChain(
	profiles []simpleConfigProfile, settings simpleConfigSettings, hops []int64,
	prefix string, includeProxy bool, link bool, warpWrap bool, startSuffix int,
	outbounds *[]any, endpoints *[]any, directStrategy string, collectECH func(configOutbound),
	origin *configHopOrigin, reads *configProfileReads,
) (string, error) {
	ingress := configHopTag(prefix, startSuffix)
	if includeProxy {
		ingress = tagProxy
	}
	resolved := make([]configOutbound, 0, len(hops))
	hasCustomFullConfig := false
	for _, id := range hops {
		if id == configWarpProfileID {
			if !settings.EnableWarp {
				return ingress, configMissingHopError(id, origin)
			}
			resolved = append(resolved, configWarpOutbound(settings))
			continue
		}
		profile := configFindProfile(profiles, id)
		if profile == nil {
			return ingress, configMissingHopError(id, origin)
		}
		reads.record(id)
		outbound, err := configParseOutboundJSON(*profile)
		if err != nil {
			return ingress, err
		}
		if outbound.profileType == "chain" {
			return ingress, fmt.Errorf("Chain in Chain is not allowed")
		}
		if outbound.profileType == "autoselector" {
			return ingress, fmt.Errorf("An auto selector cannot be used as a hop; it is not a fixed server")
		}
		if configOutboundIsCustomFullConfig(outbound) {
			hasCustomFullConfig = true
		}
		resolved = append(resolved, outbound)
	}
	if hasCustomFullConfig {
		return ingress, fmt.Errorf("Custom full config profiles cannot be used in a chain; only custom outbound profiles are chainable")
	}
	for index, outbound := range resolved {
		tag := configHopTag(prefix, startSuffix+index)
		nextTag := ""
		if index < len(resolved)-1 {
			nextTag = configHopTag(prefix, startSuffix+index+1)
		}
		if includeProxy && index == 0 {
			tag = tagProxy
		}
		if warpWrap && index == 1 {
			tag = tagWarpBypass
		}
		object, err := configBuildOutbound(outbound, settings)
		if err != nil {
			return ingress, err
		}
		object["tag"] = tag
		if collectECH != nil {
			collectECH(outbound)
		}
		if configOutboundRealmActive(outbound) {
			object["domain_resolver"] = map[string]any{"server": tagDNSDirect}
		}
		if nextTag != "" && link {
			object["detour"] = nextTag
		}
		if warpWrap && index == 0 {
			object["detour"] = tagWarpBypass
		}
		_, hasResolver := object["domain_resolver"]
		if nextTag != "" && link && !configOutboundIsEndpoint(outbound) && !hasResolver &&
			configOutboundResolvesViaDNSRules(resolved[index+1]) {
			object["domain_resolver"] = map[string]any{"server": tagDNSDirect, "strategy": directStrategy}
		}
		if configOutboundIsEndpoint(outbound) {
			*endpoints = append(*endpoints, object)
		} else {
			*outbounds = append(*outbounds, object)
		}
	}
	return ingress, nil
}

// configUnwrapChain is ChainBuilder.unwrapChain: the hop ids exit first, i.e.
// the stored in -> out list reversed.
func configUnwrapChain(profile configOutbound) []int64 {
	if profile.profileType != "chain" {
		return []int64{profile.id}
	}
	reversed := make([]int64, 0, len(profile.hops))
	for index := len(profile.hops) - 1; index >= 0; index-- {
		reversed = append(reversed, profile.hops[index])
	}
	return reversed
}
