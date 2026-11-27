// V2Ray transport for the Stage-2 outbound builder.
//
// Transport.parseFromJson reads the stored `transport` object (type aliases,
// ws Host promotion, the xhttp and mkcp sub-objects) and Transport.build writes
// it back the way sing-box takes it: an http comma list becomes an array, keys
// belonging to another transport type are dropped, and xhttp always carries a
// non-zero x_padding_bytes range.
package mobile

import (
	"strings"
)

const configTransportDefaultPadding = "100-1000"

// configTransportKeys is TRANSPORT_KEYS: the keys each sing-box transport
// accepts, which Transport.build filters the exported object against.
var configTransportKeys = map[string][]string{
	"http":        {"host", "path", "method", "headers", "idle_timeout", "ping_timeout"},
	"ws":          {"path", "headers", "max_early_data", "early_data_header_name"},
	"quic":        {},
	"grpc":        {"service_name", "idle_timeout", "ping_timeout", "permit_without_stream"},
	"httpupgrade": {"host", "path", "headers"},
	"xhttp": {
		"host", "path", "headers", "mode", "x_padding_bytes", "no_grpc_header", "no_sse_header",
		"sc_max_each_post_bytes", "sc_min_posts_interval_ms", "sc_max_buffered_posts", "sc_stream_up_server_secs",
		"x_padding_obfs_mode", "x_padding_key", "x_padding_header", "x_padding_placement", "x_padding_method",
		"uplink_http_method", "session_placement", "session_key", "seq_placement", "seq_key",
		"uplink_data_placement", "uplink_data_key", "uplink_chunk_size", "session_id_table", "session_id_length",
		"congestion_controller", "cwnd", "xmux",
	},
	"mkcp": {
		"mtu", "tti", "uplink_capacity", "downlink_capacity", "congestion",
		"read_buffer_size", "write_buffer_size", "header_type", "seed",
	},
}

type configTransportParams struct {
	typeName            string
	host                string
	path                string
	method              string
	headers             map[string]string
	idleTimeout         string
	pingTimeout         string
	maxEarlyData        int
	earlyDataHeaderName string
	serviceName         string

	// xhttp (V2RayXHTTPOptions)
	mode                 string
	xPaddingBytes        string
	noGRPCHeader         bool
	noSSEHeader          bool
	scMaxEachPostBytes   string
	scMinPostsIntervalMS string
	scMaxBufferedPosts   int64
	scStreamUpServerSecs string
	xPaddingObfsMode     bool
	xPaddingKey          string
	xPaddingHeader       string
	xPaddingPlacement    string
	xPaddingMethod       string
	uplinkHTTPMethod     string
	sessionPlacement     string
	sessionKey           string
	seqPlacement         string
	seqKey               string
	uplinkDataPlacement  string
	uplinkDataKey        string
	uplinkChunkSize      string
	sessionIDTable       string
	sessionIDLength      string
	congestionController string
	cwnd                 int
	xmux                 map[string]any

	// mkcp (V2RayKCPOptions)
	mtu              int
	tti              int
	uplinkCapacity   int
	downlinkCapacity int
	congestion       bool
	readBufferSize   int
	writeBufferSize  int
	headerType       string
	seed             string
}

// configSingBoxTransportType is singBoxTransportType: the exact lower-case
// name, with check's aliases.
func configSingBoxTransportType(value string) string {
	trimmed := strings.ToLower(strings.TrimSpace(value))
	switch trimmed {
	case "websocket":
		return "ws"
	case "kcp":
		return "mkcp"
	}
	return trimmed
}

