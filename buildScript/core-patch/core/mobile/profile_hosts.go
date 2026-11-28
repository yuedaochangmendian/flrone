// QUrl host normalization (Hosts.kt): Qt's C-style IPv4 shorthand, RFC 4291
// IPv6 text form including the embedded-IPv4 spellings and zones, and the
// ACE/IDN rules shared with configToACE.
//
// The share-link importer used to refuse every host whose Qt spelling it could
// not reproduce (C-style numbers, bracketed zones, embedded IPv4); the port
// below makes the stored host byte-identical to Kotlin's
// Hosts.normalizeHost(raw, percentDecode = true), so those refusals are gone.
package mobile

import (
	"strconv"
	"strings"
)

// profileQtParseIPv4 is QIPAddressUtils::parseIp4: one to four dot-separated
// C-style numbers (decimal, 0x hex, leading-zero octal).
func profileQtParseIPv4(text string) (uint32, bool) {
	if text == "" {
		return 0, false
	}
	parts := strings.Split(text, ".")
	if len(parts) > 4 {
		return 0, false
	}
	address := uint32(0)
	for index, part := range parts {
		value, ok := profileQtParseCNumber(part)
		if !ok {
			return 0, false
		}
		last := index == len(parts)-1
		if !last || len(parts) == 4 {
			if value > 0xFF {
				return 0, false
			}
			address = (address << 8) | value
			continue
		}
		switch len(parts) {
		case 3:
			if value > 0xFFFF {
				return 0, false
			}
			address = (address << 16) | value
		case 2:
			if value > 0xFFFFFF {
				return 0, false
			}
			address = (address << 24) | value
		default:
			address = value
		}
	}
	return address, true
}

func profileQtParseCNumber(part string) (uint32, bool) {
	if part == "" {
		return 0, false
	}
	digits := part
	radix := uint32(10)
	switch {
	case len(part) > 2 && part[0] == '0' && (part[1] == 'x' || part[1] == 'X'):
		digits = part[2:]
		radix = 16
	case len(part) > 1 && part[0] == '0':
		digits = part[1:]
		radix = 8
	}
	if digits == "" {
		return 0, false
	}
	value := uint32(0)
	for index := 0; index < len(digits); index++ {
		char := digits[index]
		if char >= 0x80 {
			return 0, false
		}
		digit := profileQtDigitValue(char)
		if digit < 0 || uint32(digit) >= radix {
			return 0, false
		}
		value = value*radix + uint32(digit)
		if value > 0xFFFFFFFF {
			return 0, false
		}
	}
	return value, true
}

func profileQtDigitValue(char byte) int {
	switch {
	case char >= '0' && char <= '9':
		return int(char - '0')
	case char >= 'a' && char <= 'f':
		return int(char-'a') + 10
	case char >= 'A' && char <= 'F':
		return int(char-'A') + 10
	}
	return -1
}

func profileQtFormatIPv4(address uint32) string {
	return strconv.Itoa(int((address>>24)&0xFF)) + "." +
		strconv.Itoa(int((address>>16)&0xFF)) + "." +
		strconv.Itoa(int((address>>8)&0xFF)) + "." +
		strconv.Itoa(int(address&0xFF))
}

