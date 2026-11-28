// S5 (next slice): mieru, snell and shadowtls share-link, Clash, stored-JSON
// and stored-validation support.
//
// The oracle is the Kotlin outbound trio, exactly as it is for the earlier
// slices:
//
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/Mieru.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/Snell.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/ShadowTls.kt
//   - outbound/common/{Tls,DialFields}.kt
//   - outbound/import/ClashProxy.kt
//
// The stored JSON, identity and share link are produced by the shared
// profileAdvancedNode helpers, so these three cannot drift from the
// vmess/vless/trojan/tuic path. Every query key or stored field listed here is
// one the Kotlin parser actually reads; a value this slice cannot normalise
// byte for byte is refused with supported:false, never dropped. Values the
// Kotlin parser itself drops during an import (an invalid mieru port range, a
// warning-level invalid dial value) are dropped the same way, because that
// drop is the oracle's own normalisation rather than an approximation.
//
// Mieru and ShadowTLS have no Clash mapping in Kotlin (OutboundFactory's Clash
// protocol list), so a Clash entry of either type is refused with that reason
// instead of being partially mapped. Snell's Clash form only reads psk,
// version, obfs-opts{mode,host} and udp, which this file mirrors exactly.
//
// The stored-JSON reader has three gates (profileNewMode): the JSON/SIP008
// body (import, with ParseDiag active exactly like ProfileImport), a stored row
// (export, no ParseDiag) and the profileValidate draft (validate, like export).
package mobile

import (
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// profileNewoutMieruTypes is the closed set this slice owns.
var profileNewoutMieruTypes = map[string]bool{
	"mieru": true, "snell": true, "shadowtls": true,
}

// profileNewOutboundDisplayType is Outbound.displayType.
func profileNewOutboundDisplayType(profileType string) string {
	switch profileType {
	case "mieru":
		return "Mieru"
	case "snell":
		return "Snell"
	case "shadowtls":
		return "ShadowTLS"
	}
	return profileType
}

// profileNewMode selects the gate a stored document is read through:
//
//   - import: the JSON/SIP008 body path (ProfileImport's ParseDiag scope), so
//     Kotlin's import-time normalisation applies and the parse-level refusals
//     (Snell's unsupported version) refuse the entry;
//   - export: a stored row (no ParseDiag), so Kotlin's DB-load readers apply
//     and no value is normalised;
//   - validate: the profileValidate stored draft, like export but tolerant of
//     values whose problem the validator reports as an issue.
type profileNewMode int

const (
	profileNewImportMode profileNewMode = iota
	profileNewExportMode
	profileNewValidateMode
)

// profileNewUnmodelled marks a document shape this slice does not model (a
// TLS field outside profileNewTLSTargetKeys, a reality split the single stored
// block cannot express). profileValidate answers supported:false for it, so the
// Kotlin validator owns the verdict; import/export refuse the document.
type profileNewUnmodelled struct{ Reason string }

func (refusal profileNewUnmodelled) Error() string { return refusal.Reason }

func profileUnmodelled(reason string) error { return profileNewUnmodelled{Reason: reason} }

// profileNewRefusal converts either refusal type into the
// profileImportUnsupported value the profileImport/profileExport actions reply
// with; false means the error is not a refusal and must abort the action.
func profileNewRefusal(err error) (profileImportUnsupported, bool) {
	var unsupported profileImportUnsupported
	if errors.As(err, &unsupported) {
		return unsupported, true
	}
	var unmodelled profileNewUnmodelled
	if errors.As(err, &unmodelled) {
		return profileImportUnsupported{Reason: unmodelled.Reason}, true
	}
	return profileImportUnsupported{}, false
}

// profileMieruMultiplexingLevels is mieru.h mieruMultiplexing plus the
// protobuf's MULTIPLEXING_DEFAULT (Mieru.kt mieruMultiplexingLevels).
var profileMieruMultiplexingLevels = []string{
	"", "MULTIPLEXING_OFF", "MULTIPLEXING_LOW", "MULTIPLEXING_MIDDLE",
	"MULTIPLEXING_HIGH", "MULTIPLEXING_DEFAULT",
}

// profileMieruTransports is mieru.h mieruTransports; profileSnellV6Modes is
// snell.h snellV6Modes; profileSnellNetworks is snellNetworks;
// profileSnellObfsModes is snellObfsModes.
var (
	profileMieruTransports = []string{"TCP", "UDP"}
	profileSnellV6Modes    = []string{"", "default", "unshaped", "unsafe-raw"}
	profileSnellNetworks   = []string{"", "tcp", "udp"}
	profileSnellObfsModes  = []string{"", "none", "http", "tls"}
)

// profileNewDialKeys are the DialFields keys merged flat into every stored
// outbound of this slice.
var profileNewDialKeys = map[string]bool{
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true,
	"tcp_multi_path": true, "udp_fragment": true, "bind_interface": true,
	"inet4_bind_address": true, "inet6_bind_address": true,
}

// profileNewFieldKeys is the per-type stored field allowlist: the type's own
// keys plus the flat dial fields. A key outside it is a refusal (profileExport
// falls back to Kotlin, profileValidate answers supported:false).
func profileNewFieldKeys(rawType string) map[string]bool {
	allowed := make(map[string]bool, len(profileNewDialKeys)+8)
	for key := range profileNewDialKeys {
		allowed[key] = true
	}
	switch rawType {
	case "mieru":
		for _, key := range []string{"transport", "username", "password", "multiplexing", "traffic_pattern", "server_ports"} {
			allowed[key] = true
		}
	case "snell":
		for _, key := range []string{"version", "psk", "userkey", "reuse", "network", "obfs_mode", "obfs_host", "mode"} {
			allowed[key] = true
		}
	case "shadowtls":
		for _, key := range []string{"version", "password", "tls"} {
			allowed[key] = true
		}
	}
	return allowed
}

// --- small helpers ----------------------------------------------------------

// profileNewASCIIUpper mirrors Kotlin's String.uppercase() for the ASCII values
// this slice carries; a non-ASCII value is refused because Java and Go case
// mappings can change lengths differently.
func profileNewASCIIUpper(value string) (string, bool) {
	for index := 0; index < len(value); index++ {
		if value[index] >= 0x80 {
			return "", false
		}
	}
	return strings.ToUpper(value), true
}

// profileNewASCIILower mirrors String.lowercase() for the same reason.
func profileNewASCIILower(value string) (string, bool) {
	for index := 0; index < len(value); index++ {
		if value[index] >= 0x80 {
			return "", false
		}
	}
	return strings.ToLower(value), true
}

func profileNewStringsToAny(items []string) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		out = append(out, item)
	}
	return out
}

