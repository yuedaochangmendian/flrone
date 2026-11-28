package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.ClashYaml
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.link.Hosts
import io.nekohasekai.sagernet.outbound.types.Hysteria
import io.nekohasekai.sagernet.outbound.types.Http
import io.nekohasekai.sagernet.outbound.types.Shadowsocks
import io.nekohasekai.sagernet.outbound.types.Socks
import io.nekohasekai.sagernet.outbound.types.Trojan
import io.nekohasekai.sagernet.outbound.types.Vless
import io.nekohasekai.sagernet.outbound.types.Vmess
import org.junit.Assert.assertTrue
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Parity pins for the Go `profileExport` simple slice (direct/http/socks/
 * shadowsocks). The expected strings are the ones the Go tests assert, so a
 * change on either side fails here or there instead of drifting silently.
 */
class ProfileStoredGoParityTest {

    private fun outbound(document: String): Outbound =
        OutboundFactory.fromJson(JsonInput.parseObject(document))
            ?: error("document did not parse: $document")

    @Test
    fun `direct exports the tag and dial fields`() {
        val outbound = outbound("""{"type":"direct","tag":"D","reuse_addr":true}""")
        assertEquals("""{"reuse_addr":true,"tag":"D","type":"direct"}""", outbound.exportToJson().toCompact())
        assertEquals("reuse_addr=true", outbound.exportToLink())
    }

    @Test
    fun `http exports its stored form, identity and link`() {
        val outbound = outbound(
            """{"type":"http","tag":"H","server":"Example.COM","server_port":8080,
               "username":"u","password":"p","path":"/x",
               "headers":{"B":"2","A":"1"},"connect_timeout":"5s"}""",
        )
        assertEquals(
            """{"connect_timeout":"5s","headers":{"A":"1","B":"2"},"password":"p","path":"/x","server":"Example.COM","server_port":8080,"tag":"H","type":"http","username":"u"}""",
            outbound.exportToJson().toCompact(),
        )
        assertEquals("http://u:p@example.com:8080?path=/x&headers=A,1,B,2&connect_timeout=5s#H", outbound.exportToLink())
        assertEquals("""{"server":"Example.COM","server_port":8080}""", outbound.exportIdentity().toCompact())
    }

    @Test
    fun `socks versions round-trip the stored text`() {
        val v4 = outbound("""{"type":"socks","server":"host","server_port":1080,"version":"4"}""")
        assertEquals("socks4://host:1080", v4.exportToLink())
        assertEquals("""{"server":"host","server_port":1080,"type":"socks","version":"4"}""", v4.exportToJson().toCompact())
        val v4a = outbound("""{"type":"socks","server":"host","server_port":1080,"version":"4a"}""")
        assertEquals("socks4a://host:1080", v4a.exportToLink())
    }

    @Test
    fun `an IDN host is stored as ACE and exported as ACE`() {
        val ace = Hosts.toAceHost("例子.测试")
        val outbound = outbound("""{"type":"http","server":"例子.测试","server_port":80}""")
        assertEquals("""{"server":"$ace","server_port":80,"type":"http"}""", outbound.exportToJson().toCompact())
        val link = outbound.exportToLink()
        assertEquals("http://$ace:80", link)
    }

    @Test
    fun `shadowsocks legacy userinfo is padded base64url`() {
        val outbound = outbound(
            """{"type":"shadowsocks","server":"host","server_port":8388,
               "method":"aes-256-gcm","password":"secret","tag":"SS"}""",
        )
        assertEquals("ss://YWVzLTI1Ni1nY206c2VjcmV0@host:8388#SS", outbound.exportToLink())
        assertEquals(
            """{"method":"aes-256-gcm","password":"secret","server":"host","server_port":8388,"tag":"SS","type":"shadowsocks"}""",
            outbound.exportToJson().toCompact(),
        )
    }
    // --- S5c link-import half: Kotlin exportToJson bytes pinned for the Go importer. ---

    private fun assertLinkStored(type: String, link: String, expected: String) {
        val outbound: Outbound = when (type) {
            "vmess" -> Vmess()
            "vless" -> Vless()
            "trojan" -> Trojan()
            "hysteria", "hysteria2", "hy2" -> Hysteria()
            else -> error("unknown type $type")
        }
        assertTrue("link should parse: $link", outbound.parseFromLink(link))
        assertEquals(expected, outbound.exportToJson().toCompact())
    }

