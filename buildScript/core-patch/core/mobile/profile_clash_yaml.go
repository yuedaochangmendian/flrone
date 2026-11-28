// Clash YAML subscription import, ported from the Android/Kotlin pair
// app/src/main/java/io/nekohasekai/sagernet/outbound/import/ClashYaml.kt and
// ClashProxy.kt (the desktop's Parser::clash, clash::from_node and load_opt).
//
// This is a slice with NO production caller yet: nothing in the action layer
// imports these symbols. A later wiring step can move the shared JSON tree to
// qjson.go without changing call sites.
//
// Scalar construction follows SnakeYAML 1.30 SafeConstructor, not YAML 1.2:
// plain yes/no/on/off (any case) are booleans, plain octal/hex/binary/sexagesimal
// ints and floats resolve, timestamps are strings (see the gaps below), and an
// explicit tag overrides the resolver. Anchors/aliases, merge keys ("<<") and
// last-wins duplicate keys are honoured by the node tree. Values are then
// converted to the generic tree JsonObject/JsonArray use (map[string]any with
// sorted keys, []any, string, bool, int64, float64, nil).
//
// Exact gaps from SnakeYAML 1.30 SafeConstructor (all exercised by the tests;
// the closest behaviour is implemented):
//
//   - go.yaml.in/yaml/v3 resolves plain yes/no/on/off as !!str. We re-resolve
//     those plain scalars to !!bool, including mixed case (SnakeYAML's bool
//     resolver accepts all case variants of yes/no/true/false/on/off), and only
//     for plain scalars ("yes"/'yes'/!!str stay strings).
//   - SnakeYAML resolves timestamps to java.util.Date; ClashYaml.convert then
//     turns them into value.toString(), e.g. "Fri Dec 14 00:00:00 UTC 2001".
//     yaml.v3 resolves the same plain scalars to !!timestamp; we keep the raw
//     text ("2001-12-14") because a Java Date string would be locale/timezone
//     dependent and no Clash field reads a timestamp.
//   - !!binary decodes to byte[] in SnakeYAML then `toString()` in convert
//     (a "[B@..." identity string). We expose the base64 text as a string; no
//     Clash field reads binary.
//   - !!set / !!omap / !!pairs are SafeConstructor collections (Set /
//     LinkedHashMap / ArrayList). We keep yaml.v3's mapping/sequence tree with
//     the explicit tag visible only through this constructor; Clash fields
//     never use these tags.
//   - !!python/... and other unknown tags throw a ConstructorException in
//     SnakeYAML; yaml.v3 accepts them in its node tree, so clashCheckTags
//     rejects them explicitly to keep the same observable error contract.
//   - SafeConstructor rejects fewer than 1 and more than 2 keys in an
//     !!omap/!!pairs mapping tuple; yaml.v3's node tree has no such check.
//   - JsonValues.normalizeDouble stores integral doubles within 2^53 as int64
//     (Qt QJsonValue behaviour). Scalar values SnakeYAML constructs as Double
//     1.0 therefore enter the tree as int64(1), like the Kotlin port.
//   - SafeConstructor's alias depth limit ("Document contains more than 50
//     aliases") is not exposed by yaml.v3; deeply aliased documents decode.
//   - The Kotlin streaming construction surfaces YAML errors after reading the
//     whole stream but in constructor order. A Go parse returns the parser
//     error first; both propagate an error to the caller, so the observable
//     contract (error vs. no proxies) is the same.
package mobile

import (
	"fmt"
	"math"
	"math/big"
	"regexp"
	"sort"
	"strconv"
	"strings"

	yaml "go.yaml.in/yaml/v3"
)

// clashDocument is the reduced document ClashYaml.Document returns. Proxies is
// nil when the root is not a mapping or has no proxies sequence; Mapping and
// ProxyProviders report what the root lists.
type clashDocument struct {
	Proxies        []map[string]any
	Mapping        bool
	ProxyProviders bool
}

// clashProxies is ClashYaml.proxies: nil when the document has no proxies
// sequence. YAML errors are returned to the caller (the desktop reports them
// as a "YAML Exception" warning).
func clashProxies(text string) ([]map[string]any, error) {
	doc, err := parseClashDocument(text)
	if err != nil {
		return nil, err
	}
	return doc.Proxies, nil
}

