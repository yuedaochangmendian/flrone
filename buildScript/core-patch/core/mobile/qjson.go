package mobile

// Canonical compact JSON: byte-for-byte the output of the Kotlin JsonWriter that
// ConfigGenerator uses for its coreConfig strings.
//
// The Kotlin writer itself reproduces Qt's QJsonDocument::toJson(Compact) (see
// app/src/main/java/io/nekohasekai/sagernet/outbound/json/JsonWriter.kt), so the
// rules below are the parity contract a future Go config builder must meet:
//
//   - Objects serialise with keys sorted ascending by UTF-16 code unit, which is
//     Kotlin's String natural order. A supplementary character therefore sorts
//     by its surrogate pair (U+10000 before U+E000) — not by code point and not
//     by UTF-8 byte order.
//   - No whitespace. Empty objects and arrays are exactly {} and [].
//   - Strings escape only '"', '\\', the five named control escapes
//     (\b \t \n \f \r) and the remaining C0 controls as \u00xx with lowercase
//     hex. DEL (0x7F), '/' and every non-ASCII character are emitted literally
//     as UTF-8. Unpaired surrogates become \uxxxx (lowercase); a high+low pair
//     is emitted as the ordinary four-byte UTF-8 sequence.
//   - NaN and infinities become null.
//   - A finite double that is integral and within ±2^53 prints as a decimal
//     integer without a decimal point (443.0 -> 443, -0.0 -> 0, 2^53 ->
//     9007199254740992). Every other finite double prints the shortest
//     round-trip digits, laid out in whichever of the plain decimal or the
//     scientific form is shorter; ties go to the decimal form. The scientific
//     form has one digit before the point, a signed exponent and at least two
//     exponent digits ("1e+16", "1e-07", "5e-324").
//   - int/Long values print as plain decimal integers.
//
// Two things a Go string cannot express are pinned as follows:
//
//   - Kotlin strings are UTF-16 and can hold an unpaired surrogate. The writer
//     accepts such a code unit encoded as WTF-8 (bytes ED A0 80 .. ED BF BF) and
//     escapes it exactly as Kotlin would; a WTF-8 surrogate pair is emitted as
//     the matching four-byte UTF-8 character. Any other invalid UTF-8 is
//     rejected instead of silently emitting a broken JSON document.
//   - Kotlin has no unsigned integer wider than Long. uint64 values above
//     math.MaxInt64 are rejected rather than printed, because Kotlin's
//     JsonObject would have normalised them through a double and lost digits —
//     no byte-exact Kotlin output exists for them.

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// maxExactDouble is 2^53, the boundary Kotlin uses (and Qt's QJsonValue uses)
// between an integer-valued double and a floating-point value.
const maxExactDouble = 1 << 53

// MarshalCanonicalJSON encodes value to the compact canonical JSON form of the
// Kotlin JsonWriter. See the file comment for the exact rules.
//
// Supported values are nil, bool, string, every signed and unsigned integer
// type (uint64 only up to math.MaxInt64), float32, float64, map[string]any,
// []any and []string. Maps and slices may nest freely.
func MarshalCanonicalJSON(value any) ([]byte, error) {
	return AppendCanonicalJSON(nil, value)
}

// AppendCanonicalJSON is MarshalCanonicalJSON appending to dst. On error dst is
// returned unchanged so a caller can keep a buffer it owns.
func AppendCanonicalJSON(dst []byte, value any) ([]byte, error) {
	start := len(dst)
	out, err := appendCanonical(dst, value)
	if err != nil {
		return dst[:start], err
	}
	return out, nil
}

// formatCanonicalDouble is the Kotlin JsonWriter.formatDouble equivalent: the
// exact text a double occupies inside the canonical JSON output, including
// "null" for NaN and infinities.
func formatCanonicalDouble(value float64) string {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return "null"
	}
	if value == math.Trunc(value) && math.Abs(value) <= maxExactDouble {
		return strconv.FormatInt(int64(value), 10)
	}
	negative := value < 0
	body := formatShortestDecimal(math.Abs(value))
	if negative {
		return "-" + body
	}
	return body
}

