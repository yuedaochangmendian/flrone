package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.ClashYaml
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.outbound.types.Mieru
import io.nekohasekai.sagernet.outbound.types.ShadowTls
import io.nekohasekai.sagernet.outbound.types.Snell
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.ParseDiag
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin oracle pins for the Go mieru/snell/shadowtls slice
 * (buildScript/core-patch/core/mobile/profile_import_newout.go and its export
 * half). Every expected string is the exact bytes the JVM
 * exportToJson/exportToLink/exportIdentity emit for the same input, and the Go
 * unit tests in profile_import_newout_test.go assert the same strings.
 *
 * A vector whose parse emits an import warning is pinned in Go only: the
 * warning path calls vtr(), which needs an Android Application this JVM harness
 * does not start (the same limit the TUIC/AnyTLS pins live with).
 */
class NewOutboundsGoParityTest {
    private val realityKey = "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG"

    private fun outbound(type: String): Outbound = when (type) {
        "mieru" -> Mieru()
        "snell" -> Snell()
        "shadowtls" -> ShadowTls()
        else -> error("unknown type $type")
    }

    private fun assertLinkStored(type: String, link: String, json: String, linkBack: String, identity: String) {
        val ob = outbound(type)
        assertTrue("link should parse: $link", ob.parseFromLink(link))
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(linkBack, ob.exportToLink())
        assertEquals(identity, ob.exportIdentity().toCompact())
    }

    @Test
    fun `mieru link full fields`() = assertLinkStored(
        "mieru",
        "mierus://alice:p%40ss@mieru.example.com?port=9000&protocol=tcp&port=9010-9020&protocol=udp&port=9030&multiplexing=MULTIPLEXING_LOW&traffic-pattern=YWJj&reuse_addr=true&connect_timeout=5s#m1",
        """{"connect_timeout":"5s","multiplexing":"MULTIPLEXING_LOW","password":"p@ss","reuse_addr":true,"server":"mieru.example.com","server_port":9000,"server_ports":["9010-9020","9030-9030"],"tag":"m1","traffic_pattern":"YWJj","transport":"TCP","type":"mieru","username":"alice"}""",
        "mierus://alice:p%40ss@mieru.example.com?profile=default&port=9000&protocol=TCP&port=9010-9020&protocol=TCP&port=9030-9030&protocol=TCP&multiplexing=MULTIPLEXING_LOW&traffic-pattern=YWJj&reuse_addr=true&connect_timeout=5s#m1",
        """{"server":"mieru.example.com","server_port":9000}""",
    )

    @Test
    fun `mieru link gains base64 padding`() = assertLinkStored(
        "mieru",
        "mieru://u:p@h.example.com?port=8080&protocol=udp&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8",
        """{"multiplexing":"MULTIPLEXING_HIGH","password":"p","server":"h.example.com","server_port":8080,"traffic_pattern":"aGVsbG8=","transport":"UDP","type":"mieru","username":"u"}""",
        "mierus://u:p@h.example.com?profile=default&port=8080&protocol=UDP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8%3D",
        """{"server":"h.example.com","server_port":8080}""",
    )

    @Test
    fun `mieru discards the authority port`() = assertLinkStored(
        "mieru",
        "mieru://u:p@mieru.example.com:9999?port=9000",
        """{"password":"p","server":"mieru.example.com","server_port":9000,"transport":"TCP","type":"mieru","username":"u"}""",
        "mierus://u:p@mieru.example.com?profile=default&port=9000&protocol=TCP",
        """{"server":"mieru.example.com","server_port":9000}""",
    )

    @Test
    fun `snell v6 link`() = assertLinkStored(
        "snell",
        "snell://psk%3Avalue@snell.example.com:8443?version=6&userkey=uk&reuse=1&network=udp&mode=unshaped&connect_timeout=5s#s6",
        """{"connect_timeout":"5s","mode":"unshaped","network":"udp","psk":"psk:value","reuse":true,"server":"snell.example.com","server_port":8443,"tag":"s6","type":"snell","userkey":"uk","version":6}""",
        "snell://psk%3Avalue@snell.example.com:8443?version=6&userkey=uk&reuse=1&network=udp&mode=unshaped&connect_timeout=5s#s6",
        """{"server":"snell.example.com","server_port":8443}""",
    )

