// Stored-form (NodeRow.outbound_json) normalisation for
// profileNormalize format:"stored".
//
// The kernel path in profile_codec_actions.go normalises through option.Outbound,
// which only understands sing-box option objects. Throne stores a different,
// smaller document (type plus the type's fields, the flat dial fields and the
// shared TLS/transport/mux/QUIC blocks), and Kotlin's model is the canonical
// writer for it. This file rebuilds that document through the same stored-form
// field tables the exporters and the stored validator use, so the editor can
// canonicalise a stored row without a second protocol model:
//
//	{"json":"…","format":"stored"} -> {"supported":true,"json":"<compact>"}
//	                                  {"supported":false,"reason":"…"} (caller falls back)
//
// The canonical bytes are Kotlin's exportToJson after parseFromJson: every
// empty/default value the model drops stays dropped, arrays keep their model
// shape, and the key order is MarshalCanonicalJSON's (UTF-16 sorted, the same
// bytes JsonWriter.toCompact writes for these ASCII keys).
//
// A type or field this slice does not model answers supported:false with a
// reason instead of a half-canonical document. openvpn, openvpn-client and
// openconnect normalise through the S5 endpoint exporter: the stored-row gate
// (no ParseDiag, so no import-time drops) plus the model's exportToJson, which
// already carries the servers/certificates/routes/pull-filter tables. A field
// outside those tables is a refusal, never a silent drop.
package mobile

import (
	"errors"
	"fmt"
	"math"
	"sort"
	"strings"
)

// profileStoredNormalizeResult is the format:"stored" reply. Supported is
// always present on this path; a refusal carries a reason and no json, so the
// caller can fall back to the Kotlin exporter without a half-written node.
type profileStoredNormalizeResult struct {
	Supported bool   `json:"supported"`
	JSON      string `json:"json,omitempty"`
	Reason    string `json:"reason,omitempty"`
}

type profileStoredNormalizer func(object map[string]any) (canonical string, reason string, err error)

// profileStoredNormalizers is the closed set this slice normalises. It is the
// same type set profileNewOutbound can template, minus the refusals below.
var profileStoredNormalizers = map[string]profileStoredNormalizer{
	"direct":       profileStoredNormalizeSimple,
	"http":         profileStoredNormalizeSimple,
	"socks":        profileStoredNormalizeSimple,
	"shadowsocks":  profileStoredNormalizeSimple,
	"vmess":        profileStoredNormalizeAdvanced,
	"vless":        profileStoredNormalizeAdvanced,
	"trojan":       profileStoredNormalizeAdvanced,
	"hysteria":     profileStoredNormalizeAdvanced,
	"hysteria2":    profileStoredNormalizeAdvanced,
	"tuic":         profileStoredNormalizeTuic,
	"juicity":      profileStoredNormalizeJuicity,
	"anytls":       profileStoredNormalizeAnyTLS,
	"shadowtls":    profileStoredNormalizeShadowTLS,
	"snell":        profileStoredNormalizeSnell,
	"mieru":        profileStoredNormalizeMieru,
	"trusttunnel":  profileStoredNormalizeTrustTunnel,
	"ssh":          profileStoredNormalizeSSH,
	"naive":        profileStoredNormalizeNaive,
	"custom":       profileStoredNormalizeCustom,
	"chain":        profileStoredNormalizeChain,
	"autoselector": profileStoredNormalizeAutoSelector,
	// The two sing-box endpoints share profile_export_wg_masque.go's model.
	"wireguard": profileStoredNormalizeWireGuard,
	"masque":    profileStoredNormalizeMasque,
	// The two kernel endpoints share profile_vpn_actions.go's exporter.
	"openvpn":        profileStoredNormalizeVpn,
	"openvpn-client": profileStoredNormalizeVpn,
	"openconnect":    profileStoredNormalizeVpn,
}

// handleProfileNormalizeStored canonicalises one stored document. Malformed
// JSON and a missing type are action errors (the document cannot be read); a
// type or field outside this slice is a successful supported:false answer.
func handleProfileNormalizeStored(document string) (any, error) {
	if strings.TrimSpace(document) == "" {
		return nil, errors.New("profile.normalize: the stored document is empty")
	}
	object, ok := configDecodeJSONObject(document)
	if !ok {
		return nil, errors.New("profile.normalize: the stored document is not a JSON object")
	}
	rawType := strings.TrimSpace(configJSONString(object, "type"))
	if rawType == "" {
		return nil, errors.New(`profile.normalize: the stored document has no "type" field`)
	}
	if normalizer, known := profileStoredNormalizers[rawType]; known {
		canonical, reason, err := normalizer(object)
		if err != nil {
			return nil, fmt.Errorf("profile.normalize: %w", err)
		}
		if reason != "" {
			return profileStoredNormalizeResult{Supported: false, Reason: reason}, nil
		}
		return profileStoredNormalizeResult{Supported: true, JSON: canonical}, nil
	}
	return profileStoredNormalizeResult{
		Supported: false,
		Reason: fmt.Sprintf("stored type %q is not supported by the Go normalizer",
			rawType),
	}, nil
}

