package io.nekohasekai.sagernet.outbound.common

import io.nekohasekai.sagernet.R
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.import.ClashProxy
import io.nekohasekai.sagernet.document.json.QtStrings
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.json.JsonValues
import io.nekohasekai.sagernet.document.link.Hosts
import io.nekohasekai.sagernet.document.link.LinkParser
import io.nekohasekai.sagernet.document.link.LinkQuery
import io.nekohasekai.sagernet.document.link.ParsedLink
import io.nekohasekai.sagernet.validation.CommonChecks
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.ParseDiag
import io.nekohasekai.sagernet.validation.Severity
import io.nekohasekai.sagernet.validation.Validation
import io.nekohasekai.sagernet.validation.acceptOptional
import io.nekohasekai.sagernet.validation.addIssue
import io.nekohasekai.sagernet.validation.readQueryInt
import io.nekohasekai.sagernet.validation.vtr

/** singBoxTransports (transport.h): sing-box V2RayTransportOptions types; tcp (or empty) means no transport. */
val SING_BOX_TRANSPORTS = listOf("tcp", "ws", "httpupgrade", "http", "grpc", "quic", "xhttp", "mkcp")

/** SingBoxTransportType (transport.h): sing-box matches types exactly in lower case; websocket is Xray's alias, which share links and v2rayN JSON carry too, and kcp is the kernel's alias of mkcp. */
fun singBoxTransportType(type: String): String {
    val t = type.trim().lowercase()
    return when (t) {
        "websocket" -> "ws"
        "kcp" -> "mkcp"
        else -> t
    }
}

/** The xhttp modes of V2RayXHTTPOptions; empty is the core's default (auto). */
val XHTTP_MODES = listOf("", "auto", "packet-up", "stream-up", "stream-one")

/** The header types of V2RayKCPOptions; empty is the core's default (none). */
val KCP_HEADER_TYPES = listOf("", "none", "srtp", "utp", "wechat-video", "dtls", "wireguard")

/** Share links spell the KCP bool as 1/true/yes. */
private fun linkBool(value: String): Boolean = when (value.trim().lowercase()) {
    "1", "true", "yes" -> true
    else -> false
}

/** The core refuses a zero x_padding_bytes range, so xhttp always carries a non-zero one. */
private const val DEFAULT_X_PADDING_BYTES = "100-1000"

/**
 * TlsForTransport (transport.cpp): sing-quic dials the quic transport with a std TLS config, which a uTLS one
 * refuses, so uTLS is dropped there. REALITY keeps it, since it cannot run without uTLS; validate refuses that profile.
 */
fun tlsForTransport(tls: JsonObject, transportType: String): JsonObject {
    if (transportType != "quic" || tls.contains("reality") || !tls.contains("utls")) return tls
    return tls.copy().also { it.remove("utls") }
}

/** The core decodes each type strictly, so a key kept from another type in the editor would refuse to start. */
private val TRANSPORT_KEYS = mapOf(
    "http" to listOf("host", "path", "method", "headers", "idle_timeout", "ping_timeout"),
    "ws" to listOf("path", "headers", "max_early_data", "early_data_header_name"),
    "quic" to emptyList(),
    "grpc" to listOf("service_name", "idle_timeout", "ping_timeout", "permit_without_stream"),
    "httpupgrade" to listOf("host", "path", "headers"),
    "xhttp" to listOf(
        "host", "path", "headers", "mode", "x_padding_bytes", "no_grpc_header", "no_sse_header",
        "sc_max_each_post_bytes", "sc_min_posts_interval_ms", "sc_max_buffered_posts", "sc_stream_up_server_secs",
        "x_padding_obfs_mode", "x_padding_key", "x_padding_header", "x_padding_placement", "x_padding_method",
        "uplink_http_method", "session_placement", "session_key", "seq_placement", "seq_key",
        "uplink_data_placement", "uplink_data_key", "uplink_chunk_size", "session_id_table", "session_id_length",
        "congestion_controller", "cwnd", "xmux",
    ),
    "mkcp" to listOf(
        "mtu", "tti", "uplink_capacity", "downlink_capacity", "congestion",
        "read_buffer_size", "write_buffer_size", "header_type", "seed",
    ),
)

/** The Checks of transport.h. */
object TransportChecks {
    @JvmStatic
    fun transportType(type: String): String {
        val t = type.trim()
        if (t.isEmpty() || t in SING_BOX_TRANSPORTS) return ""
        return vtr(R.string.validation_transport_type, t)
    }

    /** A warning: the Host header may carry a port; http takes a comma list. */
    @JvmStatic
    fun transportHost(host: String, type: String): String = CommonChecks.hostHeader(host, type == "http")

    /** [tls]: TLS is on; [reality]: the Reality key is set. [utls] is not an error: see [quicTransportUtls]. */
    @Suppress("UNUSED_PARAMETER")
    @JvmStatic
    fun quicTransport(tls: Boolean, utls: Boolean, reality: Boolean): String = when {
        !tls -> vtr(R.string.validation_transport_quic_tls)
        reality -> vtr(R.string.validation_transport_quic_reality)
        else -> ""
    }

