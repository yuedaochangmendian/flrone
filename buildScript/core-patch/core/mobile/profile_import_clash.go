// The Clash-to-Throne stored-form importer (S5d).
//
// One entry of a Clash `proxies:` sequence becomes one node in the shape the
// Kotlin exporters pin byte for byte. The source of truth is the Android
// parseFromClash pair —
// app/src/main/java/io/nekohasekai/sagernet/outbound/types/{Shadowsocks,Socks,
// Http,Vmess,Vless,Trojan,Hysteria}.kt with common/{Tls,Transport,Multiplex}.kt
// and outbound/import/ClashProxy.kt — and the JVM oracle pins in
// ProfileStoredGoParityTest.kt. Every field below follows one of those getters;
// a value that needs a Kotlin rule this file has not ported is refused with a
// reason instead of being approximated. No partially normalized node is ever
// returned.
//
// The JSON/identity/dedup tail is shared with the share-link importer:
// profileImportedNodeFromSimple and profileAdvancedNode own those bytes, so
// this file cannot drift from the link path.
//
// profileImportBody calls profileImportClashBody when it detects a Clash YAML
// subscription; the body dispatcher owns the action's all-or-nothing contract.
package mobile

import (
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// profileImportClashBody parses a Clash YAML document and converts its proxies
// sequence. The body dispatcher's contract is all-or-nothing: one unported
// entry refuses the whole body with the first reason so the caller falls back
// to Kotlin instead of storing a partial subscription.
func profileImportClashBody(text string) ([]profileImportedNode, error) {
	doc, err := parseClashDocument(text)
	if err != nil {
		return nil, err
	}
	if doc.Proxies == nil {
		return nil, profileUnsupported("clash: document has no proxies sequence")
	}
	if len(doc.Proxies) == 0 {
		return nil, profileUnsupported("clash: no proxies entries")
	}
	nodes := make([]profileImportedNode, 0, len(doc.Proxies))
	for i, entry := range doc.Proxies {
		node, err := clashProxyToImportedNode(entry)
		if err != nil {
			// Keep the typed refusal value (the body dispatcher's tests assert
			// it with a direct type assertion), carrying the entry index in
			// the reason so callers can still locate the offending proxy.
			var refused profileImportUnsupported
			if errors.As(err, &refused) {
				return nil, profileUnsupported(fmt.Sprintf("clash proxies[%d]: %s", i, refused.Reason))
			}
			return nil, err
		}
		nodes = append(nodes, *node)
	}
	return nodes, nil
}

// clashProxyToImportedNode converts one already-parsed Clash proxy entry.
func clashProxyToImportedNode(entry map[string]any) (*profileImportedNode, error) {
	if len(entry) == 0 {
		return nil, profileUnsupported("clash: empty proxies entry")
	}
	p := clashProxy{Node: entry}
	switch p.Type() {
	case "ss":
		return clashSS(p)
	case "socks5":
		return clashSocks(p)
	case "http":
		return clashHTTP(p)
	case "vmess":
		return clashVMess(p)
	case "vless":
		return clashVLESS(p)
	case "trojan":
		return clashTrojan(p)
	case "hysteria", "hysteria2":
		return clashHysteria(p)
	case "tuic":
		return clashTuic(p)
	case "anytls":
		return clashAnyTls(p)
	case "snell":
		return clashSnell(p)
	case "ssh":
		return clashSSH(p)
	case "juicity", "naive", "trusttunnel", "mieru", "shadowtls":
		// OutboundFactory's Clash protocol list has no entry for these types;
		// Kotlin would report the proxy as unsupported rather than map it.
		return nil, profileUnsupported("clash: proxy type " + p.Type() + " has no Clash mapping in Kotlin")
	case "openvpn", "openvpn-client", "openconnect":
		// Same for the two endpoint types: their Clash forms are not something
		// Kotlin can convert, and half-mapping them would invent fields.
		return nil, profileUnsupported("clash: proxy type " + p.Type() + " has no Clash mapping in Kotlin")
	default:
		return nil, profileUnsupported("clash: proxy type not ported yet: " + p.Type())
	}
}

// baseParseFromClash is Outbound.baseParseFromClash: name, ACE host and port.
// Hosts.toAceHost leaves ASCII hosts as written, so only an IDN needs the ACE
// conversion. An unconvertible name is refused rather than stored differently
// from Kotlin (which keeps the raw spelling in that case, but without a
// reliable Go equivalent of normalizeName's failure rules).
func clashBase(p clashProxy, nodeType string) (name, server string, port int, err error) {
	name = p.String("name")
	server = p.String("server")
	if server == "" {
		return "", "", 0, profileUnsupported("clash: no server")
	}
	if !configIsASCII(server) {
		ace, ok := configToACE(server)
		if !ok {
			return "", "", 0, profileUnsupported("clash: server host cannot be converted to ACE")
		}
		server = ace
	}
	port = p.Int("port")
	if port < 0 {
		return "", "", 0, profileUnsupported("clash: negative port")
	}
	return name, server, port, nil
}

// --- simple types ----------------------------------------------------------

func clashSS(p clashProxy) (*profileImportedNode, error) {
	name, server, port, err := clashBase(p, "shadowsocks")
	if err != nil {
		return nil, err
	}
	outbound := &profileStoredSimple{Type: "shadowsocks", Name: name, Server: server, Port: port}
	outbound.Method = strings.ToLower(strings.TrimSpace(p.String("cipher")))
	outbound.Password = p.String("password")
	outbound.UOT = p.Bool("udp-over-tcp")
	if plugin := p.String("plugin"); plugin != "" {
		opts := p.Obj("plugin-opts")
		switch plugin {
		case "v2ray-plugin":
			var items []string
			if opts.Bool("tls") {
				items = append(items, "tls")
			}
			for _, key := range []string{"host", "path", "mode"} {
				if value := opts.String(key); value != "" {
					items = append(items, key+"="+value)
				}
			}
			if opts.Bool("mux") {
				items = append(items, "mux")
			}
			outbound.Plugin, outbound.PluginOpts = plugin, strings.Join(items, ";")
		case "obfs":
			var items []string
			if mode := opts.String("mode"); mode != "" {
				items = append(items, "obfs="+mode)
			}
			if host := opts.String("host"); host != "" {
				items = append(items, "obfs-host="+host)
			}
			outbound.Plugin, outbound.PluginOpts = "obfs-local", strings.Join(items, ";")
		default:
			// Kotlin reports the plugin and still builds the node; a stored
			// node with an unregistered plugin would be unusable, so refuse.
			return nil, profileUnsupported("clash: shadowsocks plugin not ported yet: " + plugin)
		}
	}
	// Multiplex.parseFromClash always sets unspecified=false: even a plain
	// shadowsocks Clash entry exports {"multiplex":{"enabled":false}}.
	mux, err := clashMux(p)
	if err != nil {
		return nil, err
	}
	outbound.Multiplex = mux
	return profileImportedNodeFromSimple(outbound)
}

func clashSocks(p clashProxy) (*profileImportedNode, error) {
	name, server, port, err := clashBase(p, "socks")
	if err != nil {
		return nil, err
	}
	outbound := &profileStoredSimple{Type: "socks", Name: name, Server: server, Port: port}
	outbound.Username = p.String("username")
	outbound.Password = p.String("password")
	return profileImportedNodeFromSimple(outbound)
}

func clashHTTP(p clashProxy) (*profileImportedNode, error) {
	name, server, port, err := clashBase(p, "http")
	if err != nil {
		return nil, err
	}
	outbound := &profileStoredSimple{Type: "http", Name: name, Server: server, Port: port}
	outbound.Username = p.String("username")
	outbound.Password = p.String("password")
	// Http.parseFromClash runs Tls.parseFromClash with the entry's own tls
	// switch; a TLS-bearing http document keeps the canonical block.
	tls, hasTLS, err := clashTLS(p, p.Bool("tls"), true, true)
	if err != nil {
		return nil, err
	}
	if hasTLS {
		outbound.TLS = tls
	}
	return profileImportedNodeFromSimple(outbound)
}

// --- advanced types --------------------------------------------------------

func clashVMess(p clashProxy) (*profileImportedNode, error) {
	name, server, port, err := clashBase(p, "vmess")
	if err != nil {
		return nil, err
	}
	security := "auto"
	if cipher := p.String("cipher"); cipher != "" {
		// vmessImportSecurity: an unknown cipher warns and falls back to auto.
		if value := strings.ToLower(strings.TrimSpace(cipher)); vmessSecurityKnown(value) {
			security = value
		}
	}
	fields := map[string]any{"packet_encoding": clashPacketEncoding(p.String("packet-encoding"))}
	if uuid := p.String("uuid"); uuid != "" {
		fields["uuid"] = uuid
	}
	if security != "auto" {
		fields["security"] = security
	}
	if alterID := p.Int("alterId"); alterID > 0 {
		fields["alter_id"] = alterID
	}
	tls, hasTLS, err := clashTLS(p, p.Bool("tls"), true, true)
	if err != nil {
		return nil, err
	}
	transport, hasTransport, err := clashTransport(p)
	if err != nil {
		return nil, err
	}
	mux, err := clashMux(p)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "vmess", Name: name, Server: server, Port: port, Fields: fields,
		TLS: tls, HasTLS: hasTLS, Transport: transport, HasTr: hasTransport,
		Multiplex: mux, HasMux: true,
	}
	return profileAdvancedNode(node)
}

