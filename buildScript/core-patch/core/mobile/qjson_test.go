package mobile

// Parity tests for the canonical JSON writer: every expected string below was
// produced by running the real Kotlin JsonWriter (the compiled JsonWriter.kt
// with its Kotlin fixture), so these literals pin the byte contract rather than
// a re-reading of it. See qjson.go for the rules.
//
// The fixtures were generated with Kotlin 2.4.21 / JDK 21. Cases whose expected
// value is interesting because Go cannot hold the Kotlin type directly (lone
// surrogates) say so in the test.

import (
	"math"
	"strings"
	"testing"
)

func mustMarshalCanonical(t *testing.T, value any) string {
	t.Helper()
	encoded, err := MarshalCanonicalJSON(value)
	if err != nil {
		t.Fatalf("MarshalCanonicalJSON(%#v) returned error: %v", value, err)
	}
	return string(encoded)
}

func TestCanonicalKeyOrderIsUTF16(t *testing.T) {
	// Insertion order is meaningless for a Go map; the writer sorts. Kotlin's
	// String order compares UTF-16 code units, so the supplementary characters
	// (surrogate pairs starting at D800/D83D) sort before the BMP characters
	// E000 and FFFD. A UTF-8 byte sort would put E000 first: this map pins the
	// difference. The key "\xed\xa0\x80" is the WTF-8 form of a lone U+D800,
	// which a Kotlin String can hold but a Go string cannot express otherwise.
	value := map[string]any{
		"a":            1,
		"\u00e9":       2, // é, U+00E9
		"\u4e2d":       3, // 中, U+4E2D
		"\U00010000":   4, // surrogate pair D800 DC00
		"\U0001F600":   5, // surrogate pair D83D DE00
		"\ue000":       6, // BMP private use, code unit E000
		"\uFFFD":       7, // replacement character
		"\xed\xa0\x80": 8, // lone high surrogate D800 (WTF-8)
		"z":            9,
		"Z":            10,
	}
	want := `{"Z":10,"a":1,"z":9,"é":2,"中":3,"\ud800":8,"𐀀":4,"😀":5,"` + "\ue000" + `":6,"�":7}`
	if got := mustMarshalCanonical(t, value); got != want {
		t.Fatalf("key order mismatch\n got: %s\nwant: %s", got, want)
	}
}

func TestCanonicalNestedContainers(t *testing.T) {
	value := map[string]any{
		"m":     map[string]any{},
		"a":     []any{},
		"null":  nil,
		"bool":  true,
		"false": false,
		"objs": []any{
			map[string]any{"b": 2, "a": 1},
			[]any{1, "two", nil},
		},
	}
	want := `{"a":[],"bool":true,"false":false,"m":{},"null":null,"objs":[{"a":1,"b":2},[1,"two",null]]}`
	if got := mustMarshalCanonical(t, value); got != want {
		t.Fatalf("nested containers mismatch\n got: %s\nwant: %s", got, want)
	}
}

func TestCanonicalStringEscaping(t *testing.T) {
	// Every want here is the Kotlin JsonWriter output for the same input.
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"plain", "abc", `"abc"`},
		{"empty", "", `""`},
		{"quote-backslash-slash", "q\"b\\s/", `"q\"b\\s/"`},
		{"del-is-literal", "\u007f", "\"\u007f\""},
		{"controls", "\x00\x01\x07\b\t\n\x0b\f\r\x1f", `"\u0000\u0001\u0007\b\t\n\u000b\f\r\u001f"`},
		{"bmp-literal", "中文é✓", `"中文é✓"`},
		{"supplementary-literal", "\U0001F600\U00010000", `"😀𐀀"`},
		{"line-separators-literal", "\u2028\u2029", "\"\u2028\u2029\""},
		// A Kotlin String can hold an unpaired surrogate; the writer escapes it
		// with lowercase hex. Go has to pass the same code unit as WTF-8.
		{"lone-high", "a\xed\xa0\x80b", `"a\ud800b"`},
		{"lone-low", "a\xed\xb0\x80b", `"a\udc00b"`},
		{"high-then-bmp", "\xed\xa0\x80A", `"\ud800A"`},
		{"low-then-high", "\xed\xb0\x80\xed\xa0\x80", `"\udc00\ud800"`},
		{"valid-pair-then-lone", "\U0001F600\xed\xa0\x80", `"😀\ud800"`},
		// Two WTF-8 surrogates forming a pair are one character in a Kotlin
		// String, so the output is the ordinary four-byte UTF-8 sequence.
		{"wtf8-pair", "\xed\xa0\x80\xed\xb0\x80", "\"\U00010000\""},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mustMarshalCanonical(t, tc.in); got != tc.want {
				t.Fatalf("escaping mismatch\n got: %q\nwant: %q", got, tc.want)
			}
		})
	}

	t.Run("keys", func(t *testing.T) {
		value := map[string]any{"\x01key": 1, "\"quoted\"": 2, "back\\slash": 3}
		want := `{"\u0001key":1,"\"quoted\"":2,"back\\slash":3}`
		if got := mustMarshalCanonical(t, value); got != want {
			t.Fatalf("key escaping mismatch\n got: %s\nwant: %s", got, want)
		}
	})
}