    private val importUuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

    @Test
    fun `import vless tls ws`() = assertLinkStored(
        "vless",
        "vless://$importUuid@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws#node",
        """{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"node","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"vless","uuid":"$importUuid"}""",
    )

    @Test
    fun `import vless vision flow`() = assertLinkStored(
        "vless",
        "vless://$importUuid@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=tcp&flow=xtls-rprx-vision#v",
        """{"encryption":"none","flow":"xtls-rprx-vision","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"v","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"vless","uuid":"$importUuid"}""",
    )

    @Test
    fun `import vless encryption and grpc`() = assertLinkStored(
        "vless",
        "vless://$importUuid@vless.example.com:443?encryption=mlkem768x25519plus.native.0rtt.AAAA&security=tls&sni=sni.example.com&type=grpc&serviceName=svc#e",
        """{"encryption":"mlkem768x25519plus.native.0rtt.AAAA","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"e","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"service_name":"svc","type":"grpc"},"type":"vless","uuid":"$importUuid"}""",
    )

    @Test
    fun `import vless alpn fp insecure ws host`() = assertLinkStored(
        "vless",
        "vless://$importUuid@vless.example.com:8443?encryption=none&security=tls&sni=sni.example.com&type=ws&host=cdn.example.com&path=%2Fws&alpn=h2%2Chttp%2F1.1&fp=chrome&allowInsecure=1#a",
        """{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":8443,"tag":"a","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vless","uuid":"$importUuid"}""",
    )

    @Test
    fun `import vless reality`() = assertLinkStored(
        "vless",
        "vless://$importUuid@vless.example.com:443?encryption=none&security=reality&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&fp=chrome&sni=sni.example.com&type=tcp&flow=xtls-rprx-vision#r",
        """{"encryption":"none","flow":"xtls-rprx-vision","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"$importUuid"}""",
    )

    @Test
    fun `import vmess v2rayn base64 json`() = assertLinkStored(
        "vmess",
        "vmess://eyJ2IjoiMiIsInBzIjoibm9kZSIsImFkZCI6ImV4YW1wbGUuY29tIiwicG9ydCI6IjQ0MyIsImlkIjoiYjgzMTM4MWQtNjMyNC00ZDUzLWFkNGYtOGNkYTQ4YjMwODExIiwiYWlkIjoiMCIsIm5ldCI6IndzIiwidHlwZSI6Im5vbmUiLCJob3N0IjoiY2RuLmV4YW1wbGUuY29tIiwicGF0aCI6Ii93cyIsInRscyI6InRscyIsInNuaSI6InNuaS5leGFtcGxlLmNvbSIsImFscG4iOiJoMixodHRwLzEuMSIsImZwIjoiY2hyb21lIiwic2N5IjoiYXV0byJ9",
        """{"packet_encoding":"xudp","server":"example.com","server_port":443,"tag":"node","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vmess","uuid":"$importUuid"}""",
    )

    @Test
    fun `import vmess url form`() = assertLinkStored(
        "vmess",
        "vmess://$importUuid@example.com:443?encryption=auto&security=tls&sni=sni.example.com&type=ws&path=%2Fws&alterId=0&packetEncoding=xudp#v",
        """{"packet_encoding":"xudp","server":"example.com","server_port":443,"tag":"v","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"vmess","uuid":"$importUuid"}""",
    )

    @Test
    fun `import trojan ws`() = assertLinkStored(
        "trojan",
        "trojan://pass@trojan.example.com:443?sni=sni.example.com&alpn=h2%2Chttp%2F1.1&type=ws&path=%2Fws&host=h.example.com#t",
        """{"password":"pass","server":"trojan.example.com","server_port":443,"tag":"t","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"Host":"h.example.com"},"path":"/ws","type":"ws"},"type":"trojan"}""",
    )

    @Test
    fun `import trojan grpc insecure`() = assertLinkStored(
        "trojan",
        "trojan://pass@trojan.example.com:443?security=tls&sni=sni.example.com&type=grpc&serviceName=svc&allowInsecure=1#g",
        """{"password":"pass","server":"trojan.example.com","server_port":443,"tag":"g","tls":{"enabled":true,"insecure":true,"server_name":"sni.example.com"},"transport":{"service_name":"svc","type":"grpc"},"type":"trojan"}""",
    )

