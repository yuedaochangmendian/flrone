// Base64 decoding with the Qt semantics the Throne profile codec relies on.
//
// Ported from app/src/main/java/io/nekohasekai/sagernet/outbound/link/Base64Strict.kt.
// The strict decoder is QByteArray::fromBase64Encoding(AbortOnBase64DecodingErrors):
// a character outside the chosen alphabet, or an `=` anywhere but one/two trailing
// characters of a length-multiple-of-four input, is an error; missing padding is
// accepted and leftover bits are dropped. The lenient decoder is
// fromBase64 without the abort flag: everything outside the alphabet (including
// `=`) is skipped.
//
// Operates on the UTF-8 bytes of the input, exactly like the Kotlin
// `input.toByteArray(Charsets.UTF_8)`: a non-ASCII character is an invalid
// base64 digit, not a rune to interpret.
package mobile

const (
	profileBase64Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	profileBase64URLSafe  = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
)

// profileBase64Decode is Base64Strict.decode. A nil result means Qt would
// report an error; an empty input decodes to an empty, non-nil slice.
func profileBase64Decode(input string, urlSafe bool) ([]byte, bool) {
	src := []byte(input)
	size := len(src)
	out := make([]byte, size*3/4+3)
	var buf, nbits, offset, index int
	for index < size {
		char := src[index]
		var digit int
		switch {
		case char >= 'A' && char <= 'Z':
			digit = int(char - 'A')
		case char >= 'a' && char <= 'z':
			digit = int(char-'a') + 26
		case char >= '0' && char <= '9':
			digit = int(char-'0') + 52
		case char == '+' && !urlSafe:
			digit = 62
		case char == '-' && urlSafe:
			digit = 62
		case char == '/' && !urlSafe:
			digit = 63
		case char == '_' && urlSafe:
			digit = 63
		case char == '=':
			if size%4 != 0 {
				return nil, false
			}
			if index == size-1 {
				return out[:offset], true
			}
			if index == size-2 && src[index+1] == '=' {
				return out[:offset], true
			}
			return nil, false
		default:
			return nil, false
		}
		buf = (buf << 6) | digit
		nbits += 6
		if nbits >= 8 {
			nbits -= 8
			out[offset] = byte(buf >> nbits)
			offset++
			buf &= (1 << nbits) - 1
		}
		index++
	}
	return out[:offset], true
}

// profileBase64DecodeLenient is Base64Strict.decodeLenient: skip every byte
// outside the chosen alphabet, including `=`, and drop leftover bits.
func profileBase64DecodeLenient(input string, urlSafe bool) []byte {
	out := make([]byte, len(input)*3/4+3)
	var buf, nbits, offset int
	for _, char := range []byte(input) {
		var digit int
		switch {
		case char >= 'A' && char <= 'Z':
			digit = int(char - 'A')
		case char >= 'a' && char <= 'z':
			digit = int(char-'a') + 26
		case char >= '0' && char <= '9':
			digit = int(char-'0') + 52
		case char == '+' && !urlSafe:
			digit = 62
		case char == '/' && !urlSafe:
			digit = 63
		case char == '-' && urlSafe:
			digit = 62
		case char == '_' && urlSafe:
			digit = 63
		default:
			continue
		}
		buf = (buf << 6) | digit
		nbits += 6
		if nbits >= 8 {
			nbits -= 8
			out[offset] = byte(buf >> nbits)
			offset++
			buf &= (1 << nbits) - 1
		}
	}
	return out[:offset]
}

// profileBase64Encode is Base64Strict.encode: the standard or URL-safe alphabet,
// with optional `=` padding.
func profileBase64Encode(input []byte, urlSafe, padding bool) string {
	alphabet := profileBase64Alphabet
	if urlSafe {
		alphabet = profileBase64URLSafe
	}
	out := make([]byte, 0, (len(input)+2)/3*4)
	for index := 0; index < len(input); index += 3 {
		b0 := input[index]
		b1 := -1
		if index+1 < len(input) {
			b1 = int(input[index+1])
		}
		b2 := -1
		if index+2 < len(input) {
			b2 = int(input[index+2])
		}
		out = append(out, alphabet[int(b0)>>2])
		out = append(out, alphabet[((int(b0)&0x3)<<4)|byteOrZero(b1>>4)])
		if b1 < 0 {
			if padding {
				out = append(out, '=', '=')
			}
			continue
		}
		out = append(out, alphabet[((b1&0xF)<<2)|byteOrZero(b2>>6)])
		if b2 < 0 {
			if padding {
				out = append(out, '=')
			}
			continue
		}
		out = append(out, alphabet[b2&0x3F])
	}
	return string(out)
}

func byteOrZero(value int) int {
	if value < 0 {
		return 0
	}
	return value
}
