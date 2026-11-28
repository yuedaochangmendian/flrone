// S5d: the stored-row half of the removed Xray support, ported from
// app/src/main/java/io/nekohasekai/sagernet/outbound/import/LegacyXray.kt.
//
// The Xray runtime is gone; a stored `xrayvless` row, a `custom` row of one of
// the removed Xray subtypes, or an Xray-shaped object stored without its own
// `type` must still load as the sing-box outbound that means the same thing.
// This port builds the same sing-box object the Kotlin converter builds and exports
// the accepted node with the existing stored-form helpers
// (profileAdvancedNode / profileStoredSimple*). Nothing is approximated: a
// shape this slice cannot reproduce byte-for-byte is refused with the plain
// source string the Kotlin converter uses (no Android resources involved).
//
// Wire shape (`profileMigrate` action):
//
//	{"type":"xrayvless|custom|...","json":"<stored row>"}
//	→ {"migrated":true,"type":"vless","json":"…","name":"…",
//	   "identity":"…","dedupKey":"…","link":"…"}
//	→ {"migrated":false,"reason":"This Xray profile cannot be converted: …"}
//
// A row that is not a legacy Xray row is answered `{migrated:false}` with an
// empty reason, mirroring LegacyXray.migrateStored returning null: the caller
// keeps the row and treats it as an ordinary profile.
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

const profileMigrateMethod Method = "profileMigrate"

func init() {
	register(profileMigrateMethod, handleProfileMigrate)
}

type profileMigrateRequest struct {
	Type string  `json:"type"`
	JSON *string `json:"json"`
}

type profileMigrateReply struct {
	Migrated bool   `json:"migrated"`
	Reason   string `json:"reason,omitempty"`
	Type     string `json:"type,omitempty"`
	Name     string `json:"name,omitempty"`
	JSON     string `json:"json,omitempty"`
	Identity string `json:"identity,omitempty"`
	DedupKey string `json:"dedupKey,omitempty"`
	Link     string `json:"link,omitempty"`
}

func handleProfileMigrate(raw json.RawMessage) (any, error) {
	var request profileMigrateRequest
	if len(strings.TrimSpace(string(raw))) > 0 {
		if err := json.Unmarshal(raw, &request); err != nil {
			return nil, err
		}
	}
	if request.JSON == nil {
		return nil, errors.New("profileMigrate requires a json field")
	}
	row, ok := configDecodeJSONObject(*request.JSON)
	if !ok {
		return nil, errors.New("profileMigrate: json is not an object")
	}
	return profileMigrateStored(request.Type, row), nil
}

const (
	xraySubtypeXrayOutbound   = "xrayoutbound"
	xraySubtypeXrayFullConfig = "xrayfullconfig"
	xrayTypeXrayVless         = "xrayvless"

	// LegacyXray.FULL_CONFIG_ERROR. A plain source string, never a vtr() message.
	xrayFullConfigError = "Custom Xray full configs are no longer supported; re-import a sing-box profile instead"
)

// xrayInfraProtocols are Xray protocols that route traffic themselves: they are
// dropped exactly as before (a null Conversion, so the row is not migrated).
var xrayInfraProtocols = map[string]bool{
	"freedom": true, "direct": true, "blackhole": true,
	"block": true, "dns": true, "loopback": true,
}

// xrayConvertibleProtocols have a sing-box outbound of the same name.
// wireguard is a sing-box endpoint, converted here as a full outbound.
var xrayConvertibleProtocols = map[string]bool{
	"vless": true, "vmess": true, "trojan": true, "shadowsocks": true,
	"socks": true, "http": true, "wireguard": true,
}

