package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.link.Base64Strict
import io.nekohasekai.sagernet.document.link.Hosts
import io.nekohasekai.sagernet.document.link.LinkParser

/**
 * S8: the display and security facts of a stored profile row, read from the two contract columns
 * ([ProxyEntity.type], [ProxyEntity.outboundJson]) instead of by re-parsing the row into the Kotlin
 * outbound model.
 *
 * The values are the ones `Outbound.displayType()`, `displayName()`, `displayAddress()`,
 * `effectiveSecurity()`, `exportJsonLink(stripMetadata)` and `isEndpoint()` answer, derived per type
 * from the stored document. The document already is the compact `ExportToJson` (the data contract,
 * ProxyEntity's note), so the derivations read it directly:
 *
 * - the type label is a property of the type, a static table (the desktop's untranslated display
 *   strings); `custom` is the only type whose label also reads the row's own config;
 * - the address is per type: the plain `server:port`, or the type's own shape (a direct profile's
 *   bind fields, a chain's empty address, an auto selector's tracked group names, a custom config's
 *   own server, a wireguard peer, a hysteria realm's rendezvous host, an openconnect URL);
 * - the security verdict follows `GetSecurity` (per type: TLS state, cipher, host key, TLS pins,
 *   AMNEZIA, encryption) plus `EffectiveSecurity` (the global skip_cert setting and a private
 *   server address), so sorting and the sync filters agree with the old model.
 *
 * The same rendering difference the Dart document service documents applies here: a row whose
 * stored JSON disagrees with what the writer produces (hand-edited documents, a name column that no
 * longer matches a missing `tag`) is read from the columns and the document as they are, never
 * re-normalized. Every row the app itself wrote is byte-identical to the old model's answer.
 *
 * The JSON reader (`document.json.JsonInput`/`JsonObject`) and the host helpers
 * (`document.link.Hosts`, `LinkParser`, `Base64Strict`) now live outside the outbound package;
 * the remaining outbound model is the Kotlin fallback S8 has not retired yet.
 */
object StoredProfile {

    /** Outbound.h:23-28 `SecurityLevel`, same order: sorting uses the ordinal. */
    enum class Level { Unknown, None, Weak, Secure }

    /** Outbound.h:36-54 `SecurityInfo`, reduced to what the consumers read. */
    data class Security(
        val level: Level = Level.Unknown,
        val label: String = "",
        val transport: String = "",
        /** Secure only through the CA check, which the global skip_cert setting turns off. */
        val caVerified: Boolean = false,
        /** Weakened by that global setting rather than by the profile itself. */
        val compromised: Boolean = false,
    ) {
        /** `SecurityInfo.isInsecure`: dangerous, and not a global setting's doing. */
        val insecure: Boolean
            get() = (level == Level.None || level == Level.Weak) && !compromised
    }

    private const val CUSTOM = "custom"

    /** OutboundFactory's `displayType()` labels by factory string. */
    private val TYPE_LABELS = mapOf(
        "socks" to "Socks",
        "http" to "HTTP",
        "shadowsocks" to "Shadowsocks",
        "vmess" to "VMess",
        "vless" to "VLESS",
        "trojan" to "Trojan",
        "hysteria" to "Hysteria",
        "tuic" to "TUIC",
        "juicity" to "Juicity",
        "trusttunnel" to "TrustTunnel",
        "anytls" to "AnyTLS",
        "mieru" to "Mieru",
        "snell" to "Snell",
        "shadowtls" to "ShadowTLS",
        "wireguard" to "WireGuard",
        "masque" to "MASQUE",
        "openvpn" to "OpenVPN",
        "openconnect" to "OpenConnect",
        "ssh" to "SSH",
        "naive" to "Naive",
        "chain" to "Chain Proxy",
        "autoselector" to "Auto Selector",
        "direct" to "Direct",
    )

    /** OutboundFactory.TYPE_ALIASES: old/hand-written rows may carry the URI type. */
    private val TYPE_ALIASES = mapOf("hysteria2" to "hysteria", "openvpn-client" to "openvpn")