func appendCanonical(dst []byte, value any) ([]byte, error) {
	switch v := value.(type) {
	case nil:
		return append(dst, "null"...), nil
	case bool:
		if v {
			return append(dst, "true"...), nil
		}
		return append(dst, "false"...), nil
	case string:
		return appendCanonicalString(dst, v)
	case int:
		return strconv.AppendInt(dst, int64(v), 10), nil
	case int8:
		return strconv.AppendInt(dst, int64(v), 10), nil
	case int16:
		return strconv.AppendInt(dst, int64(v), 10), nil
	case int32:
		return strconv.AppendInt(dst, int64(v), 10), nil
	case int64:
		return strconv.AppendInt(dst, v, 10), nil
	case uint:
		return appendCanonicalUint(dst, uint64(v))
	case uint8:
		return strconv.AppendUint(dst, uint64(v), 10), nil
	case uint16:
		return strconv.AppendUint(dst, uint64(v), 10), nil
	case uint32:
		return strconv.AppendUint(dst, uint64(v), 10), nil
	case uint64:
		return appendCanonicalUint(dst, v)
	case float32:
		// Kotlin's JsonValues.normalize widens Float to Double before writing;
		// Go's float64(float32) is the identical widening.
		return append(dst, formatCanonicalDouble(float64(v))...), nil
	case float64:
		return append(dst, formatCanonicalDouble(v)...), nil
	case []any:
		dst = append(dst, '[')
		for i, item := range v {
			if i > 0 {
				dst = append(dst, ',')
			}
			var err error
			dst, err = appendCanonical(dst, item)
			if err != nil {
				return dst, err
			}
		}
		return append(dst, ']'), nil
	case []string:
		dst = append(dst, '[')
		for i, item := range v {
			if i > 0 {
				dst = append(dst, ',')
			}
			var err error
			dst, err = appendCanonicalString(dst, item)
			if err != nil {
				return dst, err
			}
		}
		return append(dst, ']'), nil
	case map[string]any:
		keys, err := canonicalKeys(v)
		if err != nil {
			return dst, err
		}
		dst = append(dst, '{')
		for i, key := range keys {
			if i > 0 {
				dst = append(dst, ',')
			}
			dst, err = appendCanonicalString(dst, key.name)
			if err != nil {
				return dst, err
			}
			dst = append(dst, ':')
			dst, err = appendCanonical(dst, v[key.name])
			if err != nil {
				return dst, err
			}
		}
		return append(dst, '}'), nil
	default:
		return dst, fmt.Errorf("canonical json: unsupported value type %T", value)
	}
}

func appendCanonicalUint(dst []byte, value uint64) ([]byte, error) {
	if value > math.MaxInt64 {
		return dst, fmt.Errorf("canonical json: uint64 %d exceeds the Kotlin Long range", value)
	}
	return strconv.AppendUint(dst, value, 10), nil
}

// sortedKey carries the UTF-16 units used for the ordering so each key is
// decoded once instead of O(n log n) times.
type sortedKey struct {
	name  string
	units []uint16
}

func canonicalKeys(m map[string]any) ([]sortedKey, error) {
	keys := make([]sortedKey, 0, len(m))
	for name := range m {
		units, err := utf16Units(name)
		if err != nil {
			return nil, err
		}
		keys = append(keys, sortedKey{name: name, units: units})
	}
	sort.Slice(keys, func(i, j int) bool {
		return compareUTF16(keys[i].units, keys[j].units) < 0
	})
	for i := 1; i < len(keys); i++ {
		if compareUTF16(keys[i-1].units, keys[i].units) == 0 {
			return nil, fmt.Errorf("canonical json: keys %q and %q are the same UTF-16 sequence", keys[i-1].name, keys[i].name)
		}
	}
	return keys, nil
}

func compareUTF16(a, b []uint16) int {
	for i := 0; i < len(a) && i < len(b); i++ {
		if a[i] != b[i] {
			if a[i] < b[i] {
				return -1
			}
			return 1
		}
	}
	switch {
	case len(a) < len(b):
		return -1
	case len(a) > len(b):
		return 1
	default:
		return 0
	}
}

// decodeWTF8Surrogate decodes the three-byte WTF-8 form of a lone UTF-16
// surrogate (ED A0 80 .. ED BF BF). Go's utf8 decoder rejects those bytes, so
// they get their own path to stay byte-compatible with Kotlin strings that can
// hold an unpaired surrogate.
func decodeWTF8Surrogate(s string) (uint16, bool) {
	if len(s) < 3 || s[0] != 0xED || s[1] < 0xA0 || s[1] > 0xBF || s[2]&0xC0 != 0x80 {
		return 0, false
	}
	unit := uint16(0xD000) | uint16(s[1]&0x3F)<<6 | uint16(s[2]&0x3F)
	return unit, true
}