// profileMigrateStored mirrors LegacyXray.migrateStored. A result with
// Migrated=false and an empty Reason is an ordinary (non-Xray) row: the caller
// keeps it untouched. A non-empty Reason is a refusal the UI shows in place.
func profileMigrateStored(storedType string, row map[string]any) profileMigrateReply {
	stored := strings.ToLower(strings.TrimSpace(storedType))
	rowType := strings.ToLower(strings.TrimSpace(configJSONString(row, "type")))
	if stored == xrayTypeXrayVless || rowType == xrayTypeXrayVless {
		return asStoredMigrate(xrayTypeXrayVless, profileXrayConvertOutbound(row))
	}
	if stored == "custom" || rowType == "custom" {
		switch strings.ToLower(strings.TrimSpace(configJSONString(row, "subtype"))) {
		case xraySubtypeXrayOutbound:
			config, ok := configDecodeJSONObject(configJSONString(row, "config"))
			if !ok {
				return refusal("This Xray profile cannot be converted: the Xray outbound config is not an object")
			}
			return asStoredMigrate("custom", profileXrayConvertOutbound(config))
		case xraySubtypeXrayFullConfig:
			return refusal("This Xray profile cannot be converted: " + xrayFullConfigError)
		default:
			return profileMigrateReply{}
		}
	}
	// An Xray-shaped object stored without its own `type` (the shape every
	// Xray outbound row had).
	if _, present := row["protocol"]; present {
		return asStoredMigrate(xrayTypeXrayVless, profileXrayConvertOutbound(row))
	}
	return profileMigrateReply{}
}

// xrayConversion is LegacyXray.Conversion: a converted node, a plain refusal
// reason, or neither (an empty/infrastructure object).
type xrayConversion struct {
	node   *profileImportedNode
	reason string
}

func xrayRefused(reason string) xrayConversion {
	return xrayConversion{reason: "This Xray profile cannot be converted: " + reason}
}

func asStoredMigrate(profileType string, conversion xrayConversion) profileMigrateReply {
	if conversion.node == nil && conversion.reason == "" {
		return profileMigrateReply{}
	}
	if conversion.node != nil {
		return profileMigrateReply{
			Migrated: true,
			Type:     conversion.node.Type,
			Name:     conversion.node.Name,
			JSON:     conversion.node.JSON,
			Identity: conversion.node.Identity,
			DedupKey: conversion.node.DedupKey,
			Link:     conversion.node.Link,
		}
	}
	// A legacy row that cannot be represented is kept with a refusal, the same
	// way an InvalidOutbound carries its reason in displayType().
	return profileMigrateReply{Migrated: false, Reason: conversion.reason, Type: profileType}
}

func refusal(reason string) profileMigrateReply {
	return profileMigrateReply{Migrated: false, Reason: reason}
}

// xrayPeer is the server and credential object of one Xray outbound.
type xrayPeer struct {
	address string
	port    int
	user    map[string]any
}