func TestCanonicalNumbers(t *testing.T) {
	cases := []struct {
		name  string
		value any
		want  string
	}{
		{"int-zero", 0, "0"},
		{"int-negative", -1, "-1"},
		{"int-443", 443, "443"},
		{"int-min", math.MinInt32, "-2147483648"},
		{"int8", int8(-128), "-128"},
		{"uint8", uint8(255), "255"},
		{"int64-max", int64(math.MaxInt64), "9223372036854775807"},
		{"int64-min", int64(math.MinInt64), "-9223372036854775808"},
		{"double-integral", 443.0, "443"},
		{"double-one", 1.0, "1"},
		{"double-zero", 0.0, "0"},
		{"double-negative-zero", math.Copysign(0, -1), "0"},
		{"double-one-and-half", 1.5, "1.5"},
		{"double-negative-one-and-half", -1.5, "-1.5"},
		{"double-tenth", 0.1, "0.1"},
		// Runtime arithmetic: the untyped constant expression 0.1 + 0.2 is
		// folded exactly to 0.3, while the Kotlin fixture computed the IEEE
		// double sum 0.30000000000000004.
		{"double-sum", func() float64 { a, b := 0.1, 0.2; return a + b }(), "0.30000000000000004"},
		{"double-mixed", 1234.5678, "1234.5678"},
		{"double-1e15", 1e15, "1000000000000000"},
		{"double-1e16", 1e16, "1e+16"},
		{"double-1e20", 1e20, "1e+20"},
		{"double-1e21", 1e21, "1e+21"},
		{"double-1.2345e21", 1.2345e21, "1.2345e+21"},
		{"double-1.2e15", 1.2e15, "1200000000000000"},
		{"double-1.2345678901234567e19", 1.2345678901234567e19, "12345678901234567000"},
		{"double-1e-4", 1e-4, "1e-04"},
		{"double-1e-3-tie-goes-decimal", 1e-3, "0.001"},
		{"double-1e-5", 1e-5, "1e-05"},
		{"double-1e-6", 1e-6, "1e-06"},
		{"double-1e-7", 1e-7, "1e-07"},
		{"double-1.7e-3", 1.7e-3, "0.0017"},
		{"double-1.7e-4-tie-goes-decimal", 1.7e-4, "0.00017"},
		{"double-1.7e-5", 1.7e-5, "1.7e-05"},
		{"double-negative-2.5e-3", -2.5e-3, "-0.0025"},
		{"double-1.2345e-10", 1.2345e-10, "1.2345e-10"},
		{"double-2^53", 9007199254740992.0, "9007199254740992"},
		{"double-2^53+2", 9007199254740994.0, "9007199254740994"},
		{"double-1e300", 1e300, "1e+300"},
		{"double-max", math.MaxFloat64, "1.7976931348623157e+308"},
		{"double-min-subnormal", 4.9e-324, "5e-324"},
		{"double-nan", math.NaN(), "null"},
		{"double-positive-infinity", math.Inf(1), "null"},
		{"double-negative-infinity", math.Inf(-1), "null"},
		{"float32-widened-first", float32(1.1), "1.100000023841858"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mustMarshalCanonical(t, tc.value); got != tc.want {
				t.Fatalf("number mismatch\n got: %s\nwant: %s", got, tc.want)
			}
		})
	}
}

func TestCanonicalEmptyAndNilContainers(t *testing.T) {
	cases := []struct {
		name  string
		value any
		want  string
	}{
		{"empty-map", map[string]any{}, "{}"},
		{"nil-map", map[string]any(nil), "{}"},
		{"empty-any-slice", []any{}, "[]"},
		{"nil-any-slice", []any(nil), "[]"},
		{"empty-string-slice", []string{}, "[]"},
		{"nil-string-slice", []string(nil), "[]"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := mustMarshalCanonical(t, tc.value); got != tc.want {
				t.Fatalf("empty container mismatch: got %s, want %s", got, tc.want)
			}
		})
	}

	value := map[string]any{"e": map[string]any{}, "a": []any{}, "s": []string{}}
	want := `{"a":[],"e":{},"s":[]}`
	if got := mustMarshalCanonical(t, value); got != want {
		t.Fatalf("nested empty containers mismatch\n got: %s\nwant: %s", got, want)
	}
}

