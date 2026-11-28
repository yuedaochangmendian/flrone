// The share-link half of the profile codec (S5c): one link in, one Throne
// stored-form node out, ported from the Kotlin outbound parsers that the
// desktop profile code uses as its oracle.
//
// # Scope and refusal contract
//
// This slice owns only the links whose every field it can reproduce byte for
// byte: http (without TLS), socks (all version spellings) and shadowsocks (all
// userinfo encodings). A link carrying a field this file cannot yet port —
// TLS, transport, multiplex, a host form Qt would rewrite differently — is
// answered `supported:false` with a reason, never a half-normalised node. The
// caller then falls back to Kotlin's importer, which remains the authority for
// the unported protocols.
//
// The oracle is the Kotlin source in this repository, not a second model:
//
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/link/{LinkParser,LinkCodec,Base64Strict,Hosts}.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/{Http,Socks,Shadowsocks}.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/common/DialFields.kt
//
// Each field below carries the name of the Kotlin function it follows. The
// tests use link vectors whose expected stored JSON is the Kotlin parser's
// exportToJson output (JsonObject's canonical sorted-key writer), so a
// behavioural change in the Kotlin parser shows up as a failing test rather
// than silently redefining "same".
package mobile

import (
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// profileImportedNode is one accepted link in the form callers store: the
// canonical compact JSON, the two share links and the dedup identity from the
// existing exporter, plus the display name/type the UI shows.
type profileImportedNode struct {
	Type     string `json:"type"`
	Name     string `json:"name"`
	JSON     string `json:"json"`
	Link     string `json:"link"`
	Identity string `json:"identity"`
	DedupKey string `json:"dedupKey"`
}

// profileImportUnsupported is the refusal value for a link the Go slice must
// not touch. Node is deliberately not emitted: see the file comment.
type profileImportUnsupported struct {
	Reason string `json:"reason"`
}

func (reason profileImportUnsupported) Error() string { return reason.Reason }

func profileUnsupported(reason string) error {
	return profileImportUnsupported{Reason: reason}
}

// profileImportOneLink is the single-link entry point used by the action.
//
// It rejects multi-line input and base64 subscription bodies before touching
// the link parser: the corpus/import orchestration is a later slice, and a
// link parser silently accepting the first line of a bundle would be a
// correctness bug rather than a convenience.
func profileImportOneLink(text string) (*profileImportedNode, error) {
	link := strings.TrimSpace(text)
	if link == "" {
		return nil, profileUnsupported("empty text: expected one share link")
	}
	if strings.ContainsAny(link, "\r\n") {
		return nil, profileUnsupported("multiple lines are not supported: expected one share link")
	}
	scheme, _, hasScheme := strings.Cut(link, "://")
	if !hasScheme {
		return nil, profileUnsupported("no URL scheme: expected one share link")
	}
	scheme = strings.ToLower(scheme)
	if scheme == "ss" {
		// The v2rayN body is base64 and has no '@' before the fragment; the
		// Kotlin parser takes that branch before QUrl ever sees the link.
		beforeFragment, _, _ := strings.Cut(link, "#")
		if !strings.Contains(beforeFragment, "@") {
			return nil, profileUnsupported("base64-body shadowsocks links are not supported in this slice")
		}
	}
	switch scheme {
	case "http", "https", "socks", "socks5", "socks4", "socks4a", "ss":
	default:
		// vmess/vless/trojan/hysteria2 and everything else carry TLS,
		// transport or multiplex fields whose Kotlin parsing has no Go port
		// yet. See profile_import_action.go's package documentation.
		return nil, profileUnsupported(fmt.Sprintf("scheme %q is not ported yet", scheme))
	}
	return profileImportKnownScheme(scheme, link)
}

func profileImportKnownScheme(scheme, link string) (*profileImportedNode, error) {
	parsed := profileLinkParse(link)
	// QUrl::isValid() is checked by every Kotlin type's parseFromLink before
	// any field is read; a rejected host/port is a malformed link, not a
	// partially imported node.
	if !parsed.IsValid() {
		return nil, profileUnsupported("malformed link: invalid host or port")
	}
	if parsed.Host == "" {
		return nil, profileUnsupported("malformed link: no host")
	}
	if profileHasUnsupportedHostForm(parsed.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}

	outbound := &profileStoredSimple{Type: "http", Port: 80}
	switch scheme {
	case "http", "https":
		if err := profileImportHTTP(scheme, parsed, outbound); err != nil {
			return nil, err
		}
	case "socks", "socks5", "socks4", "socks4a":
		outbound.Type = "socks"
		outbound.Port = 1080
		if err := profileImportSocks(scheme, parsed, outbound); err != nil {
			return nil, err
		}
	case "ss":
		outbound.Type = "shadowsocks"
		outbound.Port = 8388
		if err := profileImportShadowsocks(parsed, outbound); err != nil {
			return nil, err
		}
	}

	// Server/port come from the parsed authority: profileLinkParse has
	// already applied the same ACE/lower-case normalization Kotlin's
	// normalizeHost does (the raw spelling is kept for ASCII, as Kotlin's
	// exportToJson does).
	outbound.Server = parsed.Host
	if parsed.Port >= 0 {
		outbound.Port = parsed.Port
	}
	if outbound.Port == 0 {
		// Outbound.parseFromLink sets 0 when QUrl reports an explicit port
		// 0, then the type's default only fills in when serverPort == 0;
		// that is the Kotlin behaviour for http/socks/ss alike.
		switch outbound.Type {
		case "http":
			outbound.Port = 80
		case "socks":
			outbound.Port = 1080
		case "shadowsocks":
			outbound.Port = 8388
		}
	}
	if err := profileImportDialFields(parsed, outbound); err != nil {
		return nil, err
	}
	outbound.Name = parsed.Fragment
	storedJSON, err := profileStoredSimpleJSON(outbound)
	if err != nil {
		return nil, err
	}
	withoutTag := profileStoredSimpleWithoutTag(outbound)
	dedupJSON, err := profileStoredSimpleJSON(withoutTag)
	if err != nil {
		return nil, err
	}
	identity := storedJSON
	if outbound.Server != "" {
		encoded, encodeErr := MarshalCanonicalJSON(map[string]any{
			"server":      outbound.Server,
			"server_port": outbound.Port,
		})
		if encodeErr != nil {
			return nil, encodeErr
		}
		identity = string(encoded)
	}
	return &profileImportedNode{
		Type:     outbound.Type,
		Name:     outbound.Name,
		JSON:     storedJSON,
		Link:     profileStoredSimpleLink(outbound),
		Identity: identity,
		DedupKey: "throne://add/" + profileBase64Encode([]byte(dedupJSON), true, false),
	}, nil
}

// profileHasUnsupportedHostForm guards the host-normalization gap: the Go
// port does not yet implement Qt's C-style IPv4 shorthand (010.1, 0x7f.1,
// "1" as a 32-bit address), IPv6 embedded-IPv4 formatting or bracketed zones.
// Refusing keeps those links on the Kotlin path instead of storing a host
// string Qt would spell differently.
func profileHasUnsupportedHostForm(host string) bool {
	if strings.Contains(host, "[") || strings.Contains(host, "]") || strings.Contains(host, "%") {
		return true
	}
	if strings.Contains(host, ":") {
		// Plain IPv6: netip's canonical form matches Qt's formatIpv6 for
		// ordinary groups, but not the embedded-IPv4 shorthand.
		address, err := netip.ParseAddr(host)
		if err != nil || !address.Is6() || address.Is4In6() {
			return true
		}
		return false
	}
	// Qt's parseIpv4 accepts one to four C-style numbers and rewrites the
	// host to a dotted quad. netip only accepts the canonical four-part
	// decimal form: everything else is refused.
	if strings.Count(host, ".") <= 3 {
		address, err := netip.ParseAddr(host)
		if err == nil && address.Is4() && address.String() == host {
			return false
		}
		// Could still be a valid DNS name (e.g. "example" or "a.b");
		// only refuse when the host is all digits/hex C-number parts.
		if profileLooksLikeCIPv4(host) {
			return true
		}
	}
	return false
}

func profileLooksLikeCIPv4(host string) bool {
	parts := strings.Split(host, ".")
	if len(parts) > 4 {
		return false
	}
	for _, part := range parts {
		if part == "" {
			return false
		}
		digits := part
		base := 10
		if strings.HasPrefix(part, "0x") || strings.HasPrefix(part, "0X") {
			digits = part[2:]
			base = 16
		} else if len(part) > 1 && part[0] == '0' {
			digits = part[1:]
			base = 8
		}
		if digits == "" {
			return false
		}
		for _, r := range digits {
			var ok bool
			switch base {
			case 16:
				ok = (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') || (r >= 'A' && r <= 'F')
			case 8:
				ok = r >= '0' && r <= '7'
			default:
				ok = r >= '0' && r <= '9'
			}
			if !ok {
				return false
			}
		}
	}
	return true
}

// profileImportHTTP follows Http.parseFromLink (Http.kt:43) and the base
// Outbound.parseFromLink. TLS is the explicit stop condition: https or
// security=tls would make Kotlin parse a Tls block and default the port to
// 443, which this slice does not model.
func profileImportHTTP(scheme string, link profileParsedLink, outbound *profileStoredSimple) error {
	if scheme == "https" || strings.EqualFold(strings.TrimSpace(link.Query.Value("security")), "tls") {
		return profileUnsupported("https/security=tls is not ported yet (TLS fields would be approximated)")
	}
	username, password := link.UserName, link.Password
	// Http.kt: v2rayN base64s "user:pass" into the username; a plain name
	// like "user" is also valid base64, so only a decoded colon splits it.
	if password == "" && username != "" {
		if decoded, ok := profileBase64Decode(username, false); ok {
			text := string(decoded)
			if index := strings.Index(text, ":"); index >= 0 {
				username, password = text[:index], text[index+1:]
			}
		}
	}
	// Some providers set only the password (http://:token@host); Kotlin
	// copies it to the username so the core sends Proxy-Authorization.
	if username == "" && password != "" {
		username = password
	}
	outbound.Username, outbound.Password = username, password
	if link.Query.Has("path") {
		outbound.Path = link.Query.Value("path")
	}
	if raw := link.Query.Value("headers"); raw != "" {
		pairs := strings.Split(raw, ",")
		if len(pairs)%2 != 0 {
			return profileUnsupported("odd number of http headers: Kotlin warns and drops them")
		}
		headers := make(map[string]string, len(pairs)/2)
		for index := 0; index < len(pairs); index += 2 {
			headers[pairs[index]] = pairs[index+1]
		}
		outbound.Headers = headers
	}
	return nil
}

// profileImportSocks follows Socks.parseFromLink (Socks.kt:51) and
// parseVersion (Socks.kt:41): the explicit `version` query wins over the
// scheme's implied version, and a scheme's version only applies when no
// explicit value was supplied.
func profileImportSocks(scheme string, link profileParsedLink, outbound *profileStoredSimple) error {
	if link.Query.Has("version") {
		version := strings.ToLower(strings.TrimSpace(link.Query.Value("version")))
		switch version {
		case "4a":
			outbound.Socks4a, outbound.Socks4 = true, true
		case "4":
			outbound.Socks4 = true
		case "5":
		default:
			// Kotlin warns about an unknown version but still builds SOCKS5.
			// Keep that value semantics; a warning is not a stored field.
		}
	} else {
		switch scheme {
		case "socks4", "socks4a":
			outbound.Socks4 = true
			outbound.Socks4a = scheme == "socks4a"
		case "socks5", "socks":
			// default SOCKS5
		}
	}
	if link.Password != "" || link.UserName != "" {
		username, password := link.UserName, link.Password
		// v2rayN base64 "user:pass" in the username (Socks.kt:66).
		if password == "" && username != "" {
			if decoded, ok := profileBase64Decode(username, false); ok {
				text := string(decoded)
				if index := strings.Index(text, ":"); index >= 0 {
					username, password = text[:index], text[index+1:]
				}
			}
		}
		outbound.Username, outbound.Password = username, password
	}
	// uot is true for the literal "true" or any positive integer.
	if link.Query.Has("uot") {
		outbound.UOT = profileImportTruthy(link.Query.Value("uot"))
	}
	return nil
}

// profileImportShadowsocks follows Shadowsocks.parseFromLink (Shadowsocks.kt:146).
// Only the SIP002 plain userinfo, the base64 userinfo and the v2rayN
// all-base64 body are in scope; the base64 body is rejected earlier.
func profileImportShadowsocks(link profileParsedLink, outbound *profileStoredSimple) error {
	method, password := link.UserInfoPair()
	if password == "" {
		// Traditional base64 "method:password" in the username. Kotlin
		// tries url-safe first, then the standard alphabet, and treats an
		// empty decode as a parse failure.
		decoded, ok := profileBase64Decode(link.UserName, true)
		if !ok || len(decoded) == 0 {
			decoded, ok = profileBase64Decode(link.UserName, false)
		}
		if !ok || len(decoded) == 0 {
			return profileUnsupported("shadowsocks userinfo is not valid base64")
		}
		text := string(decoded)
		index := strings.Index(text, ":")
		if index < 0 {
			return profileUnsupported("shadowsocks base64 userinfo has no method:password separator")
		}
		method, password = text[:index], text[index+1:]
	}
	// shadowsocksMethodName: trim + lower-case.
	outbound.Method = strings.ToLower(strings.TrimSpace(method))
	outbound.Password = password

	pluginSpec := link.Query.ValueFully("plugin")
	if before, after, found := strings.Cut(pluginSpec, ";"); found {
		outbound.Plugin = profileImportPluginName(strings.TrimSpace(before))
		outbound.PluginOpts = strings.TrimSpace(after)
	} else {
		outbound.Plugin = profileImportPluginName(strings.TrimSpace(pluginSpec))
	}
	if link.Query.Has("plugin-opts") {
		outbound.PluginOpts = strings.TrimSpace(link.Query.ValueFully("plugin-opts"))
	}
	if link.Query.Has("uot") {
		outbound.UOT = profileImportTruthy(link.Query.Value("uot"))
	}
	// Multiplex.parseFromLink (Multiplex.kt:221) would read mux*,
	// brutal_* and friends. Refuse instead of dropping those fields.
	for _, key := range []string{"mux", "mux_protocol", "mux_max_connections", "mux_min_streams",
		"mux_max_streams", "mux_padding", "brutal_enabled", "brutal_up_mbps", "brutal_down_mbps"} {
		if link.Query.Has(key) {
			return profileUnsupported("shadowsocks multiplex fields are not ported yet: " + key)
		}
	}
	return nil
}

// shadowsocksPluginName: simple-obfs/obfs are the obfs-local plugin.
func profileImportPluginName(plugin string) string {
	switch plugin {
	case "simple-obfs", "obfs":
		return "obfs-local"
	default:
		return plugin
	}
}

// profileImportTruthy is the uot value semantics shared by Socks and SS:
// `true` or a positive integer. QtStrings.toInt accepts an optional sign,
// decimal digits and surrounding whitespace; a non-number is zero.
func profileImportTruthy(value string) bool {
	if strings.EqualFold(strings.TrimSpace(value), "true") {
		return true
	}
	text := strings.TrimSpace(value)
	if text == "" {
		return false
	}
	if text[0] == '+' || text[0] == '-' {
		text = text[1:]
	}
	if text == "" {
		return false
	}
	for index := 0; index < len(text); index++ {
		if text[index] < '0' || text[index] > '9' {
			return false
		}
	}
	number, err := strconv.Atoi(strings.TrimSpace(value))
	return err == nil && number > 0
}

// profileImportDialFields follows DialFields.parseFromLink (DialFields.kt:68)
// for the eight flat dial options. The three validated string fields are
// checked with the same rules Kotlin's acceptOptional applies: a link that
// carries an invalid value keeps the default in Kotlin, so Go skips it too.
func profileImportDialFields(link profileParsedLink, outbound *profileStoredSimple) error {
	query := link.Query
	if query.Has("reuse_addr") {
		outbound.ReuseAddr = query.Value("reuse_addr") == "true"
	}
	if query.Has("tcp_fast_open") {
		outbound.TCPFastOpen = query.Value("tcp_fast_open") == "true"
	}
	if query.Has("tcp_multi_path") {
		outbound.TCPMultiPath = query.Value("tcp_multi_path") == "true"
	}
	if query.Has("udp_fragment") {
		outbound.UDPFragment = query.Value("udp_fragment") == "true"
	}
	if query.Has("bind_interface") {
		outbound.BindInterface = query.Value("bind_interface")
	}
	if value, ok := profileImportCheckedString(query, "connect_timeout"); ok {
		outbound.ConnectTimeout = value
	}
	if value, ok := profileImportCheckedString(query, "inet4_bind_address"); ok {
		outbound.Inet4Bind = value
	}
	if value, ok := profileImportCheckedString(query, "inet6_bind_address"); ok {
		outbound.Inet6Bind = value
	}
	return nil
}

// profileImportCheckedString is DialFields.checked: trim the value and keep
// it only if Kotlin's validation rule would accept it. Rejected values are
// dropped (with a warning on the Kotlin side), not reported as an error.
func profileImportCheckedString(query profileLinkQuery, key string) (string, bool) {
	if !query.Has(key) {
		return "", false
	}
	value := strings.TrimSpace(query.Value(key))
	switch {
	case strings.HasSuffix(key, "connect_timeout"):
		return value, profileImportValidDuration(value)
	case strings.HasSuffix(key, "inet4_bind_address"):
		address, err := netip.ParseAddr(value)
		return value, err == nil && address.Is4()
	default:
		address, err := netip.ParseAddr(profileImportStripZone(value))
		return value, err == nil && address.Is6()
	}
}

func profileImportStripZone(value string) string {
	if index := strings.IndexByte(value, '%'); index > 0 && index < len(value)-1 &&
		!strings.Contains(value[index+1:], ":") {
		return value[:index]
	}
	return value
}

// profileImportValidDuration mirrors Validation.duration for the common
// Go-style duration spellings (ns/us/ms/s/m/h with decimals and compound
// runs). Kotlin also rejects a negative value for these dial fields; Go does
// the same. A value this helper cannot prove valid is dropped, which matches
// Kotlin's acceptOptional dropping a warning-level value.
func profileImportValidDuration(text string) bool {
	if text == "" {
		return true
	}
	if strings.HasPrefix(text, "-") {
		return false
	}
	trimmed := strings.TrimPrefix(text, "+")
	if trimmed == "" {
		return false
	}
	// Kotlin accepts "0" without a unit as a special case.
	if trimmed == "0" {
		return true
	}
	parts := 0
	for trimmed != "" {
		digits := 0
		for digits < len(trimmed) && ((trimmed[digits] >= '0' && trimmed[digits] <= '9') || trimmed[digits] == '.') {
			digits++
		}
		if digits == 0 {
			return false
		}
		trimmed = trimmed[digits:]
		unitEnd := 0
		for unitEnd < len(trimmed) && ((trimmed[unitEnd] >= 'a' && trimmed[unitEnd] <= 'z') ||
			(trimmed[unitEnd] >= 'A' && trimmed[unitEnd] <= 'Z')) {
			unitEnd++
		}
		if unitEnd == 0 {
			return false
		}
		trimmed = trimmed[unitEnd:]
		parts++
	}
	return parts > 0
}
