// QUrl/QUrlQuery parsing and percent codec used by the Throne link parsers.
//
// Ported from app/src/main/java/io/nekohasekai/sagernet/outbound/link/LinkParser.kt
// and LinkCodec.kt. The component rules are the ones Qt 6 leaves unencoded, and
// the tolerant/PrettyDecoded/FullyDecoded distinctions are reproduced because a
// share link's query (`security=`, `type=`, `sni=`) is decoded differently by
// each reader.
//
// `Hosts.normalizeHost` is not fully ported yet: this file normalizes ASCII
// hosts, brackets IPv6 literals and decodes percent escapes, but IDN/ACE and
// Qt's IPv4 shorthand rules remain a documented gap (S5c) rather than a silent
// approximation of a protocol field.
package mobile

import (
	"net/netip"
	"strings"
	"unicode/utf8"
)

const (
	profileLinkHex        = "0123456789ABCDEF"
	profileLinkUserRaw    = "!$&'()*+,-.;=_~"
	profileLinkPassRaw    = "!$&'()*+,-.:;=_~"
	profileLinkQueryRaw   = "!$'()*+,-./:;?@[]_~"
	profileLinkFragRaw    = "!$&'()*+,-./:;=?@[]_~"
	profileLinkUnreserved = "-._~"
	// Escapes QUrlQuery decodes in PrettyDecoded form.
	profileLinkPrettyDecode = " \"#&-.<=>\\^_`{|}~"
)

type profileLinkQueryItem struct {
	Key   string
	Value string
}

// profileLinkQuery is QUrlQuery(url.query()) in PrettyDecoded form, order preserved.
type profileLinkQuery struct {
	Items []profileLinkQueryItem
}

func profileLinkQueryEmpty() profileLinkQuery {
	return profileLinkQuery{}
}

func (query profileLinkQuery) Has(key string) bool {
	for _, item := range query.Items {
		if item.Key == key {
			return true
		}
	}
	return false
}

func (query profileLinkQuery) Value(key string) string {
	for _, item := range query.Items {
		if item.Key == key {
			return item.Value
		}
	}
	return ""
}

func (query profileLinkQuery) ValueFully(key string) string {
	return profileLinkDecodeFully(query.Value(key))
}

// ValueFormDecoded is formDecodedQueryValue: a literal '+' is a space before
// the percent decode, so an encoded %2B stays '+'.
func (query profileLinkQuery) ValueFormDecoded(key string) string {
	return profileLinkDecodeFully(
		strings.ReplaceAll(profileLinkRecodeQueryFullyEncoded(query.Value(key)), "+", "%20"),
	)
}

func (query profileLinkQuery) ValueOr(key, fallback string) string {
	value := query.Value(key)
	if value == "" {
		return fallback
	}
	return value
}

func (query profileLinkQuery) IsEmpty() bool {
	return len(query.Items) == 0
}

// profileParsedLink is QUrl(link) reduced to the fields the profile parsers read.
type profileParsedLink struct {
	Scheme      string
	UserName    string
	Password    string
	Host        string
	Port        int
	InvalidPort bool
	InvalidHost bool
	Path        string
	Query       profileLinkQuery
	Fragment    string
	HasFragment bool
}

func (link profileParsedLink) IsValid() bool {
	return !link.InvalidPort && !link.InvalidHost
}

func (link profileParsedLink) InvalidPortOnly() bool {
	return link.InvalidPort && !link.InvalidHost
}

func (link profileParsedLink) PortOrDefault(fallback int) int {
	if link.Port >= 0 {
		return link.Port
	}
	return fallback
}

// UserInfoPair handles a scheme whose userinfo is always id:secret: QUrl splits
// at a literal ':' before decoding, so an encoded %3A stays in UserName.
func (link profileParsedLink) UserInfoPair() (string, string) {
	if link.Password != "" || !strings.Contains(link.UserName, ":") {
		return link.UserName, link.Password
	}
	index := strings.Index(link.UserName, ":")
	return link.UserName[:index], link.UserName[index+1:]
}