    /** The types `OutboundFactory.newByType` resolves to a real outbound (ALL_TYPES minus UNSUPPORTED_TYPES). */
    private val KNOWN_TYPES = setOf(
        "socks", "http", "shadowsocks", "chain", "autoselector", "vmess", "trojan", "vless", "hysteria",
        "tuic", "juicity", "trusttunnel", "anytls", "mieru", "snell", "shadowtls", "wireguard", "masque",
        "openvpn", "openconnect", "ssh", "custom", "naive", "direct",
    )

    /** The types that carry the sing-box TLS block (`Outbound.hasTls`). */
    private val TLS_TYPES = setOf(
        "http", "trojan", "vless", "vmess", "hysteria", "tuic", "juicity", "trusttunnel",
        "anytls", "naive", "shadowtls", "masque",
    )

    /** The types whose TLS block is on regardless of `enabled` (`Outbound.mustTls`). */
    private val MUST_TLS_TYPES = setOf(
        "anytls", "hysteria", "juicity", "masque", "naive", "shadowtls", "trusttunnel", "tuic",
    )

    /** The types that carry a transport (`Outbound.hasTransport`): the v2ray ones. */
    private val TRANSPORT_TYPES = setOf("trojan", "vless", "vmess")

    /** shadowsocks::GetSecurity: pre-AEAD stream ciphers. */
    private val STREAM_CIPHERS = setOf(
        "aes-128-ctr", "aes-192-ctr", "aes-256-ctr", "aes-128-cfb", "aes-192-cfb", "aes-256-cfb",
        "rc4-md5", "chacha20-ietf", "xchacha20",
    )

    /** OutboundFactory.canonicalType. */
    @JvmStatic
    fun canonicalType(type: String): String = TYPE_ALIASES[type] ?: type

    /** Whether `OutboundFactory.newByType` constructs a real outbound for [type]. */
    @JvmStatic
    fun isKnownType(type: String): Boolean = canonicalType(type) in KNOWN_TYPES

    /**
     * `ProxyEntity.parseOutbound` answers an `InvalidOutbound` for an unknown/unsupported type and for
     * stored JSON that is not a JSON object; a blank document is a fresh profile, not invalid.
     */
    @JvmStatic
    fun isInvalidDocument(type: String, json: String): Boolean =
        !isKnownType(type) || (json.isNotBlank() && JsonInput.parseObjectOrNull(json) == null)

    // ------------------------------------------------------------------------------------------------ labels

    /**
     * `Outbound.displayType()`: the type's label, "" where the old model answered "" (an unknown type,
     * or a row whose document could not be read).
     */
    @JvmStatic
    fun label(type: String, json: String): String {
        if (!isKnownType(type)) return ""
        val document = document(json) ?: return ""
        val canonical = canonicalType(type)
        if (canonical == CUSTOM) return customLabel(document)
        return TYPE_LABELS[canonical].orEmpty()
    }

    /** `ProxyEntity.displayType()`: [label], else the stored type. */
    @JvmStatic
    fun displayType(type: String, json: String): String = label(type, json).ifEmpty { type }

    /**
     * `Outbound.displayName()` with the stored name column: the name, else the address. (The column is
     * documented as a copy of the outbound's name; a document whose name column and `tag` disagree is
     * read from the column, like the catalog always did.)
     */
    @JvmStatic
    fun outboundName(name: String?, type: String, json: String): String {
        val stored = name.orEmpty()
        if (stored.isNotEmpty()) return stored
        return displayAddress(type, json)
    }

    /** `ProxyEntity.displayName()`: [outboundName], else the type. */
    @JvmStatic
    fun displayName(name: String?, type: String, json: String): String =
        outboundName(name, type, json).ifEmpty { displayType(type, json) }

    /** `Outbound.displayTypeAndName()`: the raw pair, so a row with neither name nor address ends in "] ". */
    @JvmStatic
    fun displayTypeAndName(name: String?, type: String, json: String): String =
        "[${label(type, json)}] ${outboundName(name, type, json)}"

    private fun customLabel(document: JsonObject): String = when (val subtype = document.string("subtype").trim()) {
        "outbound" -> {
            val outboundType = capitalized(configObject(document).string("type"))
            if (outboundType.isEmpty()) "Custom Outbound" else "Custom $outboundType Outbound"
        }

        "fullconfig" -> "Custom Config"
        else -> subtype
    }

