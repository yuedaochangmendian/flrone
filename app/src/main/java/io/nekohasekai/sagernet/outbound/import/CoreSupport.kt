package io.nekohasekai.sagernet.outbound.import

import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.common.Transport
import io.nekohasekai.sagernet.outbound.types.Custom

/**
 * Issue #63 (Android only): a node the core it would run in rejects, or that the parse silently turned into plain
 * TCP, is not imported. Each check returns the reason for the import log, or null when the core can run the node;
 * what the profile's own validation already reports is not checked again. The sets follow the pinned core: sing-box
 * constant/v2ray.go.
 */
internal object CoreSupport {

    /** sing-box's V2Ray transports; empty and "tcp" mean none. kcp is the kernel's alias of mkcp. */
    private val SING_BOX_TRANSPORTS = setOf("", "tcp", "http", "ws", "quic", "grpc", "httpupgrade", "xhttp", "mkcp", "kcp")

    /** The Clash networks Transport.parseFromClash maps, to the transport types each may become. */
    private val CLASH_NETWORKS = mapOf(
        "ws" to setOf("ws", "httpupgrade"),
        "h2" to setOf("http"),
        "http" to setOf("http"),
        "grpc" to setOf("grpc"),
        "xhttp" to setOf("xhttp"),
        "kcp" to setOf("mkcp"),
        "mkcp" to setOf("mkcp"),
    )

    /**
     * Why the core would not run [outbound]; null when it can. Only what [Outbound.validate] leaves out: it already
     * reports the Shadowsocks plugin, the transport type and QUIC without TLS.
     */
    fun problem(outbound: Outbound): String? = when {
        outbound is Custom -> customProblem(outbound)
        outbound.hasTransport() -> transportProblem(outbound.getTransport(), outbound.getTls().enabled)
        else -> null
    }

    /**
     * What the Clash entry asked for that its parse dropped without a trace; null when nothing was lost. An
     * unsupported Shadowsocks plugin is reported by Shadowsocks.parseFromClash itself.
     */
    fun clashProblem(proxy: ClashProxy, outbound: Outbound): String? {
        if (!outbound.hasTransport()) return null
        val network = proxy.string("network").lowercase()
        if (network.isEmpty() || network == "tcp") return null
        if (CLASH_NETWORKS[network]?.contains(outbound.getTransport().type) == true) return null
        return transportTypeProblem(network) ?: "the Clash network \"$network\" could not be converted"
    }

    private fun transportProblem(transport: Transport, tls: Boolean): String? {
        // with TLS on, sing-box's http transport speaks HTTP/2 (v2rayhttp/client.go), which a raw-header server does not
        if (transport.type == "http" && transport.rawHttpHeader && tls) return "sing-box cannot send the raw TCP HTTP header over TLS"
        return null
    }

    private fun transportTypeProblem(type: String): String? = when {
        type in SING_BOX_TRANSPORTS -> null
        else -> "sing-box has no \"$type\" transport"
    }

    private fun customProblem(custom: Custom): String? = when (custom.subtype) {
        Custom.CUSTOM_OUTBOUND -> transportTypeProblem(custom.configObject().obj("transport").string("type"))
        else -> null
    }
}
