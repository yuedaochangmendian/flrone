package io.nekohasekai.sagernet.outbound.import

import io.nekohasekai.sagernet.outbound.InvalidOutbound
import io.nekohasekai.sagernet.document.json.JsonArray
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.json.jsonObjectOf
import io.nekohasekai.sagernet.outbound.types.Trojan
import io.nekohasekai.sagernet.outbound.types.Vless
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Rows and documents of the removed Xray implementation convert to their sing-box counterparts, or say why not. */
class LegacyXrayTest {

    private val uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

    private fun vlessRow(stream: JsonObject, user: JsonObject = JsonObject(), mux: JsonObject = JsonObject()): JsonObject =
        JsonObject().apply {
            this["protocol"] = "vless"
            this["tag"] = "legacy-node"
            this["settings"] = jsonObjectOf(
                "vnext" to JsonArray.of(
                    JsonObject().apply {
                        this["address"] = "vless.example.com"
                        this["port"] = 443
                        this["users"] = JsonArray.of(
                            JsonObject().apply {
                                this["id"] = uuid
                                this["encryption"] = "none"
                                this["flow"] = ""
                                for (key in user.keys()) this[key] = user[key]
                            },
                        )
                    },
                ),
            )
            this["streamSettings"] = stream
            if (mux.isNotEmpty()) this["mux"] = mux
        }

    @Test
    fun `a stored xrayvless row becomes a vless outbound`() {
        val stream = jsonObjectOf(
            "network" to "ws",
            "security" to "tls",
            "wsSettings" to jsonObjectOf("path" to "/chat", "host" to "ws.example.com"),
            "tlsSettings" to jsonObjectOf(
                "serverName" to "tls.example.com",
                "fingerprint" to "chrome",
            ),
        )
        val row = vlessRow(stream, mux = jsonObjectOf("enabled" to true, "concurrency" to 8))

        val converted = LegacyXray.migrateStored("xrayvless", row)
        assertTrue(converted is Vless)
        converted as Vless
        assertEquals("legacy-node", converted.name)
        assertEquals("vless.example.com", converted.server)
        assertEquals(443, converted.serverPort)
        assertEquals(uuid, converted.uuid)
        assertEquals("ws", converted.transport.type)
        assertEquals("/chat", converted.transport.path)
        assertEquals("ws.example.com", converted.transport.host)
        assertTrue(converted.tls.enabled)
        assertEquals("tls.example.com", converted.tls.server_name)
        assertEquals("chrome", converted.tls.utls.fingerPrint)
        assertTrue(converted.multiplex.enabled)
        assertEquals(8, converted.multiplex.max_streams)
    }

    @Test
    fun `xhttp encryption and mkcp survive the conversion`() {
        val xhttp = vlessRow(
            jsonObjectOf(
                "network" to "xhttp",
                "security" to "tls",
                "xhttpSettings" to jsonObjectOf(
                    "path" to "/x",
                    "host" to "cdn.example.com",
                    "mode" to "packet-up",
                    "extra" to jsonObjectOf("xPaddingBytes" to "200-800", "xmux" to jsonObjectOf("maxConnections" to "4-8")),
                ),
            ),
            user = jsonObjectOf("encryption" to "mlkem768x25519plus.native.0rtt.AAAA"),
        )
        val converted = LegacyXray.migrateStored("xrayvless", xhttp) as Vless
        assertEquals("mlkem768x25519plus.native.0rtt.AAAA", converted.encryption)
        assertEquals("xhttp", converted.transport.type)
        assertEquals("/x", converted.transport.path)
        assertEquals("cdn.example.com", converted.transport.host)
        assertEquals("packet-up", converted.transport.mode)
        assertEquals("200-800", converted.transport.x_padding_bytes)
        assertEquals("4-8", converted.transport.xmux?.string("maxConnections"))

        val kcp = vlessRow(
            jsonObjectOf(
                "network" to "kcp",
                "kcpSettings" to jsonObjectOf(
                    "mtu" to 1400,
                    "tti" to 40,
                    "header" to jsonObjectOf("type" to "srtp"),
                    "seed" to "abc",
                ),
            ),
        )
        val kcpConverted = LegacyXray.migrateStored("xrayvless", kcp) as Vless
        assertEquals("mkcp", kcpConverted.transport.type)
        assertEquals(1400, kcpConverted.transport.mtu)
        assertEquals(40, kcpConverted.transport.tti)
        assertEquals("srtp", kcpConverted.transport.header_type)
        assertEquals("abc", kcpConverted.transport.seed)
    }