    /** A warning: [utls] is the profile's own fingerprint (not unsafe), which [tlsForTransport] drops. */
    @JvmStatic
    fun quicTransportUtls(utls: Boolean): String = if (utls) vtr(R.string.validation_transport_quic_utls) else ""
}

/** Transport (include/configs/common/transport.h, src/configs/common/transport.cpp): the sing-box V2Ray transport. */
class Transport {
    @JvmField var type: String = ""
    @JvmField var host: String = ""
    @JvmField var path: String = ""
    @JvmField var method: String = ""
    @JvmField var headers: MutableList<String> = ArrayList()
    @JvmField var idle_timeout: String = ""
    @JvmField var ping_timeout: String = ""
    @JvmField var max_early_data: Int = 0
    @JvmField var early_data_header_name: String = ""
    @JvmField var service_name: String = ""

    // V2RayXHTTPOptions (xhttp). Ranges stay in the desktop's From-To text form; the core accepts a
    // number or "from-to" and normalizes empty values to its own defaults.
    @JvmField var mode: String = ""
    @JvmField var x_padding_bytes: String = ""
    @JvmField var no_grpc_header: Boolean = false
    @JvmField var no_sse_header: Boolean = false
    @JvmField var sc_max_each_post_bytes: String = ""
    @JvmField var sc_min_posts_interval_ms: String = ""
    @JvmField var sc_max_buffered_posts: Long = 0
    @JvmField var sc_stream_up_server_secs: String = ""
    @JvmField var x_padding_obfs_mode: Boolean = false
    @JvmField var x_padding_key: String = ""
    @JvmField var x_padding_header: String = ""
    @JvmField var x_padding_placement: String = ""
    @JvmField var x_padding_method: String = ""
    @JvmField var uplink_http_method: String = ""
    @JvmField var session_placement: String = ""
    @JvmField var session_key: String = ""
    @JvmField var seq_placement: String = ""
    @JvmField var seq_key: String = ""
    @JvmField var uplink_data_placement: String = ""
    @JvmField var uplink_data_key: String = ""
    @JvmField var uplink_chunk_size: String = ""
    @JvmField var session_id_table: String = ""
    @JvmField var session_id_length: String = ""
    @JvmField var congestion_controller: String = ""
    @JvmField var cwnd: Int = 0

    /** Xray's xmux block kept verbatim: the core accepts it as a raw object, so every subfield round-trips. */
    @JvmField var xmux: JsonObject? = null

    // V2RayKCPOptions (mkcp). Zero values mean the core default, so build never emits them.
    @JvmField var mtu: Int = 0
    @JvmField var tti: Int = 0
    @JvmField var uplink_capacity: Int = 0
    @JvmField var downlink_capacity: Int = 0
    @JvmField var congestion: Boolean = false
    @JvmField var read_buffer_size: Int = 0
    @JvmField var write_buffer_size: Int = 0
    @JvmField var header_type: String = ""
    @JvmField var seed: String = ""

    /** Never persisted: the parsed source asked for the raw TCP HTTP header, which sing-box reproduces only without TLS. */
    @JvmField var rawHttpHeader: Boolean = false

    fun parseFromLink(link: String): Boolean = parseFromLink(LinkParser.parse(link))

    /** Transport::ParseFromLink (transport.cpp). */
    fun parseFromLink(url: ParsedLink): Boolean {
        if (!url.isValid) return false
        val q = url.query
        fun checked(key: String, current: String, rule: (String) -> String): String {
            if (!q.has(key)) return current
            val value = q.value(key).trim()
            return if (acceptOptional(key, rule(value), value)) value else current
        }
        val linkType = singBoxTransportType(q.value("type"))
        val rawHttp = (linkType.isEmpty() || linkType == "tcp" || linkType == "raw") && q.value("headerType") == "http"
        if (q.has("type")) type = if (linkType == "raw") "tcp" else linkType
        if (rawHttp || type == "h2") {
            type = "http"
            method = "GET"
        }
        // a link naming no transport (the throneExtra of a V2RayN link) keeps what the first parse found
        if (q.has("type") || rawHttp) rawHttpHeader = rawHttp
        if (q.has("host")) host = q.valueFully("host")
        if (q.has("path")) path = q.valueFully("path")
        // the raw header's server accepts any of its comma-listed paths, while sing-box sends exactly one
        if (rawHttp) path = QtStrings.sectionFirstSkipEmpty(path, ',').trim()
        method = checked("method", method) { Validation.httpToken(it) }
        val rawHeaders = q.valueFully("headers")
        if (rawHeaders.isNotEmpty()) {
            headers = QtStrings.split(rawHeaders, "|")
            if (headers.size % 2 != 0) {
                ParseDiag.warn("headers", vtr(R.string.validation_transport_headers_pairs))
                headers.clear()
            }
        }
        idle_timeout = checked("idle_timeout", idle_timeout) { Validation.duration(it) }
        ping_timeout = checked("ping_timeout", ping_timeout) { Validation.duration(it) }
        max_early_data = readQueryInt(q, "max_early_data", max_early_data)
        if (q.has("early_data_header_name")) early_data_header_name = q.value("early_data_header_name")
        if (q.has("serviceName")) service_name = q.valueFully("serviceName")
        if (type == "xhttp") parseXhttpLink(url)
        if (type == "mkcp") parseKcpLink(q)
        return true
    }