// --- shared helpers --------------------------------------------------------

var profileStoredNormalizeBaseKeys = map[string]bool{
	"type": true, "tag": true, "server": true, "server_port": true,
	"reuse_addr": true, "connect_timeout": true, "tcp_fast_open": true,
	"tcp_multi_path": true, "udp_fragment": true, "bind_interface": true,
	"inet4_bind_address": true, "inet6_bind_address": true,
}

// profileStoredNormalizeAllowed builds a key set from the shared base keys plus
// the type's own fields.
func profileStoredNormalizeAllowed(extra ...string) map[string]bool {
	allowed := make(map[string]bool, len(profileStoredNormalizeBaseKeys)+len(extra))
	for key := range profileStoredNormalizeBaseKeys {
		allowed[key] = true
	}
	for _, key := range extra {
		allowed[key] = true
	}
	return allowed
}

// profileStoredNormalizeAllowedMaps merges one of the existing stored field
// tables into a base key set.
func profileStoredNormalizeAllowedMaps(extra map[string]bool) map[string]bool {
	allowed := profileStoredNormalizeAllowed()
	for key := range extra {
		allowed[key] = true
	}
	return allowed
}

// profileStoredNormalizeCheckKeys refuses a document carrying a key this slice
// does not model. The first unknown key in sorted order is named, so the reply
// is deterministic.
func profileStoredNormalizeCheckKeys(object map[string]any, allowed map[string]bool, rawType string) string {
	unknown := make([]string, 0)
	for key := range object {
		if !allowed[key] {
			unknown = append(unknown, key)
		}
	}
	if len(unknown) == 0 {
		return ""
	}
	sort.Strings(unknown)
	return fmt.Sprintf("stored %s field not ported yet: %s", rawType, unknown[0])
}

// profileStoredNormalizeDialFields is DialFields.exportToJson after
// DialFields.parseFromJson: booleans as given, the duration and bind addresses
// trimmed. (An import, not a stored load, drops invalid values.)
func profileStoredNormalizeDialFields(object map[string]any) map[string]any {
	dial, _ := profileExportDialFields(object)
	return dial
}

// profileStoredNormalizeBase is Outbound.baseExportToJson for a type with a
// server: type, tag, the ACE server, the port when positive and the dial fields.
func profileStoredNormalizeBase(object map[string]any, rawType string) map[string]any {
	out := map[string]any{"type": rawType}
	if tag := configJSONString(object, "tag"); tag != "" {
		out["tag"] = tag
	}
	if server := configJSONString(object, "server"); server != "" {
		out["server"] = configToACEHost(server)
	}
	if port := configJSONInt(object["server_port"]); port > 0 {
		out["server_port"] = port
	}
	for key, value := range profileStoredNormalizeDialFields(object) {
		out[key] = value
	}
	return out
}

func profileStoredNormalizeEncode(object map[string]any) (string, string, error) {
	encoded, err := MarshalCanonicalJSON(object)
	if err != nil {
		return "", "", err
	}
	return string(encoded), "", nil
}

// profileStoredNormalizeRefuse carries a profileExport/protected refusal out as
// a supported:false reason; any other error is a real action failure.
func profileStoredNormalizeRefuse(err error, fallback error) (string, string, error) {
	var refused profileImportUnsupported
	if errors.As(err, &refused) {
		return "", refused.Reason, nil
	}
	return "", "", fallback
}

func profileStoredNormalizeClone(object map[string]any) map[string]any {
	copied := make(map[string]any, len(object))
	for key, value := range object {
		copied[key] = value
	}
	return copied
}

// profileStoredNormalizeStringItems is JsonArray.strings(): array items read as
// strings (non-strings become ""), a bare string is one item.
func profileStoredNormalizeStringItems(value any) []string {
	switch typed := value.(type) {
	case string:
		return []string{typed}
	case []any:
		out := make([]string, 0, len(typed))
		for _, item := range typed {
			if text, ok := item.(string); ok {
				out = append(out, text)
			} else {
				out = append(out, "")
			}
		}
		return out
	}
	return []string{}
}

// profileStoredNormalizeTrimmedItems is QtStrings.splitSkipEmpty(text, sep) with
// each item trimmed: the Mieru server_ports / Hysteria ports shape.
func profileStoredNormalizeTrimmedItems(text, separator string) []string {
	out := []string{}
	for _, part := range strings.Split(text, separator) {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}

func profileStoredNormalizeStringsAny(items []string) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		out = append(out, item)
	}
	return out
}

// profileStoredNormalizeVariantInt is JsonValues.variantToInt: QVariant's
// 64-bit conversion (strings parse, booleans count, doubles round half away
// from zero) narrowed to int without a range check.
func profileStoredNormalizeVariantInt(value any) int {
	var long int64
	switch typed := value.(type) {
	case bool:
		if typed {
			long = 1
		}
	case string:
		long = configQtToLong(typed)
	case int64:
		long = typed
	case float64:
		long = int64(math.Round(typed))
	case int:
		long = int64(typed)
	default:
		long = 0
	}
	// QVariant::toInt narrows to 32 bits without a range check.
	return int(int32(long))
}

