package io.nekohasekai.sagernet.outbound.import

import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.InvalidOutbound
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.outbound.json.JsonValues
import io.nekohasekai.sagernet.outbound.types.Custom
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.Severity

/**
 * The Xray runtime is gone: every profile now runs on sing-box. This converts the rows and documents the removed
 * implementation left behind, so a stored `xrayvless` profile, a `custom` row of the removed Xray subtypes or an Xray
 * JSON document still load as the sing-box outbound that means the same thing:
 *
 * - a VLESS outbound becomes `vless` with its uuid, flow, VLESS Encryption, TLS / REALITY and transport;
 * - an Xray outbound of another protocol becomes the matching sing-box outbound when one exists;
 * - what sing-box cannot express (the XDRIVE transport, a custom Xray full config, an unknown protocol or transport)
 *   is refused with a message, never silently rewritten: the profile row is kept, shown with that message, and the
 *   user can edit or delete it.
 *
 * Called from the JSON and DB load paths ([io.nekohasekai.sagernet.database.ProxyEntity.parseOutbound],
 * [OutboundFactory.fromJson], [ProfileImport]); no Xray runtime type is involved.
 */
object LegacyXray {

    /** A converted outbound, or [error] naming why the Xray data cannot be represented. */
    class Conversion(@JvmField val outbound: Outbound?, @JvmField val error: String = "")

    /** Custom row subtypes of the removed Xray support. */
    private const val SUBTYPE_XRAY_OUTBOUND = "xrayoutbound"
    private const val SUBTYPE_XRAY_FULL_CONFIG = "xrayfullconfig"

    private const val TYPE_XRAY_VLESS = "xrayvless"

    /** Xray protocols that route traffic themselves: never imported, as before. */
    private val INFRA_PROTOCOLS = setOf("freedom", "direct", "blackhole", "block", "dns", "loopback")

    /** The Xray protocols with a sing-box outbound of the same name (wireguard is a sing-box endpoint). */
    private val CONVERTIBLE_PROTOCOLS = setOf("vless", "vmess", "trojan", "shadowsocks", "socks", "http", "wireguard")

    /** The refusal every whole Xray config gets: sing-box runs no such document. */
    const val FULL_CONFIG_ERROR = "Custom Xray full configs are no longer supported; re-import a sing-box profile instead"

    /**
     * A stored row of a legacy Xray profile, or null when [type]/[data] describe something else. The returned outbound
     * is an [InvalidOutbound] carrying the reason when the stored data cannot be converted; the caller keeps the row.
     */
    @JvmStatic
    fun migrateStored(type: String, data: JsonObject): Outbound? {
        val storedType = type.trim().lowercase()
        val rowType = data.string("type").trim().lowercase()
        if (storedType == TYPE_XRAY_VLESS || rowType == TYPE_XRAY_VLESS) {
            return asStored(TYPE_XRAY_VLESS, convertOutbound(data))
        }
        if (storedType == "custom" || rowType == "custom") {
            return when (data.string("subtype").trim().lowercase()) {
                SUBTYPE_XRAY_OUTBOUND -> asStored("custom", convertOutbound(JsonInput.parseObject(data.string("config"))))
                SUBTYPE_XRAY_FULL_CONFIG -> InvalidOutbound("custom", FULL_CONFIG_ERROR)
                else -> null
            }
        }
        // An Xray-shaped object stored without its own `type` (the shape every Xray outbound row had).
        if (data.contains("protocol")) return asStored(TYPE_XRAY_VLESS, convertOutbound(data))
        return null
    }

