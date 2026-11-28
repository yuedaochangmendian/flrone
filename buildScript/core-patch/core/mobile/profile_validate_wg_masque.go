// Stored validation for WireGuard and MASQUE, the two endpoint types the
// profile_import_wg_masque.go slice added to profileImport/profileExport.
//
// The checks mirror WireGuard.validate / Masque.validate with the shared
// Outbound.validate endpoint rules, in the fixed order the other stored
// validators use (dial fields, endpoint, type-specific fields). A document
// carrying a field this slice does not model answers supported:false and falls
// back to the Kotlin validator instead of presenting a half-informed verdict.
//
// Modelled TLS subset (the same one profile_import_newout.go owns): enabled,
// disable_sni, server_name, insecure, alpn, min/max_version, utls and REALITY.
// A stored masque document carrying certificate/ECH/spoof/cipher fields is not
// modelled, so it answers supported:false before any verdict is produced.
package mobile

import (
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"unicode"
)

// handleProfileValidateWg validates one wireguard/masque stored document.
// handled=false means the document is another type.
func handleProfileValidateWg(object map[string]any, rawType string) (profileValidateResult, bool) {
	if !profileWgTypes[rawType] {
		return profileValidateResult{}, false
	}
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	issues := storedIssues{}
	var (
		node    any
		unknown []string
		err     error
	)
	if rawType == "wireguard" {
		parsed, parseErr := profileWgFromObject(object, profileNewValidateMode)
		if parseErr == nil {
			node, unknown = parsed.Node, parsed.Unknown
		}
		err = parseErr
	} else {
		parsed, parseErr := profileMasqueFromObject(object, profileNewValidateMode)
		if parseErr == nil {
			node, unknown = parsed.Node, parsed.Unknown
		}
		err = parseErr
	}
	if err != nil {
		if refused, ok := profileWgRefusal(err); ok {
			result.Supported = boolPointer(false)
			issues.addError("", fmt.Sprintf(
				"the stored %q document carries a value this validation does not model (%s); fall back to the Kotlin validator",
				rawType, refused.Reason))
			return finishStoredValidation(result, issues, ""), true
		}
		issues.addError("", err.Error())
		return finishStoredValidation(result, issues, ""), true
	}
	if len(unknown) > 0 {
		result.Supported = boolPointer(false)
		issues.addError("", fmt.Sprintf(
			"the stored %q document carries a field this validation does not model; fall back to the Kotlin validator",
			rawType))
		return finishStoredValidation(result, issues, ""), true
	}

	// Dial fields (same order as the other stored validators).
	validateAdvancedDialFields(&issues, object)
	if rawType == "wireguard" {
		profileValidateWireGuard(&issues, node.(*profileWgStored))
	} else {
		profileValidateMasque(&issues, node.(*profileMasqueStored))
	}

	var normalized string
	if rawType == "wireguard" {
		encoded, encodeErr := MarshalCanonicalJSON(profileWgObject(node.(*profileWgStored)))
		if encodeErr != nil {
			return profileValidateResult{}, true
		}
		normalized = string(encoded)
	} else {
		encoded, encodeErr := MarshalCanonicalJSON(profileMasqueObject(node.(*profileMasqueStored)))
		if encodeErr != nil {
			return profileValidateResult{}, true
		}
		normalized = string(encoded)
	}
	result.Normalized = normalized
	return finishStoredValidation(result, issues, normalized), true
}

// profileValidateWireGuard is WireGuard.validate.
func profileValidateWireGuard(issues *storedIssues, node *profileWgStored) {
	// Outbound.validate: the endpoint is the peer, because WireGuard overrides
	// getAddress/getPort.
	server := strings.TrimSpace(node.Peer.Address)
	if server == "" {
		issues.addError("server", "server is required")
	} else if !profileWgHostValid(server) {
		issues.addError("server", "server is not a valid host")
	}
	if node.Peer.Port == 0 {
		issues.addError("server_port", "server_port is required")
	} else if node.Peer.Port < 1 || node.Peer.Port > 65535 {
		issues.addError("server_port", "server_port must be between 1 and 65535")
	}

	if !profileWgBase64KeyValidRequired(node.PrivateKey, 32, false) {
		issues.addError("private_key", "private_key must be 32 bytes in standard base64 (44 characters)")
	}
	if !profileWgBase64KeyValidRequired(node.Peer.PublicKey, 32, false) {
		issues.addError("public_key", "public_key must be 32 bytes in standard base64 (44 characters)")
	}
	if !profileWgBase64KeyValidRequired(node.Peer.PreSharedKey, 32, true) {
		issues.addError("pre_shared_key", "pre_shared_key must be 32 bytes in standard base64 (44 characters) or empty")
	}
	if len(node.Peer.Reserved) > 0 {
		if _, ok := profileWgReserved(joinInts(node.Peer.Reserved, ",")); !ok {
			issues.addError("reserved", "reserved must be three bytes between 0 and 255")
		}
	}
	if !profileWgKeepaliveValid(node.Peer.Keepalive) {
		issues.addError("persistent_keepalive_interval", "persistent_keepalive_interval must be a number of seconds or a range such as 22-30")
	}
	if len(node.Address) == 0 {
		issues.addError("address", "address is required")
	} else {
		for _, address := range node.Address {
			if !profileWgCIDRValid(address) {
				issues.addError("address", "address must be a list of CIDR prefixes")
				break
			}
		}
	}
	if node.UDPTimeout != "" && !profileImportValidDuration(node.UDPTimeout) {
		issues.addError("udp_timeout", "udp_timeout must be a duration such as 5s or 1m30s")
	}
	if node.Amnezia.enabled {
		profileValidateAmnezia(issues, node.Amnezia)
	}
}