    /**
     * The XHTTP share-link keys: mode and the Xray `extra` object (camelCase keys). host/path/headers are read by
     * [parseFromLink] itself, and an explicit x_padding_bytes wins over the value inside extra.
     */
    private fun parseXhttpLink(url: ParsedLink) {
        val q = url.query
        if (q.has("mode")) mode = q.value("mode").trim()
        val extraText = q.valueFully("extra")
        if (extraText.isNotBlank()) {
            val extra = JsonInput.parseObjectOrNull(extraText)
            if (extra == null || extra.isEmpty()) {
                if (ParseDiag.active()) ParseDiag.warn("extra", vtr(R.string.validation_vless_extra_invalid))
            } else {
                parseXhttpExtra(extra)
            }
        }
        if (q.has("x_padding_bytes")) x_padding_bytes = q.value("x_padding_bytes").trim()
    }

    /** Xray's xhttp extra JSON: camelCase in links, plus the snake_case names a sing-box-shaped object would use. */
    private fun parseXhttpExtra(obj: JsonObject) {
        if (obj.contains("mode")) mode = obj.string("mode").trim()
        if (obj.contains("xPaddingBytes")) x_padding_bytes = obj.string("xPaddingBytes").trim()
        if (obj.contains("x_padding_bytes")) x_padding_bytes = obj.string("x_padding_bytes").trim()
        if (obj.contains("noGRPCHeader")) no_grpc_header = obj.bool("noGRPCHeader")
        if (obj.contains("no_grpc_header")) no_grpc_header = obj.bool("no_grpc_header")
        if (obj.contains("noSSEHeader")) no_sse_header = obj.bool("noSSEHeader")
        if (obj.contains("no_sse_header")) no_sse_header = obj.bool("no_sse_header")
        if (obj.contains("scMaxEachPostBytes")) sc_max_each_post_bytes = obj.string("scMaxEachPostBytes").trim()
        if (obj.contains("sc_max_each_post_bytes")) sc_max_each_post_bytes = obj.string("sc_max_each_post_bytes").trim()
        if (obj.contains("scMinPostsIntervalMs")) sc_min_posts_interval_ms = obj.string("scMinPostsIntervalMs").trim()
        if (obj.contains("sc_min_posts_interval_ms")) sc_min_posts_interval_ms = obj.string("sc_min_posts_interval_ms").trim()
        if (obj.contains("scMaxBufferedPosts")) sc_max_buffered_posts = obj.integer("scMaxBufferedPosts")
        if (obj.contains("sc_max_buffered_posts")) sc_max_buffered_posts = obj.integer("sc_max_buffered_posts")
        if (obj.contains("scStreamUpServerSecs")) sc_stream_up_server_secs = obj.string("scStreamUpServerSecs").trim()
        if (obj.contains("sc_stream_up_server_secs")) sc_stream_up_server_secs = obj.string("sc_stream_up_server_secs").trim()
        if (obj.contains("xPaddingObfsMode")) x_padding_obfs_mode = obj.bool("xPaddingObfsMode")
        if (obj.contains("x_padding_obfs_mode")) x_padding_obfs_mode = obj.bool("x_padding_obfs_mode")
        if (obj.contains("xPaddingKey")) x_padding_key = obj.string("xPaddingKey")
        if (obj.contains("x_padding_key")) x_padding_key = obj.string("x_padding_key")
        if (obj.contains("xPaddingHeader")) x_padding_header = obj.string("xPaddingHeader")
        if (obj.contains("x_padding_header")) x_padding_header = obj.string("x_padding_header")
        if (obj.contains("xPaddingPlacement")) x_padding_placement = obj.string("xPaddingPlacement")
        if (obj.contains("x_padding_placement")) x_padding_placement = obj.string("x_padding_placement")
        if (obj.contains("xPaddingMethod")) x_padding_method = obj.string("xPaddingMethod")
        if (obj.contains("x_padding_method")) x_padding_method = obj.string("x_padding_method")
        if (obj.contains("uplinkHTTPMethod")) uplink_http_method = obj.string("uplinkHTTPMethod")
        if (obj.contains("uplink_http_method")) uplink_http_method = obj.string("uplink_http_method")
        if (obj.contains("sessionIDPlacement")) session_placement = obj.string("sessionIDPlacement")
        if (obj.contains("session_placement")) session_placement = obj.string("session_placement")
        if (obj.contains("sessionIDKey")) session_key = obj.string("sessionIDKey")
        if (obj.contains("session_key")) session_key = obj.string("session_key")
        if (obj.contains("seqPlacement")) seq_placement = obj.string("seqPlacement")
        if (obj.contains("seq_placement")) seq_placement = obj.string("seq_placement")
        if (obj.contains("seqKey")) seq_key = obj.string("seqKey")
        if (obj.contains("seq_key")) seq_key = obj.string("seq_key")
        if (obj.contains("uplinkDataPlacement")) uplink_data_placement = obj.string("uplinkDataPlacement")
        if (obj.contains("uplink_data_placement")) uplink_data_placement = obj.string("uplink_data_placement")
        if (obj.contains("uplinkDataKey")) uplink_data_key = obj.string("uplinkDataKey")
        if (obj.contains("uplink_data_key")) uplink_data_key = obj.string("uplink_data_key")
        if (obj.contains("uplinkChunkSize")) uplink_chunk_size = obj.string("uplinkChunkSize").trim()
        if (obj.contains("uplink_chunk_size")) uplink_chunk_size = obj.string("uplink_chunk_size").trim()
        if (obj.contains("sessionIDTable")) session_id_table = obj.string("sessionIDTable")
        if (obj.contains("session_id_table")) session_id_table = obj.string("session_id_table")
        if (obj.contains("sessionIDLength")) session_id_length = obj.string("sessionIDLength").trim()
        if (obj.contains("session_id_length")) session_id_length = obj.string("session_id_length").trim()
        if (obj.contains("congestionController")) congestion_controller = obj.string("congestionController")
        if (obj.contains("congestion_controller")) congestion_controller = obj.string("congestion_controller")
        if (obj.contains("cwnd")) cwnd = obj.int("cwnd")
        if (obj.isObject("xmux")) xmux = obj.obj("xmux").copy()
        if (obj.isObject("headers") && headers.isEmpty()) headers = JsonValues.objectToPairList(obj.obj("headers"))
    }

