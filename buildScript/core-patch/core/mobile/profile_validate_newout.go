// Stored validation for mieru, snell and shadowtls, the three types the
// profile_import_newout.go slice added to profileImport/profileExport.
//
// The checks mirror each type's Validate() with the shared Outbound.validate
// endpoint rules, in the same fixed order the existing stored validators use
// (dial fields, endpoint, type-specific fields). A document carrying a field
// this slice does not model answers supported:false and falls back to the
// Kotlin validator instead of presenting a half-informed verdict.
//
// Two deliberate omissions, both warning-only on the Kotlin side: the TLS
// server_name warning (CommonChecks.serverName) and the certificate/ECH PEM
// warnings. Those fields are outside profileNewTLSTargetKeys, so a document
// carrying them answers supported:false before any verdict is produced.
package mobile

import (
	"errors"
	"fmt"
	"strings"
)

// profileTLSVersionValues is TlsChecks.tlsVersion.
var profileTLSVersionValues = []string{"1.0", "1.1", "1.2", "1.3"}

// handleProfileValidateNewOutbound validates one mieru/snell/shadowtls stored
// document. It returns (result, handled): handled=false means the document is
// not one of the three types and the caller continues down the simple path.
func handleProfileValidateNewOutbound(object map[string]any, rawType string) (profileValidateResult, bool) {
	if !profileNewoutMieruTypes[rawType] {
		return profileValidateResult{}, false
	}
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	issues := storedIssues{}
	parsed, err := profileNewFromObject(object, rawType, profileNewValidateMode)
	if err != nil {
		var unmodelled profileNewUnmodelled
		if errors.As(err, &unmodelled) {
			// A field or shape this slice does not model: the Kotlin validator
			// owns the verdict.
			result.Supported = boolPointer(false)
			issues.addError("", fmt.Sprintf(
				"the stored %q document carries a value this validation does not model (%s)",
				rawType, unmodelled.Reason))
			return finishStoredValidation(result, issues, ""), true
		}
		// A value problem of a document this slice does understand is a real
		// finding, not an unsupported document.
		issues.addError("", err.Error())
		return finishStoredValidation(result, issues, ""), true
	}
	if len(parsed.Unknown) > 0 {
		result.Supported = boolPointer(false)
		issues.addError("", fmt.Sprintf(
			"the stored %q document carries a field this validation does not model",
			rawType))
		return finishStoredValidation(result, issues, ""), true
	}
	node := parsed.Node

	// Dial fields (same order as the other stored validators).
	validateAdvancedDialFields(&issues, object)
	// Endpoint.
	server := configJSONString(object, "server")
	if server == "" {
		issues.addError("server", "server is required")
	} else if !profileHostValidForStored(server) {
		issues.addError("server", "server is not a valid host")
	}
	serverPortsOptional := rawType == "mieru" && len(profileNewAnyToStrings(node.Fields["server_ports"])) > 0
	if node.Port == 0 {
		if !serverPortsOptional {
			issues.addError("server_port", "server_port is required")
		}
	} else if node.Port < 1 || node.Port > 65535 {
		issues.addError("server_port", "server_port must be between 1 and 65535")
	}

	switch rawType {
	case "mieru":
		profileValidateMieru(&issues, object, node)
	case "snell":
		profileValidateSnell(&issues, object, node)
	case "shadowtls":
		profileValidateShadowTLS(&issues, object, node, parsed)
	}

	normalized, err := node.json()
	if err != nil {
		return profileValidateResult{}, true
	}
	result.Normalized = normalized
	return finishStoredValidation(result, issues, normalized), true
}

