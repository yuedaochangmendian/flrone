package mobile

import (
	"bytes"
	"testing"
)

func TestProfileBase64StrictDecode(t *testing.T) {
	for _, tc := range []struct {
		name    string
		input   string
		urlSafe bool
		want    string
	}{
		{"standard padded", "aGVsbG8=", false, "hello"},
		{"standard unpadded", "aGVsbG8", false, "hello"},
		{"two pad chars", "aGk=", false, "hi"},
		{"url-safe alphabet", "a_-b", true, "\x6b\xff\x9b"},
		{"empty", "", false, ""},
		{"leftover bits dropped", "aGVsbG8h", false, "hello!"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := profileBase64Decode(tc.input, tc.urlSafe)
			if !ok {
				t.Fatalf("decode(%q) failed", tc.input)
			}
			if string(got) != tc.want {
				t.Fatalf("decode(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

func TestProfileBase64StrictRejects(t *testing.T) {
	for _, tc := range []struct {
		name    string
		input   string
		urlSafe bool
	}{
		{"foreign alphabet", "a+b/", true},
		{"standard alphabet in url-safe", "a+b/", true},
		{"pad in middle", "a=Gk", false},
		{"pad with wrong length", "aGVsbG8==", false},
		{"three pads", "a===", false},
		{"non-ascii byte", "é", false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got, ok := profileBase64Decode(tc.input, tc.urlSafe); ok {
				t.Fatalf("decode(%q) = %q, want an error", tc.input, got)
			}
		})
	}
}

func TestProfileBase64Lenient(t *testing.T) {
	if got := string(profileBase64DecodeLenient("aG Vs\tbG8=", false)); got != "hello" {
		t.Fatalf("lenient decode = %q", got)
	}
	if got := string(profileBase64DecodeLenient("a_-b", true)); got != "\x6b\xff\x9b" {
		t.Fatalf("lenient url-safe decode = %q", got)
	}
}

func TestProfileBase64Encode(t *testing.T) {
	for _, tc := range []struct {
		input   []byte
		urlSafe bool
		padding bool
		want    string
	}{
		{[]byte("hello"), false, true, "aGVsbG8="},
		{[]byte("hello"), false, false, "aGVsbG8"},
		{[]byte("hi"), false, true, "aGk="},
		{[]byte("hi"), true, true, "aGk="},
		{[]byte{0x6b, 0xff, 0x9b}, false, true, "a/+b"},
		{[]byte{0x6b, 0xff, 0x9b}, true, true, "a_-b"},
		{nil, false, true, ""},
	} {
		if got := profileBase64Encode(tc.input, tc.urlSafe, tc.padding); got != tc.want {
			t.Fatalf("encode(%q, urlSafe=%v, padding=%v) = %q, want %q",
				tc.input, tc.urlSafe, tc.padding, got, tc.want)
		}
	}
}

func TestProfileBase64RoundTrip(t *testing.T) {
	input := []byte{0, 1, 2, 3, 250, 251, 252, 253, 254, 255}
	for _, urlSafe := range []bool{false, true} {
		encoded := profileBase64Encode(input, urlSafe, true)
		decoded, ok := profileBase64Decode(encoded, urlSafe)
		if !ok || !bytes.Equal(decoded, input) {
			t.Fatalf("round trip urlSafe=%v: %q -> %q", urlSafe, encoded, decoded)
		}
	}
}