    private fun capitalized(value: String): String =
        if (value.isEmpty()) value else value[0].uppercaseChar() + value.substring(1)

    // ------------------------------------------------------------------------------------------------ addresses

    /** `Outbound.displayAddress()`: the type's own rendering of the row's server, "" where it has none. */
    @JvmStatic
    fun displayAddress(type: String, json: String): String {
        if (!isKnownType(type)) return ""
        val document = document(json) ?: return ""
        return when (canonicalType(type)) {
            // chain.h:14.
            "chain" -> ""
            "autoselector" -> autoSelectorAddress(document)
            "direct" -> directAddress(document)
            "custom" -> customAddress(document)
            "hysteria" -> hysteriaAddress(document)
            // wireguard::DisplayAddress: the first peer carries the server.
            "wireguard" -> firstPeer(document).let { Hosts.displayAddress(it.string("address"), it.int("port")) }
            "openconnect" -> openConnectAddress(document)
            // masque's constructor starts at 443 (masque.h:21-26); the parse only replaces an explicit server_port.
            "masque" -> Hosts.displayAddress(
                Hosts.toAceHost(document.string("server")),
                if (document.contains("server_port")) document.int("server_port") else OPEN_CONNECT_DEFAULT_PORT,
            )

            else -> baseAddress(document)
        }
    }

    /** `Outbound.getAddress()`: what `effectiveSecurity` tests for a private server. */
    private fun connectAddress(canonical: String, document: JsonObject): String = when (canonical) {
        // Custom::GetAddress: only raw outbound JSON names a server.
        "custom" -> if (document.string("subtype").trim() == "outbound") configObject(document).string("server") else ""
        // WireGuard::getAddress.
        "wireguard" -> firstPeer(document).string("address")
        "chain", "autoselector", "direct" -> ""
        "openconnect" -> openConnectServer(document)
        else -> Hosts.toAceHost(document.string("server"))
    }

    /** outbound::DisplayAddress / getAddress: the ACE host and the port. */
    private fun baseAddress(document: JsonObject): String =
        Hosts.displayAddress(Hosts.toAceHost(document.string("server")), document.int("server_port"))

    private fun firstPeer(document: JsonObject): JsonObject {
        val peers = document.array("peers")
        return if (peers.isEmpty()) JsonObject() else peers[0] as? JsonObject ?: JsonObject()
    }

    /** autoselector.cpp:9-15: the tracked groups' names, "" tracked, "no group" / "missing group". */
    private fun autoSelectorAddress(document: JsonObject): String {
        // autoselector.h ParseFromJson: "gids" wins over the older single "gid"; ids below 0 are dropped.
        val gids: List<Long> = if (document.contains("gids")) {
            document.array("gids").mapNotNull { longOr(it).takeIf { id -> id >= 0 } }
        } else if (document.contains("gid")) {
            longOr(document["gid"]).takeIf { it >= 0 }?.let(::listOf).orEmpty()
        } else {
            emptyList()
        }
        if (gids.isEmpty()) return "no group"
        // The old model read this through the group-names hook, GroupRepo.get(gid)?.displayName().
        // A document read failure renders "missing group" instead of aborting the caller (the
        // catalog and the sort worker both call this while the document is the failing part).
        val names = gids.mapNotNull { runCatching { GroupRepo.get(it)?.displayName() }.getOrNull() }
        return if (names.isEmpty()) "missing group" else names.joinToString(", ")
    }

    /** autoSelector's QJsonValue::toInt(id, -1): a whole number or the default. */
    private fun longOr(value: Any?): Long = when (value) {
        is Long -> value
        is Double -> if (value == Math.rint(value) && value >= Long.MIN_VALUE.toDouble() && value < Long.MAX_VALUE.toDouble()) {
            value.toLong()
        } else {
            -1L
        }

        else -> -1L
    }

