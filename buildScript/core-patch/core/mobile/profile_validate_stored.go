// Stored-form (NodeRow.outbound_json) validation for profileValidate.
//
// The kernel path in profile_codec_actions.go validates an outbound against the
// core's own option structs. Throne's editor, however, keeps a much smaller
// document: `type` plus the type's fields and the flat dial fields. That form
// needs the save gate's semantic checks the option structs cannot express — a
// required address or credential, a port in range, a known cipher, a dial
// duration. This file reuses the parsed subset from profile_export_simple.go
// and checks exactly those, so the editor can refuse a bad node before saving
// without inventing a third protocol model.
//
// The action shape stays that of profileValidate; only format:"stored" adds the
// `supported` boolean. A document whose type or fields this slice does not own
// answers ok:false, supported:false and one issue, so the editor refuses the row
// instead of presenting a Go verdict about a document it only half understands.
// Messages here are stable English strings: this is a new action path with no
// localisation contract to preserve.
package mobile

import (
	"fmt"
	"net/netip"
	"sort"
	"strings"
	"time"
)

const (
	profileFormatKernel = "kernel"
	profileFormatStored = "stored"
)

// shadowsocksKnownMethods is the Kotlin shadowsocksMethods list (shadowsocks.h),
// ported verbatim. The Go config builder has no cipher list of its own: it
// writes whatever `method` it is given and lets the kernel reject it at load
// time, so this list is the authoritative known set available to the caller.
var shadowsocksKnownMethods = map[string]bool{
	"2022-blake3-aes-128-gcm": true, "2022-blake3-aes-256-gcm": true,
	"2022-blake3-chacha20-poly1305": true, "none": true, "aes-128-gcm": true,
	"aes-192-gcm": true, "aes-256-gcm": true, "chacha20-ietf-poly1305": true,
	"xchacha20-ietf-poly1305": true, "aes-128-ctr": true, "aes-192-ctr": true,
	"aes-256-ctr": true, "aes-128-cfb": true, "aes-192-cfb": true,
	"aes-256-cfb": true, "rc4-md5": true, "chacha20-ietf": true, "xchacha20": true,
}

// shadowsocksKnownPlugins mirrors Kotlin's shadowsocksPlugins (SIP003 plugins
// the core registers); an empty plugin is allowed and means "no plugin".
var shadowsocksKnownPlugins = map[string]bool{
	"": true, "obfs-local": true, "v2ray-plugin": true,
}

