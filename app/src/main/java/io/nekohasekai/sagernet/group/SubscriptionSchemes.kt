package io.nekohasekai.sagernet.group

/**
 * S8: the share-link schemes of the subscription parser (`OutboundFactory.PROTOCOLS`, i.e. the
 * desktop's SubscriptionParser.cpp kProtocols), kept here so callers that only need to recognise a
 * node link do not depend on the Kotlin outbound factory. The scheme-to-type mapping itself still
 * lives with the importer until the Go `profileImport` action owns it.
 */
object SubscriptionSchemes {

    /** Every scheme of kProtocols, in its order; matching is case-sensitive, like typeForScheme. */
    private val SCHEMES = listOf(
        "socks5://", "socks4://", "socks4a://", "socks://",
        "http://", "https://",
        "ss://", "vmess://", "vless://", "trojan://",
        "anytls://", "mierus://", "mieru://", "snell://",
        "hysteria://", "hysteria2://", "hy2://",
        "tuic://", "juicity://", "tt://", "shadowtls://",
        "awg://", "wg://", "wireguard://",
        "ssh://", "naive+https://", "naive+quic://",
    )

    /** `OutboundFactory.typeForScheme(line) != null`. */
    @JvmStatic
    fun isNodeLink(line: String): Boolean = SCHEMES.any { line.startsWith(it) }
}
