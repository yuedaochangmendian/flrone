package io.flrone.bridge

import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.document.json.JsonObject
import io.nekohasekai.sagernet.document.json.jsonObjectOf
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The node page's mux/fragment/TLS-tricks overrides, read from and written into the stored
 * `outbound_json` (ADR 0008 S8, final batch).
 *
 * The mapping under test is the model's own, block for block: `Multiplex::getMuxState` /
 * `saveMuxState` / `ExportToJson` for the Keep Default / On / Off / Custom menu, and the TLS.h
 * tri-states with `Tls::ExportToJson`'s omissions (an unspecified flag, a blank fallback delay and
 * a false record fragment are not written). Every other key of the row has to survive an edit
 * untouched, and the result has to be the canonical compact document the writer produces.
 */
class FlroneNodeTuningTest {

    private fun doc(vararg pairs: Pair<String, Any?>): String = jsonObjectOf(*pairs).toCompact()

    private fun parse(json: String): JsonObject = JsonInput.parseObjectOrNull(json)!!

    private fun info(type: String, json: String): Map<String, Any?> =
        FlroneNodeTuning.infoPayload(7L, type, json)

    private fun edit(type: String, json: String, values: Map<String, Any?>): String =
        FlroneNodeTuning.savePayload(type, json, values)

    /** A VMess row as the node editor stores it: no tuning blocks yet, TLS off. */
    private fun vmess(vararg extra: Pair<String, Any?>): String = doc(
        "type" to "vmess",
        "server" to "example.com",
        "server_port" to 443,
        "uuid" to "11111111-2222-3333-4444-555555555555",
        "security" to "aes-128-gcm",
        "alter_id" to 4,
        "packet_encoding" to "xudp",
        "transport" to jsonObjectOf("type" to "ws", "path" to "/ray"),
        *extra,
    )

    private fun tlsOn(vararg extra: Pair<String, Any?>): JsonObject =
        jsonObjectOf("enabled" to true, *extra)

    // ------------------------------------------------------------------------------------- info

    @Test
    fun `info keeps the wire shape and the keep-default states`() {
        val payload = info("vmess", vmess())

        assertEquals(7L, payload["id"])
        assertEquals(true, payload["hasMux"])
        assertEquals(true, payload["hasTls"])
        assertEquals(0, payload["muxState"])
        assertEquals("", payload["muxProtocol"])
        assertEquals(0, payload["muxMaxStreams"])
        assertEquals(0, payload["muxMaxConnections"])
        assertEquals(0, payload["muxMinStreams"])
        assertEquals(false, payload["muxPadding"])
        assertEquals(false, payload["muxBrutal"])
        assertEquals(0, payload["muxBrutalUp"])
        assertEquals(0, payload["muxBrutalDown"])
        assertEquals(0, payload["fragmentState"])
        assertEquals("", payload["fragmentFallbackDelay"])
        assertEquals(false, payload["recordFragment"])
        assertEquals(0, payload["tlsTricksState"])

        // Same number types on the wire as before: ints stay Int, the id stays Long.
        assertTrue(payload["muxState"] is Int)
        assertTrue(payload["muxBrutalUp"] is Int)
        assertTrue(payload["fragmentState"] is Int)
        assertTrue(payload["hasMux"] is Boolean)
        assertTrue(payload["muxProtocol"] is String)
    }

    @Test
    fun `mux state maps keep-default, on, off and custom`() {
        assertEquals(0, info("vmess", vmess())["muxState"])
        assertEquals(0, info("vmess", vmess("multiplex" to jsonObjectOf()))["muxState"])
        assertEquals(0, info("vmess", vmess("multiplex" to jsonObjectOf("protocol" to "smux")))["muxState"])
        assertEquals(2, info("vmess", vmess("multiplex" to jsonObjectOf("enabled" to false)))["muxState"])
        assertEquals(1, info("vmess", vmess("multiplex" to jsonObjectOf("enabled" to true)))["muxState"])
        assertEquals(
            3,
            info("vmess", vmess("multiplex" to jsonObjectOf("enabled" to true, "max_streams" to 8)))["muxState"],
        )
        assertEquals(
            3,
            info("vmess", vmess("multiplex" to jsonObjectOf("enabled" to true, "padding" to true)))["muxState"],
        )
        assertEquals(
            3,
            info(
                "vmess",
                vmess("multiplex" to jsonObjectOf("enabled" to true, "brutal" to jsonObjectOf("enabled" to true))),
            )["muxState"],
        )
    }