// handleProfileValidateStored validates one stored JSON document and returns a
// profileValidateResult. The `supported` pointer is always set here: supported
// types get a real verdict, other documents are refused by the editor.
func handleProfileValidateStored(document string) (any, error) {
	result := profileValidateResult{
		Issues:    []profileIssue{},
		Supported: boolPointer(true),
	}
	issues := storedIssues{}
	if strings.TrimSpace(document) == "" {
		issues.addError("", "the document is empty; expected one stored outbound object")
		return finishStoredValidation(result, issues, ""), nil
	}
	object, ok := configDecodeJSONObject(document)
	if !ok {
		issues.addError("", "the document is not a JSON object")
		return finishStoredValidation(result, issues, ""), nil
	}
	// The three Throne-only constructs (chain/custom/autoselector) are expanded by
	// the config builder rather than the kernel; their save gate lives in
	// profile_validate_stored_constructs.go.
	if answer, handled, err := handleProfileValidateStoredConstruct(object, strings.TrimSpace(configJSONString(object, "type"))); handled {
		return answer, err
	}
	// vmess/vless/trojan/hysteria(2) share profile_export_advanced.go's stored
	// reader; profile_validate_stored_advanced.go adds their save gate.
	if answer, handled, err := handleProfileValidateStoredAdvanced(object, strings.TrimSpace(configJSONString(object, "type"))); handled {
		return answer, err
	}
	// The QUIC-family types share the stored advanced shape but need their own
	// required-field checks; dispatch before the simple codec (which would
	// report them as unsupported).
	if answer, handled := handleProfileValidateTuicAnyTLS(object, configJSONString(object, "type")); handled {
		return answer, nil
	}
	// mieru/snell/shadowtls share the advanced stored shape but have their own
	// required fields, so they dispatch before the simple codec too.
	if answer, handled := handleProfileValidateWg(object, configJSONString(object, "type")); handled {
		return answer, nil
	}
	if answer, handled := handleProfileValidateNewOutbound(object, configJSONString(object, "type")); handled {
		return answer, nil
	}
	// The two endpoint types (openvpn/openconnect) keep nested blocks the simple
	// codec does not model; they answer their own issues or supported:false.
	if answer, handled := handleProfileValidateVpn(object, configJSONString(object, "type")); handled {
		return answer, nil
	}
	// juicity/naive/ssh/trusttunnel (profile_validate_juicity.go) share the
	// advanced stored shape but have their own required fields.
	if answer, handled := handleProfileValidateS5New(object, configJSONString(object, "type")); handled {
		return answer, nil
	}
	outbound, supported, err := profileStoredSimpleFromObject(object)
	if err != nil {
		// A malformed document of a supported type: profileStoredSimpleFromObject
		// only errors on an invalid server host, which is a real validation
		// finding, not an action failure.
		issues.addError("server", err.Error())
		return finishStoredValidation(result, issues, ""), nil
	}
	if !supported {
		result.Supported = boolPointer(false)
		rawType := configJSONString(object, "type")
		if !profileStoredSimpleTypes[rawType] {
			issues.addError("", fmt.Sprintf("outbound type %q is not supported by stored validation", rawType))
		} else {
			issues.addError("", fmt.Sprintf("the stored %q document carries a field this validation does not model (TLS, transport, multiplex, a percent-escaped host, or non-string headers)", rawType))
		}
		return finishStoredValidation(result, issues, ""), nil
	}

	// Fixed check order: shared dial fields, then endpoint, then type-specific
	// fields. Deterministic so a UI can pin issue order in tests.
	issues.validateDialFields(outbound)
	switch outbound.Type {
	case "direct":
		// No endpoint required; dial fields already checked.
	case "http":
		issues.validateEndpoint(outbound)
		issues.validateHTTP(outbound)
	case "socks":
		issues.validateEndpoint(outbound)
		issues.validateSocks(outbound, object)
	case "shadowsocks":
		issues.validateEndpoint(outbound)
		issues.validateShadowsocks(outbound)
	}

	normalized, err := profileStoredSimpleJSON(outbound)
	if err != nil {
		// Encoding only fails on a type this slice does not model, which cannot
		// happen after profileStoredSimpleFromObject answered supported=true.
		return nil, fmt.Errorf("profile.validate: encode stored document: %w", err)
	}
	// The canonical form is emitted whenever the document was parsed, even with
	// errors: the editor can show a corrected draft. Issues tell the caller not
	// to save it. Unsupported documents never reach here.
	return finishStoredValidation(result, issues, normalized), nil
}

// finishStoredValidation attaches the issues and the canonical document. A
// document with only warnings is ok:true — warnings do not block saving. A
// document with no errors and no issues is ok:true as well.
func finishStoredValidation(result profileValidateResult, issues storedIssues, normalized string) profileValidateResult {
	if len(issues) == 0 {
		// The wire contract says [] for a clean document; append(nil, empty...)
		// would marshal as null.
		result.Issues = []profileIssue{}
	} else {
		result.Issues = append([]profileIssue{}, issues...)
	}
	if normalized != "" {
		result.Normalized = normalized
	}
	result.OK = !issues.hasErrors()
	return result
}

func boolPointer(value bool) *bool {
	return &value
}

// storedIssues accumulates findings in insertion order.
type storedIssues []profileIssue

func (issues *storedIssues) add(field, message, severity string) {
	*issues = append(*issues, profileIssue{Field: field, Message: message, Severity: severity})
}

func (issues *storedIssues) addError(field, message string) {
	issues.add(field, message, profileSeverityError)
}

