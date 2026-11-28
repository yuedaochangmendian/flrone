package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.link.Hosts
import io.nekohasekai.sagernet.outbound.types.Hysteria
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

}