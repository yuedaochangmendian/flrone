// The remaining outbound types of the Kotlin ConfigGenerator: juicity, anytls,
// shadowtls, snell, ssh, mieru, trusttunnel, masque and naive.
//
// Each parser reads the stored profiles.json object with the field rules of the
// type's ParseFromJson, and each build reproduces Build() byte for byte. The
// common base (server, port, dial fields) is handled by configParseOutboundJSON;
// the type-specific keys are listed in configOutboundTypeKeys.
package mobile

import (
	"fmt"
	"strconv"
	"strings"
)

// --- juicity -----------------------------------------------------------------

type configJuicityParams struct {
	uuid     string
	password string
	tls      configTLSParams
}

func configParseJuicity(object map[string]any) (configJuicityParams, error) {
	params := configJuicityParams{tls: configTLSDefault()}
	params.tls.utls.supported = false
	if _, present := object["uuid"]; present {
		params.uuid = configJSONString(object, "uuid")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		tls.utls.supported = false
		params.tls = tls
	}
	return params, nil
}

func configBuildJuicity(out configOutbound, params configJuicityParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "juicity"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if params.uuid != "" {
		object["uuid"] = params.uuid
	}
	if params.password != "" {
		object["password"] = params.password
	}
	tls, err := configTLSBuild(params.tls, settings, false)
	if err != nil {
		return nil, err
	}
	if len(tls) > 0 {
		object["tls"] = tls
	}
	return object, nil
}

// --- anytls ------------------------------------------------------------------

type configAnyTLSParams struct {
	password                 string
	idleSessionCheckInterval string
	idleSessionTimeout       string
	minIdleSession           int
	tls                      configTLSParams
}