    /** direct.h:13-18 (the missing ": " after "Bind Addr6" is the desktop's). */
    private fun directAddress(document: JsonObject): String {
        val bindInterface = document.string("bind_interface")
        val bindV4 = document.string("inet4_bind_address").trim()
        val bindV6 = document.string("inet6_bind_address").trim()
        return when {
            bindInterface.isNotEmpty() -> "Bind NIC: $bindInterface"
            bindV4.isNotEmpty() -> "Bind Addr4: $bindV4"
            bindV6.isNotEmpty() -> "Bind Addr6$bindV6"
            else -> "Empty"
        }
    }

    /** custom.cpp: only a raw outbound JSON has a server. */
    private fun customAddress(document: JsonObject): String {
        if (document.string("subtype").trim() != "outbound") return ""
        val config = configObject(document)
        return Hosts.displayAddress(config.string("server"), config.int("server_port"))
    }

    /** Hysteria's realm replaces server/server_port with a rendezvous URL (`realmActive`). */
    private fun hysteriaAddress(document: JsonObject): String {
        val protocolVersion = when (document.string("type")) {
            "hysteria" -> "1"
            "hysteria2" -> "2"
            // ParseFromJson refuses other type strings before reading anything.
            else -> return ""
        }
        if (document.isObject("realm") && protocolVersion == "2") {
            val realm = document.obj("realm")
            val serverUrl = realm.string("server_url").trim()
            val realmId = realm.string("realm_id")
            var host = prettyHost(LinkParser.parse(serverUrl).host)
            if (host.isEmpty()) host = serverUrl
            return if (realmId.isEmpty()) host else "$realmId@$host"
        }
        return baseAddress(document)
    }

    /** openconnect::DisplayAddress (composeServer): host, non-default port, path. */
    private fun openConnectAddress(document: JsonObject): String {
        val server = openConnectServer(document)
        if (server.isEmpty()) return ""
        // ParseFromJson: the server URL's path first, then an explicit server_path wins.
        var path = ""
        if (document.contains("server")) {
            val parsed = parseOpenConnectServerUrl(document.string("server"))
            if (parsed != null) {
                path = parsed.path
                if (path == "/") path = ""
            }
        }
        if (document.contains("server_path")) path = document.string("server_path")
        val url = StringBuilder(wrapIpv6Host(server))
        val port = openConnectPort(document)
        if (port > 0 && port != OPEN_CONNECT_DEFAULT_PORT) url.append(':').append(port)
        if (path.isNotEmpty()) {
            url.append(if (path.startsWith("/")) path else "/$path")
        }
        return url.toString()
    }

    private class OpenConnectUrl(val host: String, val port: Int, val path: String)

    /** openconnect::SetServerUrl: a URL or bare host[:port][/path]; null when it would leave the fields alone. */
    private fun parseOpenConnectServerUrl(raw: String): OpenConnectUrl? {
        var text = trimUnicodeSpace(raw)
        if (text.isEmpty()) return null
        if (!text.contains("://")) text = "https://" + wrapIpv6Host(text)
        val parsed = LinkParser.parse(text)
        if (!parsed.isValid || parsed.host.isEmpty()) return null
        return OpenConnectUrl(parsed.host, parsed.port, parsed.path)
    }

    /** The row's server after `SetServerUrl` (which overrides the base server when the text parses). */
    private fun openConnectServer(document: JsonObject): String {
        var server = Hosts.toAceHost(document.string("server"))
        if (document.contains("server")) {
            val parsed = parseOpenConnectServerUrl(document.string("server"))
            if (parsed != null) server = parsed.host
        }
        return server
    }

    private fun openConnectPort(document: JsonObject): Int {
        var port = document.int("server_port")
        if (document.contains("server")) {
            val parsed = parseOpenConnectServerUrl(document.string("server"))
            if (parsed != null && parsed.port > 0) port = parsed.port
        }
        return port
    }

    private const val OPEN_CONNECT_DEFAULT_PORT = 443

    /** WrapIPV6Host (Utils.hpp). */
    private fun wrapIpv6Host(host: String): String =
        if (!Hosts.isIpv6Address(host)) host else "[" + host.replace("[", "").replace("]", "") + "]"