// profileStoredNormalizeCanonicalCongestion is Tuic/TrustTunnel
// canonicalCongestion.
func profileStoredNormalizeCanonicalCongestion(value string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(value)), " ", "_")
}

// --- simple types ----------------------------------------------------------

var profileStoredNormalizeSimpleExtra = map[string][]string{
	"direct":      nil,
	"http":        {"username", "password", "path", "headers", "tls"},
	"socks":       {"username", "password", "version", "uot", "udp_over_tcp"},
	"shadowsocks": {"method", "password", "plugin", "plugin_opts", "udp_over_tcp", "multiplex"},
}

// profileStoredNormalizeSimple canonicalises direct/http/socks/shadowsocks. It
// reads the fields directly instead of calling profileStoredSimpleFromObject:
// that exporter validates the server and refuses http TLS / shadowsocks
// multiplex, while the stored load (Outbound.parseFromJson) accepts them and
// only normalises the values it models.
func profileStoredNormalizeSimple(object map[string]any) (string, string, error) {
	rawType := configJSONString(object, "type")
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed(profileStoredNormalizeSimpleExtra[rawType]...), rawType); reason != "" {
		return "", reason, nil
	}
	outbound := &profileStoredSimple{Type: rawType}
	if tag := configJSONString(object, "tag"); tag != "" {
		outbound.Name = tag
	}
	if rawType != "direct" {
		if server := configJSONString(object, "server"); server != "" {
			outbound.Server = configToACEHost(server)
		}
		outbound.Port = configJSONInt(object["server_port"])
	}
	outbound.ReuseAddr = configJSONBool(object, "reuse_addr")
	outbound.ConnectTimeout = strings.TrimSpace(configJSONString(object, "connect_timeout"))
	outbound.TCPFastOpen = configJSONBool(object, "tcp_fast_open")
	outbound.TCPMultiPath = configJSONBool(object, "tcp_multi_path")
	outbound.UDPFragment = configJSONBool(object, "udp_fragment")
	outbound.BindInterface = configJSONString(object, "bind_interface")
	outbound.Inet4Bind = strings.TrimSpace(configJSONString(object, "inet4_bind_address"))
	outbound.Inet6Bind = strings.TrimSpace(configJSONString(object, "inet6_bind_address"))
	switch rawType {
	case "http":
		outbound.Username = configJSONString(object, "username")
		outbound.Password = configJSONString(object, "password")
		outbound.Path = configJSONString(object, "path")
		if headers, present := object["headers"]; present {
			if block, ok := headers.(map[string]any); ok {
				outbound.Headers = make(map[string]string, len(block))
				for key := range block {
					// Http.parseFromJson reads every value with JsonObject.string:
					// a non-string becomes "".
					outbound.Headers[key] = configJSONString(block, key)
				}
			}
		}
		if value, present := object["tls"]; present {
			block, err := profileExportTLS(value, rawType)
			if err != nil {
				return profileStoredNormalizeRefuse(err, err)
			}
			if len(block) > 0 {
				outbound.TLS = block
			}
		}
	case "socks":
		outbound.Username = configJSONString(object, "username")
		outbound.Password = configJSONString(object, "password")
		outbound.Socks4a, outbound.Socks4 = profileStoredSocksVersion(object["version"])
		outbound.UOT = profileStoredUOT(object["uot"]) || profileStoredUOT(object["udp_over_tcp"])
	case "shadowsocks":
		outbound.Method = configJSONString(object, "method")
		outbound.Password = configJSONString(object, "password")
		outbound.Plugin = configJSONString(object, "plugin")
		outbound.PluginOpts = configJSONString(object, "plugin_opts")
		outbound.UOT = profileStoredUOT(object["udp_over_tcp"])
		if value, present := object["multiplex"]; present {
			block, err := profileExportMultiplex(value)
			if err != nil {
				return profileStoredNormalizeRefuse(err, err)
			}
			if len(block) > 0 {
				outbound.Multiplex = block
			}
		}
	}
	encoded, err := profileStoredSimpleJSON(outbound)
	if err != nil {
		return "", "", err
	}
	return encoded, "", nil
}

// --- advanced types --------------------------------------------------------

