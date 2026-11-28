package mobile

// Parity tests for the Clash YAML slice. Expected scalar types/values were
// checked against SnakeYAML 1.30 SafeConstructor (the jar pinned in flrone's
// Gradle cache) and the Kotlin ClashYaml/ClashProxy pair in app/src/main/java.
// See profile_clash_yaml.go for the documented gaps.

import (
	"math"
	"reflect"
	"testing"
)

func parseProxies(t *testing.T, text string) []map[string]any {
	t.Helper()
	entries, err := clashProxies(text)
	if err != nil {
		t.Fatalf("clashProxies(%q) returned error: %v", text, err)
	}
	return entries
}

func oneProxy(t *testing.T, text string) clashProxy {
	t.Helper()
	entries := parseProxies(t, text)
	if len(entries) != 1 {
		t.Fatalf("want exactly 1 proxies entry, got %d (%v)", len(entries), entries)
	}
	return clashProxy{Node: entries[0]}
}

func TestClashYamlStandardProxies(t *testing.T) {
	text := `proxies:
  - name: node1
    type: ss
    server: example.com
    port: 8388
    cipher: aes-256-gcm
    password: "pass word"
  - {name: node2, type: vmess, port: 443, tls: true}
proxy-providers:
  sub: {type: http, url: https://example.com/sub}
`
	doc, err := parseClashDocument(text)
	if err != nil {
		t.Fatalf("parseClashDocument: %v", err)
	}
	if !doc.Mapping || !doc.ProxyProviders {
		t.Fatalf("want mapping with proxy-providers, got %+v", doc)
	}
	if len(doc.Proxies) != 2 {
		t.Fatalf("want 2 proxies, got %d", len(doc.Proxies))
	}
	p := clashProxy{Node: doc.Proxies[0]}
	if !p.Has("type") || p.Type() != "ss" || p.String("name") != "node1" || p.Int("port") != 8388 {
		t.Fatalf("first entry wrong: %+v", doc.Proxies[0])
	}
	p2 := clashProxy{Node: doc.Proxies[1]}
	if p2.Type() != "vmess" || p2.Int("port") != 443 || !p2.Bool("tls") {
		t.Fatalf("second entry wrong: %+v", doc.Proxies[1])
	}
}

func TestClashYamlProxyProvidersOnly(t *testing.T) {
	text := `proxy-providers:
  sub:
    type: http
    url: https://example.com/sub
    interval: 3600
`
	doc, err := parseClashDocument(text)
	if err != nil {
		t.Fatalf("parseClashDocument: %v", err)
	}
	if !doc.Mapping || !doc.ProxyProviders {
		t.Fatalf("want mapping with proxy-providers, got %+v", doc)
	}
	if doc.Proxies != nil {
		t.Fatalf("want no proxies for a providers-only document, got %v", doc.Proxies)
	}
}

func TestClashYamlNoProxiesIsNotError(t *testing.T) {
	cases := []struct {
		name string
		text string
	}{
		{"empty", ""},
		{"other mapping", "foo: bar\n"},
		{"sequence root", "- a\n- b\n"},
		{"scalar root", "just a string\n"},
		{"proxies not a sequence", "proxies: {a: 1}\n"},
		{"proxies null", "proxies: null\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			doc, err := parseClashDocument(tc.text)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if doc.Proxies != nil {
				t.Fatalf("want nil proxies, got %v", doc.Proxies)
			}
		})
	}
}

func TestClashYamlBOMAndNUL(t *testing.T) {
	base := "proxies:\n  - {name: n}\n"
	cases := []struct {
		name string
		text string
	}{
		{"leading BOM", "\ufeff" + base},
		{"embedded NUL", "proxies:\n  - {name: n\x00ul}\n"},
		{"NUL before BOM", "\x00\ufeff" + base},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			entries := parseProxies(t, tc.text)
			if len(entries) != 1 {
				t.Fatalf("want 1 entry, got %d", len(entries))
			}
		})
	}
	// Middle BOM is not removed by the Kotlin sanitizer either; it stays in
	// the string rather than breaking the document.
	if _, err := clashProxies("proxies:\n  - {name: a\ufeffb}\n"); err != nil {
		t.Fatalf("middle BOM should parse as a plain string: %v", err)
	}
}