func clashVLESS(p clashProxy) (*profileImportedNode, error) {
	name, server, port, err := clashBase(p, "vless")
	if err != nil {
		return nil, err
	}
	encryption := strings.TrimSpace(p.String("encryption"))
	if encryption == "" || strings.EqualFold(encryption, "none") {
		encryption = "none"
	}
	fields := map[string]any{
		"encryption":      encryption,
		"packet_encoding": clashPacketEncoding(p.String("packet-encoding")),
	}
	if uuid := p.String("uuid"); uuid != "" {
		fields["uuid"] = uuid
	}
	flow := strings.ToLower(strings.TrimSpace(p.String("flow")))
	if flow == "none" {
		flow = ""
	}
	// vlessImportFlow keeps the name; dropUnusableVlessFlow below drops an
	// unknown one with a warning, and only udp443 is refused at validation.
	if flow == "xtls-rprx-vision-udp443" {
		return nil, profileUnsupported("clash: vless flow not supported by the core: " + flow)
	}
	if flow == "xtls-rprx-vision" {
		fields["flow"] = flow
	} else {
		flow = ""
	}
	tls, hasTLS, err := clashTLS(p, p.Bool("tls"), true, true)
	if err != nil {
		return nil, err
	}
	transport, hasTransport, err := clashTransport(p)
	if err != nil {
		return nil, err
	}
	// VlessChecks.vlessFlow: Vision needs TLS and a plain TCP dial.
	if flow == "xtls-rprx-vision" && (!hasTLS || (hasTransport && transport["type"] != "tcp")) {
		delete(fields, "flow")
	}
	mux, err := clashMux(p)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "vless", Name: name, Server: server, Port: port, Fields: fields,
		TLS: tls, HasTLS: hasTLS, Transport: transport, HasTr: hasTransport,
		Multiplex: mux, HasMux: true,
	}
	return profileAdvancedNode(node)
}

