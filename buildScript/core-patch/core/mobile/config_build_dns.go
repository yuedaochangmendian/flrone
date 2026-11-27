// DNS addresses, DNS objects and predefined (hosts-file) answers for the
// config builder, ported from DnsServers.kt (ParseDnsAddress, buildDnsObj,
// routeExcludePrefix, PredefinedDns).
package mobile

import (
	"net/netip"
	"regexp"
	"strconv"
	"strings"
)

var (
	configDNSInterfacePattern = regexp.MustCompile(`^[^\s/]+$`)
	configDNSIPv4LikePattern  = regexp.MustCompile(`^[0-9.]+$`)
	configDNSPortPattern      = regexp.MustCompile(`^[0-9]{1,5}$`)
)

// configDNSAddress is DnsAddress: port 0 means the type's default, iface is
// empty for dhcp://auto.
type configDNSAddress struct {
	typ    string
	server string
	port   int
	path   string
	iface  string
}

// configParseDNSAddress is DnsServers.parseDnsAddress: "local...",
// "dhcp://auto|<iface>", "udp|tcp|tls|quic://host[:port]",
// "https|h3://host[:port][/path]" or a bare "host[:port]" (udp).
func configParseDNSAddress(text string) (configDNSAddress, bool) {
	address := strings.TrimSpace(text)
	if address == "" {
		return configDNSAddress{}, false
	}
	if strings.HasPrefix(strings.ToLower(address), "local") {
		return configDNSAddress{typ: "local"}, true
	}
	schemeEnd := strings.Index(address, "://")
	scheme := "udp"
	rest := address
	if schemeEnd >= 0 {
		scheme = strings.ToLower(address[:schemeEnd])
		rest = address[schemeEnd+3:]
	}
	if scheme == "dhcp" {
		if rest == "" || !configDNSInterfacePattern.MatchString(rest) {
			return configDNSAddress{}, false
		}
		if strings.EqualFold(rest, "auto") {
			return configDNSAddress{typ: "dhcp"}, true
		}
		return configDNSAddress{typ: "dhcp", iface: rest}, true
	}
	if !configOneOf("udp", "tcp", "tls", "quic", "https", "h3")(scheme) {
		return configDNSAddress{}, false
	}
	path := ""
	if slash := strings.IndexByte(rest, '/'); slash >= 0 {
		if !configOneOf("https", "h3")(scheme) {
			return configDNSAddress{}, false
		}
		path = rest[slash:]
		rest = rest[:slash]
	}
	host := rest
	portText := ""
	hasPort := false
	if strings.HasPrefix(rest, "[") {
		closeIndex := strings.Index(rest, "]")
		if closeIndex < 0 {
			return configDNSAddress{}, false
		}
		host = rest[1:closeIndex]
		tail := rest[closeIndex+1:]
		if tail != "" {
			if !strings.HasPrefix(tail, ":") {
				return configDNSAddress{}, false
			}
			portText = tail[1:]
			hasPort = true
		}
		if !configIsIPv6Literal(host, true) {
			return configDNSAddress{}, false
		}
	} else if strings.Count(rest, ":") > 1 {
		if !configIsIPv6Literal(rest, true) {
			return configDNSAddress{}, false
		}
	} else {
		if colon := strings.IndexByte(rest, ':'); colon >= 0 {
			host = rest[:colon]
			portText = rest[colon+1:]
			hasPort = true
		}
		if host == "" {
			return configDNSAddress{}, false
		}
		if configDNSIPv4LikePattern.MatchString(host) {
			if !configIsCanonicalIPv4(host) {
				return configDNSAddress{}, false
			}
		} else if !configIsHostname(configToACEHost(host)) {
			return configDNSAddress{}, false
		}
	}
	port := 0
	if hasPort {
		if portText == "" {
			return configDNSAddress{}, false
		}
		if configDNSPortPattern.MatchString(portText) {
			port, _ = strconv.Atoi(portText)
		}
		if port < 1 || port > 65535 {
			return configDNSAddress{}, false
		}
	}
	return configDNSAddress{typ: scheme, server: configToACEHost(host), port: port, path: path}, true
}

// configToACEHost is Hosts.toAceHost for the ASCII subset this builder
// reproduces: an ASCII host is returned unchanged, exactly like the
// QUrl::toAce shortcut (so its case survives into the config). A non-ASCII
// name would need punycode; it is lower-cased as a best effort rather than
// silently changing an ASCII name.
func configToACEHost(host string) string {
	for index := 0; index < len(host); index++ {
		if host[index] >= 0x80 {
			return strings.ToLower(host)
		}
	}
	return host
}

