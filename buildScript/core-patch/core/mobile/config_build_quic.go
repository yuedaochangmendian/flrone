// QUIC fields for the Stage-2 outbound builder (hysteria/tuic/masque).
//
// QUICFields.parseFromJson reads the flat QUIC keys of an outbound object and
// QUICFields.build fills the empty ones from BuildContext's h2_/quic_ global
// settings; the two receive windows are written as JSON integers when the
// stored text is a bare byte count (memoryBytesJson).
package mobile

import (
	"strconv"
	"strings"
)

type configQUICParams struct {
	idleTimeout                        string
	keepAlivePeriod                    string
	streamReceiveWindow                string
	connectionReceiveWindow            string
	maxConcurrentStreams               int
	initialPacketSize                  int
	disablePathMTUDiscovery            bool
	disablePathMTUDiscoveryUnspecified bool
}

func configQUICDefault() configQUICParams {
	return configQUICParams{disablePathMTUDiscoveryUnspecified: true}
}

// configQUICParse is QUICFields.parseFromJson.
func configQUICParse(object map[string]any) (configQUICParams, error) {
	quic := configQUICDefault()
	if object == nil || len(object) == 0 {
		return quic, nil
	}
	// The QUIC keys share the outbound object with the type's own fields; the
	// per-type parser checks the whole key set, so this function only reads the
	// seven QUIC names.
	if _, present := object["idle_timeout"]; present {
		quic.idleTimeout = strings.TrimSpace(configJSONString(object, "idle_timeout"))
	}
	if _, present := object["keep_alive_period"]; present {
		quic.keepAlivePeriod = strings.TrimSpace(configJSONString(object, "keep_alive_period"))
	}
	if _, present := object["stream_receive_window"]; present {
		quic.streamReceiveWindow = configMemoryBytesText(object["stream_receive_window"])
	}
	if _, present := object["connection_receive_window"]; present {
		quic.connectionReceiveWindow = configMemoryBytesText(object["connection_receive_window"])
	}
	if _, present := object["max_concurrent_streams"]; present {
		quic.maxConcurrentStreams = configJSONInt(object["max_concurrent_streams"])
	}
	if _, present := object["initial_packet_size"]; present {
		quic.initialPacketSize = configJSONInt(object["initial_packet_size"])
	}
	if _, present := object["disable_path_mtu_discovery"]; present {
		quic.disablePathMTUDiscovery = configJSONBoolValue(object["disable_path_mtu_discovery"])
		quic.disablePathMTUDiscoveryUnspecified = false
	}
	return quic, nil
}

// configMemoryBytesText is memoryBytesText: a stored number becomes its digits
// (a negative or fractional one is reported by Kotlin and dropped, which this
// builder mirrors as an empty value), a string is kept as stored.
func configMemoryBytesText(value any) string {
	number, isNumber := value.(float64)
	if !isNumber {
		text, _ := value.(string)
		return text
	}
	if number >= 0 && number == float64(int64(number)) && number < 9.223372036854775807e18 {
		return strconv.FormatInt(int64(number), 10)
	}
	return ""
}

// configQUICExport is QUICFields.exportToJson.
func configQUICExport(quic configQUICParams) map[string]any {
	object := map[string]any{}
	if quic.idleTimeout != "" {
		object["idle_timeout"] = quic.idleTimeout
	}
	if quic.keepAlivePeriod != "" {
		object["keep_alive_period"] = quic.keepAlivePeriod
	}
	if quic.streamReceiveWindow != "" {
		object["stream_receive_window"] = quic.streamReceiveWindow
	}
	if quic.connectionReceiveWindow != "" {
		object["connection_receive_window"] = quic.connectionReceiveWindow
	}
	if quic.maxConcurrentStreams > 0 {
		object["max_concurrent_streams"] = quic.maxConcurrentStreams
	}
	if quic.initialPacketSize > 0 {
		object["initial_packet_size"] = quic.initialPacketSize
	}
	if !quic.disablePathMTUDiscoveryUnspecified {
		object["disable_path_mtu_discovery"] = quic.disablePathMTUDiscovery
	}
	return object
}

// configQUICBuild is QUICFields.build: the global settings fill in whatever the
// profile leaves empty and bare byte counts become JSON numbers.
func configQUICBuild(quic configQUICParams, settings simpleConfigSettings) map[string]any {
	object := configQUICExport(quic)
	if quic.idleTimeout == "" && settings.H2IdleTimeout != "" {
		object["idle_timeout"] = settings.H2IdleTimeout
	}
	if quic.keepAlivePeriod == "" && settings.H2KeepAlivePeriod != "" {
		object["keep_alive_period"] = settings.H2KeepAlivePeriod
	}
	if quic.streamReceiveWindow == "" && settings.H2StreamReceiveWindow != "" {
		object["stream_receive_window"] = settings.H2StreamReceiveWindow
	}
	if quic.connectionReceiveWindow == "" && settings.H2ConnectionReceiveWindow != "" {
		object["connection_receive_window"] = settings.H2ConnectionReceiveWindow
	}
	if quic.maxConcurrentStreams <= 0 && settings.H2MaxConcurrentStreams > 0 {
		object["max_concurrent_streams"] = settings.H2MaxConcurrentStreams
	}
	if quic.initialPacketSize <= 0 && settings.QuicInitialPacketSize > 0 {
		object["initial_packet_size"] = settings.QuicInitialPacketSize
	}
	if quic.disablePathMTUDiscoveryUnspecified && settings.QuicDisablePathMTUDiscovery {
		object["disable_path_mtu_discovery"] = true
	}
	for _, key := range []string{"stream_receive_window", "connection_receive_window"} {
		if value, present := object[key]; present {
			text, _ := value.(string)
			object[key] = configMemoryBytesJSON(strings.TrimSpace(text))
		}
	}
	return object
}

// configMemoryBytesJSON is memoryBytesJson: a bare digit string becomes a JSON
// integer; anything else stays a string.
func configMemoryBytesJSON(text string) any {
	if text == "" {
		return text
	}
	for index := 0; index < len(text); index++ {
		if text[index] < '0' || text[index] > '9' {
			return text
		}
	}
	parsed, err := strconv.ParseInt(text, 10, 64)
	if err != nil {
		return text
	}
	return parsed
}
