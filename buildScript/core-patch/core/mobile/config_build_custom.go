// The `custom` profile type: raw sing-box JSON in one of two shapes.
//
// subtype "outbound" is a single sing-box outbound object that the chain
// builder emits as-is (its `type` key decides whether it is an endpoint), and
// subtype "fullconfig" replaces the whole core config, so ConfigGenerator.build
// returns its compact sorted form before any section is generated — WARP and the
// route table are not consulted at all. The stored `config` member is JSON text;
// it is read with the same org.json tolerance as JsonInput.parseObject (a
// non-object or unparsable text yields an empty object, which is an error for a
// full config and an empty outbound for the other subtypes).
package mobile

import (
	"encoding/json"
	"strconv"
	"strings"
)

const (
	configCustomOutbound   = "outbound"
	configCustomFullConfig = "fullconfig"
)

// configCustomParams is the Custom outbound state: Custom.parseFromJson reads
// exactly these members.
type configCustomParams struct {
	subtype string
	config  string
}

func configParseCustom(object map[string]any) configCustomParams {
	return configCustomParams{
		subtype: strings.TrimSpace(configJSONString(object, "subtype")),
		config:  configJSONString(object, "config"),
	}
}

// isFullConfig is Custom.isFullConfig: a `fullconfig` replaces the whole core
// config and cannot appear in a chain or as a route outbound.
func (params configCustomParams) isFullConfig() bool {
	return params.subtype == configCustomFullConfig
}

// isEndpoint is Custom.isEndpoint: only raw sing-box outbound JSON of an
// endpoint type describes an endpoint.
func (params configCustomParams) isEndpoint() bool {
	if params.subtype != configCustomOutbound {
		return false
	}
	switch configJSONString(configCustomObject(params.config), "type") {
	case "wireguard", "tailscale", "masque":
		return true
	}
	return false
}

// buildObject is Custom.build: the parsed config text, unmodified.
func (params configCustomParams) buildObject() map[string]any {
	return configCustomObject(params.config)
}

// configCustomObject is Custom.configObject / JsonInput.parseObject: an empty
// object on any failure or when the text is not an object.
func configCustomObject(text string) map[string]any {
	if strings.TrimSpace(text) == "" {
		return map[string]any{}
	}
	// Strictly decoded first, so well-formed JSON takes the exact path; org.json
	// is lenient, hence the JSONTokener-shaped fallback below.
	if object, ok := configDecodeJSONObject(text); ok {
		return object
	}
	if object, ok := configLenientJSONObject(text); ok {
		return object
	}
	return map[string]any{}
}

// configDecodeJSONObject decodes the first JSON value and normalises it the way
// JsonValues.normalize does: integers stay integers (a Long in Kotlin, hence
// int64 here), every other number is a double. Trailing content is ignored,
// like org.json's JSONObject(String).
func configDecodeJSONObject(text string) (map[string]any, bool) {
	decoder := json.NewDecoder(strings.NewReader(text))
	decoder.UseNumber()
	var value any
	if err := decoder.Decode(&value); err != nil {
		return nil, false
	}
	normalised, ok := configNormalizeJSONValue(value)
	if !ok {
		return nil, false
	}
	object, ok := normalised.(map[string]any)
	return object, ok
}

func configNormalizeJSONValue(value any) (any, bool) {
	switch typed := value.(type) {
	case nil, bool, string:
		return typed, true
	case json.Number:
		text := typed.String()
		if !strings.ContainsAny(text, ".eE") {
			if parsed, err := strconv.ParseInt(text, 10, 64); err == nil {
				return parsed, true
			}
		}
		parsed, err := strconv.ParseFloat(text, 64)
		if err != nil && !configIsRangeError(err) {
			return nil, false
		}
		return parsed, true
	case map[string]any:
		object := make(map[string]any, len(typed))
		for key, item := range typed {
			normalised, ok := configNormalizeJSONValue(item)
			if !ok {
				return nil, false
			}
			object[key] = normalised
		}
		return object, true
	case []any:
		array := make([]any, 0, len(typed))
		for _, item := range typed {
			normalised, ok := configNormalizeJSONValue(item)
			if !ok {
				return nil, false
			}
			array = append(array, normalised)
		}
		return array, true
	}
	return nil, false
}