func clashTrojan(p clashProxy) (*profileImportedNode, error) {
	name, server, port, err := clashBase(p, "trojan")
	if err != nil {
		return nil, err
	}
	fields := map[string]any{}
	if password := p.String("password"); password != "" {
		fields["password"] = password
	}
	// Trojan.parseFromClash calls tls.parseFromClash(proxy) then forces enabled.
	tls, _, err := clashTLS(p, true, true, true)
	if err != nil {
		return nil, err
	}
	transport, hasTransport, err := clashTransport(p)
	if err != nil {
		return nil, err
	}
	mux, err := clashMux(p)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: "trojan", Name: name, Server: server, Port: port, Fields: fields,
		TLS: tls, HasTLS: true, Transport: transport, HasTr: hasTransport,
		Multiplex: mux, HasMux: true,
	}
	return profileAdvancedNode(node)
}

func clashHysteria(p clashProxy) (*profileImportedNode, error) {
	version := p.Type()
	name, server, port, err := clashBase(p, version)
	if err != nil {
		return nil, err
	}
	fields := map[string]any{}
	if ports := strings.TrimSpace(p.String("ports")); ports != "" {
		parts := strings.FieldsFunc(ports, func(r rune) bool { return r == ',' || r == '/' })
		if list := profilePortsToPorts(parts); len(list) > 0 {
			anyPorts := make([]any, 0, len(list))
			for _, value := range list {
				anyPorts = append(anyPorts, value)
			}
			fields["server_ports"] = anyPorts
		}
	}
	if rawHop := strings.TrimSpace(p.String("hop-interval")); rawHop != "" {
		// keep(): an invalid hop interval is dropped with a warning.
		if value := profileHopDuration(rawHop); profileValidDuration(value) {
			fields["hop_interval"] = value
		}
	}
	if version == "hysteria" {
		if protocol := strings.TrimSpace(p.String("protocol")); protocol != "" && !strings.EqualFold(protocol, "udp") {
			return nil, profileUnsupported("clash: hysteria protocol not ported yet: " + protocol)
		}
		auth := p.String("auth-str")
		if auth == "" {
			auth = p.String("auth_str")
		}
		if auth != "" {
			fields["auth_str"] = auth
		}
		if obfs := p.String("obfs"); obfs != "" {
			fields["obfs"] = obfs
		}
		if window := p.Int("recv-window"); window > 0 {
			fields["recv_window"] = window
		} else if window = p.Int("recv_window"); window > 0 {
			fields["recv_window"] = window
		}
		if window := p.Int("recv-window-conn"); window > 0 {
			fields["recv_window_conn"] = window
		} else if window = p.Int("recv_window_conn"); window > 0 {
			fields["recv_window_conn"] = window
		}
		if p.Bool("disable_mtu_discovery") {
			fields["disable_mtu_discovery"] = true
		}
	} else {
		if password := p.String("password"); password != "" {
			fields["password"] = password
		}
		obfsType := strings.ToLower(strings.TrimSpace(p.String("obfs")))
		if obfsType == "" {
			obfsType = "salamander"
		}
		if obfsPassword := p.String("obfs-password"); obfsPassword != "" {
			fields["obfs"] = map[string]any{
				"type":            obfsType,
				"password":        obfsPassword,
				"min_packet_size": 0,
				"max_packet_size": 0,
			}
		}
		// Kotlin's Hysteria.parseFromClash does not read hop_interval_max,
		// bbr_profile or disable_chrome_parrot from a Clash entry; keep the
		// same field set instead of storing values the oracle drops.
	}
	if up := clashBandwidthMbps(p.String("up")); up > 0 {
		fields["up_mbps"] = up
	}
	if down := clashBandwidthMbps(p.String("down")); down > 0 {
		fields["down_mbps"] = down
	}
	// Hysteria.parseFromClash forces tls.enabled=true after the parse.
	tls, _, err := clashTLS(p, true, true, false)
	if err != nil {
		return nil, err
	}
	node := &profileStoredAdvanced{
		Type: version, Name: name, Server: server, Port: port, Fields: fields,
		TLS: tls, AlwaysTLS: true,
	}
	return profileAdvancedNode(node)
}

