// Prefix arithmetic for the config builder, ported from Cidrs.kt
// (generate.cpp:249-328): parsePrefix, prefixContains, prefixesOverlap and
// subtractPrefix. The tun's route_exclude_address is the one consumer: the
// saved private ranges minus every prefix the tun address itself covers.
package mobile

import (
	"net/netip"
	"strconv"
	"strings"
)

// configPrefix is one parsed prefix: an address with its host bits cleared and
// the prefix length. The address family is implied by the length (4 or 16
// bytes), exactly like QHostAddress::parseSubnet.
type configPrefix struct {
	addr netip.Addr
	bits int
}

// parseConfigPrefix is Cidrs.parse / QHostAddress::parseSubnet:
// `<ipv6>[/n]` (no length = 128) or `d[.d[.d[.d]]][/n]` with decimal octets,
// missing trailing octets zero and no length = 8 per given octet; the host bits
// are cleared. A malformed value is not a prefix.
func parseConfigPrefix(text string) (configPrefix, bool) {
	subnet := strings.TrimSpace(text)
	if subnet == "" {
		return configPrefix{}, false
	}
	slash := strings.IndexByte(subnet, '/')
	netText := subnet
	bits := -1
	if slash >= 0 {
		netText = subnet[:slash]
		parsed, ok := configDecimal(subnet[slash+1:])
		if !ok {
			return configPrefix{}, false
		}
		bits = parsed
	}
	if strings.Contains(netText, ":") {
		if bits > 128 {
			return configPrefix{}, false
		}
		if bits < 0 {
			bits = 128
		}
		addressText := netText
		if percent := strings.IndexByte(addressText, '%'); percent >= 0 {
			addressText = addressText[:percent]
		}
		address, err := netip.ParseAddr(addressText)
		if err != nil || !address.Is6() {
			return configPrefix{}, false
		}
		return configPrefix{addr: configClearHostBits(address, bits), bits: bits}, true
	}
	if bits > 32 {
		return configPrefix{}, false
	}
	parts := strings.Split(netText, ".")
	if len(parts) > 4 {
		return configPrefix{}, false
	}
	if parts[len(parts)-1] == "" {
		parts = parts[:len(parts)-1]
	}
	if len(parts) == 0 {
		return configPrefix{}, false
	}
	var octets [4]byte
	for index, part := range parts {
		value, ok := configDecimal(part)
		if !ok || value > 255 {
			return configPrefix{}, false
		}
		octets[index] = byte(value)
	}
	if bits < 0 {
		bits = 8 * len(parts)
	}
	address := netip.AddrFrom4(octets)
	return configPrefix{addr: configClearHostBits(address, bits), bits: bits}, true
}

// configDecimal is Cidrs.decimal: ASCII digits only, no sign, no spaces.
func configDecimal(text string) (int, bool) {
	if text == "" {
		return 0, false
	}
	for _, character := range text {
		if character < '0' || character > '9' {
			return 0, false
		}
	}
	value, err := strconv.Atoi(text)
	return value, err == nil
}

func configClearHostBits(address netip.Addr, bits int) netip.Addr {
	if address.Is4() {
		bytes := address.As4()
		configClearHostBitsBytes(bytes[:], bits)
		return netip.AddrFrom4(bytes)
	}
	bytes := address.As16()
	configClearHostBitsBytes(bytes[:], bits)
	return netip.AddrFrom16(bytes)
}

func configClearHostBitsBytes(bytes []byte, bits int) {
	for index := bits; index < len(bytes)*8; index++ {
		bytes[index/8] &^= 0x80 >> (index % 8)
	}
}

func (prefix configPrefix) String() string {
	if prefix.addr.Is4() {
		octets := prefix.addr.As4()
		value := uint32(octets[0])<<24 | uint32(octets[1])<<16 | uint32(octets[2])<<8 | uint32(octets[3])
		return configFormatIPv4(value) + "/" + strconv.Itoa(prefix.bits)
	}
	return configFormatIPv6(prefix.addr.As16()) + "/" + strconv.Itoa(prefix.bits)
}

// contains is Cidrs.contains: same family and inner lies inside outer.
func (prefix configPrefix) contains(inner configPrefix) bool {
	if prefix.addr.Is4() != inner.addr.Is4() || prefix.bits > inner.bits {
		return false
	}
	if prefix.addr.Is4() {
		outerBytes, innerBytes := prefix.addr.As4(), inner.addr.As4()
		return configPrefixContains(outerBytes[:], innerBytes[:], prefix.bits)
	}
	outerBytes, innerBytes := prefix.addr.As16(), inner.addr.As16()
	return configPrefixContains(outerBytes[:], innerBytes[:], prefix.bits)
}

func configPrefixContains(outer, inner []byte, bits int) bool {
	for index := 0; index < bits; index++ {
		outerBit := (outer[index/8] >> (7 - index%8)) & 1
		innerBit := (inner[index/8] >> (7 - index%8)) & 1
		if outerBit != innerBit {
			return false
		}
	}
	return true
}

// configCIDROverlap is Cidrs.overlap: same family and one contains the other;
// malformed input never overlaps.
func configCIDROverlap(lhs, rhs string) bool {
	left, leftOK := parseConfigPrefix(lhs)
	right, rightOK := parseConfigPrefix(rhs)
	if !leftOK || !rightOK {
		return false
	}
	if left.bits <= right.bits {
		return left.contains(right)
	}
	return right.contains(left)
}

// configSubtractCIDR is Cidrs.subtract / subtractPrefix: a range inside hole is
// dropped, a range that holds the hole is replaced by the sibling prefixes of
// every level between the two lengths, anything else is kept verbatim.
func configSubtractCIDR(ranges []string, hole string) []string {
	cut, ok := parseConfigPrefix(hole)
	if !ok {
		return ranges
	}
	out := make([]string, 0, len(ranges))
	for _, entry := range ranges {
		rangePrefix, rangeOK := parseConfigPrefix(entry)
		if rangeOK && cut.contains(rangePrefix) {
			continue
		}
		if !rangeOK || !rangePrefix.contains(cut) {
			out = append(out, entry)
			continue
		}
		for bits := rangePrefix.bits + 1; bits <= cut.bits; bits++ {
			sibling := cut.addr
			if sibling.Is4() {
				bytes := sibling.As4()
				bytes[(bits-1)/8] ^= 0x80 >> ((bits - 1) % 8)
				sibling = netip.AddrFrom4(bytes)
			} else {
				bytes := sibling.As16()
				bytes[(bits-1)/8] ^= 0x80 >> ((bits - 1) % 8)
				sibling = netip.AddrFrom16(bytes)
			}
			sibling = configClearHostBits(sibling, bits)
			out = append(out, configPrefix{addr: sibling, bits: bits}.String())
		}
	}
	return out
}
