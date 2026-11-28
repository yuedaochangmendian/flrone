// OpenVPN stored codec and `.ovpn` profile parser (S5 slice: OpenVPN/OpenConnect).
//
// Oracle: app/src/main/java/io/nekohasekai/sagernet/outbound/types/OpenVpn.kt
// (the model, OpenVpn.parseFromJson / exportToJson, VpnFileImport and
// OpenVpnChecks) plus outbound/Outbound.kt (base parse/export/identity) and
// outbound/common/DialFields.kt. The JVM test OpenVpnGoParityTest pins the
// bytes this file has to emit for the vectors the Go tests assert.
//
// OpenVPN is a kernel *endpoint*: the stored type is `openvpn` (also accepted as
// `openvpn-client`), the build type is `openvpn-client`, and there is no share
// link — `Outbound.exportToLink` has no override here, so `exportToLink()` is
// the dial-field query string (empty for a `.ovpn` import, which never sets a
// dial field). OpenVPN is also absent from OutboundFactory's scheme table and
// from its Clash list, so a `openvpn://` link or a Clash `type: openvpn` entry
// has no Kotlin mapping; both are refused with that reason rather than guessed.
//
// The stored-JSON reader has the same three gates as profile_import_newout.go:
// import (ParseDiag active, so the optional values Kotlin drops are dropped
// here too), export (no ParseDiag: keep every stored value) and validate (like
// export). A key this slice does not model refuses the document
// (supported:false / no node) instead of being silently dropped: Kotlin's
// reader ignores unknown keys, so a document carrying one is not something this
// slice can promise to reproduce.
package mobile

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"
)

// --- shared .ovpn toolkit (VpnFileImport) -----------------------------------

// profileVpnDirective is VpnFileImport.Directive.
type profileVpnDirective struct {
	Args       []string
	InlineTag  string
	InlineBody []string
}

// profileVpnRemote is VpnFileImport.Remote.
type profileVpnRemote struct {
	Host    string
	Port    int
	Network string
}

// profileVpnIsSpace is QChar::isSpace: ASCII whitespace, NEL, NBSP and the
// Unicode separator categories, which is exactly Go's White_Space property.
func profileVpnIsSpace(char rune) bool { return unicode.IsSpace(char) }

// profileVpnTrimmed is QString::trimmed.
func profileVpnTrimmed(text string) string { return strings.TrimFunc(text, unicode.IsSpace) }

// profileVpnSimplified is QString::simplified: trimmed, inner whitespace runs
// collapsed to one space.
func profileVpnSimplified(text string) string {
	var out strings.Builder
	pendingSpace := false
	for _, char := range profileVpnTrimmed(text) {
		if profileVpnIsSpace(char) {
			pendingSpace = true
			continue
		}
		if pendingSpace {
			out.WriteByte(' ')
		}
		pendingSpace = false
		out.WriteRune(char)
	}
	return out.String()
}

// profileVpnIsSignedInteger is VpnFileImport's [ +-]?[0-9]+ shape.
func profileVpnIsSignedInteger(text string) bool {
	body := text
	if strings.HasPrefix(body, "-") || strings.HasPrefix(body, "+") {
		body = body[1:]
	}
	if body == "" {
		return false
	}
	for index := 0; index < len(body); index++ {
		if body[index] < '0' || body[index] > '9' {
			return false
		}
	}
	return true
}

// profileVpnIsUnsignedInteger is VpnFileImport's \+?[0-9]+ shape.
func profileVpnIsUnsignedInteger(text string) bool {
	body := strings.TrimPrefix(text, "+")
	if body == "" {
		return false
	}
	for index := 0; index < len(body); index++ {
		if body[index] < '0' || body[index] > '9' {
			return false
		}
	}
	return true
}

// profileVpnToInt is VpnFileImport.toIntOk: QString::toInt with its ok flag, so
// a value outside the 32-bit range is not an integer here either.
func profileVpnToInt(text string) (int, bool) {
	trimmed := profileVpnTrimmed(text)
	if !profileVpnIsSignedInteger(trimmed) {
		return 0, false
	}
	value, err := strconv.ParseInt(trimmed, 10, 32)
	if err != nil {
		return 0, false
	}
	return int(value), true
}

// profileVpnToUInt is VpnFileImport.toUInt: `\+?[0-9]+`, at most 0xFFFFFFFF.
func profileVpnToUInt(text string) (uint32, bool) {
	trimmed := profileVpnTrimmed(text)
	if !profileVpnIsUnsignedInteger(trimmed) {
		return 0, false
	}
	value, err := strconv.ParseUint(strings.TrimPrefix(trimmed, "+"), 10, 64)
	if err != nil || value > 0xFFFFFFFF {
		return 0, false
	}
	return uint32(value), true
}

// profileVpnTokenize is vpnfiTokenize: `#`/`;` start a comment only where a
// parameter would start, quotes group a value, and a backslash escapes the next
// character outside quotes (inside double quotes only `"` and `\`).
func profileVpnTokenize(line string) []string {
	tokens := []string{}
	var token strings.Builder
	quote := rune(0)
	inToken := false
	index := 0
	runes := []rune(line)
	for index < len(runes) {
		char := runes[index]
		if quote != 0 {
			if char == quote {
				quote = 0
				index++
				continue
			}
			if char == '\\' && quote == '"' && index+1 < len(runes) && (runes[index+1] == '"' || runes[index+1] == '\\') {
				index++
				token.WriteRune(runes[index])
				index++
				continue
			}
			token.WriteRune(char)
			index++
			continue
		}
		if profileVpnIsSpace(char) {
			if inToken {
				tokens = append(tokens, token.String())
				token.Reset()
				inToken = false
			}
			index++
			continue
		}
		if !inToken && (char == '#' || char == ';') {
			break
		}
		inToken = true
		if char == '"' || char == '\'' {
			quote = char
			index++
			continue
		}
		if char == '\\' && index+1 < len(runes) {
			index++
			token.WriteRune(runes[index])
			index++
			continue
		}
		token.WriteRune(char)
		index++
	}
	if inToken {
		tokens = append(tokens, token.String())
	}
	return tokens
}

// profileVpnReadOvpnDirectives is vpnfiReadOvpnDirectives: inline `<tag>`
// blocks (their interior trimmed line by line, blank edges dropped) and
// backslash line continuations.
func profileVpnReadOvpnDirectives(body string) []profileVpnDirective {
	result := []profileVpnDirective{}
	lines := strings.Split(body, "\n")
	pending := ""
	index := 0
	for index < len(lines) {
		trimmedLine := profileVpnTrimmed(strings.ReplaceAll(lines[index], "\r", ""))
		if pending == "" && len([]rune(trimmedLine)) > 2 &&
			strings.HasPrefix(trimmedLine, "<") && strings.HasSuffix(trimmedLine, ">") &&
			!strings.HasPrefix(trimmedLine, "</") {
			runes := []rune(trimmedLine)
			tag := profileVpnTrimmed(string(runes[1 : len(runes)-1]))
			closing := "</" + tag + ">"
			inlineBody := []string{}
			index++
			for index < len(lines) {
				inner := profileVpnTrimmed(strings.ReplaceAll(lines[index], "\r", ""))
				if inner == closing {
					break
				}
				inlineBody = append(inlineBody, inner)
				index++
			}
			for len(inlineBody) > 0 && inlineBody[len(inlineBody)-1] == "" {
				inlineBody = inlineBody[:len(inlineBody)-1]
			}
			for len(inlineBody) > 0 && inlineBody[0] == "" {
				inlineBody = inlineBody[1:]
			}
			result = append(result, profileVpnDirective{InlineTag: tag, InlineBody: inlineBody})
			index++
			continue
		}
		if strings.HasSuffix(trimmedLine, "\\") && !strings.HasSuffix(trimmedLine, "\\\\") {
			pending += trimmedLine[:len(trimmedLine)-1]
			pending += " "
			index++
			continue
		}
		full := pending + trimmedLine
		pending = ""
		if args := profileVpnTokenize(full); len(args) > 0 {
			result = append(result, profileVpnDirective{Args: args})
		}
		index++
	}
	if pending != "" {
		if args := profileVpnTokenize(pending); len(args) > 0 {
			result = append(result, profileVpnDirective{Args: args})
		}
	}
	return result
}

// profileVpnParseIPv6 is Hosts.parseIpv6: eight groups, `::` at most once, an
// embedded dotted IPv4 in the last group.
func profileVpnParseIPv6(text string) ([16]byte, bool) {
	var out [16]byte
	if text == "" {
		return out, false
	}
	double := strings.Index(text, "::")
	if double >= 0 && strings.Contains(text[double+2:], "::") {
		return out, false
	}
	head := text
	tail := ""
	if double >= 0 {
		head = text[:double]
		tail = text[double+2:]
	}
	headGroups, ok := profileVpnParseIPv6Groups(head)
	if !ok {
		return out, false
	}
	tailGroups, ok := profileVpnParseIPv6Groups(tail)
	if !ok {
		return out, false
	}
	var groups []int
	if double >= 0 {
		if len(headGroups)+len(tailGroups) > 7 {
			return out, false
		}
		groups = append(groups, headGroups...)
		for index := 0; index < 8-len(headGroups)-len(tailGroups); index++ {
			groups = append(groups, 0)
		}
		groups = append(groups, tailGroups...)
	} else {
		if len(headGroups) != 8 {
			return out, false
		}
		groups = headGroups
	}
	for index := 0; index < 8; index++ {
		out[2*index] = byte(groups[index] >> 8)
		out[2*index+1] = byte(groups[index])
	}
	return out, true
}

func profileVpnParseIPv6Groups(part string) ([]int, bool) {
	if part == "" {
		return []int{}, true
	}
	items := strings.Split(part, ":")
	out := make([]int, 0, len(items)+1)
	for index, item := range items {
		if item == "" {
			return nil, false
		}
		if index == len(items)-1 && strings.Contains(item, ".") {
			value, ok := configHostsParseIPv4(item)
			if !ok {
				return nil, false
			}
			out = append(out, int((value>>16)&0xFFFF), int(value&0xFFFF))
			continue
		}
		if len(item) > 4 {
			return nil, false
		}
		value := 0
		for charIndex := 0; charIndex < len(item); charIndex++ {
			char := item[charIndex]
			if char >= 0x80 {
				return nil, false
			}
			digit, ok := configHexDigit(char)
			if !ok {
				return nil, false
			}
			value = value*16 + digit
		}
		out = append(out, value)
	}
	return out, true
}

// profileVpnParseHostAddressV6 is VpnFileImport's QHostAddress path for a
// string containing ':': the 16 bytes and the scope id after the last '%'.
func profileVpnParseHostAddressV6(text string) ([16]byte, string, bool) {
	simplified := profileVpnSimplified(text)
	if simplified == "" {
		return [16]byte{}, "", false
	}
	percent := strings.LastIndex(simplified, "%")
	scope := ""
	address := simplified
	if percent >= 0 {
		scope = simplified[percent+1:]
		address = simplified[:percent]
	}
	bytes, ok := profileVpnParseIPv6(address)
	return bytes, scope, ok
}