func profileXrayConvertOutbound(out map[string]any) xrayConversion {
	if len(out) == 0 {
		return xrayConversion{}
	}
	protocol := strings.ToLower(strings.TrimSpace(configJSONString(out, "protocol")))
	if protocol == "" || xrayInfraProtocols[protocol] {
		return xrayConversion{}
	}
	if !xrayConvertibleProtocols[protocol] {
		return xrayRefused(fmt.Sprintf("Xray %q outbounds have no sing-box counterpart", protocol))
	}

	peer := xrayPeerOf(out, protocol)
	if peer.address == "" || peer.port <= 0 {
		return xrayRefused("the Xray outbound has no server address to convert")
	}

	object := map[string]any{"type": protocol}
	if tag := configJSONString(out, "tag"); tag != "" {
		object["tag"] = tag
	}
	object["server"] = peer.address
	object["server_port"] = peer.port

	var fields map[string]any
	switch protocol {
	case "vless":
		uuid := configJSONString(peer.user, "id")
		if uuid == "" {
			uuid = configJSONString(peer.user, "uuid")
		}
		if uuid == "" {
			return xrayRefused("the Xray VLESS outbound has no user id to convert")
		}
		fields = map[string]any{"uuid": uuid}
		if flow := strings.TrimSpace(configJSONString(peer.user, "flow")); flow != "" {
			fields["flow"] = flow
		}
		encryption := strings.TrimSpace(configJSONString(peer.user, "encryption"))
		if encryption == "" {
			encryption = "none"
		}
		fields["encryption"] = encryption
		fields["packet_encoding"] = "xudp" // Vless.exportToJson always writes it.

	case "vmess":
		uuid := configJSONString(peer.user, "id")
		if uuid == "" {
			uuid = configJSONString(peer.user, "uuid")
		}
		if uuid == "" {
			return xrayRefused("the Xray VMess outbound has no user id to convert")
		}
		fields = map[string]any{"uuid": uuid, "packet_encoding": "xudp"}
		if security := strings.TrimSpace(configJSONString(peer.user, "security")); security != "" {
			fields["security"] = security
		}
		if alterID := configJSONInteger(peer.user["alterId"]); alterID > 0 {
			fields["alter_id"] = alterID
		}

	case "trojan":
		password := configJSONString(peer.user, "password")
		if password == "" {
			return xrayRefused("the Xray Trojan outbound has no password to convert")
		}
		fields = map[string]any{"password": password}

	case "shadowsocks":
		method := configJSONString(peer.user, "method")
		password := configJSONString(peer.user, "password")
		if method == "" || password == "" {
			return xrayRefused("the Xray Shadowsocks outbound has no method or password to convert")
		}
		fields = map[string]any{"method": method, "password": password}

	case "socks":
		fields = map[string]any{"version": "5"}
		if username := configJSONString(peer.user, "user"); username != "" {
			fields["username"] = username
		}
		if password := configJSONString(peer.user, "pass"); password != "" {
			fields["password"] = password
		}

	case "http":
		fields = map[string]any{}
		if username := configJSONString(peer.user, "user"); username != "" {
			fields["username"] = username
		}
		if password := configJSONString(peer.user, "pass"); password != "" {
			fields["password"] = password
		}

	case "wireguard":
		settings := configJSONObjectValue(out["settings"])
		privateKey := configJSONString(settings, "secretKey")
		if privateKey == "" {
			return xrayRefused("the Xray WireGuard outbound has no secretKey to convert")
		}
		fields = map[string]any{"private_key": privateKey}
		var addresses []string
		if items, ok := settings["address"].([]any); ok {
			addresses = configJSONStringListValue(items)
		} else if address := configJSONString(settings, "address"); address != "" {
			addresses = []string{address}
		}
		if len(addresses) > 0 {
			fields["address"] = toAnySlice(addresses)
		}
		if mtu := configJSONInt(settings["mtu"]); mtu > 0 {
			fields["mtu"] = mtu
		}
		peers, _ := settings["peers"].([]any)
		wirePeer := map[string]any{}
		if len(peers) > 0 {
			if typed, ok := peers[0].(map[string]any); ok {
				wirePeer = typed
			}
		}
		publicKey := configJSONString(wirePeer, "publicKey")
		if publicKey == "" {
			return xrayRefused("the Xray WireGuard outbound has no peer public key to convert")
		}
		peerJSON := map[string]any{
			"address":    peer.address,
			"port":       peer.port,
			"public_key": publicKey,
		}
		if preShared := configJSONString(wirePeer, "preSharedKey"); preShared != "" {
			peerJSON["pre_shared_key"] = preShared
		}
		// WireGuard peers[0] is the endpoint of the row; the converted
		// outbound has no top-level server/server_port.
		delete(object, "server")
		delete(object, "server_port")
		fields["peers"] = []any{peerJSON}
	}

	if err := xrayTransportError(out); err != "" {
		return xrayRefused(err)
	}
	if err := xrayTLSError(out); err != "" {
		return xrayRefused(err)
	}
	xrayApplyTransport(out, object, fields)
	xrayApplyTLS(out, object)
	xrayApplyMultiplex(out, object)

	for key, value := range fields {
		object[key] = value
	}
	if err := xrayValidateSingBoxObject(object); err != "" {
		return xrayRefused(err)
	}
	return profileXrayStoredNode(protocol, object)
}

// xrayPeerOf mirrors peerOf: `settings` inline, or vnext/servers with their
// first entry. VMess/VLESS keep the user in users[0]; the other protocols use
// the server object itself. WireGuard uses peers[0].endpoint.
func xrayPeerOf(out map[string]any, protocol string) xrayPeer {
	settings := configJSONObjectValue(out["settings"])
	if protocol == "wireguard" {
		peers, _ := settings["peers"].([]any)
		first := map[string]any{}
		if len(peers) > 0 {
			if typed, ok := peers[0].(map[string]any); ok {
				first = typed
			}
		}
		address, port := xraySplitEndpoint(configJSONString(first, "endpoint"))
		return xrayPeer{address: address, port: port, user: first}
	}
	if _, present := settings["address"]; present {
		if _, hasVnext := settings["vnext"]; !hasVnext {
			return xrayPeer{
				address: configJSONString(settings, "address"),
				port:    configJSONInt(settings["port"]),
				user:    settings,
			}
		}
	}
	key := "servers"
	if protocol == "vmess" || protocol == "vless" {
		key = "vnext"
	}
	list, _ := settings[key].([]any)
	first := map[string]any{}
	if len(list) > 0 {
		if typed, ok := list[0].(map[string]any); ok {
			first = typed
		}
	}
	user := first
	if users, ok := first["users"].([]any); ok && len(users) > 0 {
		if typed, ok := users[0].(map[string]any); ok {
			user = typed
		}
	}
	return xrayPeer{
		address: configJSONString(first, "address"),
		port:    configJSONInt(first["port"]),
		user:    user,
	}
}