    /**
     * One Xray outbound object (`protocol` plus `settings` / `streamSettings` / `mux`) as a sing-box outbound. Null for
     * an empty object or an infrastructure protocol (dropped, as before); [Conversion.error] when it cannot be
     * represented.
     */
    @JvmStatic
    fun convertOutbound(out: JsonObject): Conversion? {
        if (out.isEmpty()) return null
        val protocol = out.string("protocol").trim().lowercase()
        if (protocol.isEmpty()) return null
        if (protocol in INFRA_PROTOCOLS) return null
        if (protocol !in CONVERTIBLE_PROTOCOLS) return refused("Xray \"$protocol\" outbounds have no sing-box counterpart")

        val peer = peerOf(out, protocol)
        if (peer.address.isEmpty() || peer.port <= 0) {
            return refused("the Xray outbound has no server address to convert")
        }
        val json = JsonObject()
        json["type"] = if (protocol == "shadowsocks") "shadowsocks" else protocol
        val tag = out.string("tag")
        if (tag.isNotEmpty()) json["tag"] = tag
        json["server"] = peer.address
        json["server_port"] = peer.port

        when (protocol) {
            "vless" -> {
                val uuid = peer.user.string("id").ifEmpty { peer.user.string("uuid") }
                if (uuid.isEmpty()) return refused("the Xray VLESS outbound has no user id to convert")
                json["uuid"] = uuid
                val flow = peer.user.string("flow").trim()
                if (flow.isNotEmpty()) json["flow"] = flow
                json["encryption"] = peer.user.string("encryption").trim().ifEmpty { "none" }
            }

            "vmess" -> {
                val uuid = peer.user.string("id").ifEmpty { peer.user.string("uuid") }
                if (uuid.isEmpty()) return refused("the Xray VMess outbound has no user id to convert")
                json["uuid"] = uuid
                val security = peer.user.string("security").trim()
                if (security.isNotEmpty()) json["security"] = security
                val alterId = peer.user.integer("alterId")
                if (alterId > 0) json["alter_id"] = alterId
            }

            "trojan" -> {
                val password = peer.user.string("password")
                if (password.isEmpty()) return refused("the Xray Trojan outbound has no password to convert")
                json["password"] = password
            }

            "shadowsocks" -> {
                val method = peer.user.string("method")
                val password = peer.user.string("password")
                if (method.isEmpty() || password.isEmpty()) return refused("the Xray Shadowsocks outbound has no method or password to convert")
                json["method"] = method
                json["password"] = password
            }

            "socks" -> {
                json["version"] = "5"
                val username = peer.user.string("user")
                if (username.isNotEmpty()) json["username"] = username
                val password = peer.user.string("pass")
                if (password.isNotEmpty()) json["password"] = password
            }

            "http" -> {
                val username = peer.user.string("user")
                if (username.isNotEmpty()) json["username"] = username
                val password = peer.user.string("pass")
                if (password.isNotEmpty()) json["password"] = password
            }

            "wireguard" -> {
                val settings = out.obj("settings")
                val privateKey = settings.string("secretKey")
                if (privateKey.isEmpty()) return refused("the Xray WireGuard outbound has no secretKey to convert")
                json["private_key"] = privateKey
                val addresses = when {
                    settings.isArray("address") -> settings.array("address").strings()
                    settings.string("address").isNotEmpty() -> listOf(settings.string("address"))
                    else -> emptyList()
                }
                if (addresses.isNotEmpty()) json["address"] = JsonArray.of(*addresses.toTypedArray())
                if (settings.integer("mtu") > 0) json["mtu"] = settings.integer("mtu")
                val wirePeer = settings.array("peers").firstOrNull() as? JsonObject ?: JsonObject()
                val peerPublicKey = wirePeer.string("publicKey")
                if (peerPublicKey.isEmpty()) return refused("the Xray WireGuard outbound has no peer public key to convert")
                val peers = JsonArray()
                val peerJson = JsonObject()
                peerJson["address"] = peer.address
                peerJson["port"] = peer.port
                peerJson["public_key"] = peerPublicKey
                val preSharedKey = wirePeer.string("preSharedKey")
                if (preSharedKey.isNotEmpty()) peerJson["pre_shared_key"] = preSharedKey
                peers.add(peerJson)
                json["peers"] = peers
            }
        }

        transportError(out)?.let { return refused(it) }
        tlsError(out)?.let { return refused(it) }
        applyTransport(out, json)
        applyTls(out, json)
        applyMultiplex(out, json)
        return parse(json)
    }