func (issues *storedIssues) addWarning(field, message string) {
	issues.add(field, message, profileSeverityWarning)
}

func (issues storedIssues) hasErrors() bool {
	for _, issue := range issues {
		if issue.Severity == profileSeverityError {
			return true
		}
	}
	return false
}

// validateDialFields checks the fields common to all four stored forms: the
// connect timeout (a Go duration) and the inet4/inet6 bind addresses.
func (issues *storedIssues) validateDialFields(outbound *profileStoredSimple) {
	if text := outbound.ConnectTimeout; text != "" {
		if _, err := time.ParseDuration(text); err != nil {
			issues.addError("connect_timeout", "connect_timeout must be a duration such as 5s or 1m30s")
		} else if strings.HasPrefix(text, "-") {
			issues.addError("connect_timeout", "connect_timeout must not be negative")
		}
	}
	if text := outbound.Inet4Bind; text != "" {
		address, err := netip.ParseAddr(text)
		if err != nil || !address.Is4() {
			issues.addError("inet4_bind_address", "inet4_bind_address must be an IPv4 address")
		}
	}
	if text := outbound.Inet6Bind; text != "" {
		address, err := netip.ParseAddr(text)
		if err != nil || !address.Is6() {
			issues.addError("inet6_bind_address", "inet6_bind_address must be an IPv6 address")
		}
	}
}

// validateEndpoint checks the required server and the 1..65535 port range.
// `direct` has no endpoint and never calls this.
func (issues *storedIssues) validateEndpoint(outbound *profileStoredSimple) {
	if outbound.Server == "" {
		issues.addError("server", "server is required")
	}
	if outbound.Port < 1 || outbound.Port > 65535 {
		issues.addError("server_port", "server_port must be between 1 and 65535")
	}
}

// validateHTTP checks the credentials and the headers object.
func (issues *storedIssues) validateHTTP(outbound *profileStoredSimple) {
	if outbound.Password != "" && outbound.Username == "" {
		issues.addWarning("password", "password is set but username is empty; the server will not receive credentials")
	}
	// profileStoredSimpleFromObject maps a non-string-map headers object to
	// supported:false. This check is the explicit guard for a map that survived
	// with a nil value and documents the accepted shape.
	if outbound.Headers != nil {
		keys := make([]string, 0, len(outbound.Headers))
		for key := range outbound.Headers {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			if strings.TrimSpace(key) == "" {
				issues.addError("headers", "headers must not contain an empty key")
			}
		}
	}
}

// validateSocks checks the SOCKS version and the credential pairing. SOCKS4
// carries only a user id, so a password is not meaningful there. The raw object
// is inspected because the parsed subset collapses every non-4 version to 5.
func (issues *storedIssues) validateSocks(outbound *profileStoredSimple, object map[string]any) {
	if value, present := object["version"]; present {
		version := strings.ToLower(strings.TrimSpace(fmt.Sprint(value)))
		switch version {
		case "4", "4a", "5":
		default:
			issues.addError("version", "version must be 4, 4a or 5")
		}
	}
	if outbound.Password != "" && outbound.Username == "" {
		issues.addWarning("password", "password is set but username is empty; SOCKS credentials need both")
	}
	if outbound.Socks4 && outbound.Password != "" {
		issues.addWarning("password", "SOCKS4 has no password field; the password will be ignored")
	}
}