// configIsHostname is the HOSTNAME regex from DnsServers.kt without its
// lookahead (Go's RE2 has no lookaround): 1-253 characters before an optional
// trailing dot, labels of 1-63 characters that start and end with
// [A-Za-z0-9_] and may carry [A-Za-z0-9_-] in between.
func configIsHostname(text string) bool {
	trimmed := strings.TrimSuffix(text, ".")
	if trimmed == "" || len(trimmed) > 253 {
		return false
	}
	for _, label := range strings.Split(trimmed, ".") {
		if len(label) == 0 || len(label) > 63 {
			return false
		}
		if !configHostnameEdge(label[0]) || !configHostnameEdge(label[len(label)-1]) {
			return false
		}
		for index := 1; index < len(label)-1; index++ {
			character := label[index]
			if !configHostnameEdge(character) && character != '-' {
				return false
			}
		}
	}
	return true
}

func configHostnameEdge(character byte) bool {
	return (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
		(character >= '0' && character <= '9') || character == '_'
}

// configHostsIsIPAddress is Hosts.isIpAddress: a C-style IPv4 literal, or a
// bracketed/zoned IPv6 literal.
func configHostsIsIPAddress(text string) bool {
	if _, ok := configHostsParseIPv4(text); ok {
		return true
	}
	bare := strings.TrimPrefix(strings.TrimSuffix(text, "]"), "[")
	if percent := strings.IndexByte(bare, '%'); percent >= 0 {
		bare = bare[:percent]
	}
	if !strings.Contains(bare, ":") {
		return false
	}
	address, err := netip.ParseAddr(bare)
	return err == nil && address.Is6()
}

func configIsCanonicalDecimal(text string, maxDigits int) bool {
	if text == "" || len(text) > maxDigits {
		return false
	}
	if len(text) > 1 && text[0] == '0' {
		return false
	}
	for _, character := range text {
		if character < '0' || character > '9' {
			return false
		}
	}
	return true
}

// configIsCanonicalIPv4 is isCanonicalIPv4: four decimal octets, no leading
// zero, at most 255.
func configIsCanonicalIPv4(text string) bool {
	octets := strings.Split(text, ".")
	if len(octets) != 4 {
		return false
	}
	for _, octet := range octets {
		if !configIsCanonicalDecimal(octet, 3) {
			return false
		}
		value, _ := strconv.Atoi(octet)
		if value > 255 {
			return false
		}
	}
	return true
}

// configIsIPv6Literal is isIPv6Literal: QHostAddress's IPv6 parse, a zone
// allowed only with allowZone.
func configIsIPv6Literal(text string, allowZone bool) bool {
	if !strings.Contains(text, ":") {
		return false
	}
	if !allowZone && strings.Contains(text, "%") {
		return false
	}
	percent := strings.IndexByte(text, '%')
	if percent == len(text)-1 {
		return false
	}
	bare := text
	if percent >= 0 {
		bare = text[:percent]
	}
	address, err := netip.ParseAddr(bare)
	return err == nil && address.Is6()
}

// configRouteExcludePrefix is DnsServers.routeExcludePrefix: the core decodes
// route_exclude_address as netip.Prefix, so a bare address gets its full
// length; empty when unparsable.
func configRouteExcludePrefix(rangeText string) string {
	text := strings.TrimSpace(rangeText)
	slash := strings.IndexByte(text, '/')
	addr := text
	if slash >= 0 {
		addr = text[:slash]
	}
	maxBits := -1
	if configIsCanonicalIPv4(addr) {
		maxBits = 32
	} else if configIsIPv6Literal(addr, false) {
		maxBits = 128
	}
	if maxBits < 0 {
		return ""
	}
	if slash < 0 {
		return addr + "/" + strconv.Itoa(maxBits)
	}
	bits := text[slash+1:]
	if !configIsCanonicalDecimal(bits, 3) {
		return ""
	}
	value, _ := strconv.Atoi(bits)
	if value > maxBits {
		return ""
	}
	return text
}

// configBuildDNSObj is DnsServers.buildDnsObj.
func configBuildDNSObj(address string) map[string]any {
	parsed, ok := configParseDNSAddress(address)
	if !ok {
		return configLegacyDNSObj(address)
	}
	if parsed.typ == "local" {
		return map[string]any{"type": "local"}
	}
	if parsed.typ == "dhcp" {
		return map[string]any{"type": "dhcp", "interface": parsed.iface}
	}
	result := map[string]any{"type": parsed.typ, "server": parsed.server}
	if parsed.port > 0 {
		result["server_port"] = parsed.port
	}
	if parsed.path != "" {
		result["path"] = parsed.path
	}
	return result
}

// configLegacyDNSObj is DnsServers.legacyDnsObj, the pre-ParseDnsAddress split
// kept for addresses the parser refuses.
func configLegacyDNSObj(address string) map[string]any {
	if strings.HasPrefix(address, "local") {
		return map[string]any{"type": "local"}
	}
	if strings.HasPrefix(address, "dhcp://") {
		ifaceName := strings.ReplaceAll(address, "dhcp://", "")
		if ifaceName == "auto" {
			ifaceName = ""
		}
		return map[string]any{"type": "dhcp", "interface": ifaceName}
	}
	addr := address
	port := -1
	typ := "udp"
	path := ""
	if strings.HasPrefix(address, "udp://") {
		addr = addr[6:]
	}
	if strings.HasPrefix(address, "tcp://") {
		typ = "tcp"
		addr = strings.ReplaceAll(addr, "tcp://", "")
	}
	if strings.HasPrefix(address, "tls://") {
		typ = "tls"
		addr = strings.ReplaceAll(addr, "tls://", "")
	}
	if strings.HasPrefix(address, "quic://") {
		typ = "quic"
		addr = strings.ReplaceAll(addr, "quic://", "")
	}
	if strings.HasPrefix(address, "https://") {
		typ = "https"
		addr = strings.ReplaceAll(addr, "https://", "")
		if slashIndex := strings.IndexByte(addr, '/'); slashIndex != -1 {
			path = addr[slashIndex:]
			addr = addr[:slashIndex]
		}
	}
	if strings.HasPrefix(address, "h3://") {
		typ = "h3"
		addr = strings.ReplaceAll(addr, "h3://", "")
		if slashIndex := strings.IndexByte(addr, '/'); slashIndex != -1 {
			path = addr[slashIndex:]
			addr = addr[:slashIndex]
		}
	}
	if strings.Contains(addr, ":") {
		parts := strings.Split(addr, ":")
		addr = parts[0]
		port = configQtToInt(parts[1])
	}
	result := map[string]any{"type": typ, "server": addr}
	if port != -1 {
		result["server_port"] = port
	}
	if path != "" {
		result["path"] = path
	}
	return result
}

// configPredefinedDNSEntry is PredefinedDNSEntry: one hosts-file domain with
// its IPv4 and IPv6 answers in file order.
type configPredefinedDNSEntry struct {
	domain string
	v4     []string
	v6     []string
}

// configParsePredefinedDNS is PredefinedDns.parse: hosts-file lines of an
// address followed by domains, `#` comments. Nil when any non-empty line is
// malformed (the caller then emits no predefined rules at all).
func configParsePredefinedDNS(lines []string) []configPredefinedDNSEntry {
	out := make([]configPredefinedDNSEntry, 0, len(lines))
	indexByDomain := make(map[string]int)
	for _, rawLine := range lines {
		line := rawLine
		if hash := strings.IndexByte(line, '#'); hash != -1 {
			line = line[:hash]
		}
		fields := strings.Fields(line)
		if len(fields) == 0 {
			continue
		}
		if len(fields) < 2 {
			return nil
		}
		address, ipv6, ok := configNormalizePredefinedAddress(fields[0])
		if !ok {
			return nil
		}
		for _, rawDomain := range fields[1:] {
			domain := strings.ToLower(rawDomain)
			domain = strings.TrimRight(domain, ".")
			if domain == "" {
				return nil
			}
			index, exists := indexByDomain[domain]
			if !exists {
				out = append(out, configPredefinedDNSEntry{domain: domain})
				index = len(out) - 1
				indexByDomain[domain] = index
			}
			bucket := &out[index].v4
			if ipv6 {
				bucket = &out[index].v6
			}
			if !configContainsString(*bucket, address) {
				*bucket = append(*bucket, address)
			}
		}
	}
	return out
}

// configNormalizePredefinedAddress is PredefinedDns.normalizeAddress:
// QHostAddress::setAddress + toString, answering the normalised text and
// whether it is IPv6.
func configNormalizePredefinedAddress(text string) (string, bool, bool) {
	bare := strings.TrimPrefix(strings.TrimSuffix(text, "]"), "[")
	withoutZone := bare
	if percent := strings.IndexByte(bare, '%'); percent >= 0 {
		withoutZone = bare[:percent]
	}
	if strings.Contains(withoutZone, ":") {
		address, err := netip.ParseAddr(withoutZone)
		if err != nil || !address.Is6() {
			return "", false, false
		}
		return configFormatIPv6(address.As16()), true, true
	}
	value, ok := configHostsParseIPv4(withoutZone)
	if !ok {
		return "", false, false
	}
	return configFormatIPv4(value), false, true
}

// configHostsParseIPv4 is Hosts.parseIpv4: QIPAddressUtils::parseIp4's one to
// four dot-separated C-style numbers (decimal, 0x hex, leading-zero octal), the
// last one covering the remaining octets.
func configHostsParseIPv4(text string) (uint32, bool) {
	if text == "" {
		return 0, false
	}
	parts := strings.Split(text, ".")
	if len(parts) > 4 {
		return 0, false
	}
	var address uint32
	for index, part := range parts {
		value, ok := configParseCNumber(part)
		if !ok {
			return 0, false
		}
		if index != len(parts)-1 || len(parts) == 4 {
			if value > 0xFF {
				return 0, false
			}
			address = address<<8 | value
			continue
		}
		switch len(parts) {
		case 3:
			if value > 0xFFFF {
				return 0, false
			}
			address = address<<16 | value
		case 2:
			if value > 0xFFFFFF {
				return 0, false
			}
			address = address<<24 | value
		default:
			address = value
		}
	}
	return address, true
}

// configParseCNumber is Hosts.parseCNumber: the leading 0x / 0 selects hex /
// octal, digits are ASCII only, and anything above 32 bits is refused.
func configParseCNumber(part string) (uint32, bool) {
	if part == "" {
		return 0, false
	}
	digits := part
	radix := uint32(10)
	if len(part) > 2 && part[0] == '0' && (part[1] == 'x' || part[1] == 'X') {
		digits = part[2:]
		radix = 16
	} else if len(part) > 1 && part[0] == '0' {
		digits = part[1:]
		radix = 8
	}
	if digits == "" {
		return 0, false
	}
	var value uint64
	for index := 0; index < len(digits); index++ {
		digit, ok := configHexDigit(digits[index])
		if !ok || uint32(digit) >= radix {
			return 0, false
		}
		value = value*uint64(radix) + uint64(digit)
		if value > 0xFFFFFFFF {
			return 0, false
		}
	}
	return uint32(value), true
}

// configFormatIPv4 is Hosts.formatIpv4: the four octets in decimal.
func configFormatIPv4(address uint32) string {
	return strconv.FormatUint(uint64(address>>24), 10) + "." +
		strconv.FormatUint(uint64((address>>16)&0xFF), 10) + "." +
		strconv.FormatUint(uint64((address>>8)&0xFF), 10) + "." +
		strconv.FormatUint(uint64(address&0xFF), 10)
}

// configFormatIPv6 is Hosts.formatIpv6: RFC 5952 text with `::` for the longest
// run of at least two zero groups, and an IPv4-mapped or IPv4-compatible tail
// as a dotted quad.
func configFormatIPv6(address [16]byte) string {
	embeddedIPv4 := false
	leadingZero := true
	for index := 0; index < 10; index++ {
		if address[index] != 0 {
			leadingZero = false
			break
		}
	}
	if leadingZero {
		if address[10] == 0xFF && address[11] == 0xFF {
			embeddedIPv4 = true
		} else if address[10] == 0 && address[11] == 0 {
			if address[12] != 0 || address[13] != 0 || address[14] != 0 {
				embeddedIPv4 = true
			} else if address[15] == 0 {
				return "::"
			}
		}
	}
	zeroRunLength := 0
	zeroRunOffset := 0
	for index := 0; index < 16; index += 2 {
		if address[index] != 0 || address[index+1] != 0 {
			continue
		}
		end := index
		for end < 16 && address[end] == 0 && address[end+1] == 0 {
			end += 2
		}
		if end-index > zeroRunLength {
			zeroRunLength = end - index
			zeroRunOffset = index
			index = end - 2
		}
	}
	var builder strings.Builder
	if zeroRunLength < 4 {
		zeroRunOffset = -1
	} else if zeroRunOffset == 0 {
		builder.WriteByte(':')
	}
	for index := 0; index < 16; index += 2 {
		if index == zeroRunOffset {
			builder.WriteByte(':')
			index += zeroRunLength - 2
			continue
		}
		if index == 12 && embeddedIPv4 {
			value := uint32(address[12])<<24 | uint32(address[13])<<16 | uint32(address[14])<<8 | uint32(address[15])
			builder.WriteString(configFormatIPv4(value))
			break
		}
		group := uint32(address[index])<<8 | uint32(address[index+1])
		builder.WriteString(strconv.FormatUint(uint64(group), 16))
		if index != 14 {
			builder.WriteByte(':')
		}
	}
	return builder.String()
}

func configContainsString(values []string, value string) bool {
	for _, existing := range values {
		if existing == value {
			return true
		}
	}
	return false
}