// profileNewAnyToStrings reads a field this slice always writes as a JSON
// string array; anything else is ignored.
func profileNewAnyToStrings(value any) []string {
	list, _ := value.([]any)
	out := make([]string, 0, len(list))
	for _, item := range list {
		if text, ok := item.(string); ok {
			out = append(out, text)
		}
	}
	return out
}

// profileNewParseLong is Validation.toInt: optional '-', ASCII digits,
// overflow-checked; false on any other shape.
func profileNewParseLong(text string) (int64, bool) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return 0, false
	}
	body := trimmed
	if trimmed[0] == '-' {
		body = trimmed[1:]
		if body == "" {
			return 0, false
		}
	}
	for index := 0; index < len(body); index++ {
		if body[index] < '0' || body[index] > '9' {
			return 0, false
		}
	}
	value, err := strconv.ParseInt(trimmed, 10, 64)
	if err != nil {
		return 0, false
	}
	return value, true
}

// profileNewVariantInt is JsonValues.variantToInt (QVariant::toInt): a string
// through QtStrings.toLong, a bool as 1/0, a double through qRound64, then a
// 32-bit narrowing. ShadowTLS reads `version` this way.
func profileNewVariantInt(value any) (int, bool) {
	switch typed := value.(type) {
	case int64:
		return int(int32(typed)), true
	case float64:
		var rounded int64
		if typed >= 0 {
			rounded = int64(typed + 0.5)
		} else {
			rounded = int64(typed - 0.5)
		}
		return int(int32(rounded)), true
	case bool:
		if typed {
			return 1, true
		}
		return 0, true
	case string:
		// QtStrings.toLong: trim, optional '-', ASCII digits, overflow -> 0.
		trimmed := strings.TrimSpace(typed)
		neg := strings.HasPrefix(trimmed, "-")
		body := trimmed
		if neg {
			body = trimmed[1:]
		}
		if body == "" {
			return 0, true
		}
		for index := 0; index < len(body); index++ {
			if body[index] < '0' || body[index] > '9' {
				return 0, true
			}
		}
		parsed, err := strconv.ParseInt(trimmed, 10, 64)
		if err != nil {
			return 0, true
		}
		return int(int32(parsed)), true
	}
	return 0, false
}

// profileNewLinkWithoutQueryKey is QUrlQuery with key removed, used to drop
// `security` before the shared TLS parser runs for ShadowTLS. ShadowTLS forces
// tls.enabled=true after Tls.parseFromLink, so the switch only changes the
// pre-force state and every other field is read either way.
func profileNewLinkWithoutQueryKey(link profileParsedLink, key string) profileParsedLink {
	copied := link
	copied.Query = profileLinkQueryEmpty()
	for _, item := range link.Query.Items {
		if item.Key == key {
			continue
		}
		copied.Query.Items = append(copied.Query.Items, item)
	}
	return copied
}

// --- share links ------------------------------------------------------------

// profileImportNewOutbound dispatches a share link of one of the three types.
func profileImportNewOutbound(scheme string, link profileParsedLink) (*profileImportedNode, error) {
	switch scheme {
	case "mieru", "mierus":
		return profileImportMieruLink(link)
	case "snell":
		return profileImportSnellLink(link)
	case "shadowtls":
		return profileImportShadowTLSLink(link)
	}
	return nil, profileUnsupported("scheme not handled by the mieru/snell/shadowtls importer: " + scheme)
}