// validateShadowsocks checks the cipher, credential and SIP003 plugin fields.
// It ports ShadowsocksChecks: a 2022 method takes ':'-separated base64 keys of
// the cipher's size, and an unknown plugin/mode is an error (the config builder
// writes these values verbatim, so a warning would let the kernel reject the
// whole configuration later).
func (issues *storedIssues) validateShadowsocks(outbound *profileStoredSimple) {
	if outbound.Multiplex != nil && configJSONBool(outbound.Multiplex, "enabled") {
		switch protocol := configJSONString(outbound.Multiplex, "protocol"); protocol {
		case "", "smux", "yamux", "h2mux":
		default:
			issues.addError("multiplex.protocol", "multiplex.protocol must be smux, yamux or h2mux")
		}
	}
	method := strings.TrimSpace(outbound.Method)
	if method == "" {
		issues.addError("method", "method is required")
	} else if !shadowsocksKnownMethods[method] {
		issues.addError("method", fmt.Sprintf("unknown shadowsocks method %q", outbound.Method))
	} else if message := shadowsocksPasswordMessage(method, outbound.Password); message != "" {
		issues.addError("password", message)
	}
	pluginName, pluginOpts := outbound.Plugin, outbound.PluginOpts
	if name, opts, found := strings.Cut(pluginName, ";"); found {
		pluginName, pluginOpts = name, opts
	}
	pluginName = strings.TrimSpace(pluginName)
	if !shadowsocksKnownPlugins[pluginName] {
		issues.addError("plugin", fmt.Sprintf("unknown shadowsocks plugin %q", outbound.Plugin))
		return
	}
	switch pluginName {
	case "obfs-local":
		mode := pluginOption(pluginOpts, "obfs")
		if mode == "" {
			mode = "http"
		}
		if mode != "http" && mode != "tls" {
			issues.addError("plugin_opts", fmt.Sprintf("obfs-local mode %q is not http or tls", mode))
		}
	case "v2ray-plugin":
		mode := pluginOption(pluginOpts, "mode")
		if mode == "" {
			mode = "websocket"
		}
		if mode != "websocket" && mode != "quic" {
			issues.addError("plugin_opts", fmt.Sprintf("v2ray-plugin mode %q is not websocket or quic", mode))
		}
		if raw := pluginOption(pluginOpts, "mux"); raw != "" && mode == "websocket" && !shadowsocksAtoi(raw) {
			issues.addError("plugin_opts", "v2ray-plugin mux must be an integer")
		}
	}
}

// shadowsocksPasswordMessage is ShadowsocksChecks.shadowsocksPassword.
func shadowsocksPasswordMessage(method, password string) string {
	if method == "none" {
		return ""
	}
	aes128 := method == "2022-blake3-aes-128-gcm"
	chacha := method == "2022-blake3-chacha20-poly1305"
	if !aes128 && !chacha && method != "2022-blake3-aes-256-gcm" {
		if password == "" {
			return "password is required"
		}
		return ""
	}
	keys := strings.Split(password, ":")
	if chacha && len(keys) > 1 {
		return "2022-blake3-chacha20-poly1305 takes exactly one key"
	}
	size := 32
	if aes128 {
		size = 16
	}
	for index, key := range keys {
		message := shadowsocksKeyMessage(key, size)
		if message == "" {
			continue
		}
		if len(keys) == 1 {
			return message
		}
		return fmt.Sprintf("key %d: %s", index+1, message)
	}
	return ""
}

func shadowsocksKeyMessage(key string, size int) string {
	if strings.ContainsAny(key, " \t\r\n") {
		return "the key must not contain whitespace"
	}
	decoded, ok := profileBase64Decode(key, false)
	if !ok || len(decoded) != size {
		return fmt.Sprintf("the key must be base64 of %d bytes", size)
	}
	return ""
}

// shadowsocksAtoi is strconv.Atoi: one optional sign, then decimal digits.
func shadowsocksAtoi(text string) bool {
	value := strings.TrimSpace(text)
	if value == "" {
		return false
	}
	if value[0] == '+' || value[0] == '-' {
		value = value[1:]
	}
	if value == "" {
		return false
	}
	for _, char := range value {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}

// pluginOption reads one key from SIP003 `;`-separated key[=value] options,
// mirroring sing-box's transport/sip003 parser closely enough for a warning.
func pluginOption(opts, key string) string {
	for _, term := range strings.Split(opts, ";") {
		name, value, found := strings.Cut(term, "=")
		if found && strings.TrimSpace(name) == key {
			return strings.TrimSpace(value)
		}
	}
	return ""
}