// profileStoredNormalizeAdvanced canonicalises vmess/vless/trojan/hysteria/
// hysteria2 through the S5e exporter, which already carries the full stored
// field tables for these five. The model defaults the exporter requires are
// filled in first: Vmess/Vless always export packet_encoding (the model default
// is "xudp") and Vless always exports encryption ("none").
func profileStoredNormalizeAdvanced(object map[string]any) (string, string, error) {
	rawType := configJSONString(object, "type")
	working := object
	switch rawType {
	case "vmess":
		copied := profileStoredNormalizeClone(object)
		if _, present := copied["packet_encoding"]; !present {
			copied["packet_encoding"] = "xudp"
		}
		// Vmess.parseFromJson reads the kebab-case aliases after the snake-case
		// keys, so the alias wins when both are present.
		if value, present := copied["alter-id"]; present {
			copied["alter_id"] = configJSONInt(value)
			delete(copied, "alter-id")
		}
		if value, present := copied["global-padding"]; present {
			copied["global_padding"] = configJSONBoolValue(value)
			delete(copied, "global-padding")
		}
		working = copied
	case "vless":
		copied := profileStoredNormalizeClone(object)
		encryption := strings.TrimSpace(configJSONString(object, "encryption"))
		if encryption == "" || strings.EqualFold(encryption, "none") {
			copied["encryption"] = "none"
		} else {
			copied["encryption"] = encryption
		}
		if _, present := copied["packet_encoding"]; !present {
			copied["packet_encoding"] = "xudp"
		}
		working = copied
	}
	node, err := profileExportAdvancedFromObject(rawType, working)
	if err != nil {
		return profileStoredNormalizeRefuse(err, err)
	}
	encoded, err := node.json()
	if err != nil {
		return "", "", err
	}
	return encoded, "", nil
}

// --- QUIC types ------------------------------------------------------------

func profileStoredNormalizeTuic(object map[string]any) (string, string, error) {
	allowed := profileStoredNormalizeAllowedMaps(profileStoredTuicFields)
	allowed["tls"] = true
	if reason := profileStoredNormalizeCheckKeys(object, allowed, "tuic"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "tuic")
	if uuid := configJSONString(object, "uuid"); uuid != "" {
		out["uuid"] = uuid
	}
	if password := configJSONString(object, "password"); password != "" {
		out["password"] = password
	}
	udpOverStream := configJSONBool(object, "udp_over_stream")
	if congestion := profileStoredNormalizeCanonicalCongestion(configJSONString(object, "congestion_control")); congestion != "" {
		out["congestion_control"] = congestion
	}
	// Tuic.exportToJson: udp_relay_mode only without udp_over_stream, and the
	// mode itself canonicalises to native/quic or "".
	mode := strings.ToLower(strings.TrimSpace(configJSONString(object, "udp_relay_mode")))
	if mode != "native" && mode != "quic" {
		mode = ""
	}
	if mode != "" && !udpOverStream {
		out["udp_relay_mode"] = mode
	}
	if udpOverStream {
		out["udp_over_stream"] = true
	}
	if configJSONBool(object, "zero_rtt_handshake") {
		out["zero_rtt_handshake"] = true
	}
	if heartbeat := strings.TrimSpace(configJSONString(object, "heartbeat")); heartbeat != "" {
		out["heartbeat"] = heartbeat
	}
	if value, present := object["tls"]; present {
		block, err := profileExportTLS(value, "tuic")
		if err != nil {
			return profileStoredNormalizeRefuse(err, err)
		}
		if len(block) > 0 {
			out["tls"] = block
		}
	}
	quic, err := profileExportQUIC(object)
	if err != nil {
		return profileStoredNormalizeRefuse(err, err)
	}
	for key, value := range quic {
		out[key] = value
	}
	return profileStoredNormalizeEncode(out)
}

func profileStoredNormalizeJuicity(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("uuid", "password", "tls"), "juicity"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "juicity")
	if uuid := configJSONString(object, "uuid"); uuid != "" {
		out["uuid"] = uuid
	}
	if password := configJSONString(object, "password"); password != "" {
		out["password"] = password
	}
	if value, present := object["tls"]; present {
		block, err := profileExportTLS(value, "juicity")
		if err != nil {
			return profileStoredNormalizeRefuse(err, err)
		}
		if len(block) > 0 {
			out["tls"] = block
		}
	}
	return profileStoredNormalizeEncode(out)
}

func profileStoredNormalizeAnyTLS(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("password", "idle_session_check_interval",
			"idle_session_timeout", "min_idle_session", "tls"), "anytls"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "anytls")
	// AnyTls's class defaults are "30s"/"30s"/5; parseFromJson only overwrites
	// them when the stored key is present, and exportToJson always writes the
	// interval/timeout (when non-empty) and the count (when positive).
	interval := "30s"
	if value, present := object["idle_session_check_interval"]; present {
		interval = configJSONStringValue(value)
	}
	timeout := "30s"
	if value, present := object["idle_session_timeout"]; present {
		timeout = configJSONStringValue(value)
	}
	minimum := 5
	if value, present := object["min_idle_session"]; present {
		minimum = configJSONInt(value)
	}
	if password := configJSONString(object, "password"); password != "" {
		out["password"] = password
	}
	if interval != "" {
		out["idle_session_check_interval"] = interval
	}
	if timeout != "" {
		out["idle_session_timeout"] = timeout
	}
	if minimum > 0 {
		out["min_idle_session"] = minimum
	}
	// anyTLS.cpp:77-88 always writes the TLS block, even disabled ({}).
	out["tls"] = map[string]any{}
	if value, present := object["tls"]; present {
		block, err := profileExportTLS(value, "anytls")
		if err != nil {
			return profileStoredNormalizeRefuse(err, err)
		}
		out["tls"] = block
	}
	return profileStoredNormalizeEncode(out)
}