    /** The Xray KCP link keys; the model stores the kernel's mkcp spelling. */
    private fun parseKcpLink(q: LinkQuery) {
        mtu = readQueryInt(q, "mtu", mtu)
        tti = readQueryInt(q, "tti", tti)
        uplink_capacity = readQueryInt(q, "uplinkCapacity", uplink_capacity)
        downlink_capacity = readQueryInt(q, "downlinkCapacity", downlink_capacity)
        read_buffer_size = readQueryInt(q, "readBufferSize", read_buffer_size)
        write_buffer_size = readQueryInt(q, "writeBufferSize", write_buffer_size)
        if (q.has("congestion")) congestion = linkBool(q.value("congestion"))
        if (q.has("headerType")) header_type = q.value("headerType").trim()
        if (q.has("seed")) seed = q.valueFully("seed")
    }

    /** Transport::ParseFromJson (transport.cpp); also the DB loader, so only an import ([ParseDiag.active]) drops values. */
    fun parseFromJson(obj: JsonObject): Boolean {
        if (obj.isEmpty()) return false
        if (obj.contains("type")) type = singBoxTransportType(obj.string("type"))
        if (obj.contains("host")) {
            host = if (obj.isArray("host")) obj.array("host").strings().joinToString(",") else obj.string("host")
        }
        if (obj.contains("path")) path = obj.string("path")
        val importing = ParseDiag.active()
        fun checked(key: String, current: String, rule: (String) -> String): String {
            if (!obj.contains(key)) return current
            val value = obj.string(key).trim()
            return if (!importing || acceptOptional("transport.$key", rule(value), value)) value else current
        }
        method = checked("method", method) { Validation.httpToken(it) }
        if (obj.contains("headers") && obj.isObject("headers")) {
            val headerObj = obj.obj("headers").copy()
            if (type == "ws") {
                if (headerObj.contains("Host")) {
                    if (headerObj.isString("Host")) {
                        host = headerObj.string("Host")
                    } else if (headerObj.isArray("Host")) {
                        for (v in headerObj.array("Host")) {
                            if (v is String) {
                                host = v
                                break
                            }
                        }
                    }
                    headerObj.remove("Host")
                }
            }
            headers = JsonValues.objectToPairList(headerObj)
        }
        idle_timeout = checked("idle_timeout", idle_timeout) { Validation.duration(it) }
        ping_timeout = checked("ping_timeout", ping_timeout) { Validation.duration(it) }
        if (obj.contains("max_early_data")) max_early_data = obj.int("max_early_data")
        if (obj.contains("early_data_header_name")) early_data_header_name = obj.string("early_data_header_name")
        if (obj.contains("service_name")) service_name = obj.string("service_name")
        if (type == "xhttp") parseXhttpJson(obj)
        if (type == "mkcp") parseKcpJson(obj)
        return true
    }