func configIsRangeError(err error) bool {
	numberError, ok := err.(*strconv.NumError)
	return ok && numberError.Err == strconv.ErrRange
}

// --- lenient fallback ---------------------------------------------------------
//
// org.json's JSONTokener (JsonInput.parseObject) accepts what strict JSON
// refuses: // and /* */ comments, single-quoted strings, unquoted keys and
// string values, and trailing separators. This reader covers exactly those
// constructs; anything it cannot read makes the caller treat the text as empty,
// matching JsonInput.parseObject's empty object on failure.

type configLenientJSON struct {
	text string
	pos  int
}

func configLenientJSONObject(text string) (map[string]any, bool) {
	parser := &configLenientJSON{text: text}
	value, ok := parser.value()
	if !ok {
		return nil, false
	}
	object, ok := value.(map[string]any)
	return object, ok
}

func (parser *configLenientJSON) skip() {
	for parser.pos < len(parser.text) {
		character := parser.text[parser.pos]
		if character == ' ' || character == '\t' || character == '\n' || character == '\r' {
			parser.pos++
			continue
		}
		if character == '/' && parser.pos+1 < len(parser.text) {
			if parser.text[parser.pos+1] == '/' {
				parser.pos += 2
				for parser.pos < len(parser.text) && parser.text[parser.pos] != '\n' && parser.text[parser.pos] != '\r' {
					parser.pos++
				}
				continue
			}
			if parser.text[parser.pos+1] == '*' {
				parser.pos += 2
				for parser.pos+1 < len(parser.text) &&
					!(parser.text[parser.pos] == '*' && parser.text[parser.pos+1] == '/') {
					parser.pos++
				}
				if parser.pos+1 < len(parser.text) {
					parser.pos += 2
				}
				continue
			}
		}
		return
	}
}

func (parser *configLenientJSON) value() (any, bool) {
	parser.skip()
	if parser.pos >= len(parser.text) {
		return nil, false
	}
	switch parser.text[parser.pos] {
	case '{':
		return parser.object()
	case '[':
		return parser.array()
	case '"', '\'':
		return parser.quoted()
	}
	return parser.bare()
}

// bare reads an unquoted token: a literal, a number or a bare string.
func (parser *configLenientJSON) bare() (any, bool) {
	start := parser.pos
	for parser.pos < len(parser.text) {
		character := parser.text[parser.pos]
		if character == ',' || character == '}' || character == ']' || character == ':' ||
			character == ';' || character == '=' || character == ' ' || character == '\t' ||
			character == '\r' || character == '\n' || character == '/' {
			break
		}
		parser.pos++
	}
	token := strings.TrimSpace(parser.text[start:parser.pos])
	if token == "" {
		return nil, false
	}
	switch token {
	case "true":
		return true, true
	case "false":
		return false, true
	case "null":
		return nil, true
	}
	if number, ok := configLenientNumber(token); ok {
		return number, true
	}
	return token, true
}

func configLenientNumber(token string) (any, bool) {
	first := token[0]
	if !(first == '-' || first == '+' || (first >= '0' && first <= '9') || first == '.') {
		return nil, false
	}
	if !strings.ContainsAny(token, ".eE") {
		if parsed, err := strconv.ParseInt(token, 10, 64); err == nil {
			return parsed, true
		}
	}
	parsed, err := strconv.ParseFloat(token, 64)
	if err != nil && !configIsRangeError(err) {
		return nil, false
	}
	return parsed, true
}

func (parser *configLenientJSON) object() (any, bool) {
	parser.pos++ // {
	object := map[string]any{}
	for {
		parser.skip()
		if parser.pos >= len(parser.text) {
			return nil, false
		}
		if parser.text[parser.pos] == '}' {
			parser.pos++
			return object, true
		}
		keyValue, ok := parser.value()
		if !ok {
			return nil, false
		}
		key, ok := configLenientKeyText(keyValue)
		if !ok {
			return nil, false
		}
		parser.skip()
		if parser.pos >= len(parser.text) || parser.text[parser.pos] != ':' {
			// org.json throws on a key without its ':' (JSONObject's constructor),
			// and JsonInput.parseObject then answers an empty object.
			return nil, false
		}
		parser.pos++
		value, ok := parser.value()
		if !ok {
			return nil, false
		}
		object[key] = value
		parser.skip()
		if parser.pos >= len(parser.text) {
			continue
		}
		switch parser.text[parser.pos] {
		case ',', ';':
			parser.pos++
		case '}':
			parser.pos++
			return object, true
		default:
			return nil, false
		}
	}
}