    @Test
    fun `custom mux fields read back from the block`() {
        val json = vmess(
            "multiplex" to jsonObjectOf(
                "enabled" to true,
                "protocol" to "yamux",
                "max_streams" to 0,
                "max_connections" to 8,
                "min_streams" to 2,
                "padding" to true,
                "brutal" to jsonObjectOf("enabled" to true, "up_mbps" to 20, "down_mbps" to 50),
            ),
        )
        val payload = info("vmess", json)
        assertEquals(3, payload["muxState"])
        assertEquals("yamux", payload["muxProtocol"])
        assertEquals(0, payload["muxMaxStreams"])
        assertEquals(8, payload["muxMaxConnections"])
        assertEquals(2, payload["muxMinStreams"])
        assertEquals(true, payload["muxPadding"])
        assertEquals(true, payload["muxBrutal"])
        assertEquals(20, payload["muxBrutalUp"])
        assertEquals(50, payload["muxBrutalDown"])
    }

    @Test
    fun `fragment and tricks tri-states read from the tls block`() {
        fun tls(vararg extra: Pair<String, Any?>): String = vmess("tls" to tlsOn(*extra))

        assertEquals(0, info("vmess", tls())["fragmentState"])
        assertEquals(1, info("vmess", tls("fragment" to true))["fragmentState"])
        assertEquals(2, info("vmess", tls("fragment" to false))["fragmentState"])
        assertEquals("200ms", info("vmess", tls("fragment_fallback_delay" to "200ms"))["fragmentFallbackDelay"])
        assertEquals(true, info("vmess", tls("record_fragment" to true))["recordFragment"])

        assertEquals(0, info("vmess", tls())["tlsTricksState"])
        assertEquals(1, info("vmess", tls("tls_tricks" to jsonObjectOf("mixedcase_sni" to true)))["tlsTricksState"])
        assertEquals(2, info("vmess", tls("tls_tricks" to jsonObjectOf("mixedcase_sni" to false)))["tlsTricksState"])
        // The block is the {mixedcase_sni} object; a bare boolean is off, as the model read it.
        assertEquals(2, info("vmess", tls("tls_tricks" to true))["tlsTricksState"])
    }

    // ------------------------------------------------------------------------------------- capabilities

    @Test
    fun `the capability table follows the model's getMux and getTls`() {
        val pairs = listOf(
            "shadowsocks" to (true to false),
            "vmess" to (true to true),
            "vless" to (true to true),
            "trojan" to (true to true),
            "http" to (false to true),
            "hysteria" to (false to true),
            "hysteria2" to (false to true),
            "tuic" to (false to true),
            "anytls" to (false to true),
            "openvpn" to (false to false),
            "openconnect" to (false to false),
            "ssh" to (false to false),
            "direct" to (false to false),
            "custom" to (false to false),
        )
        for ((type, expected) in pairs) {
            val payload = info(type, doc("type" to type, "server" to "example.com", "server_port" to 443))
            assertEquals("hasMux for $type", expected.first, payload["hasMux"])
            assertEquals("hasTls for $type", expected.second, payload["hasTls"])
        }
    }

    @Test
    fun `an unknown type or an unreadable document reports no tunables`() {
        val unknown = doc("type" to "xrayvless", "server" to "example.com")
        for (payload in listOf(info("xrayvless", unknown), info("vmess", "{not json"))) {
            assertEquals(false, payload["hasMux"])
            assertEquals(false, payload["hasTls"])
            assertEquals(0, payload["muxState"])
            assertEquals(0, payload["fragmentState"])
            assertEquals(0, payload["tlsTricksState"])
        }
    }

    // ------------------------------------------------------------------------------------- save

    @Test
    fun `custom mux settings are exported with the model's clamps and omissions`() {
        val saved = edit(
            "vmess",
            vmess(),
            mapOf(
                "muxState" to 3,
                "muxProtocol" to " yamux ",
                "muxMaxStreams" to -4,
                "muxMaxConnections" to 0,
                "muxMinStreams" to 2,
                "muxPadding" to true,
                "muxBrutal" to true,
                "muxBrutalUp" to 0,
                "muxBrutalDown" to 30,
            ),
        )
        assertEquals(
            jsonObjectOf(
                "enabled" to true,
                "protocol" to "yamux",
                "min_streams" to 2,
                "padding" to true,
                // TcpBrutal::ExportToJson: a missing rate is written as 1, sing-box wants both.
                "brutal" to jsonObjectOf("enabled" to true, "up_mbps" to 1, "down_mbps" to 30),
            ),
            parse(saved).obj("multiplex"),
        )
        val readBack = info("vmess", saved)
        assertEquals(3, readBack["muxState"])
        assertEquals("yamux", readBack["muxProtocol"])
        assertEquals(0, readBack["muxMaxStreams"])
        assertEquals(2, readBack["muxMinStreams"])
        assertEquals(true, readBack["muxPadding"])
        assertEquals(1, readBack["muxBrutalUp"])
        assertEquals(30, readBack["muxBrutalDown"])
    }