// profileImportMieruLink follows Mieru.parseFromLink:
//
//   - the authority port is discarded; every `port` item becomes either the
//     single server_port (first valid one) or one n-n server_ports entry;
//   - the first `protocol` item is the transport, upper-cased as given;
//   - multiplexing and traffic-pattern go through importTuning.
func profileImportMieruLink(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed mieru link")
	}
	if link.Query.IsEmpty() {
		return nil, profileUnsupported("malformed mieru link: no query")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	fields := map[string]any{}
	if link.UserName != "" {
		fields["username"] = link.UserName
	}
	if link.Password != "" {
		fields["password"] = link.Password
	}
	transport := ""
	for _, item := range link.Query.Items {
		if item.Key == "protocol" {
			transport = item.Value
			break
		}
	}
	protocol, ok := profileNewASCIIUpper(transport)
	if !ok {
		return nil, profileUnsupported("mieru transport is not ASCII")
	}
	if protocol == "" {
		protocol = "TCP"
	}
	fields["transport"] = protocol

	port := 0
	haveSinglePort := false
	var ranges []string
	for _, item := range link.Query.Items {
		if item.Key != "port" {
			continue
		}
		value := strings.TrimSpace(item.Value)
		if value == "" {
			continue
		}
		if strings.Contains(value, "-") {
			// An invalid range is dropped with a warning, exactly like
			// acceptOptional("port", mieruPortRange(port), port).
			if profileMieruPortRangeValid(value) {
				ranges = append(ranges, value)
			}
			continue
		}
		single, valid := profileMieruSinglePort(value)
		if !valid {
			continue
		}
		if !haveSinglePort {
			port, haveSinglePort = single, true
		} else {
			ranges = append(ranges, value+"-"+value)
		}
	}
	if len(ranges) > 0 {
		fields["server_ports"] = profileNewStringsToAny(ranges)
	}
	if link.Query.Has("multiplexing") {
		if value := profileMieruMultiplexingImport(link.Query.Value("multiplexing")); value != "" {
			fields["multiplexing"] = value
		}
	}
	if link.Query.Has("traffic-pattern") {
		if value := profileMieruTrafficPatternImport(link.Query.ValueFully("traffic-pattern")); value != "" {
			fields["traffic_pattern"] = value
		}
	}
	node := &profileStoredAdvanced{
		Type: "mieru", Name: link.Fragment, Server: link.Host, Port: port, Fields: fields,
	}
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

// profileImportSnellLink follows Snell.parseFromLink. The psk is the link's
// user name (never the password); `psk` is the alternate query key.
func profileImportSnellLink(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed snell link")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	psk := link.UserName
	if psk == "" && link.Query.Has("psk") {
		psk = link.Query.ValueFully("psk")
	}
	version := 4
	if link.Query.Has("version") {
		version = profileImportQtInt(link.Query.Value("version"))
		if !profileSnellVersionSupported(version) {
			return nil, profileUnsupported("snell version is not supported by the core: " + strings.TrimSpace(link.Query.Value("version")))
		}
	}
	fields := map[string]any{"version": version}
	if psk != "" {
		fields["psk"] = psk
	}
	if link.Query.Has("userkey") {
		if value := link.Query.ValueFully("userkey"); value != "" {
			fields["userkey"] = value
		}
	}
	if link.Query.Has("reuse") {
		// snell.cpp: empty, or anything but the literal 0/false, is reuse on.
		raw := link.Query.Value("reuse")
		if raw == "" || (raw != "0" && !strings.EqualFold(raw, "false")) {
			fields["reuse"] = true
		}
	}
	if link.Query.Has("network") {
		value, ok := profileSnellNetworkImport(link.Query.Value("network"))
		if !ok {
			return nil, profileUnsupported("snell network is not ASCII")
		}
		if value != "" {
			fields["network"] = value
		}
	}
	if link.Query.Has("obfs") {
		value, ok := profileSnellObfsImport(link.Query.Value("obfs"))
		if !ok {
			return nil, profileUnsupported("snell obfs mode is not ASCII")
		}
		if value != "" {
			fields["obfs_mode"] = value
		}
	}
	if link.Query.Has("obfs-host") {
		if value := strings.TrimSpace(link.Query.ValueFully("obfs-host")); value != "" {
			fields["obfs_host"] = value
		}
	}
	if link.Query.Has("mode") {
		if value := strings.TrimSpace(link.Query.Value("mode")); value != "" {
			fields["mode"] = value
		}
	}
	// Snell.writeFields writes only the selected version's options.
	if version == 6 {
		delete(fields, "obfs_mode")
		delete(fields, "obfs_host")
	} else {
		delete(fields, "mode")
	}
	node := &profileStoredAdvanced{
		Type: "snell", Name: link.Fragment, Server: link.Host,
		Port: link.PortOrDefault(0), Fields: fields,
	}
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

// profileImportShadowTLSLink follows ShadowTls.parseFromLink: the password is
// the URL password, `version` defaults to 1, TLS is forced on, and port 0
// (absent or explicit) becomes 443.
func profileImportShadowTLSLink(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed shadowtls link")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	version := 1
	if raw := strings.TrimSpace(link.Query.Value("version")); raw != "" {
		parsed, ok := profileNewParseLong(raw)
		if !ok || parsed < 0 || parsed > 3 {
			return nil, profileUnsupported("shadowtls version must be between 0 and 3: " + raw)
		}
		version = int(parsed)
	}
	// Tls.parseFromLink reports an Error for security=reality without pbk,
	// which refuses the whole profile on the Kotlin path; refuse it here too
	// instead of storing a plain-TLS node the user did not ask for.
	if strings.EqualFold(strings.TrimSpace(link.Query.Value("security")), "reality") && !link.Query.Has("pbk") {
		return nil, profileUnsupported("shadowtls security=reality requires pbk")
	}
	// ShadowTLS forces tls.enabled=true regardless of `security`, so parse the
	// TLS fields without the switch. Everything else is Tls.parseFromLink.
	tlsLink := profileNewLinkWithoutQueryKey(link, "security")
	tls, _, err := profileImportTLS(tlsLink, true, true)
	if err != nil {
		return nil, err
	}
	tls["enabled"] = true

	fields := map[string]any{"version": version}
	if link.Password != "" {
		fields["password"] = link.Password
	}
	port := link.PortOrDefault(0)
	if port == 0 {
		port = 443
	}
	node := &profileStoredAdvanced{
		Type: "shadowtls", Name: link.Fragment, Server: link.Host, Port: port,
		Fields: fields, TLS: tls, HasTLS: true,
	}
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

// --- mieru option helpers --------------------------------------------------

// profileMieruUint16 is Validation.parseUint16: decimal digits only, leading
// zeros allowed, at most 65535.
func profileMieruUint16(text string) (int, bool) {
	if text == "" {
		return 0, false
	}
	for index := 0; index < len(text); index++ {
		if text[index] < '0' || text[index] > '9' {
			return 0, false
		}
	}
	value, err := strconv.Atoi(text)
	if err != nil || value > 65535 {
		return 0, false
	}
	return value, true
}

// profileMieruSinglePort is Validation.port on a bare `port` item.
func profileMieruSinglePort(text string) (int, bool) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return 0, false
	}
	for index := 0; index < len(trimmed); index++ {
		if trimmed[index] < '0' || trimmed[index] > '9' {
			return 0, false
		}
	}
	value, err := strconv.Atoi(trimmed)
	if err != nil || value < 1 || value > 65535 {
		return 0, false
	}
	return value, true
}

// profileMieruPortRangeValid is MieruChecks.mieruPortRange: a dash range whose
// two ends are 1..65535 with begin <= end. The caller passes the trimmed item.
func profileMieruPortRangeValid(text string) bool {
	sides := strings.Split(strings.TrimSpace(text), "-")
	if len(sides) != 2 {
		return false
	}
	begin, okBegin := profileMieruUint16(sides[0])
	end, okEnd := profileMieruUint16(sides[1])
	if !okBegin || !okEnd || begin == 0 || end == 0 {
		return false
	}
	return begin <= end
}

// profileMieruBase64Valid is Validation.base64 for the standard alphabet: the
// text is trimmed, the trailing '=' rules apply, and a successful strict decode
// must produce bytes.
func profileMieruBase64Valid(text string) bool {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return true
	}
	equals := 0
	for equals < len(trimmed) && trimmed[len(trimmed)-1-equals] == '=' {
		equals++
	}
	data := len(trimmed) - equals
	ok := data > 0 && equals <= 2
	if ok {
		if equals > 0 {
			ok = len(trimmed)%4 == 0
		} else {
			ok = len(trimmed)%4 != 1
		}
	}
	for index := 0; ok && index < data; index++ {
		char := trimmed[index]
		digit := (char >= 'A' && char <= 'Z') || (char >= 'a' && char <= 'z') ||
			(char >= '0' && char <= '9') || char == '+' || char == '/'
		if !digit {
			ok = false
		}
	}
	if !ok {
		return false
	}
	padded := trimmed
	for len(padded)%4 != 0 {
		padded += "="
	}
	decoded, decodedOK := profileBase64Decode(padded, false)
	return decodedOK && len(decoded) > 0
}