    /** V2RayXHTTPOptions from its sing-box JSON (transport.h uses the snake_case tags). */
    private fun parseXhttpJson(obj: JsonObject) {
        if (obj.contains("mode")) mode = obj.string("mode").trim()
        if (obj.contains("x_padding_bytes")) x_padding_bytes = obj.string("x_padding_bytes").trim()
        if (obj.contains("no_grpc_header")) no_grpc_header = obj.bool("no_grpc_header")
        if (obj.contains("no_sse_header")) no_sse_header = obj.bool("no_sse_header")
        if (obj.contains("sc_max_each_post_bytes")) sc_max_each_post_bytes = obj.string("sc_max_each_post_bytes").trim()
        if (obj.contains("sc_min_posts_interval_ms")) sc_min_posts_interval_ms = obj.string("sc_min_posts_interval_ms").trim()
        if (obj.contains("sc_max_buffered_posts")) sc_max_buffered_posts = obj.integer("sc_max_buffered_posts")
        if (obj.contains("sc_stream_up_server_secs")) sc_stream_up_server_secs = obj.string("sc_stream_up_server_secs").trim()
        if (obj.contains("x_padding_obfs_mode")) x_padding_obfs_mode = obj.bool("x_padding_obfs_mode")
        if (obj.contains("x_padding_key")) x_padding_key = obj.string("x_padding_key")
        if (obj.contains("x_padding_header")) x_padding_header = obj.string("x_padding_header")
        if (obj.contains("x_padding_placement")) x_padding_placement = obj.string("x_padding_placement")
        if (obj.contains("x_padding_method")) x_padding_method = obj.string("x_padding_method")
        if (obj.contains("uplink_http_method")) uplink_http_method = obj.string("uplink_http_method")
        if (obj.contains("session_placement")) session_placement = obj.string("session_placement")
        if (obj.contains("session_key")) session_key = obj.string("session_key")
        if (obj.contains("seq_placement")) seq_placement = obj.string("seq_placement")
        if (obj.contains("seq_key")) seq_key = obj.string("seq_key")
        if (obj.contains("uplink_data_placement")) uplink_data_placement = obj.string("uplink_data_placement")
        if (obj.contains("uplink_data_key")) uplink_data_key = obj.string("uplink_data_key")
        if (obj.contains("uplink_chunk_size")) uplink_chunk_size = obj.string("uplink_chunk_size").trim()
        if (obj.contains("session_id_table")) session_id_table = obj.string("session_id_table")
        if (obj.contains("session_id_length")) session_id_length = obj.string("session_id_length").trim()
        if (obj.contains("congestion_controller")) congestion_controller = obj.string("congestion_controller")
        if (obj.contains("cwnd")) cwnd = obj.int("cwnd")
        if (obj.isObject("xmux")) xmux = obj.obj("xmux").copy()
    }

    /** V2RayKCPOptions from its sing-box JSON; absent fields keep the core defaults. */
    private fun parseKcpJson(obj: JsonObject) {
        if (obj.contains("mtu")) mtu = obj.int("mtu")
        if (obj.contains("tti")) tti = obj.int("tti")
        if (obj.contains("uplink_capacity")) uplink_capacity = obj.int("uplink_capacity")
        if (obj.contains("downlink_capacity")) downlink_capacity = obj.int("downlink_capacity")
        if (obj.contains("congestion")) congestion = obj.bool("congestion")
        if (obj.contains("read_buffer_size")) read_buffer_size = obj.int("read_buffer_size")
        if (obj.contains("write_buffer_size")) write_buffer_size = obj.int("write_buffer_size")
        if (obj.contains("header_type")) header_type = obj.string("header_type")
        if (obj.contains("seed")) seed = obj.string("seed")
    }

    /**
     * Transport::ParseFromClash (transport.cpp): ws / httpupgrade, grpc, h2 and http-opts in that priority; false when
     * none applies. mihomo sends the ws-opts Host header as the HTTP Host and uses servername only for the SNI.
     * Android also maps `network: grpc` without a service name and `network: http` without a method, which Clash
     * sends as GET.
     */
    fun parseFromClash(proxy: ClashProxy): Boolean {
        val network = proxy.string("network")
        val xhttp = proxy.obj("xhttp-opts")
        if (network == "xhttp" || xhttp.string("path").isNotEmpty()) {
            type = "xhttp"
            host = xhttp.string("host")
            path = xhttp.string("path")
            mode = xhttp.string("mode").trim()
            if (xhttp.has("x-padding-bytes")) x_padding_bytes = xhttp.string("x-padding-bytes").trim()
            if (xhttp.has("no-grpc-header")) no_grpc_header = xhttp.bool("no-grpc-header")
            if (xhttp.has("no-sse-header")) no_sse_header = xhttp.bool("no-sse-header")
            if (xhttp.has("sc-min-posts-interval-ms")) {
                sc_min_posts_interval_ms = xhttp.string("sc-min-posts-interval-ms").trim()
            }
            x_padding_obfs_mode = xhttp.bool("x-padding-obfs-mode")
            x_padding_key = xhttp.string("x-padding-key")
            x_padding_header = xhttp.string("x-padding-header")
            x_padding_placement = xhttp.string("x-padding-placement")
            x_padding_method = xhttp.string("x-padding-method")
            if (xhttp.has("congestion-controller")) congestion_controller = xhttp.string("congestion-controller")
            if (xhttp.has("cwnd")) cwnd = xhttp.int("cwnd")
            var headerHost = ""
            for ((key, value) in xhttp.stringMap("headers")) {
                if (key.equals("host", ignoreCase = true)) {
                    if (headerHost.isEmpty()) headerHost = value
                    continue
                }
                headers.add(key)
                headers.add(value)
            }
            if (headerHost.isNotEmpty()) host = headerHost
            return true
        }
        val kcp = proxy.obj("kcp-opts")
        if (network == "kcp" || network == "mkcp" || kcp.has("header-type") || kcp.has("mtu")) {
            type = "mkcp"
            mtu = kcp.int("mtu")
            tti = kcp.int("tti")
            uplink_capacity = kcp.int("uplink-capacity")
            downlink_capacity = kcp.int("downlink-capacity")
            congestion = kcp.bool("congestion")
            read_buffer_size = kcp.int("read-buffer-size")
            write_buffer_size = kcp.int("write-buffer-size")
            header_type = kcp.string("header-type")
            seed = kcp.string("seed")
            return true
        }
        val ws = proxy.obj("ws-opts")
        val wsPath = ws.string("path")
        if (wsPath.isNotEmpty() || network == "ws") {
            if (ws.bool("v2ray-http-upgrade")) {
                type = "httpupgrade"
            } else {
                type = "ws"
                early_data_header_name = ws.string("early-data-header-name")
                max_early_data = ws.int("max-early-data")
            }
            var headerHost = ""
            for ((key, value) in ws.stringMap("headers")) {
                // Host belongs in the host field, which exportToJson writes back as the ws Host header.
                if (key.equals("host", ignoreCase = true)) {
                    if (headerHost.isEmpty()) headerHost = value
                    continue
                }
                headers.add(key)
                headers.add(value)
            }
            val servername = proxy.string("servername")
            if (headerHost.isNotEmpty()) host = headerHost else if (servername.isNotEmpty()) host = servername
            path = wsPath
            return true
        }
        val grpcServiceName = proxy.obj("grpc-opts").string("grpc-service-name")
        if (grpcServiceName.isNotEmpty() || network == "grpc") {
            type = "grpc"
            service_name = grpcServiceName
            return true
        }
        val h2 = proxy.obj("h2-opts")
        val h2Path = h2.string("path")
        if (h2Path.isNotEmpty() || network == "h2") {
            type = "http"
            h2.strings("host").firstOrNull()?.let { host = it }
            path = h2Path
            return true
        }
        val http = proxy.obj("http-opts")
        val httpMethod = http.string("method")
        if (httpMethod.isNotEmpty() || network == "http") {
            type = "http"
            http.stringListMap("headers")["Host"]?.firstOrNull()?.let { host = it }
            http.strings("path").firstOrNull()?.let { path = it }
            method = httpMethod.ifEmpty { "GET" }
            rawHttpHeader = true
            return true
        }
        return false
    }

