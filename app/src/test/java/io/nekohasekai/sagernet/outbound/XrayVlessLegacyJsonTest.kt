package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf
import io.nekohasekai.sagernet.outbound.types.XrayVless
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Stored sing-box VLESS rows must load into the Xray implementation after sing-box's VLESS was removed. */
class XrayVlessLegacyJsonTest {

    @Test
    fun `a sing-box VLESS row with tls and ws converts to Xray vless`() {
        val transport = jsonObjectOf(
            "type" to "ws",
            "path" to "/chat",
            // The stored shape keeps headers (and the ws Host) in an object, not a flat list.
            "headers" to jsonObjectOf("Host" to "ws.example.com", "X-Test" to "value"),
        )
        val tls = jsonObjectOf(
            "enabled" to true,
            "server_name" to "tls.example.com",
            "alpn" to JsonArray.of("h2", "http/1.1"),
        )
        val row = JsonObject().apply {
            this["type"] = "vless"
            this["tag"] = "legacy-node"
            this["server"] = "vless.example.com"
            this["server_port"] = 443
            this["uuid"] = "b831381d-6324-4d53-ad4f-8cda48b30811"
            this["tls"] = tls
            this["transport"] = transport
        }

        val outbound = XrayVless()
        assertTrue(outbound.parseFromJson(row))

        assertEquals("legacy-node", outbound.name)
        assertEquals("vless.example.com", outbound.server)
        assertEquals(443, outbound.serverPort)
        assertEquals("b831381d-6324-4d53-ad4f-8cda48b30811", outbound.uuid)

        val built = outbound.buildXray(BuildContext.DEFAULT).json
        assertEquals("vless", built.string("protocol"))
        assertEquals("vless.example.com", built.obj("settings").string("address"))
        assertEquals("b831381d-6324-4d53-ad4f-8cda48b30811", built.obj("settings").string("id"))
        val stream = built.obj("streamSettings")
        assertEquals("ws", stream.string("network"))
        assertEquals("tls", stream.string("security"))
        val ws = stream.obj("wsSettings")
        assertEquals("/chat", ws.string("path"))
        assertEquals("ws.example.com", ws.string("host"))
        assertEquals("value", ws.obj("headers").string("X-Test"))
    }

    @Test
    fun `a sing-box VLESS row with an unmappable transport is rejected`() {
        val row = JsonObject().apply {
            this["type"] = "vless"
            this["server"] = "vless.example.com"
            this["server_port"] = 443
            this["uuid"] = "b831381d-6324-4d53-ad4f-8cda48b30811"
            this["transport"] = jsonObjectOf("type" to "http")
        }

        assertTrue(!XrayVless().parseFromJson(row))
    }
}
