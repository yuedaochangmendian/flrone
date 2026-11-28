// JSON value helpers shared by the Stage-2 outbound parsers.
//
// Every helper here mirrors one named Kotlin/Throne conversion so a per-type
// parser reads a stored profiles.json row exactly like Outbound.parseFromJson:
// a value of the wrong JSON type yields the default, numbers go through the
// QJsonValue rules, and strings are only trimmed where the Kotlin code trims.
package mobile

import (
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
)

// configJSONObjectValue is JsonObject.obj: the object itself, or nothing when
// the value is not a JSON object (callers then keep their defaults).
func configJSONObjectValue(value any) map[string]any {
	object, _ := value.(map[string]any)
	return object
}

// configJSONStringListValue is jsonStringList: a bare string is a
// single-element list, an array keeps its string items, anything else is
// empty. Items are not trimmed.
func configJSONStringListValue(value any) []string {
	switch typed := value.(type) {
	case string:
		return []string{typed}
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if text, ok := item.(string); ok {
				out = append(out, text)
			}
		}
		return out
	}
	return []string{}
}

// configJSONStringValue is JsonValues.toStringValue: strings pass through,
// everything else is "".
func configJSONStringValue(value any) string {
	text, _ := value.(string)
	return text
}

// configJSONVariantString is JsonValues.variantToString.
func configJSONVariantString(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case bool:
		if typed {
			return "true"
		}
		return "false"
	case float64:
		return formatCanonicalDouble(typed)
	}
	return ""
}

// configJSONVariantInteger is JsonValues.variantToLong (QJsonValue::toVariant().toLongLong()).
func configJSONVariantInteger(value any) int64 {
	switch typed := value.(type) {
	case float64:
		if typed >= 0 {
			return int64(typed + 0.5)
		}
		return int64(typed - 0.5)
	case bool:
		if typed {
			return 1
		}
		return 0
	case string:
		return configQtToLong(typed)
	}
	return 0
}

// configJSONVariantInt is variantToInt: QVariant::toInt narrows without a range check.
func configJSONVariantInt(value any) int {
	return int(int32(configJSONVariantInteger(value)))
}

// configJSONBoolValue is JsonValues.toBool: anything but true is false.
func configJSONBoolValue(value any) bool {
	boolean, _ := value.(bool)
	return boolean
}

// configQtToLong is QtStrings.toLong: an optional sign followed by decimal
// digits, trimmed, zero otherwise.
func configQtToLong(text string) int64 {
	trimmed := strings.TrimSpace(text)
	if !configQtIntegerText(trimmed) {
		return 0
	}
	parsed, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil {
		return 0
	}
	return parsed
}

// configQtToIntOrNull is QtStrings.toIntOrNull: the value, or false when Qt
// would report ok == false.
func configQtToIntOrNull(text string) (int, bool) {
	trimmed := strings.TrimSpace(text)
	if !configQtIntegerText(trimmed) {
		return 0, false
	}
	parsed, err := strconv.ParseInt(trimmed, 10, 32)
	if err != nil {
		return 0, false
	}
	return int(parsed), true
}

func configQtIntegerText(text string) bool {
	if text == "" {
		return false
	}
	digits := text
	if digits[0] == '+' || digits[0] == '-' {
		digits = digits[1:]
	}
	if digits == "" {
		return false
	}
	for index := 0; index < len(digits); index++ {
		if digits[index] < '0' || digits[index] > '9' {
			return false
		}
	}
	return true
}

// configSplitSkipEmpty is QtStrings.splitSkipEmpty.
func configSplitSkipEmpty(text, separator string) []string {
	parts := strings.Split(text, separator)
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

// configSplitList is QtStrings.splitList: comma separated, trimmed, blanks dropped.
func configSplitList(text string) []string {
	parts := strings.Split(text, ",")
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// configSectionFirstSkipEmpty is QtStrings.sectionFirstSkipEmpty.
func configSectionFirstSkipEmpty(text string, separator byte) string {
	for _, part := range strings.Split(text, string(separator)) {
		if part != "" {
			return part
		}
	}
	return ""
}

// configACEHost is Hosts.toAceHost for the server / SNI / transport host
// fields: an ASCII host is returned unchanged, a convertible IDN becomes its
// lower-cased punycode form, and an unconvertible name is returned untouched
// (the Kotlin wrapper never fails on this path).
func configACEHost(host string) string {
	return configToACEHost(host)
}

func configIsASCII(text string) bool {
	for index := 0; index < len(text); index++ {
		if text[index] >= 0x80 {
			return false
		}
	}
	return true
}

// configBase64Lenient is Base64Strict.decodeLenient: base64 alphabet values
// accumulate, everything else is skipped.
func configBase64Lenient(input string, urlSafe bool) []byte {
	out := make([]byte, 0, len(input)*3/4+3)
	var buffer uint32
	var bits uint
	for index := 0; index < len(input); index++ {
		value := -1
		character := input[index]
		switch {
		case character >= 'A' && character <= 'Z':
			value = int(character - 'A')
		case character >= 'a' && character <= 'z':
			value = int(character-'a') + 26
		case character >= '0' && character <= '9':
			value = int(character-'0') + 52
		case character == '+':
			if !urlSafe {
				value = 62
			}
		case character == '/':
			if !urlSafe {
				value = 63
			}
		case character == '-':
			if urlSafe {
				value = 62
			}
		case character == '_':
			if urlSafe {
				value = 63
			}
		}
		if value < 0 {
			continue
		}
		buffer = (buffer << 6) | uint32(value)
		bits += 6
		if bits >= 8 {
			bits -= 8
			out = append(out, byte(buffer>>bits))
			buffer &= (1 << bits) - 1
		}
	}
	return out
}

// configBase64KeyValid is Validation.base64Key(text, bytes) for the standard
// alphabet with padding: exactly the expected length, base64 characters, and a
// decode of the requested size.
func configBase64KeyValid(text string, bytes int) bool {
	trimmed := strings.TrimSpace(text)
	remainder := bytes % 3
	dataChars := bytes / 3 * 4
	if remainder != 0 {
		dataChars += remainder + 1
	}
	total := dataChars
	if remainder != 0 {
		total += 3 - remainder
	}
	if len(trimmed) != total {
		return false
	}
	for index := 0; index < total; index++ {
		if index < dataChars {
			character := trimmed[index]
			base64Char := (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
				(character >= '0' && character <= '9') || character == '+' || character == '/'
			if !base64Char {
				return false
			}
		} else if trimmed[index] != '=' {
			return false
		}
	}
	decoded, err := base64.StdEncoding.DecodeString(trimmed)
	return err == nil && len(decoded) == bytes
}

// configCheckKeys refuses any stored key the per-type parser does not read:
// a field the Kotlin builder would reproduce must never vanish silently.
func configCheckKeys(object map[string]any, allowed map[string]bool, subject string) error {
	for key := range object {
		if !allowed[key] {
			return fmt.Errorf("%s stores field %q, which the Go config builder does not reproduce", subject, key)
		}
	}
	return nil
}

// configKeysAllowed returns a key set for a static list.
func configKeysAllowed(keys ...string) map[string]bool {
	allowed := make(map[string]bool, len(keys))
	for _, key := range keys {
		allowed[key] = true
	}
	return allowed
}

// configSetKeys adds keys to an existing set.
func configSetKeys(allowed map[string]bool, keys ...string) map[string]bool {
	for _, key := range keys {
		allowed[key] = true
	}
	return allowed
}
