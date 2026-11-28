// S5 (next slice): juicity, naive, ssh and trusttunnel share-link, Clash,
// stored-JSON and stored-validation support.
//
// The oracle is the Kotlin outbound quartet, exactly as it is for the earlier
// slices:
//
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/Juicity.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/Naive.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/Ssh.kt
//   - app/src/main/java/io/nekohasekai/sagernet/outbound/types/TrustTunnel.kt
//   - outbound/common/{Tls,DialFields}.kt
//   - outbound/import/{ClashProxy,ProfileImport}.kt
//
// The stored JSON, identity and share link are produced by the shared
// profileAdvancedNode helpers, so these four cannot drift from the
// vmess/vless/trojan/tuic/newout path. Every query key or stored field listed
// here is one the Kotlin parser actually reads; a value this slice cannot
// normalise byte for byte is refused with supported:false, never dropped.
// Values the Kotlin importer itself drops during an import (an invalid
// congestion-control name, an unknown TLS cipher) are dropped the same way,
// because that drop is the oracle's own normalisation rather than an
// approximation.
//
// Clash: OutboundFactory's Clash protocol table maps only `ssh` of these four
// (`juicity`, `naive` and `trusttunnel` have no entry there), so a Clash entry
// of the other three is refused with that reason instead of being partially
// mapped. Ssh's Clash form reads username/password/private-key/
// private-key-passphrase/host-key/host-key-algorithms, which this file mirrors
// exactly.
//
// The stored-JSON reader has three gates (profileNewMode): the JSON/SIP008
// body (import, with ParseDiag active exactly like ProfileImport), a stored
// row (export, no ParseDiag) and the profileValidate draft (validate, like
// export).
//
// trusttunnel's official deep link (`tt://?<base64url TLV payload>`) is not
// ported: a host-less tt:// link with a query is refused with that reason, so
// the caller falls back to Kotlin rather than storing a half-parsed node.
package mobile

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
)

// profileS5NewTypes is the closed set this slice owns.
var profileS5NewTypes = map[string]bool{
	"juicity": true, "naive": true, "ssh": true, "trusttunnel": true,
}

// profileS5NewDisplayType is Outbound.displayType.
func profileS5NewDisplayType(profileType string) string {
	switch profileType {
	case "juicity":
		return "Juicity"
	case "naive":
		return "Naive"
	case "ssh":
		return "SSH"
	case "trusttunnel":
		return "TrustTunnel"
	}
	return profileType
}

// profileS5NewFieldKeys is the per-type stored field allowlist: the type's own
// keys plus the flat dial fields. A key outside it is a refusal (profileExport
// falls back to Kotlin, profileValidate answers supported:false).
func profileS5NewFieldKeys(rawType string) map[string]bool {
	allowed := make(map[string]bool, len(profileNewDialKeys)+8)
	for key := range profileNewDialKeys {
		allowed[key] = true
	}
	switch rawType {
	case "juicity":
		for _, key := range []string{"uuid", "password", "tls"} {
			allowed[key] = true
		}
	case "naive":
		for _, key := range []string{"username", "password", "insecure_concurrency", "extra_headers", "udp_over_tcp", "quic", "quic_congestion_control", "tls"} {
			allowed[key] = true
		}
	case "ssh":
		for _, key := range []string{"user", "password", "private_key", "private_key_path", "private_key_passphrase", "host_key", "host_key_algorithms", "client_version"} {
			allowed[key] = true
		}
	case "trusttunnel":
		for _, key := range []string{"username", "password", "health_check", "quic", "quic_congestion_control", "custom_sni", "client_random", "tls"} {
			allowed[key] = true
		}
	}
	return allowed
}

// --- share links ------------------------------------------------------------

// profileImportS5NewOutbound dispatches a share link of one of the four types.
// `link` is the raw text (naive must escape user-info '@' before QUrl parses
// it, and trusttunnel sniffs the deep-link shape), so the raw form is passed
// alongside the already-parsed profileParsedLink for the others.
func profileImportS5NewOutbound(scheme, raw string, link profileParsedLink) (*profileImportedNode, error) {
	var (
		node *profileImportedNode
		err  error
	)
	switch scheme {
	case "juicity":
		node, err = profileImportJuicityLink(link)
	case "naive+https", "naive+quic":
		node, err = profileImportNaiveLink(scheme, raw)
	case "ssh":
		node, err = profileImportSSHLink(link)
	case "tt":
		node, err = profileImportTrustTunnelLink(raw, link)
	default:
		return nil, profileUnsupported("scheme not handled by the juicity/naive/ssh/trusttunnel importer: " + scheme)
	}
	if err != nil {
		return nil, err
	}
	if err := profileS5ImportGate(node); err != nil {
		return nil, err
	}
	return node, nil
}

// profileS5ImportGate applies the acceptance gate ProfileImport uses after a
// parse: an Error from the type's Validate refuses the profile (Juicity's UUID,
// Naive's QUIC congestion name, TrustTunnel's credentials/client_random, an Ssh
// key). It runs over the canonical stored document so a link and a JSON entry
// are judged by the same rules; warnings do not block.
func profileS5ImportGate(node *profileImportedNode) error {
	if node == nil || !profileS5NewTypes[node.Type] {
		return nil
	}
	object, ok := configDecodeJSONObject(node.JSON)
	if !ok {
		return nil
	}
	result, handled := handleProfileValidateS5New(object, node.Type)
	if !handled || result.Supported == nil || !*result.Supported {
		return nil
	}
	for _, issue := range result.Issues {
		if issue.Severity == profileSeverityError {
			if issue.Field != "" {
				return profileUnsupported(issue.Field + ": " + issue.Message)
			}
			return profileUnsupported(issue.Message)
		}
	}
	return nil
}