// configTransportParse is Transport.parseFromJson.
func configTransportParse(object map[string]any) (configTransportParams, error) {
	transport := configTransportParams{headers: map[string]string{}}
	if object == nil {
		return transport, nil
	}
	allowed := configKeysAllowed(
		"type", "host", "path", "method", "headers", "idle_timeout", "ping_timeout",
		"max_early_data", "early_data_header_name", "service_name",
		// xhttp
		"mode", "x_padding_bytes", "no_grpc_header", "no_sse_header", "sc_max_each_post_bytes",
		"sc_min_posts_interval_ms", "sc_max_buffered_posts", "sc_stream_up_server_secs",
		"x_padding_obfs_mode", "x_padding_key", "x_padding_header", "x_padding_placement",
		"x_padding_method", "uplink_http_method", "session_placement", "session_key", "seq_placement",
		"seq_key", "uplink_data_placement", "uplink_data_key", "uplink_chunk_size", "session_id_table",
		"session_id_length", "congestion_controller", "cwnd", "xmux",
		// mkcp
		"mtu", "tti", "uplink_capacity", "downlink_capacity", "congestion", "read_buffer_size",
		"write_buffer_size", "header_type", "seed",
	)
	if err := configCheckKeys(object, allowed, "transport"); err != nil {
		return transport, err
	}
	if _, present := object["type"]; present {
		transport.typeName = configSingBoxTransportType(configJSONString(object, "type"))
	}
	if _, present := object["host"]; present {
		if items, ok := object["host"].([]any); ok {
			parts := make([]string, 0, len(items))
			for _, item := range items {
				if text, ok := item.(string); ok {
					parts = append(parts, text)
				} else {
					parts = append(parts, "")
				}
			}
			transport.host = strings.Join(parts, ",")
		} else {
			transport.host = configJSONString(object, "host")
		}
	}
	if _, present := object["path"]; present {
		transport.path = configJSONString(object, "path")
	}
	if _, present := object["method"]; present {
		transport.method = strings.TrimSpace(configJSONString(object, "method"))
	}
	if headers := configJSONObjectValue(object["headers"]); headers != nil {
		values := make(map[string]string, len(headers))
		for key, value := range headers {
			values[key] = configJSONVariantToStringValue(value)
		}
		if transport.typeName == "ws" {
			if hostValue, present := headers["Host"]; present {
				if text, ok := hostValue.(string); ok {
					transport.host = text
				} else if items, ok := hostValue.([]any); ok {
					for _, item := range items {
						if text, ok := item.(string); ok {
							transport.host = text
							break
						}
					}
				}
				delete(values, "Host")
			}
		}
		transport.headers = values
	}
	if _, present := object["idle_timeout"]; present {
		transport.idleTimeout = strings.TrimSpace(configJSONString(object, "idle_timeout"))
	}
	if _, present := object["ping_timeout"]; present {
		transport.pingTimeout = strings.TrimSpace(configJSONString(object, "ping_timeout"))
	}
	if _, present := object["max_early_data"]; present {
		transport.maxEarlyData = configJSONInt(object["max_early_data"])
	}
	if _, present := object["early_data_header_name"]; present {
		transport.earlyDataHeaderName = configJSONString(object, "early_data_header_name")
	}
	if _, present := object["service_name"]; present {
		transport.serviceName = configJSONString(object, "service_name")
	}
	if transport.typeName == "xhttp" {
		configTransportParseXHTTP(object, &transport)
	}
	if transport.typeName == "mkcp" {
		configTransportParseKCP(object, &transport)
	}
	return transport, nil
}

// configJSONVariantToStringValue is JsonValues.toStringValue: only a string
// keeps its value, everything else reads as "".
func configJSONVariantToStringValue(value any) string {
	text, _ := value.(string)
	return text
}

