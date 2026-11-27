// The built-in WARP hop of the config builder: WarpHop in the Kotlin tree
// (generate.cpp getWarpProfile :475-524 and the identity check :559-571).
//
// With enable_warp the main chain becomes [WARP as `proxy`, the exit hop as
// `warp-bypass`, ...]: the synthetic profile id below never exists in
// profiles.json, the endpoint is rebuilt from the warp_* settings and the chain
// builder treats it like any other hop. warp_mode picks the WireGuard identity
// (optionally as AmneziaWG) or the MASQUE endpoint; both are sing-box endpoints
// and therefore land in `endpoints`, never in `outbounds`.
package mobile

import (
	"fmt"
	"strings"
)

const (
	// configWarpProfileID is WarpHop.PROFILE_ID: the synthetic hop id no stored
	// profile can collide with (profile ids are positive).
	configWarpProfileID int64 = -2408

	// configWarpMissingError is WarpHop.MISSING_ERROR.
	configWarpMissingError = "Warp is enabled but its config has not been generated. Please generate the Warp config first in Routing Settings."

	configWarpMasqueDefaultPort    = 443
	configWarpWireGuardDefaultPort = 2408

	// configWarpMasqueDefaultSNI is the Masque constructor's TLS server name
	// (masque.h:21-26); a non-empty warp_masque_sni overrides it.
	configWarpMasqueDefaultSNI = "consumer-masque.cloudflareclient.com"

	configWarpWireGuardMTU = 1280
	configWarpMasqueMTU    = 1280
)

// configWarpMissing is WarpHop.missing: whether the identity of the active
// warp_mode is incomplete; amnezia also needs its packets.
func configWarpMissing(settings simpleConfigSettings) bool {
	if settings.WarpMode == "masque" {
		return settings.WarpMasquePrivateKey == "" || settings.WarpMasquePeerPublicKey == "" ||
			settings.WarpMasqueEp == "" || len(settings.WarpMasqueIfcAddrs) == 0
	}
	return settings.WarpPrivateKey == "" || settings.WarpPublicKey == "" ||
		settings.WarpEp == "" || len(settings.WarpIfcAddrs) == 0 ||
		(settings.WarpMode == "amnezia" && len(settings.WarpAmneziaPackets) == 0)
}

// configWarpOutbound is WarpHop.outbound: the synthetic "warp" profile, an
// endpoint in every mode.
func configWarpOutbound(settings simpleConfigSettings) configOutbound {
	if settings.WarpMode == "masque" {
		host, port := configWarpSplitEndpoint(settings.WarpMasqueEp, configWarpMasqueDefaultPort)
		serverName := settings.WarpMasqueSni
		if serverName == "" {
			// The Masque constructor already names the WARP SNI; WarpHop only
			// overwrites it when the setting is non-empty.
			serverName = configWarpMasqueDefaultSNI
		}
		tls := configTLSDefault()
		tls.enabled = true
		tls.serverName = serverName
		params := configMasqueParams{
			privateKey:    settings.WarpMasquePrivateKey,
			peerPublicKey: settings.WarpMasquePeerPublicKey,
			address:       settings.WarpMasqueIfcAddrs,
			mtu:           configWarpMasqueMTU,
			tls:           tls,
			quic:          configQUICDefault(),
		}
		switch settings.WarpMasqueHTTPMode {
		case 1:
			params.httpVersion = 3
			params.disableVersionFallback = true
		case 2:
			params.httpVersion = 2
		}
		return configOutbound{
			id:          configWarpProfileID,
			profileType: "masque",
			name:        "warp",
			server:      host,
			serverPort:  port,
			params:      params,
		}
	}

	host, port := configWarpSplitEndpoint(settings.WarpEp, configWarpWireGuardDefaultPort)
	reserved := make([]int, 0, len(settings.WarpReserved))
	for _, item := range settings.WarpReserved {
		reserved = append(reserved, configWarpToInt(item))
	}
	params := configWireGuardParams{
		privateKey: settings.WarpPrivateKey,
		// WarpHop assigns the addresses verbatim: WireGuard.fixAddress only runs
		// on the parse paths, so a bare address stays bare here as in Kotlin.
		address: settings.WarpIfcAddrs,
		mtu:     configWarpWireGuardMTU,
		peer: configWireGuardPeer{
			address:             host,
			port:                port,
			publicKey:           settings.WarpPublicKey,
			reserved:            reserved,
			persistentKeepalive: "10",
		},
	}
	if settings.WarpMode == "amnezia" {
		packets := settings.WarpAmneziaPackets
		packet := func(index int) string {
			if index < len(packets) {
				return packets[index]
			}
			return ""
		}
		params.amnezia = configWireGuardAmnezia{
			enabled: true,
			jc:      4,
			jmin:    40,
			jmax:    70,
			// Cloudflare expects the standard WireGuard headers.
			h1: "1", h2: "2", h3: "3", h4: "4",
			i1: packet(0), i2: packet(1), i3: packet(2), i4: packet(3), i5: packet(4),
		}
	}
	return configOutbound{
		id:          configWarpProfileID,
		profileType: "wireguard",
		name:        "warp",
		params:      params,
	}
}