// --- single-block types ----------------------------------------------------

func profileStoredNormalizeShadowTLS(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("version", "password", "tls"), "shadowtls"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "shadowtls")
	version := 1
	if value, present := object["version"]; present {
		version = profileStoredNormalizeVariantInt(value)
	}
	out["version"] = version
	if version > 1 {
		if password := configJSONString(object, "password"); password != "" {
			out["password"] = password
		}
	}
	if value, present := object["tls"]; present {
		block, err := profileExportTLS(value, "shadowtls")
		if err != nil {
			return profileStoredNormalizeRefuse(err, err)
		}
		if len(block) > 0 {
			out["tls"] = block
		}
	}
	return profileStoredNormalizeEncode(out)
}

func profileStoredNormalizeSnell(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("version", "psk", "userkey", "reuse", "network",
			"obfs_mode", "obfs_host", "mode"), "snell"); reason != "" {
		return "", reason, nil
	}
	version := 4
	if value, present := object["version"]; present {
		version = configJSONInt(value)
	}
	if version != 4 && version != 6 {
		return "", fmt.Sprintf("stored snell version must be 4 or 6, not %d", version), nil
	}
	out := profileStoredNormalizeBase(object, "snell")
	out["version"] = version
	if psk := configJSONString(object, "psk"); psk != "" {
		out["psk"] = psk
	}
	if userkey := configJSONString(object, "userkey"); userkey != "" {
		out["userkey"] = userkey
	}
	if configJSONBool(object, "reuse") {
		out["reuse"] = true
	}
	// Snell.parseFromJson: an array network reads as comma-joined strings; the
	// other form is the stored text itself.
	network := configJSONString(object, "network")
	if value, present := object["network"]; present {
		if _, isArray := value.([]any); isArray {
			network = strings.Join(profileStoredNormalizeStringItems(value), ",")
		}
	}
	if network != "" {
		out["network"] = network
	}
	if version == 6 {
		if mode := configJSONString(object, "mode"); mode != "" {
			out["mode"] = mode
		}
	} else {
		if mode := configJSONString(object, "obfs_mode"); mode != "" {
			out["obfs_mode"] = mode
		}
		if host := configJSONString(object, "obfs_host"); host != "" {
			out["obfs_host"] = host
		}
	}
	return profileStoredNormalizeEncode(out)
}

func profileStoredNormalizeMieru(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("transport", "username", "password",
			"multiplexing", "traffic_pattern", "server_ports"), "mieru"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "mieru")
	transport := configJSONString(object, "transport")
	if transport == "" {
		transport = "TCP"
	}
	out["transport"] = transport
	if username := configJSONString(object, "username"); username != "" {
		out["username"] = username
	}
	if password := configJSONString(object, "password"); password != "" {
		out["password"] = password
	}
	if multiplexing := configJSONString(object, "multiplexing"); multiplexing != "" {
		out["multiplexing"] = multiplexing
	}
	if pattern := configJSONString(object, "traffic_pattern"); pattern != "" {
		out["traffic_pattern"] = pattern
	}
	// Mieru.parseFromJson: a bare string is one range, an array is comma-joined
	// with each item trimmed; exportToJson splits on ',' and trims again.
	ports := ""
	if value, present := object["server_ports"]; present {
		if _, isString := value.(string); isString {
			ports = strings.TrimSpace(value.(string))
		} else {
			items := profileStoredNormalizeStringItems(value)
			for index := range items {
				items[index] = strings.TrimSpace(items[index])
			}
			ports = strings.Join(items, ",")
		}
	}
	if ranges := profileStoredNormalizeTrimmedItems(ports, ","); len(ranges) > 0 {
		out["server_ports"] = profileStoredNormalizeStringsAny(ranges)
	}
	return profileStoredNormalizeEncode(out)
}

func profileStoredNormalizeTrustTunnel(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("username", "password", "health_check", "quic",
			"quic_congestion_control", "custom_sni", "client_random", "tls"), "trusttunnel"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "trusttunnel")
	if username := configJSONString(object, "username"); username != "" {
		out["username"] = username
	}
	if password := configJSONString(object, "password"); password != "" {
		out["password"] = password
	}
	if configJSONBool(object, "health_check") {
		out["health_check"] = true
	}
	quic := configJSONBool(object, "quic")
	if quic {
		out["quic"] = true
		congestion := profileStoredNormalizeCanonicalCongestion(configJSONString(object, "quic_congestion_control"))
		if congestion != "" {
			out["quic_congestion_control"] = congestion
		}
	}
	if sni := configJSONString(object, "custom_sni"); sni != "" {
		out["custom_sni"] = configToACEHost(sni)
	}
	if clientRandom := configJSONString(object, "client_random"); clientRandom != "" {
		out["client_random"] = clientRandom
	}
	if value, present := object["tls"]; present {
		block, err := profileExportTLS(value, "trusttunnel")
		if err != nil {
			return profileStoredNormalizeRefuse(err, err)
		}
		if len(block) > 0 {
			out["tls"] = block
		}
	}
	return profileStoredNormalizeEncode(out)
}