func configTransportParseXHTTP(object map[string]any, transport *configTransportParams) {
	if _, present := object["mode"]; present {
		transport.mode = strings.TrimSpace(configJSONString(object, "mode"))
	}
	if _, present := object["x_padding_bytes"]; present {
		transport.xPaddingBytes = strings.TrimSpace(configJSONString(object, "x_padding_bytes"))
	}
	if _, present := object["no_grpc_header"]; present {
		transport.noGRPCHeader = configJSONBoolValue(object["no_grpc_header"])
	}
	if _, present := object["no_sse_header"]; present {
		transport.noSSEHeader = configJSONBoolValue(object["no_sse_header"])
	}
	if _, present := object["sc_max_each_post_bytes"]; present {
		transport.scMaxEachPostBytes = strings.TrimSpace(configJSONString(object, "sc_max_each_post_bytes"))
	}
	if _, present := object["sc_min_posts_interval_ms"]; present {
		transport.scMinPostsIntervalMS = strings.TrimSpace(configJSONString(object, "sc_min_posts_interval_ms"))
	}
	if _, present := object["sc_max_buffered_posts"]; present {
		transport.scMaxBufferedPosts = configJSONInteger(object["sc_max_buffered_posts"])
	}
	if _, present := object["sc_stream_up_server_secs"]; present {
		transport.scStreamUpServerSecs = strings.TrimSpace(configJSONString(object, "sc_stream_up_server_secs"))
	}
	if _, present := object["x_padding_obfs_mode"]; present {
		transport.xPaddingObfsMode = configJSONBoolValue(object["x_padding_obfs_mode"])
	}
	if _, present := object["x_padding_key"]; present {
		transport.xPaddingKey = configJSONString(object, "x_padding_key")
	}
	if _, present := object["x_padding_header"]; present {
		transport.xPaddingHeader = configJSONString(object, "x_padding_header")
	}
	if _, present := object["x_padding_placement"]; present {
		transport.xPaddingPlacement = configJSONString(object, "x_padding_placement")
	}
	if _, present := object["x_padding_method"]; present {
		transport.xPaddingMethod = configJSONString(object, "x_padding_method")
	}
	if _, present := object["uplink_http_method"]; present {
		transport.uplinkHTTPMethod = configJSONString(object, "uplink_http_method")
	}
	if _, present := object["session_placement"]; present {
		transport.sessionPlacement = configJSONString(object, "session_placement")
	}
	if _, present := object["session_key"]; present {
		transport.sessionKey = configJSONString(object, "session_key")
	}
	if _, present := object["seq_placement"]; present {
		transport.seqPlacement = configJSONString(object, "seq_placement")
	}
	if _, present := object["seq_key"]; present {
		transport.seqKey = configJSONString(object, "seq_key")
	}
	if _, present := object["uplink_data_placement"]; present {
		transport.uplinkDataPlacement = configJSONString(object, "uplink_data_placement")
	}
	if _, present := object["uplink_data_key"]; present {
		transport.uplinkDataKey = configJSONString(object, "uplink_data_key")
	}
	if _, present := object["uplink_chunk_size"]; present {
		transport.uplinkChunkSize = strings.TrimSpace(configJSONString(object, "uplink_chunk_size"))
	}
	if _, present := object["session_id_table"]; present {
		transport.sessionIDTable = configJSONString(object, "session_id_table")
	}
	if _, present := object["session_id_length"]; present {
		transport.sessionIDLength = strings.TrimSpace(configJSONString(object, "session_id_length"))
	}
	if _, present := object["congestion_controller"]; present {
		transport.congestionController = configJSONString(object, "congestion_controller")
	}
	if _, present := object["cwnd"]; present {
		transport.cwnd = configJSONInt(object["cwnd"])
	}
	if xmux := configJSONObjectValue(object["xmux"]); xmux != nil {
		transport.xmux = xmux
	}
}

func configTransportParseKCP(object map[string]any, transport *configTransportParams) {
	if _, present := object["mtu"]; present {
		transport.mtu = configJSONInt(object["mtu"])
	}
	if _, present := object["tti"]; present {
		transport.tti = configJSONInt(object["tti"])
	}
	if _, present := object["uplink_capacity"]; present {
		transport.uplinkCapacity = configJSONInt(object["uplink_capacity"])
	}
	if _, present := object["downlink_capacity"]; present {
		transport.downlinkCapacity = configJSONInt(object["downlink_capacity"])
	}
	if _, present := object["congestion"]; present {
		transport.congestion = configJSONBoolValue(object["congestion"])
	}
	if _, present := object["read_buffer_size"]; present {
		transport.readBufferSize = configJSONInt(object["read_buffer_size"])
	}
	if _, present := object["write_buffer_size"]; present {
		transport.writeBufferSize = configJSONInt(object["write_buffer_size"])
	}
	if _, present := object["header_type"]; present {
		transport.headerType = configJSONString(object, "header_type")
	}
	if _, present := object["seed"]; present {
		transport.seed = configJSONString(object, "seed")
	}
}