// configWarpSplitEndpoint is WarpHop.splitEndpoint: host, host:port, [v6] or
// [v6]:port; a bare IPv6 address has no port.
func configWarpSplitEndpoint(endpoint string, defaultPort int) (string, int) {
	text := strings.TrimSpace(endpoint)
	host := text
	portText := ""
	if strings.HasPrefix(text, "[") {
		closeIndex := strings.Index(text, "]")
		if closeIndex < 0 {
			return host, defaultPort
		}
		host = text[1:closeIndex]
		if rest := text[closeIndex+1:]; strings.HasPrefix(rest, ":") {
			portText = rest[1:]
		}
	} else if strings.Count(text, ":") == 1 {
		separator := strings.LastIndex(text, ":")
		host = text[:separator]
		portText = text[separator+1:]
	}
	parsed := configWarpToInt(portText)
	if parsed >= 1 && parsed <= 65535 {
		return host, parsed
	}
	return host, defaultPort
}

// configWarpToInt is QtStrings.toInt: a whole decimal number, else 0.
func configWarpToInt(text string) int {
	value, _ := configQtToIntOrNull(text)
	return value
}

// --- masque endpoint ----------------------------------------------------------

// configMasqueParams is the Masque endpoint build state. Only the built-in WARP
// hop constructs it: a stored masque profile is refused by
// configOutboundTypeKeys until a fixture proves that parser.
type configMasqueParams struct {
	privateKey             string
	peerPublicKey          string
	address                []string
	mtu                    int
	httpVersion            int
	disableVersionFallback bool
	tls                    configTLSParams
	quic                   configQUICParams
}

// configMasqueDialsTCP is OutboundChecks.dialsTcp for Masque: HTTP/2 pins a TCP
// carriage, and HTTP/3 falls back to it unless the fallback is disabled.
func configMasqueDialsTCP(httpVersion int, disableVersionFallback bool) bool {
	return httpVersion == 2 || !disableVersionFallback
}

// configBuildMasque is Masque.build.
func configBuildMasque(out configOutbound, params configMasqueParams, settings simpleConfigSettings) (map[string]any, error) {
	if params.privateKey == "" {
		return nil, fmt.Errorf("[MASQUE] warp: the private key is empty")
	}
	if len(params.address) == 0 {
		return nil, fmt.Errorf("[MASQUE] warp: no address is set")
	}
	tls := params.tls
	tls.enabled = true
	customFragment := settings.FragmentImplementation == "custom" && tls.fragmentEffectivelyOn(settings) &&
		configMasqueDialsTCP(params.httpVersion, params.disableVersionFallback)

	object := map[string]any{"type": "masque"}
	if out.name != "" {
		object["tag"] = out.name
	}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if customFragment {
		if err := configApplyFragmentBlock(object, settings); err != nil {
			return nil, err
		}
	}
	object["private_key"] = params.privateKey
	if params.peerPublicKey != "" {
		object["peer_public_key"] = params.peerPublicKey
	}
	object["address"] = configNonBlankStrings(params.address)
	if params.mtu > 0 {
		object["mtu"] = params.mtu
	}
	if params.httpVersion != 0 {
		object["http_version"] = params.httpVersion
	}
	if params.disableVersionFallback {
		object["disable_version_fallback"] = true
	}
	// REALITY, the only TLS build error here, is dropped.
	tlsObject, err := configTLSBuild(tls, settings, customFragment)
	if err != nil {
		return nil, err
	}
	delete(tlsObject, "reality")
	object["tls"] = tlsObject
	for key, value := range configQUICBuild(params.quic, settings) {
		object[key] = value
	}
	return object, nil
}