func profileStoredNormalizeSSH(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("user", "password", "private_key",
			"private_key_path", "private_key_passphrase", "host_key",
			"host_key_algorithms", "client_version"), "ssh"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "ssh")
	if user := configJSONString(object, "user"); user != "" {
		out["user"] = user
	}
	if password := configJSONString(object, "password"); password != "" {
		out["password"] = password
	}
	// Ssh.parseFromJson: private_key is a listable that joins with newlines; the
	// other two lists drop blank items.
	if value, present := object["private_key"]; present {
		if privateKey := strings.Join(profileStoredNormalizeStringItems(value), "\n"); privateKey != "" {
			out["private_key"] = privateKey
		}
	}
	if path := configJSONString(object, "private_key_path"); path != "" {
		out["private_key_path"] = path
	}
	if passphrase := configJSONString(object, "private_key_passphrase"); passphrase != "" {
		out["private_key_passphrase"] = passphrase
	}
	for _, key := range []string{"host_key", "host_key_algorithms"} {
		value, present := object[key]
		if !present {
			continue
		}
		items := profileStoredNormalizeStringItems(value)
		kept := make([]string, 0, len(items))
		for _, item := range items {
			if trimmed := strings.TrimSpace(item); trimmed != "" {
				kept = append(kept, trimmed)
			}
		}
		if len(kept) > 0 {
			out[key] = profileStoredNormalizeStringsAny(kept)
		}
	}
	if clientVersion := configJSONString(object, "client_version"); clientVersion != "" {
		out["client_version"] = clientVersion
	}
	return profileStoredNormalizeEncode(out)
}

func profileStoredNormalizeNaive(object map[string]any) (string, string, error) {
	if reason := profileStoredNormalizeCheckKeys(object,
		profileStoredNormalizeAllowed("username", "password", "insecure_concurrency",
			"extra_headers", "udp_over_tcp", "quic", "quic_congestion_control", "tls"), "naive"); reason != "" {
		return "", reason, nil
	}
	out := profileStoredNormalizeBase(object, "naive")
	if username := configJSONString(object, "username"); username != "" {
		out["username"] = username
	}
	if password := configJSONString(object, "password"); password != "" {
		out["password"] = password
	}
	if concurrency := configJSONInt(object["insecure_concurrency"]); concurrency > 0 {
		out["insecure_concurrency"] = concurrency
	}
	// Naive.parseFromJson turns the header object into sorted pairs and reads
	// every value as a string (an array keeps its first item; anything else is
	// "").
	if headers, present := object["extra_headers"]; present {
		if block, ok := headers.(map[string]any); ok && len(block) > 0 {
			normalized := make(map[string]any, len(block))
			for key, value := range block {
				text := ""
				if list, isArray := value.([]any); isArray {
					if len(list) > 0 {
						text = configJSONStringValue(list[0])
					}
				} else {
					text = configJSONStringValue(value)
				}
				normalized[key] = text
			}
			out["extra_headers"] = normalized
		}
	}
	if profileStoredUOT(object["udp_over_tcp"]) {
		out["udp_over_tcp"] = true
	}
	if configJSONBool(object, "quic") {
		out["quic"] = true
		if congestion := configJSONString(object, "quic_congestion_control"); congestion != "" {
			out["quic_congestion_control"] = congestion
		}
	}
	// naiveTls keeps only enabled/server_name/certificate/certificate_path/ech/
	// fragment from the stored block; everything else there is intentionally
	// dropped by the model.
	out["tls"] = profileStoredNormalizeNaiveTLS(object["tls"])
	return profileStoredNormalizeEncode(out)
}

// profileStoredNormalizeNaiveTLS is naiveTls(exportToJson) composed with the
// parse-side filter. The result always carries enabled:true.
func profileStoredNormalizeNaiveTLS(value any) map[string]any {
	out := map[string]any{"enabled": true}
	block, ok := value.(map[string]any)
	if !ok {
		return out
	}
	if name := configJSONString(block, "server_name"); name != "" {
		out["server_name"] = configToACEHost(name)
	}
	if certificate := profileStoredNormalizePEMLines(block["certificate"]); len(certificate) > 0 {
		out["certificate"] = profileStoredNormalizeStringsAny(certificate)
	}
	if path := configJSONString(block, "certificate_path"); path != "" {
		out["certificate_path"] = path
	}
	if ech, present := block["ech"]; present {
		if echBlock, err := profileExportECH(ech); err == nil && len(echBlock) > 0 {
			out["ech"] = echBlock
		}
	}
	if fragment, present := block["fragment"]; present {
		out["fragment"] = configJSONBoolValue(fragment)
	}
	return out
}