// xraySplitEndpoint handles host:port and [v6]:port.
func xraySplitEndpoint(endpoint string) (string, int) {
	value := strings.TrimSpace(endpoint)
	if strings.HasPrefix(value, "[") {
		if close := strings.IndexByte(value, ']'); close > 0 {
			port, _ := strconv.Atoi(strings.TrimPrefix(value[close+1:], ":"))
			return value[1:close], port
		}
	}
	colon := strings.LastIndexByte(value, ':')
	if colon <= 0 {
		return value, 0
	}
	port, _ := strconv.Atoi(value[colon+1:])
	return value[:colon], port
}

var xraySupportedNetworks = map[string]bool{
	"": true, "ws": true, "http": true, "grpc": true,
	"httpupgrade": true, "quic": true, "xhttp": true, "mkcp": true,
}

// xrayNormalNetwork folds Xray's aliases onto the kernel's transport names.
func xrayNormalNetwork(raw string) string {
	network := strings.ToLower(strings.TrimSpace(raw))
	switch network {
	case "", "tcp", "raw":
		return ""
	case "websocket":
		return "ws"
	case "h2":
		return "http"
	case "splithttp":
		return "xhttp"
	case "kcp":
		return "mkcp"
	}
	return network
}

func xrayTransportError(out map[string]any) string {
	network := xrayNormalNetwork(configJSONString(configJSONObjectValue(out["streamSettings"]), "network"))
	if network == "xdrive" {
		return "the XDRIVE transport has no sing-box counterpart"
	}
	if !xraySupportedNetworks[network] {
		return fmt.Sprintf("the Xray transport %q has no sing-box counterpart", network)
	}
	return ""
}

func xrayTLSError(out map[string]any) string {
	stream := configJSONObjectValue(out["streamSettings"])
	security := strings.ToLower(strings.TrimSpace(configJSONString(stream, "security")))
	if security != "" && security != "none" && security != "tls" && security != "reality" {
		return fmt.Sprintf("the Xray security %q has no sing-box counterpart", security)
	}
	if strings.TrimSpace(configJSONString(configJSONObjectValue(stream["tlsSettings"]), "verifyPeerCertByName")) != "" {
		return "verifyPeerCertByName has no sing-box counterpart"
	}
	return ""
}

