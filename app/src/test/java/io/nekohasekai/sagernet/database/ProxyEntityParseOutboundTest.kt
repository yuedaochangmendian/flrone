package io.nekohasekai.sagernet.database

import io.nekohasekai.sagernet.outbound.InvalidOutbound
import io.nekohasekai.sagernet.outbound.types.Trojan
import io.nekohasekai.sagernet.outbound.types.Vless
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * S8: `parseOutbound` reads only already-migrated document rows.
 *
 * The stored-row Xray bridge moved to the service engine's document migration
 * (`LegacyXrayMigration` in Dart, invoking the Go `profileMigrate` action). An
 * old row that still carries the removed Xray type/shape must therefore reach
 * this path as an invalid outbound, never as a silently converted one.
 */
class ProxyEntityParseOutboundTest {

    private val uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"

    @Test
    fun `a stored xrayvless row is not converted by parseOutbound`() {
        val json = """
            {"protocol":"vless","tag":"legacy-node","settings":{"vnext":[{"address":"vless.example.com","port":443,"users":[{"id":"$uuid","encryption":"none"}]}]}}
        """.trimIndent()

        val outbound = ProxyEntity.parseOutbound("xrayvless", json)

        assertTrue("expected an InvalidOutbound, got ${outbound::class.java.name}", outbound is InvalidOutbound)
        assertEquals("xrayvless", outbound.type)
        assertTrue("the document owner's migration, not this read path, converts old rows", outbound !is Vless)
    }

    @Test
    fun `a custom row of the removed xray subtype is not converted by parseOutbound`() {
        val json = """
            {"type":"custom","subtype":"xrayoutbound","config":"{\"protocol\":\"trojan\",\"settings\":{\"servers\":[{\"address\":\"t.example.com\",\"port\":443,\"password\":\"p\"}]}}"}
        """.trimIndent()

        val outbound = ProxyEntity.parseOutbound("custom", json)

        assertEquals("custom", outbound.type)
        assertTrue("an Xray custom row must not become a Trojan outbound", outbound !is Trojan)
    }

    @Test
    fun `the migrated sing-box row parses normally`() {
        val json = """
            {"type":"vless","tag":"legacy-node","server":"vless.example.com","server_port":443,"uuid":"$uuid","encryption":"none"}
        """.trimIndent()

        val outbound = ProxyEntity.parseOutbound("vless", json)

        assertTrue("expected a Vless outbound, got ${outbound::class.java.name}", outbound is Vless)
        outbound as Vless
        assertEquals("legacy-node", outbound.name)
        assertEquals("vless.example.com", outbound.server)
        assertEquals(443, outbound.serverPort)
        assertEquals(uuid, outbound.uuid)
    }
}