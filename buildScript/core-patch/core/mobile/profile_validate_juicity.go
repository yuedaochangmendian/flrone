// Stored validation for juicity, naive, ssh and trusttunnel, the four types
// the profile_import_juicity.go slice added to profileImport/profileExport.
//
// The checks mirror each type's Validate() with the shared Outbound.validate
// endpoint and TLS rules, in the same fixed order the existing stored
// validators use (dial fields, endpoint, type-specific fields, TLS). A document
// carrying a field this slice does not model answers supported:false and falls
// back to the Kotlin validator instead of presenting a half-informed verdict.
package mobile

import (
	"errors"
	"fmt"
	"net/netip"
	"regexp"
	"strings"
)

// handleProfileValidateS5New validates one juicity/naive/ssh/trusttunnel stored
// document. It returns (result, handled): handled=false means the document is
// not one of the four types and the caller continues down the simple path.
func handleProfileValidateS5New(object map[string]any, rawType string) (profileValidateResult, bool) {
	if !profileS5NewTypes[rawType] {
		return profileValidateResult{}, false
	}
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	issues := storedIssues{}
	parsed, err := profileS5FromObject(object, rawType, profileNewValidateMode)
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
	if len(parsed.Unknown) > 0 {
		result.Supported = boolPointer(false)
		issues.addError("", fmt.Sprintf(
			"the stored %q document carries a field this validation does not model; fall back to the Kotlin validator",
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
	portOptional := rawType == "ssh"
	if node.Port == 0 {
		if !portOptional {
			issues.addError("server_port", "server_port is required")
		}
	} else if node.Port < 1 || node.Port > 65535 {
		issues.addError("server_port", "server_port must be between 1 and 65535")
	}

	switch rawType {
	case "juicity":
		profileValidateJuicity(&issues, object)
	case "naive":
		profileValidateNaive(&issues, object)
	case "ssh":
		profileValidateSSH(&issues, object)
	case "trusttunnel":
		profileValidateTrustTunnel(&issues, object)
	}
	// Every type here is must-tls, so the TLS rules apply even with the block
	// off. Naive's limitedTls() narrows them to server_name/certificate/ECH.
	profileS5ValidateTLS(&issues, parsed.TLS, rawType == "naive")

	normalized, err := profileAdvancedNodeWithObject(node, profileS5NewObject(node))
	if err != nil {
		return profileValidateResult{}, true
	}
	result.Normalized = normalized.JSON
	return finishStoredValidation(result, issues, normalized.JSON), true
}

// profileValidateJuicity is Juicity.validate: super.validate plus the UUID.
func profileValidateJuicity(issues *storedIssues, object map[string]any) {
	uuid := configJSONString(object, "uuid")
	if strings.TrimSpace(uuid) == "" {
		issues.addError("uuid", "uuid is required")
	} else if !profileValidUUID(uuid) {
		issues.addError("uuid", "uuid is not a valid UUID")
	}
}

// profileValidateNaive is Naive.validate: the QUIC congestion control must be a
// known name, and every extra header name must be an HTTP token (a warning).
func profileValidateNaive(issues *storedIssues, object map[string]any) {
	if configJSONBool(object, "quic") {
		congestion := configJSONString(object, "quic_congestion_control")
		if !profileNewOneOf(congestion, profileNaiveCongestionControls, false) {
			issues.addError("quic_congestion_control", "quic_congestion_control must be bbr, bbr2, cubic or reno")
		}
	}
	headers, _ := object["extra_headers"].(map[string]any)
	if _, present := object["extra_headers"]; present {
		if _, ok := object["extra_headers"].(map[string]any); !ok {
			issues.addWarning("extra_headers", "extra_headers is not an object; the headers are dropped")
		}
	}
	pairs := profileNaivePairsFromObject(headers)
	for index := 0; index+1 < len(pairs); index += 2 {
		if !profileS5HTTPToken(pairs[index]) {
			issues.addWarning("extra_headers", fmt.Sprintf("%q is not a valid HTTP header name", pairs[index]))
			break
		}
	}
}

// profileValidateSSH is Ssh.validate: keys and passwords are never echoed; host
// keys are public.
func profileValidateSSH(issues *storedIssues, object map[string]any) {
	password := configJSONString(object, "password")
	privateKey := configJSONString(object, "private_key")
	privateKeyPath := configJSONString(object, "private_key_path")
	if password == "" && strings.TrimSpace(privateKey) == "" && strings.TrimSpace(privateKeyPath) == "" {
		issues.addWarning("auth", "no password, private key or key file set; the server will be asked for the \"none\" method")
	}
	if message := profileS5SSHPrivateKeyMessage(privateKey); message != "" {
		issues.addError("private_key", message)
	}
	if strings.TrimSpace(privateKey) != "" && strings.TrimSpace(privateKeyPath) != "" {
		issues.addWarning("private_key", "both private_key and private_key_path are set; the inline key is used and the file ignored")
	}
	if items := configJSONStringListValue(object["host_key"]); len(items) > 0 {
		for _, key := range items {
			if message := profileS5SSHHostKeyMessage(key); message != "" {
				issues.addError("host_key", message)
				break
			}
		}
	}
	if clientVersion := strings.TrimSpace(configJSONString(object, "client_version")); clientVersion != "" &&
		!strings.HasPrefix(clientVersion, "SSH-2.0-") {
		issues.addWarning("client_version", "client_version should start with SSH-2.0-")
	}
}

// profileValidateTrustTunnel is TrustTunnel.validate.
func profileValidateTrustTunnel(issues *storedIssues, object map[string]any) {
	username := configJSONString(object, "username")
	password := configJSONString(object, "password")
	if strings.TrimSpace(username) == "" || password == "" {
		issues.addError("username", "username and password are required")
	}
	customSNI := configJSONString(object, "custom_sni")
	if message := profileS5HostMessage(customSNI); message != "" {
		issues.addError("custom_sni", "custom_sni is not a valid host name")
	}
	clientRandom := configJSONString(object, "client_random")
	if !profileS5ClientRandomValid(clientRandom) {
		issues.addError("client_random", "client_random must be a hex prefix[/mask] of 1 to 32 bytes")
	}
	quic := configJSONBool(object, "quic")
	ech := false
	reality := false
	disableSNI := false
	utlsFingerprint := ""
	if tls, ok := object["tls"].(map[string]any); ok {
		ech = configJSONBool(configJSONObjectValue(tls["ech"]), "enabled")
		reality = configJSONBool(configJSONObjectValue(tls["reality"]), "enabled")
		disableSNI = configJSONBool(tls, "disable_sni")
		if utls, ok := tls["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
			utlsFingerprint = configJSONString(utls, "fingerprint")
		}
	}
	switch {
	case strings.TrimSpace(clientRandom) != "" && ech:
		issues.addError("tls", "client_random cannot be combined with ECH")
	case strings.TrimSpace(customSNI) != "" && ech:
		issues.addError("tls", "custom_sni cannot be combined with ECH")
	case strings.TrimSpace(customSNI) != "" && disableSNI:
		issues.addError("tls", "custom_sni cannot be combined with disable_sni")
	case quic:
		// A QUIC build drops uTLS and REALITY, so neither conflicts.
	case (strings.TrimSpace(clientRandom) != "" || strings.TrimSpace(customSNI) != "") && reality:
		issues.addError("tls", "client_random/custom_sni cannot be combined with REALITY")
	case strings.TrimSpace(clientRandom) != "" && utlsFingerprint == "custom":
		issues.addError("tls", "client_random cannot be combined with the custom uTLS fingerprint")
	}
}

// --- TLS validation ---------------------------------------------------------

// profileS5ValidateTLS is Tls.validate for the modelled field set. The
// certificate/pin/client-certificate checks are only reachable when those
// fields are present; a document carrying a TLS option this slice does not
// model is answered supported:false before this runs.
func profileS5ValidateTLS(issues *storedIssues, tls map[string]any, limited bool) {
	if tls == nil {
		return
	}
	if message := profileS5ServerNameMessage(configJSONString(tls, "server_name")); message != "" {
		issues.addWarning("tls.server_name", message)
	}
	if message := profileS5PEMCertificates(configJSONStringListValue(tls["certificate"])); message != "" {
		issues.addError("tls.certificate", message)
	}
	if ech, ok := tls["ech"].(map[string]any); ok && configJSONBool(ech, "enabled") {
		if !profileS5ECHConfigValid(configJSONStringListValue(ech["config"])) {
			issues.addError("tls.ech.config", "tls.ech.config must be exactly one ECH CONFIGS block")
		}
		if name := configJSONString(ech, "query_server_name"); profileS5HostMessage(name) != "" {
			issues.addWarning("tls.ech.query_server_name", "tls.ech.query_server_name is not a valid host")
		}
	}
	if limited {
		return
	}
	minVersion := strings.TrimSpace(configJSONString(tls, "min_version"))
	maxVersion := strings.TrimSpace(configJSONString(tls, "max_version"))
	validMin, validMax := true, true
	if minVersion != "" && !profileS5TLSVersionValid(minVersion) {
		issues.addError("tls.min_version", "tls.min_version must be 1.0, 1.1, 1.2 or 1.3")
		validMin = false
	}
	if maxVersion != "" && !profileS5TLSVersionValid(maxVersion) {
		issues.addError("tls.max_version", "tls.max_version must be 1.0, 1.1, 1.2 or 1.3")
		validMax = false
	}
	if validMin && validMax && minVersion != "" && maxVersion != "" && minVersion > maxVersion {
		issues.addError("tls.max_version", "tls.min_version must not be greater than tls.max_version")
	}
	for _, suite := range profileS5TLSItems(configJSONStringListValue(tls["cipher_suites"]), ":,") {
		if !profileSecureCipherSuites[suite] {
			issues.addError("tls.cipher_suites", fmt.Sprintf("cipher suite %q is not one sing-box accepts", suite))
			break
		}
	}
	for _, curve := range profileS5TLSItems(configJSONStringListValue(tls["curve_preferences"]), ",") {
		if !profileKnownTLSCurves[strings.ToLower(curve)] {
			issues.addError("tls.curve_preferences", fmt.Sprintf("unknown TLS curve %q", curve))
			break
		}
	}
	if utls, ok := tls["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" && !validFingerprint(fingerprint) {
			issues.addError("tls.utls.fingerprint", fmt.Sprintf("unknown uTLS fingerprint %q", fingerprint))
		}
	}
	for _, key := range []string{"certificate_sha256", "certificate_public_key_sha256"} {
		for _, pin := range configJSONStringListValue(tls[key]) {
			if len(profileS5PinsFromPCS(pin)) == 1 {
				issues.addError("tls."+key, "a certificate pin must be the base64 form, not hex")
				break
			}
			if decoded, ok := profileBase64Decode(strings.TrimSpace(pin), false); !ok || len(decoded) != 32 {
				issues.addError("tls."+key, "a certificate pin must be base64 of 32 bytes")
				break
			}
		}
	}
	hasPins := len(configJSONStringListValue(tls["certificate_sha256"])) > 0 ||
		len(configJSONStringListValue(tls["certificate_public_key_sha256"])) > 0
	hasCertificate := len(configJSONStringListValue(tls["certificate"])) > 0 ||
		configJSONString(tls, "certificate_path") != ""
	if hasPins && hasCertificate {
		issues.addError("tls.certificate_sha256", "certificate pins cannot be combined with a configured CA certificate")
	}
	if message := profileS5PEMCertificates(configJSONStringListValue(tls["client_certificate"])); message != "" {
		issues.addError("tls.client_certificate", message)
	}
	if message := profileS5PEMPrivateKey(configJSONStringListValue(tls["client_key"])); message != "" {
		issues.addError("tls.client_key", message)
	}
	hasClientCertificate := len(configJSONStringListValue(tls["client_certificate"])) > 0 ||
		configJSONString(tls, "client_certificate_path") != ""
	hasClientKey := len(configJSONStringListValue(tls["client_key"])) > 0 ||
		configJSONString(tls, "client_key_path") != ""
	if hasClientCertificate != hasClientKey {
		issues.addError("tls.client_key", "a client certificate and its private key must be set together")
	}
	// BuildContext.DEFAULT has fragmentImplementation "built-in" and
	// fragmentDefaultOn false: only an explicit fragment:true turns it on.
	if configJSONBool(tls, "fragment") {
		if delay := strings.TrimSpace(configJSONString(tls, "fragment_fallback_delay")); delay != "" && configValidDuration(delay) == "" {
			issues.addError("tls.fragment_fallback_delay", "tls.fragment_fallback_delay must be a duration such as 100ms")
		}
	}
	profileS5ValidateReality(issues, tls)
}

func profileS5ValidateReality(issues *storedIssues, tls map[string]any) {
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
	// TlsChecks.realityConflict with spoof false (the validator never emits it).
	ech := false
	if block, ok := tls["ech"].(map[string]any); ok {
		ech = configJSONBool(block, "enabled")
	}
	switch {
	case ech:
		issues.addError("tls.reality", "REALITY cannot be combined with ECH")
	case configJSONBool(tls, "disable_sni") && !configJSONBool(tls, "insecure"):
		issues.addError("tls.reality", "REALITY with disable_sni requires insecure")
	}
}

// --- small checks -----------------------------------------------------------

// profileS5PEMBlock is one BEGIN/END block of tlsPemBlocks.
type profileS5PEMBlock struct {
	label  string
	bodyOK bool
}

// profileS5PEMBlocks is tlsPemBlocks: Go pem.Decode's view of the text, with
// "Key: value" header lines skipped and `trailing` set when non-blank text
// follows a complete block.
func profileS5PEMBlocks(lines []string) ([]profileS5PEMBlock, bool) {
	blocks := []profileS5PEMBlock{}
	trailing := false
	label := ""
	var body strings.Builder
	inside := false
	for _, raw := range strings.Split(strings.Join(lines, "\n"), "\n") {
		line := strings.TrimSpace(raw)
		if !inside {
			if strings.HasPrefix(line, "-----BEGIN ") && strings.HasSuffix(line, "-----") && len(line) > 16 {
				label = line[11 : len(line)-5]
				body.Reset()
				inside = true
			} else if len(blocks) > 0 && line != "" {
				trailing = true
			}
			continue
		}
		if line == "-----END "+label+"-----" {
			blocks = append(blocks, profileS5PEMBlock{label: label, bodyOK: profileMieruBase64Valid(body.String())})
			inside = false
		} else if !strings.Contains(line, ":") {
			body.WriteString(line)
		}
	}
	return blocks, trailing
}

func profileS5HasText(items []string) bool {
	for _, item := range items {
		if strings.TrimSpace(item) != "" {
			return true
		}
	}
	return false
}

// profileS5PEMCertificates is TlsChecks.pemCertificates.
func profileS5PEMCertificates(lines []string) string {
	if !profileS5HasText(lines) {
		return ""
	}
	blocks, _ := profileS5PEMBlocks(lines)
	for _, block := range blocks {
		if block.label == "CERTIFICATE" && block.bodyOK {
			return ""
		}
	}
	return "tls.certificate must contain a CERTIFICATE PEM block"
}

// profileS5PEMPrivateKey is TlsChecks.pemPrivateKey.
func profileS5PEMPrivateKey(lines []string) string {
	if !profileS5HasText(lines) {
		return ""
	}
	blocks, _ := profileS5PEMBlocks(lines)
	for _, block := range blocks {
		if (block.label == "PRIVATE KEY" || strings.HasSuffix(block.label, " PRIVATE KEY")) && block.bodyOK {
			return ""
		}
	}
	return "tls.client_key must contain a PRIVATE KEY PEM block"
}

// profileS5ECHConfigValid is TlsChecks.echConfig: exactly one ECH CONFIGS block
// and nothing after it.
func profileS5ECHConfigValid(lines []string) bool {
	if !profileS5HasText(lines) {
		return true
	}
	blocks, trailing := profileS5PEMBlocks(lines)
	if len(blocks) != 1 || trailing {
		return false
	}
	return blocks[0].label == "ECH CONFIGS" && blocks[0].bodyOK
}

// profileS5HTTPToken is Validation.httpToken over a non-empty value.
func profileS5HTTPToken(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return false
	}
	for _, char := range trimmed {
		if char >= 'a' && char <= 'z' || char >= 'A' && char <= 'Z' || char >= '0' && char <= '9' {
			continue
		}
		if char <= 0 || char >= 0x80 || !strings.ContainsRune("!#$%&'*+-.^_`|~", char) {
			return false
		}
	}
	return true
}

// profileS5ServerNameMessage is CommonChecks.serverName: a host, or a
// host:port the rule reports separately.
func profileS5ServerNameMessage(text string) string {
	message := profileS5HostMessage(text)
	if message == "" {
		return ""
	}
	if message == "port" {
		return "the SNI must not include a port"
	}
	return "the SNI is not a valid host name"
}

// profileS5HostMessage is Validation.host(text, Empty.Allowed): "" when valid,
// "port" when the value is a host:port pair, "host" otherwise.
func profileS5HostMessage(text string) string {
	t := strings.TrimSpace(text)
	if t == "" {
		return ""
	}
	if strings.Contains(t, "://") {
		return "host"
	}
	if strings.ContainsAny(t, " \t\r\n\v\f") {
		return "host"
	}
	if strings.ContainsAny(t, "/?#@") {
		return "host"
	}
	if strings.HasPrefix(t, "[") {
		close := strings.Index(t, "]")
		if close < 0 {
			return "host"
		}
		address, err := netip.ParseAddr(t[1:close])
		if err != nil || !address.Is6() {
			return "host"
		}
		rest := t[close+1:]
		if rest == "" {
			return ""
		}
		if strings.HasPrefix(rest, ":") && profileLinkAllDigits(rest[1:]) {
			return "port"
		}
		return "host"
	}
	bare := t
	if percent := strings.IndexByte(bare, '%'); percent > 0 && !strings.Contains(bare[percent+1:], ":") {
		bare = bare[:percent]
	}
	if _, err := netip.ParseAddr(bare); err == nil {
		return ""
	}
	if colon := strings.LastIndex(t, ":"); colon >= 0 {
		if strings.Index(t, ":") != colon {
			return "host"
		}
		if profileLinkAllDigits(t[colon+1:]) {
			return "port"
		}
		return "host"
	}
	digitsOrDots := true
	for _, char := range t {
		if (char < '0' || char > '9') && char != '.' {
			digitsOrDots = false
			break
		}
	}
	if digitsOrDots {
		return "host"
	}
	name := t
	if !configIsASCII(name) {
		ace, ok := configToACE(name)
		if !ok {
			return "host"
		}
		name = ace
	}
	name = strings.TrimSuffix(name, ".")
	if name == "" || len(name) > 253 {
		return "host"
	}
	for _, label := range strings.Split(name, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return "host"
		}
		for index := 0; index < len(label); index++ {
			char := label[index]
			if char >= 0x80 {
				return "host"
			}
			if !((char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
				(char >= '0' && char <= '9') || char == '-' || char == '_') {
				return "host"
			}
		}
	}
	return ""
}

// profileS5ClientRandomValid is TrustTunnelChecks.trustTunnelClientRandom.
func profileS5ClientRandomValid(text string) bool {
	value := strings.TrimSpace(text)
	if value == "" {
		return true
	}
	prefix := value
	mask := ""
	if slash := strings.Index(value, "/"); slash >= 0 {
		prefix = value[:slash]
		mask = value[slash+1:]
	}
	if prefix == "" || len(prefix) < 2 || len(prefix) > 64 || len(prefix)%2 != 0 || !profileS5IsHex(prefix) {
		return false
	}
	if mask != "" {
		if len(mask) != len(prefix) || !profileS5IsHex(mask) {
			return false
		}
	}
	return true
}

// profileS5TLSItems splits a TLS list the way singBoxCipherSuites/eachItem do:
// on ':' and ',' (cipher suites) or ',' only (curves), trimming and dropping
// empty items.
func profileS5TLSItems(items []string, separators string) []string {
	out := []string{}
	for _, item := range items {
		parts := []string{item}
		if strings.ContainsAny(item, separators) {
			parts = strings.FieldsFunc(item, func(r rune) bool { return strings.ContainsRune(separators, r) })
		}
		for _, part := range parts {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				out = append(out, trimmed)
			}
		}
	}
	return out
}

// --- ssh key checks ---------------------------------------------------------

var profileS5SSHPublicKey = regexp.MustCompile(`^(?:\S+\s+)?(?:ssh-|ecdsa-sha2-|sk-)\S+\s+AAAA`)

// profileS5SSHPrivateKeyMessage is SshChecks.sshPrivateKey.
func profileS5SSHPrivateKeyMessage(text string) string {
	key := strings.TrimSpace(text)
	if key == "" || (strings.Contains(key, "-----BEGIN ") && strings.Contains(key, "PRIVATE KEY-----")) {
		return ""
	}
	if profileS5SSHPublicKey.MatchString(key) {
		return "private_key holds a public key, not a private key"
	}
	if strings.HasPrefix(key, "PuTTY-User-Key-File") {
		return "PuTTY key files are not supported; convert it to PEM first"
	}
	return "private_key is not a PEM private key"
}

// profileS5SSHHostKeyMessage is SshChecks.sshHostKey: [options] type base64
// [comment], the type matching the one inside the key.
func profileS5SSHHostKeyMessage(item string) string {
	line := strings.TrimSpace(item)
	typed := func(text string) bool {
		fields := strings.Fields(strings.TrimSpace(text))
		return len(fields) >= 2 && profileSSHKeyBlobType(fields[1]) == fields[0]
	}
	if typed(line) {
		return ""
	}
	quoted := false
	end := 0
	for end < len(line) {
		char := line[end]
		if !quoted && (char == ' ' || char == '\t') {
			break
		}
		if char == '"' && (end == 0 || line[end-1] != '\\') {
			quoted = !quoted
		}
		end++
	}
	if end < len(line) && typed(line[end:]) {
		return ""
	}
	return "host_key is not an authorized_keys line whose key type matches its base64 blob"
}

// profileSSHKeyBlobType is sshKeyBlobType: the algorithm name a wire-format
// public key starts with, or "" when the text is not padded base64 of one.
func profileSSHKeyBlobType(text string) string {
	if text == "" || len(text)%4 != 0 {
		return ""
	}
	blob, ok := profileBase64Decode(text, false)
	if !ok || len(blob) < 4 {
		return ""
	}
	length := 0
	for index := 0; index < 4; index++ {
		length = (length << 8) | int(blob[index])
	}
	if length == 0 || length > len(blob)-4 {
		return ""
	}
	return string(blob[4 : 4+length])
}