// clashPacketEncoding mirrors vmessImportPacketEncoding/vlessImportPacketEncoding:
// "none" and unknown values both mean the empty string in Kotlin's imports.
func clashPacketEncoding(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "xudp" || value == "packetaddr" {
		return value
	}
	return ""
}

// clashTLS is Tls.parseFromClash for the fields this slice pins. readPin=false
// matches the tls switch of Http/VLESS/VMess when `tls` is off (Kotlin calls
// readPin with clashTlsOn(proxy)). utlsSupported mirrors UTls.supported:
// Hysteria/TUIC turn uTLS off, so "none" disables it and other values stay
// verbatim instead of being validated.
func clashTLS(p clashProxy, enabled, readPin, utlsSupported bool) (map[string]any, bool, error) {
	realityKey := strings.TrimSpace(p.Obj("reality-opts").String("public-key"))
	// Tls.parseFromClash leaves enabled as proxy.bool("tls"), but a REALITY key
	// turns TLS on at the end -- even on an entry that wrote tls: false.
	if !enabled && realityKey == "" {
		return map[string]any{}, false, nil
	}
	tls := map[string]any{"enabled": true}
	serverName := p.String("servername")
	if serverName == "" {
		serverName = p.String("sni")
	}
	if serverName == "" {
		serverName = p.String("server")
	}
	if serverName != "" {
		tls["server_name"] = aceShareHost(serverName)
	}
	if p.Bool("skip-cert-verify") {
		tls["insecure"] = true
	}
	if alpn := p.Strings("alpn"); len(alpn) > 0 {
		items := make([]any, 0, len(alpn))
		for _, value := range alpn {
			if trimmed := strings.TrimSpace(value); trimmed != "" {
				items = append(items, trimmed)
			}
		}
		if len(items) > 0 {
			tls["alpn"] = items
		}
	}
	if readPin {
		if pin := p.String("fingerprint"); pin != "" {
			hashes := clashCertificatePins(pin)
			if len(hashes) == 0 {
				return nil, false, profileUnsupported("clash: TLS fingerprint pin is not valid hex")
			}
			tls["certificate_sha256"] = hashes
		}
	}
	if fp := strings.TrimSpace(p.String("client-fingerprint")); fp != "" {
		if strings.EqualFold(fp, "none") {
			if utlsSupported {
				tls["utls"] = map[string]any{"enabled": true, "fingerprint": "unsafe"}
			}
		} else if utlsSupported {
			// importTlsFingerprint drops an unknown fingerprint (and lower-cases
			// a case-only mistake).
			if normalized, ok := profileTLSFingerprint(fp); ok && normalized != "" {
				tls["utls"] = map[string]any{"enabled": true, "fingerprint": normalized}
			}
		} else {
			// UTls.parseFromClash keeps the value as written when uTLS is
			// unsupported (Hysteria/TUIC).
			tls["utls"] = map[string]any{"enabled": true, "fingerprint": fp}
		}
	}
	reality := p.Obj("reality-opts")
	if key := strings.TrimSpace(reality.String("public-key")); key != "" {
		// importRealityPublicKey strips trailing '=' only when the unpadded key
		// is a valid 32-byte base64url value; every other spelling is kept as
		// written (validation, not the importer, reports bad keys).
		trimmed := strings.TrimRight(key, "=")
		if strings.HasSuffix(key, "=") {
			if decoded, ok := profileBase64Decode(trimmed, true); ok && len(decoded) == 32 {
				key = trimmed
			}
		}
		r := map[string]any{"enabled": true, "public_key": key}
		if shortID := strings.TrimSpace(reality.String("short-id")); shortID != "" {
			r["short_id"] = shortID
		}
		if verify := strings.TrimSpace(reality.String("mldsa65-verify")); verify != "" {
			if !profileValidMLDSA(verify) {
				return nil, false, profileUnsupported("clash: reality mldsa65-verify is not valid")
			}
			r["mldsa65_verify"] = verify
		}
		tls["reality"] = r
		tls["enabled"] = true
	}
	return tls, true, nil
}