    /** A converted row, or an [InvalidOutbound] that shows the reason in place of its type. */
    private fun asStored(type: String, conversion: Conversion?): Outbound? = when {
        conversion == null -> null
        conversion.outbound != null -> conversion.outbound
        else -> InvalidOutbound(type, conversion.error)
    }

    private fun refused(reason: String) = Conversion(null, "This Xray profile cannot be converted: $reason")

    /**
     * The server and user of an outbound: `settings` inline, or `vnext` / `servers` with their first entry. VMess and
     * VLESS keep the user in `users[0]`; the other protocols put the credential on the server object itself (Trojan's
     * password, Shadowsocks' method), which is the fallback when there is no user entry.
     */
    private class Peer(val address: String, val port: Int, val user: JsonObject)

    private fun peerOf(out: JsonObject, protocol: String): Peer {
        val settings = out.obj("settings")
        if (settings.contains("address") && !settings.contains("vnext")) {
            return Peer(settings.string("address"), settings.integer("port").toInt(), settings)
        }
        val list = if (protocol == "vmess" || protocol == "vless") settings.array("vnext") else settings.array("servers")
        val first = list.firstOrNull() as? JsonObject ?: JsonObject()
        val user = first.array("users").firstOrNull() as? JsonObject ?: first
        return Peer(first.string("address"), first.integer("port").toInt(), user)
    }

    /** Xray settings the sing-box model cannot carry; refused rather than silently dropped. */
    private fun transportError(out: JsonObject): String? {
        val network = normalNetwork(out.obj("streamSettings").string("network"))
        if (network == "xdrive") return "the XDRIVE transport has no sing-box counterpart"
        if (network !in SUPPORTED_NETWORKS) return "the Xray transport \"$network\" has no sing-box counterpart"
        return null
    }

    private fun tlsError(out: JsonObject): String? {
        val stream = out.obj("streamSettings")
        val security = stream.string("security").trim().lowercase()
        if (security != "" && security != "none" && security != "tls" && security != "reality") {
            return "the Xray security \"$security\" has no sing-box counterpart"
        }
        if (stream.obj("tlsSettings").string("verifyPeerCertByName").isNotBlank()) {
            return "verifyPeerCertByName has no sing-box counterpart"
        }
        return null
    }

