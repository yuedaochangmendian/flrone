// profileNewOutbound's stored-form templates.
//
// Throne's node editor creates a node from OutboundFactory.newByType(type), then
// stores Outbound.exportToJson: the compact stored document the row keeps in
// NodeRow.outbound_json, not a kernel option object. This file carries the blank
// document for every type the Go config builder supports and the Kotlin factory
// can create, byte for byte what `OutboundFactory.newByType(type).exportToJson()`
// answers on the pinned tree.
//
// The bytes are not derived from this file's own reasoning: each template is the
// Kotlin model's zero value (Vless.encryption = "none", Vmess.packet_encoding =
// "xudp", Hysteria's always-written empty tls block, Masque's init defaults, ...).
// TestProfileNewOutboundTemplates pins them on the Go side and
// ProfileStoredGoParityTest pins the same literals against the running Kotlin
// oracle, so a model default change fails on both sides instead of drifting.
//
// The list is the intersection of two closed sets:
//   - OutboundFactory's creatable types minus UNSUPPORTED_TYPES (tailscale is not
//     ported, extracore is desktop-only);
//   - the types the kernel registry can load. A type absent from both the
//     outbound and the endpoint registry in this build refuses the template, so
//     a kernel without (say) QUIC cannot seed a node it could never start.
//
// `custom`, `chain` and `autoselector` are Throne's own stored constructs, not
// kernel outbound types; the config builder expands them, so they carry no
// registry check.
package mobile

import (
	"context"
	"fmt"
	"strings"

	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	"github.com/sagernet/sing/service"
)

// profileNewOutboundTypes is OutboundFactory.ALL_TYPES minus tailscale/extracore,
// in the factory's order, with the hysteria2 alias kept as an input name. That is
// 25 types: the 21 configOutboundSpecs entries (hysteria2 included) plus direct,
// custom, chain and autoselector.
var profileNewOutboundTypes = []string{
	"socks", "http", "shadowsocks", "chain", "autoselector", "vmess", "trojan",
	"vless", "hysteria", "hysteria2", "tuic", "juicity", "trusttunnel", "anytls",
	"mieru", "snell", "shadowtls", "wireguard", "masque", "openvpn", "openconnect",
	"ssh", "custom", "naive", "direct",
}

// profileNewOutboundAliases is OutboundFactory.canonicalType for the two stored
// aliases. hysteria2 canonicalises to Hysteria, whose blank protocol_version is
// "1": a fresh hysteria2 node therefore exports type "hysteria" (the populated
// node switches the type once the editor sets protocol version 2).
var profileNewOutboundAliases = map[string]string{
	"hysteria2":      "hysteria",
	"openvpn-client": "openvpn",
}

// profileNewOutboundTemplates is the canonical blank stored document per
// canonical type. Every literal below is a Kotlin exportToJson().toCompact()
// byte string for the model's zero value; see the file comment.
var profileNewOutboundTemplates = map[string]string{
	"direct":      `{"type":"direct"}`,
	"http":        `{"type":"http"}`,
	"socks":       `{"type":"socks"}`,
	"shadowsocks": `{"type":"shadowsocks"}`,
	"vmess":       `{"packet_encoding":"xudp","type":"vmess"}`,
	"vless":       `{"encryption":"none","packet_encoding":"xudp","type":"vless"}`,
	"trojan":      `{"type":"trojan"}`,
	"hysteria":    `{"tls":{},"type":"hysteria"}`,
	"tuic":        `{"type":"tuic"}`,
	"juicity":     `{"type":"juicity"}`,
	"trusttunnel": `{"type":"trusttunnel"}`,
	// AnyTls's constructor defaults are always written; Tls is always written,
	// even empty (anyTLS.cpp:77-88).
	"anytls": `{"idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"tls":{},"type":"anytls"}`,
	// Snell/Mieru/ShadowTLS always write their version/transport.
	"snell":     `{"type":"snell","version":4}`,
	"mieru":     `{"transport":"TCP","type":"mieru"}`,
	"shadowtls": `{"type":"shadowtls","version":1}`,
	// WireGuard's mtu default and Masque's init block (port 443, TLS on, the
	// Cloudflare hostname) are written because the models write every non-zero
	// default.
	"wireguard": `{"mtu":1420,"type":"wireguard"}`,
	"masque":    `{"mtu":1280,"server_port":443,"tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}`,
	// OpenVPN and OpenConnect always write these two routing defaults.
	"openvpn":     `{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openvpn"}`,
	"openconnect": `{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openconnect"}`,
	"ssh":         `{"type":"ssh"}`,
	// naive's constructor turns TLS on; naiveTls() always writes enabled.
	"naive": `{"tls":{"enabled":true},"type":"naive"}`,
	// The three Throne stored-only shapes write every key, empty values included.
	"custom": `{"config":"","name":"","subtype":"","type":"custom"}`,
	"chain":  `{"list":[],"name":"","type":"chain"}`,
	"autoselector": `{"active_size":8,"balance":false,"balance_interval_sec":30,` +
		`"balance_mode":"rotate","bench_interval_sec":600,"build_limit":300,` +
		`"connectivity_url":"","country_filter":"","dial_retries":2,` +
		`"exclude_unavailable":true,"expected":3,"gid":-1,"gids":[],"history":[],` +
		`"interrupt_on_switch":true,"interval_sec":300,"last_built":[],` +
		`"last_built_at":0,"max_rtt_ms":0,"name":"","name_filter":"","pinned_id":-1,` +
		`"pool":[],"pool_cap":1000,"pool_ranked_at":0,"result_validity_mins":1440,` +
		`"sampling":10,"test_url":"","tolerance_ms":300,"type":"autoselector",` +
		`"watch_interval_sec":15}`,
}