// clashCertificatePins is certificateSha256FromPcs: a comma/space separated
// list of 64 hex digits (colons allowed), each converted to standard base64.
func clashCertificatePins(text string) []any {
	var out []any
	for _, item := range strings.FieldsFunc(text, func(r rune) bool { return r == ',' || r == ' ' }) {
		hexText := strings.ReplaceAll(strings.TrimSpace(item), ":", "")
		if len(hexText) != 64 {
			continue
		}
		raw := make([]byte, 32)
		for i := 0; i < 32; i++ {
			value, err := strconv.ParseUint(hexText[i*2:i*2+2], 16, 8)
			if err != nil {
				return nil
			}
			raw[i] = byte(value)
		}
		out = append(out, profileBase64Encode(raw, false, true))
	}
	return out
}

// clashTransport is Transport.parseFromClash for ws/httpupgrade/grpc/http/h2/
// xhttp/mkcp. A host is written the same way as Transport.exportToJson: a Host
// header for ws, a host field elsewhere.
func clashTransport(p clashProxy) (map[string]any, bool, error) {
	network := strings.ToLower(strings.TrimSpace(p.String("network")))
	xhttp := p.Obj("xhttp-opts")
	if network == "xhttp" || xhttp.String("path") != "" {
		return clashXHTTPTransport(p, xhttp)
	}
	kcp := p.Obj("kcp-opts")
	if network == "kcp" || network == "mkcp" || kcp.Has("header-type") || kcp.Has("mtu") {
		return clashKCPTransport(kcp)
	}
	ws := p.Obj("ws-opts")
	wsPath := ws.String("path")
	if wsPath != "" || network == "ws" {
		transport := map[string]any{"type": "ws"}
		if ws.Bool("v2ray-http-upgrade") {
			transport["type"] = "httpupgrade"
		} else {
			if header := ws.String("early-data-header-name"); header != "" {
				transport["early_data_header_name"] = header
			}
			if maxEarly := ws.Int("max-early-data"); maxEarly > 0 {
				transport["max_early_data"] = maxEarly
			}
		}
		if headers, err := clashHeaders(ws, true); err != nil {
			return nil, false, err
		} else if len(headers) > 0 {
			transport["headers"] = headers
		}
		host := clashHeaderHost(ws)
		if host == "" {
			host = p.String("servername")
		}
		if host != "" {
			if transport["type"] == "ws" {
				headers, _ := transport["headers"].(map[string]any)
				if headers == nil {
					headers = map[string]any{}
				}
				headers["Host"] = aceShareHost(host)
				transport["headers"] = headers
			} else {
				// httpupgrade stores the Host as the transport's host field
				// (Transport.exportToJson), not as a headers.Host entry.
				transport["host"] = aceShareHost(host)
			}
		}
		if wsPath != "" {
			transport["path"] = wsPath
		}
		profileClashSplitEarlyData(transport)
		return transport, true, nil
	}
	grpc := p.Obj("grpc-opts").String("grpc-service-name")
	if grpc != "" || network == "grpc" {
		transport := map[string]any{"type": "grpc"}
		if grpc != "" {
			transport["service_name"] = grpc
		}
		return transport, true, nil
	}
	h2 := p.Obj("h2-opts")
	h2Path := h2.String("path")
	if h2Path != "" || network == "h2" {
		transport := map[string]any{"type": "http"}
		if hosts := h2.Strings("host"); len(hosts) > 0 {
			transport["host"] = aceShareHost(hosts[0])
		}
		if h2Path != "" {
			transport["path"] = h2Path
		}
		profileClashSplitEarlyData(transport)
		return transport, true, nil
	}
	http := p.Obj("http-opts")
	httpMethod := http.String("method")
	if httpMethod != "" || network == "http" {
		transport := map[string]any{"type": "http"}
		if hosts := http.StringListMap("headers")["Host"]; len(hosts) > 0 {
			transport["host"] = aceShareHost(hosts[0])
		}
		if paths := http.Strings("path"); len(paths) > 0 {
			transport["path"] = paths[0]
		}
		if httpMethod != "" {
			transport["method"] = httpMethod
		} else {
			// Transport.parseFromClash: method = httpMethod.ifEmpty { "GET" }
			transport["method"] = "GET"
		}
		profileClashSplitEarlyData(transport)
		return transport, true, nil
	}
	// Transport.parseFromClash returns false for a network it does not map
	// (tcp, or a value mihomo alone knows): the profile keeps no transport.
	return nil, false, nil
}