// profileImportJuicityLink follows Juicity.parseFromLink: the user-info is
// uuid:password (QUrl splits at the first literal ':'), TLS is forced on, the
// port defaults to 443 and an empty uuid or server refuses the profile.
func profileImportJuicityLink(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed juicity link: invalid host or port")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	uuid, password := link.UserInfoPair()
	if uuid == "" {
		return nil, profileUnsupported("malformed juicity link: no uuid in the user-info")
	}
	// Tls.parseFromLink reports an Error for security=reality without pbk,
	// which refuses the whole profile on the Kotlin path; refuse it here too.
	if strings.EqualFold(strings.TrimSpace(link.Query.Value("security")), "reality") && !link.Query.Has("pbk") {
		return nil, profileUnsupported("juicity security=reality requires pbk")
	}
	tls, _, err := profileImportTLS(link, true, false)
	if err != nil {
		return nil, err
	}
	// Juicity forces tls.enabled=true after tls.parseFromLink.
	if len(tls) == 0 {
		tls = map[string]any{"enabled": true}
	} else {
		tls["enabled"] = true
	}
	port := link.PortOrDefault(0)
	if port == 0 {
		port = 443
	}
	fields := map[string]any{}
	if uuid != "" {
		fields["uuid"] = uuid
	}
	if password != "" {
		fields["password"] = password
	}
	node := &profileStoredAdvanced{
		Type: "juicity", Name: link.Fragment, Server: link.Host, Port: port,
		Fields: fields, TLS: tls, HasTLS: true,
	}
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

// profileImportNaiveLink follows Naive.parseFromLink. The escaped link is
// parsed exactly like the Kotlin wrapper: only the TLS fields proven by naive
// are read (sni/certificate/certificate_path/fragment/ECH), and the scheme
// decides QUIC.
func profileImportNaiveLink(scheme, raw string) (*profileImportedNode, error) {
	link := profileLinkParse(profileNaiveEscapeUserInfoAts(raw))
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed naive link: invalid host or port")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	query := link.Query
	port := link.PortOrDefault(0)
	if port == 0 {
		port = 443
	}
	fields := map[string]any{}
	if link.UserName != "" {
		fields["username"] = link.UserName
	}
	if link.Password != "" {
		fields["password"] = link.Password
	}
	uot := false
	if query.Has("uot") {
		uot = profileImportTruthy(query.Value("uot"))
	}
	if uot {
		fields["udp_over_tcp"] = true
	}
	if query.Has("insecure-concurrency") {
		value := strings.TrimSpace(query.Value("insecure-concurrency"))
		// keep(): with ParseDiag active an invalid value is dropped with a
		// warning and the model default (0) stays.
		if parsed, ok := profileNewParseLong(value); ok && parsed >= 0 {
			if parsed > 2147483647 {
				parsed = 2147483647
			}
			if parsed > 0 {
				fields["insecure_concurrency"] = int(parsed)
			}
		}
	}
	if query.Has("extra-headers") {
		if pairs := profileNaiveParseExtraHeaders(query); len(pairs) > 0 {
			fields["extra_headers"] = profileNaivePairsToObject(pairs)
		}
	}
	quic := scheme == "naive+quic"
	if quic {
		fields["quic"] = true
		if query.Has("congestion_control") {
			if value := profileNaiveCongestionImport(query.Value("congestion_control")); value != "" {
				fields["quic_congestion_control"] = value
			}
		}
	}
	tls := map[string]any{"enabled": true}
	if query.Has("sni") {
		if value := query.Value("sni"); value != "" {
			tls["server_name"] = aceShareHost(value)
		}
	}
	if query.Has("tls_certificate") {
		// naive reads splitSkipEmpty(valueFully, ","), unlike Tls.parseFromLink.
		if items := profileS5SplitSkipEmpty(query.ValueFully("tls_certificate"), ","); len(items) > 0 {
			tls["certificate"] = stringListToAny(items)
		}
	}
	if query.Has("tls_certificate_path") {
		if value := query.ValueFully("tls_certificate_path"); value != "" {
			tls["certificate_path"] = value
		}
	}
	if query.Has("tls_fragment") {
		tls["fragment"] = query.Value("tls_fragment") == "true"
	}
	if ech := profileS5ECHParseQuery(query); len(ech) > 0 {
		if enabled, _ := ech["enabled"].(bool); enabled {
			tls["ech"] = profileS5ECHCanonical(ech)
		}
	}
	node := &profileStoredAdvanced{
		Type: "naive", Name: link.Fragment, Server: link.Host, Port: port,
		Fields: fields, TLS: tls, HasTLS: true,
	}
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

// profileImportSSHLink follows Ssh.parseFromLink: no default port, keys travel
// base64-encoded (`-` separates list items), the user/password come from the
// query or else the standard user-info.
func profileImportSSHLink(link profileParsedLink) (*profileImportedNode, error) {
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed ssh link: invalid host or port")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	query := link.Query
	fields := map[string]any{}
	user := ""
	if query.Has("user") {
		user = query.ValueFully("user")
	} else if link.UserName != "" {
		user = link.UserName
	}
	if user != "" {
		fields["user"] = user
	}
	password := ""
	if query.Has("password") {
		password = query.ValueFully("password")
	} else if link.Password != "" {
		password = link.Password
	}
	if password != "" {
		fields["password"] = password
	}
	if raw := query.Value("private_key"); raw != "" {
		// Base64Strict.decodeLenient ignores everything outside the alphabet;
		// the decoded bytes are read as UTF-8 text.
		if decoded := profileBase64DecodeLenient(raw, false); len(decoded) > 0 {
			fields["private_key"] = string(decoded)
		}
	}
	if query.Has("private_key_path") {
		if value := query.ValueFully("private_key_path"); value != "" {
			fields["private_key_path"] = value
		}
	}
	if query.Has("private_key_passphrase") {
		if value := query.ValueFully("private_key_passphrase"); value != "" {
			fields["private_key_passphrase"] = value
		}
	}
	if items := profileSSHLinkItems(query.Value("host_key")); len(items) > 0 {
		fields["host_key"] = stringListToAny(items)
	}
	if items := profileSSHLinkItems(query.Value("host_key_algorithms")); len(items) > 0 {
		fields["host_key_algorithms"] = stringListToAny(items)
	}
	if query.Has("client_version") {
		if value := strings.TrimSpace(query.ValueFully("client_version")); value != "" {
			fields["client_version"] = value
		}
	}
	node := &profileStoredAdvanced{
		Type: "ssh", Name: link.Fragment, Server: link.Host, Port: link.PortOrDefault(0),
		Fields: fields,
	}
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNode(node)
}

// profileImportTrustTunnelLink follows TrustTunnel.parseFromLink. A link
// without a host but with a query is the official deep link, which this slice
// does not port.
func profileImportTrustTunnelLink(raw string, link profileParsedLink) (*profileImportedNode, error) {
	if link.Host == "" && profileS5RawQuery(raw) != nil {
		return nil, profileUnsupported("trusttunnel deep links (tt://?<base64 TLV payload>) are not ported yet")
	}
	if !link.IsValid() || link.Host == "" {
		return nil, profileUnsupported("malformed trusttunnel link: invalid host or port")
	}
	if profileHasUnsupportedHostForm(link.Host) {
		return nil, profileUnsupported("host form is not byte-identical to Kotlin's normalization yet")
	}
	query := link.Query
	fields := map[string]any{}
	if link.UserName != "" {
		fields["username"] = link.UserName
	}
	if link.Password != "" {
		fields["password"] = link.Password
	}
	quic := false
	if query.Has("health_check") && query.Value("health_check") == "true" {
		fields["health_check"] = true
	}
	if query.Has("congestion_control") {
		quic = true
		if value := profileTrustTunnelCongestionImport(query.Value("congestion_control")); value != "" {
			fields["quic_congestion_control"] = value
		}
	}
	if quic {
		fields["quic"] = true
	}
	if query.Has("custom_sni") {
		if value := strings.TrimSpace(query.Value("custom_sni")); value != "" {
			fields["custom_sni"] = value
		}
	}
	if query.Has("client_random") {
		if value := strings.TrimSpace(query.Value("client_random")); value != "" {
			fields["client_random"] = value
		}
	}
	// Tls.parseFromLink reports an Error for security=reality without pbk.
	if strings.EqualFold(strings.TrimSpace(query.Value("security")), "reality") && !query.Has("pbk") {
		return nil, profileUnsupported("trusttunnel security=reality requires pbk")
	}
	tls, _, err := profileImportTLS(link, true, true)
	if err != nil {
		return nil, err
	}
	if len(tls) == 0 {
		tls = map[string]any{"enabled": true}
	} else {
		tls["enabled"] = true
	}
	port := link.PortOrDefault(0)
	if port == 0 {
		port = 443
	}
	// ParseFromLink returns false unless both credentials and the server are
	// present; the import acceptance gate turns that into a refusal.
	if username := configJSONString(fields, "username"); username == "" {
		return nil, profileUnsupported("trusttunnel link has no username")
	}
	if password := configJSONString(fields, "password"); password == "" {
		return nil, profileUnsupported("trusttunnel link has no password")
	}
	node := &profileStoredAdvanced{
		Type: "trusttunnel", Name: link.Fragment, Server: link.Host, Port: port,
		Fields: fields, TLS: tls, HasTLS: true,
	}
	profileImportAdvancedDialFields(link, node)
	return profileAdvancedNodeWithObject(node, profileS5NewObject(node))
}

// --- naive helpers ----------------------------------------------------------

// profileNaiveEscapeUserInfoAts is Naive.Companion.escapeUserInfoAts: Go's
// net/url splits user-info at the last '@', QUrl at the first, so every '@'
// left of the last one in the authority is percent-escaped first.
func profileNaiveEscapeUserInfoAts(link string) string {
	schemeEnd := strings.Index(link, "://")
	if schemeEnd < 0 {
		return link
	}
	from := schemeEnd + 3
	authEnd := len(link)
	for index := from; index < len(link); index++ {
		char := link[index]
		if char == '/' || char == '?' || char == '#' {
			authEnd = index
			break
		}
	}
	lastAt := strings.LastIndex(link[:authEnd], "@")
	if lastAt < from {
		return link
	}
	userInfo := link[from:lastAt]
	if !strings.Contains(userInfo, "@") {
		return link
	}
	return link[:from] + strings.ReplaceAll(userInfo, "@", "%40") + link[lastAt:]
}

// profileNaiveParseExtraHeaders is Naive.Companion.parseExtraHeaders: the
// form-decoded value split on newlines, each line "name: value". A line without
// a name is dropped (Kotlin warns; a warning is not a stored field and may
// quote a credential, so it is not reproduced here).
func profileNaiveParseExtraHeaders(query profileLinkQuery) []string {
	text := query.ValueFormDecoded("extra-headers")
	pairs := []string{}
	for _, rawLine := range profileS5SplitSkipEmpty(text, "\n") {
		line := rawLine
		if strings.HasSuffix(line, "\r") {
			line = line[:len(line)-1]
		}
		colon := strings.Index(line, ":")
		name := ""
		if colon > 0 {
			name = strings.TrimSpace(line[:colon])
		}
		if name == "" {
			continue
		}
		pairs = append(pairs, name, strings.TrimSpace(line[colon+1:]))
	}
	return pairs
}

// profileNaivePairsToObject is JsonValues.pairListToObject: an odd-length list
// gives an empty object, a duplicate key keeps the last value.
func profileNaivePairsToObject(pairs []string) map[string]any {
	out := map[string]any{}
	if len(pairs)%2 != 0 {
		return out
	}
	for index := 0; index < len(pairs); index += 2 {
		out[pairs[index]] = pairs[index+1]
	}
	return out
}

// profileNaivePairsFromObject is JsonValues.objectToPairList over a stored
// header object in sorted key order.
func profileNaivePairsFromObject(headers map[string]any) []string {
	keys := make([]string, 0, len(headers))
	for key := range headers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	pairs := make([]string, 0, len(keys)*2)
	for _, key := range keys {
		pairs = append(pairs, key, configJSONStringValue(headers[key]))
	}
	return pairs
}

// profileNaiveExportExtraHeaders is Naive.Companion.exportExtraHeaders:
// "name:value" lines joined with CRLF, then percent-encoded in full so a
// literal '+' cannot reach the reader (which decodes it as a space).
func profileNaiveExportExtraHeaders(pairs []string) string {
	lines := make([]string, 0, len(pairs)/2)
	for index := 0; index+1 < len(pairs); index += 2 {
		lines = append(lines, pairs[index]+":"+pairs[index+1])
	}
	return profileLinkPercentEncodeAll(strings.Join(lines, "\r\n"))
}

var profileNaiveCongestionControls = []string{"bbr", "bbr2", "cubic", "reno"}

// profileNaiveCongestionImport is the congestion_control branch of
// Naive.parseFromLink: trim then keep only a known name (Validation.oneOf).
func profileNaiveCongestionImport(raw string) string {
	value := strings.TrimSpace(raw)
	if !profileNewOneOf(value, profileNaiveCongestionControls, false) {
		return ""
	}
	return value
}

// --- ssh helpers ------------------------------------------------------------

// profileSSHLinkItems is sshLinkItems: each item is its own base64 text joined
// by '-', decoded with the standard alphabet after restoring the padding the
// exporter dropped, then trimmed. A malformed item is dropped (Kotlin warns).
func profileSSHLinkItems(raw string) []string {
	items := []string{}
	for _, item := range profileS5SplitSkipEmpty(raw, "-") {
		padding := (4 - len([]byte(item))%4) % 4
		decoded, ok := profileBase64Decode(item+strings.Repeat("=", padding), false)
		if ok && len(decoded) > 0 {
			items = append(items, strings.TrimSpace(string(decoded)))
		}
	}
	return items
}

// profileSSHJSONListable is sshListableItems: a bare string is one item, else
// JsonArray.strings() (every item through toStringValue, so a non-string item
// becomes "").
func profileSSHJSONListable(object map[string]any, key string) []string {
	switch value := object[key].(type) {
	case string:
		return []string{value}
	case []any:
		out := make([]string, 0, len(value))
		for _, item := range value {
			out = append(out, configJSONStringValue(item))
		}
		return out
	}
	return []string{}
}

// profileSSHJSONNonBlank is sshNonBlankItems: trim every item and drop the
// blanks (an older editor save stored a trailing empty item the core rejects).
func profileSSHJSONNonBlank(object map[string]any, key string) []string {
	items := profileSSHJSONListable(object, key)
	out := make([]string, 0, len(items))
	for _, item := range items {
		if trimmed := strings.TrimSpace(item); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// --- small shared helpers ---------------------------------------------------

func profileS5SplitSkipEmpty(value, separator string) []string {
	parts := strings.Split(value, separator)
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}

// profileS5RawQuery is TrustTunnel.Companion.rawQuery: the text after the first
// '?' of the hierarchical part, up to '#'; nil without a '?'.
func profileS5RawQuery(link string) *string {
	head := link
	if hash := strings.Index(link, "#"); hash >= 0 {
		head = link[:hash]
	}
	question := strings.Index(head, "?")
	if question < 0 {
		return nil
	}
	query := head[question+1:]
	return &query
}

// --- Clash -----------------------------------------------------------------

// clashSSH is Ssh.parseFromClash: username/password, the inline key and its
// passphrase, and the two trimmed key lists. Every other key is refused rather
// than ignored, so the caller falls back to Kotlin instead of storing a node
// missing an option.
func clashSSH(p clashProxy) (*profileImportedNode, error) {
	if err := clashRejectUnknownFields(p, "ssh", []string{
		"type", "name", "server", "port", "username", "password",
		"private-key", "private-key-passphrase", "host-key", "host-key-algorithms",
	}); err != nil {
		return nil, err
	}
	name, server, port, err := clashBase(p, "ssh")
	if err != nil {
		return nil, err
	}
	fields := map[string]any{}
	if user := p.String("username"); user != "" {
		fields["user"] = user
	}
	if password := p.String("password"); password != "" {
		fields["password"] = password
	}
	if key := p.String("private-key"); key != "" {
		fields["private_key"] = key
	}
	if passphrase := p.String("private-key-passphrase"); passphrase != "" {
		fields["private_key_passphrase"] = passphrase
	}
	for _, key := range []string{"host-key", "host-key-algorithms"} {
		items := []string{}
		for _, item := range p.Strings(key) {
			if trimmed := strings.TrimSpace(item); trimmed != "" {
				items = append(items, trimmed)
			}
		}
		if len(items) > 0 {
			stored := "host_key"
			if key == "host-key-algorithms" {
				stored = "host_key_algorithms"
			}
			fields[stored] = stringListToAny(items)
		}
	}
	node := &profileStoredAdvanced{
		Type: "ssh", Name: name, Server: server, Port: port, Fields: fields,
	}
	return profileAdvancedNode(node)
}

// --- stored JSON / SIP008 ---------------------------------------------------

// profileS5Parsed is the result of reading one stored document: the node, the
// fields the gate could not model (for the supported:false answer) and the
// parsed TLS block (validate needs it even when disabled: every type here is
// must-tls).
type profileS5Parsed struct {
	Node    *profileStoredAdvanced
	Unknown []string
	TLS     map[string]any
}

// profileImportStoredS5New converts a stored outbound object from a JSON/SIP008
// body into the same node the link/Clash converters emit.
func profileImportStoredS5New(object map[string]any, rawType string) (*profileImportedNode, error) {
	parsed, err := profileS5FromObject(object, rawType, profileNewImportMode)
	if err != nil {
		if refused, ok := profileNewRefusal(err); ok {
			return nil, refused
		}
		return nil, err
	}
	if len(parsed.Unknown) > 0 {
		return nil, profileUnsupported(fmt.Sprintf("stored %s field not ported yet: %s", rawType, parsed.Unknown[0]))
	}
	node := parsed.Node
	imported, err := profileAdvancedNodeWithObject(node, profileS5NewObject(node))
	if err != nil {
		return nil, err
	}
	if err := profileS5ImportGate(imported); err != nil {
		return nil, err
	}
	return imported, nil
}

// profileS5FromObject reads one stored outbound in the selected gate.
func profileS5FromObject(object map[string]any, rawType string, mode profileNewMode) (*profileS5Parsed, error) {
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
	parsed := &profileS5Parsed{}
	node := &profileStoredAdvanced{
		Type: rawType, Name: configJSONString(object, "tag"),
		Server: aceShareHost(server), Port: port, Fields: fields,
	}
	switch rawType {
	case "juicity":
		if err := profileS5JuicityFields(node, object); err != nil {
			return nil, err
		}
		if err := profileS5ReadTLS(node, object, rawType, mode, false, parsed); err != nil {
			return nil, err
		}
	case "naive":
		if err := profileS5NaiveFields(node, object, importing); err != nil {
			return nil, err
		}
		if err := profileS5ReadTLS(node, object, rawType, mode, true, parsed); err != nil {
			return nil, err
		}
		// naiveTls always writes enabled:true, so the block exists even when the
		// stored row carries no tls key.
		node.HasTLS = true
		if node.TLS == nil {
			node.TLS = map[string]any{"enabled": true}
		}
	case "ssh":
		if err := profileS5SSHFields(node, object, rawType); err != nil {
			return nil, err
		}
	case "trusttunnel":
		if err := profileS5TrustTunnelFields(node, object, importing); err != nil {
			return nil, err
		}
		if err := profileS5ReadTLS(node, object, rawType, mode, false, parsed); err != nil {
			return nil, err
		}
	}

	// Unknown keys fail the document (never a silent drop). The tests assert
	// the first offending key so a caller can locate it.
	allowed := profileS5NewFieldKeys(rawType)
	unknown := append([]string(nil), parsed.Unknown...)
	for key := range object {
		switch key {
		case "type", "tag", "server", "server_port":
			continue
		}
		if !allowed[key] {
			unknown = append(unknown, key)
		}
	}
	sort.Strings(unknown)
	parsed.Unknown = unknown
	if importing {
		// These types are endpoint-bearing: Kotlin's validator reports a missing
		// or zero port as an Error, which refuses the profile. Ssh is the
		// exception (serverPortOptional: the core dials 22).
		if rawType != "ssh" && node.Port <= 0 {
			return nil, profileUnsupported("stored " + rawType + " has no valid server_port")
		}
	}
	parsed.Node = node
	return parsed, nil
}

func profileS5JuicityFields(node *profileStoredAdvanced, object map[string]any) error {
	if value, present, err := profileNewStringField(object, "uuid", "juicity"); err != nil {
		return err
	} else if present && value != "" {
		node.Fields["uuid"] = value
	}
	if value, present, err := profileNewStringField(object, "password", "juicity"); err != nil {
		return err
	} else if present && value != "" {
		node.Fields["password"] = value
	}
	return nil
}

func profileS5NaiveFields(node *profileStoredAdvanced, object map[string]any, importing bool) error {
	fields := node.Fields
	if value, present, err := profileNewStringField(object, "username", "naive"); err != nil {
		return err
	} else if present && value != "" {
		fields["username"] = value
	}
	if value, present, err := profileNewStringField(object, "password", "naive"); err != nil {
		return err
	} else if present && value != "" {
		fields["password"] = value
	}
	if value, present := object["insecure_concurrency"]; present {
		// Naive.parseFromJson: maxOf(0, obj.int(...)); a non-number reads 0.
		number := configJSONInt(value)
		if number > 0 {
			fields["insecure_concurrency"] = number
		}
	}
	if value, present := object["extra_headers"]; present {
		block, ok := value.(map[string]any)
		if !ok {
			return profileUnsupported("stored naive extra_headers is not an object")
		}
		if len(block) > 0 {
			headers := map[string]any{}
			for key, item := range block {
				// JsonValues.toStringValue(value), with an array collapsed to its
				// first item (JsonNull when empty).
				if list, isArray := item.([]any); isArray {
					if len(list) > 0 {
						headers[key] = configJSONStringValue(list[0])
					} else {
						headers[key] = ""
					}
					continue
				}
				headers[key] = configJSONStringValue(item)
			}
			fields["extra_headers"] = headers
		}
	}
	quic := false
	if value, present, err := profileNewBoolField(object, "quic", "naive"); err != nil {
		return err
	} else if present {
		quic = value
	}
	if quic {
		fields["quic"] = true
	}
	// Naive.parseFromJson stores the congestion control whether or not QUIC is
	// on; exportToJson (and build) write it only inside the quic branch.
	if value, present, err := profileNewStringField(object, "quic_congestion_control", "naive"); err != nil {
		return err
	} else if present && quic {
		normalized := value
		if importing {
			normalized = profileNaiveCongestionImport(value)
		}
		if normalized != "" {
			fields["quic_congestion_control"] = normalized
		}
	}
	// udp_over_tcp is a bool or an object with `enabled`; either turns it on.
	if value, present := object["udp_over_tcp"]; present {
		enabled := false
		switch typed := value.(type) {
		case bool:
			enabled = typed
		case map[string]any:
			enabled = configJSONBool(typed, "enabled")
		default:
			return profileUnsupported("stored naive udp_over_tcp has unsupported value")
		}
		if enabled {
			fields["udp_over_tcp"] = true
		}
	}
	return nil
}

func profileS5SSHFields(node *profileStoredAdvanced, object map[string]any, rawType string) error {
	fields := node.Fields
	for _, key := range []string{"user", "password", "private_key_path", "private_key_passphrase", "client_version"} {
		if value, present, err := profileNewStringField(object, key, rawType); err != nil {
			return err
		} else if present && key == "private_key_path" || present && key == "private_key_passphrase" || present && key == "client_version" {
			if value != "" {
				fields[key] = value
			}
		} else if present && value != "" {
			fields[key] = value
		}
	}
	if _, present := object["private_key"]; present {
		// Ssh.parseFromJson joins the listable's items with '\n'.
		if joined := strings.Join(profileSSHJSONListable(object, "private_key"), "\n"); joined != "" {
			fields["private_key"] = joined
		}
	}
	for _, key := range []string{"host_key", "host_key_algorithms"} {
		if _, present := object[key]; !present {
			continue
		}
		if items := profileSSHJSONNonBlank(object, key); len(items) > 0 {
			fields[key] = stringListToAny(items)
		}
	}
	return nil
}

func profileS5TrustTunnelFields(node *profileStoredAdvanced, object map[string]any, importing bool) error {
	fields := node.Fields
	for _, key := range []string{"username", "password", "custom_sni", "client_random"} {
		if value, present, err := profileNewStringField(object, key, "trusttunnel"); err != nil {
			return err
		} else if present && value != "" {
			fields[key] = value
		}
	}
	if value, present, err := profileNewBoolField(object, "health_check", "trusttunnel"); err != nil {
		return err
	} else if present && value {
		fields["health_check"] = true
	}
	quic := false
	if value, present, err := profileNewBoolField(object, "quic", "trusttunnel"); err != nil {
		return err
	} else if present {
		quic = value
	}
	if quic {
		fields["quic"] = true
	}
	if value, present, err := profileNewStringField(object, "quic_congestion_control", "trusttunnel"); err != nil {
		return err
	} else if present && quic {
		// TrustTunnel.parseFromJson always canonicalises the name; an import
		// drops a name the core would run as BBR, a stored row keeps it.
		normalized := value
		if importing {
			normalized = profileTrustTunnelCongestionImport(value)
		}
		if normalized != "" {
			fields["quic_congestion_control"] = normalized
		}
	}
	return nil
}

// profileS5ReadTLS reads the optional tls block. `naive` filters the block
// through naiveTls first, because that is the only TLS surface the type models
// (an `alpn`/`insecure` key in a naive row is ignored, not refused).
func profileS5ReadTLS(node *profileStoredAdvanced, object map[string]any, rawType string, mode profileNewMode, naive bool, parsed *profileS5Parsed) error {
	value, present := object["tls"]
	if !present && !naive {
		return nil
	}
	block := map[string]any{}
	if present {
		nested, ok := value.(map[string]any)
		if !ok {
			return profileUnsupported("stored tls block is not an object")
		}
		block = nested
	}
	if naive {
		block = profileS5NaiveTLSFilter(block)
	}
	tlsParsed, err := profileS5TLSParse(block, mode == profileNewImportMode)
	if err != nil {
		return err
	}
	parsed.TLS = tlsParsed
	canonical := profileS5TLSCanonical(tlsParsed, true)
	if naive || configJSONBool(canonical, "enabled") {
		node.TLS, node.HasTLS = canonical, true
	}
	return nil
}

// profileS5NewObject is profileStoredAdvanced.object with the one type-specific
// rewrite the shared writer cannot express: TrustTunnel.exportToJson writes
// custom_sni through Hosts.toAceHost while its link keeps the stored spelling.
func profileS5NewObject(node *profileStoredAdvanced) map[string]any {
	object := node.object()
	if node.Type == "trusttunnel" {
		if value, _ := object["custom_sni"].(string); value != "" {
			object["custom_sni"] = aceShareHost(value)
		}
	}
	return object
}

// profileTrustTunnelCongestionImport is TrustTunnel.importCongestion:
// canonicalise (trim, lower-case, spaces to '_'), keep a known name, else ""
// on an import (the core would silently run an unknown name as BBR).
func profileTrustTunnelCongestionImport(raw string) string {
	value := strings.ToLower(strings.TrimSpace(raw))
	value = strings.ReplaceAll(value, " ", "_")
	for _, allowed := range profileTrustTunnelCongestionControls {
		if allowed == value {
			return value
		}
	}
	return ""
}

var profileTrustTunnelCongestionControls = []string{"", "bbr", "cubic", "reno", "bbr_standard", "bbr2", "bbr_variant"}

// --- TLS: stored-JSON reader ------------------------------------------------

// profileS5TLSParse is Tls.parseFromJson followed by the exportToJson shape the
// stored form keeps. With importing=true the ParseDiag-time drops apply (an
// invalid version/fingerprint/pin/cipher is dropped); without it the stored
// values are kept for the exporter to reproduce. A TLS key outside TLS.h is
// refused (the caller answers supported:false).
func profileS5TLSParse(raw map[string]any, importing bool) (map[string]any, error) {
	for key := range raw {
		if !profileStoredTLSKeys[key] {
			return nil, profileUnmodelled("tls field not ported yet: " + key)
		}
	}
	parsed := map[string]any{"enabled": configJSONBool(raw, "enabled")}
	if configJSONBool(raw, "disable_sni") {
		parsed["disable_sni"] = true
	}
	if serverName := configJSONString(raw, "server_name"); serverName != "" {
		parsed["server_name"] = serverName
	}
	if configJSONBool(raw, "insecure") {
		parsed["insecure"] = true
	}
	if value, present := raw["alpn"]; present {
		items := configJSONStringListValue(value)
		if importing {
			// Tls.parseFromJson re-splits the joined list through tlsLinkList.
			items = profileS5LinkList(items)
		}
		if len(items) > 0 {
			parsed["alpn"] = stringListToAny(items)
		}
	}
	for _, key := range []string{"min_version", "max_version"} {
		if value := strings.TrimSpace(configJSONString(raw, key)); value != "" {
			if !importing || profileS5TLSVersionValid(value) {
				parsed[key] = value
			}
		}
	}
	if value, present := raw["cipher_suites"]; present {
		items := configJSONStringListValue(value)
		if importing {
			items = profileS5CipherSuites(items)
		}
		if len(items) > 0 {
			parsed["cipher_suites"] = stringListToAny(items)
		}
	}
	if value, present := raw["curve_preferences"]; present {
		items := configJSONStringListValue(value)
		if importing {
			items = profileS5Curves(items)
		}
		if len(items) > 0 {
			parsed["curve_preferences"] = stringListToAny(items)
		}
	}
	for _, key := range []string{"certificate", "client_certificate", "client_key"} {
		if value, present := raw[key]; present {
			if lines := profileExportPEMList(value); len(lines) > 0 {
				parsed[key] = stringListToAny(lines)
			}
		}
	}
	for _, key := range []string{"certificate_path", "client_certificate_path", "client_key_path"} {
		if value := configJSONString(raw, key); value != "" {
			parsed[key] = value
		}
	}
	for _, key := range []string{"certificate_sha256", "certificate_public_key_sha256"} {
		if value, present := raw[key]; present {
			items := configJSONStringListValue(value)
			if importing {
				items = profileS5PinsFromHex(items)
			}
			if len(items) > 0 {
				parsed[key] = stringListToAny(items)
			}
		}
	}
	if value, present := raw["fragment"]; present {
		parsed["fragment"] = configJSONBoolValue(value)
		parsed["fragment_set"] = true
	}
	if value := strings.TrimSpace(configJSONString(raw, "fragment_fallback_delay")); value != "" {
		if !importing || profileImportValidDuration(value) {
			parsed["fragment_fallback_delay"] = value
		}
	}
	if configJSONBool(raw, "record_fragment") {
		parsed["record_fragment"] = true
	}
	if value := configJSONString(raw, "spoof"); value != "" {
		parsed["spoof"] = value
		if method := strings.TrimSpace(configJSONString(raw, "spoof_method")); method != "" {
			parsed["spoof_method"] = method
		}
	}
	if value, present := raw["spoof_enabled"]; present {
		parsed["spoof_enabled"] = configJSONBoolValue(value)
		parsed["spoof_set"] = true
	}
	if value, present := raw["tls_tricks"]; present {
		if nested, ok := value.(map[string]any); ok {
			parsed["tls_tricks"] = configJSONBool(nested, "mixedcase_sni")
			parsed["tls_tricks_set"] = true
		}
	}
	if value, present := raw["utls"]; present {
		nested, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("tls utls is not an object")
		}
		for key := range nested {
			if key != "enabled" && key != "fingerprint" {
				return nil, profileUnmodelled("tls.utls field not ported yet: " + key)
			}
		}
		utls := map[string]any{"enabled": configJSONBool(nested, "enabled")}
		if fingerprint := configJSONString(nested, "fingerprint"); fingerprint != "" {
			normalized := fingerprint
			if importing {
				normalized, _ = profileTLSFingerprint(fingerprint)
			}
			if normalized != "" {
				utls["fingerprint"] = normalized
			}
		}
		parsed["utls"] = utls
	}
	if value, present := raw["ech"]; present {
		nested, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("tls ech is not an object")
		}
		for key := range nested {
			switch key {
			case "enabled", "config", "config_path", "query_server_name", "resolver":
			default:
				return nil, profileUnmodelled("tls.ech field not ported yet: " + key)
			}
		}
		parsed["ech"] = profileS5ECHParse(nested)
	}
	if value, present := raw["reality"]; present {
		nested, ok := value.(map[string]any)
		if !ok {
			return nil, profileUnsupported("tls reality is not an object")
		}
		reality, err := profileS5RealityParse(nested, importing)
		if err != nil {
			return nil, err
		}
		parsed["reality"] = reality
		if configJSONString(reality, "public_key") != "" {
			// Tls.parseFromJson: a public key turns TLS on even when off.
			parsed["enabled"] = true
		}
	}
	return parsed, nil
}

// profileS5TLSCanonical is Tls.exportToJson over the parsed shape. `keepFragment`
// mirrors naiveTls' flag; every type except the naive filter keeps it.
func profileS5TLSCanonical(parsed map[string]any, keepFragment bool) map[string]any {
	if !configJSONBool(parsed, "enabled") {
		return map[string]any{}
	}
	tls := map[string]any{"enabled": true}
	if configJSONBool(parsed, "disable_sni") {
		tls["disable_sni"] = true
	}
	if serverName := configJSONString(parsed, "server_name"); serverName != "" {
		tls["server_name"] = aceShareHost(serverName)
	}
	if configJSONBool(parsed, "insecure") {
		tls["insecure"] = true
	}
	for _, key := range []string{"alpn", "cipher_suites", "curve_preferences", "certificate_sha256", "certificate_public_key_sha256"} {
		if items := configJSONStringListValue(parsed[key]); len(items) > 0 {
			tls[key] = stringListToAny(items)
		}
	}
	for _, key := range []string{"certificate", "client_certificate", "client_key"} {
		if items := configJSONStringListValue(parsed[key]); len(items) > 0 {
			tls[key] = stringListToAny(items)
		}
	}
	for _, key := range []string{"min_version", "max_version", "certificate_path", "client_certificate_path", "client_key_path", "fragment_fallback_delay"} {
		if value := configJSONString(parsed, key); value != "" {
			tls[key] = value
		}
	}
	if keepFragment && configJSONBool(parsed, "fragment_set") {
		tls["fragment"] = configJSONBool(parsed, "fragment")
	}
	if configJSONBool(parsed, "record_fragment") {
		tls["record_fragment"] = true
	}
	if configJSONBool(parsed, "spoof_set") {
		tls["spoof_enabled"] = configJSONBool(parsed, "spoof_enabled")
	}
	if spoof := configJSONString(parsed, "spoof"); spoof != "" {
		tls["spoof"] = spoof
		if method := configJSONString(parsed, "spoof_method"); method != "" {
			tls["spoof_method"] = method
		}
	}
	if configJSONBool(parsed, "tls_tricks_set") {
		tls["tls_tricks"] = map[string]any{"mixedcase_sni": configJSONBool(parsed, "tls_tricks")}
	}
	if ech, ok := parsed["ech"].(map[string]any); ok && configJSONBool(ech, "enabled") {
		tls["ech"] = profileS5ECHCanonical(ech)
	}
	if utls, ok := parsed["utls"].(map[string]any); ok && configJSONBool(utls, "enabled") {
		out := map[string]any{"enabled": true}
		if fingerprint := configJSONString(utls, "fingerprint"); fingerprint != "" {
			out["fingerprint"] = fingerprint
		}
		tls["utls"] = out
	}
	if reality, ok := parsed["reality"].(map[string]any); ok && configJSONBool(reality, "enabled") {
		out := map[string]any{"enabled": true}
		for _, key := range []string{"public_key", "short_id", "mldsa65_verify"} {
			if value := configJSONString(reality, key); value != "" {
				out[key] = value
			}
		}
		tls["reality"] = out
	}
	return tls
}

// profileS5NaiveTLSFilter is Naive.naiveTls: the core's naive outbound reads
// only enabled/server_name/certificate/certificate_path/ech/fragment; every
// other stored TLS option is dropped by the model itself.
func profileS5NaiveTLSFilter(raw map[string]any) map[string]any {
	filtered := map[string]any{"enabled": true}
	for _, key := range []string{"server_name", "certificate", "certificate_path", "ech", "fragment"} {
		if value, present := raw[key]; present {
			filtered[key] = value
		}
	}
	return filtered
}

// profileS5ECHParse is Ech.parseFromJson.
func profileS5ECHParse(raw map[string]any) map[string]any {
	ech := map[string]any{"enabled": configJSONBool(raw, "enabled")}
	if value, present := raw["config"]; present {
		if config := profileExportECHConfig(value); len(config) > 0 {
			ech["config"] = stringListToAny(config)
		}
	}
	if value := configJSONString(raw, "config_path"); value != "" {
		ech["config_path"] = value
	}
	if value := configJSONString(raw, "query_server_name"); value != "" {
		ech["query_server_name"] = value
	}
	if value := configJSONString(raw, "resolver"); value != "" {
		ech["resolver"] = value
	}
	return ech
}

// profileS5ECHParseQuery is Ech.parseFromLink (the naive link path).
func profileS5ECHParseQuery(query profileLinkQuery) map[string]any {
	ech := map[string]any{}
	if query.Has("ech") {
		value := strings.TrimSpace(query.ValueFully("ech"))
		enabled := value != "" && value != "0" && value != "false"
		if enabled {
			if value != "1" && value != "true" {
				if strings.Contains(value, "://") || strings.Contains(value, ".") {
					name, resolver := profileECHTarget(value)
					if name != "" {
						ech["query_server_name"] = name
					}
					if resolver != "" {
						ech["resolver"] = resolver
					}
				} else if config := profileECHConfig([]string{value}); config != nil {
					ech["config"] = config
				}
			}
			ech["enabled"] = true
		}
	}
	if query.Has("ech_enabled") {
		ech["enabled"] = query.Value("ech_enabled") == "true"
	}
	if query.Has("ech_config") {
		if config := profileECHConfig(qtSplitSkipEmpty(query.ValueFully("ech_config"), ",")); config != nil {
			ech["config"] = config
		}
	}
	if query.Has("ech_config_path") {
		ech["config_path"] = query.Value("ech_config_path")
	}
	if query.Has("ech_server_name") {
		if name := query.Value("ech_server_name"); name != "" {
			ech["query_server_name"] = name
		}
	}
	return ech
}

// profileS5ECHCanonical is Ech.exportToJson.
func profileS5ECHCanonical(ech map[string]any) map[string]any {
	out := map[string]any{"enabled": true}
	if config := configJSONStringListValue(ech["config"]); len(config) > 0 {
		out["config"] = stringListToAny(config)
	}
	if value := configJSONString(ech, "config_path"); value != "" {
		out["config_path"] = value
	}
	if name := configJSONString(ech, "query_server_name"); name != "" {
		out["query_server_name"] = aceShareHost(name)
	}
	if resolver := configJSONString(ech, "resolver"); resolver != "" {
		out["resolver"] = resolver
	}
	return out
}

// profileS5RealityParse is Reality.parseFromJson (plus Xray's ML-DSA-65 key).
func profileS5RealityParse(raw map[string]any, importing bool) (map[string]any, error) {
	for key := range raw {
		switch key {
		case "enabled", "public_key", "short_id", "mldsa65_verify":
		default:
			return nil, profileUnmodelled("tls.reality field not ported yet: " + key)
		}
	}
	reality := map[string]any{"enabled": configJSONBool(raw, "enabled")}
	publicKey := strings.TrimSpace(configJSONString(raw, "public_key"))
	if importing {
		publicKey = profileS5RealityPublicKey(publicKey)
	}
	if publicKey != "" {
		reality["public_key"] = publicKey
	}
	if shortID := strings.TrimSpace(configJSONString(raw, "short_id")); shortID != "" {
		reality["short_id"] = shortID
	}
	if verify := strings.TrimSpace(configJSONString(raw, "mldsa65_verify")); verify != "" {
		if importing && !profileValidMLDSA(verify) {
			// importMldsa65Verify reports an Error, which refuses the profile.
			return nil, profileUnsupported("tls.reality.mldsa65_verify is not a valid ML-DSA-65 key")
		}
		reality["mldsa65_verify"] = verify
	}
	return reality, nil
}

// --- TLS helpers ------------------------------------------------------------

var profileS5TLSVersions = []string{"1.0", "1.1", "1.2", "1.3"}

func profileS5TLSVersionValid(value string) bool {
	return profileNewOneOf(value, profileS5TLSVersions, false)
}

// profileS5LinkList is tlsLinkList: join-then-split by ',', trimmed, empty
// items dropped.
func profileS5LinkList(items []string) []string {
	out := []string{}
	for _, part := range strings.Split(strings.Join(items, ","), ",") {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

// profileS5CipherSuites is importTlsCipherSuites: only the secure names
// survive; insecure and unknown entries are dropped with a warning.
func profileS5CipherSuites(items []string) []string {
	out := []string{}
	for _, item := range items {
		if profileSecureCipherSuites[item] {
			out = append(out, item)
		}
	}
	return out
}

// profileS5Curves is tlsKnownCurves: trim, keep a known spelling.
func profileS5Curves(items []string) []string {
	out := []string{}
	for _, item := range items {
		trimmed := strings.TrimSpace(item)
		if trimmed == "" {
			continue
		}
		if profileKnownTLSCurves[strings.ToLower(trimmed)] {
			out = append(out, trimmed)
		}
	}
	return out
}

// profileS5PinsFromHex is certificatePinsFromHex: a lone 64-hex value converts
// to the base64 form sing-box takes; everything else is kept trimmed.
func profileS5PinsFromHex(items []string) []string {
	out := []string{}
	for _, item := range items {
		if strings.TrimSpace(item) == "" {
			continue
		}
		converted := profileS5PinsFromPCS(item)
		if len(converted) == 1 && !strings.Contains(item, ",") {
			out = append(out, converted[0])
		} else {
			out = append(out, strings.TrimSpace(item))
		}
	}
	return out
}

// profileS5PinsFromPCS is certificateSha256FromPcs: comma-separated 64-hex
// values (colons allowed) become standard base64.
func profileS5PinsFromPCS(text string) []string {
	out := []string{}
	for _, item := range qtSplitSkipEmpty(text, ",") {
		trimmed := strings.TrimSpace(item)
		if trimmed == "" {
			continue
		}
		hexText := strings.ReplaceAll(trimmed, ":", "")
		if len(hexText) != 64 || !profileS5IsHex(hexText) {
			continue
		}
		raw := make([]byte, 32)
		for index := 0; index < 32; index++ {
			value, err := strconv.ParseUint(hexText[index*2:index*2+2], 16, 8)
			if err != nil {
				return nil
			}
			raw[index] = byte(value)
		}
		out = append(out, profileBase64Encode(raw, false, true))
	}
	return out
}

func profileS5IsHex(text string) bool {
	for index := 0; index < len(text); index++ {
		char := text[index]
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f') || (char >= 'A' && char <= 'F')) {
			return false
		}
	}
	return true
}

// profileS5RealityPublicKey is importRealityPublicKey: the trailing '=' that
// sing-box and Xray's RawURLEncoding refuse is removed only when the unpadded
// key is a valid 32-byte base64url value.
func profileS5RealityPublicKey(key string) string {
	if !strings.HasSuffix(key, "=") {
		return key
	}
	unpadded := strings.TrimRight(key, "=")
	if decoded, ok := profileBase64Decode(unpadded, true); ok && len(decoded) == 32 {
		return unpadded
	}
	return key
}