    @Test
    fun `snell v4 obfs link`() = assertLinkStored(
        "snell",
        "snell://psk@h.example.com:443?version=4&reuse=0&network=tcp&obfs=HTTP&obfs-host=cdn.example.com#s4",
        """{"network":"tcp","obfs_host":"cdn.example.com","obfs_mode":"http","psk":"psk","server":"h.example.com","server_port":443,"tag":"s4","type":"snell","version":4}""",
        "snell://psk@h.example.com:443?version=4&network=tcp&obfs=http&obfs-host=cdn.example.com#s4",
        """{"server":"h.example.com","server_port":443}""",
    )

    @Test
    fun `snell link defaults`() = assertLinkStored(
        "snell",
        "snell://psk@h.example.com:443#s0",
        """{"psk":"psk","server":"h.example.com","server_port":443,"tag":"s0","type":"snell","version":4}""",
        "snell://psk@h.example.com:443?version=4#s0",
        """{"server":"h.example.com","server_port":443}""",
    )

    @Test
    fun `shadowtls link full fields`() = assertLinkStored(
        "shadowtls",
        "shadowtls://:pass@st.example.com:443?version=3&sni=sni.example.com&alpn=h2%2Chttp%2F1.1&allowInsecure=1&fp=chrome&connect_timeout=5s#st",
        """{"connect_timeout":"5s","password":"pass","server":"st.example.com","server_port":443,"tag":"st","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"shadowtls","version":3}""",
        "shadowtls://:pass@st.example.com:443?version=3&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&fp=chrome&connect_timeout=5s#st",
        """{"server":"st.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}},"version":3}""",
    )

    @Test
    fun `shadowtls v1 default port`() = assertLinkStored(
        "shadowtls",
        "shadowtls://st.example.com?version=1#st1",
        """{"server":"st.example.com","server_port":443,"tag":"st1","tls":{"enabled":true},"type":"shadowtls","version":1}""",
        "shadowtls://st.example.com:443?version=1&security=tls#st1",
        """{"server":"st.example.com","server_port":443,"tls":{"enabled":true},"version":1}""",
    )

    @Test
    fun `shadowtls reality link`() = assertLinkStored(
        "shadowtls",
        "shadowtls://:pw@st.example.com:443?version=3&pbk=$realityKey&sid=ab&sni=sni.example.com&security=reality#sr",
        """{"password":"pw","server":"st.example.com","server_port":443,"tag":"sr","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"$realityKey","short_id":"ab"},"server_name":"sni.example.com"},"type":"shadowtls","version":3}""",
        "shadowtls://:pw@st.example.com:443?version=3&security=reality&sni=sni.example.com&pbk=$realityKey&sid=ab#sr",
        """{"server":"st.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"$realityKey","short_id":"ab"},"server_name":"sni.example.com"},"version":3}""",
    )

    private fun assertClashStored(type: String, yaml: String, json: String) {
        val entry = ClashYaml.proxies(yaml)?.single() ?: error("document has no proxies: $yaml")
        val ob = outbound(type)
        assertTrue("Clash entry should parse", ob.parseFromClash(entry))
        assertEquals(json, ob.exportToJson().toCompact())
    }

    @Test
    fun `clash snell v4`() = assertClashStored(
        "snell",
        """proxies:
  - {name: sn, type: snell, server: snell.example.com, port: 443, psk: secret, version: 4, 'obfs-opts': {mode: HTTP, host: cdn.example.com}}
""",
        """{"network":"tcp","obfs_host":"cdn.example.com","obfs_mode":"http","psk":"secret","server":"snell.example.com","server_port":443,"tag":"sn","type":"snell","version":4}""",
    )

    @Test
    fun `clash snell v6 udp`() = assertClashStored(
        "snell",
        """proxies:
  - {name: snu, type: snell, server: snell.example.com, port: 443, psk: secret, version: 6, udp: true, 'obfs-opts': {mode: tls}}
""",
        """{"psk":"secret","server":"snell.example.com","server_port":443,"tag":"snu","type":"snell","version":6}""",
    )