func (parser *configLenientJSON) array() (any, bool) {
	parser.pos++ // [
	array := []any{}
	for {
		parser.skip()
		if parser.pos >= len(parser.text) {
			return nil, false
		}
		if parser.text[parser.pos] == ']' {
			parser.pos++
			return array, true
		}
		value, ok := parser.value()
		if !ok {
			return nil, false
		}
		array = append(array, value)
		parser.skip()
		if parser.pos >= len(parser.text) {
			continue
		}
		switch parser.text[parser.pos] {
		case ',', ';':
			parser.pos++
		case ']':
			parser.pos++
			return array, true
		default:
			return nil, false
		}
	}
}

// quoted reads a ' or " string, with org.json's escape handling: the five named
// escapes, \uXXXX and an unknown escape whose backslash is dropped.
func (parser *configLenientJSON) quoted() (any, bool) {
	quote := parser.text[parser.pos]
	parser.pos++
	var text strings.Builder
	for parser.pos < len(parser.text) {
		character := parser.text[parser.pos]
		if character == quote {
			parser.pos++
			return text.String(), true
		}
		if character != '\\' {
			text.WriteByte(character)
			parser.pos++
			continue
		}
		parser.pos++
		if parser.pos >= len(parser.text) {
			return nil, false
		}
		escape := parser.text[parser.pos]
		switch escape {
		case 'b':
			text.WriteByte('\b')
			parser.pos++
		case 't':
			text.WriteByte('\t')
			parser.pos++
		case 'n':
			text.WriteByte('\n')
			parser.pos++
		case 'f':
			text.WriteByte('\f')
			parser.pos++
		case 'r':
			text.WriteByte('\r')
			parser.pos++
		case 'u':
			if parser.pos+4 >= len(parser.text) {
				return nil, false
			}
			code, err := strconv.ParseUint(parser.text[parser.pos+1:parser.pos+5], 16, 16)
			if err != nil {
				return nil, false
			}
			parser.pos += 5
			unit := uint16(code)
			if unit >= 0xD800 && unit <= 0xDBFF && parser.pos+6 <= len(parser.text) &&
				parser.text[parser.pos] == '\\' && parser.text[parser.pos+1] == 'u' {
				if low, lowErr := strconv.ParseUint(parser.text[parser.pos+2:parser.pos+6], 16, 16); lowErr == nil &&
					low >= 0xDC00 && low <= 0xDFFF {
					text.WriteRune(rune(0x10000) + (rune(unit)-0xD800)<<10 + (rune(low) - 0xDC00))
					parser.pos += 6
					continue
				}
			}
			configWriteUTF16Unit(&text, unit)
		default:
			text.WriteByte(escape)
			parser.pos++
		}
	}
	return nil, false
}

// configWriteUTF16Unit appends one UTF-16 code unit. A lone surrogate becomes
// its WTF-8 form so MarshalCanonicalJSON escapes it exactly as the Kotlin
// writer escapes an unpaired surrogate.
func configWriteUTF16Unit(text *strings.Builder, unit uint16) {
	if unit >= 0xD800 && unit <= 0xDFFF {
		text.WriteByte(byte(0xE0 | (unit >> 12)))
		text.WriteByte(byte(0x80 | ((unit >> 6) & 0x3F)))
		text.WriteByte(byte(0x80 | (unit & 0x3F)))
		return
	}
	text.WriteRune(rune(unit))
}

// configLenientKeyText is the String.valueOf of the key org.json reads: a
// string as-is, a literal or number in its JSON text (never used by the stored
// configs, which quote their keys).
func configLenientKeyText(value any) (string, bool) {
	switch typed := value.(type) {
	case string:
		return typed, true
	case bool:
		if typed {
			return "true", true
		}
		return "false", true
	case int64:
		return strconv.FormatInt(typed, 10), true
	case float64:
		return formatCanonicalDouble(typed), true
	case nil:
		return "null", true
	}
	return "", false
}