    @Test
    fun `import hysteria v1`() = assertLinkStored(
        "hysteria",
        "hysteria://host.example.com:443?auth=secret&obfsParam=obfs-secret&upmbps=100&downmbps=50&recv_window_conn=10&recv_window=20&sni=sni.example.com&alpn=h3&insecure=1#hy1",
        """{"auth_str":"secret","down_mbps":50,"obfs":"obfs-secret","recv_window":20,"recv_window_conn":10,"server":"host.example.com","server_port":443,"tag":"hy1","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"hysteria","up_mbps":100}""",
    )

    @Test
    fun `import hysteria2 salamander`() = assertLinkStored(
        "hysteria2",
        "hysteria2://password@host.example.com:443?obfs=salamander&obfs-password=obfs-secret&upmbps=100&downmbps=50&sni=sni.example.com&alpn=h3&insecure=1#hy2",
        """{"down_mbps":50,"obfs":{"max_packet_size":0,"min_packet_size":0,"password":"obfs-secret","type":"salamander"},"password":"password","server":"host.example.com","server_port":443,"tag":"hy2","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}""",
    )

    @Test
    fun `import hy2 gecko sizes`() = assertLinkStored(
        "hy2",
        "hy2://password@host.example.com:443?obfs=gecko&obfs-password=obfs-secret&min_packet_size=512&max_packet_size=1200&upmbps=100&downmbps=50&sni=sni.example.com&alpn=h3#hy3",
        """{"down_mbps":50,"obfs":{"max_packet_size":1200,"min_packet_size":512,"password":"obfs-secret","type":"gecko"},"password":"password","server":"host.example.com","server_port":443,"tag":"hy3","tls":{"alpn":["h3"],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}""",
    )