    private fun assertStoredImport(type: String, doc: String, json: String, linkBack: String) {
        val ob = outbound(type)
        val issues = ArrayList<Issue>()
        val ok = ParseDiag.scoped(issues) { ob.parseFromJson(JsonInput.parseObject(doc)) }
        assertTrue("stored JSON should parse (issues: $issues)", ok)
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(linkBack, ob.exportToLink())
    }

    @Test
    fun `import stored mieru`() = assertStoredImport(
        "mieru",
        """{"type":"mieru","tag":"mj","server":"mieru.example.com","server_port":8080,"transport":" tcp","username":"u","password":"p","multiplexing":"MULTIPLEXING_HIGH","traffic_pattern":"aGVsbG8","server_ports":"9000-9010, 9020-9030","reuse_addr":true,"connect_timeout":"5s"}""",
        """{"connect_timeout":"5s","multiplexing":"MULTIPLEXING_HIGH","password":"p","reuse_addr":true,"server":"mieru.example.com","server_port":8080,"server_ports":["9000-9010","9020-9030"],"tag":"mj","traffic_pattern":"aGVsbG8=","transport":"TCP","type":"mieru","username":"u"}""",
        "mierus://u:p@mieru.example.com?profile=default&port=8080&protocol=TCP&port=9000-9010&protocol=TCP&port=9020-9030&protocol=TCP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8%3D&reuse_addr=true&connect_timeout=5s#mj",
    )

    @Test
    fun `import stored mieru server ports only`() = assertStoredImport(
        "mieru",
        """{"type":"mieru","server":"h.example.com","server_port":0,"username":"u","password":"p","server_ports":["9000-9010"]}""",
        """{"password":"p","server":"h.example.com","server_ports":["9000-9010"],"transport":"TCP","type":"mieru","username":"u"}""",
        "mierus://u:p@h.example.com?profile=default&port=9000-9010&protocol=TCP",
    )

    @Test
    fun `import stored snell v6`() = assertStoredImport(
        "snell",
        """{"type":"snell","tag":"sj","server":"snell.example.com","server_port":443,"version":6,"psk":"secret","userkey":"uk","reuse":true,"network":["tcp","udp"],"mode":" unshaped ","obfs_mode":"http","obfs_host":"x"}""",
        """{"mode":"unshaped","psk":"secret","reuse":true,"server":"snell.example.com","server_port":443,"tag":"sj","type":"snell","userkey":"uk","version":6}""",
        "snell://secret@snell.example.com:443?version=6&userkey=uk&reuse=1&mode=unshaped#sj",
    )

    @Test
    fun `import stored snell v4 network case`() = assertStoredImport(
        "snell",
        """{"type":"snell","server":"snell.example.com","server_port":443,"psk":"secret","network":"TCP","obfs_mode":"TLS","obfs_host":"cdn.example.com"}""",
        """{"network":"tcp","obfs_host":"cdn.example.com","obfs_mode":"tls","psk":"secret","server":"snell.example.com","server_port":443,"type":"snell","version":4}""",
        "snell://secret@snell.example.com:443?version=4&network=tcp&obfs=tls&obfs-host=cdn.example.com",
    )

    @Test
    fun `import stored shadowtls version and alpn`() = assertStoredImport(
        "shadowtls",
        """{"type":"shadowtls","tag":"sj","server":"st.example.com","server_port":8443,"version":"2","password":"pw","tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"," http/1.1 "]}}""",
        """{"password":"pw","server":"st.example.com","server_port":8443,"tag":"sj","tls":{"alpn":["h2","http/1.1"],"enabled":true,"server_name":"sni.example.com"},"type":"shadowtls","version":2}""",
        "shadowtls://:pw@st.example.com:8443?version=2&security=tls&sni=sni.example.com&alpn=h2,http/1.1#sj",
    )