    /** OpenVpn's isSpace-aware trim (vpnFileImport's trimmed). */
    private fun trimUnicodeSpace(text: String): String {
        var start = 0
        var end = text.length
        while (start < end && isUnicodeSpace(text[start])) start++
        while (end > start && isUnicodeSpace(text[end - 1])) end--
        return text.substring(start, end)
    }

    private fun isUnicodeSpace(c: Char): Boolean {
        if (c == ' ' || c in '\t'..'\r' || c == '\u0085' || c == '\u00a0') return true
        val type = Character.getType(c)
        return type == Character.SPACE_SEPARATOR.toInt() || type == Character.LINE_SEPARATOR.toInt() ||
            type == Character.PARAGRAPH_SEPARATOR.toInt()
    }

    /** Hysteria's prettyHost(host, bracketed = false): the zone id decoded, ACE labels in Unicode. */
    private fun prettyHost(hostFullyEncoded: String): String {
        if (hostFullyEncoded.contains(':')) return hostFullyEncoded.replace("%25", "%")
        if (!hostFullyEncoded.contains("xn--")) return hostFullyEncoded
        return hostFullyEncoded.split('.').joinToString(".") { label ->
            if (label.startsWith("xn--")) punycodeDecode(label.substring(4)) ?: label else label
        }
    }

    /** RFC 3492 section 6.2, copied from Hysteria's decoder: null where Qt keeps the ACE label. */
    private fun punycodeDecode(input: String): String? {
        val output = ArrayList<Int>()
        var n = 128
        var i = 0
        var bias = 72
        val delimiter = input.lastIndexOf('-')
        val basicEnd = if (delimiter > 0) delimiter else 0
        for (j in 0 until basicEnd) {
            val c = input[j]
            if (c.code >= 0x80) return null
            output.add(c.code)
        }
        var pos = if (delimiter > 0) delimiter + 1 else 0
        while (pos < input.length) {
            val oldI = i
            var w = 1
            var k = 36
            while (true) {
                if (pos >= input.length) return null
                val c = input[pos++]
                val digit = when (c) {
                    in 'a'..'z' -> c - 'a'
                    in 'A'..'Z' -> c - 'A'
                    in '0'..'9' -> c - '0' + 26
                    else -> return null
                }
                if (digit > (Int.MAX_VALUE - i) / w) return null
                i += digit * w
                val t = if (k <= bias) 1 else if (k >= bias + 26) 26 else k - bias
                if (digit < t) break
                if (w > Int.MAX_VALUE / (36 - t)) return null
                w *= 36 - t
                k += 36
            }
            val count = output.size + 1
            bias = punycodeAdapt(i - oldI, count, oldI == 0)
            if (i / count > Int.MAX_VALUE - n) return null
            n += i / count
            i %= count
            if (n > 0x10FFFF || (n in 0xD800..0xDFFF)) return null
            output.add(i, n)
            i++
        }
        val sb = StringBuilder()
        for (cp in output) sb.appendCodePoint(cp)
        return sb.toString()
    }

    private fun punycodeAdapt(delta0: Int, numPoints: Int, firstTime: Boolean): Int {
        var delta = if (firstTime) delta0 / 700 else delta0 / 2
        delta += delta / numPoints
        var k = 0
        while (delta > ((36 - 1) * 26) / 2) {
            delta /= 36 - 1
            k += 36
        }
        return k + (36 - 1 + 1) * delta / (delta + 38)
    }

    // ------------------------------------------------------------------------------------------------ security

    /**
     * `Outbound.effectiveSecurity(skipCert)`: the profile's own verdict, degraded by the global
     * skip_cert setting where the CA chain was the guarantee, and upgraded to "Private" when the
     * dangerous verdict only reaches a private address.
     */
    @JvmStatic
    fun security(type: String, json: String, skipCert: Boolean): Security {
        if (isInvalidDocument(type, json)) {
            // InvalidOutbound keeps the base security: Raw, and thus insecure.
            return Security(Level.None, "Raw", "")
        }
        val document = document(json) ?: return Security()
        val canonical = canonicalType(type)
        var verdict = ownSecurity(canonical, document)
        // EffectiveSecurity: only the CA check is weakened by skip_cert, and only where TLS was on.
        if (verdict.caVerified && canonical in TLS_TYPES && canonical != "naive" && skipCert) {
            verdict = verdict.copy(level = Level.Weak, label = "Compromised", compromised = true)
        }
        if (verdict.level != Level.None && verdict.level != Level.Weak) return verdict
        return withPrivateServer(verdict, connectAddress(canonical, document))
    }

