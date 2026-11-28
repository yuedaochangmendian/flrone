package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.types.Juicity
import io.nekohasekai.sagernet.outbound.types.Naive
import io.nekohasekai.sagernet.outbound.types.Ssh
import io.nekohasekai.sagernet.outbound.types.TrustTunnel
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.ParseDiag
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin oracle pins for the Go juicity/naive/ssh/trusttunnel slice
 * (buildScript/core-patch/core/mobile/profile_import_juicity.go and its export
 * and validation halves). Every expected string is the exact bytes the JVM
 * exportToJson/exportToLink/exportIdentity emit for the same input, and the Go
 * unit tests in profile_import_juicity_test.go assert the same strings.
 *
 * A vector whose parse emits an import warning is pinned in Go only: the
 * warning path calls vtr(), which needs an Android Application this JVM harness
 * does not start (the same limit the other slices live with).
 */
class S5JuicityGoParityTest {
    private val uuid = "8b7e6b1a-3c4d-4e5f-9a0b-1c2d3e4f5a6b"
    private val cert = "-----BEGIN CERTIFICATE-----,MIIBAA==,-----END CERTIFICATE-----"
    private val certEncoded = "-----BEGIN%20CERTIFICATE-----,MIIBAA%3D%3D,-----END%20CERTIFICATE-----"
    private val privateKey = "-----BEGIN OPENSSH PRIVATE KEY-----\nMIIBAA==\n-----END OPENSSH PRIVATE KEY-----"
    /** The same text as a JSON string body: backslash-n, not a raw newline. */
    private val privateKeyJSON = """-----BEGIN OPENSSH PRIVATE KEY-----\nMIIBAA==\n-----END OPENSSH PRIVATE KEY-----"""
    private val privateKeyB64 = "LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KTUlJQkFBPT0KLS0tLS1FTkQgT1BFTlNTSCBQUklWQVRFIEtFWS0tLS0t"
    private val hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAA0FBQQ=="
    private val hostKeyB64 = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBQTBGQlFRPT0"

    private fun outbound(type: String): Outbound = when (type) {
        "juicity" -> Juicity()
        "naive" -> Naive()
        "ssh" -> Ssh()
        "trusttunnel" -> TrustTunnel()
        else -> error("unknown type $type")
    }

    private fun assertLinkStored(type: String, link: String, json: String, linkBack: String, identity: String) {
        val ob = outbound(type)
        val issues = ArrayList<Issue>()
        val ok = ParseDiag.scoped(issues) { ob.parseFromLink(link) }
        assertTrue("link should parse: $link ($issues)", ok)
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(linkBack, ob.exportToLink())
        assertEquals(identity, ob.exportIdentity().toCompact())
    }

    @Test
    fun `juicity link full fields`() = assertLinkStored(
        "juicity",
        "juicity://$uuid:p%40ss@juicity.example.com:8443?sni=sni.example.com&alpn=h2%2Chttp%2F1.1&allowInsecure=1&fp=chrome&connect_timeout=5s#j1",
        """{"connect_timeout":"5s","password":"p@ss","server":"juicity.example.com","server_port":8443,"tag":"j1","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"juicity","uuid":"$uuid"}""",
        "juicity://$uuid:p%40ss@juicity.example.com:8443?security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&fp=chrome&connect_timeout=5s#j1",
        """{"server":"juicity.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
    )

    @Test
    fun `juicity link default port`() = assertLinkStored(
        "juicity",
        "juicity://$uuid@h.example.com#j0",
        """{"server":"h.example.com","server_port":443,"tag":"j0","tls":{"enabled":true},"type":"juicity","uuid":"$uuid"}""",
        "juicity://$uuid@h.example.com:443?security=tls#j0",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true}}""",
    )

