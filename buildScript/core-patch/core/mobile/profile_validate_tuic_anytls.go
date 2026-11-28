// Stored validation for the two QUIC-family types ported in
// profile_import_tuic_anytls.go. The fixed issue order matches the simple
// codec (dial fields, then endpoint, then type-specific fields) so a UI can
// pin it; unknown fields or shapes answer supported:false and the editor refuses them, exactly like
// the four simple types.
package mobile

import (
	"fmt"
	"net/netip"
	"strings"
	"time"
)

// handleProfileValidateTuicAnyTLS validates one tuic/anytls stored document.
// It returns (result, handled): handled=false means the document is not one of
// the two types and the caller continues down the simple path.
func handleProfileValidateTuicAnyTLS(object map[string]any, rawType string) (profileValidateResult, bool) {
	if !profileStoredTuicAnyTLSTypes[rawType] {
		return profileValidateResult{}, false
	}
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	issues := storedIssues{}

	node, unknown, err := profileParseStoredTuicAnyTLS(object, rawType)
	if err != nil {
		// A malformed document of a supported type: server/host problems are
		// real validation findings, not action failures.
		issues.addError("", err.Error())
		return finishStoredValidation(result, issues, ""), true
	}
	if len(unknown) > 0 {
		result.Supported = boolPointer(false)
		issues.addError("", fmt.Sprintf(
			"the stored %q document carries a field this validation does not model",
			rawType))
		return finishStoredValidation(result, issues, ""), true
	}

	// Dial fields (same order as the simple codec).
	validateAdvancedDialFields(&issues, object)
	// Endpoint.
	server := configJSONString(object, "server")
	port := configJSONInt(object["server_port"])
	if server == "" {
		issues.addError("server", "server is required")
	}
	if port < 1 || port > 65535 {
		issues.addError("server_port", "server_port must be between 1 and 65535")
	}

	// Type-specific fields, in Kotlin's validate() order.
	switch rawType {
	case "tuic":
		uuid := configJSONString(object, "uuid")
		if strings.TrimSpace(uuid) == "" {
			issues.addError("uuid", "uuid is required")
		} else if !profileValidUUID(uuid) {
			issues.addError("uuid", "uuid is not a valid UUID")
		}
		if heartbeat := configJSONString(object, "heartbeat"); heartbeat != "" {
			if _, err := time.ParseDuration(heartbeat); err != nil || strings.HasPrefix(heartbeat, "-") {
				issues.addError("heartbeat", "heartbeat must be a non-negative duration such as 5s")
			}
		}
		if congestion := configJSONString(object, "congestion_control"); congestion != "" {
			switch congestion {
			case "cubic", "new_reno", "bbr":
			default:
				issues.addError("congestion_control", "congestion_control must be cubic, new_reno or bbr")
			}
		}
	case "anytls":
		if configJSONString(object, "password") == "" {
			issues.addError("password", "password is required")
		}
		for _, field := range []string{"idle_session_check_interval", "idle_session_timeout"} {
			value, present := object[field]
			if !present {
				continue // Kotlin uses the 30s default when the key is absent.
			}
			if text, ok := value.(string); !ok || text == "" || configValidDuration(text) == "" {
				issues.addError(field, field+" must be a duration such as 30s")
			}
		}
		if value, present := object["min_idle_session"]; present && configJSONInt(value) < 0 {
			issues.addError("min_idle_session", "min_idle_session must not be negative")
		}
	}

	normalized, err := profileAdvancedNode(node)
	if err != nil {
		return profileValidateResult{}, true
	}
	result.Normalized = normalized.JSON
	return finishStoredValidation(result, issues, normalized.JSON), true
}

// validateAdvancedDialFields checks the same three fields as
// storedIssues.validateDialFields, over a raw object (the advanced parser does
// not build a profileStoredSimple).
func validateAdvancedDialFields(issues *storedIssues, object map[string]any) {
	if text := configJSONString(object, "connect_timeout"); text != "" {
		if _, err := time.ParseDuration(text); err != nil {
			issues.addError("connect_timeout", "connect_timeout must be a duration such as 5s or 1m30s")
		} else if strings.HasPrefix(text, "-") {
			issues.addError("connect_timeout", "connect_timeout must not be negative")
		}
	}
	if text := configJSONString(object, "inet4_bind_address"); text != "" {
		address, err := netip.ParseAddr(text)
		if err != nil || !address.Is4() {
			issues.addError("inet4_bind_address", "inet4_bind_address must be an IPv4 address")
		}
	}
	if text := configJSONString(object, "inet6_bind_address"); text != "" {
		address, err := netip.ParseAddr(text)
		if err != nil || !address.Is6() {
			issues.addError("inet6_bind_address", "inet6_bind_address must be an IPv6 address")
		}
	}
}

// profileValidUUID mirrors Validation.uuid: canonical 8-4-4-4-12 hex, with
// braced / urn:uuid: forms tolerated by the Kotlin parser.
func profileValidUUID(text string) bool {
	value := strings.TrimSpace(text)
	if strings.HasPrefix(strings.ToLower(value), "urn:uuid:") {
		value = value[len("urn:uuid:"):]
	}
	if len(value) == 38 && value[0] == '{' && value[len(value)-1] == '}' {
		value = value[1 : len(value)-1]
	}
	if len(value) != 36 {
		return false
	}
	for index := 0; index < len(value); index++ {
		char := value[index]
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if char != '-' {
				return false
			}
			continue
		}
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return false
		}
	}
	return true
}