// configTransportExport is Transport.exportToJson.
func configTransportExport(transport configTransportParams) (map[string]any, error) {
	object := map[string]any{}
	if transport.typeName == "" || transport.typeName == "tcp" {
		return object, nil
	}
	if transport.typeName == "xhttp" {
		object["type"] = "xhttp"
		if transport.host != "" {
			object["host"] = configACEHost(transport.host)
		}
		if transport.path != "" {
			object["path"] = transport.path
		}
		if transport.mode != "" {
			object["mode"] = transport.mode
		}
		padding := transport.xPaddingBytes
		if padding == "" {
			padding = configTransportDefaultPadding
		}
		object["x_padding_bytes"] = padding
		if transport.noGRPCHeader {
			object["no_grpc_header"] = true
		}
		if transport.noSSEHeader {
			object["no_sse_header"] = true
		}
		if transport.scMaxEachPostBytes != "" {
			object["sc_max_each_post_bytes"] = transport.scMaxEachPostBytes
		}
		if transport.scMinPostsIntervalMS != "" {
			object["sc_min_posts_interval_ms"] = transport.scMinPostsIntervalMS
		}
		if transport.scMaxBufferedPosts > 0 {
			object["sc_max_buffered_posts"] = transport.scMaxBufferedPosts
		}
		if transport.scStreamUpServerSecs != "" {
			object["sc_stream_up_server_secs"] = transport.scStreamUpServerSecs
		}
		if transport.xPaddingObfsMode {
			object["x_padding_obfs_mode"] = true
		}
		if transport.xPaddingKey != "" {
			object["x_padding_key"] = transport.xPaddingKey
		}
		if transport.xPaddingHeader != "" {
			object["x_padding_header"] = transport.xPaddingHeader
		}
		if transport.xPaddingPlacement != "" {
			object["x_padding_placement"] = transport.xPaddingPlacement
		}
		if transport.xPaddingMethod != "" {
			object["x_padding_method"] = transport.xPaddingMethod
		}
		if transport.uplinkHTTPMethod != "" {
			object["uplink_http_method"] = transport.uplinkHTTPMethod
		}
		if transport.sessionPlacement != "" {
			object["session_placement"] = transport.sessionPlacement
		}
		if transport.sessionKey != "" {
			object["session_key"] = transport.sessionKey
		}
		if transport.seqPlacement != "" {
			object["seq_placement"] = transport.seqPlacement
		}
		if transport.seqKey != "" {
			object["seq_key"] = transport.seqKey
		}
		if transport.uplinkDataPlacement != "" {
			object["uplink_data_placement"] = transport.uplinkDataPlacement
		}
		if transport.uplinkDataKey != "" {
			object["uplink_data_key"] = transport.uplinkDataKey
		}
		if transport.uplinkChunkSize != "" {
			object["uplink_chunk_size"] = transport.uplinkChunkSize
		}
		if transport.sessionIDTable != "" {
			object["session_id_table"] = transport.sessionIDTable
		}
		if transport.sessionIDLength != "" {
			object["session_id_length"] = transport.sessionIDLength
		}
		if transport.congestionController != "" {
			object["congestion_controller"] = transport.congestionController
		}
		if transport.cwnd > 0 {
			object["cwnd"] = transport.cwnd
		}
		if len(transport.headers) > 0 {
			object["headers"] = configHeadersObject(transport.headers)
		}
		if len(transport.xmux) > 0 {
			object["xmux"] = configCopyJSONValue(transport.xmux)
		}
		return object, nil
	}
	if transport.typeName == "mkcp" {
		object["type"] = "mkcp"
		if transport.mtu > 0 {
			object["mtu"] = transport.mtu
		}
		if transport.tti > 0 {
			object["tti"] = transport.tti
		}
		if transport.uplinkCapacity > 0 {
			object["uplink_capacity"] = transport.uplinkCapacity
		}
		if transport.downlinkCapacity > 0 {
			object["downlink_capacity"] = transport.downlinkCapacity
		}
		if transport.congestion {
			object["congestion"] = true
		}
		if transport.readBufferSize > 0 {
			object["read_buffer_size"] = transport.readBufferSize
		}
		if transport.writeBufferSize > 0 {
			object["write_buffer_size"] = transport.writeBufferSize
		}
		if transport.headerType != "" {
			object["header_type"] = transport.headerType
		}
		if transport.seed != "" {
			object["seed"] = transport.seed
		}
		return object, nil
	}
	object["type"] = transport.typeName
	if strings.Contains(transport.path, "?ed=") {
		before, after := configSplitEarlyData(transport.path)
		object["path"] = before
		object["max_early_data"] = configQtToInt(after)
		object["early_data_header_name"] = "Sec-WebSocket-Protocol"
	} else {
		if transport.path != "" {
			object["path"] = transport.path
		}
		if transport.maxEarlyData > 0 {
			object["max_early_data"] = transport.maxEarlyData
		}
		if transport.earlyDataHeaderName != "" {
			object["early_data_header_name"] = transport.earlyDataHeaderName
		}
	}
	if transport.method != "" {
		object["method"] = transport.method
	}
	if len(transport.headers) > 0 {
		object["headers"] = configHeadersObject(transport.headers)
	}
	if transport.host != "" {
		if transport.typeName == "http" || transport.typeName == "httpupgrade" {
			object["host"] = configACEHost(transport.host)
		}
		if transport.typeName == "ws" {
			headers, _ := object["headers"].(map[string]any)
			if headers == nil {
				headers = map[string]any{}
			}
			headers["Host"] = configACEHost(transport.host)
			object["headers"] = headers
		}
	}
	if transport.idleTimeout != "" {
		object["idle_timeout"] = transport.idleTimeout
	}
	if transport.pingTimeout != "" {
		object["ping_timeout"] = transport.pingTimeout
	}
	if transport.serviceName != "" {
		object["service_name"] = transport.serviceName
	}
	return object, nil
}