    /** Transport::ExportToLink (transport.cpp). */
    fun exportToLink(): List<Pair<String, String>> = exportToLink(true)

    /** In plaintext the http transport is the raw HTTP header, which other clients spell type=tcp&headerType=http. */
    fun exportToLink(tlsEnabled: Boolean): List<Pair<String, String>> {
        if (type.isEmpty() || type == "tcp") return emptyList()
        val q = ArrayList<Pair<String, String>>()
        if (type == "mkcp") {
            // Xray spells the network kcp and puts every option in the query.
            q.add("type" to "kcp")
            if (mtu > 0) q.add("mtu" to mtu.toString())
            if (tti > 0) q.add("tti" to tti.toString())
            if (uplink_capacity > 0) q.add("uplinkCapacity" to uplink_capacity.toString())
            if (downlink_capacity > 0) q.add("downlinkCapacity" to downlink_capacity.toString())
            if (congestion) q.add("congestion" to "1")
            if (read_buffer_size > 0) q.add("readBufferSize" to read_buffer_size.toString())
            if (write_buffer_size > 0) q.add("writeBufferSize" to write_buffer_size.toString())
            if (header_type.isNotEmpty()) q.add("headerType" to header_type)
            if (seed.isNotEmpty()) q.add("seed" to seed)
            return q
        }
        if (type == "xhttp") {
            q.add("type" to "xhttp")
            if (host.isNotEmpty()) q.add("host" to host)
            if (path.isNotEmpty()) q.add("path" to path)
            if (mode.isNotEmpty()) q.add("mode" to mode)
            if (headers.isNotEmpty()) q.add("headers" to headers.joinToString("|"))
            val extra = xhttpExtraJson()
            if (extra.isNotEmpty()) q.add("extra" to extra.toCompact())
            return q
        }
        if (type == "http" && !tlsEnabled) {
            q.add("type" to "tcp")
            q.add("headerType" to "http")
        } else {
            q.add("type" to type)
        }
        if (host.isNotEmpty()) q.add("host" to host)
        if (path.isNotEmpty()) q.add("path" to path)
        if (method.isNotEmpty()) q.add("method" to method)
        if (headers.isNotEmpty()) q.add("headers" to headers.joinToString("|"))
        if (idle_timeout.isNotEmpty()) q.add("idle_timeout" to idle_timeout)
        if (ping_timeout.isNotEmpty()) q.add("ping_timeout" to ping_timeout)
        if (max_early_data > 0) q.add("max_early_data" to max_early_data.toString())
        if (early_data_header_name.isNotEmpty()) q.add("early_data_header_name" to early_data_header_name)
        if (service_name.isNotEmpty()) q.add("serviceName" to service_name)
        return q
    }

