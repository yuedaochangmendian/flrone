package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.link.Hosts
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
}