    /** Outbound.cpp WithPrivateServer: traffic to a private address never crosses the internet. */
    private fun withPrivateServer(verdict: Security, host: String): Security {
        if ((verdict.level == Level.None || verdict.level == Level.Weak) && Hosts.isPrivateHost(host)) {
            return verdict.copy(level = Level.Secure, label = "Private", compromised = false)
        }
        return verdict
    }

    /** `Outbound.security()` per type. */
    private fun ownSecurity(canonical: String, document: JsonObject): Security = when (canonical) {
        // Direct/chain/autoselector give no verdict of their own.
        "direct", "chain", "autoselector" -> Security()
        "mieru", "snell" -> Security(Level.Secure, "Encrypted", "")
        // wireguard::GetSecurity.
        "wireguard" -> Security(
            Level.Secure, "Encrypted", if (document.obj("amnezia_wg").isNotEmpty()) "AmneziaWG" else "",
        )
        // shadowsocks::GetSecurity.
        "shadowsocks" -> when {
            document.string("method").isEmpty() || document.string("method") == "none" ->
                Security(Level.None, "Raw", "")
            document.string("method") in STREAM_CIPHERS -> Security(Level.Weak, "Weak Cipher", "")
            else -> Security(Level.Secure, "Encrypted", "")
        }
        // ssh::GetSecurity.
        "ssh" -> if (hasTextItems(document["host_key"])) {
            Security(Level.Secure, "Encrypted", "")
        } else {
            Security(Level.Weak, "Unverified Host Key", "")
        }
        // openvpn::GetSecurity.
        "openvpn" -> {
            val tls = document.obj("tls")
            if (document.string("mode").trim() == "static_key") {
                Security(Level.Weak, "Static Key", "")
            } else if (listableItems(tls["certificate"]) || tls.string("certificate_path").isNotEmpty() ||
                listableItems(tls["peer_fingerprint"])
            ) {
                Security(Level.Secure, "TLS", "")
            } else {
                Security(Level.Weak, "Unverified TLS", "")
            }
        }
        // openconnect::GetSecurity.
        "openconnect" -> {
            val tls = document.obj("tls")
            if (tls.bool("insecure") && !listableItems(tls["peer_fingerprint"])) {
                Security(Level.Weak, "Insecure TLS", "")
            } else {
                Security(Level.Secure, "TLS", "")
            }
        }
        // masque.cpp:123-128: the peer key pins the certificate.
        "masque" -> if (document.string("peer_public_key").isNotEmpty()) {
            Security(Level.Secure, "TLS", "")
        } else {
            tlsSecurity(canonical, document, "")
        }
        "custom" -> customSecurity(document)
        "hysteria", "juicity", "tuic" -> tlsSecurity(canonical, document, "QUIC")
        "naive", "trusttunnel" -> tlsSecurity(canonical, document, if (document.bool("quic")) "QUIC" else "")
        // vmess::GetSecurity: encrypted, but without TLS it still counts as insecure.
        "vmess" -> {
            val base = tlsSecurity(canonical, document, transportName(document))
            val security = document.string("security")
            if (base.level == Level.None && security != "none" && security != "zero") {
                base.copy(level = Level.Weak, label = "Insecure")
            } else {
                base
            }
        }
        // Outbound.security(): the transport is only part of the verdict for the types that carry one.
        else -> tlsSecurity(canonical, document, if (canonical in TRANSPORT_TYPES) transportName(document) else "")
    }