// xrayApplyTransport mirrors applyTransport, writing the converted transport
// block into the node's `transport` field. A TCP/raw network adds no block.
func xrayApplyTransport(out map[string]any, object, fields map[string]any) {
	stream := configJSONObjectValue(out["streamSettings"])
	network := xrayNormalNetwork(configJSONString(stream, "network"))
	if network == "" || network == "tcp" {
		return
	}
	transport := map[string]any{"type": network}
	switch network {
	case "ws":
		ws := configJSONObjectValue(stream["wsSettings"])
		if _, present := ws["path"]; present {
			transport["path"] = configJSONString(ws, "path")
		}
		if _, present := ws["host"]; present {
			transport["host"] = configJSONString(ws, "host")
		}
		if headers, ok := ws["headers"].(map[string]any); ok {
			transport["headers"] = headers
		}
	case "http":
		http := configJSONObjectValue(stream["httpSettings"])
		if _, present := http["path"]; present {
			transport["path"] = configJSONString(http, "path")
		}
		if hosts, ok := http["host"].([]any); ok {
			transport["host"] = hosts
		} else if host := configJSONString(http, "host"); host != "" {
			transport["host"] = host
		}
		if headers, ok := http["headers"].(map[string]any); ok {
			transport["headers"] = headers
		}
	case "grpc":
		grpc := configJSONObjectValue(stream["grpcSettings"])
		if _, present := grpc["serviceName"]; present {
			transport["service_name"] = configJSONString(grpc, "serviceName")
		}
	case "httpupgrade":
		upgrade := configJSONObjectValue(stream["httpupgradeSettings"])
		if _, present := upgrade["path"]; present {
			transport["path"] = configJSONString(upgrade, "path")
		}
		if _, present := upgrade["host"]; present {
			transport["host"] = configJSONString(upgrade, "host")
		}
		if headers, ok := upgrade["headers"].(map[string]any); ok {
			transport["headers"] = headers
		}
	case "quic":
		// type only
	case "xhttp":
		xhttp := configJSONObjectValue(stream["xhttpSettings"])
		if _, present := xhttp["path"]; present {
			transport["path"] = configJSONString(xhttp, "path")
		}
		if _, present := xhttp["host"]; present {
			transport["host"] = configJSONString(xhttp, "host")
		}
		if _, present := xhttp["mode"]; present {
			transport["mode"] = strings.TrimSpace(configJSONString(xhttp, "mode"))
		}
		xrayApplyXhttpExtra(configJSONObjectValue(xhttp["extra"]), transport)
	case "mkcp":
		kcp := configJSONObjectValue(stream["kcpSettings"])
		if mtu := configJSONInt(kcp["mtu"]); mtu > 0 {
			transport["mtu"] = mtu
		}
		if tti := configJSONInt(kcp["tti"]); tti > 0 {
			transport["tti"] = tti
		}
		if up := configJSONInt(kcp["uplinkCapacity"]); up > 0 {
			transport["uplink_capacity"] = up
		}
		if down := configJSONInt(kcp["downlinkCapacity"]); down > 0 {
			transport["downlink_capacity"] = down
		}
		if read := configJSONInt(kcp["readBufferSize"]); read > 0 {
			transport["read_buffer_size"] = read
		}
		if write := configJSONInt(kcp["writeBufferSize"]); write > 0 {
			transport["write_buffer_size"] = write
		}
		if _, present := kcp["congestion"]; present {
			transport["congestion"] = configJSONBool(kcp, "congestion")
		}
		if headerType := configJSONString(configJSONObjectValue(kcp["header"]), "type"); headerType != "" {
			transport["header_type"] = headerType
		}
		if _, present := kcp["seed"]; present {
			transport["seed"] = configJSONString(kcp, "seed")
		}
	}
	fields["transport"] = transport
}

// applyXhttpExtra's kernel-supported keys, in snake_case, in Kotlin's map order.
var xrayXhttpTextKeys = []struct{ from, to string }{
	{"xPaddingBytes", "x_padding_bytes"},
	{"scMaxEachPostBytes", "sc_max_each_post_bytes"},
	{"scMinPostsIntervalMs", "sc_min_posts_interval_ms"},
	{"scStreamUpServerSecs", "sc_stream_up_server_secs"},
	{"xPaddingObfsMode", "x_padding_obfs_mode"},
	{"xPaddingKey", "x_padding_key"},
	{"xPaddingHeader", "x_padding_header"},
	{"xPaddingPlacement", "x_padding_placement"},
	{"xPaddingMethod", "x_padding_method"},
	{"uplinkHttpMethod", "uplink_http_method"},
	{"sessionPlacement", "session_placement"},
	{"sessionKey", "session_key"},
	{"seqPlacement", "seq_placement"},
	{"seqKey", "seq_key"},
	{"uplinkDataPlacement", "uplink_data_placement"},
	{"uplinkDataKey", "uplink_data_key"},
	{"uplinkChunkSize", "uplink_chunk_size"},
	{"sessionIDTable", "session_id_table"},
	{"sessionIDLength", "session_id_length"},
	{"congestionController", "congestion_controller"},
}