// profileStoredNormalizePEMLines is tlsPemLines plus JsonValues.stringArray:
// string items are split on newlines and every blank line is dropped.
func profileStoredNormalizePEMLines(value any) []string {
	lines := []string{}
	for _, item := range configJSONStringListValue(value) {
		for _, line := range strings.Split(item, "\n") {
			if strings.TrimSpace(line) != "" {
				lines = append(lines, line)
			}
		}
	}
	return lines
}

func profileStoredNormalizeCustom(object map[string]any) (string, string, error) {
	allowed := map[string]bool{"type": true, "name": true, "subtype": true, "config": true}
	if reason := profileStoredNormalizeCheckKeys(object, allowed, "custom"); reason != "" {
		return "", reason, nil
	}
	// Custom.exportToJson writes all four keys, even empty.
	return profileStoredNormalizeEncode(map[string]any{
		"config":  configJSONString(object, "config"),
		"name":    configJSONString(object, "name"),
		"subtype": strings.TrimSpace(configJSONString(object, "subtype")),
		"type":    "custom",
	})
}

func profileStoredNormalizeChain(object map[string]any) (string, string, error) {
	allowed := map[string]bool{"type": true, "name": true, "list": true}
	if reason := profileStoredNormalizeCheckKeys(object, allowed, "chain"); reason != "" {
		return "", reason, nil
	}
	ids := []any{}
	if list, ok := object["list"].([]any); ok {
		for _, item := range list {
			ids = append(ids, configJSONInteger(item))
		}
	}
	return profileStoredNormalizeEncode(map[string]any{
		"list": ids,
		"name": configJSONString(object, "name"),
		"type": "chain",
	})
}

