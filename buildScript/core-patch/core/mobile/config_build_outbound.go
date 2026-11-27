// Outbound parsing and chain construction for the config builder.
//
// Stage 1 supports the types the golden fixtures exercise: shadowsocks (the
// main proxy), direct (the final outbound) and chain (a hop list only). Every
// other profile type and every stored field this builder does not reproduce is
// a hard error, never a silently dropped key: a config that differs from the
// Kotlin generator must fail the build, not start with missing options.
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
// needs the chain hop ids and the shadowsocks/direct build fields; anything
// else is refused rather than approximated.
type configOutbound struct {
	id          int64
	profileType string
	name        string

	server     string
	serverPort int
	method     string
	password   string
	plugin     string
	pluginOpts string
	uot        bool
	muxEnabled bool
	dial       configDialFields

	hops []int64
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

// configParseOutboundJSON loads one stored outbound object. Unknown keys are an
// error so a field the builder does not reproduce cannot silently vanish.
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
	if profile.Type != "" && parsedType != profile.Type {
		return outbound, fmt.Errorf("profile %d row type %q does not match its outbound JSON type %q",
			profile.ID, profile.Type, parsedType)
	}
	outbound.profileType = parsedType
	allowed := map[string]bool{"type": true, "name": true, "tag": true}
	switch parsedType {
	case "chain":
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
		allowed["list"] = true
	case "direct":
		if tag := configJSONString(object, "tag"); tag != "" {
			outbound.name = tag
		}
		outbound.dial = configParseDialFields(object)
		for key := range configDialKeys {
			allowed[key] = true
		}
	case "shadowsocks":
		if tag := configJSONString(object, "tag"); tag != "" {
			outbound.name = tag
		}
		outbound.server = configToACEHost(configJSONString(object, "server"))
		outbound.serverPort = configJSONInt(object["server_port"])
		outbound.method = configJSONString(object, "method")
		outbound.password = configJSONString(object, "password")
		outbound.plugin = configJSONString(object, "plugin")
		outbound.pluginOpts = configJSONString(object, "plugin_opts")
		if value, present := object["udp_over_tcp"]; present {
			if boolean, ok := value.(bool); ok {
				outbound.uot = boolean
			} else if nested, ok := value.(map[string]any); ok {
				outbound.uot = configJSONBool(nested, "enabled")
			}
		}
		outbound.dial = configParseDialFields(object)
		allowed["server"] = true
		allowed["server_port"] = true
		allowed["method"] = true
		allowed["password"] = true
		allowed["plugin"] = true
		allowed["plugin_opts"] = true
		allowed["udp_over_tcp"] = true
		if nested, ok := object["multiplex"].(map[string]any); ok {
			// Multiplex.parseFromJson: an object without `enabled` stays
			// unspecified (Keep Default); enabled=true turns it on, which the
			// builder refuses rather than approximating.
			outbound.muxEnabled = configJSONBool(nested, "enabled")
		}
		allowed["multiplex"] = true
		for key := range configDialKeys {
			allowed[key] = true
		}
	default:
		return outbound, fmt.Errorf("profile %d has type %q, which the Stage-1 Go config builder does not support",
			profile.ID, parsedType)
	}
	for key := range object {
		if !allowed[key] {
			return outbound, fmt.Errorf("profile %d (%s) stores field %q, which the Stage-1 Go config builder does not reproduce",
				profile.ID, parsedType, key)
		}
	}
	return outbound, nil
}

// configBuildOutbound is Outbound.build for the supported types. An enabled
// multiplex is refused up front: it would add an object this builder does not
// synthesise, and a global mux preset is refused by the same check when the
// profile has no own multiplex (Multiplex.effectivelyOn).
func configBuildOutbound(outbound configOutbound, settings simpleConfigSettings) (map[string]any, error) {
	switch outbound.profileType {
	case "shadowsocks":
		if settings.MuxDefaultOn || outbound.muxEnabled {
			return nil, fmt.Errorf("multiplex is on; the Stage-1 Go config builder does not build the mux preset")
		}
		return configBuildShadowsocks(outbound), nil
	case "direct":
		return configBuildDirect(outbound), nil
	case "chain":
		return nil, fmt.Errorf("a chain profile cannot be built as an outbound; its hops are expanded")
	default:
		return nil, fmt.Errorf("profile type %q is not supported by the Stage-1 Go config builder", outbound.profileType)
	}
}

func configBuildDirect(outbound configOutbound) map[string]any {
	object := map[string]any{"type": "direct"}
	outbound.dial.apply(object)
	return object
}

func configBuildShadowsocks(outbound configOutbound) map[string]any {
	plugin := outbound.plugin
	pluginOpts := outbound.pluginOpts
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
	if outbound.method != "" {
		object["method"] = outbound.method
	}
	if outbound.password != "" {
		object["password"] = outbound.password
	}
	if plugin != "" {
		object["plugin"] = plugin
	}
	if pluginOpts != "" {
		object["plugin_opts"] = pluginOpts
	}
	if outbound.uot {
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

// configBuildChain is ChainBuilder.buildOutboundChain for a resolved hop list
// (exit first). It returns the ingress tag.
func configBuildChain(
	profiles []simpleConfigProfile, settings simpleConfigSettings, hops []int64,
	prefix string, includeProxy bool, link bool, startSuffix int, outbounds *[]any,
) (string, error) {
	ingress := configHopTag(prefix, startSuffix)
	if includeProxy {
		ingress = tagProxy
	}
	resolved := make([]configOutbound, 0, len(hops))
	for _, id := range hops {
		profile := configFindProfile(profiles, id)
		if profile == nil {
			return ingress, fmt.Errorf("a proxy in the chain can no longer be found (profile id %d)", id)
		}
		outbound, err := configParseOutboundJSON(*profile)
		if err != nil {
			return ingress, err
		}
		if outbound.profileType == "chain" {
			return ingress, fmt.Errorf("Chain in Chain is not allowed (profile id %d)", id)
		}
		if outbound.profileType == "autoselector" {
			return ingress, fmt.Errorf("An auto selector cannot be used as a hop (profile id %d)", id)
		}
		resolved = append(resolved, outbound)
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
		object, err := configBuildOutbound(outbound, settings)
		if err != nil {
			return ingress, err
		}
		object["tag"] = tag
		if nextTag != "" && link {
			object["detour"] = nextTag
		}
		*outbounds = append(*outbounds, object)
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