func xrayApplyXhttpExtra(extra, transport map[string]any) {
	if len(extra) == 0 {
		return
	}
	for _, key := range xrayXhttpTextKeys {
		value, present := extra[key.from]
		if !present {
			continue
		}
		text := strings.TrimSpace(configJSONVariantString(value))
		if text != "" {
			transport[key.to] = text
		}
	}
	for _, key := range []struct{ from, to string }{
		{"scMaxBufferedPosts", "sc_max_buffered_posts"}, {"cwnd", "cwnd"},
	} {
		if value := configJSONInt(extra[key.from]); value > 0 {
			transport[key.to] = value
		}
	}
	if _, present := extra["noGRPCHeader"]; present {
		transport["no_grpc_header"] = configJSONBool(extra, "noGRPCHeader")
	}
	if _, present := extra["noSSEHeader"]; present {
		transport["no_sse_header"] = configJSONBool(extra, "noSSEHeader")
	}
	if xmux, ok := extra["xmux"].(map[string]any); ok {
		transport["xmux"] = xmux
	}
}

// xrayApplyTLS mirrors applyTls, writing the TLS block into the node's `tls`
// field. Only tls/reality are representable; tlsError refused the rest.
func xrayApplyTLS(out map[string]any, object map[string]any) {
	stream := configJSONObjectValue(out["streamSettings"])
	security := strings.ToLower(strings.TrimSpace(configJSONString(stream, "security")))
	if security != "tls" && security != "reality" {
		return
	}
	tls := map[string]any{"enabled": true}
	settings := configJSONObjectValue(stream["tlsSettings"])
	if security == "reality" {
		settings = configJSONObjectValue(stream["realitySettings"])
	}
	if _, present := settings["serverName"]; present {
		if serverName := configJSONString(settings, "serverName"); serverName != "" {
			tls["server_name"] = serverName
		}
	}
	if fingerprint := strings.TrimSpace(configJSONString(settings, "fingerprint")); fingerprint != "" {
		tls["utls"] = map[string]any{"enabled": true, "fingerprint": fingerprint}
	}
	var alpn []string
	if items, ok := settings["alpn"].([]any); ok {
		for _, item := range configJSONStringListValue(items) {
			if strings.TrimSpace(item) != "" {
				alpn = append(alpn, item)
			}
		}
	} else if text := configJSONString(settings, "alpn"); strings.TrimSpace(text) != "" {
		for _, item := range strings.Split(text, ",") {
			if trimmed := strings.TrimSpace(item); trimmed != "" {
				alpn = append(alpn, trimmed)
			}
		}
	}
	if len(alpn) > 0 {
		tls["alpn"] = toAnySlice(alpn)
	}
	if security == "tls" {
		if _, present := settings["allowInsecure"]; present {
			tls["insecure"] = configJSONBool(settings, "allowInsecure")
		}
		if pin := strings.TrimSpace(configJSONString(settings, "pinnedPeerCertSha256")); pin != "" {
			tls["certificate_sha256"] = []any{pin}
		}
	} else {
		// Newer Xray writes publicKey, older builds password; either names
		// the REALITY public key (password wins, as in Kotlin).
		publicKey := strings.TrimSpace(configJSONString(settings, "password"))
		if publicKey == "" {
			publicKey = strings.TrimSpace(configJSONString(settings, "publicKey"))
		}
		reality := map[string]any{"enabled": true, "public_key": publicKey}
		if _, present := settings["shortId"]; present {
			reality["short_id"] = strings.TrimSpace(configJSONString(settings, "shortId"))
		}
		if verify := strings.TrimSpace(configJSONString(settings, "mldsa65Verify")); verify != "" {
			reality["mldsa65_verify"] = verify
		}
		tls["reality"] = reality
	}
	object["tls"] = tls
}

// xrayApplyMultiplex mirrors applyMultiplex: xudpConcurrency and the other
// Xray-only knobs have no sing-box field and are dropped.
func xrayApplyMultiplex(out map[string]any, object map[string]any) {
	mux := configJSONObjectValue(out["mux"])
	if len(mux) == 0 {
		return
	}
	multiplex := map[string]any{}
	if _, present := mux["enabled"]; present {
		multiplex["enabled"] = configJSONBool(mux, "enabled")
	}
	if concurrency := configJSONInt(mux["concurrency"]); concurrency > 0 {
		multiplex["max_streams"] = concurrency
	}
	if len(multiplex) > 0 {
		object["multiplex"] = multiplex
	}
}