// profileMieruTrafficPatternValid is MieruChecks.mieruTrafficPattern: a valid
// padded base64 value whose trimmed length is a multiple of four.
func profileMieruTrafficPatternValid(text string) bool {
	if !profileMieruBase64Valid(text) {
		return false
	}
	return len(strings.TrimSpace(text))%4 == 0
}

// profileMieruTrafficPatternImport is Mieru.importTuning's pattern branch: a
// valid unpadded value gains the missing '=' padding; anything else is cleared.
func profileMieruTrafficPatternImport(raw string) string {
	pattern := strings.TrimSpace(raw)
	if profileMieruBase64Valid(pattern) {
		for len(pattern)%4 != 0 {
			pattern += "="
		}
	}
	if !profileMieruTrafficPatternValid(pattern) {
		return ""
	}
	return pattern
}

// profileMieruMultiplexingImport is importTuning's multiplexing branch: trim,
// then drop an unknown level (case-sensitive, like Validation.oneOf).
func profileMieruMultiplexingImport(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" || !profileMieruMultiplexingKnown(value) {
		return ""
	}
	return value
}

func profileMieruTransportKnown(value string) bool {
	for _, allowed := range profileMieruTransports {
		if allowed == value {
			return true
		}
	}
	return false
}

func profileMieruMultiplexingKnown(value string) bool {
	for _, allowed := range profileMieruMultiplexingLevels {
		if allowed == value {
			return true
		}
	}
	return false
}

