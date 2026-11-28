package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.ClashYaml
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.link.Hosts
import io.nekohasekai.sagernet.outbound.types.AnyTls
import io.nekohasekai.sagernet.outbound.types.Hysteria
import io.nekohasekai.sagernet.outbound.types.Http
import io.nekohasekai.sagernet.outbound.types.Shadowsocks
import io.nekohasekai.sagernet.outbound.types.Socks
import io.nekohasekai.sagernet.outbound.types.Trojan
import io.nekohasekai.sagernet.outbound.types.Tuic
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
            "ss", "shadowsocks" -> Shadowsocks()
            "http" -> Http()
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
    fun `import http tls link`() = assertLinkStored(
        "http",
        "https://u:p@h.example.com?security=tls&sni=sni.example.com&fp=chrome",
        """{"password":"p","server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"http","username":"u"}""",
    )

    @Test
    fun `import http security tls keeps the explicit port`() = assertLinkStored(
        "http",
        "http://h.example.com:8080?security=tls",
        """{"server":"h.example.com","server_port":8080,"tls":{"enabled":true},"type":"http"}""",
    )

    @Test
    fun `import an empty pcs is valid`() = assertLinkStored(
        "vless",
        "vless://$importUuid@host:443?security=tls&sni=s.example.com&pcs=",
        """{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"tls":{"enabled":true,"server_name":"s.example.com"},"type":"vless","uuid":"$importUuid"}""",
    )

    @Test
    fun `import unknown security leaves tls off`() = assertLinkStored(
        "vless",
        "vless://$importUuid@host:443?security=bogus",
        """{"encryption":"none","packet_encoding":"xudp","server":"host","server_port":443,"type":"vless","uuid":"$importUuid"}""",
    )

    // The URL form reads neither throneExtra nor pinSHA256 (only the V2RayN
    // body reads throneExtra, and pinSHA256 belongs to Hysteria).
    @Test
    fun `import vmess url form ignores throneExtra and pinSHA256`() = assertLinkStored(
        "vmess",
        "vmess://$importUuid@host:443?encryption=auto&packetEncoding=xudp&throneExtra=mux%3Dtrue&pinSHA256=abc",
        """{"packet_encoding":"xudp","server":"host","server_port":443,"type":"vmess","uuid":"$importUuid"}""",
    )

    @Test
    fun `import v2rayn ignores unknown keys and reads throneExtra`() = assertLinkStored(
        "vmess",
        "vmess://eyJ2IjoiMiIsInBzIjoiTiIsImFkZCI6ImguZXhhbXBsZS5jb20iLCJwb3J0IjoiODQ0MyIsImlkIjoidXVpZCIsImFpZCI6IjQiLCJuZXQiOiJ0Y3AiLCJ0eXBlIjoiaHR0cCIsImhvc3QiOiJjZG4uZXhhbXBsZS5jb20iLCJwYXRoIjoiL2EsL2IiLCJ0bHMiOiJ0bHMiLCJzbmkiOiJzbmkuZXhhbXBsZS5jb20iLCJzY3kiOiJhdXRvIiwiY3MiOiJUTFNfQUVTXzEyOF9HQ01fU0hBMjU2IiwiZnAiOiJjaHJvbWUiLCJ1bmtub3duS2V5IjoieCIsInRocm9uZUV4dHJhIjoibXV4PXRydWUmbXV4X3Byb3RvY29sPXNtdXgifQ==",
        """{"alter_id":4,"multiplex":{"enabled":true,"protocol":"smux"},"packet_encoding":"xudp","server":"h.example.com","server_port":8443,"tag":"N","tls":{"cipher_suites":["TLS_AES_128_GCM_SHA256"],"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"host":"cdn.example.com","method":"GET","path":"/a","type":"http"},"type":"vmess","uuid":"uuid"}""",
    )

    @Test
    fun `clash http tls exports an https stored form`() {
        assertClashStored(
            """proxies:
  - {name: t, type: http, server: h.example.com, port: 443, username: u, tls: true, sni: sni.example.com}
""",
            """{"server":"h.example.com","server_port":443,"tag":"t","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"http","username":"u"}""",
        )
        val outbound = Http()
        val entries = ClashYaml.proxies(
            """proxies:
  - {name: t, type: http, server: h.example.com, port: 8443, username: u, tls: true}
""",
        ) ?: error("no proxies")
        assertTrue(outbound.parseFromClash(entries.single()))
        assertEquals("https://u@h.example.com:8443?security=tls&sni=h.example.com#t", outbound.exportToLink())
        assertEquals(
            """{"server":"h.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"h.example.com"}}""",
            outbound.exportIdentity().toCompact(),
        )
    }

    @Test
    fun `stored http tls and a valid multiplex round-trip`() {
        assertEquals(
            """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"s"},"type":"http"}""",
            outbound("""{"type":"http","server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"s"}}""").exportToJson().toCompact(),
        )
        assertEquals(
            """{"multiplex":{"enabled":true,"max_streams":8,"protocol":"smux"},"packet_encoding":"xudp","server":"h","server_port":443,"type":"vmess","uuid":"u"}""",
            outbound("""{"type":"vmess","server":"h","server_port":443,"uuid":"u","packet_encoding":"xudp","multiplex":{"enabled":true,"protocol":"smux","max_streams":8}}""").exportToJson().toCompact(),
        )
    }

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
            "tuic" -> Tuic()
            "anytls" -> AnyTls()
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

    // --- S5 TLS/transport completion slice: cipher/curves/fragment/spoof/
    // tls_tricks, quic/xhttp-extra transports, Hysteria2 realm. The Go importer
    // and exporter tests pin the same bytes. ---

    private val tls2UUID = "b831381d-6324-4d53-ad4f-8cda48b30811"

    @Test
    fun `advanced tls2 link fields`() = assertLinkStored(
        "vless",
        "vless://$tls2UUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&alpn=h2%2Chttp%2F1.1&tls_min_version=1.2&tls_max_version=1.3&tls_cipher_suites=TLS_AES_128_GCM_SHA256%2CTLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256&tls_curve_preferences=X25519,P256&tls_fragment=true&tls_fragment_fallback_delay=500ms&tls_record_fragment=true&tls_spoof=example.org&tls_spoof_method=method&tls_spoof_enabled=true&tls_tricks=true&fp=chrome#tls2",
        """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"tls2","tls":{"alpn":["h2","http/1.1"],"cipher_suites":["TLS_AES_128_GCM_SHA256","TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256"],"curve_preferences":["X25519","P256"],"enabled":true,"fragment":true,"fragment_fallback_delay":"500ms","max_version":"1.3","min_version":"1.2","record_fragment":true,"server_name":"sni.example.com","spoof":"example.org","spoof_enabled":true,"spoof_method":"method","tls_tricks":{"mixedcase_sni":true},"utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"$tls2UUID"}""",
    )

    @Test
    fun `advanced tls2 stored export`() = assertStoredExport(
        """{"type":"vless","tag":"t","server":"h.example.com","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"],"min_version":"1.2","max_version":"1.3","cipher_suites":["TLS_AES_128_GCM_SHA256"],"curve_preferences":["X25519"],"fragment":true,"fragment_fallback_delay":"500ms","record_fragment":true,"spoof":"example.org","spoof_method":"method","spoof_enabled":true,"tls_tricks":{"mixedcase_sni":true},"utls":{"enabled":true,"fingerprint":"chrome"}}}""",
        """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"t","tls":{"alpn":["h2"],"cipher_suites":["TLS_AES_128_GCM_SHA256"],"curve_preferences":["X25519"],"enabled":true,"fragment":true,"fragment_fallback_delay":"500ms","max_version":"1.3","min_version":"1.2","record_fragment":true,"server_name":"sni.example.com","spoof":"example.org","spoof_enabled":true,"spoof_method":"method","tls_tricks":{"mixedcase_sni":true},"utls":{"enabled":true,"fingerprint":"chrome"}},"type":"vless","uuid":"u"}""",
        "vless://u@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&alpn=h2&tls_min_version=1.2&tls_max_version=1.3&cs=TLS_AES_128_GCM_SHA256&tls_curve_preferences=X25519&tls_fragment=true&tls_fragment_fallback_delay=500ms&tls_record_fragment=true&tls_spoof_enabled=true&tls_spoof=example.org&tls_spoof_method=method&tls_tricks=true&fp=chrome&packetEncoding=xudp#t",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
    )

    @Test
    fun `advanced quic transport link and stored export`() {
        assertLinkStored(
            "vless",
            "vless://$tls2UUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=quic#q",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"q","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"},"type":"vless","uuid":"$tls2UUID"}""",
        )
        assertStoredExport(
            """{"type":"vless","tag":"q","server":"h.example.com","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"}}""",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"q","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"},"type":"vless","uuid":"u"}""",
            "vless://u@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=quic&packetEncoding=xudp#q",
            """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"quic"}}""",
        )
    }

    @Test
    fun `advanced xhttp extra xmux and headers`() {
        assertLinkStored(
            "vless",
            "vless://$tls2UUID@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=xhttp&host=x.example.com&path=%2Fx&mode=packet-up&headers=User-Agent%7Ctest&extra=%7B%22xPaddingBytes%22%3A%22200-300%22%2C%22noSSEHeader%22%3Atrue%2C%22xmux%22%3A%7B%22maxConcurrency%22%3A%2216-32%22%7D%2C%22headers%22%3A%7B%22X-Extra%22%3A%22yes%22%7D%7D#xh",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"User-Agent":"test"},"host":"x.example.com","mode":"packet-up","no_sse_header":true,"path":"/x","type":"xhttp","x_padding_bytes":"200-300","xmux":{"maxConcurrency":"16-32"}},"type":"vless","uuid":"$tls2UUID"}""",
        )
        assertStoredExport(
            """{"type":"vless","tag":"xh","server":"h.example.com","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp","host":"x.example.com","path":"/x","mode":"packet-up","x_padding_bytes":"200-300","no_sse_header":true,"headers":{"User-Agent":"test"},"xmux":{"maxConcurrency":"16-32"}}}""",
            """{"encryption":"none","packet_encoding":"xudp","server":"h.example.com","server_port":443,"tag":"xh","tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"headers":{"User-Agent":"test"},"host":"x.example.com","mode":"packet-up","no_sse_header":true,"path":"/x","type":"xhttp","x_padding_bytes":"200-300","xmux":{"maxConcurrency":"16-32"}},"type":"vless","uuid":"u"}""",
            "vless://u@h.example.com:443?encryption=none&security=tls&sni=sni.example.com&type=xhttp&host=x.example.com&path=/x&mode=packet-up&headers=User-Agent%7Ctest&extra=%7B%22headers%22:%7B%22User-Agent%22:%22test%22%7D,%22noSSEHeader%22:true,%22xPaddingBytes%22:%22200-300%22,%22xmux%22:%7B%22maxConcurrency%22:%2216-32%22%7D%7D&packetEncoding=xudp#xh",
            """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"transport":{"type":"xhttp"}}""",
        )
    }

    @Test
    fun `advanced hysteria2 realm stored export`() = assertStoredExport(
        """{"type":"hysteria2","tag":"realm","password":"pass","realm":{"server_url":"https://realm.example.com","token":"tok","realm_id":"rid","stun_servers":["stun.example.com:3478"],"ip_version":4,"port_mapping":{"enabled":true,"timeout":"10s","lifetime":"30s"}},"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        """{"password":"pass","realm":{"ip_version":4,"port_mapping":{"enabled":true,"lifetime":"30s","timeout":"10s"},"realm_id":"rid","server_url":"https://realm.example.com","stun_servers":["stun.example.com:3478"],"token":"tok"},"tag":"realm","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"hysteria2"}""",
        "",
        """{"protocol_version":"2","realm_id":"rid","realm_server_url":"https://realm.example.com","tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `advanced hysteria2 port hopping and unsupported utls`() = assertLinkStored(
        "hysteria2",
        "hysteria2://pass@h.example.com:443?mport=1000-2000%2C3000&hop_interval=10&hop_interval_max=20&bbr_profile=standard&fp=banana&sni=sni.example.com#hy",
        """{"bbr_profile":"standard","hop_interval":"10s","hop_interval_max":"20s","password":"pass","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"banana"}},"type":"hysteria2"}""",
    )

    @Test
    fun `advanced hysteria2 port hopping stored link`() = assertStoredExport(
        """{"type":"hysteria2","tag":"hy","server":"h.example.com","server_port":443,"password":"pass","server_ports":["1000:2000","3000:3000"],"hop_interval":"10s","hop_interval_max":"20s","bbr_profile":"standard","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"banana"}}}""",
        """{"bbr_profile":"standard","hop_interval":"10s","hop_interval_max":"20s","password":"pass","server":"h.example.com","server_port":443,"server_ports":["1000:2000","3000:3000"],"tag":"hy","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"banana"}},"type":"hysteria2"}""",
        "hysteria2://pass@h.example.com:1000-2000,3000-3000?hop_interval_max=20s&bbr_profile=standard&hop_interval=10s&security=tls&sni=sni.example.com&fp=banana#hy",
        """{"protocol_version":"2","server":"h.example.com","server_port":443,"server_ports":"1000:2000,3000:3000","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"banana"}}}""",
    )

    @Test
    fun `clash tls2 edge fields`() {
        assertClashStored(
            """proxies:
  - {name: t, type: tuic, server: t.example.com, port: 443, uuid: u, password: p, 'client-fingerprint': none, sni: sni.example.com}
""",
            """{"password":"p","server":"t.example.com","server_port":443,"tag":"t","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"tuic","uuid":"u"}""",
        )
        assertClashStored(
            """proxies:
  - {name: hu, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, network: ws, 'ws-opts': {path: '/ws?ed=2048', headers: {Host: cdn.example.com}}, 'client-fingerprint': chrome}
""",
            """{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"hu","tls":{"enabled":true,"server_name":"h.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"transport":{"early_data_header_name":"Sec-WebSocket-Protocol","headers":{"Host":"cdn.example.com"},"max_early_data":2048,"path":"/ws","type":"ws"},"type":"vless","uuid":"u"}""",
        )
        assertClashStored(
            """proxies:
  - {name: hp, type: vless, server: h.example.com, port: 443, uuid: u, tls: true, network: ws, 'ws-opts': {'v2ray-http-upgrade': true, path: /hu, headers: {Host: cdn.example.com}}}
""",
            """{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"hp","tls":{"enabled":true,"server_name":"h.example.com"},"transport":{"host":"cdn.example.com","path":"/hu","type":"httpupgrade"},"type":"vless","uuid":"u"}""",
        )
        // A REALITY key turns TLS on even when the entry wrote tls: false.
        assertClashStored(
            """proxies:
  - {name: r, type: vless, server: h.example.com, port: 443, uuid: u, 'reality-opts': {'public-key': abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI, 'short-id': abc}}
""",
            """{"encryption":"none","multiplex":{"enabled":false},"packet_encoding":"","server":"h.example.com","server_port":443,"tag":"r","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHI","short_id":"abc"},"server_name":"h.example.com"},"type":"vless","uuid":"u"}""",
        )
    }

    // --- S5f new-outbound templates: the Go profileNewOutbound literals. ---
    // The Go side pins the same strings in TestProfileNewOutboundTemplates;
    // both harnesses pin the Kotlin model's zero value, so a default change
    // fails on both sides instead of drifting.

    @Test
    fun `blank new-outbound templates match the Go literals`() {
        val templates = mapOf(
            "direct" to """{"type":"direct"}""",
            "http" to """{"type":"http"}""",
            "socks" to """{"type":"socks"}""",
            "shadowsocks" to """{"type":"shadowsocks"}""",
            "vmess" to """{"packet_encoding":"xudp","type":"vmess"}""",
            "vless" to """{"encryption":"none","packet_encoding":"xudp","type":"vless"}""",
            "trojan" to """{"type":"trojan"}""",
            "hysteria" to """{"tls":{},"type":"hysteria"}""",
            // The factory alias resolves to Hysteria, whose blank protocol is v1.
            "hysteria2" to """{"tls":{},"type":"hysteria"}""",
            "tuic" to """{"type":"tuic"}""",
            "juicity" to """{"type":"juicity"}""",
            "trusttunnel" to """{"type":"trusttunnel"}""",
            "anytls" to """{"idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"tls":{},"type":"anytls"}""",
            "snell" to """{"type":"snell","version":4}""",
            "mieru" to """{"transport":"TCP","type":"mieru"}""",
            "shadowtls" to """{"type":"shadowtls","version":1}""",
            "wireguard" to """{"mtu":1420,"type":"wireguard"}""",
            "masque" to """{"mtu":1280,"server_port":443,"tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}""",
            "openvpn" to """{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openvpn"}""",
            "openconnect" to """{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openconnect"}""",
            "ssh" to """{"type":"ssh"}""",
            "naive" to """{"tls":{"enabled":true},"type":"naive"}""",
            "custom" to """{"config":"","name":"","subtype":"","type":"custom"}""",
            "chain" to """{"list":[],"name":"","type":"chain"}""",
            "autoselector" to """{"active_size":8,"balance":false,"balance_interval_sec":30,"balance_mode":"rotate","bench_interval_sec":600,"build_limit":300,"connectivity_url":"","country_filter":"","dial_retries":2,"exclude_unavailable":true,"expected":3,"gid":-1,"gids":[],"history":[],"interrupt_on_switch":true,"interval_sec":300,"last_built":[],"last_built_at":0,"max_rtt_ms":0,"name":"","name_filter":"","pinned_id":-1,"pool":[],"pool_cap":1000,"pool_ranked_at":0,"result_validity_mins":1440,"sampling":10,"test_url":"","tolerance_ms":300,"type":"autoselector","watch_interval_sec":15}""",
            // Alias input, same blank document as openvpn.
            "openvpn-client" to """{"only_advertised_routes":true,"tunnel_dns":"prefer","type":"openvpn"}""",
        )
        assertEquals(25, templates.keys.count { it != "openvpn-client" })
        for ((type, expected) in templates) {
            val outbound = OutboundFactory.newByType(type)
            assertTrue("$type should not be invalid", !outbound.invalid)
            assertEquals("$type template", expected, outbound.exportToJson().toCompact())
        }
    }

    // --- S5f stored normalize: the Go handleProfileNormalizeStored literals. ---
    // TestProfileNormalizeStoredCanonicalForms pins the Go normalizer to these
    // same bytes.

    @Test
    fun `stored normalize cases match the Go literals`() {
        val cases = listOf(
            """{"type":"direct","tag":"D","reuse_addr":true,"connect_timeout":" 5s ","server":"ignored","server_port":1}""" to
                """{"connect_timeout":"5s","reuse_addr":true,"tag":"D","type":"direct"}""",
            """{"type":"http","server":"Example.COM","server_port":8080,"username":"u","password":"p","path":"/x","headers":{"B":"2","A":1},"tls":{"enabled":true,"server_name":"example.com"}}""" to
                """{"headers":{"A":"","B":"2"},"password":"p","path":"/x","server":"Example.COM","server_port":8080,"tls":{"enabled":true,"server_name":"example.com"},"type":"http","username":"u"}""",
            """{"type":"socks","server":"h","server_port":1080,"version":4,"udp_over_tcp":{"enabled":true}}""" to
                """{"server":"h","server_port":1080,"type":"socks","uot":true,"version":"4"}""",
            """{"type":"shadowsocks","server":"Host.example","server_port":8388,"method":"aes-256-gcm","password":"secret","multiplex":{"enabled":false}}""" to
                """{"method":"aes-256-gcm","multiplex":{"enabled":false},"password":"secret","server":"Host.example","server_port":8388,"type":"shadowsocks"}""",
            """{"type":"vless","server":"Vless.Example","server_port":443,"uuid":"u","encryption":"","tls":{"enabled":true,"server_name":"Sni.Example"}}""" to
                """{"encryption":"none","packet_encoding":"xudp","server":"Vless.Example","server_port":443,"tls":{"enabled":true,"server_name":"Sni.Example"},"type":"vless","uuid":"u"}""",
            """{"type":"vmess","server":"h","server_port":443,"uuid":"u","alter-id":4,"global-padding":true}""" to
                """{"alter_id":4,"global_padding":true,"packet_encoding":"xudp","server":"h","server_port":443,"type":"vmess","uuid":"u"}""",
            """{"type":"trojan","server":"h","server_port":443,"password":"p","tls":{"enabled":false}}""" to
                """{"password":"p","server":"h","server_port":443,"type":"trojan"}""",
            """{"tls":{},"type":"hysteria"}""" to
                """{"tls":{},"type":"hysteria"}""",
            """{"type":"hysteria2","server":"h","server_port":443,"password":"p","tls":{"enabled":false}}""" to
                """{"password":"p","server":"h","server_port":443,"tls":{},"type":"hysteria2"}""",
            """{"type":"tuic","server":"h","server_port":443,"uuid":"u","congestion_control":" BBR ","udp_relay_mode":"NATIVE","heartbeat":" 5s ","idle_timeout":"30s"}""" to
                """{"congestion_control":"bbr","heartbeat":"5s","idle_timeout":"30s","server":"h","server_port":443,"type":"tuic","udp_relay_mode":"native","uuid":"u"}""",
            """{"type":"juicity","server":"h","server_port":443,"uuid":"u","password":"p","tls":{"enabled":true}}""" to
                """{"password":"p","server":"h","server_port":443,"tls":{"enabled":true},"type":"juicity","uuid":"u"}""",
            """{"type":"anytls","server":"h","server_port":443,"password":"p"}""" to
                """{"idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"password":"p","server":"h","server_port":443,"tls":{},"type":"anytls"}""",
            """{"type":"shadowtls","server":"h","server_port":443,"version":"3","password":"p","tls":{"enabled":true,"server_name":"s"}}""" to
                """{"password":"p","server":"h","server_port":443,"tls":{"enabled":true,"server_name":"s"},"type":"shadowtls","version":3}""",
            """{"type":"snell","server":"h","server_port":443,"version":6,"psk":"p","mode":"unsafe","obfs_mode":"http"}""" to
                """{"mode":"unsafe","psk":"p","server":"h","server_port":443,"type":"snell","version":6}""",
            """{"type":"mieru","server":"h","server_port":443,"transport":" udp ","server_ports":"9000-9999, 8000","username":"u"}""" to
                """{"server":"h","server_port":443,"server_ports":["9000-9999","8000"],"transport":" udp ","type":"mieru","username":"u"}""",
            """{"type":"trusttunnel","server":"h","server_port":443,"quic":true,"quic_congestion_control":" BBR ","custom_sni":"Sni.Example"}""" to
                """{"custom_sni":"Sni.Example","quic":true,"quic_congestion_control":"bbr","server":"h","server_port":443,"type":"trusttunnel"}""",
            """{"type":"ssh","server":"h","server_port":22,"user":"u","private_key":["line1","line2"],"host_key":[" a ","","b"]}""" to
                """{"host_key":["a","b"],"private_key":"line1\nline2","server":"h","server_port":22,"type":"ssh","user":"u"}""",
            """{"type":"naive","server":"h","server_port":443,"username":"u","extra_headers":{"B":["x"],"A":"y"},"udp_over_tcp":{"enabled":true},"tls":{"enabled":false,"server_name":"S","alpn":["h2"],"fragment":false}}""" to
                """{"extra_headers":{"A":"y","B":"x"},"server":"h","server_port":443,"tls":{"enabled":true,"fragment":false,"server_name":"S"},"type":"naive","udp_over_tcp":true,"username":"u"}""",
            """{"type":"custom","name":" n ","subtype":" outbound ","config":"{}"}""" to
                """{"config":"{}","name":" n ","subtype":"outbound","type":"custom"}""",
            """{"type":"chain","name":"c","list":[3,1.0,"x"]}""" to
                """{"list":[3,1,0],"name":"c","type":"chain"}""",
            """{"type":"vmess","server":"h","server_port":443,"security":"auto","packet_encoding":""}""" to
                """{"packet_encoding":"","server":"h","server_port":443,"type":"vmess"}""",
            """{"type":"vmess","server":"h","server_port":443,"security":"","packet_encoding":"xudp"}""" to
                """{"packet_encoding":"xudp","security":"","server":"h","server_port":443,"type":"vmess"}""",
            """{"type":"hysteria2","server":"h","server_port":443,"obfs":{"type":" GECKO ","password":""},"tls":{"enabled":true}}""" to
                """{"server":"h","server_port":443,"tls":{"enabled":true},"type":"hysteria2"}""",
            """{"type":"hysteria2","server":"h","server_port":443,"obfs":{"type":" GECKO ","password":"p","min_packet_size":512},"tls":{"enabled":true}}""" to
                """{"obfs":{"max_packet_size":0,"min_packet_size":512,"password":"p","type":"gecko"},"server":"h","server_port":443,"tls":{"enabled":true},"type":"hysteria2"}""",
            """{"type":"hysteria","server":"h","server_port":443,"auth":"base64","auth_str":"string","tls":{"enabled":true}}""" to
                """{"auth_str":"string","server":"h","server_port":443,"tls":{"enabled":true},"type":"hysteria"}""",
            """{"type":"naive","server":"h","server_port":443,"tls":{"certificate":["A","","B "]}}""" to
                """{"server":"h","server_port":443,"tls":{"certificate":["A","B "],"enabled":true},"type":"naive"}""",
            """{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"min_version":" 1.2 ","max_version":" 1.3 ","certificate":["-----BEGIN CERTIFICATE-----","","abc","-----END CERTIFICATE-----"],"spoof_method":" word ","fragment_fallback_delay":" 100ms "}}""" to
                """{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,"tls":{"certificate":["-----BEGIN CERTIFICATE-----","abc","-----END CERTIFICATE-----"],"enabled":true,"fragment_fallback_delay":"100ms","max_version":"1.3","min_version":"1.2"},"type":"vless","uuid":"u"}""",
            """{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","tls":{"enabled":true,"ech":{"enabled":true,"config":["ZWNmLWNvbmZpZw"]}}}""" to
                """{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,"tls":{"ech":{"config":["-----BEGIN ECH CONFIGS-----","ZWNmLWNvbmZpZw","-----END ECH CONFIGS-----"],"enabled":true},"enabled":true},"type":"vless","uuid":"u"}""",
            """{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","transport":{"type":"ws","host":"Cdn.Example","path":"/ws"}}""" to
                """{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,"transport":{"headers":{"Host":"Cdn.Example"},"path":"/ws","type":"ws"},"type":"vless","uuid":"u"}""",
            """{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"none","packet_encoding":"xudp","transport":{"type":"ws","path":"/ws?ed=2048"}}""" to
                """{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,"transport":{"early_data_header_name":"Sec-WebSocket-Protocol","max_early_data":2048,"path":"/ws","type":"ws"},"type":"vless","uuid":"u"}""",
            """{"type":"autoselector","name":"a","gids":[5,5,-1],"pool_cap":10,"build_limit":20,"expected":4,"active_size":2}""" to
                """{"active_size":4,"balance":false,"balance_interval_sec":30,"balance_mode":"rotate","bench_interval_sec":600,"build_limit":10,"connectivity_url":"","country_filter":"","dial_retries":2,"exclude_unavailable":true,"expected":4,"gid":5,"gids":[5],"history":[],"interrupt_on_switch":true,"interval_sec":300,"last_built":[],"last_built_at":0,"max_rtt_ms":0,"name":"a","name_filter":"","pinned_id":-1,"pool":[],"pool_cap":10,"pool_ranked_at":0,"result_validity_mins":1440,"sampling":10,"test_url":"","tolerance_ms":300,"type":"autoselector","watch_interval_sec":15}""",
        )
        for ((document, expected) in cases) {
            assertEquals(document, expected, outbound(document).exportToJson().toCompact())
        }
    }
}