// parseClashDocument is ClashYaml.document. Sanitization is the portable part
// of sanitizeClashYaml (SubscriptionParser.cpp:242-247): NULs and a leading BOM
// confuse the YAML reader.
func parseClashDocument(text string) (clashDocument, error) {
	text = strings.ReplaceAll(text, "\x00", "")
	text = strings.TrimPrefix(text, "\ufeff")

	var root yaml.Node
	if err := yaml.Unmarshal([]byte(text), &root); err != nil {
		return clashDocument{}, err
	}
	// SafeConstructor rejects a tag it has no constructor for. yaml.v3's node
	// tree accepts them, so check explicitly rather than silently keeping the
	// scalar text (a tagged field must not masquerade as a valid proxy).
	if err := clashCheckTags(&root); err != nil {
		return clashDocument{}, err
	}
	if len(root.Content) == 0 {
		return clashDocument{}, nil
	}
	c := &clashConstructor{}
	value := clashConvert(c.construct(root.Content[0]), 0)
	obj, ok := value.(map[string]any)
	if !ok {
		return clashDocument{}, nil
	}
	doc := clashDocument{Mapping: true}
	_, doc.ProxyProviders = obj["proxy-providers"]
	items, ok := obj["proxies"].([]any)
	if !ok {
		return doc, nil
	}
	doc.Proxies = make([]map[string]any, 0, len(items))
	for _, item := range items {
		entry, ok := item.(map[string]any)
		if !ok {
			entry = map[string]any{}
		}
		doc.Proxies = append(doc.Proxies, entry)
	}
	return doc, nil
}

// clashCheckTags rejects nodes with a tag SafeConstructor has no constructor
// for (SnakeYAML throws a ConstructorException). yaml.v3 accepts any tag in
// its node tree, so this check is needed to keep the observable contract:
// a malformed tagged document is an error, not a proxies entry.
func clashCheckTags(node *yaml.Node) error {
	if node == nil {
		return nil
	}
	if tag := node.Tag; tag != "" && tag != "!" {
		switch tag {
		case "!!null", "!!bool", "!!int", "!!float", "!!str", "!!timestamp",
			"!!seq", "!!map", "!!binary", "!!merge", "!!set", "!!omap", "!!pairs":
			// known SafeConstructor tags
		default:
			// A local !foo tag is also unknown to SafeConstructor (it would
			// fail unless registered). Custom tags are not valid Clash input.
			return fmt.Errorf("clash: unsupported YAML tag %q", tag)
		}
	}
	for _, child := range node.Content {
		if err := clashCheckTags(child); err != nil {
			return err
		}
	}
	return nil
}

// clashConstructor is the SafeConstructor over a yaml.v3 node tree. Every node
// is constructed once, including aliases: yaml.v3 shares aliased nodes, and a
// Go map is a reference, matching SnakeYAML's alias semantics. Mappings are
// flattened (merge keys expanded, duplicates last-wins) before construction.
type clashConstructor struct{}

func (c *clashConstructor) construct(node *yaml.Node) any {
	if node == nil {
		return nil
	}
	switch node.Kind {
	case yaml.AliasNode:
		if node.Alias == nil {
			return nil
		}
		return c.construct(node.Alias)
	case yaml.DocumentNode:
		if len(node.Content) == 0 {
			return nil
		}
		return c.construct(node.Content[0])
	case yaml.SequenceNode:
		out := make([]any, 0, len(node.Content))
		for _, child := range node.Content {
			out = append(out, c.construct(child))
		}
		return out
	case yaml.MappingNode:
		return c.constructMapping(node)
	case yaml.ScalarNode:
		return c.constructScalar(node)
	}
	return nil
}

// constructMapping applies SafeConstructor.flattenMapping: a merge value is a
// mapping or a sequence of mappings whose entries are prepended; direct keys
// always win over merged ones regardless of position, and later entries of
// both kinds win over earlier ones.
func (c *clashConstructor) constructMapping(node *yaml.Node) map[string]any {
	pairs := clashFlattenMapping(node)
	out := map[string]any{}
	for _, pair := range pairs {
		key := clashKeyString(c.construct(pair.key))
		out[key] = c.construct(pair.value)
	}
	return out
}