func TestCanonicalConfigFragment(t *testing.T) {
	// The shape of a generated sing-box coreConfig: nested objects, arrays of
	// objects, booleans, integers, strings with a URL, and a []string address
	// list. Expected bytes are the Kotlin JsonWriter output for an equivalent
	// JsonObject tree.
	value := map[string]any{
		"log": map[string]any{"level": "info", "timestamp": true},
		"dns": map[string]any{
			"servers": []any{
				map[string]any{"tag": "dns-direct", "address": "223.5.5.5", "detour": "direct"},
				map[string]any{
					"tag":      "dns-proxy",
					"address":  "https://dns.alidns.com/dns-query",
					"detour":   "proxy",
					"strategy": "prefer_ipv4",
				},
			},
			"final":             "dns-proxy",
			"independent_cache": true,
		},
		"inbounds": []any{
			map[string]any{
				"type":         "tun",
				"tag":          "tun-in",
				"address":      []string{"172.19.0.1/30", "fdfe:dcba:9876::1/126"},
				"mtu":          9000,
				"auto_route":   true,
				"strict_route": true,
				"stack":        "mixed",
			},
		},
		"outbounds": []any{
			map[string]any{"type": "direct", "tag": "direct"},
			map[string]any{
				"type":        "vmess",
				"tag":         "proxy",
				"server":      "example.com",
				"server_port": 443,
				"uuid":        "b831381d-6324-4d53-ad4f-8cda48b30811",
				"security":    "auto",
				"alter_id":    0,
				"tls": map[string]any{
					"enabled":     true,
					"server_name": "example.com",
					"utls":        map[string]any{"enabled": true, "fingerprint": "chrome"},
				},
			},
		},
		"route": map[string]any{
			"rules": []any{
				map[string]any{"protocol": "dns", "outbound": "dns-out"},
				map[string]any{
					"geoip":         []string{"cn"},
					"outbound":      "direct",
					"domain_suffix": []string{".cn"},
				},
			},
			"final":                 "proxy",
			"auto_detect_interface": true,
		},
		"experimental": map[string]any{
			"cache_file": map[string]any{"enabled": true, "path": "cache.db"},
			"clash_api":  map[string]any{"external_controller": "127.0.0.1:9090", "default_mode": "rule"},
		},
	}
	want := `{"dns":{"final":"dns-proxy","independent_cache":true,"servers":[{"address":"223.5.5.5","detour":"direct","tag":"dns-direct"},{"address":"https://dns.alidns.com/dns-query","detour":"proxy","strategy":"prefer_ipv4","tag":"dns-proxy"}]},"experimental":{"cache_file":{"enabled":true,"path":"cache.db"},"clash_api":{"default_mode":"rule","external_controller":"127.0.0.1:9090"}},"inbounds":[{"address":["172.19.0.1/30","fdfe:dcba:9876::1/126"],"auto_route":true,"mtu":9000,"stack":"mixed","strict_route":true,"tag":"tun-in","type":"tun"}],"log":{"level":"info","timestamp":true},"outbounds":[{"tag":"direct","type":"direct"},{"alter_id":0,"security":"auto","server":"example.com","server_port":443,"tag":"proxy","tls":{"enabled":true,"server_name":"example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vmess","uuid":"b831381d-6324-4d53-ad4f-8cda48b30811"}],"route":{"auto_detect_interface":true,"final":"proxy","rules":[{"outbound":"dns-out","protocol":"dns"},{"domain_suffix":[".cn"],"geoip":["cn"],"outbound":"direct"}]}}`
	if got := mustMarshalCanonical(t, value); got != want {
		t.Fatalf("config fragment mismatch\n got: %s\nwant: %s", got, want)
	}
}

func TestCanonicalRejectsValuesKotlinCannotRepresent(t *testing.T) {
	cases := []struct {
		name        string
		value       any
		errContains string
	}{
		{"unsupported-type", struct{ X int }{1}, "unsupported value type"},
		{"channel", make(chan int), "unsupported value type"},
		{"uint64-overflow", uint64(math.MaxInt64) + 1, "exceeds the Kotlin Long range"},
		{"invalid-utf8", "\xff", "invalid UTF-8"},
		{"invalid-utf8-truncated-surrogate", "\xed\xa0", "invalid UTF-8"},
		{"duplicate-utf16-keys", map[string]any{
			"\U00010000":               1,
			"\xed\xa0\x80\xed\xb0\x80": 2,
		}, "same UTF-16 sequence"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := MarshalCanonicalJSON(tc.value)
			if err == nil {
				t.Fatalf("expected an error, got %q", got)
			}
			if !strings.Contains(err.Error(), tc.errContains) {
				t.Fatalf("error %q does not contain %q", err, tc.errContains)
			}
		})
	}
}

func TestCanonicalAppendLeavesDstUnchangedOnError(t *testing.T) {
	dst := []byte("prefix:")
	out, err := AppendCanonicalJSON(dst, map[string]any{"bad": make(chan int)})
	if err == nil {
		t.Fatal("expected an error")
	}
	if string(out) != "prefix:" {
		t.Fatalf("dst was mutated on error: %q", out)
	}
	// appendCanonical's partial writes must not escape on the success path
	// either: the caller's slice header is only replaced by the result.
	out, err = AppendCanonicalJSON(dst, map[string]any{"a": 1})
	if err != nil {
		t.Fatal(err)
	}
	if string(out) != `prefix:{"a":1}` {
		t.Fatalf("append result = %q", out)
	}
}