// profileClashSplitEarlyData is Transport.exportToJson's `?ed=` handling: a
// path of the form /x?ed=2048 becomes path /x plus max_early_data and the
// standard Sec-WebSocket-Protocol header name.
func profileClashSplitEarlyData(transport map[string]any) {
	path, _ := transport["path"].(string)
	if !strings.Contains(path, "?ed=") {
		return
	}
	parts := strings.SplitN(path, "?ed=", 2)
	transport["path"] = parts[0]
	if value := profileImportQtInt(parts[1]); value > 0 {
		transport["max_early_data"] = value
	}
	transport["early_data_header_name"] = "Sec-WebSocket-Protocol"
}

// clashXHTTPTransport is Transport.parseFromClash's xhttp branch + exportToJson.
// It mirrors the Kotlin getter set exactly; fields Kotlin does not read (e.g.
// sc-max-each-post-bytes, x-padding-key aliases) are refused rather than
// silently dropped only when they would change the stored form.
func clashXHTTPTransport(p clashProxy, xhttp clashProxy) (map[string]any, bool, error) {
	transport := map[string]any{"type": "xhttp"}
	host := xhttp.String("host")
	// Kotlin's header Host wins over the xhttp host field.
	if headerHost := clashHeaderHost(xhttp); headerHost != "" {
		host = headerHost
	}
	if host != "" {
		transport["host"] = aceShareHost(host)
	}
	if path := xhttp.String("path"); path != "" {
		transport["path"] = path
	}
	mode := strings.TrimSpace(xhttp.String("mode"))
	if mode != "" && !profileXHTTPModeKnown(mode) {
		return nil, false, profileUnsupported("clash: xhttp mode not supported by the core: " + mode)
	}
	if mode != "" {
		transport["mode"] = mode
	}
	xPadding := ""
	if xhttp.Has("x-padding-bytes") {
		xPadding = strings.TrimSpace(xhttp.String("x-padding-bytes"))
	}
	for _, field := range []struct{ key, stored string }{
		{"no-grpc-header", "no_grpc_header"}, {"no-sse-header", "no_sse_header"},
		{"x-padding-obfs-mode", "x_padding_obfs_mode"},
	} {
		if xhttp.Has(field.key) && xhttp.Bool(field.key) {
			transport[field.stored] = true
		}
	}
	for _, field := range []struct{ key, stored string }{
		{"sc-min-posts-interval-ms", "sc_min_posts_interval_ms"},
		{"x-padding-key", "x_padding_key"}, {"x-padding-header", "x_padding_header"},
		{"x-padding-placement", "x_padding_placement"}, {"x-padding-method", "x_padding_method"},
		{"congestion-controller", "congestion_controller"},
	} {
		if value := strings.TrimSpace(xhttp.String(field.key)); value != "" {
			transport[field.stored] = value
		}
	}
	if xhttp.Has("cwnd") {
		if value := xhttp.Int("cwnd"); value > 0 {
			transport["cwnd"] = value
		}
	}
	// Kotlin copies these from the headers map as a pair list; exportToJson
	// writes them back as a JSON object. A Host key is handled above.
	headers, err := clashHeaders(xhttp, false)
	if err != nil {
		return nil, false, err
	}
	if len(headers) > 0 {
		transport["headers"] = headers
	}
	if xPadding == "" {
		xPadding = "100-1000"
	}
	transport["x_padding_bytes"] = xPadding
	return transport, true, nil
}

