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
}