    @Test
    fun `advanced share-link identities match the Go importer`() {
        val uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        val cases = listOf(
            "vless://$uuid@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws" to
                """{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}""",
            "vless://$uuid@vless.example.com:8443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws&alpn=h2%2Chttp%2F1.1&fp=chrome&allowInsecure=1" to
                """{"server":"vless.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}},"transport":{"type":"ws"}}""",
            "vless://$uuid@vless.example.com:443?encryption=none&security=reality&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&fp=chrome&sni=sni.example.com&type=tcp" to
                """{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
            "hysteria2://password@host.example.com:443?sni=sni.example.com&alpn=h3&insecure=1" to
                """{"protocol_version":"2","server":"host.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        )
        for ((link, expected) in cases) {
            val outbound = OutboundFactory.parseLink(link) ?: error("link did not parse: $link")
            assertEquals(expected, outbound.exportIdentity().toCompact())
        }
    }

    // --- S5d Clash-to-stored oracle pins: the bytes profileImportClashBody must produce. ---

    private fun assertClashStored(yaml: String, expected: String) {
        val entries = ClashYaml.proxies(yaml) ?: error("document has no proxies: $yaml")
        assertEquals(1, entries.size)
        val entry = entries.single()
        val outbound: Outbound = when (entry.string("type").lowercase()) {
            "ss" -> Shadowsocks()
            "socks5" -> Socks()
            "http" -> Http()
            "vmess" -> Vmess()
            "vless" -> Vless()
            "trojan" -> Trojan()
            "hysteria", "hysteria2" -> Hysteria()
            else -> error("unknown Clash type ${entry.string("type")}")
        }
        assertTrue("Clash entry should parse", outbound.parseFromClash(entry))
        assertEquals(expected, outbound.exportToJson().toCompact())
    }

    @Test
    fun `clash simple ss socks http`() {
        assertClashStored(
            """proxies:
  - {name: ss1, type: ss, server: ss.example.com, port: 8388, cipher: AES-256-GCM, password: secret, udp-over-tcp: true}
""",
            """{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"secret","server":"ss.example.com","server_port":8388,"tag":"ss1","type":"shadowsocks","udp_over_tcp":true}""",
        )
        assertClashStored(
            """proxies:
  - {name: s5, type: socks5, server: socks.example.com, port: 1080, username: u, password: p}
""",
            """{"password":"p","server":"socks.example.com","server_port":1080,"tag":"s5","type":"socks","username":"u"}""",
        )
        assertClashStored(
            """proxies:
  - {name: h1, type: http, server: http.example.com, port: 8080, username: u, password: p}
""",
            """{"password":"p","server":"http.example.com","server_port":8080,"tag":"h1","type":"http","username":"u"}""",
        )
    }

    @Test
    fun `clash ss plugin conversions`() {
        assertClashStored(
            """proxies:
  - {name: ss-v2, type: ss, server: s.example.com, port: 8388, cipher: aes-256-gcm, password: pass, plugin: v2ray-plugin, 'plugin-opts': {tls: true, host: cdn.example.com, path: /ws, mode: websocket, mux: true}}
""",
            """{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"pass","plugin":"v2ray-plugin","plugin_opts":"tls;host=cdn.example.com;path=/ws;mode=websocket;mux","server":"s.example.com","server_port":8388,"tag":"ss-v2","type":"shadowsocks"}""",
        )
        assertClashStored(
            """proxies:
  - {name: ss-obfs, type: ss, server: s.example.com, port: 8388, cipher: aes-256-gcm, password: pass, plugin: obfs, 'plugin-opts': {mode: tls, host: cdn.example.com}}
""",
            """{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"pass","plugin":"obfs-local","plugin_opts":"obfs=tls;obfs-host=cdn.example.com","server":"s.example.com","server_port":8388,"tag":"ss-obfs","type":"shadowsocks"}""",
        )
    }

    @Test
    fun `clash vmess vless trojan transports`() {
        assertClashStored(
            """proxies:
  - {name: v1, type: vmess, server: vmess.example.com, port: 443, uuid: $importUuid, alterId: 0, cipher: auto, tls: true, servername: sni.example.com, network: ws, 'ws-opts': {path: /ws, headers: {Host: cdn.example.com}}}
""",
            """{"multiplex":{"enabled":false},"packet_encoding":"","server":"vmess.example.com","server_port":443,"tag":"v1","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vmess","uuid":"$importUuid"}""",
        )
        assertClashStored(
            """proxies:
  - {name: vl, type: vless, server: vless.example.com, port: 443, uuid: $importUuid, tls: true, servername: sni.example.com, network: grpc, 'grpc-opts': {'grpc-service-name': svc}, 'client-fingerprint': chrome}
""",
            """{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"vless.example.com","server_port":443,"tag":"vl","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"service_name":"svc","type":"grpc"},"type":"vless","uuid":"$importUuid"}""",
        )
        assertClashStored(
            """proxies:
  - {name: tj, type: trojan, server: trojan.example.com, port: 443, password: pass, sni: sni.example.com, alpn: [h2, http/1.1], 'skip-cert-verify': true, network: ws, 'ws-opts': {path: /ws}}
""",
            """{"multiplex":{"enabled":false},"password":"pass","server":"trojan.example.com","server_port":443,"tag":"tj","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"trojan"}""",
        )
    }

    @Test
    fun `clash hysteria v1 and v2`() {
        assertClashStored(
            """proxies:
  - {name: hy, type: hysteria, server: hy.example.com, port: 443, 'auth-str': secret, up: 100 Mbps, down: '50 Mbps', 'recv-window': 20, sni: sni.example.com, alpn: [h3]}
""",
            """{"auth_str":"secret","down_mbps":50,"recv_window":20,"server":"hy.example.com","server_port":443,"tag":"hy","tls":{"alpn":["h3"],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria","up_mbps":100}""",
        )
        assertClashStored(
            """proxies:
  - {name: hy2, type: hysteria2, server: hy2.example.com, port: 443, password: pass, obfs: salamander, 'obfs-password': obfspass, up: '100 Mbps', down: '50 Mbps', sni: sni.example.com}
""",
            """{"down_mbps":50,"obfs":{"max_packet_size":0,"min_packet_size":0,"password":"obfspass","type":"salamander"},"password":"pass","server":"hy2.example.com","server_port":443,"tag":"hy2","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}""",
        )
    }

    @Test
    fun `clash tls fields and reality`() {
        assertClashStored(
            """proxies:
  - {name: rz, type: vless, server: v.example.com, port: 443, uuid: u, tls: true, 'reality-opts': {'public-key': abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI, 'short-id': abc}}
""",
            """{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"v.example.com","server_port":443,"tag":"rz","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI","short_id":"abc"},"server_name":"v.example.com"},"type":"vless","uuid":"u"}""",
        )
        assertClashStored(
            """proxies:
  - {name: p, type: trojan, server: t.example.com, port: 443, password: p, tls: true, fingerprint: 'AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'}
""",
            """{"multiplex":{"enabled":false},"password":"p","server":"t.example.com","server_port":443,"tag":"p","tls":{"certificate_sha256":["qrvM3e7/ABEiM0RVZneImaq7zN3u/wARIjNEVWZ3iJk="],"enabled":true,"server_name":"t.example.com"},"type":"trojan"}""",
        )
    }

    // --- S5 export advanced slice: Kotlin export bytes pinned for Go. ---
    // The Go advanced exporter reads these same stored documents and must
    // reproduce all four outputs byte-for-byte.

    private fun assertStoredExport(
        document: String,
        json: String,
        link: String,
        identity: String,
    ) {
        val outbound = outbound(document)
        assertEquals(json, outbound.exportToJson().toCompact())
        assertEquals(link, outbound.exportToLink())
        assertEquals(identity, outbound.exportIdentity().toCompact())
    }

    private val exportUuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

    @Test
    fun `export vmess v2rayn ws tls`() {
        assertStoredExport(
            """{"packet_encoding":"xudp","server":"example.com","server_port":443,"tag":"node","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vmess","uuid":"$exportUuid"}""",
            """{"packet_encoding":"xudp","server":"example.com","server_port":443,"tag":"node","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"headers":{"Host":"cdn.example.com"},"path":"/ws","type":"ws"},"type":"vmess","uuid":"$exportUuid"}""",
            "vmess://eyJhZGQiOiJleGFtcGxlLmNvbSIsImFpZCI6IjAiLCJhbHBuIjoiaDIsaHR0cC8xLjEiLCJmcCI6ImNocm9tZSIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJpZCI6ImI4MzEzODFkLTYzMjQtNGQ1My1hZDRmLThjZGE0OGIzMDgxMSIsIm5ldCI6IndzIiwicGF0aCI6Ii93cyIsInBvcnQiOiI0NDMiLCJwcyI6Im5vZGUiLCJzY3kiOiJhdXRvIiwic25pIjoic25pLmV4YW1wbGUuY29tIiwidGhyb25lRXh0cmEiOiJ0eXBlPXdzJmhvc3Q9Y2RuLmV4YW1wbGUuY29tJnBhdGg9L3dzIiwidGxzIjoidGxzIiwidHlwZSI6Im5vbmUiLCJ2IjoiMiJ9",
            """{"server":"example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}},"transport":{"type":"ws"}}""",
        )
    }

    @Test
    fun `export vless tls ws`() {
        assertStoredExport(
            """{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"node","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"vless","uuid":"$exportUuid"}""",
            """{"encryption":"none","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"node","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"path":"/ws","type":"ws"},"type":"vless","uuid":"$exportUuid"}""",
            "vless://$exportUuid@vless.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=/ws&packetEncoding=xudp#node",
            """{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}""",
        )
    }

    @Test
    fun `export vless reality vision`() {
        assertStoredExport(
            """{"encryption":"none","flow":"xtls-rprx-vision","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"$exportUuid"}""",
            """{"encryption":"none","flow":"xtls-rprx-vision","packet_encoding":"xudp","server":"vless.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"$exportUuid"}""",
            "vless://$exportUuid@vless.example.com:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=sni.example.com&fp=chrome&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&packetEncoding=xudp#r",
            """{"server":"vless.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc"},"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
        )
    }

    @Test
    fun `export trojan ws`() {
        assertStoredExport(
            """{"password":"pass","server":"trojan.example.com","server_port":443,"tag":"t","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"Host":"h.example.com"},"path":"/ws","type":"ws"},"type":"trojan"}""",
            """{"password":"pass","server":"trojan.example.com","server_port":443,"tag":"t","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"Host":"h.example.com"},"path":"/ws","type":"ws"},"type":"trojan"}""",
            "trojan://pass@trojan.example.com:443?security=tls&sni=sni.example.com&alpn=h2,http/1.1&type=ws&host=h.example.com&path=/ws#t",
            """{"server":"trojan.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}""",
        )
    }

    @Test
    fun `export hysteria v1`() {
        assertStoredExport(
            """{"auth_str":"secret","down_mbps":50,"obfs":"obfs-secret","recv_window":20,"recv_window_conn":10,"server":"host.example.com","server_port":443,"tag":"hy1","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"hysteria","up_mbps":100}""",
            """{"auth_str":"secret","down_mbps":50,"obfs":"obfs-secret","recv_window":20,"recv_window_conn":10,"server":"host.example.com","server_port":443,"tag":"hy1","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"hysteria","up_mbps":100}""",
            "hysteria://host.example.com:443?obfsParam=obfs-secret&auth=secret&recv_window_conn=10&recv_window=20&upmbps=100&downmbps=50&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h3#hy1",
            """{"obfs":true,"protocol_version":"1","server":"host.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        )
    }

    @Test
    fun `export hysteria2 gecko`() {
        assertStoredExport(
            """{"down_mbps":50,"obfs":{"max_packet_size":1200,"min_packet_size":512,"password":"obfs-secret","type":"gecko"},"password":"password","server":"host.example.com","server_port":443,"tag":"hy2","tls":{"alpn":["h3"],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}""",
            """{"down_mbps":50,"obfs":{"max_packet_size":1200,"min_packet_size":512,"password":"obfs-secret","type":"gecko"},"password":"password","server":"host.example.com","server_port":443,"tag":"hy2","tls":{"alpn":["h3"],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2","up_mbps":100}""",
            "hysteria2://password@host.example.com:443?obfs=gecko&obfs-password=obfs-secret&min_packet_size=512&max_packet_size=1200&upmbps=100&downmbps=50&security=tls&sni=sni.example.com&alpn=h3#hy2",
            """{"obfs":true,"protocol_version":"2","server":"host.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        )
    }

    // --- S5 advanced: every expected string below is Kotlin's exact
    // exportToJson().toCompact() / exportIdentity().toCompact() output for the
    // link/Clash vector; the Go importer tests pin the same bytes. ---

    private val advancedUUID = "b831381d-6324-4d53-ad4f-8cda48b30811"
    private val pin64 = "AA:".repeat(31) + "AA"

    @Test
    fun `advanced tls link fields`() = assertLinkStored(
        "vless",
        "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&disable_sni=1&sni=sni.example.com&alpn=h2&tls_min_version=1.2&tls_max_version=1.3&tls_certificate=A%2CB&tls_certificate_path=%2Fp&pcs=$pin64&tls_certificate_public_key_sha256=pk1%2Cpk2&tls_client_certificate=C&tls_client_certificate_path=%2Fcp&tls_client_key=K&tls_client_key_path=%2Fkp&fp=chrome#tls",
        """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"tls","tls":{"alpn":["h2"],"certificate":["A%2CB"],"certificate_path":"%2Fp","certificate_public_key_sha256":["pk1%2Cpk2"],"certificate_sha256":["qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="],"client_certificate":["C"],"client_certificate_path":"%2Fcp","client_key":["K"],"client_key_path":"%2Fkp","disable_sni":true,"enabled":true,"max_version":"1.3","min_version":"1.2","server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"$advancedUUID"}""",
    )

    @Test
    fun `advanced ech target and config`() {
        assertLinkStored(
            "vless",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&ech=ech.example.com%2Bhttps%3A%2F%2Fresolver.example.com&fp=chrome#ech",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"ech","tls":{"ech":{"enabled":true,"query_server_name":"ech.example.com","resolver":"https://resolver.example.com"},"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"$advancedUUID"}""",
        )
        assertLinkStored(
            "vless",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&ech_config=ZWNmLWNvbmZpZw&ech_enabled=true#echcfg",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"echcfg","tls":{"ech":{"config":["-----BEGIN ECH CONFIGS-----","ZWNmLWNvbmZpZw","-----END ECH CONFIGS-----"],"enabled":true},"enabled":true,"server_name":"sni.example.com"},"type":"vless","uuid":"$advancedUUID"}""",
        )
    }

    @Test
    fun `advanced transports ws early data httpupgrade xhttp mkcp`() {
        assertLinkStored(
            "vless",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws&host=cdn.example.com&headers=User-Agent%7Ctest%7CX-Other%7Cyes&max_early_data=2048&early_data_header_name=Sec-WebSocket-Protocol#ws",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"ws","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"early_data_header_name":"Sec-WebSocket-Protocol","headers":{"Host":"cdn.example.com","User-Agent":"test","X-Other":"yes"},"max_early_data":2048,"path":"/ws","type":"ws"},"type":"vless","uuid":"$advancedUUID"}""",
        )
        assertLinkStored(
            "vless",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=httpupgrade&path=%2Fh&host=h.example.com&headers=A%7CB#hu",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"hu","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"A":"B"},"host":"h.example.com","path":"/h","type":"httpupgrade"},"type":"vless","uuid":"$advancedUUID"}""",
        )
        assertLinkStored(
            "vless",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=xhttp&host=x.example.com&path=%2Fx&mode=packet-up&x_padding_bytes=100-200#xh",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"host":"x.example.com","mode":"packet-up","path":"/x","type":"xhttp","x_padding_bytes":"100-200"},"type":"vless","uuid":"$advancedUUID"}""",
        )
        assertLinkStored(
            "vless",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=kcp&mtu=1350&tti=50&uplinkCapacity=20&downlinkCapacity=50&congestion=true&readBufferSize=4&writeBufferSize=4&headerType=srtp&seed=abc#kcp",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"kcp","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"congestion":true,"downlink_capacity":50,"header_type":"srtp","mtu":1350,"read_buffer_size":4,"seed":"abc","tti":50,"type":"mkcp","uplink_capacity":20,"write_buffer_size":4},"type":"vless","uuid":"$advancedUUID"}""",
        )
    }

    @Test
    fun `advanced multiplex vless and shadowsocks`() {
        assertLinkStored(
            "vless",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&mux=true&mux_protocol=smux&mux_max_connections=4&mux_min_streams=2&mux_padding=true&brutal_enabled=true&brutal_up_mbps=100&brutal_down_mbps=50#mx",
            """{"encryption":"none","multiplex":{"brutal":{"down_mbps":50,"enabled":true,"up_mbps":100},"enabled":true,"max_connections":4,"min_streams":2,"padding":true,"protocol":"smux"},"packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"mx","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"vless","uuid":"$advancedUUID"}""",
        )
        assertLinkStored(
            "ss",
            "ss://YWVzLTI1Ni1nY206c2VjcmV0@h.example.com:8388?mux=true&mux_protocol=yamux&mux_max_streams=8&mux_padding=true#ssm",
            """{"method":"aes-256-gcm","multiplex":{"enabled":true,"max_streams":8,"padding":true,"protocol":"yamux"},"password":"secret","server":"h.example.com","server_port":8388,"tag":"ssm","type":"shadowsocks"}""",
        )
    }

    @Test
    fun `advanced hysteria port hopping protocol obfs bbr pins quic`() {
        assertLinkStored(
            "hysteria",
            "hysteria://h.example.com:443?auth=secret&mport=1000-2000%2C3000&hop_interval=10s&pinSHA256=$pin64&quic_idle_timeout=10s&quic_stream_receive_window=1m&quic_max_concurrent_streams=100&quic_initial_packet_size=1400&quic_disable_path_mtu_discovery=true&sni=sni.example.com#hy1",
            """{"auth_str":"secret","disable_path_mtu_discovery":true,"hop_interval":"10s","idle_timeout":"10s","initial_packet_size":1400,"max_concurrent_streams":100,"server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"stream_receive_window":"1m","tag":"hy1","tls":{"certificate_sha256":["qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria"}""",
        )
        assertLinkStored(
            "hysteria2",
            "hysteria2://pass@h.example.com:443?mport=1000-2000%2C3000&hop_interval=10s&hop_interval_max=20s&bbr_profile=standard&disable_chrome_parrot=true&pinSHA256=$pin64&quic_keep_alive_period=5s&sni=sni.example.com#hy2",
            """{"bbr_profile":"standard","disable_chrome_parrot":true,"hop_interval":"10s","hop_interval_max":"20s","keep_alive_period":"5s","password":"pass","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy2","tls":{"certificate_sha256":["qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="],"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2"}""",
        )
    }

    @Test
    fun `advanced identities match the Go importer`() {
        val cases = listOf(
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=ws&path=%2Fws&headers=User-Agent%7Ctest%7CX-Other%7Cyes&max_early_data=2048" to
                """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"ws"}}""",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=xhttp" to
                """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp"}}""",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&disable_sni=1&sni=sni.example.com&fp=chrome" to
                """{"server":"h.example.com","server_port":443,"tls":{"disable_sni":true,"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
            "vless://$advancedUUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&ech=ech.example.com%2Bhttps%3A%2F%2Fresolver.example.com&fp=chrome" to
                """{"server":"h.example.com","server_port":443,"tls":{"ech":{"enabled":true,"query_server_name":"ech.example.com","resolver":"https://resolver.example.com"},"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
            "hysteria://h.example.com:443?mport=1000-2000%2C3000&sni=sni.example.com" to
                """{"protocol_version":"1","server":"h.example.com","server_port":443,"server_ports":"1000:2000,3000:3000","tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        )
        for ((link, expected) in cases) {
            val out = OutboundFactory.parseLink(link) ?: error("link did not parse: $link")
            assertEquals(expected, out.exportIdentity().toCompact())
        }
    }

    @Test
    fun `advanced reality mldsa65 verify from link and clash`() {
        val key = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(1952) { 65 })
        val reality = """"enabled":true,"mldsa65_verify":"$key","public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK","short_id":"abc""""
        val link = "vless://u@h.example.com:443?encryption=none&security=reality&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK&sid=abc&pqv=$key&sni=sni.example.com"
        val out = OutboundFactory.parseLink(link) ?: error("link did not parse")
        assertEquals(
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tls":{"enabled":true,"reality":{$reality},"server_name":"sni.example.com"},"type":"vless","uuid":"u"}""",
            out.exportToJson().toCompact(),
        )
        assertEquals(
            """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"reality":{$reality},"server_name":"sni.example.com"}}""",
            out.exportIdentity().toCompact(),
        )
        assertClashStored(
            """proxies:
  - {name: r, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, 'reality-opts': {'public-key': abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJK, 'short-id': abc, 'mldsa65-verify': '$key'}}
""",
            """{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{$reality},"server_name":"h.example.com"},"type":"vless","uuid":"u"}""",
        )
    }

    @Test
    fun `advanced clash xhttp kcp smux and hysteria ports`() {
        assertClashStored(
            """proxies:
  - {name: xh, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, network: xhttp, 'xhttp-opts': {path: /x, mode: stream-up, host: x.example.com, 'x-padding-bytes': '100-200', 'no-grpc-header': true, headers: {A: B}}}
""",
            """{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"h.example.com"},"transport":{"headers":{"A":"B"},"host":"x.example.com","mode":"stream-up","no_grpc_header":true,"path":"/x","type":"xhttp","x_padding_bytes":"100-200"},"type":"vless","uuid":"u"}""",
        )
        assertClashStored(
            """proxies:
  - {name: kc, type: vmess, server: h.example.com, port: 443, uuid: u, cipher: auto, tls: true, network: kcp, 'kcp-opts': {mtu: 1350, tti: 50, 'uplink-capacity': 20, 'downlink-capacity': 50, congestion: true, 'header-type': srtp, seed: abc}}
""",
            """{"multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"kc","tls":{"enabled":true,"server_name":"h.example.com"},"transport":{"congestion":true,"downlink_capacity":50,"header_type":"srtp","mtu":1350,"seed":"abc","tti":50,"type":"mkcp","uplink_capacity":20},"type":"vmess","uuid":"u"}""",
        )
        assertClashStored(
            """proxies:
  - {name: sm, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, smux: {enabled: true, protocol: smux, 'max-connections': 4, 'min-streams': 2, padding: true}}
""",
            """{"encryption":"none","multiplex":{"enabled":true,"max_connections":4,"min_streams":2,"padding":true,"protocol":"smux"},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"sm","tls":{"enabled":true,"server_name":"h.example.com"},"type":"vless","uuid":"u"}""",
        )
        assertClashStored(
            """proxies:
  - {name: hy, type: hysteria, server: h.example.com, port: 443, 'auth-str': s, ports: '1000-2000,3000', 'hop-interval': '10', sni: sni.example.com}
""",
            """{"auth_str":"s","hop_interval":"10s","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria"}""",
        )
        assertClashStored(
            """proxies:
  - {name: hy2, type: hysteria2, server: h.example.com, port: 443, password: p, ports: '1000-2000,3000', 'hop-interval': '10', sni: sni.example.com}
""",
            """{"hop_interval":"10s","password":"p","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy2","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2"}""",
        )
    }
}