// clashKCPTransport is Transport.parseFromClash's mkcp branch + exportToJson.
func clashKCPTransport(kcp clashProxy) (map[string]any, bool, error) {
	transport := map[string]any{"type": "mkcp"}
	for _, field := range []struct{ key, stored string }{
		{"mtu", "mtu"}, {"tti", "tti"},
		{"uplink-capacity", "uplink_capacity"}, {"downlink-capacity", "downlink_capacity"},
		{"read-buffer-size", "read_buffer_size"}, {"write-buffer-size", "write_buffer_size"},
	} {
		if value := kcp.Int(field.key); value > 0 {
			transport[field.stored] = value
		}
	}
	if kcp.Bool("congestion") {
		transport["congestion"] = true
	}
	if value := strings.TrimSpace(kcp.String("header-type")); value != "" {
		transport["header_type"] = value
	}
	if value := kcp.String("seed"); value != "" {
		transport["seed"] = value
	}
	return transport, true, nil
}

// clashHeaders converts a ws-opts headers map into the stored headers object.
// A Host key is handled separately (it moves to the host field / Host header).
func clashHeaders(ws clashProxy, wsTransport bool) (map[string]any, error) {
	out := map[string]any{}
	for key, value := range ws.StringMap("headers") {
		if strings.EqualFold(key, "host") {
			continue
		}
		out[key] = value
	}
	_ = wsTransport
	return out, nil
}