type clashNodePair struct{ key, value *yaml.Node }

func clashFlattenMapping(node *yaml.Node) []clashNodePair {
	var merged []clashNodePair
	var direct []clashNodePair
	for i := 0; i+1 < len(node.Content); i += 2 {
		key, value := node.Content[i], node.Content[i+1]
		if isClashMergeKey(key) {
			merged = append(merged, clashMergePairs(value)...)
			continue
		}
		direct = append(direct, clashNodePair{key, value})
	}
	return append(append([]clashNodePair{}, merged...), direct...)
}

func isClashMergeKey(node *yaml.Node) bool {
	return node != nil && node.Kind == yaml.ScalarNode && node.Value == "<<" &&
		(node.Tag == "" || node.Tag == "!" || node.Tag == "!!merge")
}

func clashMergePairs(node *yaml.Node) []clashNodePair {
	if node == nil {
		return nil
	}
	if node.Kind == yaml.AliasNode && node.Alias != nil {
		node = node.Alias
	}
	if node.Kind == yaml.MappingNode {
		pairs := make([]clashNodePair, 0, len(node.Content)/2)
		for i := 0; i+1 < len(node.Content); i += 2 {
			pairs = append(pairs, clashNodePair{node.Content[i], node.Content[i+1]})
		}
		return pairs
	}
	if node.Kind == yaml.SequenceNode {
		var out []clashNodePair
		for _, item := range node.Content {
			out = append(out, clashMergePairs(item)...)
		}
		return out
	}
	return nil
}

func (c *clashConstructor) constructScalar(node *yaml.Node) any {
	tag := clashScalarTag(node)
	value := node.Value

	switch tag {
	case "!!null":
		return nil
	case "!!bool":
		return clashParseBool(value)
	case "!!int":
		if n, ok := clashParseInt(value); ok {
			return n
		}
		// SnakeYAML throws a ConstructorException for a non-int value; yaml.v3
		// rejects the tag at parse time. Keep the text rather than fail the
		// whole document so one odd field cannot hide the proxies sequence.
		return value
	case "!!float":
		return clashParseFloat(value)
	case "!!str", "!!timestamp":
		// Timestamps: see the gap in the file header.
		return value
	}
	// Unknown tags are rejected by clashCheckTags before construction; the
	// remaining fallthrough covers only known tags with no special handling.
	return value
}

// clashScalarTag reproduces SnakeYAML's Resolver for plain scalars. yaml.v3
// already resolves most tags; the adjustments below close the YAML 1.1 / 1.2
// gaps documented in the file header. Quoted scalars are always !!str unless
// explicitly tagged (yaml.v3's Style distinguishes them).
func clashScalarTag(node *yaml.Node) string {
	tag := node.Tag
	if node.Style&(yaml.TaggedStyle|yaml.SingleQuotedStyle|yaml.DoubleQuotedStyle|yaml.LiteralStyle|yaml.FoldedStyle) != 0 {
		return tag
	}
	// A plain scalar that yaml.v3 resolved as !!str can still be a SnakeYAML
	// bool (yes/no/on/off) or a sexagesimal int (1:20, 1:20.5).
	if tag == "!!str" || tag == "" || tag == "!" {
		if node.Value != "" {
			if _, ok := clashPlainBool(node.Value); ok {
				return "!!bool"
			}
			if clashSexagesimal(node.Value) {
				if strings.Contains(node.Value, ".") {
					return "!!float"
				}
				return "!!int"
			}
		}
	}
	return tag
}

