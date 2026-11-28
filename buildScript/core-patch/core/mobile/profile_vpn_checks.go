// Shared field grammar for the OpenVPN/OpenConnect slices: the parts of
// Validation.kt, VpnFileImport and the two Checks objects that decide whether a
// stored value is acceptable.
//
// Messages are stable English strings rather than the Android resources: this
// is a new action path with no localisation contract (the same rule
// profile_validate_stored.go states). What has to match Kotlin exactly is the
// *verdict* per value, not the wording.
package mobile

import (
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"unicode"
)

// profileVpnDurationUnits is Validation.DURATION_UNIT_VALUES, the Go
// `time.ParseDuration` unit table plus the desktop's day unit.
var profileVpnDurationUnits = map[string]uint64{
	"ns": 1, "us": 1000, "µs": 1000, "μs": 1000, "ms": 1000000,
	"s": 1000000000, "m": 60000000000, "h": 3600000000000, "d": 86400000000000,
}

// profileVpnDurationNs is Validation.parseDurationNs: sing's ParseDuration on
// the UTF-8 bytes of the trimmed text, with its exact overflow rules.
func profileVpnDurationNs(text string) (int64, bool) {
	s := []byte(profileVpnTrimmed(text))
	n := len(s)
	const kLimit uint64 = 1 << 63
	digitAt := func(k int) bool { return s[k] >= '0' && s[k] <= '9' }
	p := 0
	negative := false
	if p < n && (s[p] == '-' || s[p] == '+') {
		negative = s[p] == '-'
		p++
	}
	if n-p == 1 && s[p] == '0' {
		return 0, true
	}
	if p == n {
		return 0, false
	}
	var elapsed uint64
	for p < n {
		var value uint64
		var fraction uint64
		scale := 1.0
		if !(s[p] == '.' || digitAt(p)) {
			return 0, false
		}
		intStart := p
		for p < n && digitAt(p) {
			if value > kLimit/10 {
				return 0, false
			}
			value = value*10 + uint64(s[p]-'0')
			if value > kLimit {
				return 0, false
			}
			p++
		}
		pre := p != intStart
		post := false
		if p < n && s[p] == '.' {
			p++
			fracStart := p
			overflow := false
			for p < n && digitAt(p) {
				if !overflow {
					if fraction > (kLimit-1)/10 {
						overflow = true
					} else {
						next := fraction*10 + uint64(s[p]-'0')
						if next > kLimit {
							overflow = true
						} else {
							fraction = next
							scale *= 10
						}
					}
				}
				p++
			}
			post = p != fracStart
		}
		if !pre && !post {
			return 0, false
		}
		unitStart := p
		for p < n && s[p] != '.' && !digitAt(p) {
			p++
		}
		if p == unitStart {
			return 0, false
		}
		unit, ok := profileVpnDurationUnits[string(s[unitStart:p])]
		if !ok {
			return 0, false
		}
		if value > kLimit/unit {
			return 0, false
		}
		value *= unit
		if fraction > 0 {
			value += uint64(float64(fraction) * (float64(unit) / scale))
			if value > kLimit {
				return 0, false
			}
		}
		elapsed += value
		if elapsed > kLimit {
			return 0, false
		}
	}
	if negative {
		if elapsed == kLimit {
			return -9223372036854775808, true
		}
		return -int64(elapsed), true
	}
	if elapsed > kLimit-1 {
		return 0, false
	}
	return int64(elapsed), true
}

// profileVpnFormatDurationNs is Validation.formatDuration.
func profileVpnFormatDurationNs(ns int64) string {
	if ns == 0 {
		return "0s"
	}
	units := []struct {
		value uint64
		name  string
	}{
		{3600000000000, "h"}, {60000000000, "m"}, {1000000000, "s"},
		{1000000, "ms"}, {1000, "us"}, {1, "ns"},
	}
	var out strings.Builder
	value := uint64(ns)
	if ns < 0 {
		out.WriteByte('-')
		value = -value
	}
	for _, unit := range units {
		quotient := value / unit.value
		if quotient != 0 {
			out.WriteString(strconv.FormatUint(quotient, 10))
			out.WriteString(unit.name)
			value %= unit.value
		}
	}
	return out.String()
}

