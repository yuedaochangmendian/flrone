package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.ProfileImport
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf
import io.nekohasekai.sagernet.outbound.types.Vless
import io.nekohasekai.sagernet.outbound.types.XrayVless
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ordinary VLESS runs on sing-box's own `vless` outbound; only what sing-box cannot do
 * (XHTTP, XDRIVE, VLESS Encryption) still resolves to the Xray type.
 */
class VlessOutboundTest {

    private val uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

    private fun tlsWsLink(query: String = "encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws"): String =
        "vless://$uuid@vless.example.com:443?$query#node"

    @Test
    fun `build emits the sing-box vless outbound`() {
        val vless = Vless()
        vless.server = "vless.example.com"
        vless.serverPort = 443
        vless.uuid = uuid
        vless.flow = "xtls-rprx-vision"
        vless.tls.enabled = true
        vless.tls.server_name = "sni.example.com"
        vless.transport.type = "tcp"

        val built = vless.build(BuildContext.DEFAULT).json

        assertEquals("vless", built.string("type"))
        assertEquals("vless.example.com", built.string("server"))
        assertEquals(443, built.int("server_port"))
        assertEquals(uuid, built.string("uuid"))
        assertEquals("xtls-rprx-vision", built.string("flow"))
        assertEquals("xudp", built.string("packet_encoding"))
        assertTrue(built.obj("tls").bool("enabled"))
        assertEquals("sni.example.com", built.obj("tls").string("server_name"))
        // A raw TCP transport has no transport object, and no encryption key exists in sing-box's VLESS.
        assertFalse(built.contains("transport"))
        assertFalse(built.contains("encryption"))
    }

    @Test
    fun `build keeps a ws transport and string fields`() {
        val vless = Vless()
        vless.server = "vless.example.com"
        vless.serverPort = 8443
        vless.uuid = uuid
        vless.tls.enabled = true
        vless.transport.type = "ws"
        vless.transport.path = "/ws"

        val built = vless.build(BuildContext.DEFAULT).json

        assertEquals("vless", built.string("type"))
        assertEquals("ws", built.obj("transport").string("type"))
        assertEquals("/ws", built.obj("transport").string("path"))
        assertEquals("xudp", built.string("packet_encoding"))
    }

    @Test
    fun `link export and parse round-trip a standard vless node`() {
        val vless = Vless()
        vless.server = "vless.example.com"
        vless.serverPort = 443
        vless.uuid = uuid
        vless.tls.enabled = true
        vless.tls.server_name = "sni.example.com"
        vless.transport.type = "ws"
        vless.transport.path = "/ws"

        val link = vless.exportToLink()
        assertTrue(link.startsWith("vless://$uuid@vless.example.com:443?"))
        assertTrue(link.contains("encryption=none"))
        assertTrue(link.contains("security=tls"))
        assertTrue(link.contains("type=ws"))

        val parsed = Vless()
        assertTrue(parsed.parseFromLink(link))
        assertEquals("vless.example.com", parsed.server)
        assertEquals(443, parsed.serverPort)
        assertEquals(uuid, parsed.uuid)
        assertTrue(parsed.tls.enabled)
        assertEquals("sni.example.com", parsed.tls.server_name)
        assertEquals("ws", parsed.transport.type)
        assertEquals("/ws", parsed.transport.path)
        assertEquals("xudp", parsed.packet_encoding)
    }

    @Test
    fun `link export and parse round-trip a vision flow`() {
        val vless = Vless()
        vless.server = "vless.example.com"
        vless.serverPort = 443
        vless.uuid = uuid
        vless.flow = "xtls-rprx-vision"
        vless.tls.enabled = true

        val link = vless.exportToLink()
        assertTrue(link.contains("flow=xtls-rprx-vision"))

        val parsed = Vless()
        assertTrue(parsed.parseFromLink(link))
        assertEquals("xtls-rprx-vision", parsed.flow)
    }

    @Test
    fun `json export and parse round-trip keeps the model`() {
        val vless = Vless()
        vless.name = "node"
        vless.server = "vless.example.com"
        vless.serverPort = 443
        vless.uuid = uuid
        vless.flow = "xtls-rprx-vision"
        vless.tls.enabled = true
        vless.tls.server_name = "sni.example.com"
        vless.transport.type = "grpc"
        vless.transport.service_name = "svc"

        val exported = vless.exportToJson()
        assertEquals("vless", exported.string("type"))

        val parsed = Vless()
        assertTrue(parsed.parseFromJson(exported))
        assertEquals(uuid, parsed.uuid)
        assertEquals("xtls-rprx-vision", parsed.flow)
        assertTrue(parsed.tls.enabled)
        assertEquals("grpc", parsed.transport.type)
        assertEquals("svc", parsed.transport.service_name)
    }