    /** Outbound.cpp SecurityFromTLS. */
    private fun tlsSecurity(canonical: String, document: JsonObject, transport: String): Security {
        if (canonical !in TLS_TYPES) return Security(Level.None, "Raw", transport)
        val tls = document.obj("tls")
        val reality = tls.obj("reality")
        // Tls::ParseFromJson turns TLS on for a reality public key.
        val enabled = tls.bool("enabled") || reality.string("public_key").isNotEmpty()
        if (!enabled && canonical !in MUST_TLS_TYPES) return Security(Level.None, "Raw", transport)
        return when {
            reality.bool("enabled") -> Security(Level.Secure, "Reality", transport)
            hasTextItems(tls["certificate_sha256"]) || hasTextItems(tls["certificate_public_key_sha256"]) ->
                Security(Level.Secure, "TLS", transport)
            tls.bool("insecure") -> Security(Level.Weak, "Insecure TLS", transport)
            else -> Security(Level.Secure, "TLS", transport, caVerified = true)
        }
    }

    /** DisplayTransportName (Outbound.cpp:5-16), for the types that carry a transport. */
    private fun transportName(document: JsonObject): String {
        val type = document.obj("transport").string("type")
        return when (type) {
            "", "tcp", "raw" -> ""
            "ws" -> "WebSocket"
            "grpc" -> "gRPC"
            "http" -> "HTTP"
            "httpupgrade" -> "HTTPUpgrade"
            "xhttp" -> "XHTTP"
            "mkcp" -> "mKCP"
            "quic" -> "QUIC"
            else -> type.uppercase()
        }
    }

    /** custom.cpp:176-196: the verdict of the outbound the config actually exits through. */
    private fun customSecurity(document: JsonObject): Security = when (document.string("subtype").trim()) {
        "outbound" -> analyzeSingBox(configObject(document))
        "fullconfig" -> {
            val egress = singBoxEgress(configObject(document))
            if (egress.isEmpty()) Security() else analyzeSingBox(egress)
        }

        else -> Security()
    }

    /** custom.cpp:20-30: an outbound of an unknown or not yet ported type has no verdict. */
    private fun analyzeSingBox(document: JsonObject): Security {
        val type = document.string("type")
        if (type.isEmpty() || type == "custom" || type == "selector" || type == "urltest" || isSingBoxInfra(type)) {
            return Security()
        }
        if (!isKnownType(type)) return Security()
        val canonical = canonicalType(type)
        return withPrivateServer(ownSecurity(canonical, document), connectAddress(canonical, document))
    }

    /** custom.cpp:15-18. */
    private fun isSingBoxInfra(type: String): Boolean = type == "direct" || type == "block" || type == "dns"

    private fun singBoxEgress(config: JsonObject): JsonObject =
        resolveSingBoxEgress(config.array("outbounds"), config.obj("route").string("final"), 5)

    /** custom.cpp:44-69: the named tag, or the first outbound (sing-box's default egress), through selector/urltest groups. */
    private fun resolveSingBoxEgress(outbounds: JsonArray, tag: String, depth: Int): JsonObject {
        if (depth <= 0 || outbounds.isEmpty()) return JsonObject()
        var target = JsonObject()
        if (tag.isEmpty()) {
            target = firstObject(outbounds)
        } else {
            for (value in outbounds) {
                val candidate = value as? JsonObject ?: JsonObject()
                if (candidate.string("tag") == tag) {
                    target = candidate
                    break
                }
            }
        }
        if (target.isEmpty()) return JsonObject()
        val type = target.string("type")
        if (type == "selector" || type == "urltest") {
            val subs = target.array("outbounds")
            var next = target.string("default")
            if (next.isEmpty() && subs.isNotEmpty()) next = subs[0] as? String ?: ""
            return resolveSingBoxEgress(outbounds, next, depth - 1)
        }
        if (type.isEmpty() || isSingBoxInfra(type)) return JsonObject()
        return target
    }

    private fun firstObject(array: JsonArray): JsonObject =
        if (array.isEmpty()) JsonObject() else array[0] as? JsonObject ?: JsonObject()

    // ------------------------------------------------------------------------------------------------ documents

    /** The stored document: an empty object for a blank column (the type's defaults), null when unreadable. */
    private fun document(json: String): JsonObject? = if (json.isBlank()) JsonObject() else JsonInput.parseObjectOrNull(json)

    /** Custom.configObject: the config text as a JSON object (an empty object when it is not one). */
    private fun configObject(document: JsonObject): JsonObject = JsonInput.parseObject(document.string("config"))