// profileVpnAllDigits is Validation.allDigits.
func profileVpnAllDigits(text string) bool {
	if text == "" {
		return false
	}
	for index := 0; index < len(text); index++ {
		if text[index] < '0' || text[index] > '9' {
			return false
		}
	}
	return true
}

// profileVpnSignedDigits is Validation.signedDigits.
func profileVpnSignedDigits(text string) bool {
	return profileVpnAllDigits(strings.TrimPrefix(text, "-"))
}

// profileVpnParseLong is Validation.parseLong: an optional '-', ASCII digits,
// overflow-checked to the int64 range. Unlike profileVpnToInt it does not accept
// a leading '+' (Validation.parseLong does not either).
func profileVpnParseLong(text string) (int64, bool) {
	if text == "" {
		return 0, false
	}
	negative := text[0] == '-'
	index := 0
	if negative {
		index = 1
	}
	if index == len(text) {
		return 0, false
	}
	limit := uint64(9223372036854775807)
	if negative {
		limit++
	}
	var value uint64
	for ; index < len(text); index++ {
		char := text[index]
		if char < '0' || char > '9' {
			return 0, false
		}
		digit := uint64(char - '0')
		if value > (limit-digit)/10 {
			return 0, false
		}
		value = value*10 + digit
	}
	if !negative {
		return int64(value), true
	}
	if value == limit {
		return -9223372036854775808, true
	}
	return -int64(value), true
}

// profileVpnDurationMessage is Validation.duration over the parsed value.
// maxNs is -1 for "no upper bound".
func profileVpnDurationMessage(text string, wholeSeconds, emptyRequired bool, maxNs int64) string {
	trimmed := profileVpnTrimmed(text)
	if trimmed == "" {
		if emptyRequired {
			return "is required"
		}
		return ""
	}
	ns, ok := profileVpnDurationNs(trimmed)
	if !ok {
		dot := strings.Index(trimmed, ".")
		bare := false
		if dot < 0 {
			bare = profileVpnAllDigits(trimmed)
		} else {
			bare = profileVpnAllDigits(trimmed[:dot]) && profileVpnAllDigits(trimmed[dot+1:])
		}
		if bare {
			return "needs a unit (for example 5s)"
		}
		return "is not a duration"
	}
	if ns < 0 {
		return "must not be negative"
	}
	if wholeSeconds && ns%1000000000 != 0 {
		return "must be a whole number of seconds"
	}
	if maxNs >= 0 && ns > maxNs {
		return "must be at most " + profileVpnFormatDurationNs(maxNs)
	}
	return ""
}

// profileVpnIntMessage is Validation.int.
func profileVpnIntMessage(text string, min, max int64) string {
	trimmed := profileVpnTrimmed(text)
	if trimmed == "" {
		return ""
	}
	value, ok := profileVpnParseLong(trimmed)
	if !ok {
		if profileVpnSignedDigits(trimmed) {
			return fmt.Sprintf("must be between %d and %d", min, max)
		}
		return "must be a whole number"
	}
	if value < min || value > max {
		return fmt.Sprintf("must be between %d and %d", min, max)
	}
	return ""
}

// profileVpnPortMessage is Validation.port with Empty.Required.
func profileVpnPortMessage(text string) string {
	trimmed := profileVpnTrimmed(text)
	if trimmed == "" {
		return "is required"
	}
	value, ok := profileVpnParseLong(trimmed)
	if !ok || value < 1 || value > 65535 {
		return "must be a port number from 1 to 65535"
	}
	return ""
}