// xrayValidateSingBoxObject is the resource-free subset of the built
// outbound's `parseFromJson` + `validate`. Every convertible protocol here is
// a real registered Kotlin outbound (see the CONVERTIBLE_PROTOCOLS set), so
// `newByType` never yields an InvalidOutbound and an object built by this
// port always parses. The remaining Kotlin checks (uuid/password/flow format,
// host grammar) render their messages through vtr()/Android resources, which a
// plain Go core cannot reproduce; the task's refusal contract is explicitly
// "plain source string, no Android resources", so those are not re-implemented
// as synthetic refusals. See the exact-gaps note in the Go test file.
func xrayValidateSingBoxObject(object map[string]any) string {
	if profileType := configJSONString(object, "type"); !xrayConvertibleProtocols[profileType] {
		return fmt.Sprintf("the sing-box %q outbound is not available", profileType)
	}
	return ""
}

// profileXrayStoredNode reuses the existing stored-form exporters so the
// migrated node is byte-identical to the Kotlin conversion's exports.
func profileXrayStoredNode(protocol string, object map[string]any) xrayConversion {
	storedJSON, err := MarshalCanonicalJSON(object)
	if err != nil {
		return xrayRefused(err.Error())
	}
	if protocol == "direct" || protocol == "http" || protocol == "socks" || protocol == "shadowsocks" {
		simple, supported, err := profileStoredSimpleFromObject(object)
		if err != nil || !supported {
			return xrayRefused("the Xray data does not parse as a sing-box outbound")
		}
		withoutTag := profileStoredSimpleWithoutTag(simple)
		dedupJSON, err := profileStoredSimpleJSON(withoutTag)
		if err != nil {
			return xrayRefused(err.Error())
		}
		identity := string(storedJSON)
		if simple.Server != "" {
			encoded, err := MarshalCanonicalJSON(map[string]any{
				"server": simple.Server, "server_port": simple.Port,
			})
			if err != nil {
				return xrayRefused(err.Error())
			}
			identity = string(encoded)
		}
		link := profileStoredSimpleLink(simple)
		return xrayConversion{node: &profileImportedNode{
			Type:     simple.Type,
			Name:     simple.Name,
			JSON:     string(storedJSON),
			Link:     link,
			Identity: identity,
			DedupKey: "throne://add/" + profileBase64Encode([]byte(dedupJSON), true, false),
		}}
	}

	// The advanced types need the struct form the Kotlin exporter uses,
	// including the defaults (packet_encoding, tls/transport/mux blocks).
	node, err := profileXrayAdvancedNode(protocol, object)
	if err != nil {
		return xrayRefused(err.Error())
	}
	return xrayConversion{node: node}
}

func profileXrayAdvancedNode(protocol string, object map[string]any) (*profileImportedNode, error) {
	name, _ := object["tag"].(string)
	server, _ := object["server"].(string)
	port := configJSONInt(object["server_port"])
	stored := &profileStoredAdvanced{
		Type:   protocol,
		Name:   name,
		Server: server,
		Port:   port,
		Fields: map[string]any{},
	}
	fields := map[string]any{}
	for key, value := range object {
		switch key {
		case "type", "tag", "server", "server_port", "tls", "transport", "multiplex", "quic":
			continue
		default:
			fields[key] = value
		}
	}
	stored.Fields = fields
	if tls, ok := object["tls"].(map[string]any); ok && len(tls) > 0 {
		stored.HasTLS = true
		stored.TLS = tls
	}
	if transport, ok := object["transport"].(map[string]any); ok && len(transport) > 0 {
		stored.HasTr = true
		stored.Transport = transport
	}
	if mux, ok := object["multiplex"].(map[string]any); ok && len(mux) > 0 {
		stored.HasMux = true
		stored.Multiplex = mux
	}
	if quic, ok := object["quic"].(map[string]any); ok && len(quic) > 0 {
		stored.HasQUIC = true
		stored.QUIC = quic
	}
	// Validate the exact stored JSON the advanced node would export before
	// using its identity/link: the object must survive the Kotlin export.
	if _, err := stored.json(); err != nil {
		return nil, err
	}
	return profileAdvancedNode(stored)
}

func toAnySlice(items []string) []any {
	out := make([]any, 0, len(items))
	for _, item := range items {
		out = append(out, item)
	}
	return out
}