func profileStoredNormalizeAutoSelector(object map[string]any) (string, string, error) {
	allowed := map[string]bool{
		"type": true, "name": true, "gid": true, "gids": true,
		"name_filter": true, "country_filter": true, "exclude_unavailable": true,
		"pool_cap": true, "build_limit": true, "result_validity_mins": true,
		"test_url": true, "connectivity_url": true, "interval_sec": true,
		"bench_interval_sec": true, "watch_interval_sec": true, "active_size": true,
		"sampling": true, "tolerance_ms": true, "max_rtt_ms": true, "expected": true,
		"dial_retries": true, "interrupt_on_switch": true, "balance": true,
		"balance_mode": true, "balance_interval_sec": true, "pool": true,
		"pool_ranked_at": true, "pinned_id": true, "last_built": true,
		"last_built_at": true, "history": true,
	}
	if reason := profileStoredNormalizeCheckKeys(object, allowed, "autoselector"); reason != "" {
		return "", reason, nil
	}
	// AutoSelector.parseFromJson's defaults, then normalize()'s clamps.
	gids := []int64{}
	if value, present := object["gids"]; present {
		if list, ok := value.([]any); ok {
			for _, item := range list {
				if id := profileStoredNormalizeLongOr(item, -1); id >= 0 {
					gids = append(gids, id)
				}
			}
		}
	} else if value, present := object["gid"]; present {
		if id := profileStoredNormalizeLongOr(value, -1); id >= 0 {
			gids = append(gids, id)
		}
	}
	name := configJSONString(object, "name")
	intOr := func(key string, fallback int) int {
		if _, present := object[key]; !present {
			return fallback
		}
		return profileStoredNormalizeIntOr(object[key], fallback)
	}
	poolCap := intOr("pool_cap", 1000)
	buildLimit := intOr("build_limit", 300)
	resultValidity := intOr("result_validity_mins", 1440)
	intervalSec := intOr("interval_sec", 300)
	benchInterval := intOr("bench_interval_sec", 600)
	watchInterval := intOr("watch_interval_sec", 15)
	activeSize := intOr("active_size", 8)
	sampling := intOr("sampling", 10)
	tolerance := intOr("tolerance_ms", 300)
	maxRTT := intOr("max_rtt_ms", 0)
	expected := intOr("expected", 3)
	dialRetries := intOr("dial_retries", 2)
	balanceInterval := intOr("balance_interval_sec", 30)
	excludeUnavailable := profileStoredNormalizeBoolOr(object["exclude_unavailable"], true)
	interruptOnSwitch := profileStoredNormalizeBoolOr(object["interrupt_on_switch"], true)
	balance := profileStoredNormalizeBoolOr(object["balance"], false)
	balanceMode := "rotate"
	if value, ok := object["balance_mode"].(string); ok {
		balanceMode = value
	}
	pool := []any{}
	if list, ok := object["pool"].([]any); ok {
		for _, item := range list {
			pool = append(pool, configJSONInteger(item))
		}
	}
	pinned := int64(-1)
	if value, present := object["pinned_id"]; present {
		pinned = profileStoredNormalizeLongOr(value, -1)
	}
	lastBuilt := []any{}
	if list, ok := object["last_built"].([]any); ok {
		for _, item := range list {
			lastBuilt = append(lastBuilt, configJSONInteger(item))
		}
	}
	history := []any{}
	if list, ok := object["history"].([]any); ok {
		history = list
	}

	// AutoSelector.normalize(): unique non-negative gids, then the clamps in the
	// model's order.
	unique := make([]int64, 0, len(gids))
	seen := map[int64]bool{}
	for _, id := range gids {
		if id >= 0 && !seen[id] {
			seen[id] = true
			unique = append(unique, id)
		}
	}
	gids = unique
	if poolCap < 1 {
		poolCap = 1
	}
	if poolCap > 3000 {
		poolCap = 3000
	}
	if buildLimit < 1 {
		buildLimit = 1
	}
	if buildLimit > 500 {
		buildLimit = 500
	}
	if buildLimit > poolCap {
		buildLimit = poolCap
	}
	if resultValidity < 0 {
		resultValidity = 0
	}
	if intervalSec < 10 {
		intervalSec = 10
	}
	if benchInterval < intervalSec {
		benchInterval = intervalSec
	}
	if watchInterval < 5 {
		watchInterval = 5
	}
	if watchInterval > intervalSec {
		watchInterval = intervalSec
	}
	if activeSize < 1 {
		activeSize = 1
	}
	if expected < 1 {
		expected = 1
	}
	if activeSize < expected {
		activeSize = expected
	}
	if activeSize > buildLimit {
		activeSize = buildLimit
	}
	if sampling < 2 {
		sampling = 2
	}
	if sampling > 60 {
		sampling = 60
	}
	if tolerance < 0 {
		tolerance = 0
	}
	if maxRTT < 0 {
		maxRTT = 0
	}
	if expected > buildLimit {
		expected = buildLimit
	}
	if dialRetries < 0 {
		dialRetries = 0
	}
	if dialRetries > 5 {
		dialRetries = 5
	}
	if balanceInterval < 5 {
		balanceInterval = 5
	}
	if balanceMode != "connection" {
		balanceMode = "rotate"
	}

	gid := int64(-1)
	if len(gids) > 0 {
		gid = gids[0]
	}
	out := map[string]any{
		"active_size":          activeSize,
		"balance":              balance,
		"balance_interval_sec": balanceInterval,
		"balance_mode":         balanceMode,
		"bench_interval_sec":   benchInterval,
		"build_limit":          buildLimit,
		"connectivity_url":     configJSONString(object, "connectivity_url"),
		"country_filter":       configJSONString(object, "country_filter"),
		"dial_retries":         dialRetries,
		"exclude_unavailable":  excludeUnavailable,
		"expected":             expected,
		"gid":                  gid,
		"history":              history,
		"interrupt_on_switch":  interruptOnSwitch,
		"interval_sec":         intervalSec,
		"last_built_at":        profileStoredNormalizeDoubleLong(object["last_built_at"]),
		"max_rtt_ms":           maxRTT,
		"name":                 name,
		"name_filter":          configJSONString(object, "name_filter"),
		"pinned_id":            pinned,
		"pool":                 pool,
		"pool_cap":             poolCap,
		"pool_ranked_at":       profileStoredNormalizeDoubleLong(object["pool_ranked_at"]),
		"result_validity_mins": resultValidity,
		"sampling":             sampling,
		"test_url":             configJSONString(object, "test_url"),
		"tolerance_ms":         tolerance,
		"type":                 "autoselector",
		"watch_interval_sec":   watchInterval,
	}
	gidsOut := make([]any, 0, len(gids))
	for _, id := range gids {
		gidsOut = append(gidsOut, id)
	}
	out["gids"] = gidsOut
	out["last_built"] = lastBuilt
	return profileStoredNormalizeEncode(out)
}

// profileStoredNormalizeLongOr is AutoSelector.longOr: integral numbers keep
// their value, anything else the fallback.
func profileStoredNormalizeLongOr(value any, fallback int64) int64 {
	switch typed := value.(type) {
	case int64:
		return typed
	case float64:
		if typed == math.Trunc(typed) && typed >= math.MinInt64 && typed < math.MaxInt64 {
			return int64(typed)
		}
	}
	return fallback
}

// profileStoredNormalizeIntOr is AutoSelector.intOr.
func profileStoredNormalizeIntOr(value any, fallback int) int {
	switch typed := value.(type) {
	case int64:
		if typed >= math.MinInt32 && typed <= math.MaxInt32 {
			return int(typed)
		}
	case float64:
		if typed == math.Trunc(typed) && typed >= math.MinInt32 && typed <= math.MaxInt32 {
			return int(typed)
		}
	}
	return fallback
}

// profileStoredNormalizeBoolOr is AutoSelector.boolOr.
func profileStoredNormalizeBoolOr(value any, fallback bool) bool {
	if boolean, ok := value.(bool); ok {
		return boolean
	}
	return fallback
}

// profileStoredNormalizeDoubleLong is JsonValues.toDouble(value).toLong():
// numbers only, truncated toward zero.
func profileStoredNormalizeDoubleLong(value any) int64 {
	number := configJSONNumber(value)
	if number == 0 {
		return 0
	}
	return int64(number)
}
