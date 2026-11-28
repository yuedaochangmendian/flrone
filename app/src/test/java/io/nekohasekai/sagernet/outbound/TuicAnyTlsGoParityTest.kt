package io.nekohasekai.sagernet.outbound

import io.nekohasekai.sagernet.outbound.import.ClashYaml
import io.nekohasekai.sagernet.document.json.JsonInput
import io.nekohasekai.sagernet.outbound.types.AnyTls
import io.nekohasekai.sagernet.outbound.types.Tuic
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Kotlin oracle pins for the Go TUIC/AnyTLS import slice
 * (buildScript/core-patch/core/mobile/profile_import_tuic_anytls.go). Every
 * expected string is the exact bytes the JVM exporter emits; the Go unit tests
 * in profile_import_tuic_anytls_test.go assert the same strings. A change on
 * either side therefore fails here or there rather than drifting silently.
 */
class TuicAnyTlsGoParityTest {
    private val uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

    private fun outbound(type: String): Outbound = when (type) {
        "tuic" -> Tuic()
        "anytls" -> AnyTls()
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
    fun `tuic link full fields`() = assertLinkStored(
        "tuic",
        "tuic://$uuid:pass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=true&heartbeat=10s&sni=sni.example.com&alpn=h3&disable_sni=true&allowInsecure=1#t1",
        """{"congestion_control":"bbr","heartbeat":"10s","password":"pass","server":"tuic.example.com","server_port":443,"tag":"t1","tls":{"alpn":["h3"],"disable_sni":true,"enabled":true,"insecure":true,"server_name":"sni.example.com"},"type":"tuic","udp_relay_mode":"native","uuid":"$uuid","zero_rtt_handshake":true}""",
        "tuic://$uuid:pass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=true&heartbeat=10s&security=tls&disable_sni=true&sni=sni.example.com&allowInsecure=true&alpn=h3#t1",
        """{"server":"tuic.example.com","server_port":443,"tls":{"disable_sni":true,"enabled":true,"server_name":"sni.example.com"}}""",
    )

    @Test
    fun `tuic link percent userinfo and quic fields`() = assertLinkStored(
        "tuic",
        "tuic://$uuid:p%40ss@tuic.example.com:443?security=tls&sni=sni.example.com&fp=chrome&quic_idle_timeout=30s&quic_max_concurrent_streams=10&quic_disable_path_mtu_discovery=true#t2",
        """{"disable_path_mtu_discovery":true,"idle_timeout":"30s","max_concurrent_streams":10,"password":"p@ss","server":"tuic.example.com","server_port":443,"tag":"t2","tls":{"enabled":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"tuic","uuid":"$uuid"}""",
        "tuic://$uuid:p%40ss@tuic.example.com:443?security=tls&sni=sni.example.com&fp=chrome&quic_idle_timeout=30s&quic_max_concurrent_streams=10&quic_disable_path_mtu_discovery=true#t2",
        """{"server":"tuic.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
    )

    @Test
    fun `anytls link full fields and dial`() = assertLinkStored(
        "anytls",
        "anytls://pass@anytls.example.com:443?sni=sni.example.com&alpn=h2%2Chttp%2F1.1&fp=chrome&allowInsecure=1&idle_session_check_interval=45s&idle_session_timeout=1m&min_idle_session=3&connect_timeout=5s#a1",
        """{"connect_timeout":"5s","idle_session_check_interval":"45s","idle_session_timeout":"1m","min_idle_session":3,"password":"pass","server":"anytls.example.com","server_port":443,"tag":"a1","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"anytls"}""",
        "anytls://pass@anytls.example.com:443?idle_session_check_interval=45s&idle_session_timeout=1m&min_idle_session=3&security=tls&sni=sni.example.com&allowInsecure=true&alpn=h2,http/1.1&fp=chrome&connect_timeout=5s#a1",
        """{"server":"anytls.example.com","server_port":443,"tls":{"enabled":true,"server_name":"sni.example.com","utls":{"fingerprint":"chrome"}}}""",
    )

    private fun assertClashStored(yaml: String, json: String) {
        val entry = ClashYaml.proxies(yaml)?.single() ?: error("document has no proxies: $yaml")
        val ob = outbound(entry.string("type").lowercase())
        assertTrue("Clash entry should parse", ob.parseFromClash(entry))
        assertEquals(json, ob.exportToJson().toCompact())
    }

    @Test
    fun `clash tuic fields`() = assertClashStored(
        """proxies:
  - {name: tc, type: tuic, server: tuic.example.com, port: 443, uuid: $uuid, password: pass, congestion-controller: bbr, 'udp-relay-mode': native, 'reduce-rtt': true, 'heartbeat-interval': 10000, sni: sni.example.com, alpn: [h3], 'skip-cert-verify': true, ip: 1.2.3.4, 'client-fingerprint': chrome}
""",
        """{"congestion_control":"bbr","heartbeat":"10000ms","password":"pass","server":"1.2.3.4","server_port":443,"tag":"tc","tls":{"alpn":["h3"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"tuic","udp_relay_mode":"native","uuid":"$uuid","zero_rtt_handshake":true}""",
    )

    @Test
    fun `clash anytls fields`() = assertClashStored(
        """proxies:
  - {name: at, type: anytls, server: anytls.example.com, port: 443, password: pass, 'idle-session-check-interval': 45, 'idle-session-timeout': 60, 'min-idle-session': 3, sni: sni.example.com, alpn: [h2, http/1.1], 'skip-cert-verify': true, 'client-fingerprint': chrome}
""",
        """{"idle_session_check_interval":"45s","idle_session_timeout":"60s","min_idle_session":3,"password":"pass","server":"anytls.example.com","server_port":443,"tag":"at","tls":{"alpn":["h2","http/1.1"],"enabled":true,"insecure":true,"server_name":"sni.example.com","utls":{"enabled":true,"fingerprint":"chrome"}},"type":"anytls"}""",
    )

    private fun assertStoredJsonLink(type: String, doc: String, json: String, linkBack: String) {
        val ob = outbound(type)
        assertTrue("stored JSON should parse: $doc", ob.parseFromJson(JsonInput.parseObject(doc)))
        assertEquals(json, ob.exportToJson().toCompact())
        assertEquals(linkBack, ob.exportToLink())
    }

    @Test
    fun `stored tuic json round-trip`() = assertStoredJsonLink(
        "tuic",
        """{"type":"tuic","tag":"tj","server":"tuic.example.com","server_port":443,"uuid":"$uuid","password":"pass","congestion_control":"bbr","udp_relay_mode":"native","zero_rtt_handshake":true,"heartbeat":"10s","tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        """{"congestion_control":"bbr","heartbeat":"10s","password":"pass","server":"tuic.example.com","server_port":443,"tag":"tj","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"tuic","udp_relay_mode":"native","uuid":"$uuid","zero_rtt_handshake":true}""",
        "tuic://$uuid:pass@tuic.example.com:443?congestion_control=bbr&udp_relay_mode=native&zero_rtt_handshake=true&heartbeat=10s&security=tls&sni=sni.example.com#tj",
    )

    @Test
    fun `stored anytls json round-trip`() = assertStoredJsonLink(
        "anytls",
        """{"type":"anytls","tag":"aj","server":"anytls.example.com","server_port":443,"password":"pass","idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"tls":{"enabled":true,"server_name":"sni.example.com"}}""",
        """{"idle_session_check_interval":"30s","idle_session_timeout":"30s","min_idle_session":5,"password":"pass","server":"anytls.example.com","server_port":443,"tag":"aj","tls":{"enabled":true,"server_name":"sni.example.com"},"type":"anytls"}""",
        "anytls://pass@anytls.example.com:443?idle_session_check_interval=30s&idle_session_timeout=30s&min_idle_session=5&security=tls&sni=sni.example.com#aj",
    )
}
