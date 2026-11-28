// Stored validation for the two endpoint types (OpenVPN and OpenConnect).
//
// Oracle: OpenVpn.validate / OpenVpnChecks and OpenConnect.validate /
// OpenConnectChecks, plus the shared Outbound.validate endpoint rules and
// DialFields.validate. The checks and their verdicts (error vs warning) match
// Kotlin; the messages are stable English strings because this path has no
// localisation contract.
//
// The check order follows the other Go stored validators (dial fields,
// endpoint, type-specific) rather than the Kotlin interleaving, so every Go
// verdict is presented in one order. A document carrying a key this slice does
// not model answers supported:false before any verdict, so a half-understood
// document never produces a confident answer.
package mobile

import (
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// profileOpenVPNNetworks is OPENVPN_NETWORKS: "" lets the core pick.
var profileOpenVPNNetworks = []string{"", "udp", "udp4", "udp6", "tcp", "tcp4", "tcp6"}

var profileOpenVPNControlWrapTypes = []string{"tls_auth", "tls_crypt", "tls_crypt_v2"}

var profileOpenVPNTopologies = []string{"net30", "p2p", "subnet"}

var profileOpenVPNAuthRetries = []string{"none", "nointeract", "interact"}

var profileOpenVPNKeyDirections = []string{"server", "client"}

var profileOpenVPNMSSFixModes = []string{"mtu", "fixed"}

var profileOpenVPNDirections = []string{"server", "client"}

var profileOpenVPNPullFilterActions = []string{"accept", "ignore", "reject"}

var profileOpenVPNRemoteCertificateTLSValues = []string{"server", "client", "none"}

var profileOpenVPNCertificateProfiles = []string{"legacy", "preferred", "insecure", "suiteb"}

var profileOpenVPNNSCertificateTypes = []string{"server", "client"}

var profileOpenVPNServerNameTypes = []string{"subject", "name", "name-prefix"}

var profileOpenVPNTLSVersions = []string{"1.0", "1.1", "1.2", "1.3"}

// handleProfileValidateVpn validates one openvpn/openconnect stored document.
// handled=false means the document is another type.
func handleProfileValidateVpn(object map[string]any, rawType string) (profileValidateResult, bool) {
	if rawType != "openvpn" && rawType != "openvpn-client" && rawType != "openconnect" {
		return profileValidateResult{}, false
	}
	if rawType == "openvpn-client" {
		rawType = "openvpn"
	}
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	issues := storedIssues{}
	if rawType == "openvpn" {
		model, unknown, err := profileOpenVPNParseStored(object, profileNewValidateMode)
		if err != nil {
			var unmodelled profileNewUnmodelled
			if errors.As(err, &unmodelled) {
				result.Supported = boolPointer(false)
				issues.addError("", fmt.Sprintf(
					"the stored %q document carries a value this validation does not model (%s); fall back to the Kotlin validator",
					rawType, unmodelled.Reason))
				return finishStoredValidation(result, issues, ""), true
			}
			issues.addError("", err.Error())
			return finishStoredValidation(result, issues, ""), true
		}
		if len(unknown) > 0 {
			result.Supported = boolPointer(false)
			issues.addError("", fmt.Sprintf(
				"the stored %q document carries a field this validation does not model (%s); fall back to the Kotlin validator",
				rawType, unknown[0]))
			return finishStoredValidation(result, issues, ""), true
		}
		validateOpenVPNDial(&issues, model)
		validateOpenVPNEndpoint(&issues, model)
		validateOpenVPNFields(&issues, model)
		normalized, err := MarshalCanonicalJSON(profileOpenVPNExportJSON(model))
		if err != nil {
			return profileValidateResult{}, true
		}
		result.Normalized = string(normalized)
		return finishStoredValidation(result, issues, result.Normalized), true
	}

	model, unknown, err := profileOpenConnectParseStored(object, profileNewValidateMode)
	if err != nil {
		var unmodelled profileNewUnmodelled
		if errors.As(err, &unmodelled) {
			result.Supported = boolPointer(false)
			issues.addError("", fmt.Sprintf(
				"the stored %q document carries a value this validation does not model (%s); fall back to the Kotlin validator",
				rawType, unmodelled.Reason))
			return finishStoredValidation(result, issues, ""), true
		}
		issues.addError("", err.Error())
		return finishStoredValidation(result, issues, ""), true
	}
	if len(unknown) > 0 {
		result.Supported = boolPointer(false)
		issues.addError("", fmt.Sprintf(
			"the stored %q document carries a field this validation does not model (%s); fall back to the Kotlin validator",
			rawType, unknown[0]))
		return finishStoredValidation(result, issues, ""), true
	}
	validateOpenConnectDial(&issues, model)
	validateOpenConnectEndpoint(&issues, model)
	validateOpenConnectFields(&issues, model)
	normalized, err := MarshalCanonicalJSON(profileOpenConnectExportJSON(model))
	if err != nil {
		return profileValidateResult{}, true
	}
	result.Normalized = string(normalized)
	return finishStoredValidation(result, issues, result.Normalized), true
}

// --- shared endpoint pieces -----------------------------------------------

// profileVpnValidateDial is DialFields.validate over the flat dial keys.
func profileVpnValidateDial(issues *storedIssues, dial map[string]any) {
	if value, present := dial["connect_timeout"]; present {
		if text, ok := value.(string); ok {
			if message := profileVpnDurationMessage(text, false, false, -1); message != "" {
				issues.addError("connect_timeout", "connect_timeout "+message)
			}
		}
	}
	for _, key := range []string{"inet4_bind_address", "inet6_bind_address"} {
		value, present := dial[key]
		if !present {
			continue
		}
		text, ok := value.(string)
		if !ok {
			continue
		}
		family := 6
		if key == "inet4_bind_address" {
			family = 4
		}
		if message := profileVpnIPMessage(text, family, true); message != "" {
			issues.addError(key, key+" "+message)
		}
	}
}

// profileVpnValidateEndpoint is the base outbound::Validate server checks.
func profileVpnValidateEndpoint(issues *storedIssues, server string, port int, portOptional, addressOptional bool) {
	address := profileVpnTrimmed(server)
	if address == "" {
		if !addressOptional {
			issues.addError("server", "server is required")
		}
	} else if !profileVpnHostOK(address) {
		issues.addError("server", fmt.Sprintf("%q is not a valid host", address))
	}
	portText := strconv.Itoa(port)
	if port == 0 {
		if !portOptional {
			issues.addError("server_port", "server_port is required")
		}
	} else if port < 1 || port > 65535 {
		issues.addError("server_port", portText+" must be a port number from 1 to 65535")
	}
}

func validateOpenVPNDial(issues *storedIssues, model *profileOpenVPN) {
	profileVpnValidateDial(issues, model.Dial)
}

func validateOpenConnectDial(issues *storedIssues, model *profileOpenConnect) {
	profileVpnValidateDial(issues, model.Dial)
}

func validateOpenVPNEndpoint(issues *storedIssues, model *profileOpenVPN) {
	profileVpnValidateEndpoint(issues, model.Server, model.Port, len(model.Servers) > 0, len(model.Servers) > 0)
}

func validateOpenConnectEndpoint(issues *storedIssues, model *profileOpenConnect) {
	profileVpnValidateEndpoint(issues, model.Server, model.Port, true, false)
}

// --- OpenVpn.validate ------------------------------------------------------

func validateOpenVPNFields(issues *storedIssues, model *profileOpenVPN) {
	report := func(field, message string) {
		if message != "" {
			issues.addError(field, message)
		}
	}
	reportOneOf := func(field, value string, allowed []string) {
		if value == "" || profileNewOneOf(value, allowed, false) {
			return
		}
		issues.addError(field, field+" must be one of "+strings.Join(allowed, ", "))
	}
	reportItems := func(field string, items []string, rule func(string) string) {
		for _, item := range items {
			if message := rule(item); message != "" {
				issues.addError(field, item+" "+message)
				return
			}
		}
	}

	reportOneOf("mode", model.Mode, []string{"tls", "static_key"})
	reportOneOf("network", model.Network, profileOpenVPNNetworks)
	if len(model.Servers) == 0 && (strings.HasPrefix(model.Server, "[") || strings.HasSuffix(model.Server, "]")) {
		report("server", profileOpenVPNRemoteHostMessage(model.Server))
	}
	for index, remote := range model.Servers {
		field := fmt.Sprintf("servers[%d]", index)
		report(field+".server", profileOpenVPNRemoteHostMessage(remote.Server))
		report(field+".server_port", profileVpnPortMessage(strconv.Itoa(remote.Port)))
		reportOneOf(field+".network", remote.Network, profileOpenVPNNetworks)
	}
	for _, item := range model.Address {
		if !profileVpnCIDROK(item) {
			issues.addError("address", fmt.Sprintf("%q must be a CIDR prefix such as 10.0.0.0/8", item))
			break
		}
	}
	report("peer_address", profileVpnIPMessage(model.PeerAddress, 4, true))
	report("peer_address_ipv6", profileVpnIPMessage(model.PeerAddressIPv6, 6, true))
	reportOneOf("topology", model.Topology, profileOpenVPNTopologies)
	reportOneOf("auth_retry", model.AuthRetry, profileOpenVPNAuthRetries)
	reportOneOf("key_direction", model.KeyDirection, profileOpenVPNKeyDirections)
	report("cipher", profileOpenVPNCipherNameMessage(model.Cipher))
	reportItems("data_ciphers", model.DataCiphers, profileOpenVPNCipherNameMessage)
	report("data_ciphers_fallback", profileOpenVPNCipherNameMessage(model.DataCiphersFallback))
	report("auth", profileOpenVPNDigestMessage(model.Auth))
	reportOneOf("mss_fix_mode", model.MSSFixMode, profileOpenVPNMSSFixModes)
	report("fragment", profileOpenVPNOpenVPNFragmentMessage(strconv.Itoa(model.Fragment)))
	report("replay_window", profileOpenVPNReplayWindowMessage(strconv.Itoa(model.ReplayWindow)))
	report("replay_window_time", profileOpenVPNReplayWindowTimeMessage(model.ReplayWindowTime))
	reportItems("routes", model.Routes, func(item string) string {
		if profileVpnCIDROK(item) {
			return ""
		}
		return "must be a CIDR prefix such as 10.0.0.0/8"
	})
	report("route_gateway", profileVpnIPMessage(model.RouteGateway, 0, true))
	report("ping_interval", profileOpenVPNDurationRuleMessage(model.PingInterval, true))
	report("ping_restart", profileOpenVPNDurationRuleMessage(model.PingRestart, true))
	report("renegotiate_interval", profileOpenVPNDurationRuleMessage(model.RenegotiateInterval, false))
	report("tls_timeout", profileOpenVPNDurationRuleMessage(model.TLSTimeout, false))
	report("handshake_window", profileOpenVPNDurationRuleMessage(model.HandshakeWindow, false))
	report("udp_timeout", profileVpnDurationMessage(model.UDPTimeout, false, false, -1))
	for index, filter := range model.PullFilters {
		if filter.Action == "" && filter.Text == "" {
			continue
		}
		field := fmt.Sprintf("pull_filters[%d]", index)
		if filter.Action == "" {
			issues.addError(field+".action", field+".action is required")
		} else if !profileNewOneOf(filter.Action, profileOpenVPNPullFilterActions, false) {
			issues.addError(field+".action", field+".action must be one of "+strings.Join(profileOpenVPNPullFilterActions, ", "))
		}
		if profileVpnTrimmed(filter.Text) == "" {
			issues.addError(field+".text", field+".text is required")
		}
	}

	reportOneOf("tls.server_name_type", model.TLS.ServerNameType, profileOpenVPNServerNameTypes)
	reportItems("tls.peer_fingerprint", model.TLS.PeerFingerprint, func(item string) string {
		if profileVpnFingerprintOK(item) {
			return ""
		}
		return "must be a 64-digit SHA-256 fingerprint"
	})
	reportItems("tls.remote_certificate_ku", model.TLS.RemoteCertificateKU, func(item string) string {
		if profileOpenVPNKeyUsageOK(item) {
			return ""
		}
		return "must be a hexadecimal key-usage value of at most 16 digits"
	})
	report("tls.remote_certificate_eku", profileOpenVPNExtendedKeyUsageMessage(model.TLS.RemoteCertificateEKU))
	reportOneOf("tls.remote_certificate_tls", model.TLS.RemoteCertificateTLS, profileOpenVPNRemoteCertificateTLSValues)
	reportOneOf("tls.certificate_profile", model.TLS.CertificateProfile, profileOpenVPNCertificateProfiles)
	reportOneOf("tls.ns_certificate_type", model.TLS.NSCertificateType, profileOpenVPNNSCertificateTypes)
	reportOneOf("tls.version_min", model.TLS.VersionMin, profileOpenVPNTLSVersions)
	reportOneOf("tls.version_max", model.TLS.VersionMax, profileOpenVPNTLSVersions)
	report("tls.cipher", profileOpenVPNTLSCipherMessage(model.TLS.Cipher))
	report("tls.groups", profileOpenVPNTLSGroupsMessage(model.TLS.Groups))

	for _, key := range profileOpenVPNModeConflicts(model) {
		report(key, profileOpenVPNModeConflictMessage(model, key))
	}
	report("static_key", profileOpenVPNStaticKeyMissingMessage(model))
	report("static_key", profileVpnMaterialConflictMessage(model.StaticKey, model.StaticKeyPath))
	report("cipher", profileOpenVPNStaticCipherMessage(model))
	report("address", profileOpenVPNStaticAddressMessage(model))
	report("tls.certificate", profileOpenVPNTLSVerificationMessage(model))
	report("tls.client_certificate", profileOpenVPNClientPairMessage(model))
	report("tls.certificate", profileVpnMaterialConflictMessage(model.TLS.Certificate, model.TLS.CertificatePath))
	report("tls.client_certificate", profileVpnMaterialConflictMessage(model.TLS.ClientCertificate, model.TLS.ClientCertificatePath))
	report("tls.client_key", profileVpnMaterialConflictMessage(model.TLS.ClientKey, model.TLS.ClientKeyPath))
	report("tls.control_wrap.key", profileVpnMaterialConflictMessage(model.TLS.ControlWrap.Key, model.TLS.ControlWrap.KeyPath))
	report("tls.control_wrap.type", profileOpenVPNControlWrapKeyMessage(model))
	report("tls.control_wrap.direction", profileOpenVPNControlWrapDirectionMessage(model))
	report("tls.remote_certificate_eku", profileOpenVPNRemoteCertificateMessage(model))
	report("tls.version_max", profileOpenVPNTLSVersionsMessage(model))
	report("mss_fix", profileOpenVPNMSSFixMessage(model))
	report("ping_restart", profileOpenVPNPingRestartMessage(model))
	report("renegotiate_interval", profileOpenVPNRenegotiateMessage(model))
}

func profileOpenVPNStaticMode(model *profileOpenVPN) bool { return model.Mode == "static_key" }

func profileOpenVPNPullFiltersSet(model *profileOpenVPN) bool {
	for _, filter := range model.PullFilters {
		if filter.Action != "" || filter.Text != "" {
			return true
		}
	}
	return false
}

// profileVpnDurationSet is OpenVpnChecks.durationSet: an empty value is unset,
// an unparsable one counts as set so the field's own rule reports it.
func profileVpnDurationSet(text string) bool {
	if profileVpnTrimmed(text) == "" {
		return false
	}
	if ns, ok := profileVpnDurationNs(text); ok {
		return ns != 0
	}
	return true
}

// profileOpenVPNModeConflicts is OpenVpnChecks.openVpnModeConflicts: the keys
// the profile's mode refuses.
func profileOpenVPNModeConflicts(model *profileOpenVPN) []string {
	var keys []string
	add := func(set bool, key string) {
		if set {
			keys = append(keys, key)
		}
	}
	if !profileOpenVPNStaticMode(model) {
		add(len(model.StaticKey) > 0, "static_key")
		add(model.StaticKeyPath != "", "static_key_path")
		add(model.KeyDirection != "", "key_direction")
		add(model.Cipher != "", "cipher")
		return keys
	}
	tls := model.TLS
	add(model.Username != "", "username")
	add(model.Password != "", "password")
	add(model.AuthRetry != "" && model.AuthRetry != "none", "auth_retry")
	add(model.StaticChallenge != "", "static_challenge")
	add(model.StaticChallengeEcho, "static_challenge_echo")
	add(model.RouteNoPull, "route_no_pull")
	add(profileOpenVPNPullFiltersSet(model), "pull_filters")
	add(profileVpnDurationSet(model.RenegotiateInterval), "renegotiate_interval")
	add(model.RenegotiateDisabled, "renegotiate_disabled")
	add(model.RenegotiateBytes > 0, "renegotiate_bytes")
	add(model.RenegotiatePackets > 0, "renegotiate_packets")
	add(profileVpnDurationSet(model.TLSTimeout), "tls_timeout")
	add(profileVpnDurationSet(model.HandshakeWindow), "handshake_window")
	add(len(model.DataCiphers) > 0, "data_ciphers")
	add(model.DataCiphersFallback != "", "data_ciphers_fallback")
	add(tls.ServerName != "", "tls.server_name")
	add(tls.ServerNameType != "", "tls.server_name_type")
	add(len(tls.Certificate) > 0, "tls.certificate")
	add(tls.CertificatePath != "", "tls.certificate_path")
	add(len(tls.ClientCertificate) > 0, "tls.client_certificate")
	add(tls.ClientCertificatePath != "", "tls.client_certificate_path")
	add(len(tls.ClientKey) > 0, "tls.client_key")
	add(tls.ClientKeyPath != "", "tls.client_key_path")
	add(len(tls.PeerFingerprint) > 0, "tls.peer_fingerprint")
	add(tls.CRLPath != "", "tls.crl_path")
	add(len(tls.RemoteCertificateKU) > 0, "tls.remote_certificate_ku")
	add(tls.RemoteCertificateEKU != "", "tls.remote_certificate_eku")
	add(tls.RemoteCertificateTLS != "", "tls.remote_certificate_tls")
	add(tls.CertificateProfile != "", "tls.certificate_profile")
	add(tls.NSCertificateType != "", "tls.ns_certificate_type")
	add(tls.VersionMin != "", "tls.version_min")
	add(tls.VersionMax != "", "tls.version_max")
	add(tls.Cipher != "", "tls.cipher")
	add(tls.Groups != "", "tls.groups")
	add(tls.ControlWrap.Kind != "", "tls.control_wrap")
	return keys
}

// profileOpenVPNModeConflictMessage is OpenVpnChecks.openVpnModeConflict.
func profileOpenVPNModeConflictMessage(model *profileOpenVPN, key string) string {
	found := false
	for _, candidate := range profileOpenVPNModeConflicts(model) {
		if candidate == key {
			found = true
		}
	}
	if !found {
		return ""
	}
	if profileOpenVPNStaticMode(model) {
		return "is not used in static-key mode"
	}
	if key == "cipher" {
		return "is only used in static-key mode; set data_ciphers_fallback for TLS mode"
	}
	if key == "key_direction" {
		return "is only used in static-key mode"
	}
	return "is only used in TLS mode"
}

// profileOpenVPNStaticKeyMissingMessage is OpenVpnChecks.openVpnStaticKeyMissing.
func profileOpenVPNStaticKeyMissingMessage(model *profileOpenVPN) string {
	if !profileOpenVPNStaticMode(model) || len(model.StaticKey) > 0 || model.StaticKeyPath != "" {
		return ""
	}
	return "a static-key profile requires the secret"
}

// profileOpenVPNStaticCipherMessage is OpenVpnChecks.openVpnStaticCipher.
func profileOpenVPNStaticCipherMessage(model *profileOpenVPN) string {
	if !profileOpenVPNStaticMode(model) {
		return ""
	}
	cipher, ok := profileNewASCIIUpper(profileVpnTrimmed(model.Cipher))
	if !ok {
		return "must be an OpenVPN cipher name"
	}
	if cipher == "" {
		return "a static-key profile requires a cipher"
	}
	if profileOpenVPNDataCipher(cipher) && !profileOpenVPNStaticCipher(cipher) {
		return "a static-key profile needs a CBC cipher or NONE, not an AEAD"
	}
	return ""
}

// profileOpenVPNStaticAddressMessage is OpenVpnChecks.openVpnStaticAddress.
func profileOpenVPNStaticAddressMessage(model *profileOpenVPN) string {
	if !profileOpenVPNStaticMode(model) {
		return ""
	}
	if len(model.Address) == 0 {
		return "a static-key profile requires an address"
	}
	hasV4, hasV6 := false, false
	for _, item := range model.Address {
		// A malformed item is reported by its own rule.
		if !profileVpnCIDROK(item) {
			return ""
		}
		if strings.Contains(item, ":") {
			hasV6 = true
		} else {
			hasV4 = true
		}
	}
	peer4 := profileVpnTrimmed(model.PeerAddress) != ""
	peer6 := profileVpnTrimmed(model.PeerAddressIPv6) != ""
	if hasV4 && !peer4 {
		return "an IPv4 address requires peer_address"
	}
	if hasV6 && !peer6 {
		return "an IPv6 address requires peer_address_ipv6"
	}
	if peer4 && !hasV4 {
		return "peer_address is set without an IPv4 address"
	}
	if peer6 && !hasV6 {
		return "peer_address_ipv6 is set without an IPv6 address"
	}
	return ""
}

// profileOpenVPNTLSVerificationMessage is
// OpenVpnChecks.openVpnTlsVerification: requireCAOrPeerFingerprint runs at
// session start, so a bare client pair still fails.
func profileOpenVPNTLSVerificationMessage(model *profileOpenVPN) string {
	if profileOpenVPNStaticMode(model) {
		return ""
	}
	tls := model.TLS
	if len(tls.Certificate) > 0 || profileVpnTrimmed(tls.CertificatePath) != "" || len(tls.PeerFingerprint) > 0 {
		return ""
	}
	return "TLS mode requires a CA certificate or a peer fingerprint"
}

// profileOpenVPNClientPairMessage is OpenVpnChecks.openVpnClientPair.
func profileOpenVPNClientPairMessage(model *profileOpenVPN) string {
	if profileOpenVPNStaticMode(model) {
		return ""
	}
	tls := model.TLS
	certificate := len(tls.ClientCertificate) > 0 || tls.ClientCertificatePath != ""
	key := len(tls.ClientKey) > 0 || tls.ClientKeyPath != ""
	if certificate == key {
		return ""
	}
	if certificate {
		return "a client certificate requires its client key"
	}
	return "a client key requires its client certificate"
}

// profileVpnMaterialConflictMessage is
// OpenVpnChecks.vpnMaterialConflict: the same material pasted and as a file
// path, which the core refuses.
func profileVpnMaterialConflictMessage(inline []string, path string) string {
	if len(inline) == 0 || profileVpnTrimmed(path) == "" {
		return ""
	}
	return "the inline value and a file path are both set; the core refuses both"
}

// profileOpenVPNControlWrapKeyMessage is OpenVpnChecks.openVpnControlWrapKey.
func profileOpenVPNControlWrapKeyMessage(model *profileOpenVPN) string {
	wrap := model.TLS.ControlWrap
	key := len(wrap.Key) > 0 || profileVpnTrimmed(wrap.KeyPath) != ""
	if wrap.Kind == "" {
		if !key {
			return ""
		}
		if profileOpenVPNStaticMode(model) {
			return "a control-channel wrap is not used in static-key mode"
		}
		return "a control-channel key requires a type"
	}
	if !profileNewOneOf(wrap.Kind, profileOpenVPNControlWrapTypes, false) {
		return "the type must be tls_auth, tls_crypt or tls_crypt_v2"
	}
	if !key {
		return "the wrap requires a key"
	}
	return ""
}

// profileOpenVPNControlWrapDirectionMessage is
// OpenVpnChecks.openVpnControlWrapDirection.
func profileOpenVPNControlWrapDirectionMessage(model *profileOpenVPN) string {
	wrap := model.TLS.ControlWrap
	if wrap.Direction == "" {
		return ""
	}
	if !profileNewOneOf(wrap.Direction, profileOpenVPNDirections, false) {
		return "the direction must be server or client"
	}
	if wrap.Kind != "tls_auth" {
		return "only tls-auth takes a direction"
	}
	return ""
}

// profileOpenVPNRemoteCertificateMessage is
// OpenVpnChecks.openVpnRemoteCertificate.
func profileOpenVPNRemoteCertificateMessage(model *profileOpenVPN) string {
	tls := model.TLS
	if profileVpnTrimmed(tls.RemoteCertificateEKU) == "" || tls.RemoteCertificateTLS == "" {
		return ""
	}
	return "remote-cert-eku replaces remote-cert-tls; remove one"
}

// profileOpenVPNTLSVersionsMessage is OpenVpnChecks.openVpnTlsVersions: an
// unset minimum is 1.2.
func profileOpenVPNTLSVersionsMessage(model *profileOpenVPN) string {
	tls := model.TLS
	indexOf := func(value string) int {
		for index, candidate := range profileOpenVPNTLSVersions {
			if candidate == value {
				return index
			}
		}
		return -1
	}
	minimum := tls.VersionMin
	if minimum == "" {
		minimum = "1.2"
	}
	min := indexOf(minimum)
	max := indexOf(tls.VersionMax)
	if min < 0 || max < 0 || max >= min {
		return ""
	}
	return "version_max must not be lower than version_min"
}

// profileOpenVPNMSSFixMessage is OpenVpnChecks.openVpnMssFix.
func profileOpenVPNMSSFixMessage(model *profileOpenVPN) string {
	if model.MSSFixDisabled && model.MSSFix > 0 {
		return "mss_fix must be empty while mss_fix_disabled is set"
	}
	if model.MSSFixDisabled && model.MSSFixMode != "" {
		return "mss_fix_mode must be empty while mss_fix_disabled is set"
	}
	if model.MSSFix <= 0 && model.MSSFixMode != "" {
		return "mss_fix_mode needs a positive mss_fix"
	}
	return ""
}

// profileOpenVPNPingRestartMessage is OpenVpnChecks.openVpnPingRestart.
func profileOpenVPNPingRestartMessage(model *profileOpenVPN) string {
	if !model.PingRestartDisabled {
		return ""
	}
	ns, ok := profileVpnDurationNs(model.PingRestart)
	if !ok || ns <= 0 {
		return ""
	}
	return "ping_restart must be empty while ping_restart_disabled is set"
}

// profileOpenVPNRenegotiateMessage is OpenVpnChecks.openVpnRenegotiate.
func profileOpenVPNRenegotiateMessage(model *profileOpenVPN) string {
	if !model.RenegotiateDisabled {
		return ""
	}
	ns, ok := profileVpnDurationNs(model.RenegotiateInterval)
	if !ok || ns <= 0 {
		return ""
	}
	return "renegotiate_interval must be empty while renegotiate_disabled is set"
}

// --- OpenConnect.validate --------------------------------------------------

// profileOpenConnectTokenModes is OpenConnectChecks.TOKEN_MODES.
var profileOpenConnectTokenModes = []string{"totp", "hotp", "stoken", "oidc"}

func validateOpenConnectFields(issues *storedIssues, model *profileOpenConnect) {
	report := func(field, message string) {
		if message != "" {
			issues.addError(field, message)
		}
	}
	reportOneOf := func(field, value string, allowed []string) {
		if value == "" || profileNewOneOf(value, allowed, false) {
			return
		}
		issues.addError(field, field+" must be one of "+strings.Join(allowed, ", "))
	}
	reportOneOf("flavor", model.Flavor, profileOpenConnectFlavors)
	report("server_path", profileOpenConnectServerPathMessage(model.ServerPath))
	mtuText := strconv.Itoa(model.MTU)
	report("mtu", profileVpnIntMessage(mtuText, 0, 65535))
	if message := profileOpenConnectMTUFloorMessage(mtuText); message != "" {
		issues.addWarning("mtu", message)
	}
	baseMTUText := strconv.Itoa(model.BaseMTU)
	report("base_mtu", profileVpnIntMessage(baseMTUText, 0, 65535))
	if message := profileOpenConnectMTUFloorMessage(baseMTUText); message != "" {
		issues.addWarning("base_mtu", message)
	}
	if model.DTLSLocalPort != 0 {
		report("dtls_local_port", profileVpnPortMessage(strconv.Itoa(model.DTLSLocalPort)))
	}
	if message := profileOpenConnectReportedOSMessage(model.Flavor, model.ReportedOS); message != "" {
		issues.addError("reported_os", "reported_os "+message)
	}
	reportOneOf("compression_mode", model.CompressionMode, profileOpenConnectCompressionModes)
	report("dpd_interval", profileVpnDurationMessage(model.DPDInterval, false, false, -1))
	if message := profileOpenConnectDPDFloorMessage(model.DPDInterval); message != "" {
		issues.addWarning("dpd_interval", message)
	}
	report("reconnect_timeout", profileVpnDurationMessage(model.ReconnectTimeout, false, false, -1))
	report("trojan_interval", profileVpnDurationMessage(model.TrojanInterval, false, false, -1))
	report("udp_timeout", profileVpnDurationMessage(model.UDPTimeout, false, false, -1))
	report("tls.server_name", profileVpnServerNameMessage(model.TLS.ServerName))
	for _, line := range model.TLS.PeerFingerprint {
		if message := profileOpenConnectFingerprintMessage(line); message != "" {
			issues.addError("tls.peer_fingerprint", line+" "+message)
			break
		}
	}
	report("tls.certificate_authority", profileVpnMaterialConflictMessage(model.TLS.CertificateAuthority, model.TLS.CertificateAuthorityPath))
	report("tls.client_certificate", profileVpnMaterialConflictMessage(model.TLS.ClientCertificate, model.TLS.ClientCertificatePath))
	report("tls.client_key", profileVpnMaterialConflictMessage(model.TLS.ClientKey, model.TLS.ClientKeyPath))
	report("tls.mca_certificate", profileVpnMaterialConflictMessage(model.TLS.MCACertificate, model.TLS.MCACertificatePath))
	report("tls.mca_key", profileVpnMaterialConflictMessage(model.TLS.MCAKey, model.TLS.MCAKeyPath))
	report("tls.client_certificate", profileOpenConnectCertificatePairMessage(
		model.TLS.ClientCertificate, model.TLS.ClientCertificatePath, model.TLS.ClientKey, model.TLS.ClientKeyPath))
	report("tls.mca_certificate", profileOpenConnectCertificatePairMessage(
		model.TLS.MCACertificate, model.TLS.MCACertificatePath, model.TLS.MCAKey, model.TLS.MCAKeyPath))
	for index, certificate := range model.TNCC.Certificates {
		report(fmt.Sprintf("tncc.certificates[%d]", index),
			profileVpnMaterialConflictMessage(certificate.Certificate, certificate.CertificatePath))
	}
	report("token", profileOpenConnectTokenMessage(model))
	if message := profileOpenConnectTokenUnusedMessage(model); message != "" {
		issues.addWarning("token", message)
	}
	if message := profileOpenConnectTokenCounterMessage(model); message != "" {
		issues.addWarning("token.counter", message)
	}
	report("mobile", profileOpenConnectMobileMessage(model))
	report("compression_mode", profileOpenConnectCompressionMessage(model))
	for index, entry := range model.FormEntries {
		if message := profileOpenConnectFormEntryMessage(entry.FormID, entry.SubmissionKey, entry.Name, entry.Value, entry.Promote); message != "" {
			issues.addError(fmt.Sprintf("form_entries[%d]", index), message)
		}
	}
}

// profileOpenConnectServerPathMessage is
// OpenConnectChecks.openConnectServerPath: the core parses the composed server
// with net/url and refuses a query or fragment.
func profileOpenConnectServerPathMessage(text string) string {
	path := profileVpnTrimmed(text)
	if strings.ContainsAny(path, "?#") {
		return "must not contain a query or fragment"
	}
	for index := 0; index < len(path); index++ {
		if path[index] != '%' {
			continue
		}
		if index+2 >= len(path) {
			return "has an incomplete percent escape"
		}
		if _, ok := configHexDigit(path[index+1]); !ok {
			return "has an incomplete percent escape"
		}
		if _, ok := configHexDigit(path[index+2]); !ok {
			return "has an incomplete percent escape"
		}
		index += 2
	}
	return ""
}

// profileOpenConnectMTUFloorMessage is OpenConnectChecks.openConnectMtuFloor:
// the core raises a smaller MTU to 576.
func profileOpenConnectMTUFloorMessage(text string) string {
	value, _ := profileVpnParseLong(profileVpnTrimmed(text))
	if value <= 0 || value >= 576 {
		return ""
	}
	return "a value below 576 is raised to 576 by the core"
}

// profileOpenConnectDPDFloorMessage is OpenConnectChecks.openConnectDpdFloor:
// NewClient raises a shorter interval to 2s.
func profileOpenConnectDPDFloorMessage(text string) string {
	ns, ok := profileVpnDurationNs(profileVpnTrimmed(text))
	if !ok || ns <= 0 || ns >= 2000000000 {
		return ""
	}
	return "an interval below 2s is raised to 2s by the core"
}

// profileOpenConnectFingerprintMessage is
// OpenConnectChecks.openConnectFingerprint (sing-openconnect
// parsePeerFingerprint).
func profileOpenConnectFingerprintMessage(line string) string {
	value := profileVpnTrimmed(line)
	if value == "" {
		return ""
	}
	encoded := value
	maximum := 40
	base64Value := false
	switch {
	case strings.HasPrefix(value, "sha1:"):
		encoded = value[5:]
	case strings.HasPrefix(value, "sha256:"):
		encoded = value[7:]
		maximum = 64
	case strings.HasPrefix(value, "pin-sha256:"):
		encoded = value[11:]
		maximum = 44
		base64Value = true
	case strings.Contains(value, ":"):
		return "must not use colons"
	}
	ok := len(encoded) >= 4 && len(encoded) <= maximum
	for index := 0; ok && index < len(encoded); index++ {
		char := encoded[index]
		isBase64 := (char >= '0' && char <= '9') || (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') || char == '+' || char == '/' ||
			(char == '=' && index >= len(encoded)-2)
		if base64Value {
			ok = isBase64
		} else {
			_, ok = configHexDigit(char)
		}
	}
	if ok && base64Value && len(encoded) == maximum {
		decoded, decodedOK := profileBase64Decode(encoded, false)
		ok = decodedOK && len(decoded) == 32
	}
	if ok {
		return ""
	}
	if base64Value {
		return "must be a base64 SHA-256 pin of 32 bytes"
	}
	return fmt.Sprintf("must be 4 to %d hex digits", maximum)
}

// profileOpenConnectCertificatePairMessage is
// OpenConnectChecks.openConnectCertificatePair.
func profileOpenConnectCertificatePairMessage(certificate []string, certificatePath string, key []string, keyPath string) string {
	hasCertificate := len(certificate) > 0 || profileVpnTrimmed(certificatePath) != ""
	hasKey := len(key) > 0 || profileVpnTrimmed(keyPath) != ""
	if hasCertificate == hasKey {
		return ""
	}
	if hasCertificate {
		return "a certificate requires its key"
	}
	return "a key requires its certificate"
}

// profileOpenConnectFormEntryMessage is
// OpenConnectChecks.openConnectFormEntry.
func profileOpenConnectFormEntryMessage(formID, submissionKey, name, value string, promote bool) string {
	if submissionKey == "" && (formID == "" || name == "") {
		return "a form entry needs a submission_key or both form_id and name"
	}
	if promote && value != "" {
		return "a promoted form entry needs an empty value"
	}
	return ""
}

// profileOpenConnectTokenMessage is OpenConnectChecks.openConnectToken.
func profileOpenConnectTokenMessage(model *profileOpenConnect) string {
	token := model.Token
	if token.Mode == "" {
		return ""
	}
	if !profileNewOneOf(token.Mode, profileOpenConnectTokenModes, false) {
		return "the token mode must be totp, hotp, stoken or oidc"
	}
	if token.Secret != "" && token.SecretPath != "" {
		return "the token secret and secret_path are both set"
	}
	if token.Secret == "" && token.SecretPath == "" {
		return "the token requires a secret"
	}
	return ""
}

// profileOpenConnectTokenUnusedMessage is
// OpenConnectChecks.openConnectTokenUnused.
func profileOpenConnectTokenUnusedMessage(model *profileOpenConnect) string {
	token := model.Token
	if token.Mode != "" {
		return ""
	}
	used := token.Secret != "" || token.SecretPath != "" || token.Pin != "" ||
		token.Password != "" || token.DeviceID != "" || token.Counter > 0
	if !used {
		return ""
	}
	return "the token fields are dropped while the token has no mode"
}

// profileOpenConnectTokenCounterMessage is
// OpenConnectChecks.openConnectTokenCounter: only hotp tokens count.
func profileOpenConnectTokenCounterMessage(model *profileOpenConnect) string {
	token := model.Token
	if token.Counter <= 0 || token.Mode == "" || token.Mode == "hotp" {
		return ""
	}
	return "the counter is only used by hotp tokens"
}

// profileOpenConnectMobileMessage is OpenConnectChecks.openConnectMobile:
// build() emits all three as soon as one is set, and the core refuses an empty
// one.
func profileOpenConnectMobileMessage(model *profileOpenConnect) string {
	mobile := model.Mobile
	set := 0
	for _, value := range []string{mobile.PlatformVersion, mobile.DeviceType, mobile.DeviceUniqueID} {
		if value != "" {
			set++
		}
	}
	if set == 0 || set == 3 {
		return ""
	}
	return "platform_version, device_type and device_unique_id must be set together"
}

// profileOpenConnectCompressionMessage is
// OpenConnectChecks.openConnectCompression.
func profileOpenConnectCompressionMessage(model *profileOpenConnect) string {
	if !model.CompressionDisabled || model.CompressionMode != "all" {
		return ""
	}
	return "compression_mode cannot be \"all\" while compression is disabled"
}

// profileVpnServerNameMessage is CommonChecks.serverName: an SNI is a domain
// name or IP address, without a scheme or port.
func profileVpnServerNameMessage(text string) string {
	// Validation.host runs with Empty.Allowed here, so an empty name is fine.
	if profileVpnTrimmed(text) == "" || profileVpnHostOK(text) {
		return ""
	}
	if profileVpnHostPortOK(text, true) {
		return "must not contain a port"
	}
	return "is not a valid server name"
}

// profileVpnHostPortOK is Validation.hostPort.
func profileVpnHostPortOK(text string, portRequired bool) bool {
	trimmed := profileVpnTrimmed(text)
	if trimmed == "" {
		return !portRequired
	}
	if strings.Contains(trimmed, "://") {
		return false
	}
	port := ""
	hasPort := false
	if strings.HasPrefix(trimmed, "[") {
		close := strings.Index(trimmed, "]")
		if close < 0 {
			return false
		}
		kind, zoned, ok := profileVpnIPKind(trimmed[1:close])
		if !ok || zoned || kind != 6 {
			return false
		}
		rest := trimmed[close+1:]
		if rest != "" {
			if !strings.HasPrefix(rest, ":") {
				return false
			}
			port = rest[1:]
			hasPort = true
		}
	} else {
		if _, _, ok := profileVpnIPKind(trimmed); ok {
			if address, err := netip.ParseAddr(trimmed); err == nil && address.Is6() {
				return false
			}
		}
		host := trimmed
		if colon := strings.LastIndex(trimmed, ":"); colon >= 0 {
			host = trimmed[:colon]
			port = trimmed[colon+1:]
			hasPort = true
			if strings.Contains(host, ":") {
				return false
			}
		}
		if host == "" {
			return false
		}
		if !profileVpnHostOK(host) {
			return false
		}
	}
	if !hasPort {
		return !portRequired
	}
	value, ok := profileVpnParseLong(port)
	return ok && value >= 1 && value <= 65535
}