    /** Xray's xhttp extra object: the link's camelCase spellings, so a link export round-trips with Xray clients. */
    private fun xhttpExtraJson(): JsonObject {
        val obj = JsonObject()
        if (x_padding_bytes.isNotEmpty()) obj["xPaddingBytes"] = x_padding_bytes
        if (no_grpc_header) obj["noGRPCHeader"] = true
        if (no_sse_header) obj["noSSEHeader"] = true
        if (sc_max_each_post_bytes.isNotEmpty()) obj["scMaxEachPostBytes"] = sc_max_each_post_bytes
        if (sc_min_posts_interval_ms.isNotEmpty()) obj["scMinPostsIntervalMs"] = sc_min_posts_interval_ms
        if (sc_max_buffered_posts > 0) obj["scMaxBufferedPosts"] = sc_max_buffered_posts
        if (sc_stream_up_server_secs.isNotEmpty()) obj["scStreamUpServerSecs"] = sc_stream_up_server_secs
        if (x_padding_obfs_mode) obj["xPaddingObfsMode"] = true
        if (x_padding_key.isNotEmpty()) obj["xPaddingKey"] = x_padding_key
        if (x_padding_header.isNotEmpty()) obj["xPaddingHeader"] = x_padding_header
        if (x_padding_placement.isNotEmpty()) obj["xPaddingPlacement"] = x_padding_placement
        if (x_padding_method.isNotEmpty()) obj["xPaddingMethod"] = x_padding_method
        if (uplink_http_method.isNotEmpty()) obj["uplinkHTTPMethod"] = uplink_http_method
        if (session_placement.isNotEmpty()) obj["sessionIDPlacement"] = session_placement
        if (session_key.isNotEmpty()) obj["sessionIDKey"] = session_key
        if (seq_placement.isNotEmpty()) obj["seqPlacement"] = seq_placement
        if (seq_key.isNotEmpty()) obj["seqKey"] = seq_key
        if (uplink_data_placement.isNotEmpty()) obj["uplinkDataPlacement"] = uplink_data_placement
        if (uplink_data_key.isNotEmpty()) obj["uplinkDataKey"] = uplink_data_key
        if (uplink_chunk_size.isNotEmpty()) obj["uplinkChunkSize"] = uplink_chunk_size
        if (session_id_table.isNotEmpty()) obj["sessionIDTable"] = session_id_table
        if (session_id_length.isNotEmpty()) obj["sessionIDLength"] = session_id_length
        if (congestion_controller.isNotEmpty()) obj["congestionController"] = congestion_controller
        if (cwnd > 0) obj["cwnd"] = cwnd
        if (headers.isNotEmpty()) obj["headers"] = JsonValues.pairListToObject(headers)
        xmux?.let { if (it.isNotEmpty()) obj["xmux"] = it.copy() }
        return obj
    }

    /** Transport::ExportToJson (transport.cpp). */
    fun exportToJson(): JsonObject {
        val obj = JsonObject()
        if (type.isEmpty() || type == "tcp") return obj
        if (type == "xhttp") {
            obj["type"] = "xhttp"
            if (host.isNotEmpty()) obj["host"] = Hosts.toAceHost(host)
            if (path.isNotEmpty()) obj["path"] = path
            if (mode.isNotEmpty()) obj["mode"] = mode
            // The core refuses a zero range, so the default is written even before an edit.
            obj["x_padding_bytes"] = x_padding_bytes.ifEmpty { DEFAULT_X_PADDING_BYTES }
            if (no_grpc_header) obj["no_grpc_header"] = true
            if (no_sse_header) obj["no_sse_header"] = true
            if (sc_max_each_post_bytes.isNotEmpty()) obj["sc_max_each_post_bytes"] = sc_max_each_post_bytes
            if (sc_min_posts_interval_ms.isNotEmpty()) obj["sc_min_posts_interval_ms"] = sc_min_posts_interval_ms
            if (sc_max_buffered_posts > 0) obj["sc_max_buffered_posts"] = sc_max_buffered_posts
            if (sc_stream_up_server_secs.isNotEmpty()) obj["sc_stream_up_server_secs"] = sc_stream_up_server_secs
            if (x_padding_obfs_mode) obj["x_padding_obfs_mode"] = true
            if (x_padding_key.isNotEmpty()) obj["x_padding_key"] = x_padding_key
            if (x_padding_header.isNotEmpty()) obj["x_padding_header"] = x_padding_header
            if (x_padding_placement.isNotEmpty()) obj["x_padding_placement"] = x_padding_placement
            if (x_padding_method.isNotEmpty()) obj["x_padding_method"] = x_padding_method
            if (uplink_http_method.isNotEmpty()) obj["uplink_http_method"] = uplink_http_method
            if (session_placement.isNotEmpty()) obj["session_placement"] = session_placement
            if (session_key.isNotEmpty()) obj["session_key"] = session_key
            if (seq_placement.isNotEmpty()) obj["seq_placement"] = seq_placement
            if (seq_key.isNotEmpty()) obj["seq_key"] = seq_key
            if (uplink_data_placement.isNotEmpty()) obj["uplink_data_placement"] = uplink_data_placement
            if (uplink_data_key.isNotEmpty()) obj["uplink_data_key"] = uplink_data_key
            if (uplink_chunk_size.isNotEmpty()) obj["uplink_chunk_size"] = uplink_chunk_size
            if (session_id_table.isNotEmpty()) obj["session_id_table"] = session_id_table
            if (session_id_length.isNotEmpty()) obj["session_id_length"] = session_id_length
            if (congestion_controller.isNotEmpty()) obj["congestion_controller"] = congestion_controller
            if (cwnd > 0) obj["cwnd"] = cwnd
            if (headers.isNotEmpty()) obj["headers"] = JsonValues.pairListToObject(headers)
            xmux?.let { if (it.isNotEmpty()) obj["xmux"] = it.copy() }
            return obj
        }
        if (type == "mkcp") {
            obj["type"] = "mkcp"
            if (mtu > 0) obj["mtu"] = mtu
            if (tti > 0) obj["tti"] = tti
            if (uplink_capacity > 0) obj["uplink_capacity"] = uplink_capacity
            if (downlink_capacity > 0) obj["downlink_capacity"] = downlink_capacity
            if (congestion) obj["congestion"] = true
            if (read_buffer_size > 0) obj["read_buffer_size"] = read_buffer_size
            if (write_buffer_size > 0) obj["write_buffer_size"] = write_buffer_size
            if (header_type.isNotEmpty()) obj["header_type"] = header_type
            if (seed.isNotEmpty()) obj["seed"] = seed
            return obj
        }
        obj["type"] = type
        if (path.contains("?ed=")) {
            val spl = path.split("?ed=")
            obj["path"] = spl[0]
            obj["max_early_data"] = QtStrings.toInt(spl[1])
            obj["early_data_header_name"] = "Sec-WebSocket-Protocol"
        } else {
            if (path.isNotEmpty()) obj["path"] = path
            if (max_early_data > 0) obj["max_early_data"] = max_early_data
            if (early_data_header_name.isNotEmpty()) obj["early_data_header_name"] = early_data_header_name
        }
        if (method.isNotEmpty()) obj["method"] = method
        if (headers.isNotEmpty()) obj["headers"] = JsonValues.pairListToObject(headers)
        if (host.isNotEmpty()) {
            if (type == "http" || type == "httpupgrade") obj["host"] = Hosts.toAceHost(host)
            if (type == "ws") {
                val headersObj = obj["headers"] as? JsonObject ?: JsonObject()
                headersObj["Host"] = Hosts.toAceHost(host)
                obj["headers"] = headersObj
            }
        }
        if (idle_timeout.isNotEmpty()) obj["idle_timeout"] = idle_timeout
        if (ping_timeout.isNotEmpty()) obj["ping_timeout"] = ping_timeout
        if (service_name.isNotEmpty()) obj["service_name"] = service_name
        return obj
    }

