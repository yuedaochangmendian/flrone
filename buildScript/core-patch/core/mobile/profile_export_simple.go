// The stored-form half of the profile codec, first S5b slice.
//
// Throne stores one outbound as a compact JSON object (`NodeRow.outbound_json`),
// with `type` plus the type's fields and the flat dial fields. The Kotlin model
// owns this form today; this file starts the Go replacement with the four
// simplest types (direct, http, socks, shadowsocks) and leaves every document
// that needs TLS/transport/multiplex unsupported. A caller can therefore use
// this action when it answers `supported:true` and fall back to the Kotlin
// exporter otherwise -- no half-decoded node ever reaches the document.
//
// Wire shape (`profileExport` action):
//
//	{"json":"…","name":"optional override","stripMetadata":false}
//	→ {"supported":true,"type":"socks","name":"…","displayType":"Socks",
//	   "json":"…","link":"…","jsonLink":"…","identity":"…","dedupKey":"…"}
//	→ {"supported":false,"type":"vless"}
//
// `json` is the canonical compact stored form (the same sorted-key bytes the
// Kotlin JsonWriter emits); `jsonLink`/`dedupKey` are the desktop's
// `throne://add/<base64url>` export with and without the tag.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
)

const profileExportMethod Method = "profileExport"

func init() {
	register(profileExportMethod, handleProfileExport)
}

type profileExportRequest struct {
	JSON          *string `json:"json"`
	Name          *string `json:"name"`
	StripMetadata bool    `json:"stripMetadata"`
}

type profileExportReply struct {
	Supported   bool   `json:"supported"`
	Type        string `json:"type"`
	Name        string `json:"name"`
	DisplayType string `json:"displayType"`
	JSON        string `json:"json"`
	Link        string `json:"link"`
	JSONLink    string `json:"jsonLink"`
	Identity    string `json:"identity"`
	DedupKey    string `json:"dedupKey"`
	// Reason is set on a supported:false refusal to name the field this slice
	// could not reproduce byte-for-byte. Additive: Dart ignores unknown keys.
	Reason string `json:"reason,omitempty"`
}

// profileStoredSimple is the parsed subset shared by the four codecs.
type profileStoredSimple struct {
	Type   string
	Name   string
	Server string
	Port   int

	ReuseAddr      bool
	ConnectTimeout string
	TCPFastOpen    bool
	TCPMultiPath   bool
	UDPFragment    bool
	BindInterface  string
	Inet4Bind      string
	Inet6Bind      string

	Username string
	Password string
	Path     string
	Headers  map[string]string

	Method     string
	Plugin     string
	PluginOpts string
	Socks4a    bool
	Socks4     bool
	UOT        bool

	// Multiplex is non-nil only for imports whose Kotlin counterpart always
	// writes a multiplex block (Clash imports call Multiplex.parseFromClash,
	// which clears "unspecified"). Simple links leave it nil.
	Multiplex map[string]any

	// TLS is the canonical http TLS block the stored normalizer builds (the
	// stored validation/export paths still refuse a TLS-bearing http document,
	// so nothing below sets it). Nil means "no tls key".
	TLS map[string]any
}

var profileStoredSimpleTypes = map[string]bool{
	"direct": true, "http": true, "socks": true, "shadowsocks": true,
}