// profileNewOutboundKernel says where the kernel registers a type: "outbound",
// "endpoint", or "" for a Throne stored-only construct the config builder
// expands itself. It keeps the registry check honest without pretending chain,
// custom and autoselector are kernel types.
//
// The kernel name differs from the stored name for the endpoint types: Throne
// stores masque/openvpn while the kernel registers masque-client and
// openvpn-client (constant/proxy.go). The config builder emits those names too
// (config_build_openvpn.go, config_build_openconnect.go).
type profileNewOutboundKernelEntry struct {
	registry string
	name     string
}

var profileNewOutboundKernel = map[string]profileNewOutboundKernelEntry{
	"direct":       {registry: "outbound", name: "direct"},
	"http":         {registry: "outbound", name: "http"},
	"socks":        {registry: "outbound", name: "socks"},
	"shadowsocks":  {registry: "outbound", name: "shadowsocks"},
	"vmess":        {registry: "outbound", name: "vmess"},
	"vless":        {registry: "outbound", name: "vless"},
	"trojan":       {registry: "outbound", name: "trojan"},
	"hysteria":     {registry: "outbound", name: "hysteria"},
	"tuic":         {registry: "outbound", name: "tuic"},
	"juicity":      {registry: "outbound", name: "juicity"},
	"anytls":       {registry: "outbound", name: "anytls"},
	"shadowtls":    {registry: "outbound", name: "shadowtls"},
	"snell":        {registry: "outbound", name: "snell"},
	"ssh":          {registry: "outbound", name: "ssh"},
	"mieru":        {registry: "outbound", name: "mieru"},
	"trusttunnel":  {registry: "outbound", name: "trusttunnel"},
	"naive":        {registry: "outbound", name: "naive"},
	"wireguard":    {registry: "endpoint", name: "wireguard"},
	"masque":       {registry: "endpoint", name: "masque-client"},
	"openvpn":      {registry: "endpoint", name: "openvpn-client"},
	"openconnect":  {registry: "endpoint", name: "openconnect"},
	"custom":       {},
	"chain":        {},
	"autoselector": {},
}

// profileNewOutboundTemplateContext carries the two registries the capability
// check reads. It is separate from profileCodecContext because the template
// path never decodes an outbound; only the descriptor tables are consulted.
func profileNewOutboundTemplateContext() context.Context {
	ctx := service.ContextWith[option.OutboundOptionsRegistry](context.Background(), include.OutboundRegistry())
	return service.ContextWith[option.EndpointOptionsRegistry](ctx, include.EndpointRegistry())
}

// newProfileOutboundTemplate answers the blank stored document for one type.
// A type outside the table is refused with the full supported list; a type whose
// kernel registry entry is missing in this build is refused too, because a
// template for a type the kernel cannot load would open the editor on a node
// that can never start.
func newProfileOutboundTemplate(ctx context.Context, outboundType string) (string, error) {
	canonical := outboundType
	if aliased, ok := profileNewOutboundAliases[outboundType]; ok {
		canonical = aliased
	}
	template, ok := profileNewOutboundTemplates[canonical]
	if !ok {
		return "", fmt.Errorf("profile.newOutbound: unsupported type %q (want %s)",
			outboundType, strings.Join(profileNewOutboundTypes, ", "))
	}
	entry, ok := profileNewOutboundKernel[canonical]
	if !ok {
		return "", fmt.Errorf("profile.newOutbound: type %q has no kernel registry kind", canonical)
	}
	switch entry.registry {
	case "":
		return template, nil
	case "outbound":
		registry := service.FromContext[option.OutboundOptionsRegistry](ctx)
		if registry == nil {
			return "", fmt.Errorf("profile.newOutbound: the kernel exposes no outbound options registry")
		}
		if _, loaded := registry.CreateOptions(entry.name); !loaded {
			return "", fmt.Errorf("profile.newOutbound: this kernel build has no %q outbound", entry.name)
		}
	case "endpoint":
		registry := service.FromContext[option.EndpointOptionsRegistry](ctx)
		if registry == nil {
			return "", fmt.Errorf("profile.newOutbound: the kernel exposes no endpoint options registry")
		}
		if _, loaded := registry.CreateOptions(entry.name); !loaded {
			return "", fmt.Errorf("profile.newOutbound: this kernel build has no %q endpoint", entry.name)
		}
	default:
		return "", fmt.Errorf("profile.newOutbound: type %q has an unknown registry kind", canonical)
	}
	return template, nil
}