    @Test
    fun `an ordinary link is routed to the sing-box type`() {
        val routed = OutboundFactory.parseLink(tlsWsLink())
        assertTrue(routed is Vless)
        // REALITY is sing-box's own too: no preference routes it to Xray any more.
        val reality = tlsWsLink("encryption=none&security=reality&pbk=key&sid=ab&fp=chrome&sni=sni.example.com&type=tcp&flow=xtls-rprx-vision")
        assertFalse(OutboundFactory.useXrayVless(reality))
        assertTrue(OutboundFactory.parseLink(reality) is Vless)
        // h2/quic map onto sing-box transports.
        assertFalse(OutboundFactory.useXrayVless(tlsWsLink("encryption=none&security=tls&type=h2&path=%2F")))
        assertFalse(OutboundFactory.useXrayVless(tlsWsLink("encryption=none&security=tls&type=quic")))
    }

    @Test
    fun `xhttp and xdrive links stay on Xray`() {
        val xhttp = tlsWsLink("encryption=none&security=tls&type=xhttp&path=%2Fx")
        val xdrive = tlsWsLink("encryption=none&security=tls&type=xdrive")
        assertTrue(OutboundFactory.useXrayVless(xhttp))
        assertTrue(OutboundFactory.useXrayVless(xdrive))
        assertTrue(OutboundFactory.parseLink(xhttp) is XrayVless)
        // XDRIVE needs the storage settings a share link cannot carry, so Xray's stream refuses the
        // link outright (its parse reports the error through the importer's ParseDiag scope).
    }

    @Test
    fun `VLESS Encryption links stay on Xray and are refused by the sing-box model`() {
        val link = tlsWsLink("encryption=mlkem768x25519plus.native.0rtt.AAAA&security=tls&sni=sni.example.com")
        assertTrue(OutboundFactory.useXrayVless(link))
        assertTrue(OutboundFactory.parseLink(link) is XrayVless)
        assertFalse(Vless().parseFromLink(link))
    }

    @Test
    fun `a transport sing-box cannot carry stays on Xray`() {
        // The link is routed to Xray, whose stream then refuses kcp; the point is that it never
        // silently becomes plain TCP on the sing-box side.
        assertTrue(OutboundFactory.useXrayVless(tlsWsLink("encryption=none&type=kcp")))
        // The vision-udp443 flow is Xray's.
        assertTrue(OutboundFactory.useXrayVless(tlsWsLink("encryption=none&security=tls&type=tcp&flow=xtls-rprx-vision-udp443")))
    }

    @Test
    fun `the sing-box json row refuses a legacy encryption`() {
        val row = jsonObjectOf(
            "type" to "vless",
            "server" to "vless.example.com",
            "server_port" to 443,
            "uuid" to uuid,
            "encryption" to "mlkem768x25519plus.native.0rtt.AAAA",
        )
        assertFalse(Vless().parseFromJson(row))
        // encryption=none is what share links write and is accepted.
        assertTrue(Vless().parseFromJson(row.copy().also { it["encryption"] = "none" }))
    }

    @Test
    fun `a standard Clash entry imports as the sing-box type`() {
        val yaml = """
            proxies:
              - name: clash-node
                type: vless
                server: vless.example.com
                port: 443
                uuid: $uuid
                network: ws
                tls: true
                servername: sni.example.com
                ws-opts:
                  path: /ws
        """.trimIndent()

        val result = ProfileImport.parse(yaml, ctx = BuildContext.DEFAULT)

        assertEquals(1, result.outbounds.size)
        assertTrue(result.outbounds.single() is Vless)
        assertEquals("clash-node", result.outbounds.single().name)
    }

    @Test
    fun `a Clash xhttp entry imports as the Xray type`() {
        val yaml = """
            proxies:
              - name: clash-xhttp
                type: vless
                server: vless.example.com
                port: 443
                uuid: $uuid
                network: xhttp
                tls: true
                servername: sni.example.com
        """.trimIndent()

        val result = ProfileImport.parse(yaml, ctx = BuildContext.DEFAULT)

        assertEquals(1, result.outbounds.size)
        assertTrue(result.outbounds.single() is XrayVless)
    }

    @Test
    fun `a Clash entry with VLESS Encryption imports as the Xray type`() {
        val yaml = """
            proxies:
              - name: clash-encrypted
                type: vless
                server: vless.example.com
                port: 443
                uuid: $uuid
                encryption: mlkem768x25519plus.native.0rtt.AAAA
                network: tcp
                tls: true
                servername: sni.example.com
        """.trimIndent()

        val result = ProfileImport.parse(yaml, ctx = BuildContext.DEFAULT)

        assertEquals(1, result.outbounds.size)
        assertTrue(result.outbounds.single() is XrayVless)
    }
}