func configParseAnyTLS(object map[string]any) (configAnyTLSParams, error) {
	params := configAnyTLSParams{
		idleSessionCheckInterval: "30s",
		idleSessionTimeout:       "30s",
		minIdleSession:           5,
		tls:                      configTLSDefault(),
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["idle_session_check_interval"]; present {
		params.idleSessionCheckInterval = configJSONString(object, "idle_session_check_interval")
	}
	if _, present := object["idle_session_timeout"]; present {
		params.idleSessionTimeout = configJSONString(object, "idle_session_timeout")
	}
	if _, present := object["min_idle_session"]; present {
		params.minIdleSession = configJSONInt(object["min_idle_session"])
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	return params, nil
}

func configBuildAnyTLS(out configOutbound, params configAnyTLSParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "anytls"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	// The core refuses an AnyTLS outbound with tcp_fast_open.
	delete(object, "tcp_fast_open")
	if params.password != "" {
		object["password"] = params.password
	}
	if params.idleSessionCheckInterval != "" {
		object["idle_session_check_interval"] = params.idleSessionCheckInterval
	}
	if params.idleSessionTimeout != "" {
		object["idle_session_timeout"] = params.idleSessionTimeout
	}
	if params.minIdleSession > 0 {
		object["min_idle_session"] = params.minIdleSession
	}
	customFragment := configCustomFragmentApplies("anytls", "", &params.tls, settings)
	if err := configApplyCustomFragment(object, "anytls", "", &params.tls, settings); err != nil {
		return nil, err
	}
	tls, err := configTLSBuild(params.tls, settings, customFragment)
	if err != nil {
		return nil, err
	}
	object["tls"] = tls
	return object, nil
}

// configVariantInt is QJsonValue::toInt via QVariant: a numeric string such as
// "2" also reads as 2 (ShadowTLS stores its version that way).
func configVariantInt(value any) int {
	if text, ok := value.(string); ok {
		parsed, err := strconv.Atoi(strings.TrimSpace(text))
		if err == nil {
			return parsed
		}
		return 0
	}
	return configJSONInt(value)
}

// --- shadowtls ---------------------------------------------------------------

type configShadowTLSParams struct {
	version  int
	password string
	tls      configTLSParams
}

func configParseShadowTLS(object map[string]any) (configShadowTLSParams, error) {
	params := configShadowTLSParams{version: 1, tls: configTLSDefault()}
	if _, present := object["version"]; present {
		params.version = configVariantInt(object["version"])
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	return params, nil
}

func configBuildShadowTLS(out configOutbound, params configShadowTLSParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "shadowtls"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	object["version"] = params.version
	if params.version > 1 && params.password != "" {
		object["password"] = params.password
	}
	customFragment := configCustomFragmentApplies("shadowtls", "", &params.tls, settings)
	if err := configApplyCustomFragment(object, "shadowtls", "", &params.tls, settings); err != nil {
		return nil, err
	}
	tls, err := configTLSBuild(params.tls, settings, customFragment)
	if err != nil {
		return nil, err
	}
	if len(tls) > 0 {
		object["tls"] = tls
	}
	return object, nil
}

// --- snell -------------------------------------------------------------------

type configSnellParams struct {
	version  int
	psk      string
	userkey  string
	reuse    bool
	network  string
	obfsMode string
	obfsHost string
	mode     string
}

func configParseSnell(object map[string]any) (configSnellParams, error) {
	params := configSnellParams{version: 4}
	if _, present := object["version"]; present {
		params.version = configVariantInt(object["version"])
	}
	if params.version != 4 && params.version != 6 {
		return params, fmt.Errorf("snell version %d is not supported by the core", params.version)
	}
	if _, present := object["psk"]; present {
		params.psk = configJSONString(object, "psk")
	}
	if _, present := object["userkey"]; present {
		params.userkey = configJSONString(object, "userkey")
	}
	if _, present := object["reuse"]; present {
		params.reuse = configJSONBoolValue(object["reuse"])
	}
	if _, present := object["network"]; present {
		if items, ok := object["network"].([]any); ok {
			texts := make([]string, 0, len(items))
			for _, item := range items {
				texts = append(texts, configJSONVariantToStringValue(item))
			}
			params.network = strings.Join(texts, ",")
		} else {
			params.network = configJSONString(object, "network")
		}
	}
	if _, present := object["obfs_mode"]; present {
		params.obfsMode = configJSONString(object, "obfs_mode")
	}
	if _, present := object["obfs_host"]; present {
		params.obfsHost = configJSONString(object, "obfs_host")
	}
	if _, present := object["mode"]; present {
		params.mode = configJSONString(object, "mode")
	}
	return params, nil
}

func configBuildSnell(out configOutbound, params configSnellParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "snell"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	object["version"] = params.version
	if params.psk != "" {
		object["psk"] = params.psk
	}
	if params.userkey != "" {
		object["userkey"] = params.userkey
	}
	if params.reuse {
		object["reuse"] = true
	}
	if params.network != "" {
		object["network"] = params.network
	}
	if params.version == 6 {
		if params.mode != "" {
			object["mode"] = params.mode
		}
	} else {
		if params.obfsMode != "" {
			object["obfs_mode"] = params.obfsMode
		}
		if params.obfsHost != "" {
			object["obfs_host"] = params.obfsHost
		}
	}
	return object, nil
}

// --- ssh ---------------------------------------------------------------------

type configSSHParams struct {
	user                 string
	password             string
	privateKey           string
	privateKeyPath       string
	privateKeyPassphrase string
	hostKey              []string
	hostKeyAlgorithms    []string
	clientVersion        string
}

func configParseSSH(object map[string]any) (configSSHParams, error) {
	params := configSSHParams{}
	if _, present := object["user"]; present {
		params.user = configJSONString(object, "user")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if value, present := object["private_key"]; present {
		if items, ok := value.([]any); ok {
			texts := make([]string, 0, len(items))
			for _, item := range items {
				if text, ok := item.(string); ok {
					texts = append(texts, text)
				}
			}
			params.privateKey = strings.Join(texts, "\n")
		} else {
			params.privateKey = configJSONString(object, "private_key")
		}
	}
	if _, present := object["private_key_path"]; present {
		params.privateKeyPath = configJSONString(object, "private_key_path")
	}
	if _, present := object["private_key_passphrase"]; present {
		params.privateKeyPassphrase = configJSONString(object, "private_key_passphrase")
	}
	if _, present := object["host_key"]; present {
		params.hostKey = configTrimmedNonBlankStrings(configJSONStringListValue(object["host_key"]))
	}
	if _, present := object["host_key_algorithms"]; present {
		params.hostKeyAlgorithms = configTrimmedNonBlankStrings(configJSONStringListValue(object["host_key_algorithms"]))
	}
	if _, present := object["client_version"]; present {
		params.clientVersion = configJSONString(object, "client_version")
	}
	return params, nil
}

func configBuildSSH(out configOutbound, params configSSHParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "ssh"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if params.user != "" {
		object["user"] = params.user
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.privateKey != "" {
		object["private_key"] = params.privateKey
	}
	if params.privateKeyPath != "" {
		object["private_key_path"] = params.privateKeyPath
	}
	if params.privateKeyPassphrase != "" {
		object["private_key_passphrase"] = params.privateKeyPassphrase
	}
	if len(params.hostKey) > 0 {
		object["host_key"] = configStringsToAny(params.hostKey)
	}
	if len(params.hostKeyAlgorithms) > 0 {
		object["host_key_algorithms"] = configStringsToAny(params.hostKeyAlgorithms)
	}
	if params.clientVersion != "" {
		object["client_version"] = params.clientVersion
	}
	return object, nil
}

// configTrimmedNonBlankStrings is map { it.trim() }.filterTo(ArrayList()) { it.isNotEmpty() }.
func configTrimmedNonBlankStrings(items []string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		trimmed := strings.TrimSpace(item)
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// --- mieru -------------------------------------------------------------------

type configMieruParams struct {
	transport      string
	username       string
	password       string
	multiplexing   string
	trafficPattern string
	serverPorts    []string
}

func configParseMieru(object map[string]any) (configMieruParams, error) {
	params := configMieruParams{transport: "TCP"}
	if _, present := object["transport"]; present {
		params.transport = configJSONString(object, "transport")
	}
	if _, present := object["username"]; present {
		params.username = configJSONString(object, "username")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["multiplexing"]; present {
		params.multiplexing = configJSONString(object, "multiplexing")
	}
	if _, present := object["traffic_pattern"]; present {
		params.trafficPattern = configJSONString(object, "traffic_pattern")
	}
	if value, present := object["server_ports"]; present {
		text := ""
		if items, ok := value.([]any); ok {
			parts := make([]string, 0, len(items))
			for _, item := range items {
				if itemText, ok := item.(string); ok {
					parts = append(parts, strings.TrimSpace(itemText))
				}
			}
			text = strings.Join(parts, ",")
		} else {
			text = strings.TrimSpace(configJSONString(object, "server_ports"))
		}
		for _, part := range configSplitSkipEmpty(text, ",") {
			trimmed := strings.TrimSpace(part)
			if trimmed != "" {
				params.serverPorts = append(params.serverPorts, trimmed)
			}
		}
	}
	return params, nil
}

func configBuildMieru(out configOutbound, params configMieruParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "mieru"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	transport := params.transport
	if transport == "" {
		transport = "TCP"
	}
	object["transport"] = transport
	if params.username != "" {
		object["username"] = params.username
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.multiplexing != "" {
		object["multiplexing"] = params.multiplexing
	}
	if params.trafficPattern != "" {
		object["traffic_pattern"] = params.trafficPattern
	}
	if len(params.serverPorts) > 0 {
		object["server_ports"] = configStringsToAny(params.serverPorts)
	}
	return object, nil
}

// --- trusttunnel -------------------------------------------------------------

type configTrustTunnelParams struct {
	username          string
	password          string
	congestionControl string
	customSNI         string
	clientRandom      string
	healthCheck       bool
	quic              bool
	tls               configTLSParams
}

func configParseTrustTunnel(object map[string]any) (configTrustTunnelParams, error) {
	params := configTrustTunnelParams{tls: configTLSDefault()}
	if _, present := object["username"]; present {
		params.username = configJSONString(object, "username")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["health_check"]; present {
		params.healthCheck = configJSONBoolValue(object["health_check"])
	}
	if _, present := object["quic"]; present {
		params.quic = configJSONBoolValue(object["quic"])
	}
	if _, present := object["quic_congestion_control"]; present {
		params.congestionControl = strings.ReplaceAll(
			strings.ToLower(strings.TrimSpace(configJSONString(object, "quic_congestion_control"))), " ", "_")
	}
	if _, present := object["custom_sni"]; present {
		params.customSNI = configJSONString(object, "custom_sni")
	}
	if _, present := object["client_random"]; present {
		params.clientRandom = configJSONString(object, "client_random")
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		params.tls = tls
	}
	return params, nil
}

func configBuildTrustTunnel(out configOutbound, params configTrustTunnelParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "trusttunnel"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if params.username != "" {
		object["username"] = params.username
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.healthCheck {
		object["health_check"] = true
	}
	if params.quic {
		object["quic"] = true
		if params.congestionControl != "" {
			object["quic_congestion_control"] = params.congestionControl
		}
	}
	if params.customSNI != "" {
		object["custom_sni"] = configACEHost(params.customSNI)
	}
	if params.clientRandom != "" {
		object["client_random"] = params.clientRandom
	}
	if params.tls.enabled {
		customFragment := !params.quic && configCustomFragmentApplies("trusttunnel", "", &params.tls, settings)
		if customFragment {
			if err := configApplyFragmentBlock(object, settings); err != nil {
				return nil, err
			}
		}
		tlsObject, err := configTLSBuild(params.tls, settings, customFragment)
		if err != nil {
			return nil, err
		}
		if params.quic {
			delete(tlsObject, "utls")
			delete(tlsObject, "reality")
		}
		if !params.quic {
			if _, present := tlsObject["utls"]; !present {
				tlsObject["utls"] = map[string]any{"enabled": true, "fingerprint": "chrome"}
			}
		}
		object["tls"] = tlsObject
	}
	return object, nil
}

// --- masque ------------------------------------------------------------------

func configMasqueHostPrefixed(addresses []string) []string {
	out := make([]string, 0, len(addresses))
	for _, raw := range addresses {
		address := strings.TrimSpace(raw)
		if address == "" {
			continue
		}
		if !strings.Contains(address, "/") {
			if strings.Contains(address, ":") {
				address += "/128"
			} else {
				address += "/32"
			}
		}
		out = append(out, address)
	}
	return out
}

func configParseMasque(object map[string]any) (configMasqueParams, error) {
	params := configMasqueParams{
		mtu:  1280,
		tls:  configTLSDefault(),
		quic: configQUICDefault(),
	}
	params.tls.enabled = true
	params.tls.serverName = "consumer-masque.cloudflareclient.com"
	if value, present := object["private_key"]; present {
		if items, ok := value.([]any); ok {
			texts := make([]string, 0, len(items))
			for _, item := range items {
				if text, ok := item.(string); ok {
					texts = append(texts, text)
				}
			}
			params.privateKey = strings.Join(texts, "\n")
		} else {
			params.privateKey = configJSONString(object, "private_key")
		}
	}
	if _, present := object["peer_public_key"]; present {
		params.peerPublicKey = configJSONString(object, "peer_public_key")
	}
	if _, present := object["address"]; present {
		raw := configJSONStringListValue(object["address"])
		params.address = configMasqueHostPrefixed(raw)
	}
	if _, present := object["mtu"]; present {
		params.mtu = configJSONInt(object["mtu"])
	}
	if _, present := object["http_version"]; present {
		params.httpVersion = configJSONInt(object["http_version"])
	}
	if _, present := object["disable_version_fallback"]; present {
		params.disableVersionFallback = configJSONBoolValue(object["disable_version_fallback"])
	}
	if _, present := object["tls"]; present {
		tlsObject := configJSONObjectValue(object["tls"])
		tls, err := configTLSParse(tlsObject)
		if err != nil {
			return params, err
		}
		// An absent SNI means the server address, not the constructor's WARP default.
		if _, present := tlsObject["server_name"]; !present {
			tls.serverName = ""
		}
		tls.enabled = true
		params.tls = tls
	}
	quic, err := configQUICParse(object)
	if err != nil {
		return params, err
	}
	params.quic = quic
	return params, nil
}

// --- naive -------------------------------------------------------------------

type configNaiveParams struct {
	username            string
	password            string
	congestionControl   string
	extraHeaders        map[string]string
	insecureConcurrency int
	quic                bool
	uot                 bool
	tls                 configTLSParams
}

func configParseNaive(object map[string]any) (configNaiveParams, error) {
	params := configNaiveParams{
		extraHeaders: map[string]string{},
		tls:          configTLSDefault(),
	}
	params.tls.enabled = true
	params.tls.utls.supported = false
	if _, present := object["username"]; present {
		params.username = configJSONString(object, "username")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["insecure_concurrency"]; present {
		value := configJSONInt(object["insecure_concurrency"])
		if value > 0 {
			params.insecureConcurrency = value
		}
	}
	if headers := configJSONObjectValue(object["extra_headers"]); headers != nil {
		for key, value := range headers {
			if items, ok := value.([]any); ok {
				if len(items) == 0 {
					params.extraHeaders[key] = ""
				} else {
					params.extraHeaders[key] = configJSONVariantToStringValue(items[0])
				}
				continue
			}
			params.extraHeaders[key] = configJSONVariantToStringValue(value)
		}
	}
	if _, present := object["udp_over_tcp"]; present {
		if nested := configJSONObjectValue(object["udp_over_tcp"]); nested != nil {
			params.uot = configJSONBoolValue(nested["enabled"])
		} else {
			params.uot = configJSONBoolValue(object["udp_over_tcp"])
		}
	}
	if _, present := object["quic"]; present {
		params.quic = configJSONBoolValue(object["quic"])
	}
	if _, present := object["quic_congestion_control"]; present {
		params.congestionControl = configJSONString(object, "quic_congestion_control")
	}
	if raw := configJSONObjectValue(object["tls"]); raw != nil {
		// Naive.parseFromJson filters through naiveTls(keepFragment=true): only
		// these keys ever reach Tls.parseFromJson; the rest of a stored TLS
		// block is dropped, not an unknown-key error.
		filtered := map[string]any{"enabled": true}
		for _, key := range []string{"server_name", "certificate", "certificate_path", "ech", "fragment"} {
			if value, present := raw[key]; present {
				filtered[key] = value
			}
		}
		tls, err := configTLSParse(filtered)
		if err != nil {
			return params, err
		}
		tls.enabled = true
		tls.utls.supported = false
		params.tls = tls
	}
	return params, nil
}

// configNaiveTLS is naiveTls: only enabled/server_name/certificate/
// certificate_path/ech survive; the global skip_cert and fragment defaults do
// not apply to naive.
func configNaiveTLS(params configNaiveParams) (map[string]any, error) {
	object := map[string]any{"enabled": true}
	if params.tls.serverName != "" {
		object["server_name"] = configACEHost(params.tls.serverName)
	}
	if len(params.tls.certificate) > 0 {
		object["certificate"] = configNonBlankStrings(params.tls.certificate)
	}
	if params.tls.certificatePath != "" {
		object["certificate_path"] = params.tls.certificatePath
	}
	if params.tls.ech.enabled {
		ech, err := configECHBuild(params.tls.ech)
		if err != nil {
			return nil, err
		}
		if len(ech) > 0 {
			object["ech"] = ech
		}
	}
	return object, nil
}

func configBuildNaive(out configOutbound, params configNaiveParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "naive"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if !params.quic && configCustomFragmentApplies("naive", "", &params.tls, settings) {
		if err := configApplyFragmentBlock(object, settings); err != nil {
			return nil, err
		}
	}
	if params.username != "" {
		object["username"] = params.username
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.insecureConcurrency > 0 {
		object["insecure_concurrency"] = params.insecureConcurrency
	}
	if len(params.extraHeaders) > 0 {
		headers := map[string]any{}
		for key, value := range params.extraHeaders {
			headers[key] = value
		}
		object["extra_headers"] = headers
	}
	if params.uot {
		object["udp_over_tcp"] = true
	}
	if params.quic {
		object["quic"] = true
		if params.congestionControl != "" {
			object["quic_congestion_control"] = params.congestionControl
		}
	}
	tls, err := configNaiveTLS(params)
	if err != nil {
		return nil, err
	}
	object["tls"] = tls
	return object, nil
}
