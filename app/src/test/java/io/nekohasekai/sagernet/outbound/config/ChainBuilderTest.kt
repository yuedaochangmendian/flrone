package io.nekohasekai.sagernet.outbound.config

import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.outbound.types.Vless
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** A chain is a plain ordered list of sing-box outbounds linked with `detour`; the hop order is the semantics. */
class ChainBuilderTest {

    private fun vless(name: String, server: String): Vless = Vless().apply {
        this.name = name
        this.server = server
        serverPort = 443
        uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    }

    private fun provider(vararg entries: Pair<Long, Outbound>) = object : ProfileProvider {
        private val byId = entries.toMap()
        override fun get(id: Long): Outbound? = byId[id]
    }

    @Test
    fun `a two-hop chain links the exit through the entry with detour`() {
        val state = BuildState(forTest = false)
        val chains = ChainBuilder(
            provider(1L to vless("exit", "exit.example.com"), 2L to vless("entry", "entry.example.com")),
            BuildContext.DEFAULT,
            state,
        )

        val ingress = chains.buildOutboundChain(ChainRequest(listOf(1L, 2L), "config", includeProxy = true))

        assertEquals("proxy", ingress)
        assertEquals("", state.error)
        assertEquals(2, state.outbounds.size)
        val exit = state.outbounds[0] as JsonObject
        assertEquals("proxy", exit.string("tag"))
        assertEquals("exit.example.com", exit.string("server"))
        assertEquals("config-1", exit.string("detour"))
        val entry = state.outbounds[1] as JsonObject
        assertEquals("config-1", entry.string("tag"))
        assertEquals("entry.example.com", entry.string("server"))
        assertFalse(entry.contains("detour"))
    }

    @Test
    fun `a route chain keeps its suffix and does not take the proxy tag`() {
        val state = BuildState(forTest = true)
        val chains = ChainBuilder(
            provider(1L to vless("exit", "exit.example.com"), 2L to vless("entry", "entry.example.com")),
            BuildContext.DEFAULT,
            state,
        )

        val ingress = chains.buildOutboundChain(ChainRequest(listOf(1L, 2L), "route", link = true, startSuffix = 3))

        assertEquals("route-3", ingress)
        assertEquals("route-3", (state.outbounds[0] as JsonObject).string("tag"))
        assertEquals("route-4", (state.outbounds[0] as JsonObject).string("detour"))
        assertEquals("route-4", (state.outbounds[1] as JsonObject).string("tag"))
    }

    @Test
    fun `a missing hop names the chain`() {
        val state = BuildState(forTest = false)
        val chain = io.nekohasekai.sagernet.outbound.types.Chain().apply { list.addAll(listOf(1L, 9L)) }
        val chains = ChainBuilder(provider(1L to vless("exit", "exit.example.com")), BuildContext.DEFAULT, state)

        chains.buildOutboundChain(ChainRequest(listOf(1L, 9L), "config", origin = HopOrigin(chain)))

        assertTrue(state.error.contains("no longer exists"))
    }
}