// profileValidateAmnezia is WireGuard.amneziaIssues.
func profileValidateAmnezia(issues *storedIssues, amnezia profileWgAmnezia) {
	for _, field := range []struct {
		key   string
		value int
	}{
		{"s1", amnezia.s1}, {"s2", amnezia.s2}, {"s3", amnezia.s3}, {"s4", amnezia.s4},
	} {
		// Only a positive value above the limit is emitted.
		if field.value > 65535 {
			issues.addError(field.key, field.key+" must be an integer between 0 and 65535")
		}
	}
	headers := [4]string{amnezia.h1, amnezia.h2, amnezia.h3, amnezia.h4}
	for index, header := range headers {
		if !profileWgAmneziaRangeValid(header) {
			issues.addError("h"+strconv.Itoa(index+1), "h"+strconv.Itoa(index+1)+" must be a number or a range such as 100-200")
		}
	}
	if profileWgHeadersOverlap(headers) {
		issues.addError("h1", "the H1-H4 ranges must not overlap")
	}
	for index, signature := range []string{amnezia.i1, amnezia.i2, amnezia.i3, amnezia.i4, amnezia.i5} {
		if !profileWgSignatureValid(signature) {
			issues.addError("i"+strconv.Itoa(index+1), "i"+strconv.Itoa(index+1)+" is not a valid AmneziaWG signature")
		}
	}
	if !profileWgBase64KeyValidRequired(amnezia.headerProtectionKey, 32, true) {
		issues.addError("header_protection_key", "header_protection_key must be 32 bytes in standard base64 (44 characters) or empty")
	}
	if strings.TrimSpace(amnezia.headerProtectionKey) != "" {
		for index, padding := range []int{amnezia.s1, amnezia.s2, amnezia.s3, amnezia.s4} {
			if padding < 12 {
				issues.addError("header_protection_key", fmt.Sprintf(
					"S%d must be at least 12 when header_protection_key is set (got %d)", index+1, padding))
				break
			}
		}
	}
	for _, field := range []struct {
		key   string
		value string
	}{
		{"content_padding_addition", amnezia.contentPaddingAddition},
		{"rekey_after_time", amnezia.rekeyAfterTime},
		{"rekey_timeout", amnezia.rekeyTimeout},
		{"reject_after_time", amnezia.rejectAfterTime},
		{"keepalive_timeout", amnezia.keepaliveTimeout},
		{"max_handshake_attempts", amnezia.maxHandshakeAttempts},
	} {
		if !profileWgAmneziaRangeValid(field.value) {
			issues.addError(field.key, field.key+" must be a number or a range such as 100-200")
		}
	}
	if amnezia.jmin > amnezia.jmax {
		issues.addWarning("jmin", "jmin must not be greater than jmax")
	}
}

// profileWgAmneziaRangeValid is WireGuardChecks.amneziaRange
// (Validation.intOrRange 0..UINT32_MAX, empty allowed).
func profileWgAmneziaRangeValid(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	dash := strings.IndexByte(trimmed, '-')
	low, high := trimmed, trimmed
	if dash >= 0 {
		low, high = trimmed[:dash], trimmed[dash+1:]
	}
	values := [2]int64{}
	for index, part := range []string{low, high} {
		if part == "" || strings.HasPrefix(part, "-") {
			return false
		}
		body := part
		if strings.HasPrefix(body, "+") {
			body = body[1:]
		}
		if body == "" {
			return false
		}
		for char := 0; char < len(body); char++ {
			if body[char] < '0' || body[char] > '9' {
				return false
			}
		}
		value, err := strconv.ParseInt(part, 10, 64)
		if err != nil || value < 0 || value > 4294967295 {
			return false
		}
		values[index] = value
	}
	return values[0] <= values[1]
}