// profileVpnNetmaskPrefixLength is QNetmask::setAddress: the prefix length of
// an IP-style netmask, valid only while it is 1s followed by 0s.
func profileVpnNetmaskPrefixLength(text string) (int, bool) {
	simplified := profileVpnSimplified(text)
	var bytes []byte
	if strings.Contains(simplified, ":") {
		parsed, _, ok := profileVpnParseHostAddressV6(simplified)
		if !ok {
			return 0, false
		}
		bytes = parsed[:]
	} else {
		value, ok := configHostsParseIPv4(simplified)
		if !ok {
			return 0, false
		}
		bytes = []byte{byte(value >> 24), byte(value >> 16), byte(value >> 8), byte(value)}
	}
	netmask := 0
	index := 0
	for index < len(bytes) {
		current := int(bytes[index])
		if current == 255 {
			netmask += 8
			index++
			continue
		}
		switch current {
		case 254:
			netmask += 7
		case 252:
			netmask += 6
		case 248:
			netmask += 5
		case 240:
			netmask += 4
		case 224:
			netmask += 3
		case 192:
			netmask += 2
		case 128:
			netmask += 1
		case 0:
		default:
			return 0, false
		}
		break
	}
	index++
	for index < len(bytes) {
		if bytes[index] != 0 {
			return 0, false
		}
		index++
	}
	return netmask, true
}

// profileVpnClearBits is clearBits for a 128-bit address: the host bits from
// [start] on are cleared.
func profileVpnClearBits(where []byte, start int) {
	const end = 128
	if start == end {
		return
	}
	mask := (256 - (1 << (8 - (start & 7)))) & 0xFF
	where[start/8] &= byte(mask)
	for index := (start + 7) / 8; index < end/8; index++ {
		where[index] = 0
	}
}

// profileVpnParseSubnet is QHostAddress::parseSubnet: "a.b.c.d/nn",
// "a.b.c.d/m.m.m.m", the short "a.b/nn" forms and "<ipv6>/nn", with the host
// bits cleared. It returns the network text and the prefix length.
func profileVpnParseSubnet(subnet string) (string, int, bool) {
	if subnet == "" {
		return "", 0, false
	}
	slash := strings.Index(subnet, "/")
	netStr := subnet
	if slash != -1 {
		netStr = subnet[:slash]
	}
	netmask := int64(-1)
	isIPv6 := strings.Contains(netStr, ":")
	if slash != -1 {
		rest := subnet[slash+1:]
		if !isIPv6 && strings.Contains(rest, ".") {
			length, ok := profileVpnNetmaskPrefixLength(rest)
			if !ok {
				return "", 0, false
			}
			netmask = int64(length)
		} else {
			value, ok := profileVpnToUInt(rest)
			if !ok {
				return "", 0, false
			}
			netmask = int64(value)
		}
	}
	if isIPv6 {
		if netmask > 128 {
			return "", 0, false
		}
		if netmask < 0 {
			netmask = 128
		}
		bytes, scope, ok := profileVpnParseHostAddressV6(netStr)
		if !ok {
			return "", 0, false
		}
		slice := bytes[:]
		profileVpnClearBits(slice, int(netmask))
		text := configFormatIPv6(bytes)
		if scope != "" {
			text += "%" + scope
		}
		return text, int(netmask), true
	}
	if netmask > 32 {
		return "", 0, false
	}
	parts := strings.Split(netStr, ".")
	if len(parts) > 4 {
		return "", 0, false
	}
	if len(parts) > 0 && parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	address := uint64(0)
	for _, part := range parts {
		value, ok := profileVpnToUInt(part)
		if !ok || value > 255 {
			return "", 0, false
		}
		address = (address << 8) + uint64(value)
	}
	address = (address << (8 * (4 - len(parts)))) & 0xFFFFFFFF
	if netmask == -1 {
		netmask = int64(8 * len(parts))
	} else if netmask == 0 {
		address = 0
	} else if netmask != 32 {
		shift := uint(32 - netmask)
		address &= (0xFFFFFFFF >> shift) << shift
		address &= 0xFFFFFFFF
	}
	return configFormatIPv4(uint32(address)), int(netmask), true
}

// profileVpnPrefix is vpnfiPrefix: parseSubnet takes both the /24 and the
// /255.255.255.0 spelling.
func profileVpnPrefix(address, mask string) string {
	text, length, ok := profileVpnParseSubnet(address + "/" + mask)
	if !ok {
		return ""
	}
	return text + "/" + strconv.Itoa(length)
}

// profileVpnNormalizePrefix is vpnfiNormalizePrefix.
func profileVpnNormalizePrefix(prefix string) string {
	text, length, ok := profileVpnParseSubnet(prefix)
	if !ok {
		return ""
	}
	return text + "/" + strconv.Itoa(length)
}

// profileVpnNormalizeFingerprint is OpenVpnChecks.openVpnNormalizeFingerprint:
// colons and spaces removed, lower-cased.
func profileVpnNormalizeFingerprint(line string) string {
	var out strings.Builder
	for _, char := range line {
		if char == ':' || profileVpnIsSpace(char) {
			continue
		}
		out.WriteRune(unicode.ToLower(char))
	}
	return out.String()
}