    private fun applyTransport(out: JsonObject, json: JsonObject) {
        val stream = out.obj("streamSettings")
        val network = normalNetwork(stream.string("network"))
        val transport = JsonObject()
        when (network) {
            "", "tcp" -> return
            "ws" -> {
                val ws = stream.obj("wsSettings")
                transport["type"] = "ws"
                if (ws.contains("path")) transport["path"] = ws.string("path")
                if (ws.contains("host")) transport["host"] = ws.string("host")
                if (ws.isObject("headers")) transport["headers"] = ws.obj("headers")
            }

            "http" -> {
                val http = stream.obj("httpSettings")
                transport["type"] = "http"
                if (http.contains("path")) transport["path"] = http.string("path")
                if (http.contains("host") && http["host"] is JsonArray) transport["host"] = http["host"]
                else if (http.string("host").isNotEmpty()) transport["host"] = http.string("host")
                if (http.isObject("headers")) transport["headers"] = http.obj("headers")
            }

            "grpc" -> {
                val grpc = stream.obj("grpcSettings")
                transport["type"] = "grpc"
                if (grpc.contains("serviceName")) transport["service_name"] = grpc.string("serviceName")
            }

            "httpupgrade" -> {
                val upgrade = stream.obj("httpupgradeSettings")
                transport["type"] = "httpupgrade"
                if (upgrade.contains("path")) transport["path"] = upgrade.string("path")
                if (upgrade.contains("host")) transport["host"] = upgrade.string("host")
                if (upgrade.isObject("headers")) transport["headers"] = upgrade.obj("headers")
            }

            "quic" -> transport["type"] = "quic"

            "xhttp" -> {
                val xhttp = stream.obj("xhttpSettings")
                transport["type"] = "xhttp"
                if (xhttp.contains("path")) transport["path"] = xhttp.string("path")
                if (xhttp.contains("host")) transport["host"] = xhttp.string("host")
                if (xhttp.contains("mode")) transport["mode"] = xhttp.string("mode").trim()
                applyXhttpExtra(xhttp.obj("extra"), transport)
            }

            "mkcp" -> {
                val kcp = stream.obj("kcpSettings")
                transport["type"] = "mkcp"
                if (kcp.integer("mtu") > 0) transport["mtu"] = kcp.integer("mtu")
                if (kcp.integer("tti") > 0) transport["tti"] = kcp.integer("tti")
                if (kcp.integer("uplinkCapacity") > 0) transport["uplink_capacity"] = kcp.integer("uplinkCapacity")
                if (kcp.integer("downlinkCapacity") > 0) transport["downlink_capacity"] = kcp.integer("downlinkCapacity")
                if (kcp.integer("readBufferSize") > 0) transport["read_buffer_size"] = kcp.integer("readBufferSize")
                if (kcp.integer("writeBufferSize") > 0) transport["write_buffer_size"] = kcp.integer("writeBufferSize")
                if (kcp.contains("congestion")) transport["congestion"] = kcp.bool("congestion")
                val headerType = kcp.obj("header").string("type")
                if (headerType.isNotEmpty()) transport["header_type"] = headerType
                if (kcp.contains("seed")) transport["seed"] = kcp.string("seed")
            }
        }
        json["transport"] = transport
    }

    /** The Xray XHTTP `extra` object's kernel-supported keys, in the kernel's snake_case spelling. */
    private fun applyXhttpExtra(extra: JsonObject, transport: JsonObject) {
        if (extra.isEmpty()) return
        val text = mapOf(
            "xPaddingBytes" to "x_padding_bytes",
            "scMaxEachPostBytes" to "sc_max_each_post_bytes",
            "scMinPostsIntervalMs" to "sc_min_posts_interval_ms",
            "scStreamUpServerSecs" to "sc_stream_up_server_secs",
            "xPaddingObfsMode" to "x_padding_obfs_mode",
            "xPaddingKey" to "x_padding_key",
            "xPaddingHeader" to "x_padding_header",
            "xPaddingPlacement" to "x_padding_placement",
            "xPaddingMethod" to "x_padding_method",
            "uplinkHttpMethod" to "uplink_http_method",
            "sessionPlacement" to "session_placement",
            "sessionKey" to "session_key",
            "seqPlacement" to "seq_placement",
            "seqKey" to "seq_key",
            "uplinkDataPlacement" to "uplink_data_placement",
            "uplinkDataKey" to "uplink_data_key",
            "uplinkChunkSize" to "uplink_chunk_size",
            "sessionIDTable" to "session_id_table",
            "sessionIDLength" to "session_id_length",
            "congestionController" to "congestion_controller",
        )
        for ((from, to) in text) {
            if (!extra.contains(from)) continue
            val value = JsonValues.toStringValue(extra[from]).trim()
            if (value.isNotEmpty()) transport[to] = value
        }
        val ints = mapOf("scMaxBufferedPosts" to "sc_max_buffered_posts", "cwnd" to "cwnd")
        for ((from, to) in ints) {
            if (extra.integer(from) > 0) transport[to] = extra.integer(from)
        }
        if (extra.contains("noGRPCHeader")) transport["no_grpc_header"] = extra.bool("noGRPCHeader")
        if (extra.contains("noSSEHeader")) transport["no_sse_header"] = extra.bool("noSSEHeader")
        if (extra.isObject("xmux")) transport["xmux"] = extra.obj("xmux")
    }