// profileLinkParse is QUrl(link) in TolerantMode.
func profileLinkParse(link string) profileParsedLink {
	hash := -1
	question := -1
	colon := -1
	for index := 0; index < len(link); index++ {
		char := link[index]
		if char == '#' {
			hash = index
			break
		}
		if question == -1 {
			if char == ':' && colon == -1 {
				colon = index
			} else if char == '?' {
				question = index
			}
		}
	}
	scheme := ""
	hierStart := 0
	if colon != -1 && profileLinkValidScheme(link, colon) {
		scheme = strings.ToLower(link[:colon])
		hierStart = colon + 1
	}
	hierEnd := len(link)
	if question != -1 && question < hierEnd {
		hierEnd = question
	}
	if hash != -1 && hash < hierEnd {
		hierEnd = hash
	}

	userName := ""
	password := ""
	host := ""
	port := -1
	invalidPort := false
	invalidHost := false
	pathStart := hierStart
	if hierEnd-hierStart >= 2 && link[hierStart] == '/' && link[hierStart+1] == '/' {
		authorityEnd := hierEnd
		for index := hierStart + 2; index < hierEnd; index++ {
			if link[index] == '/' {
				authorityEnd = index
				break
			}
		}
		auth := link[hierStart+2 : authorityEnd]
		from := 0
		if at := strings.Index(auth, "@"); at >= 0 {
			userInfo := auth[:at]
			if delim := strings.Index(userInfo, ":"); delim >= 0 {
				userName = profileLinkDecodeFully(profileLinkTolerant(userInfo[:delim]))
				password = profileLinkDecodeFully(profileLinkTolerant(userInfo[delim+1:]))
			} else {
				userName = profileLinkDecodeFully(profileLinkTolerant(userInfo))
			}
			from = at + 1
		}
		rest := auth[from:]
		colonIndex := strings.LastIndex(rest, ":")
		if colonIndex >= 0 && strings.HasPrefix(rest, "[") {
			closing := strings.Index(rest, "]")
			if closing < 0 || closing > colonIndex {
				colonIndex = -1
			}
		}
		if colonIndex >= 0 && colonIndex != len(rest)-1 {
			digits := rest[colonIndex+1:]
			value := -1
			if len(digits) <= 9 && profileLinkAllDigits(digits) {
				value = profileLinkAtoi(digits)
			}
			if value >= 0 && value <= 65535 {
				port = value
			} else {
				invalidPort = true
			}
		}
		hostRaw := rest
		if colonIndex >= 0 {
			hostRaw = rest[:colonIndex]
		}
		normalized, ok := profileLinkNormalizeHost(hostRaw)
		if !ok {
			invalidHost = true
		} else {
			host = normalized
		}
		pathStart = authorityEnd
	}
	path := profileLinkDecodeFully(profileLinkTolerant(link[pathStart:hierEnd]))
	query := profileLinkQueryEmpty()
	if question != -1 {
		queryEnd := len(link)
		if hash != -1 {
			queryEnd = hash
		}
		query = profileLinkParseQuery(link[question+1 : queryEnd])
	}
	fragment := ""
	hasFragment := false
	if hash != -1 {
		fragment = profileLinkDecodeFully(profileLinkTolerant(link[hash+1:]))
		hasFragment = true
	}
	return profileParsedLink{
		Scheme:      scheme,
		UserName:    userName,
		Password:    password,
		Host:        host,
		Port:        port,
		InvalidPort: invalidPort,
		InvalidHost: invalidHost,
		Path:        path,
		Query:       query,
		Fragment:    fragment,
		HasFragment: hasFragment,
	}
}

func profileLinkValidScheme(link string, colon int) bool {
	if colon <= 0 {
		return false
	}
	first := link[0]
	if !((first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z')) {
		return false
	}
	for index := 1; index < colon; index++ {
		char := link[index]
		if (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') || char == '+' || char == '-' || char == '.' {
			continue
		}
		return false
	}
	return true
}

func profileLinkParseQuery(rawQuery string) profileLinkQuery {
	if rawQuery == "" {
		return profileLinkQueryEmpty()
	}
	text := profileLinkTolerant(rawQuery)
	segments := strings.Split(text, "&")
	items := make([]profileLinkQueryItem, 0, len(segments))
	for _, segment := range segments {
		eq := strings.Index(segment, "=")
		key := ""
		value := ""
		if eq >= 0 {
			key = profileLinkDecodePretty(segment[:eq])
			value = profileLinkDecodePretty(segment[eq+1:])
		} else {
			key = profileLinkDecodePretty(segment)
		}
		items = append(items, profileLinkQueryItem{Key: key, Value: value})
	}
	return profileLinkQuery{Items: items}
}

// profileLinkNormalizeHost is the S5a slice of Hosts.normalizeHost: percent
// decode, ASCII lower case and bracketed/plain IPv6 normalization. IDN/ACE and
// Qt's C-style IPv4 shorthand are S5c gaps.
func profileLinkNormalizeHost(raw string) (string, bool) {
	host := raw
	if strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]") {
		host = host[1 : len(host)-1]
	}
	host = profileLinkDecodeFully(profileLinkTolerant(host))
	if host == "" {
		return "", true
	}
	if strings.Contains(host, ":") {
		address, err := netip.ParseAddr(host)
		if err != nil || !address.Is6() {
			return "", false
		}
		return address.String(), true
	}
	for _, char := range host {
		if char > 0x7F {
			// IDN needs the ACE/NFKC rules from Hosts.kt; S5c ports that.
			if profileLinkHostCharInvalid(char) {
				return "", false
			}
			continue
		}
		if profileLinkHostCharInvalid(char) {
			return "", false
		}
	}
	return strings.ToLower(host), true
}