func clashHeaderHost(ws clashProxy) string {
	for key, value := range ws.StringMap("headers") {
		if strings.EqualFold(key, "host") {
			return value
		}
	}
	return ""
}

// clashMux is Multiplex.parseFromClash + exportToJson. Kotlin always sets
// unspecified=false, so the exported object is at least {"enabled":false};
// a valid smux protocol/max-streams/connection pair/padding is kept.
func clashMux(p clashProxy) (map[string]any, error) {
	smux := p.Obj("smux")
	enabled := smux.Bool("enabled")
	block := map[string]any{"enabled": enabled}
	if !enabled {
		return block, nil
	}
	if protocol := strings.TrimSpace(smux.String("protocol")); protocol != "" {
		// acceptOptional drops a protocol outside muxProtocols.
		switch protocol {
		case "smux", "yamux", "h2mux":
			block["protocol"] = protocol
		}
	}
	// Kotlin lets max-streams win over the connection pair (parseFromClash).
	if maxStreams := smux.Int("max-streams"); maxStreams > 0 {
		block["max_streams"] = maxStreams
	} else {
		if value := smux.Int("max-connections"); value > 0 {
			block["max_connections"] = value
		}
		if value := smux.Int("min-streams"); value > 0 {
			block["min_streams"] = value
		}
	}
	if smux.Bool("padding") {
		block["padding"] = true
	}
	return block, nil
}

// clashBandwidthMbps is Hysteria.clashBandwidthToMbps for the Clash forms:
// a bare number is Mbps; an optional K/M/G/T prefix and b/B unit scale it.
var clashBandwidthRE = regexp.MustCompile(`^(\d+(?:\.\d+)?)\s*([KMGTkmgt]?)(?:([bB])(?:ps|/s)?|ps)?$`)

func clashBandwidthMbps(text string) int {
	match := clashBandwidthRE.FindStringSubmatch(strings.TrimSpace(text))
	if match == nil {
		return 0
	}
	value, err := strconv.ParseFloat(match[1], 64)
	if err != nil || value <= 0 {
		return 0
	}
	prefix, unit := strings.ToUpper(match[2]), match[3]
	if prefix != "" || unit != "" {
		scale := 1e-6
		switch prefix {
		case "K":
			scale = 1e-3
		case "M":
			scale = 1
		case "G":
			scale = 1e3
		case "T":
			scale = 1e6
		}
		if unit == "B" {
			scale *= 8
		}
		value *= scale
	}
	if value <= 0 {
		return 0
	}
	mbps := int64(value + 0.5)
	if mbps < 1 {
		mbps = 1
	}
	return int(mbps)
}