    private fun applyTls(out: JsonObject, json: JsonObject) {
        val stream = out.obj("streamSettings")
        val security = stream.string("security").trim().lowercase()
        if (security != "tls" && security != "reality") return
        val tls = JsonObject()
        tls["enabled"] = true
        val settings = if (security == "reality") stream.obj("realitySettings") else stream.obj("tlsSettings")
        if (settings.contains("serverName")) {
            val serverName = settings.string("serverName")
            if (serverName.isNotEmpty()) tls["server_name"] = serverName
        }
        val fingerprint = settings.string("fingerprint").trim()
        if (fingerprint.isNotEmpty()) {
            val utls = JsonObject()
            utls["enabled"] = true
            utls["fingerprint"] = fingerprint
            tls["utls"] = utls
        }
        val alpn = when {
            settings.isArray("alpn") -> settings.array("alpn").strings().filter { it.isNotBlank() }
            settings.string("alpn").isNotBlank() -> settings.string("alpn").split(',').map { it.trim() }.filter { it.isNotEmpty() }
            else -> emptyList()
        }
        if (alpn.isNotEmpty()) tls["alpn"] = JsonArray.of(*alpn.toTypedArray())
        if (security == "tls") {
            if (settings.contains("allowInsecure")) tls["insecure"] = settings.bool("allowInsecure")
            val pin = settings.string("pinnedPeerCertSha256").trim()
            if (pin.isNotEmpty()) tls["certificate_sha256"] = JsonArray.of(pin)
        } else {
            val reality = JsonObject()
            reality["enabled"] = true
            // Newer Xray writes publicKey, older builds password; either names the REALITY public key.
            val publicKey = settings.string("password").trim().ifEmpty { settings.string("publicKey").trim() }
            reality["public_key"] = publicKey
            if (settings.contains("shortId")) reality["short_id"] = settings.string("shortId").trim()
            val mldsa65Verify = settings.string("mldsa65Verify").trim()
            if (mldsa65Verify.isNotEmpty()) reality["mldsa65_verify"] = mldsa65Verify
            tls["reality"] = reality
        }
        json["tls"] = tls
    }

    /**
     * The Xray mux block: `concurrency` becomes max_streams. `xudpConcurrency` has no sing-box field (the kernel's
     * multiplex has no XUDP pool), so it is dropped with the rest of the Xray-only knobs.
     */
    private fun applyMultiplex(out: JsonObject, json: JsonObject) {
        val mux = out.obj("mux")
        if (mux.isEmpty()) return
        val multiplex = JsonObject()
        if (mux.contains("enabled")) multiplex["enabled"] = mux.bool("enabled")
        if (mux.integer("concurrency") > 0) multiplex["max_streams"] = mux.integer("concurrency")
        if (multiplex.isNotEmpty()) json["multiplex"] = multiplex
    }

    /** Parses the built sing-box object and refuses it when the model's own checks reject it. */
    private fun parse(json: JsonObject): Conversion {
        val outbound = OutboundFactory.newByType(json.string("type"))
        if (outbound.invalid) return refused("the sing-box \"${json.string("type")}\" outbound is not available")
        if (!outbound.parseFromJson(json)) return refused("the Xray data does not parse as a sing-box outbound")
        val issues = ArrayList<Issue>()
        outbound.validate(issues, BuildContext.DEFAULT)
        val error = issues.firstOrNull { it.severity == Severity.Error }
        if (error != null) {
            val at = if (error.field.isEmpty()) "" else error.field + ": "
            return refused(at + error.message)
        }
        return Conversion(outbound)
    }

    /** Xray's aliases, folded onto the kernel's transport names. */
    private fun normalNetwork(raw: String): String = when (val network = raw.trim().lowercase()) {
        "", "tcp", "raw" -> ""
        "websocket" -> "ws"
        "h2" -> "http"
        "splithttp" -> "xhttp"
        "kcp" -> "mkcp"
        else -> network
    }

    private val SUPPORTED_NETWORKS = setOf("", "ws", "http", "grpc", "httpupgrade", "quic", "xhttp", "mkcp")
}