    @Test
    fun `juicity link reality`() = assertLinkStored(
        "juicity",
        "juicity://$uuid:pw@h.example.com:443?pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=ab&sni=sni.example.com&security=reality#jr",
        """{"password":"pw","server":"h.example.com","server_port":443,"tag":"jr","tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"ab"},"server_name":"sni.example.com"},"type":"juicity","uuid":"$uuid"}""",
        "juicity://$uuid:pw@h.example.com:443?security=reality&sni=sni.example.com&pbk=abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG&sid=ab#jr",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"reality":{"enabled":true,"public_key":"abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG","short_id":"ab"},"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `naive https link full fields`() = assertLinkStored(
        "naive",
        "naive+https://alice:p%40ss@naive.example.com:8443?sni=sni.example.com&extra-headers=A%3A%201%0D%0AB%3A%202&insecure-concurrency=2&uot=1&tls_fragment=true&tls_certificate=$certEncoded#n1",
        """{"extra_headers":{"A":"1","B":"2"},"insecure_concurrency":2,"password":"p@ss","server":"naive.example.com","server_port":8443,"tag":"n1","tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIBAA==","-----END CERTIFICATE-----"],"enabled":true,"fragment":true,"server_name":"sni.example.com"},"type":"naive","udp_over_tcp":true,"username":"alice"}""",
        "naive+https://alice:p%40ss@naive.example.com:8443?sni=sni.example.com&extra-headers=A%3A1%0D%0AB%3A2&insecure-concurrency=2&uot=1&tls_certificate=$certEncoded&tls_fragment=true#n1",
        """{"server":"naive.example.com","server_port":8443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `naive quic link`() = assertLinkStored(
        "naive",
        "naive+quic://u:p@h.example.com?congestion_control=bbr2&uot=true#nq",
        """{"password":"p","quic":true,"quic_congestion_control":"bbr2","server":"h.example.com","server_port":443,"tag":"nq","tls":{"enabled":true},"type":"naive","udp_over_tcp":true,"username":"u"}""",
        "naive+quic://u:p@h.example.com:443?uot=1&congestion_control=bbr2#nq",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true}}""",
    )