// clashSexagesimal reports a YAML 1.1 base-60 number (digits:digits...).
func clashSexagesimal(value string) bool {
	parts := strings.Split(value, ":")
	if len(parts) < 2 {
		return false
	}
	for i, part := range parts {
		if part == "" {
			return false
		}
		if i == len(parts)-1 && strings.Contains(part, ".") {
			part = strings.Replace(part, ".", "", 1)
		}
		for _, r := range part {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}

// SnakeYAML YAML 1.1 bool resolver: yes/no/true/false/on/off, any case.
func clashPlainBool(value string) (bool, bool) {
	switch strings.ToLower(value) {
	case "yes", "true", "on":
		return true, true
	case "no", "false", "off":
		return false, true
	}
	return false, false
}

func clashParseBool(value string) bool {
	if b, ok := clashPlainBool(value); ok {
		return b
	}
	// Explicit !!bool on "1"/"0" is an error in SnakeYAML; yaml.v3 has no
	// constructor to call. Fall back to the trimmed numeric form.
	return strings.TrimSpace(value) == "1"
}

// clashParseInt handles the SnakeYAML integer forms, including binary, octal,
// hex, underscores and sexagesimal, all via math/big (Java falls back from
// Integer to Long to BigInteger; we normalise to int64 or text).
func clashParseInt(value string) (int64, bool) {
	plain := strings.ReplaceAll(value, "_", "")
	if plain == "" {
		return 0, false
	}
	if strings.Contains(plain, ":") {
		parts := strings.Split(plain, ":")
		total := new(big.Int)
		negative := false
		if strings.HasPrefix(parts[0], "-") {
			negative = true
			parts[0] = parts[0][1:]
		} else {
			parts[0] = strings.TrimPrefix(parts[0], "+")
		}
		for _, part := range parts {
			if part == "" {
				return 0, false
			}
			v := new(big.Int)
			if _, ok := v.SetString(part, 10); !ok {
				return 0, false
			}
			total.Mul(total, big.NewInt(60))
			total.Add(total, v)
		}
		if negative {
			total.Neg(total)
		}
		if !total.IsInt64() {
			return 0, false
		}
		return total.Int64(), true
	}
	sign := ""
	if strings.HasPrefix(plain, "-") {
		sign, plain = "-", plain[1:]
	} else {
		plain = strings.TrimPrefix(plain, "+")
	}
	base := 10
	switch {
	case strings.HasPrefix(plain, "0b"):
		base, plain = 2, plain[2:]
	case strings.HasPrefix(plain, "0x"):
		base, plain = 16, plain[2:]
	case len(plain) > 1 && plain[0] == '0':
		base, plain = 8, plain[1:]
	}
	if plain == "" {
		return 0, false
	}
	v, ok := new(big.Int).SetString(sign+plain, base)
	if !ok || !v.IsInt64() {
		return 0, false
	}
	return v.Int64(), true
}

func clashParseFloat(value string) float64 {
	plain := strings.ReplaceAll(value, "_", "")
	plain = strings.ToLower(plain)
	if plain == ".inf" || plain == "+.inf" {
		return math.Inf(1)
	}
	if plain == "-.inf" {
		return math.Inf(-1)
	}
	if plain == ".nan" {
		return math.NaN()
	}
	if strings.Contains(plain, ":") {
		sign := 1.0
		if strings.HasPrefix(plain, "-") {
			sign, plain = -1, plain[1:]
		} else {
			plain = strings.TrimPrefix(plain, "+")
		}
		parts := strings.Split(plain, ":")
		result := 0.0
		for _, part := range parts {
			v, err := strconv.ParseFloat(part, 64)
			if err != nil {
				return 0
			}
			result = result*60 + v
		}
		return sign * result
	}
	v, err := strconv.ParseFloat(strings.TrimSuffix(plain, "."), 64)
	if err != nil {
		return 0
	}
	return v
}

func clashKeyString(value any) string {
	switch v := value.(type) {
	case string:
		return v
	case bool:
		if v {
			return "true"
		}
		return "false"
	case int64:
		return strconv.FormatInt(v, 10)
	case float64:
		return clashFormatG(v)
	case nil:
		return "<nil>"
	}
	return fmt.Sprint(value)
}

// clashConvert mirrors ClashYaml.convert: normalise constructed values into
// the generic JSON tree. JsonValues.normalizeDouble keeps integral doubles
// within +/-2^53 as int64 (Qt QJsonValue behaviour), so 1.0 becomes int64(1).
func clashConvert(value any, depth int) any {
	if depth > 1000 {
		return nil
	}
	switch v := value.(type) {
	case map[string]any:
		out := make(map[string]any, len(v))
		for key, item := range v {
			out[key] = clashConvert(item, depth+1)
		}
		return out
	case []any:
		out := make([]any, len(v))
		for i, item := range v {
			out[i] = clashConvert(item, depth+1)
		}
		return out
	case int:
		return int64(v)
	case int32:
		return int64(v)
	case uint64:
		if v <= math.MaxInt64 {
			return int64(v)
		}
		return float64(v)
	case float32:
		return clashNormalizeDouble(float64(v))
	case float64:
		return clashNormalizeDouble(v)
	case string, bool, int64, nil:
		return v
	default:
		// Byte slices, big ints etc. all become their toString() in Kotlin.
		return fmt.Sprint(v)
	}
}

func clashNormalizeDouble(v float64) any {
	if !math.IsNaN(v) && !math.IsInf(v, 0) && v == math.Trunc(v) && math.Abs(v) <= 1<<53 {
		return int64(v)
	}
	return v
}

// clashFormatG is ClashProxy.formatDouble: QByteArray::number(v, 'g', 15),
// C's %g with 15 significant digits, then trimG. Java's "%.15g" pads the
// mantissa to 15 significant digits; Go's does not, so we pad before trimming.
func clashFormatG(v float64) string {
	if math.IsNaN(v) {
		return "NaN"
	}
	if math.IsInf(v, 0) {
		if v < 0 {
			return "-Infinity"
		}
		return "Infinity"
	}
	text := fmt.Sprintf("%.15g", v)
	if i := strings.IndexAny(text, "eE"); i >= 0 {
		mantissa := clashPadGMantissa(text[:i])
		exp, err := strconv.Atoi(text[i+1:])
		if err != nil {
			return text
		}
		sign := "+"
		if exp < 0 {
			sign, exp = "-", -exp
		}
		return mantissa + "e" + sign + fmt.Sprintf("%02d", exp)
	}
	return clashPadGMantissa(text)
}

// clashPadGMantissa pads Go's %g output to Java's 15-significant-digit form.
func clashPadGMantissa(mantissa string) string {
	neg := false
	if strings.HasPrefix(mantissa, "-") {
		neg, mantissa = true, mantissa[1:]
	}
	if dot := strings.IndexByte(mantissa, '.'); dot >= 0 {
		digits := len(mantissa) - 1
		if digits < 15 {
			mantissa += strings.Repeat("0", 15-digits)
		}
		mantissa = strings.TrimRight(mantissa, "0")
		mantissa = strings.TrimSuffix(mantissa, ".")
	} else {
		digits := len(mantissa)
		if digits < 15 {
			mantissa += "." + strings.Repeat("0", 15-digits)
		}
		mantissa = strings.TrimRight(mantissa, "0")
		mantissa = strings.TrimSuffix(mantissa, ".")
	}
	if neg {
		return "-" + mantissa
	}
	return mantissa
}

// clashProxy is ClashProxy: field accessors over one converted proxies entry.
// Every accessor reads a JSON tree value; a value of the wrong shape yields
// the same default as the Kotlin getter (no coercion in string/obj/has).
type clashProxy struct {
	Node map[string]any
}

// Type is ClashProxy.type: the lower-cased `type` string.
func (p clashProxy) Type() string { return strings.ToLower(p.String("type")) }

func (p clashProxy) Has(key string) bool {
	_, ok := p.Node[key]
	return ok
}

// Present is ClashProxy.present: the key exists and is not JSON null.
func (p clashProxy) Present(key string) bool {
	v, ok := p.Node[key]
	return ok && v != nil
}

// String is load_opt<std::string>: strings pass through, integers print in
// decimal, doubles use %g/15 and booleans use true/false; all other shapes
// produce the empty string.
func (p clashProxy) String(key string) string {
	switch v := p.Node[key].(type) {
	case string:
		return v
	case int64:
		return strconv.FormatInt(v, 10)
	case float64:
		return clashFormatG(v)
	case bool:
		if v {
			return "true"
		}
		return "false"
	}
	return ""
}

// Bool is load_opt<MyBool>: only a JSON bool or 0/1 (number or text) is
// accepted; YAML 1.1 yes/no/on/off become bools at parse time and are accepted
// as such, but quoted yes/on text is rejected, matching mihomo.
func (p clashProxy) Bool(key string) bool {
	value, ok := clashReadBool(p.Node[key])
	if !ok {
		return false
	}
	return value
}

// Int is load_opt<MyInt>: a whole int64 value in int range, as a number or as
// trimmed decimal text; everything else yields 0.
func (p clashProxy) Int(key string) int {
	value, ok := clashReadInt(p.Node[key])
	if !ok {
		return 0
	}
	return value
}

// Strings is a scalar string or a sequence of scalar strings. Items of other
// shapes are dropped (mapNotNull), matching ClashProxy.scalarStrings.
func (p clashProxy) Strings(key string) []string {
	switch v := p.Node[key].(type) {
	case string:
		return []string{v}
	case []any:
		out := make([]string, 0, len(v))
		for _, item := range v {
			switch s := item.(type) {
			case string:
				out = append(out, s)
			case int64:
				out = append(out, strconv.FormatInt(s, 10))
			case float64:
				out = append(out, clashFormatG(s))
			case bool:
				if s {
					out = append(out, "true")
				} else {
					out = append(out, "false")
				}
			}
		}
		return out
	}
	return nil
}

// Obj is a nested option block: an empty view when the key is not a mapping.
func (p clashProxy) Obj(key string) clashProxy {
	if nested, ok := p.Node[key].(map[string]any); ok {
		return clashProxy{Node: nested}
	}
	return clashProxy{Node: map[string]any{}}
}

// StringMap is std::map<std::string, std::string>: keys sorted, values read
// through String.
func (p clashProxy) StringMap(key string) map[string]string {
	out := map[string]string{}
	nested, ok := p.Node[key].(map[string]any)
	if !ok {
		return out
	}
	for _, k := range clashSortedKeys(nested) {
		out[k] = clashProxy{Node: nested}.String(k)
	}
	return out
}

// StringListMap is std::map<std::string, std::vector<std::string>> (http-opts
// headers): keys sorted, values read through Strings.
func (p clashProxy) StringListMap(key string) map[string][]string {
	out := map[string][]string{}
	nested, ok := p.Node[key].(map[string]any)
	if !ok {
		return out
	}
	for _, k := range clashSortedKeys(nested) {
		out[k] = clashProxy{Node: nested}.Strings(k)
	}
	return out
}

// clashSortedKeys is JsonObject.sortedKeys (UTF-16 code unit order). Go's
// string sort is UTF-8 byte order; they differ only for keys containing
// supplementary characters, which no Clash option field uses.
func clashSortedKeys(obj map[string]any) []string {
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

var clashIntTextRE = regexp.MustCompile(`^[+-]?[0-9]+$`)

// clashReadInt is clashReadInt (clash.cpp): a whole decimal number in int
// range, as a number or as trimmed text.
func clashReadInt(value any) (int, bool) {
	switch v := value.(type) {
	case int64:
		if v >= math.MinInt32 && v <= math.MaxInt32 {
			return int(v), true
		}
	case float64:
		if v == math.Trunc(v) && v >= math.MinInt32 && v <= math.MaxInt32 {
			return int(v), true
		}
	case string:
		text := strings.TrimSpace(v)
		if clashIntTextRE.MatchString(text) {
			n, err := strconv.ParseInt(text, 10, 32)
			if err == nil {
				return int(n), true
			}
		}
	}
	return 0, false
}

// clashReadBool is clashReadBool (clash.cpp): only true/false/1/0 (case
// insensitive for text), not yes/no/on/off strings.
func clashReadBool(value any) (bool, bool) {
	switch v := value.(type) {
	case bool:
		return v, true
	case int64:
		switch v {
		case 0:
			return false, true
		case 1:
			return true, true
		}
	case string:
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "true", "1":
			return true, true
		case "false", "0":
			return false, true
		}
	}
	return false, false
}
