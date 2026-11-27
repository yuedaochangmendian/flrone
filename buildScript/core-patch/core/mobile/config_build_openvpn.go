// OpenVPN outbound parsing and building.
//
// OpenVPN is a port of OpenVpn.parseFromJson / OpenVpn.Tls.parseFromJson and
// OpenVpn.build (Kotlin outbound/types/OpenVpn.kt). The stored profile type is
// `openvpn` but the core object is `openvpn-client`. Its `tls` object is the
// OpenVPN TLS block (certificate paths, fingerprints, TLS-crypt), NOT the
// sing-box TLS block handled by config_build_tls.go, and it is an endpoint in
// the core config like wireguard.
//
// Profile loading has no ParseDiag active, so ovpnKeep / ovpnReadChecked keep
// every stored value: validation is an import-time concern, not a build-time
// one. The byte-for-byte contract is the Kotlin build() output.
package mobile

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"unicode"
)

type configOpenVPNRemote struct {
	server     string
	serverPort int
	network    string
}

type configOpenVPNControlWrap struct {
	kind      string
	key       []string
	keyPath   string
	direction string
}

type configOpenVPNTLS struct {
	serverName            string
	serverNameType        string
	certificate           []string
	certificatePath       string
	clientCertificate     []string
	clientCertificatePath string
	clientKey             []string
	clientKeyPath         string
	peerFingerprint       []string
	crlPath               string
	remoteCertificateKU   []string
	remoteCertificateEKU  string
	remoteCertificateTLS  string
	certificateProfile    string
	nsCertificateType     string
	versionMin            string
	versionMax            string
	cipher                string
	groups                string
	controlWrap           configOpenVPNControlWrap
}

type configOpenVPNPullFilter struct {
	action string
	text   string
}

type configOpenVPNParams struct {
	network             string
	username            string
	password            string
	staticChallenge     string
	staticChallengeEcho bool
	mtu                 int
	tls                 configOpenVPNTLS

	mode                string
	servers             []configOpenVPNRemote
	remoteRandom        bool
	address             []string
	peerAddress         string
	peerAddressIPv6     string
	topology            string
	authRetry           string
	staticKey           []string
	staticKeyPath       string
	keyDirection        string
	cipher              string
	dataCiphers         []string
	dataCiphersFallback string
	auth                string
	mssFix              int
	mssFixDisabled      bool
	mssFixMode          string
	fragment            int
	replayWindow        int
	replayWindowTime    string
	compression         string
	compressionLZO      string
	allowCompression    string
	routeNoPull         bool
	pullFilters         []configOpenVPNPullFilter
	routes              []string
	routeGateway        string
	routeMetric         int
	redirectGateway     bool
	redirectGWFlags     []string
	redirectPrivate     bool
	blockIPv6           bool
	pingInterval        string
	pingRestart         string
	pingRestartDisabled bool
	renegotiateInterval string
	renegotiateDisabled bool
	renegotiateBytes    int64
	renegotiatePackets  int64
	tlsTimeout          string
	handshakeWindow     string
	explicitExitNotify  int
	system              bool
	interfaceName       string
	udpTimeout          string
	udpMapping          string
	udpFiltering        string
	udpNATMax           int
	tunnelDNS           string
}

// configOVPNListable mirrors VpnFileImport.listable: a bare string is split on
// newlines with empty pieces dropped; an array maps every item to a string
// (non-string items become ""), unlike configJSONStringListValue which drops
// them.
func configOVPNListable(value any) []string {
	if text, ok := value.(string); ok {
		return configSplitSkipEmpty(text, "\n")
	}
	if items, ok := value.([]any); ok {
		out := make([]string, 0, len(items))
		for _, item := range items {
			text, _ := item.(string)
			out = append(out, text)
		}
		return out
	}
	return []string{}
}