func profileLinkHostCharInvalid(char rune) bool {
	if char <= 0x20 || char == 0x7F {
		return true
	}
	return strings.ContainsRune("<>\"{}|\\^`#$%&+,/:;=?@[]", char)
}

func profileLinkAllDigits(text string) bool {
	if text == "" {
		return false
	}
	for _, char := range text {
		if char < '0' || char > '9' {
			return false
		}
	}
	return true
}

func profileLinkAtoi(text string) int {
	value := 0
	for _, char := range text {
		value = value*10 + int(char-'0')
	}
	return value
}

func profileLinkEncodeUserName(value string) string {
	return profileLinkEncode(value, profileLinkUserRaw)
}

func profileLinkEncodePassword(value string) string {
	return profileLinkEncode(value, profileLinkPassRaw)
}

func profileLinkEncodeQueryPart(value string) string {
	return profileLinkEncode(value, profileLinkQueryRaw)
}

func profileLinkEncodeFragment(value string) string {
	return profileLinkEncode(value, profileLinkFragRaw)
}

func profileLinkPercentEncodeAll(value string) string {
	return profileLinkEncode(value, profileLinkUnreserved)
}

func profileLinkIsAlnum(char byte) bool {
	return (char >= 'a' && char <= 'z') || (char >= 'A' && char <= 'Z') ||
		(char >= '0' && char <= '9')
}

func profileLinkEncode(value, raw string) string {
	var builder strings.Builder
	for _, char := range value {
		if char < 0x80 {
			if profileLinkIsAlnum(byte(char)) || strings.ContainsRune(raw, char) {
				builder.WriteByte(byte(char))
			} else {
				profileLinkAppendEscape(&builder, int(char))
			}
			continue
		}
		var buffer [utf8.UTFMax]byte
		size := utf8.EncodeRune(buffer[:], char)
		for _, b := range buffer[:size] {
			profileLinkAppendEscape(&builder, int(b))
		}
	}
	return builder.String()
}

func profileLinkAppendEscape(builder *strings.Builder, value int) {
	builder.WriteByte('%')
	builder.WriteByte(profileLinkHex[(value>>4)&0xF])
	builder.WriteByte(profileLinkHex[value&0xF])
}

func profileLinkHexValue(char byte) int {
	switch {
	case char >= '0' && char <= '9':
		return int(char - '0')
	case char >= 'a' && char <= 'f':
		return int(char-'a') + 10
	case char >= 'A' && char <= 'F':
		return int(char-'A') + 10
	default:
		return -1
	}
}

func profileLinkEscapeAt(value string, index int) int {
	if index >= len(value) || value[index] != '%' || index+2 >= len(value) {
		return -1
	}
	high := profileLinkHexValue(value[index+1])
	low := profileLinkHexValue(value[index+2])
	if high < 0 || low < 0 {
		return -1
	}
	return (high << 4) | low
}

func profileLinkHasInvalidPercent(value string) bool {
	for index := 0; index < len(value); index++ {
		if value[index] == '%' && profileLinkEscapeAt(value, index) < 0 {
			return true
		}
	}
	return false
}