// profileVpnIPv4Fields is Go netip parseIPv4Fields: four decimal octets, no
// leading zeros except a lone "0", each at most 255.
func profileVpnIPv4Fields(text string) bool {
	value := 0
	pos := 0
	digits := 0
	for index := 0; index < len(text); index++ {
		char := text[index]
		if char >= '0' && char <= '9' {
			if digits == 1 && value == 0 {
				return false
			}
			value = value*10 + int(char-'0')
			digits++
			if value > 255 {
				return false
			}
			continue
		}
		if char != '.' {
			return false
		}
		if index == 0 || index == len(text)-1 || text[index-1] == '.' {
			return false
		}
		if pos == 3 {
			return false
		}
		pos++
		value = 0
		digits = 0
	}
	return pos == 3
}

// profileVpnIPKind is Validation.parseIp's result: 0 invalid, 4 or 6.
func profileVpnIPKind(text string) (int, bool, bool) {
	for index := 0; index < len(text); index++ {
		switch text[index] {
		case '.':
			if profileVpnIPv4Fields(text) {
				return 4, false, true
			}
			return 0, false, false
		case ':':
			address, err := netip.ParseAddr(text)
			if err != nil || !address.Is6() {
				return 0, false, false
			}
			return 6, address.Zone() != "", true
		case '%':
			return 0, false, false
		}
	}
	return 0, false, false
}

// profileVpnIPOK is Validation.ip(text, family, empty). family 0 = any.
func profileVpnIPOK(text string, family int, emptyAllowed bool) bool {
	trimmed := profileVpnTrimmed(text)
	if trimmed == "" {
		return emptyAllowed
	}
	kind, zoned, ok := profileVpnIPKind(trimmed)
	if !ok || zoned {
		return false
	}
	if family == 4 {
		return kind == 4
	}
	if family == 6 {
		return kind == 6
	}
	return true
}

// profileVpnIPMessage is the message form of profileVpnIPOK.
func profileVpnIPMessage(text string, family int, emptyAllowed bool) string {
	if profileVpnIPOK(text, family, emptyAllowed) {
		return ""
	}
	switch family {
	case 4:
		return "must be an IPv4 address"
	case 6:
		return "must be an IPv6 address"
	}
	return "must be an IP address"
}

// profileVpnCIDROK is Validation.cidr(text, Any, allowBareIp=false,
// Empty.Required): Go netip.ParsePrefix spelled the desktop's way.
func profileVpnCIDROK(text string) bool {
	trimmed := profileVpnTrimmed(text)
	if trimmed == "" {
		return false
	}
	slash := strings.LastIndex(trimmed, "/")
	if slash < 0 {
		return false
	}
	kind, zoned, ok := profileVpnIPKind(trimmed[:slash])
	if !ok || zoned {
		return false
	}
	bits := trimmed[slash+1:]
	if strings.Contains(bits, ".") {
		return false
	}
	if !profileVpnAllDigits(bits) {
		return false
	}
	if len(bits) > 1 && bits[0] == '0' {
		return false
	}
	maxBits := 128
	if kind == 4 {
		maxBits = 32
	}
	if len(bits) > 3 {
		return false
	}
	value, err := strconv.Atoi(bits)
	if err != nil || value > maxBits {
		return false
	}
	return true
}

// profileVpnZoneHasColon is Validation.zoneHasColon: interface names never
// contain ':', so a colon in the zone is a port typed after the address.
func profileVpnZoneHasColon(text string) bool {
	percent := strings.Index(text, "%")
	return percent >= 0 && strings.Contains(text[percent+1:], ":")
}

// profileVpnIPv6Like is Validation.ipv6Like.
func profileVpnIPv6Like(text string) bool {
	address := text
	if percent := strings.Index(text, "%"); percent >= 0 {
		address = text[:percent]
	}
	colon := strings.Index(address, ":")
	dot := strings.Index(address, ".")
	if colon < 0 || (dot >= 0 && dot < colon) {
		return false
	}
	for index := 0; index < len(address); index++ {
		char := address[index]
		if _, ok := configHexDigit(char); !ok {
			if char != ':' && char != '.' {
				return false
			}
		}
	}
	return true
}