// configTransportBuild is Transport.build: the http comma list becomes an
// array, keys of another type are dropped, and xhttp gets a default range.
func configTransportBuild(transport configTransportParams) (map[string]any, error) {
	object, err := configTransportExport(transport)
	if err != nil {
		return nil, err
	}
	if transport.typeName == "http" {
		if exported := configJSONString(object, "host"); strings.Contains(exported, ",") {
			hosts := configSplitSkipEmpty(exported, ",")
			items := make([]any, 0, len(hosts))
			for _, host := range hosts {
				if trimmed := strings.TrimSpace(host); trimmed != "" {
					items = append(items, trimmed)
				}
			}
			object["host"] = items
		}
	}
	if keys, known := configTransportKeys[transport.typeName]; known {
		allowed := configKeysAllowed(keys...)
		for key := range object {
			if key != "type" && !allowed[key] {
				delete(object, key)
			}
		}
	}
	if transport.typeName == "xhttp" && configJSONString(object, "x_padding_bytes") == "" {
		object["x_padding_bytes"] = configTransportDefaultPadding
	}
	return object, nil
}

// configSplitEarlyData is `path.split("?ed=")` followed by [0] / [1].
func configSplitEarlyData(path string) (string, string) {
	index := strings.Index(path, "?ed=")
	if index < 0 {
		return path, ""
	}
	before := path[:index]
	rest := path[index+len("?ed="):]
	if next := strings.Index(rest, "?ed="); next >= 0 {
		rest = rest[:next]
	}
	return before, rest
}

func configHeadersObject(headers map[string]string) map[string]any {
	object := make(map[string]any, len(headers))
	for key, value := range headers {
		object[key] = value
	}
	return object
}

// configCopyJSONValue is JsonValues.deepCopy for a value already decoded from
// the stored document (objects and arrays are copied so a caller cannot mutate
// the parsed row).
func configCopyJSONValue(value any) any {
	switch typed := value.(type) {
	case map[string]any:
		copied := make(map[string]any, len(typed))
		for key, item := range typed {
			copied[key] = configCopyJSONValue(item)
		}
		return copied
	case []any:
		copied := make([]any, 0, len(typed))
		for _, item := range typed {
			copied = append(copied, configCopyJSONValue(item))
		}
		return copied
	}
	return value
}