func TestClashYamlYAML11Booleans(t *testing.T) {
	text := `proxies:
  - {y1: yes, y2: YES, y3: Yes, n1: no, n2: NO, n3: No, on1: on, on2: ON, off1: off, off2: OFF,
     t1: true, f1: false, q1: 'yes', q2: "on", q3: !!str no, tag: !!bool YES}
`
	p := oneProxy(t, text)
	for _, key := range []string{"y1", "y2", "y3", "on1", "on2", "t1", "tag"} {
		if !p.Bool(key) {
			t.Errorf("%s should be bool true", key)
		}
		if p.String(key) != "true" {
			t.Errorf("%s string should be \"true\", got %q", key, p.String(key))
		}
	}
	for _, key := range []string{"n1", "n2", "n3", "off1", "off2", "f1"} {
		if p.Bool(key) {
			t.Errorf("%s should be bool false", key)
		}
	}
	// Quoted and !!str forms remain strings: MyBool must NOT accept them.
	for _, key := range []string{"q1", "q2", "q3"} {
		if _, ok := p.Node[key].(string); !ok {
			t.Errorf("%s should be a string, got %T(%v)", key, p.Node[key], p.Node[key])
		}
		if p.Bool(key) {
			t.Errorf("%s quoted string should not coerce to bool", key)
		}
	}
}

func TestClashYamlNumericStringsAndIntFields(t *testing.T) {
	text := `proxies:
  - port1: '8388'
    port2: ' 443 '
    port3: 8388
    port4: 2147483648
    port5: '2147483647'
    port6: '2147483648'
    port7: '1.5'
    port8: '  +12  '
    port9: 443.0
    port10: 4.5
    port11: true
    port12: yes
    port13: null
    port14: '12x'
`
	p := oneProxy(t, text)
	want := map[string]int{
		"port1": 8388, "port2": 443, "port3": 8388, "port4": 0,
		"port5": 2147483647, "port6": 0, "port7": 0, "port8": 12,
		"port9": 443, "port10": 0, "port11": 0, "port12": 0,
		"port13": 0, "port14": 0,
	}
	for key, expected := range want {
		if got := p.Int(key); got != expected {
			t.Errorf("Int(%s) = %d, want %d", key, got, expected)
		}
	}
	// Plain `yes` is a YAML 1.1 bool, so it reaches Bool as a real boolean and
	// is accepted there (but is not an int, hence Int("port12") == 0 above).
	if !p.Bool("port12") {
		t.Error("Bool(port12) should accept plain yes (constructed as bool true)")
	}
}

func TestClashYamlDuplicateKeysLastWins(t *testing.T) {
	text := `proxies:
  - {name: first, name: second, port: 1, port: 2}
proxies:
  - {name: only}
`
	doc, err := parseClashDocument(text)
	if err != nil {
		t.Fatalf("parseClashDocument: %v", err)
	}
	if len(doc.Proxies) != 1 {
		t.Fatalf("last proxies wins: want 1 entry, got %d", len(doc.Proxies))
	}
	p := clashProxy{Node: doc.Proxies[0]}
	if p.String("name") != "only" {
		t.Fatalf("last proxies wins: got %q", p.String("name"))
	}
}

func TestClashYamlDuplicateKeysWithinEntry(t *testing.T) {
	p := oneProxy(t, "proxies:\n  - {name: a, name: b, port: 1, port: 2}\n")
	if p.String("name") != "b" || p.Int("port") != 2 {
		t.Fatalf("last value should win: %+v", p.Node)
	}
}

func TestClashYamlAnchorsAndMerge(t *testing.T) {
	text := `defaults: &defaults
  type: ss
  cipher: aes-256-gcm
  port: 8388
proxies:
  - <<: *defaults
    name: merged
    port: 443
  - <<: [*defaults, {name: second, cipher: chacha20}]
  - *defaults
`
	entries := parseProxies(t, text)
	if len(entries) != 3 {
		t.Fatalf("want 3 entries, got %d", len(entries))
	}
	p0 := clashProxy{Node: entries[0]}
	if p0.String("name") != "merged" || p0.Type() != "ss" || p0.Int("port") != 443 || p0.String("cipher") != "aes-256-gcm" {
		t.Fatalf("merge with direct override wrong: %+v", entries[0])
	}
	p1 := clashProxy{Node: entries[1]}
	if p1.String("name") != "second" || p1.String("cipher") != "chacha20" || p1.Int("port") != 8388 {
		t.Fatalf("sequence merge wrong: %+v", entries[1])
	}
	p2 := clashProxy{Node: entries[2]}
	if p2.Type() != "ss" || p2.Int("port") != 8388 {
		t.Fatalf("bare alias wrong: %+v", entries[2])
	}
}