// profileVpnHostOK is Validation.host(text, Empty.Required).
func profileVpnHostOK(text string) bool {
	trimmed := profileVpnTrimmed(text)
	if trimmed == "" {
		return false
	}
	if strings.Contains(trimmed, "://") {
		return false
	}
	for _, char := range trimmed {
		if unicode.IsSpace(char) {
			return false
		}
	}
	if strings.ContainsAny(trimmed, "/?#@") {
		return false
	}
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
		if rest == "" {
			return true
		}
		if strings.HasPrefix(rest, ":") && profileVpnAllDigits(rest[1:]) {
			return false
		}
		return false
	}
	if _, zoned, ok := profileVpnIPKind(trimmed); ok {
		if !zoned {
			return true
		}
		return false
	}
	colon := strings.LastIndex(trimmed, ":")
	if colon >= 0 {
		if strings.Index(trimmed, ":") != colon {
			return false
		}
		if profileVpnAllDigits(trimmed[colon+1:]) {
			return false
		}
		return false
	}
	digitsOnly := true
	for index := 0; index < len(trimmed); index++ {
		if !((trimmed[index] >= '0' && trimmed[index] <= '9') || trimmed[index] == '.') {
			digitsOnly = false
			break
		}
	}
	if digitsOnly {
		return false
	}
	name := profileVpnToACE(trimmed)
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

// profileVpnToACE is Hosts.toAce: a lower-cased LDH name with non-ASCII labels
// converted to ACE; "" when the name fails the hostname rules.
func profileVpnToACE(host string) string {
	if host == "" || strings.HasPrefix(host, ".") {
		return ""
	}
	trailingDot := strings.HasSuffix(host, ".")
	body := strings.TrimSuffix(host, ".")
	labels := strings.Split(body, ".")
	out := make([]string, 0, len(labels))
	for _, label := range labels {
		if label == "" || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return ""
		}
		converted := label
		if configIsASCII(label) {
			converted = strings.ToLower(label)
		} else {
			ace, ok := configToACE(label)
			if !ok {
				return ""
			}
			converted = ace
		}
		if !profileVpnValidASCIILabel(converted) {
			return ""
		}
		out = append(out, converted)
	}
	result := strings.Join(out, ".")
	if trailingDot {
		result += "."
	}
	return result
}

func profileVpnValidASCIILabel(label string) bool {
	if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
		return false
	}
	for index := 0; index < len(label); index++ {
		char := label[index]
		if !((char >= 'a' && char <= 'z') || (char >= '0' && char <= '9') || char == '-' || char == '_') {
			return false
		}
	}
	return true
}

// --- OpenVpnChecks ---------------------------------------------------------

var profileOpenVPNCBCCiphers = map[string]bool{
	"BF-CBC": true, "DES-CBC": true, "DES-EDE-CBC": true, "DES-EDE3-CBC": true,
	"CAST5-CBC": true, "AES-128-CBC": true, "AES-192-CBC": true, "AES-256-CBC": true,
	"ARIA-128-CBC": true, "ARIA-192-CBC": true, "ARIA-256-CBC": true,
	"CAMELLIA-128-CBC": true, "CAMELLIA-192-CBC": true, "CAMELLIA-256-CBC": true,
	"SEED-CBC": true, "SM4-CBC": true,
}

var profileOpenVPNAEADCiphers = map[string]bool{
	"AES-128-GCM": true, "AES-192-GCM": true, "AES-256-GCM": true, "CHACHA20-POLY1305": true,
}

var profileOpenVPNDigests = []string{
	"SHA1", "SHA224", "SHA256", "SHA384", "SHA512", "RIPEMD160", "MD5", "NONE",
}

