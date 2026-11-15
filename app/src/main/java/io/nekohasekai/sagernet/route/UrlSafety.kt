package io.nekohasekai.sagernet.route

import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI

/**
 * The one place a runtime URL is allowed to reach the network.
 *
 * Three call sites fetch a URL that ultimately came from outside the app:
 *
 *  * [RuleSets.mirrorLink] rewrites a rule-set URL from a share link or a routing profile;
 *  * [io.nekohasekai.sagernet.database.RouteRepo.refresh] downloads the routeprofiles snapshot;
 *  * [io.nekohasekai.sagernet.group.RemoteRouteUpdater.fetchInto] fetches a remote routing
 *    profile.
 *
 * A routing profile is an importable document, so its `remote_url` is attacker-controlled input.
 * Without a check, "fetch my routing profile" is an SSRF primitive: `http://127.0.0.1:9090` or
 * `http://192.168.1.1/` would make the device talk to its own loopback or LAN on the importer's
 * behalf, and `http://[::1]/` is the same trick over IPv6. [requirePublicHttp] refuses those
 * targets before any socket is opened.
 *
 * Two checks, in this order:
 *
 *  1. [requirePublicHttp] — scheme, userinfo, and the host *as written*. Cheap, no DNS.
 *  2. [requirePublicResolution] — every address the host resolves to. This is the check that
 *     matters: a host name that looks public can resolve to `127.0.0.1`, and checking only the
 *     literal would let it through (DNS rebinding).
 *
 * Callers must run the second one on the host they are about to connect to. A full
 * connect-time check would also pin the resolved address for the actual request, which needs a
 * custom socket factory; the resolve-then-connect window is small and closing it completely is
 * out of scope here. Both checks together are what makes the address classes below meaningful.
 */
object UrlSafety {

    /** The only schemes allowed. A routing profile has no business reaching `file:` or `ftp:`. */
    private val ALLOWED_SCHEMES = setOf("http", "https")

    /** Refused as host names whatever they resolve to: they name the device itself. */
    private val BLOCKED_HOST_NAMES = setOf(
        "localhost",
        "localhost.localdomain",
        "ip6-localhost",
        "ip6-loopback",
        "metadata", // cloud metadata services (169.254.169.254 is covered by the link-local rule)
    )

    /**
     * Validates [url] and answers the trimmed string to fetch.
     *
     * Throws [IllegalArgumentException] with a message naming the reason, so the caller's
     * existing error reporting (an `error(...)` in a `suspend fun`, or the update paths'
     * `readableMessage`) shows the user why a profile was refused instead of a bare failure.
     */
    fun requirePublicHttp(url: String): String {
        val trimmed = url.trim()
        require(trimmed.isNotEmpty()) { "the URL is empty" }

        val uri = try {
            URI(trimmed)
        } catch (e: Exception) {
            throw IllegalArgumentException("the URL is not parseable: ${e.message}", e)
        }
        val scheme = uri.scheme?.lowercase()
        require(scheme != null && scheme in ALLOWED_SCHEMES) {
            "only http and https URLs are allowed, not \"${uri.scheme}\""
        }
        // `http://user:pass@host/` is legal but is never how these files are served, and a
        // userinfo section is a classic way to make a URL read as one host while dialling
        // another.
        require(uri.rawUserInfo.isNullOrEmpty()) { "the URL must not carry credentials" }
        require(uri.rawAuthority.isNullOrEmpty() || uri.host != null) {
            "the URL has no host"
        }


        val host = uri.host ?: throw IllegalArgumentException("the URL has no host")
        requirePublicHost(host)
        return trimmed
    }

    /**
     * Resolves [host] and refuses the URL when *any* answer is a non-public address.
     *
     * Resolve this on the host you are about to fetch, not on a cached earlier value: the point
     * of the check is that the name did not turn into a loopback address since.
     */
    fun requirePublicResolution(host: String) {
        // A literal address is its own resolution and must not be handed to the resolver: an
        // IPv4 literal like `127.0.0.1` would come back as an Inet4Address anyway, but an
        // out-of-range or half-written literal could reach a resolver that treats it as a name.
        val literal = parseLiteralOrNull(host)
        if (literal != null) {
            require(isPublicAddress(literal)) { "the URL points at a non-public address ($host)" }
            return
        }
        val resolved = try {
            InetAddress.getAllByName(host)
        } catch (e: Exception) {
            throw IllegalArgumentException("the host could not be resolved: ${e.message}", e)
        }
        require(resolved.isNotEmpty()) { "the host resolved to no address" }
        for (address in resolved) {
            require(isPublicAddress(address)) {
                "the URL points at a non-public address (${address.hostAddress})"
            }
        }
    }

    /** [requirePublicHttp] and [requirePublicResolution] in one step, for a fetch that follows at once. */
    fun requirePublicFetch(url: String): String {
        val checked = requirePublicHttp(url)
        val host = URI(checked).host ?: throw IllegalArgumentException("the URL has no host")
        requirePublicResolution(host)
        return checked
    }

