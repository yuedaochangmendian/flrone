package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.common.SING_BOX_TRANSPORTS
import io.nekohasekai.sagernet.outbound.import.ProfileImport
import io.nekohasekai.sagernet.outbound.json.jsonObjectOf
import io.nekohasekai.sagernet.outbound.types.Vless
import io.nekohasekai.sagernet.outbound.types.vlessFlows
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Ordinary VLESS, XHTTP, mKCP and VLESS Encryption all run on the extended kernel's own `vless` outbound. What the
 * kernel cannot express (XDRIVE, an unknown transport, the vision-udp443 flow) is refused by the model's checks.
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
        // A raw TCP transport has no transport object; encryption defaults to the explicit none.
        assertFalse(built.contains("transport"))
        assertEquals("none", built.string("encryption"))
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
        // REALITY is sing-box's own too.
        val reality = tlsWsLink("encryption=none&security=reality&pbk=key&sid=ab&fp=chrome&sni=sni.example.com&type=tcp&flow=xtls-rprx-vision")
        assertTrue(OutboundFactory.parseLink(reality) is Vless)
        // h2/quic map onto sing-box transports.
        val h2 = OutboundFactory.parseLink(tlsWsLink("encryption=none&security=tls&type=h2&path=%2F"))
        assertTrue(h2 is Vless)
        assertEquals("http", (h2 as Vless).transport.type)
        val quic = OutboundFactory.parseLink(tlsWsLink("encryption=none&security=tls&type=quic"))
        assertTrue(quic is Vless)
        assertEquals("quic", (quic as Vless).transport.type)
    }

    @Test
    fun `xhttp runs on sing-box and xdrive is refused by the model`() {
        val xhttp = OutboundFactory.parseLink(tlsWsLink("encryption=none&security=tls&type=xhttp&path=%2Fx"))
        assertTrue(xhttp is Vless)
        assertEquals("xhttp", (xhttp as Vless).transport.type)
        // XDRIVE has no sing-box counterpart: the link parses into the same model, whose checks refuse it.
        val xdrive = OutboundFactory.parseLink(tlsWsLink("encryption=none&security=tls&type=xdrive"))
        assertTrue(xdrive is Vless)
        // Kept as written, and outside the set the kernel accepts, so the profile's checks refuse it.
        assertEquals("xdrive", (xdrive as Vless).transport.type)
        assertFalse("xdrive" in SING_BOX_TRANSPORTS)
    }

    @Test
    fun `VLESS Encryption runs on sing-box`() {
        val link = tlsWsLink("encryption=mlkem768x25519plus.native.0rtt.AAAA&security=tls&sni=sni.example.com")
        val routed = OutboundFactory.parseLink(link)
        assertTrue(routed is Vless)
        assertEquals("mlkem768x25519plus.native.0rtt.AAAA", (routed as Vless).encryption)
    }

    @Test
    fun `an XHTTP link carries extra padding and xmux into the sing-box transport`() {
        val extra = """{"xPaddingBytes":"200-800","noGRPCHeader":true,"xmux":{"maxConnections":"4-8"}}"""
        val encoded = java.net.URLEncoder.encode(extra, "UTF-8")
        val link = tlsWsLink("encryption=none&security=tls&type=xhttp&mode=packet-up&host=cdn.example.com&path=%2Fx&extra=$encoded")

        val parsed = OutboundFactory.parseLink(link)
        assertTrue(parsed is Vless)
        parsed as Vless

        assertEquals("xhttp", parsed.transport.type)
        assertEquals("packet-up", parsed.transport.mode)
        assertEquals("cdn.example.com", parsed.transport.host)
        assertEquals("/x", parsed.transport.path)
        assertEquals("200-800", parsed.transport.x_padding_bytes)
        assertTrue(parsed.transport.no_grpc_header)
        assertEquals("4-8", parsed.transport.xmux?.string("maxConnections"))

        val built = parsed.build(BuildContext.DEFAULT).json.obj("transport")
        assertEquals("xhttp", built.string("type"))
        assertEquals("packet-up", built.string("mode"))
        // The core rejects a zero range, so the parsed range is carried verbatim.
        assertEquals("200-800", built.string("x_padding_bytes"))
        assertTrue(built.bool("no_grpc_header"))
        assertEquals("4-8", built.obj("xmux").string("maxConnections"))

        // The model survives a link round-trip, extra included.
        val again = Vless()
        assertTrue(again.parseFromLink(parsed.exportToLink()))
        assertEquals("xhttp", again.transport.type)
        assertEquals("200-800", again.transport.x_padding_bytes)
        assertEquals("4-8", again.transport.xmux?.string("maxConnections"))
        // JSON export -> import keeps the same keys the form edits.
        val json = again.exportToJson()
        val fromJson = Vless()
        assertTrue(fromJson.parseFromJson(json))
        assertEquals("200-800", fromJson.transport.x_padding_bytes)
        assertTrue(fromJson.transport.no_grpc_header)
    }

    @Test
    fun `an XHTTP transport always builds a non-zero padding range`() {
        val vless = Vless()
        vless.server = "vless.example.com"
        vless.serverPort = 443
        vless.uuid = uuid
        vless.transport.type = "xhttp"

        val built = vless.build(BuildContext.DEFAULT).json.obj("transport")
        assertEquals("xhttp", built.string("type"))
        assertEquals("100-1000", built.string("x_padding_bytes"))
    }

    @Test
    fun `a kcp link builds and parses the mkcp transport`() {
        val link = tlsWsLink(
            "encryption=none&type=kcp&headerType=srtp&seed=abc&mtu=1400&tti=40" +
                "&uplinkCapacity=5&downlinkCapacity=50&congestion=1"
        )

        val parsed = OutboundFactory.parseLink(link)
        assertTrue(parsed is Vless)
        parsed as Vless
        assertEquals("mkcp", parsed.transport.type)
        assertEquals(1400, parsed.transport.mtu)
        assertEquals(40, parsed.transport.tti)
        assertEquals(5, parsed.transport.uplink_capacity)
        assertEquals(50, parsed.transport.downlink_capacity)
        assertTrue(parsed.transport.congestion)
        assertEquals("srtp", parsed.transport.header_type)
        assertEquals("abc", parsed.transport.seed)

        val built = parsed.build(BuildContext.DEFAULT).json.obj("transport")
        assertEquals("mkcp", built.string("type"))
        assertEquals(1400, built.int("mtu"))
        assertEquals(40, built.int("tti"))
        assertEquals(5, built.int("uplink_capacity"))
        assertEquals(50, built.int("downlink_capacity"))
        assertTrue(built.bool("congestion"))
        assertEquals("srtp", built.string("header_type"))
        assertEquals("abc", built.string("seed"))

        val again = Vless()
        assertTrue(again.parseFromLink(parsed.exportToLink()))
        assertEquals("mkcp", again.transport.type)
        assertEquals(1400, again.transport.mtu)
        assertEquals("srtp", again.transport.header_type)
        assertEquals("abc", again.transport.seed)
    }

    @Test
    fun `a kcp transport omits zero options`() {
        val vless = Vless()
        vless.server = "vless.example.com"
        vless.serverPort = 443
        vless.uuid = uuid
        vless.transport.type = "mkcp"

        val built = vless.build(BuildContext.DEFAULT).json.obj("transport")
        assertEquals("mkcp", built.string("type"))
        // Defaults come from the core: no zero-valued key is written.
        assertFalse(built.contains("mtu"))
        assertFalse(built.contains("tti"))
        assertFalse(built.contains("uplink_capacity"))
    }

    @Test
    fun `a transport sing-box cannot carry is refused by the model`() {
        // The unknown network is kept as written and refused, never silently turned into plain TCP.
        val unknown = OutboundFactory.parseLink(tlsWsLink("encryption=none&type=meek"))
        assertTrue(unknown is Vless)
        assertEquals("meek", (unknown as Vless).transport.type)
        assertFalse("meek" in SING_BOX_TRANSPORTS)
        // The vision-udp443 flow is Xray's spelling, which the kernel's flow check refuses.
        val udp443 = OutboundFactory.parseLink(tlsWsLink("encryption=none&security=tls&type=tcp&flow=xtls-rprx-vision-udp443"))
        assertTrue(udp443 is Vless)
        assertEquals("xtls-rprx-vision-udp443", (udp443 as Vless).flow)
        assertFalse(udp443.flow in vlessFlows)
    }

    @Test
    fun `the sing-box json row loads a legacy encryption`() {
        val row = jsonObjectOf(
            "type" to "vless",
            "server" to "vless.example.com",
            "server_port" to 443,
            "uuid" to uuid,
            "encryption" to "mlkem768x25519plus.native.0rtt.AAAA",
        )
        val loaded = Vless()
        assertTrue(loaded.parseFromJson(row))
        assertEquals("mlkem768x25519plus.native.0rtt.AAAA", loaded.encryption)
        assertEquals("none", Vless().encryption)
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
    fun `a Clash xhttp entry imports as the sing-box type`() {
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
                xhttp-opts:
                  path: /x
                  host: cdn.example.com
                  mode: packet-up
        """.trimIndent()

        val result = ProfileImport.parse(yaml, ctx = BuildContext.DEFAULT)

        assertEquals(1, result.outbounds.size)
        val imported = result.outbounds.single()
        assertTrue(imported is Vless)
        imported as Vless
        assertEquals("xhttp", imported.transport.type)
        assertEquals("/x", imported.transport.path)
        assertEquals("cdn.example.com", imported.transport.host)
        assertEquals("packet-up", imported.transport.mode)
    }

    @Test
    fun `a Clash kcp entry imports as the sing-box type`() {
        val yaml = """
            proxies:
              - name: clash-kcp
                type: vless
                server: vless.example.com
                port: 443
                uuid: $uuid
                network: kcp
                tls: true
                servername: sni.example.com
                kcp-opts:
                  mtu: 1400
                  tti: 40
                  header-type: srtp
                  seed: abc
        """.trimIndent()

        val result = ProfileImport.parse(yaml, ctx = BuildContext.DEFAULT)

        assertEquals(1, result.outbounds.size)
        val imported = result.outbounds.single()
        assertTrue(imported is Vless)
        imported as Vless
        assertEquals("mkcp", imported.transport.type)
        assertEquals(1400, imported.transport.mtu)
        assertEquals(40, imported.transport.tti)
        assertEquals("srtp", imported.transport.header_type)
        assertEquals("abc", imported.transport.seed)
    }

    @Test
    fun `a Clash entry with VLESS Encryption imports as the sing-box type`() {
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
        val imported = result.outbounds.single()
        assertTrue(imported is Vless)
        assertEquals("mlkem768x25519plus.native.0rtt.AAAA", (imported as Vless).encryption)
    }
}