    /**
     * `Outbound.exportJsonLink(stripMetadata = true)`, the duplicate key (GroupUpdater's Uniq):
     * the stored document without `tag`, so a renamed node still dedupes. The stored column is the
     * compact ExportToJson, so no re-export is needed; a row the old model could not parse exported
     * an empty object and every such row shared one key, which is kept here.
     *
     * A document with no keys (a freshly created or hand-cleared profile) hashes as its type key
     * instead: the old exporter wrote the type's constructor defaults around it (`packet_encoding`
     * for vmess, `tls:{}` for hysteria, …), but only the *equality* of keys matters here, and the
     * type key keeps every real row in the same classes (same type dedupes, different types do not).
     */
    @JvmStatic
    fun dedupKey(type: String, json: String): String {
        if (isInvalidDocument(type, json)) return "throne://add/" + Base64Strict.encode(JsonObject().toCompact(), urlSafe = true, padding = false)
        val document = document(json)!!
        val export = if (document.isEmpty()) typeOnlyExport(type) else document.copy().also { it.remove("tag") }.toCompact()
        return "throne://add/" + Base64Strict.encode(export, urlSafe = true, padding = false)
    }

    /** The type key of the ExportToJson a zero-field profile of [type] writes. */
    private fun typeOnlyExport(type: String): String {
        val document = JsonObject()
        document["type"] = canonicalType(type)
        return document.toCompact()
    }

    /**
     * `Outbound.exportJsonLink()`: the stored document (tag included) as a
     * `throne://add/` JSON link. A blank column answers the type's minimal
     * export; an unreadable document has no link.
     */
    @JvmStatic
    fun jsonLink(type: String, json: String): String {
        val compact = if (json.isBlank()) typeOnlyExport(type) else document(json)?.toCompact() ?: return ""
        return "throne://add/" + Base64Strict.encode(compact, urlSafe = true, padding = false)
    }

    // ------------------------------------------------------------------------------------------------ listables

    /**
     * `Tls`'s JsonStringList: a bare string is one item (even an empty one), an array contributes its
     * string items. Used for the certificate pins, where the old model tested the parsed list.
     */
    private fun hasTextItems(value: Any?): Boolean = when (value) {
        is String -> true
        is JsonArray -> value.any { it is String }
        else -> false
    }

    /**
     * `VpnFileImport.listable`: a bare string is split on newlines with blanks dropped, an array is
     * taken as it is. Used for the OpenVPN/OpenConnect certificate material.
     */
    private fun listableItems(value: Any?): Boolean = when (value) {
        is String -> value.split('\n').any { it.isNotEmpty() }
        is JsonArray -> value.isNotEmpty()
        else -> false
    }

    /**
     * The config text of a `custom` row whose subtype is `fullconfig` (a whole core config), null for
     * every other row: what the validator hands to `CheckConfig` as it is.
     */
    @JvmStatic
    fun fullConfigText(type: String, json: String): String? {
        if (canonicalType(type) != CUSTOM) return null
        val document = document(json) ?: return null
        if (document.string("subtype").trim() != "fullconfig") return null
        return document.string("config")
    }

    /** `Chain.list`: the hop ids, empty for every other type. */
    @JvmStatic
    fun chainHops(type: String, json: String): List<Long> {        if (canonicalType(type) != "chain") return emptyList()
        val document = document(json) ?: return emptyList()
        return document.array("list").map { value ->
            when (value) {
                is Long -> value
                is Double -> if (value == Math.rint(value) && value >= Long.MIN_VALUE.toDouble() && value < Long.MAX_VALUE.toDouble()) {
                    value.toLong()
                } else {
                    0L
                }

                else -> 0L
            }
        }
    }

    /** `Outbound.isEndpoint()`: the types whose tunnel can be up while a probe fails. */
    @JvmStatic
    fun isEndpoint(type: String, json: String): Boolean = when (canonicalType(type)) {
        "openvpn", "openconnect", "masque", "wireguard" -> true
        "custom" -> {
            val document = document(json)
            if (document == null || document.string("subtype").trim() != "outbound") {
                false
            } else {
                configObject(document).string("type") in setOf("wireguard", "tailscale", "masque")
            }
        }

        else -> false
    }
}