func TestClashYamlExplicitTags(t *testing.T) {
	text := `proxies:
  - a: !!str 123
    b: !!int '456'
    c: !!bool YES
    d: !!float 1
    e: !!null whatever
    g: !!binary SGVsbG8=
    h: 0x1f
    i: 012
    j: 0b101
`
	p := oneProxy(t, text)
	if p.String("a") != "123" {
		t.Errorf("!!str should stay a string, got %v", p.Node["a"])
	}
	if p.Int("b") != 456 {
		t.Errorf("!!int should construct an int, got %v (%T)", p.Node["b"], p.Node["b"])
	}
	if !p.Bool("c") {
		t.Errorf("!!bool YES should be true, got %v", p.Node["c"])
	}
	if p.Node["d"] != int64(1) {
		t.Errorf("!!float 1 normalises to int64(1), got %v (%T)", p.Node["d"], p.Node["d"])
	}
	if p.Has("e") && p.Node["e"] != nil {
		t.Errorf("!!null should be nil, got %v", p.Node["e"])
	}
	if p.Int("h") != 31 || p.Int("i") != 10 || p.Int("j") != 5 {
		t.Errorf("yaml 1.1 int forms wrong: %+v", p.Node)
	}
}

func TestClashYamlMalformed(t *testing.T) {
	cases := []string{
		"proxies:\n  - name: a\n   bad: indent\n",
		"proxies: [unclosed\n",
		"proxies:\n\t- name: a\n",
		"proxies:\n  - {key: !!python/object:foo {}}\n",
		"proxies:\n  - {key: !custom value}\n",
	}
	for _, text := range cases {
		if _, err := clashProxies(text); err == nil {
			t.Errorf("expected an error for %q", text)
		}
	}
}

func TestClashYamlNestedOptionBlocks(t *testing.T) {
	text := `proxies:
  - name: ws
    type: vmess
    ws-opts:
      path: /ws
      headers:
        Host: example.com
        Z-Last: z
        A-First: 1
    http-opts:
      headers:
        Connection: [keep-alive, upgrade]
        Accept: text/plain
    smux:
      enabled: true
      max-streams: 128
`
	p := oneProxy(t, text)
	ws := p.Obj("ws-opts")
	if ws.String("path") != "/ws" {
		t.Errorf("ws path = %q", ws.String("path"))
	}
	h := ws.StringMap("headers")
	if h["Host"] != "example.com" || h["A-First"] != "1" {
		t.Errorf("ws headers wrong: %v", h)
	}
	if !reflect.DeepEqual([]string{"A-First", "Host", "Z-Last"}, clashSortedKeys(ws.Node["headers"].(map[string]any))) {
		t.Errorf("headers should be sorted by key, got %v", h)
	}
	http := p.Obj("http-opts").StringListMap("headers")
	if !reflect.DeepEqual(http["Connection"], []string{"keep-alive", "upgrade"}) {
		t.Errorf("http headers wrong: %v", http)
	}
	if http["Accept"][0] != "text/plain" {
		t.Errorf("http scalar header wrong: %v", http)
	}
	smux := p.Obj("smux")
	if !smux.Bool("enabled") || smux.Int("max-streams") != 128 {
		t.Errorf("smux wrong: %+v", smux.Node)
	}
	// Missing and wrongly-shaped blocks are empty views, matching ClashProxy.obj.
	if p.Obj("missing").Has("path") || p.Obj("name").Has("path") {
		t.Error("empty view expected for absent/non-mapping block")
	}
}

func TestClashFormatG(t *testing.T) {
	cases := []struct {
		value float64
		want  string
	}{
		{1.0, "1"},
		{443.0, "443"},
		{1e6, "1000000"},
		{1e15, "1e+15"}, // Java %.15g switches to exponent at 1e15
		{1e16, "1e+16"},
		{1.2345678901234567e20, "1.23456789012346e+20"},
		{0.0001, "0.0001"},
		{1e-5, "1e-05"},
		{1.5e-7, "1.5e-07"},
		{123456789012345.0, "123456789012345"},
	}
	for _, tc := range cases {
		if got := clashFormatG(tc.value); got != tc.want {
			t.Errorf("clashFormatG(%v) = %q, want %q", tc.value, got, tc.want)
		}
	}
}