    @Test
    fun `custom keeps the settings the editor did not send`() {
        val json = vmess(
            "multiplex" to jsonObjectOf("enabled" to true, "protocol" to "smux", "max_streams" to 4),
        )
        val saved = edit("vmess", json, mapOf("muxState" to 3, "muxPadding" to true))
        assertEquals(
            jsonObjectOf("enabled" to true, "protocol" to "smux", "max_streams" to 4, "padding" to true),
            parse(saved).obj("multiplex"),
        )
    }

    @Test
    fun `switching away from custom clears or drops the settings`() {
        val custom = vmess(
            "multiplex" to jsonObjectOf(
                "enabled" to true,
                "protocol" to "smux",
                "max_connections" to 8,
                "padding" to true,
                "brutal" to jsonObjectOf("enabled" to true, "up_mbps" to 5, "down_mbps" to 5),
            ),
            "tls" to tlsOn("fragment" to true),
        )
        assertEquals(jsonObjectOf("enabled" to true), parse(edit("vmess", custom, mapOf("muxState" to 1))).obj("multiplex"))
        assertEquals(jsonObjectOf("enabled" to false), parse(edit("vmess", custom, mapOf("muxState" to 2))).obj("multiplex"))
        assertEquals(false, parse(edit("vmess", custom, mapOf("muxState" to 0))).contains("multiplex"))
        // A state the menu cannot produce is saveMuxState's disabled multiplex, like any other.
        assertEquals(jsonObjectOf("enabled" to false), parse(edit("vmess", custom, mapOf("muxState" to 9))).obj("multiplex"))
    }

    @Test
    fun `fragment and tricks write the tri-states and omit the defaults again`() {
        val json = vmess("tls" to tlsOn("server_name" to "cdn.example.com"))
        val on = parse(
            edit(
                "vmess",
                json,
                mapOf("fragmentState" to 1, "fragmentFallbackDelay" to " 200ms ", "recordFragment" to true, "tlsTricksState" to 1),
            ),
        ).obj("tls")
        assertEquals(true, on.bool("fragment"))
        assertEquals("200ms", on.string("fragment_fallback_delay"))
        assertEquals(true, on.bool("record_fragment"))
        assertEquals(jsonObjectOf("mixedcase_sni" to true), on.obj("tls_tricks"))
        assertEquals("cdn.example.com", on.string("server_name"))

        val off = parse(
            edit(
                "vmess",
                json,
                mapOf("fragmentState" to 0, "fragmentFallbackDelay" to "   ", "recordFragment" to false, "tlsTricksState" to 0),
            ),
        ).obj("tls")
        assertFalse(off.contains("fragment"))
        assertFalse(off.contains("fragment_fallback_delay"))
        assertFalse(off.contains("record_fragment"))
        assertFalse(off.contains("tls_tricks"))
        assertEquals("cdn.example.com", off.string("server_name"))

        val explicitOff = parse(edit("vmess", json, mapOf("fragmentState" to 2, "tlsTricksState" to 2))).obj("tls")
        assertEquals(false, explicitOff.bool("fragment"))
        assertEquals(jsonObjectOf("mixedcase_sni" to false), explicitOff.obj("tls_tricks"))
    }

    @Test
    fun `no tls block means no tuning is invented`() {
        val plain = vmess()
        assertEquals(plain, edit("vmess", plain, mapOf("fragmentState" to 1, "recordFragment" to true, "tlsTricksState" to 1)))

        // A row whose TLS is off stores no tuning: the model's export dropped the block the same way.
        val tlsOff = vmess("tls" to jsonObjectOf("enabled" to false, "server_name" to "cdn.example.com"))
        assertEquals(tlsOff, edit("vmess", tlsOff, mapOf("fragmentState" to 1, "tlsTricksState" to 2)))
    }