// profileMieruServerPorts is the stored server_ports derivation shared by the
// JSON reader and the validator: a string is trimmed and split, an array keeps
// its string items (JsonArray.strings maps anything else to ""), and empty
// parts vanish exactly as splitSkipEmpty does on export.
func profileMieruServerPorts(value any, rawType string) ([]string, error) {
	var text string
	switch typed := value.(type) {
	case string:
		text = strings.TrimSpace(typed)
	case []any:
		parts := make([]string, 0, len(typed))
		for _, item := range typed {
			if itemText, ok := item.(string); ok {
				parts = append(parts, strings.TrimSpace(itemText))
			} else {
				parts = append(parts, "")
			}
		}
		text = strings.Join(parts, ",")
	default:
		return nil, profileUnsupported("stored " + rawType + " server_ports has unsupported value")
	}
	var out []string
	for _, part := range strings.Split(text, ",") {
		trimmed := strings.TrimSpace(part)
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out, nil
}

// --- snell option helpers --------------------------------------------------

// profileSnellVersionSupported is Snell.supportedVersion: the core registers a
// v4 and a v6 client only.
func profileSnellVersionSupported(version int) bool {
	return version == 4 || version == 6
}

// profileSnellNetworkImport is snellImportNetwork: lower-case, comma split,
// both tcp+udp mean the empty default, anything unknown means the default.
func profileSnellNetworkImport(raw string) (string, bool) {
	lower, ok := profileNewASCIILower(raw)
	if !ok {
		return "", false
	}
	haveTCP, haveUDP := false, false
	for _, part := range strings.Split(lower, ",") {
		switch strings.TrimSpace(part) {
		case "":
		case "tcp":
			haveTCP = true
		case "udp":
			haveUDP = true
		default:
			return "", true
		}
	}
	if haveTCP && haveUDP {
		return "", true
	}
	if haveTCP {
		return "tcp", true
	}
	if haveUDP {
		return "udp", true
	}
	return "", true
}

// profileSnellObfsImport is snellImportObfsMode: trim then lower-case.
func profileSnellObfsImport(raw string) (string, bool) {
	return profileNewASCIILower(strings.TrimSpace(raw))
}

// profileSnellObfsSupported is Snell.supportedObfsMode over the lower-cased
// value the importer stores.
func profileSnellObfsSupported(value string) bool {
	for _, allowed := range profileSnellObfsModes {
		if allowed == value {
			return true
		}
	}
	return false
}

// profileNewOneOf is Validation.oneOf over a trimmed value.
func profileNewOneOf(value string, allowed []string, ignoreCase bool) bool {
	trimmed := strings.TrimSpace(value)
	for _, item := range allowed {
		if ignoreCase {
			if strings.EqualFold(item, trimmed) {
				return true
			}
		} else if item == trimmed {
			return true
		}
	}
	return false
}

// --- Clash -----------------------------------------------------------------

// clashSnell is Snell.parseFromClash: psk, a positive `version`, the first
// supported obfs mode, `udp` (absent/false means tcp-only), and the base
// name/server/port. Every other key is refused rather than ignored.
func clashSnell(p clashProxy) (*profileImportedNode, error) {
	if err := clashRejectUnknownFields(p, "snell", []string{
		"type", "name", "server", "port", "psk", "version", "obfs-opts", "udp",
	}); err != nil {
		return nil, err
	}
	name, server, port, err := clashBase(p, "snell")
	if err != nil {
		return nil, err
	}
	version := 4
	if value := p.Int("version"); value > 0 {
		version = value
	}
	if !profileSnellVersionSupported(version) {
		return nil, profileUnsupported("clash: snell version is not supported by the core: " + strconv.Itoa(version))
	}
	fields := map[string]any{"version": version}
	if psk := p.String("psk"); psk != "" {
		fields["psk"] = psk
	}
	obfs := p.Obj("obfs-opts")
	if err := clashRejectUnknownFields(obfs, "snell obfs-opts", []string{"mode", "host"}); err != nil {
		return nil, err
	}
	obfsMode, ok := profileSnellObfsImport(obfs.String("mode"))
	if !ok {
		return nil, profileUnsupported("clash: snell obfs mode is not ASCII")
	}
	if !profileSnellObfsSupported(obfsMode) {
		return nil, profileUnsupported("clash: snell obfs mode is not supported by the core: " + obfsMode)
	}
	// Snell.writeFields writes obfs options only for v4; a v6 entry keeps the
	// parsed mode in the model but not in the stored form.
	if version != 6 {
		if obfsMode != "" {
			fields["obfs_mode"] = obfsMode
		}
		if host := obfs.String("host"); host != "" {
			fields["obfs_host"] = host
		}
	}
	if !p.Bool("udp") {
		fields["network"] = "tcp"
	}
	node := &profileStoredAdvanced{
		Type: "snell", Name: name, Server: server, Port: port, Fields: fields,
	}
	return profileAdvancedNode(node)
}

// --- stored JSON / SIP008 --------------------------------------------------

// profileNewParsed is the result of reading one stored document: the node, the
// fields the gate could not model (for the supported:false answer) and the
// ShadowTLS TLS block as parsed. The parsed block is kept even when disabled,
// because ShadowTLS must-tls means the validator checks it anyway.
type profileNewParsed struct {
	Node    *profileStoredAdvanced
	Unknown []string
	TLS     map[string]any
}

// profileImportStoredNew converts a stored outbound object from a JSON/SIP008
// body into the same node the link/Clash converters emit.
func profileImportStoredNew(object map[string]any, rawType string) (*profileImportedNode, error) {
	parsed, err := profileNewFromObject(object, rawType, profileNewImportMode)
	if err != nil {
		if refused, ok := profileNewRefusal(err); ok {
			return nil, refused
		}
		return nil, err
	}
	if len(parsed.Unknown) > 0 {
		return nil, profileUnsupported(fmt.Sprintf("stored %s field not ported yet: %s", rawType, parsed.Unknown[0]))
	}
	return profileAdvancedNode(parsed.Node)
}

// profileNewFromObject reads one stored outbound in the selected gate.
func profileNewFromObject(object map[string]any, rawType string, mode profileNewMode) (*profileNewParsed, error) {
	importing := mode == profileNewImportMode
	server := configJSONString(object, "server")
	if importing {
		if server == "" || profileHasUnsupportedHostForm(server) {
			return nil, profileUnsupported("stored " + rawType + " has no valid server")
		}
	} else if server != "" {
		if _, valid := profileLinkNormalizeHost(server); !valid {
			return nil, profileUnsupported("profileExport: invalid server " + strconv.Quote(server))
		}
		if strings.Contains(server, "%") {
			return nil, profileUnsupported("server host needs percent-decoding")
		}
	}
	port, _, err := profileNewIntField(object, "server_port", rawType)
	if err != nil {
		return nil, err
	}
	fields, err := profileNewDialFields(object, rawType, importing)
	if err != nil {
		return nil, err
	}
	parsed := &profileNewParsed{}
	node := &profileStoredAdvanced{
		Type: rawType, Name: configJSONString(object, "tag"),
		Server: aceShareHost(server), Port: port, Fields: fields,
	}
	switch rawType {
	case "mieru":
		if err := profileNewMieruFields(node, object, importing); err != nil {
			return nil, err
		}
	case "snell":
		if err := profileNewSnellFields(node, object, importing, mode != profileNewValidateMode); err != nil {
			return nil, err
		}
	case "shadowtls":
		if err := profileNewShadowTLSFields(node, object, mode, parsed); err != nil {
			return nil, err
		}
	}

	// Unknown keys fail the document (never a silent drop). The tests assert
	// the first offending key so a caller can locate it.
	allowed := profileNewFieldKeys(rawType)
	unknown := parsed.Unknown
	for key := range object {
		switch key {
		case "type", "tag", "server", "server_port":
			continue
		}
		if !allowed[key] {
			unknown = append(unknown, key)
		}
	}
	parsed.Unknown = unknown
	if importing {
		if rawType == "mieru" {
			if node.Port == 0 && len(profileNewAnyToStrings(node.Fields["server_ports"])) == 0 {
				return nil, profileUnsupported("stored mieru has no valid server_port")
			}
		} else if node.Port <= 0 {
			return nil, profileUnsupported("stored " + rawType + " has no valid server_port")
		}
	}
	parsed.Node = node
	return parsed, nil
}

func profileNewMieruFields(node *profileStoredAdvanced, object map[string]any, importing bool) error {
	fields := node.Fields
	transport := "TCP"
	if value, present, err := profileNewStringField(object, "transport", "mieru"); err != nil {
		return err
	} else if present {
		if importing {
			upper, ok := profileNewASCIIUpper(strings.TrimSpace(value))
			if !ok {
				return profileUnsupported("stored mieru transport is not ASCII")
			}
			if upper != "" {
				transport = upper
			}
		} else if value != "" {
			transport = value
		}
	}
	fields["transport"] = transport
	if value, present, err := profileNewStringField(object, "username", "mieru"); err != nil {
		return err
	} else if present && value != "" {
		fields["username"] = value
	}
	if value, present, err := profileNewStringField(object, "password", "mieru"); err != nil {
		return err
	} else if present && value != "" {
		fields["password"] = value
	}
	if value, present, err := profileNewStringField(object, "multiplexing", "mieru"); err != nil {
		return err
	} else if present {
		if importing {
			if normalized := profileMieruMultiplexingImport(value); normalized != "" {
				fields["multiplexing"] = normalized
			}
		} else if value != "" {
			fields["multiplexing"] = value
		}
	}
	if value, present, err := profileNewStringField(object, "traffic_pattern", "mieru"); err != nil {
		return err
	} else if present {
		if importing {
			if normalized := profileMieruTrafficPatternImport(value); normalized != "" {
				fields["traffic_pattern"] = normalized
			}
		} else if value != "" {
			fields["traffic_pattern"] = value
		}
	}
	if value, present := object["server_ports"]; present {
		ports, err := profileMieruServerPorts(value, "mieru")
		if err != nil {
			return err
		}
		if len(ports) > 0 {
			fields["server_ports"] = profileNewStringsToAny(ports)
		}
	}
	return nil
}

// profileNewSnellFields reads the Snell fields. `strictVersion` is the import
// and export gate: Snell.parseFromJson returns false there for a version the
// core has no client for, so the node must not exist; the validator reports
// the version as an issue instead.
func profileNewSnellFields(node *profileStoredAdvanced, object map[string]any, importing, strictVersion bool) error {
	fields := node.Fields
	version := 4
	if value, present, err := profileNewIntField(object, "version", "snell"); err != nil {
		return err
	} else if present {
		version = value
	}
	if strictVersion && !profileSnellVersionSupported(version) {
		return profileUnsupported("stored snell version is not supported by the core: " + strconv.Itoa(version))
	}
	fields["version"] = version
	if value, present, err := profileNewStringField(object, "psk", "snell"); err != nil {
		return err
	} else if present && value != "" {
		fields["psk"] = value
	}
	if value, present, err := profileNewStringField(object, "userkey", "snell"); err != nil {
		return err
	} else if present && value != "" {
		fields["userkey"] = value
	}
	if value, present, err := profileNewBoolField(object, "reuse", "snell"); err != nil {
		return err
	} else if present && value {
		fields["reuse"] = true
	}
	if importing {
		if value, present, err := profileNewStringListField(object, "network", "snell"); err != nil {
			return err
		} else if present {
			normalized, ok := profileSnellNetworkImport(strings.Join(value, ","))
			if !ok {
				return profileUnsupported("stored snell network is not ASCII")
			}
			if normalized != "" {
				fields["network"] = normalized
			}
		}
	} else if value, present := object["network"]; present {
		text, usable, err := profileSnellNetworkDraft(value)
		if err != nil {
			return err
		}
		if usable && text != "" {
			fields["network"] = text
		}
	}
	if value, present, err := profileNewStringField(object, "obfs_mode", "snell"); err != nil {
		return err
	} else if present {
		normalized := value
		if importing {
			var ok bool
			if normalized, ok = profileSnellObfsImport(value); !ok {
				return profileUnsupported("stored snell obfs_mode is not ASCII")
			}
		}
		if normalized != "" {
			fields["obfs_mode"] = normalized
		}
	}
	if value, present, err := profileNewStringField(object, "obfs_host", "snell"); err != nil {
		return err
	} else if present && value != "" {
		fields["obfs_host"] = value
	}
	if value, present, err := profileNewStringField(object, "mode", "snell"); err != nil {
		return err
	} else if present {
		normalized := value
		if importing {
			normalized = strings.TrimSpace(value)
		}
		if normalized != "" {
			fields["mode"] = normalized
		}
	}
	// Snell.writeFields writes only the selected version's options; the other
	// version's values stay in the model (the validator warns about them) but
	// never reach the stored form.
	if version == 6 {
		delete(fields, "obfs_mode")
		delete(fields, "obfs_host")
	} else {
		delete(fields, "mode")
	}
	return nil
}

// profileSnellNetworkDraft is JsonObject.network for the stored-row gate: a
// string verbatim, an array through importNetwork (Snell.parseFromJson runs
// that for arrays regardless of ParseDiag), anything else a refusal.
func profileSnellNetworkDraft(value any) (string, bool, error) {
	switch typed := value.(type) {
	case string:
		return typed, true, nil
	case []any:
		parts := make([]string, 0, len(typed))
		for _, item := range typed {
			if text, ok := item.(string); ok {
				parts = append(parts, text)
			} else {
				parts = append(parts, "")
			}
		}
		normalized, ok := profileSnellNetworkImport(strings.Join(parts, ","))
		if !ok {
			return "", false, profileUnsupported("stored snell network is not ASCII")
		}
		return normalized, true, nil
	}
	return "", false, profileUnsupported("stored snell field has unsupported value: network")
}

// profileNewShadowTLSFields reads version/password/tls for ShadowTLS. `mode`
// decides how the TLS block is canonicalised: import applies Tls.parseFromJson
// with ParseDiag active, export/validate keep the stored values.
func profileNewShadowTLSFields(node *profileStoredAdvanced, object map[string]any, mode profileNewMode, parsed *profileNewParsed) error {
	version := 1
	if value, present, err := profileNewVariantIntField(object, "version", "shadowtls"); err != nil {
		return err
	} else if present {
		version = value
	}
	node.Fields["version"] = version
	if value, present, err := profileNewStringField(object, "password", "shadowtls"); err != nil {
		return err
	} else if present && value != "" {
		node.Fields["password"] = value
	}
	value, present := object["tls"]
	if !present {
		return nil
	}
	block, ok := value.(map[string]any)
	if !ok {
		return profileUnsupported("stored tls block is not an object")
	}
	var (
		parsedTLS map[string]any
		unknown   []string
		err       error
	)
	if mode == profileNewImportMode {
		parsedTLS, unknown, err = profileNewTLSImport(block)
	} else {
		parsedTLS, err = profileNewTLSDraft(block)
	}
	if err != nil {
		return err
	}
	parsed.Unknown = append(parsed.Unknown, unknown...)
	parsed.TLS = parsedTLS
	canonical, err := profileNewTLSCanonical(parsedTLS)
	if err != nil {
		return err
	}
	if enabled, _ := canonical["enabled"].(bool); enabled {
		node.TLS, node.HasTLS = canonical, true
	}
	return nil
}

// profileNewTLSTargetKeys is the TLS field set this slice models for ShadowTLS
// stored documents (a subset of TLS.h: the editor and the common share links
// need these; certificates/fragment/spoof/ECH need the Kotlin validator).
var profileNewTLSTargetKeys = map[string]bool{
	"enabled": true, "disable_sni": true, "server_name": true, "insecure": true,
	"alpn": true, "min_version": true, "max_version": true, "utls": true, "reality": true,
}

// profileNewTLSImport is Tls.parseFromJson with ParseDiag active, restricted to
// profileNewTLSTargetKeys. The returned map is the parsed shape (see
// profileNewTLSCanonical); unknown nested keys are reported for supported:false.
func profileNewTLSImport(raw map[string]any) (map[string]any, []string, error) {
	if err := profileNewTLSCheckKeys(raw); err != nil {
		return nil, nil, err
	}
	parsed := map[string]any{"enabled": configJSONBool(raw, "enabled")}
	if configJSONBool(raw, "disable_sni") {
		parsed["disable_sni"] = true
	}
	if serverName := configJSONString(raw, "server_name"); serverName != "" {
		parsed["server_name"] = aceShareHost(serverName)
	}
	if configJSONBool(raw, "insecure") {
		parsed["insecure"] = true
	}
	if value, present := raw["alpn"]; present {
		// Tls.parseFromJson imports through jsonStringList then tlsLinkList:
		// the items are joined with ',' and re-split, trimming and dropping
		// empty entries.
		joined := strings.Join(profileExportStringList(value), ",")
		items := make([]any, 0, 2)
		for _, part := range strings.Split(joined, ",") {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				items = append(items, trimmed)
			}
		}
		if len(items) > 0 {
			parsed["alpn"] = items
		}
	}
	for _, key := range []string{"min_version", "max_version"} {
		if value, present, err := profileNewStringField(raw, key, "tls"); err != nil {
			return nil, nil, err
		} else if present {
			// `checked` trims and keeps a value only when TlsChecks.tlsVersion
			// accepts it.
			switch strings.TrimSpace(value) {
			case "1.0", "1.1", "1.2", "1.3":
				parsed[key] = strings.TrimSpace(value)
			}
		}
	}
	if value, present := raw["utls"]; present {
		utlsRaw, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("tls utls is not an object")
		}
		for key := range utlsRaw {
			if key != "enabled" && key != "fingerprint" {
				return nil, nil, profileUnmodelled("tls.utls field not ported yet: " + key)
			}
		}
		utls := map[string]any{"enabled": configJSONBool(utlsRaw, "enabled")}
		if fingerprint := configJSONString(utlsRaw, "fingerprint"); fingerprint != "" {
			// importTlsFingerprint keeps a known value, lower-cases a case-only
			// mistake and clears anything else.
			if normalized, ok := profileTLSFingerprint(fingerprint); ok {
				utls["fingerprint"] = normalized
			}
		}
		parsed["utls"] = utls
	}
	if value, present := raw["reality"]; present {
		realityRaw, ok := value.(map[string]any)
		if !ok {
			return nil, nil, profileUnsupported("tls reality is not an object")
		}
		for key := range realityRaw {
			switch key {
			case "enabled", "public_key", "short_id", "mldsa65_verify":
			default:
				return nil, nil, profileUnmodelled("tls.reality field not ported yet: " + key)
			}
		}
		reality := map[string]any{"enabled": configJSONBool(realityRaw, "enabled")}
		publicKey := strings.TrimSpace(configJSONString(realityRaw, "public_key"))
		if strings.HasSuffix(publicKey, "=") {
			// importRealityPublicKey drops the '=' padding sing-box refuses only
			// when the unpadded key is a valid 32-byte base64url value.
			unpadded := strings.TrimRight(publicKey, "=")
			if decoded, ok := profileBase64Decode(unpadded, true); ok && len(decoded) == 32 {
				publicKey = unpadded
			}
		}
		if publicKey != "" {
			reality["public_key"] = publicKey
			// Tls.parseFromJson: a public key turns TLS on even when off.
			parsed["enabled"] = true
		}
		if shortID := strings.TrimSpace(configJSONString(realityRaw, "short_id")); shortID != "" {
			reality["short_id"] = shortID
		}
		if verify := strings.TrimSpace(configJSONString(realityRaw, "mldsa65_verify")); verify != "" {
			if !profileValidMLDSA(verify) {
				// importMldsa65Verify reports an Error, which refuses the profile.
				return nil, nil, profileUnsupported("tls.reality.mldsa65_verify is not a valid ML-DSA-65 key")
			}
			reality["mldsa65_verify"] = verify
		}
		parsed["reality"] = reality
	}
	return parsed, nil, nil
}