var profileOpenVPNEKUNames = map[string]bool{
	"server": true, "client": true, "TLS Web Server Authentication": true,
	"TLS Web Client Authentication": true, "Code Signing": true,
	"E-mail Protection": true, "IPSec End System": true, "IPSec Tunnel": true,
	"IPSec User": true, "Time Stamping": true, "OCSP Signing": true,
	"Any Extended Key Usage": true, "Microsoft Server Gated Crypto": true,
	"Netscape Server Gated Crypto": true, "Microsoft Commercial Code Signing": true,
	"Microsoft Individual Code Signing": true,
}

var profileOpenVPNTLSCiphers = map[string]bool{
	"RC4-SHA": true, "DES-CBC3-SHA": true, "AES128-SHA": true, "AES256-SHA": true,
	"AES128-SHA256": true, "AES128-GCM-SHA256": true, "AES256-GCM-SHA384": true,
	"ECDHE-ECDSA-AES128-SHA": true, "ECDHE-ECDSA-AES256-SHA": true,
	"ECDHE-ECDSA-RC4-SHA": true, "ECDHE-RSA-RC4-SHA": true,
	"ECDHE-RSA-DES-CBC3-SHA": true, "ECDHE-RSA-AES128-SHA": true,
	"ECDHE-RSA-AES256-SHA": true, "ECDHE-ECDSA-AES128-SHA256": true,
	"ECDHE-RSA-AES128-SHA256": true, "ECDHE-ECDSA-AES128-GCM-SHA256": true,
	"ECDHE-RSA-AES128-GCM-SHA256": true, "ECDHE-ECDSA-AES256-GCM-SHA384": true,
	"ECDHE-RSA-AES256-GCM-SHA384": true, "ECDHE-ECDSA-CHACHA20-POLY1305": true,
	"ECDHE-RSA-CHACHA20-POLY1305": true,
	"TLS_RSA_WITH_RC4_128_SHA":    true, "TLS_RSA_WITH_3DES_EDE_CBC_SHA": true,
	"TLS_RSA_WITH_AES_128_CBC_SHA": true, "TLS_RSA_WITH_AES_256_CBC_SHA": true,
	"TLS_RSA_WITH_AES_128_CBC_SHA256": true, "TLS_RSA_WITH_AES_128_GCM_SHA256": true,
	"TLS_RSA_WITH_AES_256_GCM_SHA384":      true,
	"TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA": true,
	"TLS_ECDHE_ECDSA_WITH_AES_256_CBC_SHA": true,
	"TLS_ECDHE_ECDSA_WITH_RC4_128_SHA":     true, "TLS_ECDHE_RSA_WITH_RC4_128_SHA": true,
	"TLS_ECDHE_RSA_WITH_3DES_EDE_CBC_SHA":           true,
	"TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA":            true,
	"TLS_ECDHE_RSA_WITH_AES_256_CBC_SHA":            true,
	"TLS_ECDHE_ECDSA_WITH_AES_128_CBC_SHA256":       true,
	"TLS_ECDHE_RSA_WITH_AES_128_CBC_SHA256":         true,
	"TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256":       true,
	"TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256":         true,
	"TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384":       true,
	"TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384":         true,
	"TLS_ECDHE_ECDSA_WITH_CHACHA20_POLY1305_SHA256": true,
	"TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256":   true,
}

var profileOpenVPNTLSGroups = map[string]bool{
	"X25519": true, "CURVE25519": true, "SECP256R1": true, "PRIME256V1": true,
	"P-256": true, "NISTP256": true, "SECP384R1": true, "P-384": true,
	"NISTP384": true, "SECP521R1": true, "P-521": true, "NISTP521": true,
}

// profileOpenVPNStaticCipher is sing-openvpn staticCipherKeySize.
func profileOpenVPNStaticCipher(name string) bool {
	return name == "NONE" || profileOpenVPNCBCCiphers[name]
}