// profileVpnFingerprintOK is OpenVpnChecks.openVpnFingerprint: an empty message
// for 64 bare lowercase hex characters.
func profileVpnFingerprintOK(line string) bool {
	hex := profileVpnNormalizeFingerprint(line)
	if hex == "" {
		return true
	}
	if len(hex) != 64 {
		return false
	}
	for index := 0; index < len(hex); index++ {
		char := hex[index]
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}

// profileVpnFingerprint is vpnfiFingerprint: the normalised hex, or "" when the
// value is not a fingerprint.
func profileVpnFingerprint(raw string) string {
	hex := profileVpnNormalizeFingerprint(raw)
	if hex != "" && profileVpnFingerprintOK(hex) {
		return hex
	}
	return ""
}

// profileVpnIsValidDuration is VpnFileImport.isValidDuration:
// Validation.duration(text, Empty.Required).isEmpty().
func profileVpnIsValidDuration(text string) bool {
	return profileVpnDurationMessage(text, false, true, -1) == ""
}

// profileVpnNetwork is vpnfiNetwork.
func profileVpnNetwork(proto string) string {
	lower, ok := profileNewASCIILower(proto)
	if !ok {
		return ""
	}
	switch lower {
	case "udp", "udp4", "udp6", "tcp", "tcp4", "tcp6":
		return lower
	case "tcp-client":
		return "tcp"
	case "tcp4-client":
		return "tcp4"
	case "tcp6-client":
		return "tcp6"
	}
	return ""
}

// profileVpnRouteKeyword is vpnfiRouteKeyword.
func profileVpnRouteKeyword(value string) bool {
	switch value {
	case "vpn_gateway", "net_gateway", "remote_host", "default", "dhcp":
		return true
	}
	return false
}

// profileVpnParseRemote is vpnfiParseRemote: `remote host [port] [proto]` in
// either order.
func profileVpnParseRemote(args []string) profileVpnRemote {
	remote := profileVpnRemote{}
	if len(args) < 2 {
		return remote
	}
	remote.Host = args[1]
	for index := 2; index < len(args) && index < 4; index++ {
		if port, ok := profileVpnToInt(args[index]); ok && port > 0 {
			remote.Port = port
			continue
		}
		if network := profileVpnNetwork(args[index]); network != "" {
			remote.Network = network
		}
	}
	return remote
}

// profileVpnKeyDirection is the `key-direction` / `secret` / `tls-auth`
// direction argument.
func profileVpnKeyDirection(value string) string {
	if value == "1" {
		return "client"
	}
	if value == "0" {
		return "server"
	}
	return ""
}

// profileVpnNote appends one import note. The action reply carries no notes, so
// only the fatal ones change the result; the text is stable English because
// this path has no localisation contract.
func profileVpnNote(notes *[]string, text string) {
	if notes != nil {
		*notes = append(*notes, text)
	}
}

func profileVpnNotef(notes *[]string, format string, args ...any) {
	profileVpnNote(notes, fmt.Sprintf(format, args...))
}

// profileVpnAccept is vpnfiAccept: a non-empty message means the value is
// dropped with a note.
func profileVpnAccept(notes *[]string, key, value, message string) bool {
	if message == "" {
		return true
	}
	profileVpnNotef(notes, "%s: %q was dropped (%s)", key, value, message)
	return false
}

// profileVpnDuration is vpnfiDuration: sing-box wants a duration string where
// `.ovpn` writes bare seconds.
func profileVpnDuration(notes *[]string, key, value string) string {
	trimmed := profileVpnTrimmed(value)
	if profileVpnIsSignedInteger(trimmed) {
		if seconds, err := strconv.ParseInt(trimmed, 10, 64); err == nil && seconds >= 0 {
			if seconds > 0 {
				return strconv.FormatInt(seconds, 10) + "s"
			}
			return ""
		}
	}
	if !profileVpnIsSignedInteger(trimmed) && profileVpnIsValidDuration(value) {
		return value
	}
	profileVpnNotef(notes, "%s: %q is not a duration", key, value)
	return ""
}

// profileVpnDataCiphers is vpnfiDataCiphers: the canonical upper-case names;
// unsupported offers are dropped from the negotiation list.
func profileVpnDataCiphers(notes *[]string, key, value string) []string {
	ciphers := []string{}
	for _, name := range configSplitSkipEmpty(value, ":") {
		upper, ok := profileNewASCIIUpper(profileVpnTrimmed(name))
		if !ok {
			profileVpnAccept(notes, key, name, "the cipher name is not ASCII")
			continue
		}
		// OpenVPN 2.6 marks an optional cipher with '?'; the core takes the bare name.
		upper = strings.TrimPrefix(upper, "?")
		if profileVpnAccept(notes, key, name, profileOpenVPNCipherNameMessage(upper)) {
			ciphers = append(ciphers, upper)
		}
	}
	return ciphers
}

// --- OpenVPN stored model ---------------------------------------------------

// profileOpenVPNControlWrap is OpenVPNControlWrap.
type profileOpenVPNControlWrap struct {
	Kind      string
	Key       []string
	KeyPath   string
	Direction string
}

// profileOpenVPNTLS is OpenVPNTls (the endpoint's own TLS block, not the
// sing-box one).
type profileOpenVPNTLS struct {
	ServerName            string
	ServerNameType        string
	Certificate           []string
	CertificatePath       string
	ClientCertificate     []string
	ClientCertificatePath string
	ClientKey             []string
	ClientKeyPath         string
	PeerFingerprint       []string
	CRLPath               string
	RemoteCertificateKU   []string
	RemoteCertificateEKU  string
	RemoteCertificateTLS  string
	CertificateProfile    string
	NSCertificateType     string
	VersionMin            string
	VersionMax            string
	Cipher                string
	Groups                string
	ControlWrap           profileOpenVPNControlWrap
}

// profileOpenVPNPullFilter is OpenVPNPullFilter.
type profileOpenVPNPullFilter struct {
	Action string
	Text   string
}

// profileOpenVPN is the stored OpenVPN profile. Field defaults follow the
// Kotlin model's initialisers (only_advertised_routes true, tunnel_dns
// "prefer", otp_profile_id -1).
type profileOpenVPN struct {
	Type   string
	Name   string
	Server string
	Port   int

	Dial map[string]any // flat dial fields, already canonical

	Network              string
	Username             string
	Password             string
	StaticChallenge      string
	StaticChallengeEcho  bool
	MTU                  int
	TLS                  profileOpenVPNTLS
	OTPProfileID         int
	OnlyAdvertisedRoutes bool
	TunnelDNS            string

	Mode                string
	Servers             []profileOpenVPNRemoteStored
	RemoteRandom        bool
	Address             []string
	PeerAddress         string
	PeerAddressIPv6     string
	Topology            string
	AuthRetry           string
	StaticKey           []string
	StaticKeyPath       string
	KeyDirection        string
	Cipher              string
	DataCiphers         []string
	DataCiphersFallback string
	Auth                string
	MSSFix              int
	MSSFixDisabled      bool
	MSSFixMode          string
	Fragment            int
	ReplayWindow        int
	ReplayWindowTime    string
	Compression         string
	CompressionLZO      string
	AllowCompression    string
	RouteNoPull         bool
	PullFilters         []profileOpenVPNPullFilter
	Routes              []string
	RouteGateway        string
	RouteMetric         int
	RedirectGateway     bool
	RedirectGWFlags     []string
	RedirectPrivate     bool
	BlockIPv6           bool
	PingInterval        string
	PingRestart         string
	PingRestartDisabled bool
	RenegotiateInterval string
	RenegotiateDisabled bool
	RenegotiateBytes    int64
	RenegotiatePackets  int64
	TLSTimeout          string
	HandshakeWindow     string
	ExplicitExitNotify  int
	System              bool
	InterfaceName       string
	UDPTimeout          string
	UDPMapping          string
	UDPFiltering        string
	UDPNATMax           int
}

// profileOpenVPNRemoteStored is OpenVPNRemote::ParseFromJson/ExportToJson.
type profileOpenVPNRemoteStored struct {
	Server     string
	Port       int
	Network    string
	HasServer  bool
	HasPort    bool
	HasNetwork bool
}

// profileOpenVPNFieldKeys is the stored key set OpenVpn.parseFromJson reads.
// A key outside it is a refusal: Kotlin ignores unknown keys, so this slice
// cannot promise to reproduce such a document.
var profileOpenVPNFieldKeys = map[string]bool{
	// Outbound + DialFields.
	"type": true, "tag": true, "server": true, "server_port": true,
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true,
	"tcp_multi_path": true, "udp_fragment": true, "bind_interface": true,
	"inet4_bind_address": true, "inet6_bind_address": true,
	// OpenVpn.
	"mode": true, "network": true, "servers": true, "remote_random": true,
	"address": true, "peer_address": true, "peer_address_ipv6": true,
	"topology": true, "username": true, "password": true, "auth_retry": true,
	"static_challenge": true, "static_challenge_echo": true, "static_key": true,
	"static_key_path": true, "key_direction": true, "tls": true, "cipher": true,
	"data_ciphers": true, "data_ciphers_fallback": true, "auth": true,
	"mss_fix": true, "mss_fix_disabled": true, "mss_fix_mode": true,
	"fragment": true, "replay_window": true, "replay_window_time": true,
	"compression": true, "compression_lzo": true, "allow_compression": true,
	"route_no_pull": true, "pull_filters": true, "routes": true,
	"route_gateway": true, "route_metric": true, "redirect_gateway": true,
	"redirect_gateway_flags": true, "redirect_private": true, "block_ipv6": true,
	"ping_interval": true, "ping_restart": true, "ping_restart_disabled": true,
	"renegotiate_interval": true, "renegotiate_disabled": true,
	"renegotiate_bytes": true, "renegotiate_packets": true, "tls_timeout": true,
	"handshake_window": true, "explicit_exit_notify": true, "system": true,
	"name": true, "mtu": true, "udp_timeout": true, "udp_mapping": true,
	"udp_filtering": true, "udp_nat_max": true,
	// Throne-only round-trip fields and the two pre-mode checkboxes.
	"otp_profile_id": true, "only_advertised_routes": true, "tunnel_dns": true,
	"block_outside_dns": true, "use_tunnel_dns": true,
}

var profileOpenVPNTLSFieldKeys = map[string]bool{
	"server_name": true, "server_name_type": true, "certificate": true,
	"certificate_path": true, "client_certificate": true,
	"client_certificate_path": true, "client_key": true,
	"client_key_path": true, "peer_fingerprint": true, "crl_path": true,
	"remote_certificate_ku": true, "remote_certificate_eku": true,
	"remote_certificate_tls": true, "certificate_profile": true,
	"ns_certificate_type": true, "version_min": true, "version_max": true,
	"cipher": true, "groups": true, "control_wrap": true,
}

var profileOpenVPNControlWrapKeys = map[string]bool{
	"type": true, "key": true, "key_path": true, "direction": true,
}

var profileOpenVPNRemoteKeys = map[string]bool{
	"server": true, "server_port": true, "network": true,
}

var profileOpenVPNPullFilterKeys = map[string]bool{"action": true, "text": true}

// newProfileOpenVPN returns the Kotlin model's default state.
func newProfileOpenVPN() *profileOpenVPN {
	return &profileOpenVPN{
		Type: "openvpn", OTPProfileID: -1, OnlyAdvertisedRoutes: true,
		TunnelDNS: "prefer", Dial: map[string]any{},
	}
}

// profileVpnListable is VpnFileImport.listable: a bare string is split on
// newlines with empty pieces dropped; an array maps every item to a string
// (non-string items become "").
func profileVpnListable(value any) []string {
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
	return nil
}

// profileVpnStoredString reads a stored string key strictly: a non-string value
// is a refusal (Kotlin would read "" and keep going, which this slice cannot
// tell apart from an intentional empty value).
func profileVpnStoredString(object map[string]any, key, rawType string) (string, bool, error) {
	raw, present := object[key]
	if !present {
		return "", false, nil
	}
	text, ok := raw.(string)
	if !ok {
		return "", false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
	}
	return text, true, nil
}

// profileVpnStoredBool is the strict boolean reader.
func profileVpnStoredBool(object map[string]any, key, rawType string) (bool, bool, error) {
	raw, present := object[key]
	if !present {
		return false, false, nil
	}
	value, ok := raw.(bool)
	if !ok {
		return false, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
	}
	return value, true, nil
}

// profileVpnStoredNumber is JsonObject.int / JsonObject.integer: a whole number
// (or a whole-valued double) that fits the target width.
func profileVpnStoredNumber(object map[string]any, key, rawType string, asInt bool) (int64, bool, error) {
	raw, present := object[key]
	if !present {
		return 0, false, nil
	}
	switch raw.(type) {
	case int64, float64:
	default:
		return 0, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
	}
	if asInt {
		return int64(configJSONInt(raw)), true, nil
	}
	return configJSONInteger(raw), true, nil
}

// profileVpnStoredListable reads a listable key. A present non-string,
// non-array value is a refusal.
func profileVpnStoredListable(object map[string]any, key, rawType string) ([]string, bool, error) {
	raw, present := object[key]
	if !present {
		return nil, false, nil
	}
	switch raw.(type) {
	case string, []any:
		return profileVpnListable(raw), true, nil
	}
	return nil, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
}

// profileVpnDialFields reads the flat dial keys with the stored-row semantics
// (no import drops); the import gate drops invalid optional values exactly like
// DialFields.parseFromJson with ParseDiag active.
func profileVpnDialFields(object map[string]any, rawType string, importing bool) (map[string]any, error) {
	fields := map[string]any{}
	for _, key := range []string{"reuse_addr", "tcp_fast_open", "tcp_multi_path", "udp_fragment"} {
		value, present, err := profileVpnStoredBool(object, key, rawType)
		if err != nil {
			return nil, err
		}
		if present && value {
			fields[key] = true
		}
	}
	if value, present, err := profileVpnStoredString(object, "connect_timeout", rawType); err != nil {
		return nil, err
	} else if present {
		trimmed := profileVpnTrimmed(value)
		if !importing || profileVpnDurationMessage(trimmed, false, false, -1) == "" {
			fields["connect_timeout"] = trimmed
		}
	}
	if value, present, err := profileVpnStoredString(object, "bind_interface", rawType); err != nil {
		return nil, err
	} else if present && value != "" {
		fields["bind_interface"] = value
	}
	for _, key := range []string{"inet4_bind_address", "inet6_bind_address"} {
		value, present, err := profileVpnStoredString(object, key, rawType)
		if err != nil {
			return nil, err
		}
		if !present {
			continue
		}
		trimmed := profileVpnTrimmed(value)
		if trimmed == "" {
			continue
		}
		family := 6
		if key == "inet4_bind_address" {
			family = 4
		}
		if importing && !profileVpnIPOK(trimmed, family, false) {
			continue
		}
		fields[key] = trimmed
	}
	return fields, nil
}

// profileOpenVPNParseStored is OpenVpn.parseFromJson plus the base and dial
// readers. `mode` decides whether the import-only optional drops apply.
func profileOpenVPNParseStored(object map[string]any, mode profileNewMode) (*profileOpenVPN, []string, error) {
	importing := mode == profileNewImportMode
	rawType := configJSONString(object, "type")
	canonical := rawType
	if canonical == "openvpn-client" {
		canonical = "openvpn"
	}
	if canonical != "openvpn" {
		return nil, nil, profileUnsupported("stored document is not openvpn")
	}
	model := newProfileOpenVPN()

	var unknown []string
	for key := range object {
		if !profileOpenVPNFieldKeys[key] {
			unknown = append(unknown, key)
		}
	}

	if value, present, err := profileVpnStoredString(object, "tag", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Name = value
	}
	if value, present, err := profileVpnStoredString(object, "server", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Server = aceShareHost(value)
	}
	if value, present, err := profileVpnStoredNumber(object, "server_port", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		model.Port = int(value)
	}
	dial, err := profileVpnDialFields(object, canonical, importing)
	if err != nil {
		return nil, nil, err
	}
	model.Dial = dial

	readChecked := func(key, current string, rule func(string) bool) (string, error) {
		value, present, err := profileVpnStoredString(object, key, canonical)
		if err != nil {
			return "", err
		}
		if !present {
			return current, nil
		}
		trimmed := profileVpnTrimmed(value)
		if !importing || rule(trimmed) {
			return trimmed, nil
		}
		return current, nil
	}

	if value, present, err := profileVpnStoredString(object, "mode", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Mode = profileVpnTrimmed(value)
	}
	if value, present, err := profileVpnStoredString(object, "network", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Network = profileVpnTrimmed(value)
	}
	if value, present := object["servers"]; present {
		items, ok := value.([]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openvpn servers is not an array")
		}
		model.Servers = nil
		for _, item := range items {
			entry, ok := item.(map[string]any)
			if !ok || len(entry) == 0 {
				// Remote.parseFromJson answers false for an empty/non-object
				// entry, so the remote is not added.
				continue
			}
			for key := range entry {
				if !profileOpenVPNRemoteKeys[key] {
					unknown = append(unknown, "servers."+key)
				}
			}
			remote := profileOpenVPNRemoteStored{}
			if value, present, err := profileVpnStoredString(entry, "server", canonical); err != nil {
				return nil, nil, err
			} else if present {
				remote.Server, remote.HasServer = value, true
			}
			if value, present, err := profileVpnStoredNumber(entry, "server_port", canonical, true); err != nil {
				return nil, nil, err
			} else if present {
				remote.Port, remote.HasPort = int(value), true
			}
			if value, present, err := profileVpnStoredString(entry, "network", canonical); err != nil {
				return nil, nil, err
			} else if present {
				remote.Network, remote.HasNetwork = profileVpnTrimmed(value), true
			}
			model.Servers = append(model.Servers, remote)
		}
	}
	if value, present, err := profileVpnStoredBool(object, "remote_random", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.RemoteRandom = value
	}
	if items, present, err := profileVpnStoredListable(object, "address", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Address = items
	}
	if value, present, err := profileVpnStoredString(object, "peer_address", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.PeerAddress = value
	}
	if value, present, err := profileVpnStoredString(object, "peer_address_ipv6", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.PeerAddressIPv6 = value
	}
	if value, present, err := profileVpnStoredString(object, "topology", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Topology = profileVpnTrimmed(value)
	}
	if value, present, err := profileVpnStoredString(object, "username", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Username = value
	}
	if value, present, err := profileVpnStoredString(object, "password", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Password = value
	}
	if value, present, err := profileVpnStoredString(object, "auth_retry", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.AuthRetry = profileVpnTrimmed(value)
	}
	if value, present, err := profileVpnStoredString(object, "static_challenge", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.StaticChallenge = value
	}
	if value, present, err := profileVpnStoredBool(object, "static_challenge_echo", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.StaticChallengeEcho = value
	}
	if items, present, err := profileVpnStoredListable(object, "static_key", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.StaticKey = items
	}
	if value, present, err := profileVpnStoredString(object, "static_key_path", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.StaticKeyPath = value
	}
	if value, present, err := profileVpnStoredString(object, "key_direction", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.KeyDirection = profileVpnTrimmed(value)
	}
	if value, present := object["tls"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openvpn tls block is not an object")
		}
		tls, tlsUnknown, tlsErr := profileOpenVPNParseTLS(block, canonical, importing)
		if tlsErr != nil {
			return nil, nil, tlsErr
		}
		model.TLS = tls
		unknown = append(unknown, tlsUnknown...)
	} else {
		model.TLS = profileOpenVPNTLS{}
	}
	if value, present, err := profileVpnStoredString(object, "cipher", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Cipher = value
	}
	if items, present, err := profileVpnStoredListable(object, "data_ciphers", canonical); err != nil {
		return nil, nil, err
	} else if present {
		// ovpnKeepItems trims every item and drops the blank ones on both
		// gates; only an import additionally drops the refused names.
		kept := make([]string, 0, len(items))
		for _, raw := range items {
			item := profileVpnTrimmed(raw)
			if item == "" {
				continue
			}
			if importing && profileOpenVPNCipherNameMessage(item) != "" {
				continue
			}
			kept = append(kept, item)
		}
		model.DataCiphers = kept
	}
	if value, err := readChecked("data_ciphers_fallback", model.DataCiphersFallback, func(item string) bool {
		return profileOpenVPNCipherNameMessage(item) == ""
	}); err != nil {
		return nil, nil, err
	} else {
		model.DataCiphersFallback = value
	}
	if value, present, err := profileVpnStoredString(object, "auth", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Auth = value
	}
	if value, present, err := profileVpnStoredNumber(object, "mss_fix", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		model.MSSFix = int(value)
	}
	if value, present, err := profileVpnStoredBool(object, "mss_fix_disabled", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.MSSFixDisabled = value
	}
	if value, present, err := profileVpnStoredString(object, "mss_fix_mode", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.MSSFixMode = profileVpnTrimmed(value)
	}
	if value, present, err := profileVpnStoredNumber(object, "fragment", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		text := strconv.Itoa(int(value))
		if !importing || profileOpenVPNOpenVPNFragmentMessage(text) == "" {
			model.Fragment = int(value)
		}
	}
	if value, present, err := profileVpnStoredNumber(object, "replay_window", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		text := strconv.Itoa(int(value))
		if !importing || profileOpenVPNReplayWindowMessage(text) == "" {
			model.ReplayWindow = int(value)
		}
	}
	if value, err := readChecked("replay_window_time", model.ReplayWindowTime, func(item string) bool {
		return profileOpenVPNReplayWindowTimeMessage(item) == ""
	}); err != nil {
		return nil, nil, err
	} else {
		model.ReplayWindowTime = value
	}
	if value, present, err := profileVpnStoredString(object, "compression", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.Compression = value
	}
	if value, present, err := profileVpnStoredString(object, "compression_lzo", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.CompressionLZO = value
	}
	if value, present, err := profileVpnStoredString(object, "allow_compression", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.AllowCompression = value
	}
	if value, present, err := profileVpnStoredBool(object, "route_no_pull", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.RouteNoPull = value
	}
	if value, present := object["pull_filters"]; present {
		items, ok := value.([]any)
		if !ok {
			return nil, nil, profileUnsupported("stored openvpn pull_filters is not an array")
		}
		model.PullFilters = nil
		for _, item := range items {
			entry, ok := item.(map[string]any)
			if !ok || len(entry) == 0 {
				continue
			}
			for key := range entry {
				if !profileOpenVPNPullFilterKeys[key] {
					unknown = append(unknown, "pull_filters."+key)
				}
			}
			filter := profileOpenVPNPullFilter{}
			if value, present, err := profileVpnStoredString(entry, "action", canonical); err != nil {
				return nil, nil, err
			} else if present {
				filter.Action = profileVpnTrimmed(value)
			}
			if value, present, err := profileVpnStoredString(entry, "text", canonical); err != nil {
				return nil, nil, err
			} else if present {
				filter.Text = value
			}
			model.PullFilters = append(model.PullFilters, filter)
		}
	}
	if items, present, err := profileVpnStoredListable(object, "routes", canonical); err != nil {
		return nil, nil, err
	} else if present {
		kept := make([]string, 0, len(items))
		for _, raw := range items {
			item := profileVpnTrimmed(raw)
			if item == "" {
				continue
			}
			if !importing || profileVpnCIDROK(item) {
				kept = append(kept, item)
			}
		}
		model.Routes = kept
	}
	if value, err := readChecked("route_gateway", model.RouteGateway, func(item string) bool {
		return profileVpnIPOK(item, 0, true)
	}); err != nil {
		return nil, nil, err
	} else {
		model.RouteGateway = value
	}
	if value, present, err := profileVpnStoredNumber(object, "route_metric", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		model.RouteMetric = int(value)
	}
	if value, present, err := profileVpnStoredBool(object, "redirect_gateway", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.RedirectGateway = value
	}
	if items, present, err := profileVpnStoredListable(object, "redirect_gateway_flags", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.RedirectGWFlags = items
	}
	if value, present, err := profileVpnStoredBool(object, "redirect_private", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.RedirectPrivate = value
	}
	if value, present, err := profileVpnStoredBool(object, "block_ipv6", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.BlockIPv6 = value
	}
	if value, err := readChecked("ping_interval", model.PingInterval, func(item string) bool {
		return profileOpenVPNPingIntervalOK(item)
	}); err != nil {
		return nil, nil, err
	} else {
		model.PingInterval = value
	}
	if value, err := readChecked("ping_restart", model.PingRestart, func(item string) bool {
		return profileOpenVPNPingIntervalOK(item)
	}); err != nil {
		return nil, nil, err
	} else {
		model.PingRestart = value
	}
	if value, present, err := profileVpnStoredBool(object, "ping_restart_disabled", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.PingRestartDisabled = value
	}
	if value, err := readChecked("renegotiate_interval", model.RenegotiateInterval, func(item string) bool {
		return profileOpenVPNIntervalOK(item)
	}); err != nil {
		return nil, nil, err
	} else {
		model.RenegotiateInterval = value
	}
	if value, present, err := profileVpnStoredBool(object, "renegotiate_disabled", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.RenegotiateDisabled = value
	}
	if value, present, err := profileVpnStoredNumber(object, "renegotiate_bytes", canonical, false); err != nil {
		return nil, nil, err
	} else if present {
		model.RenegotiateBytes = value
	}
	if value, present, err := profileVpnStoredNumber(object, "renegotiate_packets", canonical, false); err != nil {
		return nil, nil, err
	} else if present {
		model.RenegotiatePackets = value
	}
	if value, err := readChecked("tls_timeout", model.TLSTimeout, func(item string) bool {
		return profileOpenVPNIntervalOK(item)
	}); err != nil {
		return nil, nil, err
	} else {
		model.TLSTimeout = value
	}
	if value, err := readChecked("handshake_window", model.HandshakeWindow, func(item string) bool {
		return profileOpenVPNIntervalOK(item)
	}); err != nil {
		return nil, nil, err
	} else {
		model.HandshakeWindow = value
	}
	if value, present, err := profileVpnStoredNumber(object, "explicit_exit_notify", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		model.ExplicitExitNotify = int(value)
	}
	if value, present, err := profileVpnStoredBool(object, "system", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.System = value
	}
	if value, present, err := profileVpnStoredString(object, "name", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.InterfaceName = value
	}
	if value, present, err := profileVpnStoredNumber(object, "mtu", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		model.MTU = int(value)
	}
	if raw, present := object["udp_timeout"]; present {
		// The core also takes a bare number of seconds here; Throne stores and
		// emits the duration string.
		isNumber := false
		switch raw.(type) {
		case int64, float64:
			isNumber = true
		}
		if isNumber && configJSONInteger(raw) > 0 {
			model.UDPTimeout = strconv.FormatInt(configJSONInteger(raw), 10) + "s"
		} else {
			value, err := readChecked("udp_timeout", model.UDPTimeout, func(item string) bool {
				return profileVpnDurationMessage(item, false, false, -1) == ""
			})
			if err != nil {
				return nil, nil, err
			}
			model.UDPTimeout = value
		}
	}
	if value, present, err := profileVpnStoredString(object, "udp_mapping", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.UDPMapping = value
	}
	if value, present, err := profileVpnStoredString(object, "udp_filtering", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.UDPFiltering = value
	}
	if value, present, err := profileVpnStoredNumber(object, "udp_nat_max", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		model.UDPNATMax = int(value)
	}
	if value, present, err := profileVpnStoredNumber(object, "otp_profile_id", canonical, true); err != nil {
		return nil, nil, err
	} else if present {
		model.OTPProfileID = int(value)
	}
	if value, present, err := profileVpnStoredBool(object, "only_advertised_routes", canonical); err != nil {
		return nil, nil, err
	} else if present {
		model.OnlyAdvertisedRoutes = value
	}
	// Profiles saved before the mode existed carry the two checkboxes it replaced.
	if _, present := object["tunnel_dns"]; present {
		value, _, err := profileVpnStoredString(object, "tunnel_dns", canonical)
		if err != nil {
			return nil, nil, err
		}
		model.TunnelDNS = value
	} else if blockOutside, present, err := profileVpnStoredBool(object, "block_outside_dns", canonical); err != nil {
		return nil, nil, err
	} else if present && blockOutside {
		model.TunnelDNS = "strict"
	} else if useTunnel, present, err := profileVpnStoredBool(object, "use_tunnel_dns", canonical); err != nil {
		return nil, nil, err
	} else if present && !useTunnel {
		model.TunnelDNS = "none"
	}
	return model, unknown, nil
}