// profileNewTLSDraft is the stored-row reader used by profileExport and the
// stored validator: Tls.parseFromJson without ParseDiag, so values are kept as
// written for the exporter to reproduce (and for the validator to judge).
func profileNewTLSDraft(raw map[string]any) (map[string]any, error) {
	if err := profileNewTLSCheckKeys(raw); err != nil {
		return nil, err
	}
	parsed := map[string]any{"enabled": configJSONBool(raw, "enabled")}
	if configJSONBool(raw, "disable_sni") {
		parsed["disable_sni"] = true
	}
	if serverName := configJSONString(raw, "server_name"); serverName != "" {
		parsed["server_name"] = aceShareHost(serverName)
	}
	if configJSONBool(raw, "insecure") {
		parsed["insecure"] = true
	}
	if value, present := raw["alpn"]; present {
		if list := profileExportStringList(value); len(list) > 0 {
			parsed["alpn"] = stringListToAny(list)
		}
	}
	for _, key := range []string{"min_version", "max_version"} {
		// Tls.parseFromJson's `checked` trims these even without ParseDiag.
		if value := strings.TrimSpace(configJSONString(raw, key)); value != "" {
			parsed[key] = value
		}
	}
	if value, present := raw["utls"]; present {
		utlsRaw, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("tls utls is not an object")
		}
		for key := range utlsRaw {
			if key != "enabled" && key != "fingerprint" {
				return nil, profileUnmodelled("tls.utls field not ported yet: " + key)
			}
		}
		utls := map[string]any{"enabled": configJSONBool(utlsRaw, "enabled")}
		if fingerprint := configJSONString(utlsRaw, "fingerprint"); fingerprint != "" {
			utls["fingerprint"] = fingerprint
		}
		parsed["utls"] = utls
	}
	if value, present := raw["reality"]; present {
		realityRaw, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("tls reality is not an object")
		}
		for key := range realityRaw {
			switch key {
			case "enabled", "public_key", "short_id", "mldsa65_verify":
			default:
				return nil, profileUnmodelled("tls.reality field not ported yet: " + key)
			}
		}
		reality := map[string]any{"enabled": configJSONBool(realityRaw, "enabled")}
		// Reality.parseFromJson trims these three fields even without ParseDiag.
		for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
			if text := strings.TrimSpace(configJSONString(realityRaw, key)); text != "" {
				reality[key] = text
			}
		}
		if _, ok := reality["public_key"]; ok {
			// Tls.parseFromJson: a public key turns TLS on even when off.
			parsed["enabled"] = true
		}
		parsed["reality"] = reality
	}
	return parsed, nil
}