// profileQtParseIPv6 is Hosts.parseIpv6: RFC 4291 text form with "::", an
// optional trailing dotted quad and no zone.
func profileQtParseIPv6(text string) ([16]byte, bool) {
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
	headGroups, ok := profileQtParseGroups(head)
	if !ok {
		return out, false
	}
	tailGroups, ok := profileQtParseGroups(tail)
	if !ok {
		return out, false
	}
	var groups []int
	if double >= 0 {
		if len(headGroups)+len(tailGroups) > 7 {
			return out, false
		}
		groups = make([]int, 0, 8)
		groups = append(groups, headGroups...)
		for count := 8 - len(headGroups) - len(tailGroups); count > 0; count-- {
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

func profileQtParseGroups(part string) ([]int, bool) {
	if part == "" {
		return nil, true
	}
	items := strings.Split(part, ":")
	out := make([]int, 0, len(items)+1)
	for index, item := range items {
		if item == "" {
			return nil, false
		}
		if index == len(items)-1 && strings.Contains(item, ".") {
			value, ok := profileQtParseIPv4(item)
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
			digit := profileQtDigitValue(char)
			if digit < 0 || digit >= 16 {
				return nil, false
			}
			value = value*16 + digit
		}
		out = append(out, value)
	}
	return out, true
}

// profileQtFormatIPv6 is QIPAddressUtils::toString: the first longest run of
// at least two zero groups becomes "::", and ::ffff:a.b.c.d / ::a.b.c.d keep
// the dotted quad.
func profileQtFormatIPv6(address [16]byte) string {
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
	for index := 0; index < 16; {
		if address[index] == 0 && address[index+1] == 0 {
			end := index
			for end < 16 && address[end] == 0 && address[end+1] == 0 {
				end += 2
			}
			if end-index > zeroRunLength {
				zeroRunLength = end - index
				zeroRunOffset = index
				index = end
			}
		}
		index += 2
	}
	var builder strings.Builder
	if zeroRunLength < 4 {
		zeroRunOffset = -1
	} else if zeroRunOffset == 0 {
		builder.WriteByte(':')
	}
	for index := 0; index < 16; {
		if index == zeroRunOffset {
			builder.WriteByte(':')
			index += zeroRunLength
			continue
		}
		if index == 12 && embeddedIPv4 {
			value := uint32(address[12])<<24 | uint32(address[13])<<16 | uint32(address[14])<<8 | uint32(address[15])
			builder.WriteString(profileQtFormatIPv4(value))
			break
		}
		group := int(address[index])<<8 | int(address[index+1])
		builder.WriteString(profileQtFormatHex(group))
		if index != 14 {
			builder.WriteByte(':')
		}
		index += 2
	}
	return builder.String()
}

func profileQtFormatHex(value int) string {
	const digits = "0123456789abcdef"
	if value == 0 {
		return "0"
	}
	var buffer [4]byte
	position := len(buffer)
	for value > 0 {
		position--
		buffer[position] = digits[value&0xF]
		value >>= 4
	}
	return string(buffer[position:])
}

// profileQtNormalizeBracketed is Hosts.normalizeBracketed: "[addr]" or
// "[addr%zone]" (the stored form keeps the zone percent-encoded as %25).
func profileQtNormalizeBracketed(host string) (string, bool) {
	if !strings.HasSuffix(host, "]") || len(host) < 3 {
		return "", false
	}
	inner := host[1 : len(host)-1]
	address := inner
	zone := ""
	hasZone := false
	if index := strings.Index(inner, "%"); index >= 0 {
		address = inner[:index]
		zone = inner[index+1:]
		hasZone = true
	}
	if hasZone && zone == "" {
		return "", false
	}
	bytes, ok := profileQtParseIPv6(address)
	if !ok {
		return "", false
	}
	formatted := profileQtFormatIPv6(bytes)
	if hasZone {
		return formatted + "%25" + zone, true
	}
	return formatted, true
}

// profileHostNormalize is Hosts.normalizeHost(raw, percentDecode = true): the
// host QUrl stores for a parsed authority. The second result is false for a
// host QUrl rejects.
func profileHostNormalize(raw string) (string, bool) {
	host := profileLinkDecodeFully(profileLinkTolerant(raw))
	if host == "" {
		return "", true
	}
	if strings.HasPrefix(host, "[") {
		return profileQtNormalizeBracketed(host)
	}
	if !strings.Contains(host, "%") {
		if value, ok := profileQtParseIPv4(host); ok {
			return profileQtFormatIPv4(value), true
		}
		if ace, ok := configToACE(host); ok {
			return ace, true
		}
	}
	return "", false
}

// profileHostValidForStored accepts the server spellings a stored document
// carries: QUrl's normalized form for names and IPv4, and an unbracketed
// IPv6 literal (optionally zoned) for IPv6. Kotlin's parseFromJson keeps the
// server string as written, so this is a validity check, not a rewrite.
func profileHostValidForStored(server string) bool {
	text := server
	if strings.HasPrefix(text, "[") && strings.HasSuffix(text, "]") {
		text = text[1 : len(text)-1]
	}
	if strings.Contains(text, ":") {
		address := text
		if index := strings.Index(address, "%"); index >= 0 {
			address = address[:index]
		}
		_, ok := profileQtParseIPv6(address)
		return ok
	}
	_, ok := profileHostNormalize(server)
	return ok
}