// profileOpenVPNParseTLS is OpenVpn.Tls.parseFromJson. The TLS cipher suites
// and groups pass OpenVpnChecks on import.
func profileOpenVPNParseTLS(block map[string]any, rawType string, importing bool) (profileOpenVPNTLS, []string, error) {
	tls := profileOpenVPNTLS{}
	var unknown []string
	for key := range block {
		if !profileOpenVPNTLSFieldKeys[key] {
			unknown = append(unknown, "tls."+key)
		}
	}
	readString := func(key string, target *string, trim bool) error {
		value, present, err := profileVpnStoredString(block, key, rawType)
		if err != nil {
			return err
		}
		if !present {
			return nil
		}
		if trim {
			*target = profileVpnTrimmed(value)
		} else {
			*target = value
		}
		return nil
	}
	readList := func(key string, target *[]string) error {
		items, present, err := profileVpnStoredListable(block, key, rawType)
		if err != nil {
			return err
		}
		if present {
			*target = items
		}
		return nil
	}
	if err := readString("server_name", &tls.ServerName, false); err != nil {
		return tls, nil, err
	}
	if err := readString("server_name_type", &tls.ServerNameType, true); err != nil {
		return tls, nil, err
	}
	if err := readList("certificate", &tls.Certificate); err != nil {
		return tls, nil, err
	}
	if err := readString("certificate_path", &tls.CertificatePath, false); err != nil {
		return tls, nil, err
	}
	if err := readList("client_certificate", &tls.ClientCertificate); err != nil {
		return tls, nil, err
	}
	if err := readString("client_certificate_path", &tls.ClientCertificatePath, false); err != nil {
		return tls, nil, err
	}
	if err := readList("client_key", &tls.ClientKey); err != nil {
		return tls, nil, err
	}
	if err := readString("client_key_path", &tls.ClientKeyPath, false); err != nil {
		return tls, nil, err
	}
	if err := readList("peer_fingerprint", &tls.PeerFingerprint); err != nil {
		return tls, nil, err
	}
	if err := readString("crl_path", &tls.CRLPath, false); err != nil {
		return tls, nil, err
	}
	if err := readList("remote_certificate_ku", &tls.RemoteCertificateKU); err != nil {
		return tls, nil, err
	}
	if err := readString("remote_certificate_eku", &tls.RemoteCertificateEKU, false); err != nil {
		return tls, nil, err
	}
	if err := readString("remote_certificate_tls", &tls.RemoteCertificateTLS, true); err != nil {
		return tls, nil, err
	}
	if err := readString("certificate_profile", &tls.CertificateProfile, true); err != nil {
		return tls, nil, err
	}
	if err := readString("ns_certificate_type", &tls.NSCertificateType, true); err != nil {
		return tls, nil, err
	}
	if err := readString("version_min", &tls.VersionMin, true); err != nil {
		return tls, nil, err
	}
	if err := readString("version_max", &tls.VersionMax, true); err != nil {
		return tls, nil, err
	}
	// Without them the core's default suites and groups apply.
	readCheckedTLS := func(key, current string, rule func(string) bool) (string, error) {
		value, present, err := profileVpnStoredString(block, key, rawType)
		if err != nil {
			return "", err
		}
		if !present {
			return current, nil
		}
		trimmed := profileVpnTrimmed(value)
		if !importing || rule(trimmed) {
			return trimmed, nil
		}
		return current, nil
	}
	if value, err := readCheckedTLS("cipher", tls.Cipher, func(item string) bool {
		return profileOpenVPNTLSCipherMessage(item) == ""
	}); err != nil {
		return tls, nil, err
	} else {
		tls.Cipher = value
	}
	if value, err := readCheckedTLS("groups", tls.Groups, func(item string) bool {
		return profileOpenVPNTLSGroupsMessage(item) == ""
	}); err != nil {
		return tls, nil, err
	} else {
		tls.Groups = value
	}
	if value, present := block["control_wrap"]; present {
		entry, ok := value.(map[string]any)
		if !ok {
			return tls, nil, profileUnsupported("stored openvpn tls.control_wrap is not an object")
		}
		wrap := profileOpenVPNControlWrap{}
		if len(entry) > 0 {
			for key := range entry {
				if !profileOpenVPNControlWrapKeys[key] {
					unknown = append(unknown, "tls.control_wrap."+key)
				}
			}
			if value, present, err := profileVpnStoredString(entry, "type", rawType); err != nil {
				return tls, nil, err
			} else if present {
				wrap.Kind = profileVpnTrimmed(value)
			}
			if items, present, err := profileVpnStoredListable(entry, "key", rawType); err != nil {
				return tls, nil, err
			} else if present {
				wrap.Key = items
			}
			if value, present, err := profileVpnStoredString(entry, "key_path", rawType); err != nil {
				return tls, nil, err
			} else if present {
				wrap.KeyPath = value
			}
			if value, present, err := profileVpnStoredString(entry, "direction", rawType); err != nil {
				return tls, nil, err
			} else if present {
				wrap.Direction = profileVpnTrimmed(value)
			}
		}
		tls.ControlWrap = wrap
	}
	return tls, unknown, nil
}

