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

// configToACEHost approximates Hosts.toAceHost: the stored host is already an
// ASCII IDNA name from the profile editor; lowercase it for the check and the
// output. Non-ASCII names are outside the Stage-1 fixture surface.
func configToACEHost(host string) string {
	return strings.ToLower(host)
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
		return address.String(), true, true
	}
	address, err := netip.ParseAddr(withoutZone)
	if err != nil || !address.Is4() {
		return "", false, false
	}
	return address.String(), false, true
}

func configContainsString(values []string, value string) bool {
	for _, existing := range values {
		if existing == value {
			return true
		}
	}
	return false
}