    /** Transport::ExportIdentity (transport.cpp). */
    fun exportIdentity(): JsonObject {
        val obj = JsonObject()
        if (type.isEmpty() || type == "tcp") return obj
        obj["type"] = type
        return obj
    }

    /** Transport::Build (transport.cpp): a comma list of http hosts becomes an array of trimmed hosts; keys of other types are dropped. */
    fun build(ctx: BuildContext): JsonObject {
        val obj = exportToJson()
        val exported = obj.string("host")
        if (type == "http" && exported.contains(',')) {
            val hosts = QtStrings.splitSkipEmpty(exported, ",").map { it.trim() }
            obj["host"] = JsonValues.stringArray(hosts)
        }
        TRANSPORT_KEYS[type]?.let { keys ->
            for (key in obj.keys()) if (key != "type" && key !in keys) obj.remove(key)
        }
        // The core rejects a zero x_padding_bytes range; the model default covers a cleared field.
        if (type == "xhttp" && obj.string("x_padding_bytes").isEmpty()) obj["x_padding_bytes"] = DEFAULT_X_PADDING_BYTES
        return obj
    }

    /** Transport::Validate (transport.cpp); see [TransportChecks.quicTransport] for the flags. */
    fun validate(issues: MutableList<Issue>, tls: Boolean, utls: Boolean, reality: Boolean) {
        issues.addIssue(Severity.Error, "transport.type", TransportChecks.transportType(type), type)
        if (type == "http" || type == "ws" || type == "httpupgrade") {
            issues.addIssue(Severity.Warning, "transport.host", TransportChecks.transportHost(host, type), host)
        }
        if (type == "xhttp") {
            issues.addIssue(Severity.Warning, "transport.host", TransportChecks.transportHost(host, "xhttp"), host)
            issues.addIssue(Severity.Error, "transport.mode", Validation.oneOf(mode, XHTTP_MODES), mode)
        }
        if (type == "mkcp") {
            issues.addIssue(Severity.Error, "transport.header_type", Validation.oneOf(header_type, KCP_HEADER_TYPES), header_type)
        }
        if (type == "http") issues.addIssue(Severity.Warning, "transport.method", Validation.httpToken(method), method)
        if (type == "http" || type == "grpc") {
            issues.addIssue(Severity.Error, "transport.idle_timeout", Validation.duration(idle_timeout), idle_timeout)
            issues.addIssue(Severity.Error, "transport.ping_timeout", Validation.duration(ping_timeout), ping_timeout)
        }
        if (type == "quic") {
            issues.addIssue(Severity.Error, "transport.type", TransportChecks.quicTransport(tls, utls, reality))
            if (tls && !reality) issues.addIssue(Severity.Warning, "tls.utls.fingerprint", TransportChecks.quicTransportUtls(utls))
        }
    }
}
