package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.ClashYaml
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.types.Masque
import io.nekohasekai.sagernet.outbound.types.WireGuard
import io.nekohasekai.sagernet.validation.Issue
import io.nekohasekai.sagernet.validation.ParseDiag
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin oracle pins for the Go WireGuard/MASQUE slice
 * (buildScript/core-patch/core/mobile/profile_import_wg_masque.go and its
 * export/validate halves). Every expected string is the exact bytes the JVM
 * exportToJson/exportToLink/exportIdentity emit for the same input, and the Go
 * unit tests in profile_import_wg_masque_test.go assert the same strings.
 *
 * A vector whose parse emits an import warning (an invalid reserved list, an
 * out-of-range Amnezia value that does not refuse the profile) is pinned in Go
 * only: the warning path calls vtr(), which needs an Android Application this
 * JVM harness does not start (the same limit the TUIC/AnyTLS pins live with).
 */
class WgMasqueGoParityTest {
    private val privateKey = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    private val publicKey = "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
    private val psk = "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC="

    private fun outbound(type: String): Outbound = when (type) {
        "wireguard" -> WireGuard()
        "masque" -> Masque()
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
    fun `wireguard link full fields`() = assertLinkStored(
        "wireguard",
        "wg://$privateKey@wg.example.com?public_key=$publicKey&pre_shared_key=$psk&reserved=1-2-3&persistent_keepalive_interval=25&local_address=10.0.0.2,fd00::2&mtu=1280&workers=2&udp_timeout=30s&use_system_interface=true&enable_amnezia=true&jc=4&jmin=40&jmax=70&s1=30&s2=40&h1=1&h2=2&h3=3&h4=4&i1=%3Cb%200x1234%3E#w1",
        """{"address":["10.0.0.2/32","fd00::2/128"],"amnezia_wg":{"h1":"1","h2":"2","h3":"3","h4":"4","i1":"<b 0x1234>","jc":4,"jmax":70,"jmin":40,"s1":30,"s2":40},"mtu":1280,"peers":[{"address":"wg.example.com","persistent_keepalive_interval":25,"port":51820,"pre_shared_key":"$psk","public_key":"$publicKey","reserved":[1,2,3]}],"private_key":"$privateKey","system":true,"tag":"w1","type":"wireguard","udp_timeout":"30s","worker_count":2}""",
        "wg://wg.example.com:51820?private_key=${privateKey.replace("=", "%3D")}&local_address=10.0.0.2/32-fd00::2/128&mtu=1280&use_system_interface=true&workers=2&udp_timeout=30s&enable_amnezia=true&jc=4&jmin=40&jmax=70&s1=30&s2=40&h1=1&h2=2&h3=3&h4=4&i1=%3Cb%200x1234%3E&public_key=${publicKey.replace("=", "%3D")}&pre_shared_key=${psk.replace("=", "%3D")}&reserved=1-2-3&persistent_keepalive_interval=25#w1",
        """{"server":"wg.example.com","server_port":51820}""",
    )

    @Test
    fun `wireguard link defaults`() = assertLinkStored(
        "wireguard",
        "wg://h.example.com?private_key=$privateKey&public_key=$publicKey#n",
        """{"mtu":1420,"peers":[{"address":"h.example.com","port":51820,"public_key":"$publicKey"}],"private_key":"$privateKey","tag":"n","type":"wireguard"}""",
        "wg://h.example.com:51820?private_key=${privateKey.replace("=", "%3D")}&public_key=${publicKey.replace("=", "%3D")}#n",
        """{"server":"h.example.com","server_port":51820}""",
    )

    private fun assertStoredImport(type: String, doc: String, json: String, linkBack: String, identity: String) {
        val ob = outbound(type)
        val issues = ArrayList<Issue>()
        val ok = ParseDiag.scoped(issues) { ob.parseFromJson(JsonInput.parseObject(doc)) }
        assertTrue("stored JSON should parse (issues: $issues)", ok)
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(linkBack, ob.exportToLink())
        assertEquals(identity, ob.exportIdentity().toCompact())
    }

    @Test
    fun `import stored wireguard decodes a base64 reserved string`() = assertStoredImport(
        "wireguard",
        """{"type":"wireguard","tag":"wj","server":"ignored.example.com","server_port":444,"private_key":"$privateKey","peers":[{"address":"peer.example.com","port":51820,"public_key":"$publicKey","pre_shared_key":"$psk","reserved":"AQID","persistent_keepalive_interval":"22-30"}],"address":"10.1.0.2","mtu":1300,"system":true,"worker_count":2,"udp_timeout":" 15s "}""",
        """{"address":["10.1.0.2/32"],"mtu":1300,"peers":[{"address":"peer.example.com","persistent_keepalive_interval":"22-30","port":51820,"pre_shared_key":"$psk","public_key":"$publicKey","reserved":[1,2,3]}],"private_key":"$privateKey","system":true,"tag":"wj","type":"wireguard","udp_timeout":"15s","worker_count":2}""",
        "wg://peer.example.com:51820?private_key=${privateKey.replace("=", "%3D")}&local_address=10.1.0.2/32&mtu=1300&use_system_interface=true&workers=2&udp_timeout=15s&public_key=${publicKey.replace("=", "%3D")}&pre_shared_key=${psk.replace("=", "%3D")}&reserved=1-2-3&persistent_keepalive_interval=22-30#wj",
        """{"server":"ignored.example.com","server_port":444}""",
    )

    private fun assertClashStored(type: String, yaml: String, json: String, identity: String) {
        val entry = ClashYaml.proxies(yaml)?.single() ?: error("document has no proxies: $yaml")
        val ob = outbound(type)
        assertTrue("Clash entry should parse", ob.parseFromClash(entry))
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals("", ob.exportToLink())
        assertEquals(identity, ob.exportIdentity().toCompact())
    }

    @Test
    fun `clash masque h2`() = assertClashStored(
        "masque",
        """proxies:
  - {name: m1, type: masque, server: consumer.example.com, port: 443, 'private-key': $privateKey, 'public-key': $publicKey, ip: 172.16.0.2, ipv6: 'fd00::2', mtu: 1280, sni: sni.example.com, skip-cert-verify: true, network: h2}
""",
        """{"address":["172.16.0.2/32","fd00::2/128"],"http_version":2,"mtu":1280,"peer_public_key":"$publicKey","private_key":"$privateKey","server":"consumer.example.com","server_port":443,"tag":"m1","tls":{"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"masque"}""",
        """{"private_key":"$privateKey","server":"consumer.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `clash masque h3 default port and sni`() = assertClashStored(
        "masque",
        """proxies:
  - {name: m3, type: masque, server: consumer.example.com, 'private-key': $privateKey, ip: 172.16.0.2}
""",
        """{"address":["172.16.0.2/32"],"disable_version_fallback":true,"http_version":3,"mtu":1280,"private_key":"$privateKey","server":"consumer.example.com","server_port":443,"tag":"m3","tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}""",
        """{"private_key":"$privateKey","server":"consumer.example.com","server_port":443,"tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"}}""",
    )

    @Test
    fun `import stored masque`() = assertStoredImport(
        "masque",
        """{"type":"masque","tag":"mj","server":"consumer.example.com","server_port":443,"private_key":"$privateKey","peer_public_key":"$publicKey","address":["172.16.0.2"],"mtu":1280,"http_version":2,"disable_version_fallback":true,"tls":{"enabled":true,"server_name":"sni.example.com","insecure":true},"idle_timeout":"30s","initial_packet_size":1400}""",
        """{"address":["172.16.0.2/32"],"disable_version_fallback":true,"http_version":2,"idle_timeout":"30s","initial_packet_size":1400,"mtu":1280,"peer_public_key":"$publicKey","private_key":"$privateKey","server":"consumer.example.com","server_port":443,"tag":"mj","tls":{"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"masque"}""",
        "",
        """{"private_key":"$privateKey","server":"consumer.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `import stored masque clears sni`() = assertStoredImport(
        "masque",
        """{"type":"masque","tag":"md","private_key":"$privateKey","address":["172.16.0.2"],"tls":{"enabled":true}}""",
        """{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"$privateKey","server_port":443,"tag":"md","tls":{"enabled":true},"type":"masque"}""",
        "",
        """{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"$privateKey","server_port":443,"tag":"md","tls":{"enabled":true},"type":"masque"}""",
    )

    @Test
    fun `import stored masque default sni`() = assertStoredImport(
        "masque",
        """{"type":"masque","tag":"mt","private_key":"$privateKey","address":["172.16.0.2"]}""",
        """{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"$privateKey","server_port":443,"tag":"mt","tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}""",
        "",
        """{"address":["172.16.0.2/32"],"mtu":1280,"private_key":"$privateKey","server_port":443,"tag":"mt","tls":{"enabled":true,"server_name":"consumer-masque.cloudflareclient.com"},"type":"masque"}""",
    )

    private fun assertExport(doc: String, type: String, json: String, link: String, identity: String) {
        val ob = OutboundFactory.fromJson(JsonInput.parseObject(doc)) ?: error("document did not parse: $doc")
        assertEquals(type, ob.type)
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(link, ob.exportToLink())
        assertEquals(identity, ob.exportIdentity().toCompact())
    }

    @Test
    fun `export stored wireguard`() = assertExport(
        """{"type":"wireguard","tag":"we","private_key":"$privateKey","address":["10.0.0.2/32"],"mtu":1280,"peers":[{"address":"p.example.com","port":51820,"public_key":"$publicKey","reserved":[1,2,3],"persistent_keepalive_interval":"22-30"}]}""",
        "wireguard",
        """{"address":["10.0.0.2/32"],"mtu":1280,"peers":[{"address":"p.example.com","persistent_keepalive_interval":"22-30","port":51820,"public_key":"$publicKey","reserved":[1,2,3]}],"private_key":"$privateKey","tag":"we","type":"wireguard"}""",
        "wg://p.example.com:51820?private_key=${privateKey.replace("=", "%3D")}&local_address=10.0.0.2/32&mtu=1280&public_key=${publicKey.replace("=", "%3D")}&reserved=1-2-3&persistent_keepalive_interval=22-30#we",
        """{"address":["10.0.0.2/32"],"mtu":1280,"peers":[{"address":"p.example.com","persistent_keepalive_interval":"22-30","port":51820,"public_key":"$publicKey","reserved":[1,2,3]}],"private_key":"$privateKey","tag":"we","type":"wireguard"}""",
    )

    @Test
    fun `export stored masque`() = assertExport(
        """{"type":"masque","tag":"me","server":"s.example.com","server_port":443,"private_key":"$privateKey","address":"172.16.0.2","mtu":900,"http_version":3,"disable_version_fallback":true,"tls":{"enabled":true,"server_name":"sni.example.com","alpn":["h2"]},"reuse_addr":true,"idle_timeout":"10s"}""",
        "masque",
        """{"address":["172.16.0.2/32"],"disable_version_fallback":true,"http_version":3,"idle_timeout":"10s","mtu":900,"private_key":"$privateKey","reuse_addr":true,"server":"s.example.com","server_port":443,"tag":"me","tls":{"alpn":["h2"],"enabled":true,"server_name":"sni.example.com"},"type":"masque"}""",
        "",
        """{"private_key":"$privateKey","server":"s.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
    )
}