// profileVpnStringArray is JsonValues.stringArray: blank items are dropped.
func profileVpnStringArray(items []string) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		if profileVpnTrimmed(item) == "" {
			continue
		}
		out = append(out, item)
	}
	return out
}

// profileOpenVPNExportJSON is OpenVpn.exportToJson.
func profileOpenVPNExportJSON(model *profileOpenVPN) map[string]any {
	object := map[string]any{"type": "openvpn"}
	if model.Name != "" {
		object["tag"] = model.Name
	}
	if model.Server != "" {
		object["server"] = model.Server
	}
	if model.Port > 0 {
		object["server_port"] = model.Port
	}
	for key, value := range model.Dial {
		object[key] = value
	}
	if model.Mode != "" {
		object["mode"] = model.Mode
	}
	if model.Network != "" {
		object["network"] = model.Network
	}
	if len(model.Servers) > 0 {
		remotes := make([]any, 0, len(model.Servers))
		for _, remote := range model.Servers {
			item := profileOpenVPNRemoteStoredJSON(remote)
			if len(item) > 0 {
				remotes = append(remotes, item)
			}
		}
		if len(remotes) > 0 {
			object["servers"] = remotes
		}
	}
	if model.RemoteRandom {
		object["remote_random"] = true
	}
	if len(model.Address) > 0 {
		object["address"] = profileVpnStringArray(model.Address)
	}
	if model.PeerAddress != "" {
		object["peer_address"] = model.PeerAddress
	}
	if model.PeerAddressIPv6 != "" {
		object["peer_address_ipv6"] = model.PeerAddressIPv6
	}
	if model.Topology != "" {
		object["topology"] = model.Topology
	}
	if model.Username != "" {
		object["username"] = model.Username
	}
	if model.Password != "" {
		object["password"] = model.Password
	}
	if model.AuthRetry != "" {
		object["auth_retry"] = model.AuthRetry
	}
	if model.StaticChallenge != "" {
		object["static_challenge"] = model.StaticChallenge
	}
	if model.StaticChallengeEcho {
		object["static_challenge_echo"] = true
	}
	if len(model.StaticKey) > 0 {
		object["static_key"] = profileVpnStringArray(model.StaticKey)
	}
	if model.StaticKeyPath != "" {
		object["static_key_path"] = model.StaticKeyPath
	}
	if model.KeyDirection != "" {
		object["key_direction"] = model.KeyDirection
	}
	if tls := profileOpenVPNTLSJSON(model.TLS); len(tls) > 0 {
		object["tls"] = tls
	}
	if model.Cipher != "" {
		object["cipher"] = model.Cipher
	}
	if len(model.DataCiphers) > 0 {
		object["data_ciphers"] = profileVpnStringArray(model.DataCiphers)
	}
	if model.DataCiphersFallback != "" {
		object["data_ciphers_fallback"] = model.DataCiphersFallback
	}
	if model.Auth != "" {
		object["auth"] = model.Auth
	}
	if model.MSSFix > 0 {
		object["mss_fix"] = model.MSSFix
	}
	if model.MSSFixDisabled {
		object["mss_fix_disabled"] = true
	}
	if model.MSSFixMode != "" {
		object["mss_fix_mode"] = model.MSSFixMode
	}
	if model.Fragment > 0 {
		object["fragment"] = model.Fragment
	}
	if model.ReplayWindow > 0 {
		object["replay_window"] = model.ReplayWindow
	}
	if model.ReplayWindowTime != "" {
		object["replay_window_time"] = model.ReplayWindowTime
	}
	if model.Compression != "" {
		object["compression"] = model.Compression
	}
	if model.CompressionLZO != "" {
		object["compression_lzo"] = model.CompressionLZO
	}
	if model.AllowCompression != "" {
		object["allow_compression"] = model.AllowCompression
	}
	if model.RouteNoPull {
		object["route_no_pull"] = true
	}
	if len(model.PullFilters) > 0 {
		filters := make([]any, 0, len(model.PullFilters))
		for _, filter := range model.PullFilters {
			item := profileOpenVPNPullFilterJSON(filter)
			if len(item) > 0 {
				filters = append(filters, item)
			}
		}
		if len(filters) > 0 {
			object["pull_filters"] = filters
		}
	}
	if len(model.Routes) > 0 {
		object["routes"] = profileVpnStringArray(model.Routes)
	}
	if model.RouteGateway != "" {
		object["route_gateway"] = model.RouteGateway
	}
	if model.RouteMetric > 0 {
		object["route_metric"] = model.RouteMetric
	}
	if model.RedirectGateway {
		object["redirect_gateway"] = true
	}
	if len(model.RedirectGWFlags) > 0 {
		object["redirect_gateway_flags"] = profileVpnStringArray(model.RedirectGWFlags)
	}
	if model.RedirectPrivate {
		object["redirect_private"] = true
	}
	if model.BlockIPv6 {
		object["block_ipv6"] = true
	}
	if model.PingInterval != "" {
		object["ping_interval"] = model.PingInterval
	}
	if model.PingRestart != "" {
		object["ping_restart"] = model.PingRestart
	}
	if model.PingRestartDisabled {
		object["ping_restart_disabled"] = true
	}
	if model.RenegotiateInterval != "" {
		object["renegotiate_interval"] = model.RenegotiateInterval
	}
	if model.RenegotiateDisabled {
		object["renegotiate_disabled"] = true
	}
	if model.RenegotiateBytes > 0 {
		object["renegotiate_bytes"] = model.RenegotiateBytes
	}
	if model.RenegotiatePackets > 0 {
		object["renegotiate_packets"] = model.RenegotiatePackets
	}
	if model.TLSTimeout != "" {
		object["tls_timeout"] = model.TLSTimeout
	}
	if model.HandshakeWindow != "" {
		object["handshake_window"] = model.HandshakeWindow
	}
	if model.ExplicitExitNotify > 0 {
		object["explicit_exit_notify"] = model.ExplicitExitNotify
	}
	if model.System {
		object["system"] = true
	}
	if model.InterfaceName != "" {
		object["name"] = model.InterfaceName
	}
	if model.MTU > 0 {
		object["mtu"] = model.MTU
	}
	if model.UDPTimeout != "" {
		object["udp_timeout"] = model.UDPTimeout
	}
	if model.UDPMapping != "" {
		object["udp_mapping"] = model.UDPMapping
	}
	if model.UDPFiltering != "" {
		object["udp_filtering"] = model.UDPFiltering
	}
	if model.UDPNATMax > 0 {
		object["udp_nat_max"] = model.UDPNATMax
	}
	if model.OTPProfileID >= 0 {
		object["otp_profile_id"] = model.OTPProfileID
	}
	object["only_advertised_routes"] = model.OnlyAdvertisedRoutes
	object["tunnel_dns"] = model.TunnelDNS
	return object
}