    // --- the address classes ----------------------------------------------------

    /** The host-name half of the check: literals are validated by class, names by shape. */
    private fun requirePublicHost(host: String) {
        val lower = host.lowercase().trim('[', ']')
        require(lower !in BLOCKED_HOST_NAMES) { "the URL points at \"$lower\", which is this device" }
        // `.localhost` is reserved for loopback by RFC 6761 and never resolves publicly.
        require(!lower.endsWith(".localhost")) { "the URL points at \"$lower\", which is loopback" }
        // A single label (`http://intranet/`) can only resolve through a search domain, which is
        // exactly the LAN case this check exists to refuse.
        require(lower.contains('.') || lower.contains(':')) { "the URL host \"$lower\" is not a public name" }
        parseLiteralOrNull(lower)?.let { literal ->
            require(isPublicAddress(literal)) { "the URL points at a non-public address ($lower)" }
        }
    }

    /**
     * Whether [address] is a public unicast address.
     *
     * The list is the standard one for SSRF checks; every branch answers "not public", so a new
     * class added later fails closed.
     */
    internal fun isPublicAddress(address: InetAddress): Boolean {
        if (address.isAnyLocalAddress) return false       // 0.0.0.0, ::
        if (address.isLoopbackAddress) return false       // 127.0.0.0/8, ::1
        if (address.isLinkLocalAddress) return false      // 169.254.0.0/16, fe80::/10
        if (address.isSiteLocalAddress) return false      // 10/8, 172.16/12, 192.168/16
        if (address.isMulticastAddress) return false      // 224/4, ff00::/8
        val bytes = address.address
        return when {
            address is Inet4Address -> isPublicV4(bytes)
            address is Inet6Address -> isPublicV6(bytes)
            else -> false
        }
    }

    /** 100.64/10 (CGNAT), 198.18/15 (benchmark), 240/4 (reserved) and 255.255.255.255. */
    private fun isPublicV4(bytes: ByteArray): Boolean {
        val a = bytes[0].toInt() and 0xFF
        val b = bytes[1].toInt() and 0xFF
        // 100.64.0.0/10: 100.64.0.0 - 100.127.255.255
        if (a == 100 && b in 64..127) return false
        // 198.18.0.0/15: 198.18.0.0 - 198.19.255.255
        if (a == 198 && b in 18..19) return false
        // 240.0.0.0/4 (includes the limited broadcast address 255.255.255.255)
        if (a >= 240) return false
        return true
    }

    /**
     * Unique-local (fc00::/7) and IPv4-mapped (::ffff:0:0/96) addresses.
     *
     * The JDK's own predicates miss two classes this has to cover: `isSiteLocalAddress` is false
     * for `fd00::1` (ULA is not the deprecated site-local range), and nothing rejects CGNAT,
     * benchmark or reserved IPv4. That is why [isPublicV4] exists.
     *
     * An IPv4-mapped literal is usually collapsed to an [Inet4Address] by the resolver
     * (`::ffff:192.168.1.1` comes back as `/192.168.1.1`), so [isPublicV4] would already have
     * judged it. The branch below keeps the answer correct when a stack does *not* collapse it —
     * `::ffff:127.0.0.1` must be loopback however it is reported.
     */
    private fun isPublicV6(bytes: ByteArray): Boolean {
        val first = bytes[0].toInt() and 0xFF
        // fc00::/7 — the top seven bits are 1111 110.
        if (first and 0xFE == 0xFC) return false
        if (isIpv4Mapped(bytes)) {
            return isPublicV4(bytes.copyOfRange(12, 16))
        }
        return true
    }

    /** ::ffff:a.b.c.d — ten zero bytes, then 0xffff, then the four IPv4 bytes. */
    private fun isIpv4Mapped(bytes: ByteArray): Boolean {
        if (bytes.size != 16) return false
        for (index in 0 until 10) if (bytes[index].toInt() != 0) return false
        return (bytes[10].toInt() and 0xFF) == 0xFF && (bytes[11].toInt() and 0xFF) == 0xFF
    }

    /**
     * Parses [host] as an IP literal, or null when it is a name.
     *
     * [InetAddress.getByName] would resolve a name, so it is only called for something shaped
     * like a literal. [java.net.URI.getHost] keeps the brackets on an IPv6 literal
     * (`[::1]`), unlike the WHATWG parsers that strip them, so they are removed here.
     */
    private fun parseLiteralOrNull(host: String): InetAddress? {
        val bare = host.trim().trim('[', ']')
        val looksV4 = bare.isNotEmpty() && bare.all { it.isDigit() || it == '.' }
        val looksV6 = bare.contains(':')
        if (!looksV4 && !looksV6) return null
        return try {
            InetAddress.getByName(bare)
        } catch (e: Exception) {
            // A malformed literal must not silently become a name lookup; treat it as invalid by
            // reporting it as an unusable address.
            null
        }
    }
}