    @Test
    fun `import stored shadowtls reality`() = assertStoredImport(
        "shadowtls",
        """{"type":"shadowtls","server":"st.example.com","server_port":443,"version":3,"password":"pw","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"$realityKey","short_id":" ab "}}}""",
        """{"password":"pw","server":"st.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"$realityKey","short_id":"ab"}},"type":"shadowtls","version":3}""",
        "shadowtls://:pw@st.example.com:443?version=3&security=reality&pbk=$realityKey&sid=ab",
    )

    @Test
    fun `import stored shadowtls versions`() = assertStoredImport(
        "shadowtls",
        """{"type":"shadowtls","server":"st.example.com","server_port":443,"version":1,"tls":{"enabled":true,"min_version":"1.2","max_version":"1.3"}}""",
        """{"server":"st.example.com","server_port":443,"tls":{"enabled":true,"max_version":"1.3","min_version":"1.2"},"type":"shadowtls","version":1}""",
        "shadowtls://st.example.com:443?version=1&security=tls&tls_min_version=1.2&tls_max_version=1.3",
    )

    private fun assertExport(doc: String, type: String, json: String, link: String, identity: String) {
        val ob = OutboundFactory.fromJson(JsonInput.parseObject(doc)) ?: error("document did not parse: $doc")
        assertEquals(type, ob.type)
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(link, ob.exportToLink())
        assertEquals(identity, ob.exportIdentity().toCompact())
    }

    @Test
    fun `export stored mieru`() = assertExport(
        """{"type":"mieru","tag":"me","server":"mieru.example.com","server_port":8080,"transport":"UDP","username":"u","password":"p","multiplexing":"MULTIPLEXING_HIGH","traffic_pattern":"aGVsbG8=","server_ports":["9000-9010"],"reuse_addr":true}""",
        "mieru",
        """{"multiplexing":"MULTIPLEXING_HIGH","password":"p","reuse_addr":true,"server":"mieru.example.com","server_port":8080,"server_ports":["9000-9010"],"tag":"me","traffic_pattern":"aGVsbG8=","transport":"UDP","type":"mieru","username":"u"}""",
        "mierus://u:p@mieru.example.com?profile=default&port=8080&protocol=UDP&port=9000-9010&protocol=UDP&multiplexing=MULTIPLEXING_HIGH&traffic-pattern=aGVsbG8%3D&reuse_addr=true#me",
        """{"server":"mieru.example.com","server_port":8080}""",
    )

    @Test
    fun `export stored snell`() = assertExport(
        """{"type":"snell","tag":"se","server":"s.example.com","server_port":443,"version":6,"psk":"secret","network":"udp","mode":"unshaped","reuse":true,"userkey":"uk"}""",
        "snell",
        """{"mode":"unshaped","network":"udp","psk":"secret","reuse":true,"server":"s.example.com","server_port":443,"tag":"se","type":"snell","userkey":"uk","version":6}""",
        "snell://secret@s.example.com:443?version=6&userkey=uk&reuse=1&network=udp&mode=unshaped#se",
        """{"server":"s.example.com","server_port":443}""",
    )

    @Test
    fun `export stored shadowtls`() = assertExport(
        """{"type":"shadowtls","tag":"sh","server":"s.example.com","server_port":443,"version":3,"password":"pw","tls":{"enabled":true,"server_name":"sni.example.com","insecure":true,"alpn":["h2"]}}""",
        "shadowtls",
        """{"password":"pw","server":"s.example.com","server_port":443,"tag":"sh","tls":{"alpn":["h2"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"shadowtls","version":3}""",
        "shadowtls://:pw@s.example.com:443?version=3&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2#sh",
        """{"server":"s.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"},"version":3}""",
    )

    @Test
    fun `export stored shadowtls with TLS off`() = assertExport(
        """{"type":"shadowtls","server":"s.example.com","server_port":443,"version":1,"tls":{"enabled":false,"server_name":"sni.example.com"}}""",
        "shadowtls",
        """{"server":"s.example.com","server_port":443,"type":"shadowtls","version":1}""",
        "shadowtls://s.example.com:443?version=1",
        """{"server":"s.example.com","server_port":443,"version":1}""",
    )
}