func handleProfileExport(raw json.RawMessage) (any, error) {
	var request profileExportRequest
	if len(strings.TrimSpace(string(raw))) > 0 {
		if err := json.Unmarshal(raw, &request); err != nil {
			return nil, err
		}
	}
	if request.JSON == nil {
		return nil, errors.New("profileExport requires a json field")
	}
	object, ok := configDecodeJSONObject(*request.JSON)
	if !ok {
		return nil, errors.New("profileExport: json is not an object")
	}
	outbound, supported, err := profileStoredSimpleFromObject(object)
	if err != nil {
		return nil, err
	}
	if !supported {
		// The three newer single-protocol types (mieru/snell/shadowtls) own a
		// stored-row reader in profile_export_newout.go; the five TLS/transport
		// types come next. Both refuse an unported field with supported:false so
		// the caller falls back to the Kotlin exporter unchanged.
		if reply, owned, newErr := handleProfileExportNew(object, request.Name); owned || newErr != nil {
			if newErr != nil {
				if refused, ok := newErr.(profileImportUnsupported); ok {
					return profileExportReply{Supported: false, Type: configJSONString(object, "type"), Reason: refused.Reason}, nil
				}
				return nil, newErr
			}
			return reply, nil
		}
		// The endpoint slice owns openvpn/openvpn-client/openconnect: their
		// stored JSON has nested blocks (servers, tls, token, ...) that the
		// simple and advanced readers do not model.
		if vpn, owned, vpnErr := handleProfileExportVpn(object, request.Name); owned || vpnErr != nil {
			if vpnErr != nil {
				if refused, ok := vpnErr.(profileImportUnsupported); ok {
					return profileExportReply{Supported: false, Type: configJSONString(object, "type"), Reason: refused.Reason}, nil
				}
				return nil, vpnErr
			}
			return vpn, nil
		}
		// The advanced slice owns the five TLS/transport-bearing types. A
		// refusal (unported field) keeps the reply's supported:false shape so
		// callers fall back to the Kotlin exporter unchanged.
		advanced, owned, advancedErr := handleProfileExportAdvanced(object, request.Name)
		if advancedErr != nil {
			if refused, ok := advancedErr.(profileImportUnsupported); ok {
				return profileExportReply{Supported: false, Type: configJSONString(object, "type"), Reason: refused.Reason}, nil
			}
			return nil, advancedErr
		}
		if owned {
			return advanced, nil
		}
		return profileExportReply{Supported: false, Type: configJSONString(object, "type")}, nil
	}
	if request.Name != nil {
		outbound.Name = strings.TrimSpace(*request.Name)
	}
	storedJSON, err := profileStoredSimpleJSON(outbound)
	if err != nil {
		return nil, err
	}
	withoutTag := profileStoredSimpleWithoutTag(outbound)
	dedupJSON, err := profileStoredSimpleJSON(withoutTag)
	if err != nil {
		return nil, err
	}
	identity := storedJSON
	if outbound.Server != "" {
		identityMap := map[string]any{
			"server":      outbound.Server,
			"server_port": outbound.Port,
		}
		if len(outbound.TLS) > 0 {
			if tlsIdentity := profileExportTLSIdentity(outbound.TLS); len(tlsIdentity) > 0 {
				identityMap["tls"] = tlsIdentity
			}
		}
		encoded, encodeErr := MarshalCanonicalJSON(identityMap)
		if encodeErr != nil {
			return nil, encodeErr
		}
		identity = string(encoded)
	}
	jsonLink := "throne://add/" + profileBase64Encode([]byte(storedJSON), true, false)
	return profileExportReply{
		Supported:   true,
		Type:        outbound.Type,
		Name:        outbound.Name,
		DisplayType: profileStoredSimpleDisplayType(outbound.Type),
		JSON:        storedJSON,
		Link:        profileStoredSimpleLink(outbound),
		JSONLink:    jsonLink,
		Identity:    identity,
		DedupKey:    "throne://add/" + profileBase64Encode([]byte(dedupJSON), true, false),
	}, nil
}