// profileOpenVPNRemoteStoredJSON is OpenVPNRemote::ExportToJson.
func profileOpenVPNRemoteStoredJSON(remote profileOpenVPNRemoteStored) map[string]any {
	object := map[string]any{}
	if remote.Server != "" {
		object["server"] = remote.Server
	}
	if remote.Port > 0 {
		object["server_port"] = remote.Port
	}
	if remote.Network != "" {
		object["network"] = remote.Network
	}
	return object
}

// profileOpenVPNPullFilterJSON is OpenVPNPullFilter::ExportToJson.
func profileOpenVPNPullFilterJSON(filter profileOpenVPNPullFilter) map[string]any {
	object := map[string]any{}
	if filter.Action == "" && filter.Text == "" {
		return object
	}
	object["action"] = filter.Action
	object["text"] = filter.Text
	return object
}

// profileOpenVPNTLSJSON is OpenVpn.Tls.exportToJson.
func profileOpenVPNTLSJSON(tls profileOpenVPNTLS) map[string]any {
	object := map[string]any{}
	if tls.ServerName != "" {
		object["server_name"] = tls.ServerName
	}
	if tls.ServerNameType != "" {
		object["server_name_type"] = tls.ServerNameType
	}
	if len(tls.Certificate) > 0 {
		object["certificate"] = profileVpnStringArray(tls.Certificate)
	}
	if tls.CertificatePath != "" {
		object["certificate_path"] = tls.CertificatePath
	}
	if len(tls.ClientCertificate) > 0 {
		object["client_certificate"] = profileVpnStringArray(tls.ClientCertificate)
	}
	if tls.ClientCertificatePath != "" {
		object["client_certificate_path"] = tls.ClientCertificatePath
	}
	if len(tls.ClientKey) > 0 {
		object["client_key"] = profileVpnStringArray(tls.ClientKey)
	}
	if tls.ClientKeyPath != "" {
		object["client_key_path"] = tls.ClientKeyPath
	}
	if len(tls.PeerFingerprint) > 0 {
		object["peer_fingerprint"] = profileVpnStringArray(tls.PeerFingerprint)
	}
	if tls.CRLPath != "" {
		object["crl_path"] = tls.CRLPath
	}
	if len(tls.RemoteCertificateKU) > 0 {
		object["remote_certificate_ku"] = profileVpnStringArray(tls.RemoteCertificateKU)
	}
	if tls.RemoteCertificateEKU != "" {
		object["remote_certificate_eku"] = tls.RemoteCertificateEKU
	}
	if tls.RemoteCertificateTLS != "" {
		object["remote_certificate_tls"] = tls.RemoteCertificateTLS
	}
	if tls.CertificateProfile != "" {
		object["certificate_profile"] = tls.CertificateProfile
	}
	if tls.NSCertificateType != "" {
		object["ns_certificate_type"] = tls.NSCertificateType
	}
	if tls.VersionMin != "" {
		object["version_min"] = tls.VersionMin
	}
	if tls.VersionMax != "" {
		object["version_max"] = tls.VersionMax
	}
	if tls.Cipher != "" {
		object["cipher"] = tls.Cipher
	}
	if tls.Groups != "" {
		object["groups"] = tls.Groups
	}
	if wrap := profileOpenVPNControlWrapJSON(tls.ControlWrap); len(wrap) > 0 {
		object["control_wrap"] = wrap
	}
	return object
}

// profileOpenVPNControlWrapJSON is OpenVPNControlWrap::ExportToJson: an empty
// type drops the whole object.
func profileOpenVPNControlWrapJSON(wrap profileOpenVPNControlWrap) map[string]any {
	object := map[string]any{}
	if wrap.Kind == "" {
		return object
	}
	object["type"] = wrap.Kind
	if len(wrap.Key) > 0 {
		object["key"] = profileVpnStringArray(wrap.Key)
	}
	if wrap.KeyPath != "" {
		object["key_path"] = wrap.KeyPath
	}
	if wrap.Direction != "" {
		object["direction"] = wrap.Direction
	}
	return object
}

// profileOpenVPNNode builds the action's imported node from the model: the
// stored JSON, identity (base Outbound.exportIdentity: server/port only, since
// the endpoint's TLS block is not sing-box TLS), the dial-query link and the
// dedup key.
func profileOpenVPNNode(model *profileOpenVPN) (*profileImportedNode, error) {
	stored, err := MarshalCanonicalJSON(profileOpenVPNExportJSON(model))
	if err != nil {
		return nil, err
	}
	withoutTag := *model
	withoutTag.Name = ""
	dedup, err := MarshalCanonicalJSON(profileOpenVPNExportJSON(&withoutTag))
	if err != nil {
		return nil, err
	}
	identity := string(stored)
	if model.Server != "" {
		encoded, encodeErr := MarshalCanonicalJSON(map[string]any{
			"server": model.Server, "server_port": model.Port,
		})
		if encodeErr != nil {
			return nil, encodeErr
		}
		identity = string(encoded)
	}
	return &profileImportedNode{
		Type:     "openvpn",
		Name:     model.Name,
		JSON:     string(stored),
		Link:     profileOpenVPNDialQueryLink(model),
		Identity: identity,
		DedupKey: "throne://add/" + profileBase64Encode(dedup, true, false),
	}, nil
}

// profileOpenVPNDialQueryLink is Outbound.exportToLink for a type with no
// override: LinkBuilder.formatQuery(dial.exportToLink()).
func profileOpenVPNDialQueryLink(model *profileOpenVPN) string {
	return profileStoredFormatQuery(profileOpenVPNDialQuery(model))
}

// profileOpenVPNDialQuery is DialFields.exportToLink in its fixed order.
func profileOpenVPNDialQuery(model *profileOpenVPN) []profileStoredQueryItem {
	query := []profileStoredQueryItem{}
	if configJSONBool(model.Dial, "reuse_addr") {
		query = append(query, profileStoredQueryItem{key: "reuse_addr", value: "true"})
	}
	if value := configJSONString(model.Dial, "connect_timeout"); value != "" {
		query = append(query, profileStoredQueryItem{key: "connect_timeout", value: value})
	}
	for _, key := range []string{"tcp_fast_open", "tcp_multi_path", "udp_fragment"} {
		if configJSONBool(model.Dial, key) {
			query = append(query, profileStoredQueryItem{key: key, value: "true"})
		}
	}
	for _, key := range []string{"bind_interface", "inet4_bind_address", "inet6_bind_address"} {
		if value := configJSONString(model.Dial, key); value != "" {
			query = append(query, profileStoredQueryItem{key: key, value: value})
		}
	}
	return query
}

// --- OpenVPN profile parser (ParseOvpnConfig) -------------------------------

// profileOpenVPNIgnored is vpnfiOvpnIgnored: no endpoint equivalent, or the
// endpoint already behaves this way.
var profileOpenVPNIgnored = map[string]bool{
	"allow-recursive-routing": true, "auth-nocache": true, "auth-token": true,
	"auth-token-user": true, "bind": true, "block-outside-dns": true,
	"client": true, "connect-retry": true, "connect-retry-max": true,
	"connect-timeout": true, "daemon": true, "dco": true, "dev-node": true,
	"dh": true, "dhcp-option": true, "dhcp-release": true, "dhcp-renew": true,
	"disable-dco": true, "down": true, "down-pre": true, "echo": true,
	"errors-to-stderr": true, "fast-io": true, "float": true, "group": true,
	"hash-size": true, "ifconfig-noexec": true, "ifconfig-nowarn": true,
	"ipchange": true, "key-method": true, "log": true, "log-append": true,
	"lport": true, "machine-readable-output": true, "max-routes": true,
	"mode": true, "mssfix-default": true, "mtu-disc": true, "mtu-test": true,
	"multihome": true, "mute": true, "mute-replay-warnings": true,
	"ncp-disable": true, "nice": true, "nobind": true, "opt-verify": true,
	"passtos": true, "persist-key": true, "persist-local-ip": true,
	"persist-remote-ip": true, "persist-tun": true, "ping-timer-rem": true,
	"pull": true, "push-peer-info": true, "rcvbuf": true, "register-dns": true,
	"remap-usr1": true, "remote-random-hostname": true, "resolv-retry": true,
	"route-delay": true, "route-method": true, "route-pre-down": true,
	"route-up": true, "script-security": true, "server-poll-timeout": true,
	"service": true, "setenv-safe": true, "single-session": true, "sndbuf": true,
	"socket-flags": true, "status": true, "suppress-timestamps": true,
	"syslog": true, "tls-client": true, "tls-exit": true, "tls-verify": true,
	"topology-subnet": true, "tran-window": true, "tun-mtu-extra": true,
	"txqueuelen": true, "up": true, "up-delay": true, "up-restart": true,
	"user": true, "verb": true, "windows-driver": true, "writepid": true,
}

// profileOpenVPNUnsupported is vpnfiOvpnUnsupported: recognised, but nothing in
// the endpoint carries them.
var profileOpenVPNUnsupported = map[string]bool{
	"askpass": true, "capath": true, "cryptoapicert": true, "engine": true,
	"extra-certs": true, "http-proxy": true, "http-proxy-option": true,
	"inactive": true, "link-mtu": true, "management": true,
	"management-hold": true, "management-query-passwords": true,
	"no-replay": true, "ping-exit": true, "pkcs11-id": true,
	"pkcs11-providers": true, "providers": true, "socks-proxy": true,
	"tls-ciphersuites": true, "tls-crypt-v2-verify": true,
	"tls-export-cert": true, "x509-track": true, "x509-username-field": true,
}

// profileOpenVPNServerOnly is vpnfiOvpnServerOnly.
var profileOpenVPNServerOnly = map[string]bool{
	"client-config-dir": true, "ifconfig-pool": true, "push": true,
	"server": true, "server-bridge": true, "tls-server": true,
}