// profileValidateMieru is Mieru.validate.
func profileValidateMieru(issues *storedIssues, object map[string]any, node *profileStoredAdvanced) {
	if strings.TrimSpace(configJSONString(object, "username")) == "" {
		issues.addError("username", "username is required")
	}
	if strings.TrimSpace(configJSONString(object, "password")) == "" {
		issues.addError("password", "password is required")
	}
	if transport := strings.TrimSpace(configJSONString(object, "transport")); transport != "" && !profileMieruTransportKnown(transport) {
		issues.addError("transport", "transport must be TCP or UDP")
	}
	if multiplexing := strings.TrimSpace(configJSONString(object, "multiplexing")); multiplexing != "" && !profileMieruMultiplexingKnown(multiplexing) {
		issues.addError("multiplexing", "multiplexing must be one of MULTIPLEXING_OFF, MULTIPLEXING_LOW, MULTIPLEXING_MIDDLE, MULTIPLEXING_HIGH or MULTIPLEXING_DEFAULT")
	}
	if value, present := object["server_ports"]; present {
		ports, err := profileMieruServerPorts(value, "mieru")
		if err != nil {
			issues.addError("server_ports", "server_ports must be a string or a list of strings")
		} else {
			for _, port := range ports {
				if !profileMieruPortRangeValid(port) {
					issues.addError("server_ports", fmt.Sprintf(
						"server_ports item %q must be a range such as 9000-9010 with both ends in 1..65535 and begin <= end", port))
					break
				}
			}
		}
	}
	if pattern := configJSONString(object, "traffic_pattern"); pattern != "" {
		if !profileMieruTrafficPatternValid(strings.TrimSpace(pattern)) {
			issues.addError("traffic_pattern", "traffic_pattern must be padded standard base64")
		}
	}
	_ = node
}

// profileValidateSnell is Snell.validate. The version's own check comes from
// supportedVersion: parseFromJson refuses a stored row outside v4/v6, so the
// validator reports it instead of importing it.
func profileValidateSnell(issues *storedIssues, object map[string]any, node *profileStoredAdvanced) {
	version := profileJSONInt(node.Fields, "version")
	if !profileSnellVersionSupported(version) {
		issues.addError("version", "version must be 4 or 6")
	}
	if strings.TrimSpace(configJSONString(object, "psk")) == "" {
		issues.addError("psk", "psk is required")
	}
	if userkey := configJSONString(object, "userkey"); len([]byte(userkey)) > 255 {
		issues.addError("userkey", fmt.Sprintf("userkey must be at most 255 UTF-8 bytes (got %d)", len([]byte(userkey))))
	}
	if network := strings.TrimSpace(configJSONString(object, "network")); !profileNewOneOf(network, profileSnellNetworks, false) {
		issues.addError("network", "network must be tcp or udp")
	}
	if version == 6 {
		mode := strings.TrimSpace(configJSONString(object, "mode"))
		if !profileNewOneOf(mode, profileSnellV6Modes, false) {
			issues.addError("mode", "mode must be default, unshaped or unsafe-raw")
		}
		obfsMode := strings.TrimSpace(configJSONString(object, "obfs_mode"))
		if (obfsMode != "" && !strings.EqualFold(obfsMode, "none")) || configJSONString(object, "obfs_host") != "" {
			issues.addWarning("obfs_mode", "obfs options are ignored in Snell v6")
		}
	} else if profileSnellVersionSupported(version) {
		obfsMode := strings.TrimSpace(configJSONString(object, "obfs_mode"))
		if !profileNewOneOf(obfsMode, profileSnellObfsModes, true) {
			issues.addError("obfs_mode", "obfs_mode must be none, http or tls")
		} else {
			obfs := strings.ToLower(obfsMode)
			if strings.TrimSpace(configJSONString(object, "obfs_host")) != "" && obfs != "http" && obfs != "tls" {
				issues.addWarning("obfs_host", "obfs_host is ignored without the http or tls obfs mode")
			}
		}
		if configJSONString(object, "mode") != "" {
			issues.addWarning("mode", "mode is ignored in Snell v4")
		}
	}
}

// profileValidateShadowTLS is ShadowTls.validate plus the must-tls TLS checks.
func profileValidateShadowTLS(issues *storedIssues, object map[string]any, node *profileStoredAdvanced, parsed *profileNewParsed) {
	profileValidateShadowTLSTLS(issues, parsed.TLS)
	version := profileJSONInt(node.Fields, "version")
	if version < 0 || version > 3 {
		issues.addError("version", "version must be between 0 and 3")
		return
	}
	if version >= 2 && configJSONString(object, "password") == "" {
		issues.addError("password", "password is required for ShadowTLS v2 and v3")
	}
}