// profileWgHeadersOverlap is WireGuardChecks.amneziaHeaders' overlap leg. A
// header the range rule rejects makes the Kotlin check silent, so this returns
// false for it too.
func profileWgHeadersOverlap(headers [4]string) bool {
	ranges := [4][2]int64{}
	for index, header := range headers {
		text := strings.TrimSpace(header)
		if text == "" {
			ranges[index] = [2]int64{int64(index + 1), int64(index + 1)}
			continue
		}
		if !profileWgAmneziaRangeValid(text) {
			return false
		}
		dash := strings.IndexByte(text, '-')
		low, high := text, text
		if dash >= 0 {
			low, high = text[:dash], text[dash+1:]
		}
		lowValue, _ := strconv.ParseInt(low, 10, 64)
		highValue := lowValue
		if dash >= 0 {
			highValue, _ = strconv.ParseInt(high, 10, 64)
		}
		ranges[index] = [2]int64{lowValue, highValue}
	}
	for i := 0; i < len(ranges); i++ {
		for j := i + 1; j < len(ranges); j++ {
			if ranges[i][0] <= ranges[j][1] && ranges[j][0] <= ranges[i][1] {
				return true
			}
		}
	}
	return false
}

// profileWgSignatureValid is WireGuardChecks.amneziaSignature (wireguard-go
// newObfChain): <b 0xHEX>, <r N>, <rc N>, <rd N>, <dz N>, <t>, <d>, <ds>.
func profileWgSignatureValid(spec string) bool {
	for start := strings.IndexByte(spec, '<'); start >= 0; {
		end := strings.IndexByte(spec[start:], '>')
		if end < 0 {
			return false
		}
		end += start
		parts := profileWgWords(spec[start+1 : end])
		start = strings.IndexByte(spec[end+1:], '<')
		if start >= 0 {
			start += end + 1
		}
		if len(parts) == 0 {
			return false
		}
		tag := parts[0]
		argument := ""
		if len(parts) > 1 {
			argument = parts[1]
		}
		switch tag {
		case "b":
			hex := strings.TrimPrefix(argument, "0x")
			if hex == "" || !profileWgHexValid(hex) {
				return false
			}
		case "r", "rc", "rd", "dz":
			text := strings.TrimPrefix(argument, "+")
			length, ok := profileNewParseLong(text)
			if !ok || length < 0 {
				return false
			}
		case "t", "d", "ds":
		default:
			return false
		}
	}
	return true
}

// profileWgWords is QString::simplified().split(' ', SkipEmptyParts).
func profileWgWords(text string) []string {
	fields := make([]string, 0, 2)
	current := strings.Builder{}
	for _, char := range text {
		if !unicode.IsSpace(char) {
			current.WriteRune(char)
			continue
		}
		if current.Len() > 0 {
			fields = append(fields, current.String())
			current.Reset()
		}
	}
	if current.Len() > 0 {
		fields = append(fields, current.String())
	}
	return fields
}

// profileWgHexValid is Validation.hex(text, 0, 0) with the even-length rule.
func profileWgHexValid(text string) bool {
	if len(text)%2 != 0 {
		return false
	}
	for index := 0; index < len(text); index++ {
		char := text[index]
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return false
		}
	}
	return true
}

// profileWgBase64KeyValidRequired is Validation.base64Key; emptyAllowed mirrors
// Empty.Allowed.
func profileWgBase64KeyValidRequired(text string, bytes int, emptyAllowed bool) bool {
	if strings.TrimSpace(text) == "" {
		return emptyAllowed
	}
	return profileWgBase64KeyValid(text, bytes)
}