// profileStoredSimpleFromObject returns supported=false for a type this slice
// does not own yet, and an error for a malformed document of a type it does.
func profileStoredSimpleFromObject(object map[string]any) (*profileStoredSimple, bool, error) {
	rawType := configJSONString(object, "type")
	// hysteria2/openvpn-client-style aliases belong to their own codecs; only
	// the exact four names are in this slice.
	if !profileStoredSimpleTypes[rawType] {
		return nil, false, nil
	}
	outbound := &profileStoredSimple{Type: rawType}
	if value, ok := object["tag"].(string); ok {
		outbound.Name = value
	}
	if raw := configJSONString(object, "server"); raw != "" {
		if !profileHostValidForStored(raw) {
			return nil, true, fmt.Errorf("profileExport: invalid server %q", raw)
		}
		// IDN follows Hosts.toAceHost into the stored form (ACE, lower case);
		// ASCII keeps the caller's spelling, as Kotlin's toAceHost does. A
		// percent-escaped host is left to the Kotlin exporter until S5c.
		if strings.Contains(raw, "%") {
			return nil, false, nil
		}
		if configIsASCII(raw) {
			outbound.Server = raw
		} else {
			ace, ok := configToACE(raw)
			if !ok {
				return nil, false, nil
			}
			outbound.Server = ace
		}
	}
	outbound.Port = configJSONInt(object["server_port"])
	outbound.ReuseAddr = configJSONBool(object, "reuse_addr")
	outbound.ConnectTimeout = strings.TrimSpace(configJSONString(object, "connect_timeout"))
	outbound.TCPFastOpen = configJSONBool(object, "tcp_fast_open")
	outbound.TCPMultiPath = configJSONBool(object, "tcp_multi_path")
	outbound.UDPFragment = configJSONBool(object, "udp_fragment")
	outbound.BindInterface = configJSONString(object, "bind_interface")
	outbound.Inet4Bind = configJSONString(object, "inet4_bind_address")
	outbound.Inet6Bind = configJSONString(object, "inet6_bind_address")
	switch rawType {
	case "direct":
		// no endpoint fields
	case "http":
		if value, present := object["tls"]; present {
			// Http has TLS: Tls.parseFromJson reads the block and exportToJson
			// writes the canonical form. A block the exporter cannot reproduce
			// answers supported=false so the caller falls back to Kotlin.
			if block, ok := value.(map[string]any); ok && len(block) > 0 {
				tls, err := profileExportTLS(value, "")
				if err != nil {
					return nil, false, nil
				}
				if len(tls) > 0 {
					outbound.TLS = tls
				}
			}
		}
		outbound.Username = configJSONString(object, "username")
		outbound.Password = configJSONString(object, "password")
		outbound.Path = configJSONString(object, "path")
		if headers, present := object["headers"]; present {
			var valid bool
			outbound.Headers, valid = profileStoredStringMap(headers)
			if !valid {
				return nil, false, nil
			}
		}
	case "socks":
		outbound.Username = configJSONString(object, "username")
		outbound.Password = configJSONString(object, "password")
		outbound.UOT = profileStoredUOT(object["uot"])
		outbound.Socks4a, outbound.Socks4 = profileStoredSocksVersion(object["version"])
	case "shadowsocks":
		if value, present := object["multiplex"]; present {
			block, ok := value.(map[string]any)
			if !ok {
				return nil, false, nil
			}
			if _, hasEnabled := block["enabled"]; hasEnabled {
				outbound.Multiplex = profileNormalizeStoredMultiplex(block)
			}
		}
		outbound.Method = configJSONString(object, "method")
		outbound.Password = configJSONString(object, "password")
		outbound.Plugin = configJSONString(object, "plugin")
		outbound.PluginOpts = configJSONString(object, "plugin_opts")
		outbound.UOT = profileStoredUOT(object["uot"]) ||
			profileStoredUOT(object["udp_over_tcp"])
	}
	return outbound, true, nil
}

func profileStoredUOT(value any) bool {
	switch typed := value.(type) {
	case bool:
		return typed
	case map[string]any:
		enabled, _ := typed["enabled"].(bool)
		return enabled
	}
	return false
}

// profileStoredSocksVersion returns whether the form is 4a; the stored "4a"/"4"
// text and the numeric forms are both accepted.
func profileStoredSocksVersion(value any) (socks4a bool, version4 bool) {
	text := strings.ToLower(strings.TrimSpace(fmt.Sprint(value)))
	switch text {
	case "4", "4a":
		return text == "4a", true
	case "5", "0", "<nil>":
		return false, false
	}
	number := configJSONInt(value)
	if number == 4 {
		return false, true
	}
	return false, false
}

func profileStoredSimpleJSON(outbound *profileStoredSimple) (string, error) {
	object := map[string]any{"type": outbound.Type}
	if outbound.Name != "" {
		object["tag"] = outbound.Name
	}
	if outbound.Type != "direct" {
		if outbound.Server != "" {
			object["server"] = outbound.Server
		}
		if outbound.Port > 0 {
			object["server_port"] = outbound.Port
		}
	}
	if outbound.ReuseAddr {
		object["reuse_addr"] = true
	}
	if outbound.ConnectTimeout != "" {
		object["connect_timeout"] = outbound.ConnectTimeout
	}
	if outbound.TCPFastOpen {
		object["tcp_fast_open"] = true
	}
	if outbound.TCPMultiPath {
		object["tcp_multi_path"] = true
	}
	if outbound.UDPFragment {
		object["udp_fragment"] = true
	}
	if outbound.BindInterface != "" {
		object["bind_interface"] = outbound.BindInterface
	}
	if outbound.Inet4Bind != "" {
		object["inet4_bind_address"] = outbound.Inet4Bind
	}
	if outbound.Inet6Bind != "" {
		object["inet6_bind_address"] = outbound.Inet6Bind
	}
	switch outbound.Type {
	case "http":
		if outbound.Username != "" {
			object["username"] = outbound.Username
		}
		if outbound.Password != "" {
			object["password"] = outbound.Password
		}
		if outbound.Path != "" {
			object["path"] = outbound.Path
		}
		if len(outbound.Headers) > 0 {
			headers := map[string]any{}
			for key, value := range outbound.Headers {
				headers[key] = value
			}
			object["headers"] = headers
		}
		// Tls.exportToJson drops a disabled block; the stored normalizer keeps the
		// canonical block here, and a nil field means the key was never present.
		if len(outbound.TLS) > 0 {
			object["tls"] = outbound.TLS
		}
	case "socks":
		if outbound.Username != "" {
			object["username"] = outbound.Username
		}
		if outbound.Password != "" {
			object["password"] = outbound.Password
		}
		if outbound.Socks4a {
			object["version"] = "4a"
		} else if outbound.Socks4 {
			object["version"] = "4"
		}
		if outbound.UOT {
			object["uot"] = true
		}
	case "shadowsocks":
		if outbound.Method != "" {
			object["method"] = outbound.Method
		}
		if outbound.Password != "" {
			object["password"] = outbound.Password
		}
		if outbound.Plugin != "" {
			object["plugin"] = outbound.Plugin
		}
		if outbound.PluginOpts != "" {
			object["plugin_opts"] = outbound.PluginOpts
		}
		if outbound.UOT {
			object["udp_over_tcp"] = true
		}
	}
	if outbound.Multiplex != nil {
		object["multiplex"] = outbound.Multiplex
	}
	encoded, err := MarshalCanonicalJSON(object)
	return string(encoded), err
}