// profileOpenVPNDataCipher is sing-openvpn validateDataCipherName: the static
// ciphers, the AEADs and the -CFB/-OFB form of a CBC cipher.
func profileOpenVPNDataCipher(name string) bool {
	if profileOpenVPNStaticCipher(name) || profileOpenVPNAEADCiphers[name] {
		return true
	}
	if strings.HasSuffix(name, "-CFB") || strings.HasSuffix(name, "-OFB") {
		return profileOpenVPNCBCCiphers[name[:len(name)-4]+"-CBC"]
	}
	return false
}

// profileOpenVPNCipherNameMessage is OpenVpnChecks.openVpnCipherName: names are
// checked upper-cased, as the editors save them and the build emits them.
func profileOpenVPNCipherNameMessage(name string) string {
	upper, ok := profileNewASCIIUpper(profileVpnTrimmed(name))
	if !ok {
		return "must be an OpenVPN cipher name"
	}
	if upper == "" || profileOpenVPNDataCipher(upper) {
		return ""
	}
	if strings.Contains(upper, ":") {
		return "lists one cipher only; use data_ciphers for a list"
	}
	return "is not a cipher the core supports"
}

// profileOpenVPNDigestMessage is OpenVpnChecks.openVpnDigest.
func profileOpenVPNDigestMessage(name string) string {
	upper, ok := profileNewASCIIUpper(profileVpnTrimmed(name))
	if !ok {
		return "is not a digest"
	}
	if upper == "" {
		return ""
	}
	for _, digest := range profileOpenVPNDigests {
		if digest == upper {
			return ""
		}
	}
	return "must be one of SHA1, SHA224, SHA256, SHA384, SHA512, RIPEMD160, MD5 or NONE"
}

// profileOpenVPNKeyUsageOK is OpenVpnChecks.openVpnKeyUsage:
// Validation.hex(item, 1, 16, evenLength = false).
func profileOpenVPNKeyUsageOK(item string) bool {
	trimmed := profileVpnTrimmed(item)
	if trimmed == "" {
		return true
	}
	if len(trimmed) < 1 || len(trimmed) > 16 {
		return false
	}
	for index := 0; index < len(trimmed); index++ {
		if _, ok := configHexDigit(trimmed[index]); !ok {
			return false
		}
	}
	return true
}

// profileOpenVPNExtendedKeyUsageMessage is
// OpenVpnChecks.openVpnExtendedKeyUsage: an OpenSSL purpose name or a dotted
// OID.
func profileOpenVPNExtendedKeyUsageMessage(text string) string {
	value := profileVpnTrimmed(text)
	if value == "" || profileOpenVPNEKUNames[value] {
		return ""
	}
	parts := strings.Split(value, ".")
	oid := len(parts) >= 2
	if oid {
		for _, part := range parts {
			if part == "" || len(part) > 9 {
				oid = false
				break
			}
			for index := 0; index < len(part); index++ {
				if part[index] < '0' || part[index] > '9' {
					oid = false
					break
				}
			}
			if !oid {
				break
			}
		}
	}
	if oid {
		return ""
	}
	return "must be an OpenSSL purpose name or a dotted OID"
}

// profileOpenVPNNormalizeTLSCipher is OpenVpnChecks.openVpnNormalizeTlsCipher:
// OpenVPN's TLS-ECDHE-RSA-WITH-... spelling becomes the TLS_ECDHE_RSA_WITH_...
// name the core knows.
func profileOpenVPNNormalizeTLSCipher(text string) string {
	parts := strings.Split(profileVpnTrimmed(text), ":")
	for index, token := range parts {
		upper := strings.ToUpper(token)
		if strings.HasPrefix(upper, "TLS-") && strings.Contains(upper, "-WITH-") {
			parts[index] = strings.ReplaceAll(upper, "-", "_")
		}
	}
	return strings.Join(parts, ":")
}

// profileOpenVPNTLSCipherMessage is OpenVpnChecks.openVpnTlsCipher: its OpenSSL
// table or Go's name for the same suites.
func profileOpenVPNTLSCipherMessage(text string) string {
	value := profileOpenVPNNormalizeTLSCipher(text)
	if value == "" {
		return ""
	}
	for _, token := range strings.Split(value, ":") {
		if token == "" {
			return "has an empty entry"
		}
		if !profileOpenVPNTLSCiphers[token] {
			return fmt.Sprintf("%q is not a TLS cipher suite the core knows", token)
		}
	}
	return ""
}

