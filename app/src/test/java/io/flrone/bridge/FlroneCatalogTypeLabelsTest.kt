package io.flrone.bridge

import io.flrone.model.ProxyNode
import io.nekohasekai.sagernet.database.ProxyEntity
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The catalog's node labels come from the stored columns (S8): the type label is a static table
 * plus the `custom` row's own config, never a parsed outbound. These pin what a row renders.
 */
class FlroneCatalogTypeLabelsTest {

    private fun node(type: String, name: String?, json: String): ProxyNode =
        FlroneCatalog.node(ProxyEntity(id = 1, type = type, name = name, outboundJson = json))

    @Test
    fun `a node carries the stored name and its type label`() {
        val node = node("shadowsocks", "Node A", """{"type":"shadowsocks","tag":"Node A","server":"a.example","server_port":8388}""")

        assertEquals("Node A", node.tag)
        assertEquals("Shadowsocks", node.type)
    }

    @Test
    fun `an alias row carries the canonical label`() {
        assertEquals("Hysteria", node("hysteria2", "H2", """{"type":"hysteria2","tag":"H2","server":"h.example","server_port":443}""").type)
    }

    @Test
    fun `a nameless node falls back to its address`() {
        val node = node("trojan", null, """{"type":"trojan","server":"t.example","server_port":443}""")

        assertEquals("t.example:443", node.tag)
        assertEquals("Trojan", node.type)
    }

    @Test
    fun `a custom node shows its config shape`() {
        assertEquals(
            "Custom Outbound",
            node("custom", "C", """{"type":"custom","name":"C","subtype":"outbound","config":"{\"type\":\"\"}"}""").type,
        )
        assertEquals(
            "Custom Direct Outbound",
            node("custom", "C", """{"type":"custom","name":"C","subtype":"outbound","config":"{\"type\":\"direct\"}"}""").type,
        )
        assertEquals(
            "Custom Config",
            node("custom", "C", """{"type":"custom","name":"C","subtype":"fullconfig","config":"{\"outbounds\":[]}"}""").type,
        )
        // An unknown subtype renders as itself, and an empty one as the stored type.
        assertEquals("tor", node("custom", "C", """{"type":"custom","name":"C","subtype":"tor","config":"{}"}""").type)
        assertEquals("custom", node("custom", "C", """{"type":"custom","name":"C","subtype":"","config":"{}"}""").type)
    }

    @Test
    fun `an unreadable row labels with its stored type`() {
        assertEquals("trojan", node("trojan", "Bad", "not json").type)
        assertEquals("xrayvless", node("xrayvless", "Legacy", """{"protocol":"vless"}""").type)
    }

    @Test
    fun `a selector row is marked as one`() {
        val node = node("autoselector", "Auto", """{"type":"autoselector","name":"Auto","gids":[2]}""")

        assertEquals("Auto Selector", node.type)
        assertEquals(true, node.isSelector)
    }
}