// profileOpenVPNParseConfig is ParseOvpnConfig (vpnFileImport.cpp) applied to
// [model]. Notes are appended to [notes]; a fatal problem appends its reason
// last and returns false. The action reply carries no notes, so only the fatal
// set changes the imported node.
func profileOpenVPNParseConfig(model *profileOpenVPN, body string, notes *[]string) bool {
	directives := profileVpnReadOvpnDirectives(body)
	if len(directives) == 0 {
		profileVpnNote(notes, "the OpenVPN profile is empty")
		return false
	}

	model.Servers = nil
	model.Address = nil
	model.Routes = nil
	model.DataCiphers = nil
	model.PullFilters = nil
	model.RedirectGWFlags = nil
	model.TLS.PeerFingerprint = nil
	model.TLS.RemoteCertificateKU = nil

	remotes := []profileVpnRemote{}
	defaultPort := 0
	keyDirectionArg := ""
	legacyCipher := ""
	ifconfigLocal := ""
	ifconfigSecond := ""
	fatal := ""
	clientCertSwitch := ""
	friendlyName := ""

	// OpenVPN Connect keeps its display name in a comment, which the tokenizer drops.
	for _, line := range strings.Split(body, "\n") {
		comment := profileVpnTrimmed(line)
		if !strings.HasPrefix(comment, "#") {
			continue
		}
		comment = profileVpnTrimmed(comment[1:])
		const prefix = "OVPN_FRIENDLY_PROFILE_NAME="
		if strings.HasPrefix(comment, prefix) {
			friendlyName = profileVpnTrimmed(comment[len(prefix):])
		}
	}

	for _, item := range directives {
		if fatal != "" {
			break
		}
		if item.InlineTag != "" {
			tag := item.InlineTag
			if tag == "connection" {
				remote := profileVpnRemote{}
				blockNetwork := ""
				blockPort := 0
				for _, line := range item.InlineBody {
					args := profileVpnTokenize(line)
					if len(args) == 0 {
						continue
					}
					switch args[0] {
					case "remote":
						remote = profileVpnParseRemote(args)
					case "proto":
						if len(args) > 1 {
							blockNetwork = profileVpnNetwork(args[1])
						}
					case "port", "rport":
						if len(args) > 1 {
							blockPort = profileVpnQtToInt(args[1])
						}
					}
				}
				if remote.Host == "" {
					profileVpnNote(notes, "a connection block has no remote")
					continue
				}
				if remote.Network == "" {
					remote.Network = blockNetwork
				}
				if remote.Port == 0 {
					remote.Port = blockPort
				}
				remotes = append(remotes, remote)
				continue
			}
			switch tag {
			case "ca":
				model.TLS.Certificate = append([]string(nil), item.InlineBody...)
			case "cert":
				model.TLS.ClientCertificate = append([]string(nil), item.InlineBody...)
			case "key":
				model.TLS.ClientKey = append([]string(nil), item.InlineBody...)
			case "tls-auth", "tls-crypt", "tls-crypt-v2":
				model.TLS.ControlWrap.Kind = strings.ReplaceAll(tag, "-", "_")
				model.TLS.ControlWrap.Key = append([]string(nil), item.InlineBody...)
			case "secret":
				model.Mode = "static_key"
				model.StaticKey = append([]string(nil), item.InlineBody...)
			case "auth-user-pass":
				if len(item.InlineBody) > 0 {
					model.Username = item.InlineBody[0]
				}
				if len(item.InlineBody) > 1 {
					model.Password = item.InlineBody[1]
				}
			case "peer-fingerprint":
				for _, line := range item.InlineBody {
					if hex := profileVpnFingerprint(line); hex != "" {
						model.TLS.PeerFingerprint = append(model.TLS.PeerFingerprint, hex)
					} else {
						profileVpnNotef(notes, "peer-fingerprint %q is not a SHA-256 fingerprint", line)
					}
				}
			case "pkcs12":
				fatal = "the profile is a PKCS#12 bundle, which the endpoint cannot read"
			default:
				profileVpnNotef(notes, "the inline <%s> block is not supported", tag)
			}
			continue
		}

		args := item.Args
		key := args[0]
		value := ""
		if len(args) > 1 {
			value = args[1]
		}

		if profileOpenVPNServerOnly[key] {
			fatal = "the profile is a server configuration (" + key + ")"
			continue
		}
		if key == "pkcs12" {
			fatal = "the profile is a PKCS#12 bundle, which the endpoint cannot read"
			continue
		}
		if key == "dev" || key == "dev-type" {
			if strings.HasPrefix(value, "tap") {
				fatal = "TAP mode is not supported, only TUN"
			}
			continue
		}
		if key == "mode" {
			if value == "server" {
				fatal = "the profile is a server configuration (mode server)"
			}
			continue
		}

		switch key {
		case "remote":
			remote := profileVpnParseRemote(args)
			if remote.Host != "" {
				remotes = append(remotes, remote)
			}
			continue
		case "proto":
			network := profileVpnNetwork(value)
			if network != "" {
				model.Network = network
			} else if strings.HasSuffix(value, "-server") {
				fatal = "the profile uses a server transport (" + value + ")"
			} else {
				profileVpnNotef(notes, "proto %q is not a known transport", value)
			}
			continue
		case "port", "rport":
			if profileVpnAccept(notes, key, value, profileOpenVPNPortMessage(value)) {
				defaultPort = profileVpnQtToInt(value)
			}
			continue
		case "remote-random":
			model.RemoteRandom = true
			continue
		case "ifconfig":
			if len(args) > 2 {
				ifconfigLocal = args[1]
				ifconfigSecond = args[2]
			}
			continue
		case "ifconfig-ipv6":
			if len(args) > 1 {
				if profileVpnNormalizePrefix(args[1]) != "" {
					model.Address = append(model.Address, args[1])
				} else {
					profileVpnNotef(notes, "ifconfig-ipv6 %q is not a prefix", args[1])
				}
				if len(args) > 2 {
					model.PeerAddressIPv6 = args[2]
				}
			}
			continue
		case "topology":
			model.Topology = value
			continue
		case "auth-retry":
			model.AuthRetry = value
			continue
		case "auth-user-pass":
			if value != "" && value != "[inline]" {
				profileVpnNotef(notes, "the credentials file %q is not read; enter the username and password instead", value)
			}
			continue
		case "client-cert-not-required":
			// OpenVPN 3 reads it as "log in without a client certificate"; 2.x has no such switch.
			clientCertSwitch = key
			continue
		case "setenv":
			setting := ""
			if len(args) > 2 {
				setting = args[2]
			}
			if value == "CLIENT_CERT" && setting == "0" {
				clientCertSwitch = "setenv CLIENT_CERT 0"
			} else if value == "FRIENDLY_NAME" && setting != "" {
				friendlyName = setting
			}
			continue
		case "static-challenge":
			model.StaticChallenge = value
			if len(args) > 2 {
				model.StaticChallengeEcho = args[2] == "1"
			}
			continue
		case "key-direction":
			keyDirectionArg = profileVpnKeyDirection(value)
			continue
		case "secret":
			model.Mode = "static_key"
			if value != "" && value != "[inline]" {
				model.StaticKeyPath = value
			}
			if len(args) > 2 {
				keyDirectionArg = profileVpnKeyDirection(args[2])
			}
			continue
		case "ca", "cert", "key", "crl-verify":
			if value == "" || value == "[inline]" {
				continue
			}
			switch key {
			case "ca":
				model.TLS.CertificatePath = value
			case "cert":
				model.TLS.ClientCertificatePath = value
			case "key":
				model.TLS.ClientKeyPath = value
			default:
				model.TLS.CRLPath = value
				if len(args) > 2 && args[2] == "dir" {
					profileVpnNote(notes, "a CRL directory is not read, only a single CRL file")
				}
			}
			continue
		case "tls-auth", "tls-crypt", "tls-crypt-v2":
			model.TLS.ControlWrap.Kind = strings.ReplaceAll(key, "-", "_")
			if value != "" && value != "[inline]" {
				model.TLS.ControlWrap.KeyPath = value
			}
			if key == "tls-auth" && len(args) > 2 {
				keyDirectionArg = profileVpnKeyDirection(args[2])
			}
			continue
		case "peer-fingerprint", "verify-hash":
			if hex := profileVpnFingerprint(value); hex != "" {
				model.TLS.PeerFingerprint = append(model.TLS.PeerFingerprint, hex)
			} else {
				profileVpnNotef(notes, "%q is not a SHA-256 fingerprint", value)
			}
			continue
		case "remote-cert-tls":
			model.TLS.RemoteCertificateTLS = value
			continue
		case "remote-cert-ku":
			for index := 1; index < len(args); index++ {
				model.TLS.RemoteCertificateKU = append(model.TLS.RemoteCertificateKU, args[index])
			}
			continue
		case "remote-cert-eku":
			model.TLS.RemoteCertificateEKU = value
			continue
		case "ns-cert-type":
			model.TLS.NSCertificateType = value
			continue
		case "verify-x509-name":
			model.TLS.ServerName = value
			model.TLS.ServerNameType = "subject"
			if len(args) > 2 {
				model.TLS.ServerNameType = args[2]
			}
			continue
		case "tls-version-min":
			model.TLS.VersionMin = value
			continue
		case "tls-version-max":
			model.TLS.VersionMax = value
			continue
		case "tls-cipher":
			suites := profileOpenVPNNormalizeTLSCipher(value)
			if profileVpnAccept(notes, key, value, profileOpenVPNTLSCipherMessage(suites)) {
				model.TLS.Cipher = suites
			}
			continue
		case "tls-groups":
			groups, _ := profileNewASCIIUpper(profileVpnTrimmed(value))
			if profileVpnAccept(notes, key, value, profileOpenVPNTLSGroupsMessage(groups)) {
				model.TLS.Groups = groups
			}
			continue
		case "tls-cert-profile":
			model.TLS.CertificateProfile = value
			continue
		case "cipher":
			legacyCipher, _ = profileNewASCIIUpper(profileVpnTrimmed(value))
			continue
		case "data-ciphers", "ncp-ciphers":
			model.DataCiphers = profileVpnDataCiphers(notes, key, value)
			continue
		case "data-ciphers-fallback":
			fallback, ok := profileNewASCIIUpper(profileVpnTrimmed(value))
			if !ok {
				profileVpnNotef(notes, "data-ciphers-fallback %q is not ASCII", value)
				continue
			}
			if profileVpnAccept(notes, key, value, profileOpenVPNCipherNameMessage(fallback)) {
				model.DataCiphersFallback = fallback
			}
			continue
		case "auth":
			model.Auth, _ = profileNewASCIIUpper(profileVpnTrimmed(value))
			continue
		case "mssfix":
			if value == "" {
				continue
			}
			if value == "0" {
				model.MSSFixDisabled = true
			} else if profileVpnAccept(notes, key, value, profileOpenVPNIntMessage(value, 0, 65535)) {
				model.MSSFix = profileVpnQtToInt(value)
				if len(args) > 2 && (args[2] == "mtu" || args[2] == "fixed") {
					model.MSSFixMode = args[2]
				}
			}
			continue
		case "fragment":
			if profileVpnAccept(notes, key, value, profileOpenVPNOpenVPNFragmentMessage(value)) {
				model.Fragment = profileVpnQtToInt(value)
			}
			continue
		case "replay-window":
			if profileVpnAccept(notes, key, value, profileOpenVPNReplayWindowMessage(value)) {
				model.ReplayWindow = profileVpnQtToInt(value)
			}
			if len(args) > 2 {
				window := profileVpnDuration(notes, key, args[2])
				if profileVpnAccept(notes, key, args[2], profileOpenVPNReplayWindowTimeMessage(window)) {
					model.ReplayWindowTime = window
				}
			}
			continue
		case "compress":
			compressMode, _ := profileNewASCIILower(value)
			switch {
			case compressMode == "lzo":
				// The endpoint spells `compress lzo` as the identical comp-lzo mode.
				model.CompressionLZO = "yes"
			case compressMode == "":
				model.Compression = "stub"
			case compressMode == "migrate":
				model.Compression = "none"
			default:
				model.Compression = compressMode
			}
			continue
		case "comp-lzo":
			if value == "" {
				model.CompressionLZO = "adaptive"
			} else {
				model.CompressionLZO, _ = profileNewASCIILower(value)
			}
			continue
		case "allow-compression":
			model.AllowCompression, _ = profileNewASCIILower(value)
			continue
		case "route-nopull":
			model.RouteNoPull = true
			continue
		case "pull-filter":
			if len(args) > 2 {
				model.PullFilters = append(model.PullFilters, profileOpenVPNPullFilter{Action: args[1], Text: args[2]})
			}
			continue
		case "route":
			if len(args) > 1 {
				if profileVpnRouteKeyword(args[1]) {
					profileVpnNotef(notes, "the symbolic route gateway %q is not supported", args[1])
					continue
				}
				prefixText := ""
				next := 2
				if strings.Contains(args[1], "/") {
					prefixText = profileVpnNormalizePrefix(args[1])
				} else if len(args) > 2 && !profileVpnRouteKeyword(args[2]) && profileVpnPrefix(args[1], args[2]) != "" {
					prefixText = profileVpnPrefix(args[1], args[2])
					next = 3
				} else {
					prefixText = profileVpnPrefix(args[1], "255.255.255.255")
				}
				if prefixText == "" {
					profileVpnNotef(notes, "route %s cannot be read", strings.Join(args[1:], " "))
					continue
				}
				if !profileVpnContains(model.Routes, prefixText) {
					model.Routes = append(model.Routes, prefixText)
				}
				// OpenVPN also takes a host name here; the endpoint needs an address.
				if len(args) > next && !profileVpnRouteKeyword(args[next]) && model.RouteGateway == "" &&
					profileVpnAccept(notes, key, args[next], profileOpenVPNIPMessage(args[next], 0, false)) {
					model.RouteGateway = args[next]
				}
				if len(args) > next+1 && model.RouteMetric == 0 &&
					profileVpnAccept(notes, key, args[next+1], profileOpenVPNIntMessage(args[next+1], 0, 2147483647)) {
					model.RouteMetric = profileVpnQtToInt(args[next+1])
				}
			}
			continue
		case "route-ipv6":
			if len(args) > 1 {
				prefixText := profileVpnNormalizePrefix(args[1])
				if prefixText != "" {
					if !profileVpnContains(model.Routes, prefixText) {
						model.Routes = append(model.Routes, prefixText)
					}
				} else {
					profileVpnNotef(notes, "route-ipv6 %s cannot be read", strings.Join(args[1:], " "))
				}
			}
			continue
		case "route-gateway":
			if !profileVpnRouteKeyword(value) &&
				profileVpnAccept(notes, key, value, profileOpenVPNIPMessage(value, 0, true)) {
				model.RouteGateway = value
			}
			continue
		case "route-metric":
			if profileVpnAccept(notes, key, value, profileOpenVPNIntMessage(value, 0, 2147483647)) {
				model.RouteMetric = profileVpnQtToInt(value)
			}
			continue
		case "redirect-gateway", "redirect-private":
			if key == "redirect-gateway" {
				model.RedirectGateway = true
			} else {
				model.RedirectPrivate = true
			}
			for index := 1; index < len(args); index++ {
				flag, _ := profileNewASCIILower(args[index])
				// Host-route exceptions for the DHCP and DNS servers never apply
				// here, and warning about them sends users looking for a setting
				// that does not exist.
				if flag == "bypass-dhcp" || flag == "bypass-dns" {
					continue
				}
				if flag == "block-local" {
					profileVpnNotef(notes, "the redirect-gateway flag %q is not supported", flag)
					continue
				}
				if !profileVpnContains(model.RedirectGWFlags, flag) {
					model.RedirectGWFlags = append(model.RedirectGWFlags, flag)
				}
			}
			continue
		case "block-ipv6":
			model.BlockIPv6 = true
			continue
		case "keepalive":
			if len(args) > 2 {
				model.PingInterval = profileVpnDuration(notes, key, args[1])
				model.PingRestart = profileVpnDuration(notes, key, args[2])
			}
			continue
		case "ping":
			model.PingInterval = profileVpnDuration(notes, key, value)
			continue
		case "ping-restart":
			if value == "0" {
				model.PingRestartDisabled = true
			} else {
				model.PingRestart = profileVpnDuration(notes, key, value)
			}
			continue
		case "reneg-sec":
			if value == "0" {
				model.RenegotiateDisabled = true
			} else {
				model.RenegotiateInterval = profileVpnDuration(notes, key, value)
			}
			continue
		case "reneg-bytes":
			if profileVpnAccept(notes, key, value, profileOpenVPNIntMessage(value, 0, 9223372036854775807)) {
				model.RenegotiateBytes = profileVpnQtToLong(value)
			}
			continue
		case "reneg-pkts":
			if profileVpnAccept(notes, key, value, profileOpenVPNIntMessage(value, 0, 9223372036854775807)) {
				model.RenegotiatePackets = profileVpnQtToLong(value)
			}
			continue
		case "tls-timeout":
			model.TLSTimeout = profileVpnDuration(notes, key, value)
			continue
		case "hand-window":
			model.HandshakeWindow = profileVpnDuration(notes, key, value)
			continue
		case "explicit-exit-notify":
			if value == "" {
				model.ExplicitExitNotify = 1
			} else if profileVpnAccept(notes, key, value, profileOpenVPNIntMessage(value, 0, 2147483647)) {
				model.ExplicitExitNotify = profileVpnQtToInt(value)
			}
			continue
		case "tun-mtu":
			if profileVpnAccept(notes, key, value, profileOpenVPNIntMessage(value, 0, 65535)) {
				model.MTU = profileVpnQtToInt(value)
			}
			continue
		}
		if profileOpenVPNIgnored[key] {
			continue
		}
		if profileOpenVPNUnsupported[key] {
			profileVpnNotef(notes, "the option %q is recognised but not supported", key)
			continue
		}
		profileVpnNotef(notes, "the option %q is not known", key)
	}

	if fatal != "" {
		profileVpnNote(notes, fatal)
		return false
	}

	if clientCertSwitch != "" {
		dropped := len(model.TLS.ClientCertificate) > 0 || model.TLS.ClientCertificatePath != "" ||
			len(model.TLS.ClientKey) > 0 || model.TLS.ClientKeyPath != ""
		model.TLS.ClientCertificate = nil
		model.TLS.ClientCertificatePath = ""
		model.TLS.ClientKey = nil
		model.TLS.ClientKeyPath = ""
		if dropped {
			profileVpnNotef(notes, "%s turns off the client certificate, so the profile's pair was dropped", clientCertSwitch)
		}
	}
	// The core, like OpenVPN 2.x, refuses a lone certificate or key.
	hasClientCert := len(model.TLS.ClientCertificate) > 0 || model.TLS.ClientCertificatePath != ""
	hasClientKey := len(model.TLS.ClientKey) > 0 || model.TLS.ClientKeyPath != ""
	if hasClientCert != hasClientKey {
		if hasClientCert {
			profileVpnNote(notes, "a client certificate without its key is refused")
		} else {
			profileVpnNote(notes, "a client key without its certificate is refused")
		}
		return false
	}

	for index := range remotes {
		if remotes[index].Port == 0 {
			if defaultPort > 0 {
				remotes[index].Port = defaultPort
			} else {
				remotes[index].Port = 1194
			}
		}
	}
	if len(remotes) == 0 {
		profileVpnNote(notes, "the profile has no remote server")
		return false
	}
	// `server`/`server_port` and `servers` conflict in the core.
	if len(remotes) == 1 {
		model.Server = remotes[0].Host
		model.Port = remotes[0].Port
		if remotes[0].Network != "" {
			model.Network = remotes[0].Network
		}
	} else {
		model.Server = ""
		model.Port = 0
		for _, remote := range remotes {
			model.Servers = append(model.Servers, profileOpenVPNRemoteStored{
				Server: remote.Host, Port: remote.Port, Network: remote.Network,
				HasServer: true, HasPort: true, HasNetwork: remote.Network != "",
			})
		}
	}
	if friendlyName != "" {
		model.Name = friendlyName
	}
	if model.Name == "" {
		model.Name = remotes[0].Host
	}

	if ifconfigLocal != "" && ifconfigSecond != "" {
		// Only `--topology subnet` makes the second argument a netmask.
		masked := model.Topology == "subnet" || strings.HasPrefix(ifconfigSecond, "255.")
		mask := "32"
		if masked {
			mask = ifconfigSecond
		}
		if _, length, ok := profileVpnParseSubnet(ifconfigLocal + "/" + mask); ok {
			model.Address = append(model.Address, ifconfigLocal+"/"+strconv.Itoa(length))
		} else {
			profileVpnNotef(notes, "ifconfig %q is not an address", ifconfigLocal)
		}
		if !masked {
			model.PeerAddress = ifconfigSecond
		}
	}

	// `key-direction` binds to the control-channel wrap in TLS mode, the secret otherwise.
	if keyDirectionArg != "" {
		if model.TLS.ControlWrap.Kind == "tls_auth" {
			model.TLS.ControlWrap.Direction = keyDirectionArg
		} else if model.Mode == "static_key" {
			model.KeyDirection = keyDirectionArg
		}
	}
	// Outside static-key mode `cipher` is the pre-negotiation data cipher.
	if legacyCipher != "" {
		if model.Mode == "static_key" {
			model.Cipher = legacyCipher
		} else if model.DataCiphersFallback == "" &&
			profileVpnAccept(notes, "cipher", legacyCipher, profileOpenVPNCipherNameMessage(legacyCipher)) {
			model.DataCiphersFallback = legacyCipher
		}
	}
	if model.TLS.RemoteCertificateEKU != "" && model.TLS.RemoteCertificateTLS != "" {
		profileVpnNote(notes, "remote-cert-eku replaces remote-cert-tls; the latter was cleared")
		model.TLS.RemoteCertificateTLS = ""
	}
	// A redirect-gateway config is a full tunnel, not a management network.
	if model.RedirectGateway && !model.RouteNoPull {
		model.OnlyAdvertisedRoutes = false
	}

	// Every inline value conflicts with its own *_path in the core.
	if len(model.TLS.Certificate) > 0 {
		model.TLS.CertificatePath = ""
	}
	if len(model.TLS.ClientCertificate) > 0 {
		model.TLS.ClientCertificatePath = ""
	}
	if len(model.TLS.ClientKey) > 0 {
		model.TLS.ClientKeyPath = ""
	}
	if len(model.TLS.ControlWrap.Key) > 0 {
		model.TLS.ControlWrap.KeyPath = ""
	}
	if len(model.StaticKey) > 0 {
		model.StaticKeyPath = ""
	}
	return true
}

// profileVpnContains is List.contains for the small lists the parser keeps.
func profileVpnContains(items []string, value string) bool {
	for _, item := range items {
		if item == value {
			return true
		}
	}
	return false
}

// profileVpnQtToInt is QtStrings.toInt: 0 on any failure or overflow.
func profileVpnQtToInt(text string) int {
	value, ok := profileVpnToInt(text)
	if !ok {
		return 0
	}
	return value
}

// profileVpnQtToLong is QtStrings.toLong: 0 on any failure or overflow.
func profileVpnQtToLong(text string) int64 {
	trimmed := profileVpnTrimmed(text)
	if !profileVpnIsSignedInteger(trimmed) {
		return 0
	}
	value, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil {
		return 0
	}
	return value
}