func profileStoredSimpleWithoutTag(outbound *profileStoredSimple) *profileStoredSimple {
	copied := *outbound
	copied.Name = ""
	return &copied
}

func profileStoredSimpleDisplayType(profileType string) string {
	switch profileType {
	case "direct":
		return "Direct"
	case "http":
		return "HTTP"
	case "socks":
		return "Socks"
	case "shadowsocks":
		return "Shadowsocks"
	}
	return profileType
}

func profileStoredSimpleLink(outbound *profileStoredSimple) string {
	if outbound.Type == "direct" {
		query := profileStoredDialQuery(outbound)
		return profileStoredFormatQuery(query)
	}
	if outbound.Server == "" {
		return ""
	}
	builder := profileStoredLinkBuilder{}
	switch outbound.Type {
	case "http":
		builder.scheme = "http"
		if outbound.TLS != nil {
			if enabled, _ := outbound.TLS["enabled"].(bool); enabled {
				builder.scheme = "https"
			}
		}
		builder.username = outbound.Username
		builder.hasUsername = outbound.Username != ""
		builder.password = outbound.Password
		builder.hasPassword = outbound.Password != ""
		if outbound.Path != "" {
			builder.query = append(builder.query, profileStoredQueryItem{key: "path", value: outbound.Path})
		}
		if len(outbound.Headers) > 0 {
			keys := make([]string, 0, len(outbound.Headers))
			for key := range outbound.Headers {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			pairs := make([]string, 0, len(keys)*2)
			for _, key := range keys {
				pairs = append(pairs, key, outbound.Headers[key])
			}
			builder.query = append(builder.query, profileStoredQueryItem{key: "headers", value: strings.Join(pairs, ",")})
		}
		// Http.exportToLink appends Tls.exportToLink after path/headers.
		builder.query = append(builder.query, profileExportTLSQuery(outbound.TLS)...)
	case "socks":
		switch {
		case outbound.Socks4a:
			builder.scheme = "socks4a"
		case outbound.Socks4:
			builder.scheme = "socks4"
		default:
			builder.scheme = "socks5"
		}
		builder.username = outbound.Username
		builder.hasUsername = outbound.Username != ""
		builder.password = outbound.Password
		builder.hasPassword = outbound.Password != ""
		if outbound.UOT {
			builder.query = append(builder.query, profileStoredQueryItem{key: "uot", value: "1"})
		}
	case "shadowsocks":
		builder.scheme = "ss"
		if strings.HasPrefix(outbound.Method, "2022-") {
			builder.username = outbound.Method
			builder.hasUsername = true
			builder.password = outbound.Password
			builder.hasPassword = outbound.Password != ""
		} else {
			builder.username = profileBase64Encode([]byte(outbound.Method+":"+outbound.Password), true, true)
			builder.hasUsername = true
		}
		if outbound.Plugin != "" {
			plugin := outbound.Plugin
			if outbound.PluginOpts != "" {
				plugin += ";" + outbound.PluginOpts
			}
			builder.query = append(builder.query, profileStoredQueryItem{
				key: "plugin", value: profileLinkPercentEncodeAll(plugin), encoded: true,
			})
		}
		if outbound.UOT {
			builder.query = append(builder.query, profileStoredQueryItem{key: "uot", value: "1"})
		}
	}
	if builder.scheme == "" {
		return ""
	}
	builder.host = outbound.Server
	builder.port = outbound.Port
	if outbound.Name != "" {
		builder.fragment = outbound.Name
		builder.hasFragment = true
	}
	builder.query = append(builder.query, profileStoredDialQuery(outbound)...)
	return builder.build()
}

func profileStoredDialQuery(outbound *profileStoredSimple) []profileStoredQueryItem {
	var query []profileStoredQueryItem
	if outbound.ReuseAddr {
		query = append(query, profileStoredQueryItem{key: "reuse_addr", value: "true"})
	}
	if outbound.ConnectTimeout != "" {
		query = append(query, profileStoredQueryItem{key: "connect_timeout", value: outbound.ConnectTimeout})
	}
	if outbound.TCPFastOpen {
		query = append(query, profileStoredQueryItem{key: "tcp_fast_open", value: "true"})
	}
	if outbound.TCPMultiPath {
		query = append(query, profileStoredQueryItem{key: "tcp_multi_path", value: "true"})
	}
	if outbound.UDPFragment {
		query = append(query, profileStoredQueryItem{key: "udp_fragment", value: "true"})
	}
	if outbound.BindInterface != "" {
		query = append(query, profileStoredQueryItem{key: "bind_interface", value: outbound.BindInterface})
	}
	if outbound.Inet4Bind != "" {
		query = append(query, profileStoredQueryItem{key: "inet4_bind_address", value: outbound.Inet4Bind})
	}
	if outbound.Inet6Bind != "" {
		query = append(query, profileStoredQueryItem{key: "inet6_bind_address", value: outbound.Inet6Bind})
	}
	return query
}

type profileStoredQueryItem struct {
	key     string
	value   string
	encoded bool
}

type profileStoredLinkBuilder struct {
	scheme      string
	host        string
	port        int
	fragment    string
	hasFragment bool
	username    string
	hasUsername bool
	password    string
	hasPassword bool
	query       []profileStoredQueryItem
}

func (builder profileStoredLinkBuilder) build() string {
	if builder.port < -1 || builder.port > 65535 || builder.host == "" {
		return ""
	}
	normalizedHost, valid := profileLinkNormalizeHostForURL(builder.host)
	if !valid {
		return ""
	}
	builder.host = normalizedHost
	var out strings.Builder
	out.WriteString(builder.scheme)
	out.WriteString("://")
	if builder.hasUsername || builder.hasPassword {
		out.WriteString(profileLinkEncodeUserName(builder.username))
		if builder.hasPassword {
			out.WriteString(":")
			out.WriteString(profileLinkEncodePassword(builder.password))
		}
		out.WriteString("@")
	}
	out.WriteString(profileStoredFormatHost(builder.host))
	if builder.port >= 0 {
		out.WriteString(":")
		out.WriteString(strconv.Itoa(builder.port))
	}
	if len(builder.query) > 0 {
		out.WriteString("?")
		for index, item := range builder.query {
			if index > 0 {
				out.WriteString("&")
			}
			out.WriteString(profileLinkEncodeQueryPart(item.key))
			out.WriteString("=")
			if item.encoded {
				out.WriteString(item.value)
			} else {
				out.WriteString(profileLinkEncodeQueryPart(item.value))
			}
		}
	}
	if builder.hasFragment {
		out.WriteString("#")
		out.WriteString(profileLinkEncodeFragment(builder.fragment))
	}
	return out.String()
}

func profileStoredFormatQuery(query []profileStoredQueryItem) string {
	var out strings.Builder
	for index, item := range query {
		if index > 0 {
			out.WriteString("&")
		}
		out.WriteString(profileLinkEncodeQueryPart(item.key))
		out.WriteString("=")
		if item.encoded {
			out.WriteString(item.value)
		} else {
			out.WriteString(profileLinkEncodeQueryPart(item.value))
		}
	}
	return out.String()
}

func profileStoredFormatHost(host string) string {
	if strings.Contains(host, ":") {
		return "[" + host + "]"
	}
	return host
}

func profileStoredStringMap(value any) (map[string]string, bool) {
	object, ok := value.(map[string]any)
	if !ok {
		return nil, true
	}
	out := make(map[string]string, len(object))
	for key, item := range object {
		text, ok := item.(string)
		if !ok {
			return nil, false
		}
		out[key] = text
	}
	return out, true
}