func profileLinkRecodeQueryFullyEncoded(pretty string) string {
	keepEscapes := !profileLinkHasInvalidPercent(pretty)
	var builder strings.Builder
	for index := 0; index < len(pretty); {
		b := -1
		if keepEscapes {
			b = profileLinkEscapeAt(pretty, index)
		}
		if b >= 0 {
			char := byte(b)
			if b < 0x80 && (profileLinkIsAlnum(char) || strings.ContainsRune(profileLinkUnreserved, rune(char))) {
				builder.WriteByte(char)
			} else {
				profileLinkAppendEscape(&builder, b)
			}
			index += 3
			continue
		}
		char, size := utf8.DecodeRuneInString(pretty[index:])
		if char < 0x80 {
			if profileLinkIsAlnum(byte(char)) || strings.ContainsRune(profileLinkQueryRaw, char) {
				builder.WriteByte(byte(char))
			} else {
				profileLinkAppendEscape(&builder, int(char))
			}
			index++
			continue
		}
		var buffer [utf8.UTFMax]byte
		n := utf8.EncodeRune(buffer[:], char)
		for _, encoded := range buffer[:n] {
			profileLinkAppendEscape(&builder, int(encoded))
		}
		index += size
	}
	return builder.String()
}

func profileLinkTolerant(value string) string {
	if profileLinkHasInvalidPercent(value) {
		return strings.ReplaceAll(value, "%", "%25")
	}
	return value
}

func profileLinkDecodeFully(raw string) string {
	var builder strings.Builder
	for index := 0; index < len(raw); {
		b := profileLinkEscapeAt(raw, index)
		if b < 0 {
			char, size := utf8.DecodeRuneInString(raw[index:])
			if char == utf8.RuneError && size == 1 {
				builder.WriteRune('\uFFFD')
				index++
			} else {
				builder.WriteString(raw[index : index+size])
				index += size
			}
			continue
		}
		if b < 0x80 {
			builder.WriteByte(byte(b))
			index += 3
			continue
		}
		consumed := profileLinkDecodeUTF8Escape(raw, index, &builder)
		if consumed > 0 {
			index += consumed
		} else {
			builder.WriteRune('\uFFFD')
			index += 3
		}
	}
	return builder.String()
}

func profileLinkDecodePretty(raw string) string {
	var builder strings.Builder
	for index := 0; index < len(raw); {
		b := profileLinkEscapeAt(raw, index)
		char, size := utf8.DecodeRuneInString(raw[index:])
		if b < 0 {
			if char < 0x20 || char == 0x7F {
				profileLinkAppendEscape(&builder, int(char))
			} else {
				builder.WriteString(raw[index : index+size])
			}
			index += size
			continue
		}
		if b < 0x80 {
			ch := byte(b)
			if profileLinkIsAlnum(ch) || strings.ContainsRune(profileLinkPrettyDecode, rune(ch)) {
				builder.WriteByte(ch)
			} else {
				profileLinkAppendEscape(&builder, b)
			}
			index += 3
			continue
		}
		consumed := profileLinkDecodeUTF8Escape(raw, index, &builder)
		if consumed > 0 {
			index += consumed
		} else {
			profileLinkAppendEscape(&builder, b)
			index += 3
		}
	}
	return builder.String()
}

// profileLinkDecodeUTF8Escape decodes one strictly valid UTF-8 sequence written
// as consecutive escapes; 0 when the sequence is not valid.
func profileLinkDecodeUTF8Escape(value string, start int, builder *strings.Builder) int {
	b0 := profileLinkEscapeAt(value, start)
	need := 0
	switch {
	case b0 >= 0xC2 && b0 <= 0xDF:
		need = 2
	case b0 >= 0xE0 && b0 <= 0xEF:
		need = 3
	case b0 >= 0xF0 && b0 <= 0xF4:
		need = 4
	default:
		return 0
	}
	codePoint := 0
	switch need {
	case 2:
		codePoint = b0 & 0x1F
	case 3:
		codePoint = b0 & 0x0F
	default:
		codePoint = b0 & 0x07
	}
	for index := 1; index < need; index++ {
		b := profileLinkEscapeAt(value, start+3*index)
		if b < 0 {
			return 0
		}
		low := 0x80
		if index == 1 && b0 == 0xE0 {
			low = 0xA0
		}
		if index == 1 && b0 == 0xF0 {
			low = 0x90
		}
		high := 0xBF
		if index == 1 && b0 == 0xED {
			high = 0x9F
		}
		if index == 1 && b0 == 0xF4 {
			high = 0x8F
		}
		if b < low || b > high {
			return 0
		}
		codePoint = (codePoint << 6) | (b & 0x3F)
	}
	builder.WriteRune(rune(codePoint))
	return 3 * need
}