func utf16Units(s string) ([]uint16, error) {
	units := make([]uint16, 0, len(s))
	for i := 0; i < len(s); {
		if s[i] < utf8.RuneSelf {
			units = append(units, uint16(s[i]))
			i++
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r != utf8.RuneError || size > 1 {
			if r >= 0x10000 {
				r -= 0x10000
				units = append(units, uint16(0xD800+(r>>10)), uint16(0xDC00+(r&0x3FF)))
			} else {
				units = append(units, uint16(r))
			}
			i += size
			continue
		}
		unit, ok := decodeWTF8Surrogate(s[i:])
		if !ok {
			return nil, fmt.Errorf("canonical json: invalid UTF-8 at byte offset %d", i)
		}
		units = append(units, unit)
		i += 3
	}
	return units, nil
}

func appendCanonicalString(dst []byte, s string) ([]byte, error) {
	dst = append(dst, '"')
	for i := 0; i < len(s); {
		b := s[i]
		if b < utf8.RuneSelf {
			switch {
			case b == '"':
				dst = append(dst, '\\', '"')
			case b == '\\':
				dst = append(dst, '\\', '\\')
			case b < 0x20:
				switch b {
				case '\b':
					dst = append(dst, '\\', 'b')
				case '\t':
					dst = append(dst, '\\', 't')
				case '\n':
					dst = append(dst, '\\', 'n')
				case '\f':
					dst = append(dst, '\\', 'f')
				case '\r':
					dst = append(dst, '\\', 'r')
				default:
					dst = append(dst, '\\', 'u', '0', '0', hexLower(uint16(b>>4)), hexLower(uint16(b&0x0F)))
				}
			default:
				// Includes DEL, '/' and printable ASCII.
				dst = append(dst, b)
			}
			i++
			continue
		}
		r, size := utf8.DecodeRuneInString(s[i:])
		if r != utf8.RuneError || size > 1 {
			dst = append(dst, s[i:i+size]...)
			i += size
			continue
		}
		unit, ok := decodeWTF8Surrogate(s[i:])
		if !ok {
			return dst, fmt.Errorf("canonical json: invalid UTF-8 at byte offset %d", i)
		}
		// Kotlin emits a high+low pair literally. A pair arriving as two WTF-8
		// surrogates becomes the same four-byte UTF-8 sequence a Kotlin string
		// with that pair produces.
		if unit >= 0xD800 && unit <= 0xDBFF {
			if low, lowOK := decodeWTF8Surrogate(s[i+3:]); lowOK && low >= 0xDC00 && low <= 0xDFFF {
				codePoint := rune(0x10000) + (rune(unit)-0xD800)<<10 + (rune(low) - 0xDC00)
				dst = utf8.AppendRune(dst, codePoint)
				i += 6
				continue
			}
		}
		dst = append(dst, '\\', 'u', hexLower(unit>>12), hexLower((unit>>8)&0x0F), hexLower((unit>>4)&0x0F), hexLower(unit&0x0F))
		i += 3
	}
	return append(dst, '"'), nil
}

func hexLower(value uint16) byte {
	const digits = "0123456789abcdef"
	return digits[value&0x0F]
}

// formatShortestDecimal reproduces JsonWriter.formatDouble's body for a finite,
// positive, non-integral-or-large value: shortest round-trip digits, then the
// shorter of the plain decimal and the scientific layout.
func formatShortestDecimal(value float64) string {
	// 'e' with precision -1 yields the shortest digits in the form
	// "d[.ddd]e±XX", which is exactly what the Kotlin BigDecimal loop produces.
	text := strconv.FormatFloat(value, 'e', -1, 64)
	e := strings.IndexByte(text, 'e')
	mantissa := text[:e]
	exponent, _ := strconv.Atoi(text[e+1:])
	digits := strings.Replace(mantissa, ".", "", 1)
	decimalPoint := exponent + 1

	var plain string
	switch {
	case decimalPoint <= 0:
		plain = "0." + strings.Repeat("0", -decimalPoint) + digits
	case decimalPoint < len(digits):
		plain = digits[:decimalPoint] + "." + digits[decimalPoint:]
	default:
		plain = digits + strings.Repeat("0", decimalPoint-len(digits))
	}

	scientificExponent := decimalPoint - 1
	scientificMantissa := digits
	if len(digits) > 1 {
		scientificMantissa = digits[:1] + "." + digits[1:]
	}
	sign := "+"
	if scientificExponent < 0 {
		sign = "-"
	}
	exponentDigits := strconv.Itoa(int(math.Abs(float64(scientificExponent))))
	if len(exponentDigits) < 2 {
		exponentDigits = "0" + exponentDigits
	}
	scientific := scientificMantissa + "e" + sign + exponentDigits
	if len(scientific) < len(plain) {
		return scientific
	}
	return plain
}