func TestClashProxyStringCoercions(t *testing.T) {
	text := `proxies:
  - a: text
    b: 123
    c: 1.5
    d: true
    e: false
    f: 1e20
    g: [1, 2]
    h: {nested: 1}
    i: null
`
	p := oneProxy(t, text)
	if p.String("a") != "text" || p.String("b") != "123" || p.String("c") != "1.5" ||
		p.String("d") != "true" || p.String("e") != "false" || p.String("f") != "1e+20" ||
		p.String("g") != "" || p.String("h") != "" || p.String("i") != "" || p.String("missing") != "" {
		t.Fatalf("string coercions wrong: %+v", p.Node)
	}
	if !p.Present("a") || p.Present("i") || p.Present("missing") || !p.Has("i") {
		t.Error("Has/Present semantics wrong")
	}
}

func TestClashProxyBoolAcceptsOnlyTrueFalseOneZero(t *testing.T) {
	text := `proxies:
  - a: true
    b: false
    c: 1
    d: 0
    e: 'true'
    f: 'FALSE'
    g: ' 1 '
    h: '0'
    i: 'yes'
    j: 'on'
    k: 2
    l: -1
    m: 1.0
    n: [true]
    o: null
`
	p := oneProxy(t, text)
	for _, key := range []string{"a", "c", "e", "g"} {
		if !p.Bool(key) {
			t.Errorf("Bool(%s) should be true", key)
		}
	}
	for _, key := range []string{"b", "d", "f", "h"} {
		if p.Bool(key) {
			t.Errorf("Bool(%s) should be false", key)
		}
	}
	// m is 1.0 -> JsonValues.normalizeDouble narrows to 1L -> MyBool accepts it.
	for _, key := range []string{"i", "j", "k", "l", "n", "o"} {
		if p.Bool(key) {
			t.Errorf("Bool(%s) should reject the value", key)
		}
	}
	if !p.Bool("m") {
		t.Error("Bool(m) should accept 1.0 (narrowed to int64 1)")
	}
}

func TestClashYamlScalarTypes(t *testing.T) {
	text := `proxies:
  - n0: 0
    n1: -12
    n2: +12
    n3: 012
    n4: 0x1f
    n5: 0b101
    n6: 1_000
    n7: 1:20
    n8: 2147483648
    n9: 9223372036854775808
    f1: 1.5
    f2: .5
    f3: 5.
    f4: 1e3
    f5: .inf
    f6: -.Inf
    f7: .NaN
    s1: null
    s2: ~
    s3: ''
    s4: plain text
    d1: 2001-12-14
`
	p := oneProxy(t, text)
	for key, want := range map[string]int64{
		"n0": 0, "n1": -12, "n2": 12, "n3": 10, "n4": 31, "n5": 5,
		"n6": 1000, "n7": 80, "n8": 2147483648,
	} {
		if got, ok := p.Node[key].(int64); !ok || got != want {
			t.Errorf("%s = %v (%T), want int64(%d)", key, got, got, want)
		}
	}
	// Beyond int64, SnakeYAML constructs BigInteger; we keep the text (gap).
	if p.Node["n9"] == nil {
		t.Error("n9 should have a value")
	}
	for _, key := range []string{"f1", "f5", "f6", "f7"} {
		if _, ok := p.Node[key].(float64); !ok {
			t.Errorf("%s should be a float64, got %T", key, p.Node[key])
		}
	}
	// .5 is a non-integral Double; Qt narrowing keeps it as a float.
	if v, ok := p.Node["f2"].(float64); !ok || v != 0.5 {
		t.Errorf(".5 should stay float64(0.5), got %v (%T)", p.Node["f2"], p.Node["f2"])
	}
	if v, ok := p.Node["f3"].(int64); !ok || v != 5 {
		t.Errorf("5. normalises to int64(5), got %v (%T)", p.Node["f3"], p.Node["f3"])
	}
	if v, ok := p.Node["f4"].(int64); !ok || v != 1000 {
		t.Errorf("1e3 normalises to int64(1000), got %v (%T)", p.Node["f4"], p.Node["f4"])
	}
	if math.IsInf(p.Node["f5"].(float64), 1) != true || math.IsInf(p.Node["f6"].(float64), -1) != true ||
		!math.IsNaN(p.Node["f7"].(float64)) {
		t.Error("inf/nan construction wrong")
	}
	for _, key := range []string{"s1", "s2"} {
		if p.Node[key] != nil {
			t.Errorf("%s should be null, got %v", key, p.Node[key])
		}
	}
	if p.String("s3") != "" || p.String("s4") != "plain text" || p.String("d1") != "2001-12-14" {
		t.Errorf("string/timestamp wrong: %+v", p.Node)
	}
}