// configOVPNKeepItems is ovpnKeepItems without ParseDiag: trim and drop blanks.
func configOVPNKeepItems(items []string) []string {
	out := make([]string, 0, len(items))
	for _, item := range items {
		trimmed := strings.TrimSpace(item)
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// configOVPNReadChecked is ovpnReadChecked without ParseDiag: the trimmed
// stored string, or the current value when the key is absent.
func configOVPNReadChecked(object map[string]any, key, current string) string {
	if _, present := object[key]; !present {
		return current
	}
	return strings.TrimSpace(configJSONString(object, key))
}

func configOVPNIsNumber(value any) bool {
	switch value.(type) {
	case float64, json.Number, int, int64:
		return true
	}
	return false
}

func configParseOpenVPNRemote(object map[string]any) configOpenVPNRemote {
	remote := configOpenVPNRemote{}
	if _, present := object["server"]; present {
		remote.server = configJSONString(object, "server")
	}
	if _, present := object["server_port"]; present {
		remote.serverPort = configJSONInt(object["server_port"])
	}
	if _, present := object["network"]; present {
		remote.network = strings.TrimSpace(configJSONString(object, "network"))
	}
	return remote
}

func configParseOpenVPNControlWrap(object map[string]any) (configOpenVPNControlWrap, error) {
	wrap := configOpenVPNControlWrap{}
	if err := configCheckKeys(object, configKeysAllowed("type", "key", "key_path", "direction"), "openvpn.tls.control_wrap"); err != nil {
		return wrap, err
	}
	if _, present := object["type"]; present {
		wrap.kind = strings.TrimSpace(configJSONString(object, "type"))
	}
	if _, present := object["key"]; present {
		wrap.key = configOVPNListable(object["key"])
	}
	if _, present := object["key_path"]; present {
		wrap.keyPath = configJSONString(object, "key_path")
	}
	if _, present := object["direction"]; present {
		wrap.direction = strings.TrimSpace(configJSONString(object, "direction"))
	}
	return wrap, nil
}

func configParseOpenVPNTLS(object map[string]any) (configOpenVPNTLS, error) {
	tls := configOpenVPNTLS{}
	if object == nil {
		return tls, nil
	}
	if err := configCheckKeys(object, configKeysAllowed(
		"server_name", "server_name_type", "certificate", "certificate_path",
		"client_certificate", "client_certificate_path", "client_key", "client_key_path",
		"peer_fingerprint", "crl_path", "remote_certificate_ku", "remote_certificate_eku",
		"remote_certificate_tls", "certificate_profile", "ns_certificate_type",
		"version_min", "version_max", "cipher", "groups", "control_wrap",
	), "openvpn.tls"); err != nil {
		return tls, err
	}
	if _, present := object["server_name"]; present {
		tls.serverName = configJSONString(object, "server_name")
	}
	if _, present := object["server_name_type"]; present {
		tls.serverNameType = strings.TrimSpace(configJSONString(object, "server_name_type"))
	}
	if _, present := object["certificate"]; present {
		tls.certificate = configOVPNListable(object["certificate"])
	}
	if _, present := object["certificate_path"]; present {
		tls.certificatePath = configJSONString(object, "certificate_path")
	}
	if _, present := object["client_certificate"]; present {
		tls.clientCertificate = configOVPNListable(object["client_certificate"])
	}
	if _, present := object["client_certificate_path"]; present {
		tls.clientCertificatePath = configJSONString(object, "client_certificate_path")
	}
	if _, present := object["client_key"]; present {
		tls.clientKey = configOVPNListable(object["client_key"])
	}
	if _, present := object["client_key_path"]; present {
		tls.clientKeyPath = configJSONString(object, "client_key_path")
	}
	if _, present := object["peer_fingerprint"]; present {
		tls.peerFingerprint = configOVPNListable(object["peer_fingerprint"])
	}
	if _, present := object["crl_path"]; present {
		tls.crlPath = configJSONString(object, "crl_path")
	}
	if _, present := object["remote_certificate_ku"]; present {
		tls.remoteCertificateKU = configOVPNListable(object["remote_certificate_ku"])
	}
	if _, present := object["remote_certificate_eku"]; present {
		tls.remoteCertificateEKU = configJSONString(object, "remote_certificate_eku")
	}
	if _, present := object["remote_certificate_tls"]; present {
		tls.remoteCertificateTLS = strings.TrimSpace(configJSONString(object, "remote_certificate_tls"))
	}
	if _, present := object["certificate_profile"]; present {
		tls.certificateProfile = strings.TrimSpace(configJSONString(object, "certificate_profile"))
	}
	if _, present := object["ns_certificate_type"]; present {
		tls.nsCertificateType = strings.TrimSpace(configJSONString(object, "ns_certificate_type"))
	}
	if _, present := object["version_min"]; present {
		tls.versionMin = strings.TrimSpace(configJSONString(object, "version_min"))
	}
	if _, present := object["version_max"]; present {
		tls.versionMax = strings.TrimSpace(configJSONString(object, "version_max"))
	}
	tls.cipher = configOVPNReadChecked(object, "cipher", tls.cipher)
	tls.groups = configOVPNReadChecked(object, "groups", tls.groups)
	if wrap := configJSONObjectValue(object["control_wrap"]); wrap != nil {
		parsed, err := configParseOpenVPNControlWrap(wrap)
		if err != nil {
			return tls, err
		}
		tls.controlWrap = parsed
	}
	return tls, nil
}

func configParseOpenVPNPullFilter(object map[string]any) (configOpenVPNPullFilter, error) {
	filter := configOpenVPNPullFilter{}
	if err := configCheckKeys(object, configKeysAllowed("action", "text"), "openvpn.pull_filters"); err != nil {
		return filter, err
	}
	if _, present := object["action"]; present {
		filter.action = strings.TrimSpace(configJSONString(object, "action"))
	}
	if _, present := object["text"]; present {
		filter.text = configJSONString(object, "text")
	}
	return filter, nil
}

// configParseOpenVPN is OpenVpn.parseFromJson with the shared Outbound fields
// (server, server_port, dial) already consumed by configParseOutboundJSON.
func configParseOpenVPN(object map[string]any) (configOpenVPNParams, error) {
	params := configOpenVPNParams{}
	if _, present := object["mode"]; present {
		params.mode = strings.TrimSpace(configJSONString(object, "mode"))
	}
	if _, present := object["network"]; present {
		params.network = strings.TrimSpace(configJSONString(object, "network"))
	}
	if servers, ok := object["servers"].([]any); ok {
		params.servers = make([]configOpenVPNRemote, 0, len(servers))
		for _, item := range servers {
			remote := configParseOpenVPNRemote(configJSONObjectValue(item))
			params.servers = append(params.servers, remote)
		}
	}
	if _, present := object["remote_random"]; present {
		params.remoteRandom = configJSONBoolValue(object["remote_random"])
	}
	if _, present := object["address"]; present {
		params.address = configOVPNListable(object["address"])
	}
	if _, present := object["peer_address"]; present {
		params.peerAddress = configJSONString(object, "peer_address")
	}
	if _, present := object["peer_address_ipv6"]; present {
		params.peerAddressIPv6 = configJSONString(object, "peer_address_ipv6")
	}
	if _, present := object["topology"]; present {
		params.topology = strings.TrimSpace(configJSONString(object, "topology"))
	}
	if _, present := object["username"]; present {
		params.username = configJSONString(object, "username")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["auth_retry"]; present {
		params.authRetry = strings.TrimSpace(configJSONString(object, "auth_retry"))
	}
	if _, present := object["static_challenge"]; present {
		params.staticChallenge = configJSONString(object, "static_challenge")
	}
	if _, present := object["static_challenge_echo"]; present {
		params.staticChallengeEcho = configJSONBoolValue(object["static_challenge_echo"])
	}
	if _, present := object["static_key"]; present {
		params.staticKey = configOVPNListable(object["static_key"])
	}
	if _, present := object["static_key_path"]; present {
		params.staticKeyPath = configJSONString(object, "static_key_path")
	}
	if _, present := object["key_direction"]; present {
		params.keyDirection = strings.TrimSpace(configJSONString(object, "key_direction"))
	}
	if tls := configJSONObjectValue(object["tls"]); tls != nil {
		parsed, err := configParseOpenVPNTLS(tls)
		if err != nil {
			return params, err
		}
		params.tls = parsed
	}
	if _, present := object["cipher"]; present {
		params.cipher = configJSONString(object, "cipher")
	}
	if _, present := object["data_ciphers"]; present {
		params.dataCiphers = configOVPNKeepItems(configOVPNListable(object["data_ciphers"]))
	}
	params.dataCiphersFallback = configOVPNReadChecked(object, "data_ciphers_fallback", params.dataCiphersFallback)
	if _, present := object["auth"]; present {
		params.auth = configJSONString(object, "auth")
	}
	if _, present := object["mss_fix"]; present {
		params.mssFix = configJSONInt(object["mss_fix"])
	}
	if _, present := object["mss_fix_disabled"]; present {
		params.mssFixDisabled = configJSONBoolValue(object["mss_fix_disabled"])
	}
	if _, present := object["mss_fix_mode"]; present {
		params.mssFixMode = strings.TrimSpace(configJSONString(object, "mss_fix_mode"))
	}
	if _, present := object["fragment"]; present {
		// ovpnKeep without ParseDiag keeps any stored integer.
		params.fragment = configJSONInt(object["fragment"])
	}
	if _, present := object["replay_window"]; present {
		params.replayWindow = configJSONInt(object["replay_window"])
	}
	params.replayWindowTime = configOVPNReadChecked(object, "replay_window_time", params.replayWindowTime)
	if _, present := object["compression"]; present {
		params.compression = configJSONString(object, "compression")
	}
	if _, present := object["compression_lzo"]; present {
		params.compressionLZO = configJSONString(object, "compression_lzo")
	}
	if _, present := object["allow_compression"]; present {
		params.allowCompression = configJSONString(object, "allow_compression")
	}
	if _, present := object["route_no_pull"]; present {
		params.routeNoPull = configJSONBoolValue(object["route_no_pull"])
	}
	if filters, ok := object["pull_filters"].([]any); ok {
		params.pullFilters = make([]configOpenVPNPullFilter, 0, len(filters))
		for _, item := range filters {
			filter, err := configParseOpenVPNPullFilter(configJSONObjectValue(item))
			if err != nil {
				return params, err
			}
			params.pullFilters = append(params.pullFilters, filter)
		}
	}
	if _, present := object["routes"]; present {
		params.routes = configOVPNKeepItems(configOVPNListable(object["routes"]))
	}
	params.routeGateway = configOVPNReadChecked(object, "route_gateway", params.routeGateway)
	if _, present := object["route_metric"]; present {
		params.routeMetric = configJSONInt(object["route_metric"])
	}
	if _, present := object["redirect_gateway"]; present {
		params.redirectGateway = configJSONBoolValue(object["redirect_gateway"])
	}
	if _, present := object["redirect_gateway_flags"]; present {
		params.redirectGWFlags = configOVPNListable(object["redirect_gateway_flags"])
	}
	if _, present := object["redirect_private"]; present {
		params.redirectPrivate = configJSONBoolValue(object["redirect_private"])
	}
	if _, present := object["block_ipv6"]; present {
		params.blockIPv6 = configJSONBoolValue(object["block_ipv6"])
	}
	params.pingInterval = configOVPNReadChecked(object, "ping_interval", params.pingInterval)
	params.pingRestart = configOVPNReadChecked(object, "ping_restart", params.pingRestart)
	if _, present := object["ping_restart_disabled"]; present {
		params.pingRestartDisabled = configJSONBoolValue(object["ping_restart_disabled"])
	}
	params.renegotiateInterval = configOVPNReadChecked(object, "renegotiate_interval", params.renegotiateInterval)
	if _, present := object["renegotiate_disabled"]; present {
		params.renegotiateDisabled = configJSONBoolValue(object["renegotiate_disabled"])
	}
	if _, present := object["renegotiate_bytes"]; present {
		params.renegotiateBytes = configJSONInteger(object["renegotiate_bytes"])
	}
	if _, present := object["renegotiate_packets"]; present {
		params.renegotiatePackets = configJSONInteger(object["renegotiate_packets"])
	}
	params.tlsTimeout = configOVPNReadChecked(object, "tls_timeout", params.tlsTimeout)
	params.handshakeWindow = configOVPNReadChecked(object, "handshake_window", params.handshakeWindow)
	if _, present := object["explicit_exit_notify"]; present {
		params.explicitExitNotify = configJSONInt(object["explicit_exit_notify"])
	}
	if _, present := object["system"]; present {
		params.system = configJSONBoolValue(object["system"])
	}
	if _, present := object["name"]; present {
		params.interfaceName = configJSONString(object, "name")
	}
	if _, present := object["mtu"]; present {
		params.mtu = configJSONInt(object["mtu"])
	}
	if value, present := object["udp_timeout"]; present {
		if configOVPNIsNumber(value) && configJSONInteger(value) > 0 {
			params.udpTimeout = strconv.FormatInt(configJSONInteger(value), 10) + "s"
		} else {
			params.udpTimeout = configOVPNReadChecked(object, "udp_timeout", params.udpTimeout)
		}
	}
	if _, present := object["udp_mapping"]; present {
		params.udpMapping = configJSONString(object, "udp_mapping")
	}
	if _, present := object["udp_filtering"]; present {
		params.udpFiltering = configJSONString(object, "udp_filtering")
	}
	if _, present := object["udp_nat_max"]; present {
		params.udpNATMax = configJSONInt(object["udp_nat_max"])
	}
	// Legacy checkboxes: the mode determines tunnel_dns when no stored value
	// exists. These and otp_profile_id never reach the core.
	if _, present := object["tunnel_dns"]; present {
		params.tunnelDNS = configJSONString(object, "tunnel_dns")
	} else if configJSONBoolValue(object["block_outside_dns"]) {
		params.tunnelDNS = "strict"
	} else if _, present := object["use_tunnel_dns"]; present && !configJSONBoolValue(object["use_tunnel_dns"]) {
		params.tunnelDNS = "none"
	} else {
		params.tunnelDNS = "prefer"
	}
	return params, nil
}

// configOVPNNormalizeFingerprint strips separators and lower-cases, as
// OpenVpnChecks.openVpnNormalizeFingerprint does in Tls.build.
func configOVPNNormalizeFingerprint(line string) string {
	var out strings.Builder
	for _, character := range line {
		if character == ':' || unicode.IsSpace(character) {
			continue
		}
		out.WriteRune(unicode.ToLower(character))
	}
	return out.String()
}

// configOVPNNormalizeTLSCipher is openVpnNormalizeTlsCipher: OpenSSL names of
// the form TLS-*-WITH-* become the Go spelling (upper-case, underscores).
func configOVPNNormalizeTLSCipher(text string) string {
	tokens := strings.Split(strings.TrimSpace(text), ":")
	for index, token := range tokens {
		upper := strings.ToUpper(token)
		if strings.HasPrefix(upper, "TLS-") && strings.Contains(upper, "-WITH-") {
			tokens[index] = strings.ReplaceAll(upper, "-", "_")
		}
	}
	return strings.Join(tokens, ":")
}

// configOpenVPNTLSBuild is OpenVpn.Tls.build: the OpenVPN TLS object, not the
// sing-box one.
func configOpenVPNTLSBuild(tls configOpenVPNTLS) map[string]any {
	object := map[string]any{}
	if tls.serverName != "" {
		object["server_name"] = tls.serverName
	}
	if tls.serverNameType != "" {
		object["server_name_type"] = tls.serverNameType
	}
	if len(tls.certificate) > 0 {
		object["certificate"] = configNonBlankStrings(tls.certificate)
	}
	if tls.certificatePath != "" {
		object["certificate_path"] = tls.certificatePath
	}
	if len(tls.clientCertificate) > 0 {
		object["client_certificate"] = configNonBlankStrings(tls.clientCertificate)
	}
	if tls.clientCertificatePath != "" {
		object["client_certificate_path"] = tls.clientCertificatePath
	}
	if len(tls.clientKey) > 0 {
		object["client_key"] = configNonBlankStrings(tls.clientKey)
	}
	if tls.clientKeyPath != "" {
		object["client_key_path"] = tls.clientKeyPath
	}
	if len(tls.peerFingerprint) > 0 {
		object["peer_fingerprint"] = configNonBlankStrings(tls.peerFingerprint)
	}
	if tls.crlPath != "" {
		object["crl_path"] = tls.crlPath
	}
	if len(tls.remoteCertificateKU) > 0 {
		object["remote_certificate_ku"] = configNonBlankStrings(tls.remoteCertificateKU)
	}
	if tls.remoteCertificateEKU != "" {
		object["remote_certificate_eku"] = tls.remoteCertificateEKU
	}
	if tls.remoteCertificateTLS != "" {
		object["remote_certificate_tls"] = tls.remoteCertificateTLS
	}
	if tls.certificateProfile != "" {
		object["certificate_profile"] = tls.certificateProfile
	}
	if tls.nsCertificateType != "" {
		object["ns_certificate_type"] = tls.nsCertificateType
	}
	if tls.versionMin != "" {
		object["version_min"] = tls.versionMin
	}
	if tls.versionMax != "" {
		object["version_max"] = tls.versionMax
	}
	if tls.cipher != "" {
		object["cipher"] = tls.cipher
	}
	if tls.groups != "" {
		object["groups"] = tls.groups
	}
	if wrap := tls.controlWrap; wrap.kind != "" {
		item := map[string]any{"type": wrap.kind}
		if len(wrap.key) > 0 {
			item["key"] = configNonBlankStrings(wrap.key)
		}
		if wrap.keyPath != "" {
			item["key_path"] = wrap.keyPath
		}
		if wrap.direction != "" {
			item["direction"] = wrap.direction
		}
		object["control_wrap"] = item
	}
	if len(tls.peerFingerprint) > 0 {
		fingerprints := make([]any, 0, len(tls.peerFingerprint))
		for _, item := range tls.peerFingerprint {
			normalized := configOVPNNormalizeFingerprint(item)
			if normalized != "" {
				fingerprints = append(fingerprints, normalized)
			}
		}
		if len(fingerprints) == 0 {
			delete(object, "peer_fingerprint")
		} else {
			object["peer_fingerprint"] = fingerprints
		}
	}
	if tls.cipher != "" {
		object["cipher"] = configOVPNNormalizeTLSCipher(tls.cipher)
	}
	if tls.groups != "" {
		object["groups"] = strings.ToUpper(strings.TrimSpace(tls.groups))
	}
	return object
}

// configBuildOpenVPN is OpenVpn.build. The core type is `openvpn-client`, the
// dial fields come before the server/servers pair (which is mutually
// exclusive), and cipher/auth names are emitted in canonical upper case.
func configBuildOpenVPN(out configOutbound, params configOpenVPNParams) (map[string]any, error) {
	if params.mode == "static_key" && len(params.staticKey) == 0 && params.staticKeyPath == "" {
		return nil, fmt.Errorf("openvpn: static_key mode requires static_key or static_key_path")
	}
	if len(params.staticKey) > 0 && params.staticKeyPath != "" {
		return nil, fmt.Errorf("openvpn: static_key and static_key_path conflict")
	}
	object := map[string]any{"type": "openvpn-client"}
	if out.name != "" {
		object["tag"] = out.name
	}
	for key, value := range configDialFieldsBuild(out.dial) {
		object[key] = value
	}

	if len(params.servers) == 0 {
		if out.server != "" {
			object["server"] = out.server
		}
		if out.serverPort > 0 {
			object["server_port"] = out.serverPort
		}
	} else {
		remotes := make([]any, 0, len(params.servers))
		for _, remote := range params.servers {
			item := map[string]any{}
			if remote.server != "" {
				item["server"] = remote.server
			}
			if remote.serverPort > 0 {
				item["server_port"] = remote.serverPort
			}
			if remote.network != "" {
				item["network"] = remote.network
			}
			if len(item) > 0 {
				remotes = append(remotes, item)
			}
		}
		object["servers"] = remotes
		if params.remoteRandom {
			object["remote_random"] = true
		}
	}

	if params.username != "" {
		object["username"] = params.username
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.staticChallenge != "" {
		object["static_challenge"] = params.staticChallenge
	}
	if params.staticChallengeEcho {
		object["static_challenge_echo"] = true
	}
	if params.mode != "" {
		object["mode"] = params.mode
	}
	if params.network != "" {
		object["network"] = params.network
	}
	if len(params.address) > 0 {
		object["address"] = configNonBlankStrings(params.address)
	}
	if params.peerAddress != "" {
		object["peer_address"] = params.peerAddress
	}
	if params.peerAddressIPv6 != "" {
		object["peer_address_ipv6"] = params.peerAddressIPv6
	}
	if params.topology != "" {
		object["topology"] = params.topology
	}
	if params.authRetry != "" {
		object["auth_retry"] = params.authRetry
	}
	if len(params.staticKey) > 0 {
		object["static_key"] = configNonBlankStrings(params.staticKey)
	}
	if params.staticKeyPath != "" {
		object["static_key_path"] = params.staticKeyPath
	}
	if params.keyDirection != "" {
		object["key_direction"] = params.keyDirection
	}
	if tls := configOpenVPNTLSBuild(params.tls); len(tls) > 0 {
		object["tls"] = tls
	}
	if params.cipher != "" {
		object["cipher"] = strings.ToUpper(strings.TrimSpace(params.cipher))
	}
	if len(params.dataCiphers) > 0 {
		values := make([]string, 0, len(params.dataCiphers))
		for _, item := range params.dataCiphers {
			values = append(values, strings.ToUpper(strings.TrimSpace(item)))
		}
		object["data_ciphers"] = configNonBlankStrings(values)
	}
	if params.dataCiphersFallback != "" {
		object["data_ciphers_fallback"] = strings.ToUpper(strings.TrimSpace(params.dataCiphersFallback))
	}
	if params.auth != "" {
		object["auth"] = strings.ToUpper(strings.TrimSpace(params.auth))
	}
	if params.mssFix > 0 {
		object["mss_fix"] = params.mssFix
	}
	if params.mssFixDisabled {
		object["mss_fix_disabled"] = true
	}
	if params.mssFixMode != "" {
		object["mss_fix_mode"] = params.mssFixMode
	}
	if params.fragment > 0 {
		object["fragment"] = params.fragment
	}
	if params.replayWindow > 0 {
		object["replay_window"] = params.replayWindow
	}
	if params.replayWindowTime != "" {
		object["replay_window_time"] = params.replayWindowTime
	}
	if params.compression != "" {
		object["compression"] = params.compression
	}
	if params.compressionLZO != "" {
		object["compression_lzo"] = params.compressionLZO
	}
	if params.allowCompression != "" {
		object["allow_compression"] = params.allowCompression
	}
	if params.routeNoPull {
		object["route_no_pull"] = true
	}
	if len(params.pullFilters) > 0 {
		filters := make([]any, 0, len(params.pullFilters))
		for _, filter := range params.pullFilters {
			if filter.action == "" && filter.text == "" {
				continue
			}
			item := map[string]any{"action": filter.action, "text": filter.text}
			filters = append(filters, item)
		}
		if len(filters) > 0 {
			object["pull_filters"] = filters
		}
	}
	if len(params.routes) > 0 {
		object["routes"] = configNonBlankStrings(params.routes)
	}
	if params.routeGateway != "" {
		object["route_gateway"] = params.routeGateway
	}
	if params.routeMetric > 0 {
		object["route_metric"] = params.routeMetric
	}
	if params.redirectGateway {
		object["redirect_gateway"] = true
	}
	if len(params.redirectGWFlags) > 0 {
		object["redirect_gateway_flags"] = configNonBlankStrings(params.redirectGWFlags)
	}
	if params.redirectPrivate {
		object["redirect_private"] = true
	}
	if params.blockIPv6 {
		object["block_ipv6"] = true
	}
	if params.pingInterval != "" {
		object["ping_interval"] = params.pingInterval
	}
	if params.pingRestart != "" {
		object["ping_restart"] = params.pingRestart
	}
	if params.pingRestartDisabled {
		object["ping_restart_disabled"] = true
	}
	if params.renegotiateInterval != "" {
		object["renegotiate_interval"] = params.renegotiateInterval
	}
	if params.renegotiateDisabled {
		object["renegotiate_disabled"] = true
	}
	if params.renegotiateBytes > 0 {
		object["renegotiate_bytes"] = params.renegotiateBytes
	}
	if params.renegotiatePackets > 0 {
		object["renegotiate_packets"] = params.renegotiatePackets
	}
	if params.tlsTimeout != "" {
		object["tls_timeout"] = params.tlsTimeout
	}
	if params.handshakeWindow != "" {
		object["handshake_window"] = params.handshakeWindow
	}
	if params.explicitExitNotify > 0 {
		object["explicit_exit_notify"] = params.explicitExitNotify
	}
	if params.system {
		object["system"] = true
	}
	if params.interfaceName != "" {
		object["name"] = params.interfaceName
	}
	if params.mtu > 0 {
		object["mtu"] = params.mtu
	}
	if params.udpTimeout != "" {
		object["udp_timeout"] = params.udpTimeout
	}
	if params.udpMapping != "" {
		object["udp_mapping"] = params.udpMapping
	}
	if params.udpFiltering != "" {
		object["udp_filtering"] = params.udpFiltering
	}
	if params.udpNATMax > 0 {
		object["udp_nat_max"] = params.udpNATMax
	}
	return object, nil
}