    @Test
    fun `a non-capable type keeps its document`() {
        val ssl = doc("type" to "shadowsocks", "server" to "example.com", "server_port" to 8388, "method" to "aes-256-gcm")
        val savedSsl = edit("shadowsocks", ssl, mapOf("fragmentState" to 1, "tlsTricksState" to 1, "muxState" to 2))
        assertFalse(parse(savedSsl).contains("tls"))
        assertEquals(jsonObjectOf("enabled" to false), parse(savedSsl).obj("multiplex"))

        val http = doc(
            "type" to "http",
            "server" to "example.com",
            "server_port" to 8080,
            "tls" to tlsOn(),
        )
        val savedHttp = edit("http", http, mapOf("muxState" to 3, "muxProtocol" to "yamux", "fragmentState" to 1))
        assertFalse(parse(savedHttp).contains("multiplex"))
        assertEquals(true, parse(savedHttp).obj("tls").bool("fragment"))
    }

    @Test
    fun `a row the tuning cannot own is left byte-identical`() {
        val unknown = doc("type" to "xrayvless", "server" to "example.com")
        assertEquals(unknown, edit("xrayvless", unknown, mapOf("muxState" to 2)))

        val unreadable = "{not json"
        assertEquals(unreadable, edit("vmess", unreadable, mapOf("muxState" to 2)))

        // A blank column is a fresh document: the edit only adds its own block (the row's type column
        // already says vmess, which is what the reader parses with).
        assertEquals("{\"multiplex\":{\"enabled\":false}}", edit("vmess", "", mapOf("muxState" to 2)))
    }

    // ------------------------------------------------------------------------------------- preservation

    @Test
    fun `non-tuning fields are untouched and the document stays canonical`() {
        val json = vmess(
            "tls" to tlsOn(
                "server_name" to "cdn.example.com",
                "utls" to jsonObjectOf("enabled" to true, "fingerprint" to "chrome"),
            ),
        )
        val saved = edit("vmess", json, mapOf("muxState" to 3, "muxProtocol" to "smux", "fragmentState" to 1))

        val before = parse(json)
        val after = parse(saved)
        for (key in before.keys()) {
            if (key == "multiplex" || key == "tls") continue
            assertEquals("field `$key` must survive an edit", before[key], after[key])
        }
        assertEquals((before.keys() + "multiplex").sorted(), after.keys().sorted())

        // Only the fragment was added to the TLS block; the rest of it is the stored one.
        val tlsBefore = before.obj("tls")
        val tlsAfter = after.obj("tls")
        assertEquals(true, tlsAfter.bool("fragment"))
        for (key in tlsBefore.keys()) {
            if (key == "fragment") continue
            assertEquals("tls field `$key` must survive an edit", tlsBefore[key], tlsAfter[key])
        }

        // The stored text is the canonical compact document, never a hand-spaced edit.
        assertEquals(saved, after.toCompact())
    }

    @Test
    fun `a tuning edit round-trips to the same document and the same state`() {
        val values: Map<String, Any?> = mapOf(
            "muxState" to 3,
            "muxProtocol" to "yamux",
            "muxMaxStreams" to 16,
            "muxPadding" to true,
            "muxBrutal" to true,
            "muxBrutalUp" to 10,
            "muxBrutalDown" to 40,
            "fragmentState" to 1,
            "fragmentFallbackDelay" to "150ms",
            "recordFragment" to true,
            "tlsTricksState" to 1,
        )
        val json = vmess("tls" to tlsOn("server_name" to "cdn.example.com"))
        val first = edit("vmess", json, values)

        // Saving the same values again changes nothing: the stored block is already the export.
        assertEquals(first, edit("vmess", first, values))
        assertEquals(first, parse(first).toCompact())

        val payload = info("vmess", first)
        assertEquals(3, payload["muxState"])
        assertEquals("yamux", payload["muxProtocol"])
        assertEquals(16, payload["muxMaxStreams"])
        assertEquals(true, payload["muxPadding"])
        assertEquals(true, payload["muxBrutal"])
        assertEquals(10, payload["muxBrutalUp"])
        assertEquals(40, payload["muxBrutalDown"])
        assertEquals(1, payload["fragmentState"])
        assertEquals("150ms", payload["fragmentFallbackDelay"])
        assertEquals(true, payload["recordFragment"])
        assertEquals(1, payload["tlsTricksState"])

        // A payload with no tuning key at all is a no-op, the way the old save skipped absent keys.
        assertEquals(first, edit("vmess", first, emptyMap()))
    }
}