// profileValidateShadowTLSTLS is the Tls.validate subset this slice models:
// version values/order, the uTLS fingerprint and the REALITY block. The
// server_name, certificate and ECH checks are not modelled (see the file
// header); their fields make the document answer supported:false first.
func profileValidateShadowTLSTLS(issues *storedIssues, tls map[string]any) {
	if tls == nil {
		return
	}
	minVersion := strings.TrimSpace(configJSONString(tls, "min_version"))
	maxVersion := strings.TrimSpace(configJSONString(tls, "max_version"))
	validMin, validMax := true, true
	if minVersion != "" && !profileNewOneOf(minVersion, profileTLSVersionValues, false) {
		issues.addError("tls.min_version", "tls.min_version must be 1.0, 1.1, 1.2 or 1.3")
		validMin = false
	}
	if maxVersion != "" && !profileNewOneOf(maxVersion, profileTLSVersionValues, false) {
		issues.addError("tls.max_version", "tls.max_version must be 1.0, 1.1, 1.2 or 1.3")
		validMax = false
	}
	if validMin && validMax && minVersion != "" && maxVersion != "" && minVersion > maxVersion {
		issues.addError("tls.max_version", "tls.min_version must not be greater than tls.max_version")
	}
	if utls, ok := tls["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" && !validFingerprint(fingerprint) {
			issues.addError("tls.utls.fingerprint", fmt.Sprintf("unknown uTLS fingerprint %q", fingerprint))
		}
	}
	reality, ok := tls["reality"].(map[string]any)
	if !ok {
		return
	}
	enabled := configJSONBool(reality, "enabled")
	publicKey := strings.TrimSpace(configJSONString(reality, "public_key"))
	if !enabled && publicKey == "" {
		return
	}
	if publicKey == "" {
		issues.addError("tls.reality.public_key", "tls.reality.public_key is required")
	} else if !profileNewRealityKeyValid(publicKey) {
		issues.addError("tls.reality.public_key", "tls.reality.public_key must be an unpadded base64url value of 32 bytes")
	}
	if shortID := configJSONString(reality, "short_id"); shortID != "" && !profileNewRealityShortIDValid(shortID) {
		issues.addError("tls.reality.short_id", "tls.reality.short_id must be at most 16 hex characters (even length)")
	}
	if verify := configJSONString(reality, "mldsa65_verify"); verify != "" && !profileValidMLDSA(verify) {
		issues.addError("tls.reality.mldsa65_verify", "tls.reality.mldsa65_verify must be an unpadded base64url value of 1952 bytes")
	}
	// TlsChecks.realityConflict without the ECH leg (ECH is outside the
	// modelled field set, so it can never be present here).
	if configJSONBool(tls, "disable_sni") && !configJSONBool(tls, "insecure") {
		issues.addError("tls.reality", "REALITY with disable_sni requires insecure")
	}
}

// profileNewRealityKeyValid is TlsChecks.realityPublicKey(required=true):
// unpadded base64url of exactly 32 bytes.
func profileNewRealityKeyValid(key string) bool {
	trimmed := strings.TrimSpace(key)
	if trimmed == "" || strings.Contains(trimmed, "=") {
		return false
	}
	decoded, ok := profileBase64Decode(trimmed, true)
	return ok && len(decoded) == 32
}

// profileNewRealityShortIDValid is TlsChecks.realityShortId: optional hex,
// even length, at most 16 characters.
func profileNewRealityShortIDValid(text string) bool {
	trimmed := strings.TrimSpace(text)
	if len(trimmed)%2 != 0 || len(trimmed) > 16 {
		return false
	}
	for index := 0; index < len(trimmed); index++ {
		char := trimmed[index]
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return false
		}
	}
	return true
}
