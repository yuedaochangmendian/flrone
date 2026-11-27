// TUIC: the QUIC outbound with flat QUIC keys and a mandatory TLS block
// (types/Tuic.kt, tuic.cpp).
package mobile

import (
	"strings"
)

type configTuicParams struct {
	uuid              string
	password          string
	congestionControl string
	udpRelayMode      string
	udpOverStream     bool
	zeroRTTHandshake  bool
	heartbeat         string
	tls               configTLSParams
	quic              configQUICParams
}

// configTuicCongestion is canonicalTuicCongestion. tuicImportCongestion keeps
// an unknown value when no diagnostics scope is active (DB loads), so this
// builder must not filter it; the core applies its own default.
func configTuicCongestion(value string) string {
	return strings.ReplaceAll(strings.ToLower(strings.TrimSpace(value)), " ", "_")
}

func configTuicRelayMode(value string) string {
	mode := strings.ToLower(strings.TrimSpace(value))
	if mode != "native" && mode != "quic" {
		return ""
	}
	return mode
}

func configParseTuic(object map[string]any) (configTuicParams, error) {
	params := configTuicParams{
		tls:  configTLSDefault(),
		quic: configQUICDefault(),
	}
	// Tuic.init: uTLS is never emitted.
	params.tls.utls.supported = false

	if _, present := object["uuid"]; present {
		params.uuid = configJSONString(object, "uuid")
	}
	if _, present := object["password"]; present {
		params.password = configJSONString(object, "password")
	}
	if _, present := object["congestion_control"]; present {
		params.congestionControl = configTuicCongestion(configJSONString(object, "congestion_control"))
	}
	if _, present := object["udp_relay_mode"]; present {
		params.udpRelayMode = configTuicRelayMode(configJSONString(object, "udp_relay_mode"))
	}
	if _, present := object["udp_over_stream"]; present {
		params.udpOverStream = configJSONBoolValue(object["udp_over_stream"])
	}
	if _, present := object["zero_rtt_handshake"]; present {
		params.zeroRTTHandshake = configJSONBoolValue(object["zero_rtt_handshake"])
	}
	if _, present := object["heartbeat"]; present {
		params.heartbeat = strings.TrimSpace(configJSONString(object, "heartbeat"))
	}
	if _, present := object["tls"]; present {
		tls, err := configTLSParse(configJSONObjectValue(object["tls"]))
		if err != nil {
			return params, err
		}
		tls.utls.supported = false
		params.tls = tls
	}
	quic, err := configQUICParse(object)
	if err != nil {
		return params, err
	}
	params.quic = quic
	return params, nil
}

func configBuildTuic(out configOutbound, params configTuicParams, settings simpleConfigSettings) (map[string]any, error) {
	object := map[string]any{"type": "tuic"}
	for key, value := range configOutboundBaseObject(out) {
		object[key] = value
	}
	if params.uuid != "" {
		object["uuid"] = params.uuid
	}
	if params.password != "" {
		object["password"] = params.password
	}
	if params.congestionControl != "" {
		object["congestion_control"] = params.congestionControl
	}
	if !params.udpOverStream && params.udpRelayMode != "" {
		object["udp_relay_mode"] = params.udpRelayMode
	}
	if params.udpOverStream {
		object["udp_over_stream"] = true
	}
	if params.zeroRTTHandshake {
		object["zero_rtt_handshake"] = true
	}
	if params.heartbeat != "" {
		object["heartbeat"] = params.heartbeat
	}
	tls, err := configTLSBuild(params.tls, settings, false)
	if err != nil {
		return nil, err
	}
	if len(tls) > 0 {
		object["tls"] = tls
	}
	for key, value := range configQUICBuild(params.quic, settings) {
		object[key] = value
	}
	return object, nil
}