    @Test
    fun `a reality row keeps its key and short id`() {
        val row = vlessRow(
            jsonObjectOf(
                "network" to "raw",
                "security" to "reality",
                "realitySettings" to jsonObjectOf(
                    "serverName" to "www.example.com",
                    "fingerprint" to "chrome",
                    "publicKey" to "Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw",
                    "shortId" to "0123456789abcdef",
                ),
            ),
            user = jsonObjectOf("flow" to "xtls-rprx-vision"),
        )

        val converted = LegacyXray.migrateStored("xrayvless", row) as Vless
        assertTrue(converted.tls.enabled)
        assertTrue(converted.tls.reality.enabled)
        assertEquals("www.example.com", converted.tls.server_name)
        assertEquals("Z84J2IelR9ch3k8VtlVhhs5ycBUlXA7wHBWcBrjqnAw", converted.tls.reality.public_key)
        assertEquals("0123456789abcdef", converted.tls.reality.short_id)
        assertEquals("xtls-rprx-vision", converted.flow)
        assertTrue(converted.build(io.nekohasekai.sagernet.outbound.BuildContext.DEFAULT).ok)
    }

    @Test
    fun `xdrive cannot be represented and says so`() {
        val row = vlessRow(jsonObjectOf("network" to "xdrive", "security" to "tls"))

        val converted = LegacyXray.migrateStored("xrayvless", row)
        assertTrue(converted is InvalidOutbound)
        assertTrue((converted as InvalidOutbound).invalid)
        assertTrue(converted.displayType().contains("XDRIVE", ignoreCase = true))
    }

    @Test
    fun `a custom xray full config is kept but invalid`() {
        val row = jsonObjectOf(
            "type" to "custom",
            "subtype" to "xrayfullconfig",
            "config" to jsonObjectOf("outbounds" to JsonArray()).toCompact(),
        )

        val converted = LegacyXray.migrateStored("custom", row)
        assertTrue(converted is InvalidOutbound)
        assertTrue((converted as InvalidOutbound).invalid)
        assertTrue(converted.displayType().contains("full config", ignoreCase = true))
    }

    @Test
    fun `a custom xrayoutbound row converts when the protocol maps`() {
        val trojan = jsonObjectOf(
            "protocol" to "trojan",
            "tag" to "t",
            "settings" to jsonObjectOf(
                "servers" to JsonArray.of(
                    jsonObjectOf(
                        "address" to "trojan.example.com",
                        "port" to 443,
                        "password" to "secret",
                    ),
                ),
            ),
            "streamSettings" to jsonObjectOf("network" to "ws", "security" to "tls", "tlsSettings" to jsonObjectOf("serverName" to "sni.example.com")),
        )
        val row = jsonObjectOf("type" to "custom", "subtype" to "xrayoutbound", "config" to trojan.toCompact())

        val converted = LegacyXray.migrateStored("custom", row)
        assertTrue(converted is Trojan)
        converted as Trojan
        assertEquals("trojan.example.com", converted.server)
        assertEquals(443, converted.serverPort)
        assertEquals("secret", converted.password)
        assertEquals("ws", converted.transport.type)

        // A protocol with no sing-box outbound is refused instead of stored as a dead custom row.
        val hysteria = jsonObjectOf("protocol" to "hysteria", "settings" to jsonObjectOf("address" to "h.example.com", "port" to 443))
        val refused = LegacyXray.migrateStored("custom", jsonObjectOf("type" to "custom", "subtype" to "xrayoutbound", "config" to hysteria.toCompact()))
        assertTrue(refused is InvalidOutbound)
        assertTrue((refused as InvalidOutbound).invalid)
    }
}