// profileOpenVPNTLSGroupsMessage is OpenVpnChecks.openVpnTlsGroups, after the
// upper-casing the build applies.
func profileOpenVPNTLSGroupsMessage(text string) string {
	value := strings.ToUpper(profileVpnTrimmed(text))
	if value == "" {
		return ""
	}
	for _, token := range strings.Split(value, ":") {
		if token == "" {
			return "has an empty entry"
		}
		if !profileOpenVPNTLSGroups[token] {
			return fmt.Sprintf("%q is not a TLS group the core knows", token)
		}
	}
	return ""
}

// profileOpenVPNDurationRuleMessage is sing-openvpn validateDurationOption, plus
// validatePingDurationOption's whole seconds.
func profileOpenVPNDurationRuleMessage(text string, wholeSeconds bool) string {
	if message := profileVpnDurationMessage(text, wholeSeconds, false, -1); message != "" {
		return message
	}
	ns, ok := profileVpnDurationNs(text)
	if !ok {
		ns = 0
	}
	if ns > 0 && ns < 1000000000 {
		return "must be 0 or at least 1s"
	}
	return ""
}

// profileOpenVPNIntervalOK is OpenVpnChecks.openVpnInterval.
func profileOpenVPNIntervalOK(text string) bool {
	return profileOpenVPNDurationRuleMessage(text, false) == ""
}

// profileOpenVPNPingIntervalOK is OpenVpnChecks.openVpnPingInterval.
func profileOpenVPNPingIntervalOK(text string) bool {
	return profileOpenVPNDurationRuleMessage(text, true) == ""
}

// profileOpenVPNReplayWindowTimeMessage is
// OpenVpnChecks.openVpnReplayWindowTime.
func profileOpenVPNReplayWindowTimeMessage(text string) string {
	return profileVpnDurationMessage(text, true, false, 600*1000000000)
}

// profileOpenVPNOpenVPNFragmentMessage is OpenVpnChecks.openVpnFragment.
func profileOpenVPNOpenVPNFragmentMessage(text string) string {
	if message := profileVpnIntMessage(text, 0, 65535); message != "" {
		return message
	}
	value, _ := profileVpnParseLong(profileVpnTrimmed(text))
	if value > 0 && value < 68 {
		return "must be at least 68 bytes"
	}
	return ""
}

// profileOpenVPNReplayWindowMessage is OpenVpnChecks.openVpnReplayWindow.
func profileOpenVPNReplayWindowMessage(text string) string {
	return profileVpnIntMessage(text, 0, 65536)
}

// profileOpenVPNPortMessage is Validation.port over a raw `.ovpn` value.
func profileOpenVPNPortMessage(text string) string { return profileVpnPortMessage(text) }

// profileOpenVPNIntMessage is Validation.int over a raw `.ovpn` value.
func profileOpenVPNIntMessage(text string, min, max int64) string {
	return profileVpnIntMessage(text, min, max)
}

// profileOpenVPNIPMessage is Validation.ip over a raw `.ovpn` value.
func profileOpenVPNIPMessage(text string, family int, emptyAllowed bool) string {
	return profileVpnIPMessage(text, family, emptyAllowed)
}

// profileOpenVPNRemoteHostMessage is OpenVpnChecks.openVpnRemoteHost:
// resolveClientRemotes refuses whitespace and brackets.
func profileOpenVPNRemoteHostMessage(text string) string {
	host := profileVpnTrimmed(text)
	if strings.HasPrefix(host, "[") || strings.HasSuffix(host, "]") {
		return "must not be bracketed; the endpoint brackets IPv6 itself"
	}
	if !profileVpnHostOK(host) {
		return "is not a valid host"
	}
	return ""
}