// profileNewTLSCanonical is Tls.exportToJson over the parsed shape. A disabled
// block becomes {} (ShadowTLS then writes no tls key at all), and a reality
// block is written only when it is enabled -- while its public_key still
// forces the TLS block on, exactly like Tls.parseFromJson.
func profileNewTLSCanonical(parsed map[string]any) (map[string]any, error) {
	if len(parsed) == 0 || !configJSONBool(parsed, "enabled") {
		return map[string]any{}, nil
	}
	tls := map[string]any{"enabled": true}
	if configJSONBool(parsed, "disable_sni") {
		tls["disable_sni"] = true
	}
	if serverName := configJSONString(parsed, "server_name"); serverName != "" {
		tls["server_name"] = serverName
	}
	if configJSONBool(parsed, "insecure") {
		tls["insecure"] = true
	}
	if list := profileExportStringList(parsed["alpn"]); len(list) > 0 {
		tls["alpn"] = stringListToAny(list)
	}
	for _, key := range []string{"min_version", "max_version"} {
		if value := configJSONString(parsed, key); value != "" {
			tls[key] = value
		}
	}
	if utls, ok := parsed["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
		out := map[string]any{"enabled": true}
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" {
			out["fingerprint"] = fingerprint
		}
		tls["utls"] = out
	}
	if reality, ok := parsed["reality"].(map[string]any); ok {
		enabled := configJSONBool(reality, "enabled")
		publicKey := configJSONString(reality, "public_key")
		if !enabled && publicKey != "" {
			// Reality.parseFromJson keeps the key, Tls.parseFromJson turns TLS on,
			// exportToJson omits a disabled block while exportIdentity keeps the
			// key: that split cannot be represented by one stored block.
			return nil, profileUnmodelled("tls.reality public_key without enabled is not reproducible")
		}
		if enabled {
			out := map[string]any{"enabled": true}
			for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
				if value := configJSONString(reality, key); value != "" {
					out[key] = value
				}
			}
			tls["reality"] = out
		}
	}
	return tls, nil
}