// profileValidateMasque is Masque.validate.
func profileValidateMasque(issues *storedIssues, node *profileMasqueStored) {
	server := strings.TrimSpace(node.Server)
	if server == "" {
		issues.addError("server", "server is required")
	} else if !profileWgHostValid(server) {
		issues.addError("server", "server is not a valid host")
	}
	// Masque.serverPortOptional: 0 means the core dials 443.
	if node.ServerPort != 0 && (node.ServerPort < 1 || node.ServerPort > 65535) {
		issues.addError("server_port", "server_port must be between 1 and 65535")
	}

	if !profileMasqueKeyValid(node.PrivateKey, false) {
		issues.addError("private_key", "private_key must be standard base64 DER")
	}
	if !profileMasqueKeyValid(node.PeerPublicKey, true) {
		issues.addError("peer_public_key", "peer_public_key must be standard base64 DER or empty")
	}
	if len(node.Address) == 0 {
		issues.addError("address", "address is required")
	} else {
		for _, address := range node.Address {
			if !profileWgCIDRValid(address) {
				issues.addError("address", "address must be a list of CIDR prefixes")
				break
			}
		}
	}
	if !profileNewOneOf(strconv.Itoa(node.HTTPVersion), profileMasqueHTTPVersions, false) {
		issues.addError("http_version", "http_version must be 0, 2 or 3")
	}
	profileValidateMasqueQUIC(issues, node.QUIC)
	profileValidateMasqueTLS(issues, node.TLS)
}

// profileMasqueKeyValid is MasqueChecks.masqueKey: trimmed, non-empty (unless
// allowed), a multiple of four characters and standard base64.
func profileMasqueKeyValid(text string, emptyAllowed bool) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return emptyAllowed
	}
	if len(trimmed)%4 != 0 {
		return false
	}
	return profileMieruBase64Valid(trimmed)
}

// profileValidateMasqueQUIC is QuicFields.validate.
func profileValidateMasqueQUIC(issues *storedIssues, quic profileMasqueQUIC) {
	for _, field := range []struct {
		key   string
		value string
	}{
		{"idle_timeout", quic.IdleTimeout},
		{"keep_alive_period", quic.KeepAlivePeriod},
	} {
		if field.value != "" && !profileImportValidDuration(field.value) {
			issues.addError(field.key, field.key+" must be a duration such as 5s or 1m30s")
		}
	}
	for _, field := range []struct {
		key   string
		value string
	}{
		{"stream_receive_window", quic.StreamReceiveWindow},
		{"connection_receive_window", quic.ConnectionReceiveWindow},
	} {
		if field.value != "" && !profileValidMemoryBytes(field.value) {
			issues.addError(field.key, field.key+" must be a byte size such as 1m or a plain integer")
		}
	}
	if !profileMasqueInitialPacketSizeValid(strconv.Itoa(quic.InitialPacketSize)) {
		issues.addError("initial_packet_size", "initial_packet_size must be 0 or between 1200 and 1452")
	}
}

// profileValidateMasqueTLS is the Tls.validate subset this slice models.
func profileValidateMasqueTLS(issues *storedIssues, tls map[string]any) {
	if tls == nil {
		return
	}
	serverName := configJSONString(tls, "server_name")
	if strings.TrimSpace(serverName) != "" && !profileWgHostValid(serverName) {
		issues.addWarning("tls.server_name", "tls.server_name must be a host name without a port")
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
	// TlsChecks.realityConflict without the ECH leg (ECH is outside the modelled
	// field set, so it can never be present here).
	if configJSONBool(tls, "disable_sni") && !configJSONBool(tls, "insecure") {
		issues.addError("tls.reality", "REALITY with disable_sni requires insecure")
	}
}

// profileWgHostValid is Validation.host's accepted forms: an IP literal (IPv6
// bracketed or bare), or a DNS name; no scheme, path, port or whitespace.
func profileWgHostValid(text string) bool {
	t := strings.TrimSpace(text)
	if t == "" {
		return true
	}
	if strings.Contains(t, "://") {
		return false
	}
	for _, char := range t {
		if unicode.IsSpace(char) {
			return false
		}
	}
	if strings.ContainsAny(t, "/?#@") {
		return false
	}
	if strings.HasPrefix(t, "[") {
		closeIndex := strings.IndexByte(t, ']')
		if closeIndex < 0 {
			return false
		}
		address, err := netip.ParseAddr(t[1:closeIndex])
		if err != nil || !address.Is6() {
			return false
		}
		return t[closeIndex+1:] == ""
	}
	if address, err := netip.ParseAddr(t); err == nil {
		return address.Zone() == ""
	}
	if strings.Contains(t, ":") {
		return false
	}
	if strings.Trim(t, "0123456789.") == "" {
		return false
	}
	name := t
	if !configIsASCII(name) {
		converted, ok := configToACE(name)
		if !ok {
			return false
		}
		name = converted
	} else {
		name = strings.ToLower(name)
	}
	name = strings.TrimSuffix(name, ".")
	if name == "" || len(name) > 253 {
		return false
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return false
		}
		for index := 0; index < len(label); index++ {
			char := label[index]
			if !((char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '-' || char == '_') {
				return false
			}
		}
	}
	return true
}