    @Test
    fun `naive https link defaults`() = assertLinkStored(
        "naive",
        "naive+https://h.example.com:443#nd",
        """{"server":"h.example.com","server_port":443,"tag":"nd","tls":{"enabled":true},"type":"naive"}""",
        "naive+https://h.example.com:443#nd",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true}}""",
    )

    @Test
    fun `ssh link full fields`() = assertLinkStored(
        "ssh",
        "ssh://h.example.com:2222?user=u&password=p&private_key=$privateKeyB64&host_key=$hostKeyB64&host_key_algorithms=c3NoLWVkMjU1MTk&client_version=SSH-2.0-OpenSSH_9.0#s1",
        """{"client_version":"SSH-2.0-OpenSSH_9.0","host_key":["$hostKey"],"host_key_algorithms":["ssh-ed25519"],"password":"p","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nMIIBAA==\n-----END OPENSSH PRIVATE KEY-----","server":"h.example.com","server_port":2222,"tag":"s1","type":"ssh","user":"u"}""",
        "ssh://h.example.com:2222?user=u&password=p&private_key=$privateKeyB64&host_key=$hostKeyB64&host_key_algorithms=c3NoLWVkMjU1MTk&client_version=SSH-2.0-OpenSSH_9.0#s1",
        """{"server":"h.example.com","server_port":2222}""",
    )

    @Test
    fun `ssh link default port`() = assertLinkStored(
        "ssh",
        "ssh://h.example.com#s0",
        """{"server":"h.example.com","tag":"s0","type":"ssh"}""",
        "ssh://h.example.com:0#s0",
        """{"server":"h.example.com","server_port":0}""",
    )

    @Test
    fun `trusttunnel link full fields`() = assertLinkStored(
        "trusttunnel",
        "tt://user:pass@tt.example.com:443?health_check=true&congestion_control=cubic&custom_sni=sni.example.com&client_random=abcdef/ffffff&connect_timeout=5s#t1",
        """{"client_random":"abcdef/ffffff","connect_timeout":"5s","custom_sni":"sni.example.com","health_check":true,"password":"pass","quic":true,"quic_congestion_control":"cubic","server":"tt.example.com","server_port":443,"tag":"t1","tls":{"enabled":true},"type":"trusttunnel","username":"user"}""",
        "tt://user:pass@tt.example.com:443?health_check=true&congestion_control=cubic&custom_sni=sni.example.com&client_random=abcdef/ffffff&security=tls&connect_timeout=5s#t1",
        """{"server":"tt.example.com","server_port":443,"tls":{"enabled":true}}""",
    )

    @Test
    fun `trusttunnel link defaults`() = assertLinkStored(
        "trusttunnel",
        "tt://user:pass@tt.example.com#t0",
        """{"password":"pass","server":"tt.example.com","server_port":443,"tag":"t0","tls":{"enabled":true},"type":"trusttunnel","username":"user"}""",
        "tt://user:pass@tt.example.com:443?security=tls#t0",
        """{"server":"tt.example.com","server_port":443,"tls":{"enabled":true}}""",
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
    fun `import stored juicity`() = assertStoredImport(
        "juicity",
        """{"type":"juicity","tag":"jj","server":"juicity.example.com","server_port":8443,"uuid":"$uuid","password":"pw","tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"," http/1.1 "],"insecure":true,"utls":{"enabled":true,"fingerprint":"chrome"},"fragment":false}}""",
        """{"password":"pw","server":"juicity.example.com","server_port":8443,"tag":"jj","tls":{"alpn":["h2","http/1.1"],"enabled":true,"fragment":false,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"juicity","uuid":"$uuid"}""",
        "juicity://$uuid:pw@juicity.example.com:8443?security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&tls_fragment=false&fp=chrome#jj",
    )

    @Test
    fun `import stored naive`() = assertStoredImport(
        "naive",
        """{"type":"naive","tag":"nj","server":"naive.example.com","server_port":8443,"username":"u","password":"p","insecure_concurrency":3,"extra_headers":{"B":["x","y"],"A":"z"},"udp_over_tcp":{"enabled":true},"quic":true,"quic_congestion_control":"cubic","tls":{"enabled":false,"server_name":"Sni.Example","alpn":["h2"],"certificate":["-----BEGIN CERTIFICATE-----","","MIIBAA==","-----END CERTIFICATE-----"],"fragment":false,"insecure":true}}""",
        """{"extra_headers":{"A":"z","B":"x"},"insecure_concurrency":3,"password":"p","quic":true,"quic_congestion_control":"cubic","server":"naive.example.com","server_port":8443,"tag":"nj","tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIBAA==","-----END CERTIFICATE-----"],"enabled":true,"fragment":false,"server_name":"Sni.Example"},"type":"naive","udp_over_tcp":true,"username":"u"}""",
        "naive+quic://u:p@naive.example.com:8443?sni=Sni.Example&extra-headers=A%3Az%0D%0AB%3Ax&insecure-concurrency=3&uot=1&congestion_control=cubic&tls_certificate=$certEncoded&tls_fragment=false#nj",
    )

    @Test
    fun `import stored ssh`() = assertStoredImport(
        "ssh",
        """{"type":"ssh","tag":"sj","server":"ssh.example.com","server_port":2222,"user":"u","password":"p","private_key":["-----BEGIN OPENSSH PRIVATE KEY-----","MIIBAA==","-----END OPENSSH PRIVATE KEY-----"],"host_key":["$hostKey"],"host_key_algorithms":["ssh-ed25519"],"client_version":"SSH-2.0-X"}""",
        """{"client_version":"SSH-2.0-X","host_key":["$hostKey"],"host_key_algorithms":["ssh-ed25519"],"password":"p","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nMIIBAA==\n-----END OPENSSH PRIVATE KEY-----","server":"ssh.example.com","server_port":2222,"tag":"sj","type":"ssh","user":"u"}""",
        "ssh://ssh.example.com:2222?user=u&password=p&private_key=$privateKeyB64&host_key=$hostKeyB64&host_key_algorithms=c3NoLWVkMjU1MTk&client_version=SSH-2.0-X#sj",
    )

    @Test
    fun `import stored trusttunnel`() = assertStoredImport(
        "trusttunnel",
        """{"type":"trusttunnel","tag":"tj","server":"tt.example.com","server_port":443,"username":"u","password":"p","health_check":true,"quic":true,"quic_congestion_control":" CUBIC ","custom_sni":"Sni.Example","client_random":"ab/ff","tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        """{"client_random":"ab/ff","custom_sni":"Sni.Example","health_check":true,"password":"p","quic":true,"quic_congestion_control":"cubic","server":"tt.example.com","server_port":443,"tag":"tj","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"trusttunnel","username":"u"}""",
        "tt://u:p@tt.example.com:443?health_check=true&congestion_control=cubic&custom_sni=Sni.Example&client_random=ab/ff&security=tls&sni=sni.example.com#tj",
    )

    private fun assertExport(doc: String, type: String, json: String, link: String, identity: String) {
        val ob = OutboundFactory.fromJson(JsonInput.parseObject(doc)) ?: error("document did not parse: $doc")
        assertEquals(type, ob.type)
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(link, ob.exportToLink())
        assertEquals(identity, ob.exportIdentity().toCompact())
    }

    @Test
    fun `export stored juicity`() = assertExport(
        """{"type":"juicity","tag":"je","server":"h.example.com","server_port":443,"uuid":"$uuid","password":"p","tls":{"enabled":true,"server_name":"sni.example.com","insecure":true,"alpn":["h2"]}}""",
        "juicity",
        """{"password":"p","server":"h.example.com","server_port":443,"tag":"je","tls":{"alpn":["h2"],"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"juicity","uuid":"$uuid"}""",
        "juicity://$uuid:p@h.example.com:443?security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2#je",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `export blank juicity`() = assertExport(
        """{"type":"juicity"}""",
        "juicity",
        """{"type":"juicity"}""",
        "juicity://:0",
        """{"type":"juicity"}""",
    )

    @Test
    fun `export stored naive`() = assertExport(
        """{"type":"naive","tag":"ne","server":"h.example.com","server_port":443,"username":"u","password":"p","extra_headers":{"B":"2","A":"1"},"insecure_concurrency":2,"udp_over_tcp":true,"quic":true,"quic_congestion_control":"bbr2","tls":{"enabled":true,"server_name":"sni.example.com","certificate":["-----BEGIN CERTIFICATE-----","MIIBAA==","-----END CERTIFICATE-----"],"certificate_path":"/p","fragment":true}}""",
        "naive",
        """{"extra_headers":{"A":"1","B":"2"},"insecure_concurrency":2,"password":"p","quic":true,"quic_congestion_control":"bbr2","server":"h.example.com","server_port":443,"tag":"ne","tls":{"certificate":["-----BEGIN CERTIFICATE-----","MIIBAA==","-----END CERTIFICATE-----"],"certificate_path":"/p","enabled":true,"fragment":true,"server_name":"sni.example.com"},"type":"naive","udp_over_tcp":true,"username":"u"}""",
        "naive+quic://u:p@h.example.com:443?sni=sni.example.com&extra-headers=A%3A1%0D%0AB%3A2&insecure-concurrency=2&uot=1&congestion_control=bbr2&tls_certificate=$certEncoded&tls_certificate_path=/p&tls_fragment=true#ne",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `export blank naive`() = assertExport(
        """{"type":"naive"}""",
        "naive",
        """{"tls":{"enabled":true},"type":"naive"}""",
        "naive+https://",
        """{"tls":{"enabled":true},"type":"naive"}""",
    )

    @Test
    fun `export stored ssh`() = assertExport(
        """{"type":"ssh","tag":"se","server":"h.example.com","server_port":2222,"user":"u","password":"p","private_key":"$privateKeyJSON","private_key_path":"/k","private_key_passphrase":"pp","host_key":["$hostKey","$hostKey"],"host_key_algorithms":["c"],"client_version":"SSH-2.0-X"}""",
        "ssh",
        """{"client_version":"SSH-2.0-X","host_key":["$hostKey","$hostKey"],"host_key_algorithms":["c"],"password":"p","private_key":"-----BEGIN OPENSSH PRIVATE KEY-----\nMIIBAA==\n-----END OPENSSH PRIVATE KEY-----","private_key_passphrase":"pp","private_key_path":"/k","server":"h.example.com","server_port":2222,"tag":"se","type":"ssh","user":"u"}""",
        "ssh://h.example.com:2222?user=u&password=p&private_key=$privateKeyB64&private_key_path=/k&private_key_passphrase=pp&host_key=$hostKeyB64-$hostKeyB64&host_key_algorithms=Yw&client_version=SSH-2.0-X#se",
        """{"server":"h.example.com","server_port":2222}""",
    )

    @Test
    fun `export blank ssh`() = assertExport(
        """{"type":"ssh"}""",
        "ssh",
        """{"type":"ssh"}""",
        "ssh://:0",
        """{"type":"ssh"}""",
    )

    @Test
    fun `export stored trusttunnel`() = assertExport(
        """{"type":"trusttunnel","tag":"te","server":"h.example.com","server_port":443,"username":"u","password":"p","health_check":true,"quic":true,"quic_congestion_control":"cubic","custom_sni":"Sni.Example","client_random":"ab/ff","tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        "trusttunnel",
        """{"client_random":"ab/ff","custom_sni":"Sni.Example","health_check":true,"password":"p","quic":true,"quic_congestion_control":"cubic","server":"h.example.com","server_port":443,"tag":"te","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"trusttunnel","username":"u"}""",
        "tt://u:p@h.example.com:443?health_check=true&congestion_control=cubic&custom_sni=Sni.Example&client_random=ab/ff&security=tls&sni=sni.example.com#te",
        """{"server":"h.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `export blank trusttunnel`() = assertExport(
        """{"type":"trusttunnel"}""",
        "trusttunnel",
        """{"type":"trusttunnel"}""",
        "tt://:0",
        """{"type":"trusttunnel"}""",
    )

    @Test
    fun `stored normalize cases match the Go literals`() {
        val cases = listOf(
            """{"type":"juicity","tag":"nj","server":"h","server_port":443,"uuid":"$uuid","password":"p","tls":{"enabled":true,"server_name":"sni.example.com"}}""" to
                """{"password":"p","server":"h","server_port":443,"tag":"nj","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"juicity","uuid":"$uuid"}""",
            """{"type":"naive","tag":"n","server":"h","server_port":443,"quic":true,"quic_congestion_control":"cubic","tls":{"enabled":true}}""" to
                """{"quic":true,"quic_congestion_control":"cubic","server":"h","server_port":443,"tag":"n","tls":{"enabled":true},"type":"naive"}""",
            """{"type":"ssh","tag":"s","server":"h","server_port":22,"user":"u","private_key":["a","b"],"host_key":[" a ",""]}""" to
                """{"host_key":["a"],"private_key":"a\nb","server":"h","server_port":22,"tag":"s","type":"ssh","user":"u"}""",
            """{"type":"trusttunnel","tag":"t","server":"h","server_port":443,"username":"u","password":"p","quic":true,"quic_congestion_control":" BBR ","custom_sni":"Sni.Example"}""" to
                """{"custom_sni":"Sni.Example","password":"p","quic":true,"quic_congestion_control":"bbr","server":"h","server_port":443,"tag":"t","type":"trusttunnel","username":"u"}""",
        )
        for ((document, expected) in cases) {
            assertEquals(document, expected, OutboundFactory.fromJson(JsonInput.parseObject(document))!!.exportToJson().toCompact())
        }
    }
}