func profileNewTLSCheckKeys(raw map[string]any) error {
	for key := range raw {
		if !profileNewTLSTargetKeys[key] {
			return profileUnmodelled("tls field not ported yet: " + key)
		}
	}
	return nil
}

// --- strict stored scalar readers ------------------------------------------

func profileNewStringField(object map[string]any, key, rawType string) (string, bool, error) {
	raw, present := object[key]
	if !present {
		return "", false, nil
	}
	text, ok := raw.(string)
	if !ok {
		return "", false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
	}
	return text, true, nil
}

func profileNewBoolField(object map[string]any, key, rawType string) (bool, bool, error) {
	raw, present := object[key]
	if !present {
		return false, false, nil
	}
	value, ok := raw.(bool)
	if !ok {
		return false, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
	}
	return value, true, nil
}

func profileNewIntField(object map[string]any, key, rawType string) (int, bool, error) {
	raw, present := object[key]
	if !present {
		return 0, false, nil
	}
	switch raw.(type) {
	case int64, float64:
		return configJSONInt(raw), true, nil
	}
	return 0, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
}

func profileNewVariantIntField(object map[string]any, key, rawType string) (int, bool, error) {
	raw, present := object[key]
	if !present {
		return 0, false, nil
	}
	value, ok := profileNewVariantInt(raw)
	if !ok {
		return 0, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
	}
	return value, true, nil
}

func profileNewStringListField(object map[string]any, key, rawType string) ([]string, bool, error) {
	raw, present := object[key]
	if !present {
		return nil, false, nil
	}
	switch typed := raw.(type) {
	case string:
		return []string{typed}, true, nil
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			text, ok := item.(string)
			if !ok {
				return nil, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
			}
			out = append(out, text)
		}
		return out, true, nil
	}
	return nil, false, profileUnsupported("stored " + rawType + " field has unsupported value: " + key)
}

// profileNewDialFields reads the flat DialFields keys. A field Kotlin's import
// would drop after a failed check is dropped here too; the stored-row gate
// keeps it as written.
func profileNewDialFields(object map[string]any, rawType string, importing bool) (map[string]any, error) {
	fields := map[string]any{}
	for _, key := range []string{"reuse_addr", "tcp_fast_open", "tcp_multi_path", "udp_fragment"} {
		value, present, err := profileNewBoolField(object, key, rawType)
		if err != nil {
			return nil, err
		}
		if present && value {
			fields[key] = true
		}
	}
	if value, present, err := profileNewStringField(object, "connect_timeout", rawType); err != nil {
		return nil, err
	} else if present {
		trimmed := strings.TrimSpace(value)
		if trimmed != "" && (!importing || profileImportValidDuration(trimmed)) {
			fields["connect_timeout"] = trimmed
		}
	}
	if value, present, err := profileNewStringField(object, "bind_interface", rawType); err != nil {
		return nil, err
	} else if present && value != "" {
		fields["bind_interface"] = value
	}
	for _, key := range []string{"inet4_bind_address", "inet6_bind_address"} {
		value, present, err := profileNewStringField(object, key, rawType)
		if err != nil {
			return nil, err
		}
		if !present {
			continue
		}
		trimmed := strings.TrimSpace(value)
		if trimmed == "" {
			continue
		}
		if importing && !profileNewBindAddressValid(key, trimmed) {
			continue
		}
		fields[key] = trimmed
	}
	return fields, nil
}

// profileNewBindAddressValid is dialFieldsRule's inet4/inet6 branch (dial
// rules allow an IPv6 zone, which netip also parses).
func profileNewBindAddressValid(key, value string) bool {
	address, err := netip.ParseAddr(value)
	if err != nil {
		return false
	}
	if key == "inet4_bind_address" {
		return address.Is4()
	}
	return address.Is6()
}
