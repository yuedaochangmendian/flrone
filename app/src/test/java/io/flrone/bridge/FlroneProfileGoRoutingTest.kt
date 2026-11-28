package io.flrone.bridge

import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.OutboundFactory
import io.nekohasekai.sagernet.outbound.json.JsonArray
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.ui.json.ProfileJson
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The S8 node-editor routing contract: Go actions answer first, and the old
 * Kotlin model path runs only when an action says `supported:false` (or the
 * action bus is unavailable). The fake transport stands in for
 * `Core.runAction`, so the request methods/payloads and the reply mapping are
 * asserted without a device.
 *
 * The parity cases reuse the live Kotlin model as the oracle: the Go templates
 * and stored bytes are already pinned against it by ProfileStoredGoParityTest,
 * and these tests prove the routing wrapper keeps the exact draft/report shapes
 * the Dart form expects.
 */
class FlroneProfileGoRoutingTest {

    private lateinit var originalTransport: (String) -> String
    private lateinit var originalContext: () -> BuildContext

    @Before
    fun setUp() {
        originalTransport = FlroneProfileActions.transport
        originalContext = FlroneNodeEditorLegacy.buildContext
        FlroneNodeEditorLegacy.buildContext = { BuildContext.DEFAULT }
    }

    @After
    fun tearDown() {
        FlroneProfileActions.transport = originalTransport
        FlroneNodeEditorLegacy.buildContext = originalContext
    }

    // ------------------------------------------------------------------------------------------------ helpers

    private fun objectOf(vararg pairs: Pair<String, Any?>): JsonObject =
        JsonObject().also { value -> pairs.forEach { (key, item) -> value[key] = item } }

    private fun okReply(data: JsonObject): String = objectOf(
        "id" to "test",
        "method" to "test",
        "code" to 0,
        "data" to data,
    ).toCompact()

    private fun errorReply(message: String): String = objectOf(
        "id" to "test",
        "method" to "test",
        "code" to -1,
        "data" to message,
    ).toCompact()

    private fun importReply(vararg nodes: JsonObject): JsonObject = objectOf(
        "supported" to true,
        "nodes" to JsonArray().also { array -> nodes.forEach { array.add(it) } },
    )

    private fun nodeJson(
        type: String,
        name: String,
        json: String,
        link: String = "",
    ): JsonObject = objectOf(
        "type" to type,
        "name" to name,
        "json" to json,
        "link" to link,
        "identity" to "",
        "dedupKey" to "",
    )

    private fun request(encoded: String): JsonObject = JsonInput.parseObject(encoded)

    // ------------------------------------------------------------------------------------------------ create/template

    @Test
    fun `blank templates keep the old createNode draft for every covered type`() {
        val types = listOf(
            "socks", "http", "shadowsocks", "chain", "autoselector", "vmess", "trojan",
            "vless", "hysteria", "hysteria2", "tuic", "juicity", "trusttunnel", "anytls",
            "mieru", "snell", "shadowtls", "wireguard", "masque", "openvpn", "openvpn-client",
            "openconnect", "ssh", "custom", "naive", "direct",
        )
        assertEquals(25, types.size - 1)
        for (type in types) {
            val outbound = OutboundFactory.newByType(type)
            assertFalse("$type must be a live Kotlin type", outbound.invalid)
            val draft = FlroneProfileActions.createNodeDraft(
                type,
                outbound.exportToJson().toCompact(),
                42L,
            )
            assertEquals("$type id", 0L, draft["id"])
            assertEquals("$type group", 42L, draft["groupId"])
            assertEquals(
                "$type name",
                outbound.name.ifBlank { outbound.displayType().ifBlank { type } },
                draft["name"],
            )
            assertEquals("$type display type", outbound.displayType(), draft["type"])
            assertEquals("$type pretty json", ProfileJson.text(outbound), draft["json"])
        }
    }

    @Test
    fun `display types match the Kotlin outbound classes`() {
        val types = OutboundFactory.ALL_TYPES + listOf("hysteria2", "openvpn-client")
        for (type in types) {
            val outbound = OutboundFactory.newByType(type)
            assertEquals("$type displayType", outbound.displayType(), FlroneProfileActions.displayType(type))
        }
        assertEquals("unknown types keep the stored type when the model has no label", "future-proto", FlroneProfileActions.displayTypeOrStored("future-proto"))
    }

    @Test
    fun `endpoint classification matches the Kotlin outbound classes`() {
        val types = OutboundFactory.ALL_TYPES + listOf("hysteria2", "openvpn-client")
        for (type in types) {
            val outbound = OutboundFactory.newByType(type)
            assertEquals("$type isEndpoint", outbound.isEndpoint(), FlroneProfileActions.isEndpointType(type))
        }
    }

    @Test
    fun `display names match the model fallbacks`() {
        val cases = listOf(
            """{"type":"shadowsocks","tag":"Node A","server":"host","server_port":8388,"method":"aes-256-gcm","password":"secret"}""",
            """{"type":"shadowsocks","server":"host","server_port":8388,"method":"aes-256-gcm","password":"secret"}""",
            """{"type":"direct"}""",
            """{"type":"hysteria2","realm":{"server_url":"https://realm.example.com","realm_id":"rid"},"tls":{}}""",
            """{"type":"http","server":"2001:db8::1","server_port":8080}""",
        )
        for (json in cases) {
            val outbound = OutboundFactory.fromJson(JsonInput.parseObject(json))
            assertNotNull("the oracle must parse: $json", outbound)
            val objectValue = JsonInput.parseObject(json)
            val type = objectValue.string("type")
            assertEquals(
                "display name for $json",
                outbound!!.displayName(),
                FlroneProfileActions.displayName(type, objectValue.string("tag"), json),
            )
        }
    }

    @Test
    fun `a row is only read through Go when its column and stored types agree`() {
        assertTrue(FlroneProfileActions.rowTypeMatches("""{"type":"vless","server":"h"}""", "vless"))
        assertTrue(FlroneProfileActions.rowTypeMatches("""{"type":"hysteria2","password":"p"}""", "hysteria"))
        assertFalse(FlroneProfileActions.rowTypeMatches("""{"type":"vless"}""", "vmess"))
        assertFalse(FlroneProfileActions.rowTypeMatches("""{"type":"custom"}""", "custom"))
        assertFalse(FlroneProfileActions.rowTypeMatches("""{"type":"autoselector"}""", "autoselector"))
        assertFalse(FlroneProfileActions.rowTypeMatches("""{}""", "socks"))
        assertFalse(FlroneProfileActions.rowTypeMatches("""{"type":"socks"}""", ""))
    }

    @Test
    fun `profileNewOutbound answers the template and a refusal stays a null`() {
        val template = """{"encryption":"none","packet_encoding":"xudp","type":"vless"}"""
        FlroneProfileActions.transport = { encoded ->
            val request = request(encoded)
            assertEquals("profileNewOutbound", request.string("method"))
            assertEquals("vless", (request["data"] as JsonObject).string("type"))
            okReply(objectOf("json" to template))
        }
        assertEquals(template, FlroneProfileActions.newOutbound("vless"))

        FlroneProfileActions.transport = { errorReply("profile.newOutbound: unsupported type") }
        assertNull(FlroneProfileActions.newOutbound("tailscale"))
    }

    // ------------------------------------------------------------------------------------------------ import

    @Test
    fun `nodeParse asks Go first and keeps the Dart nodes shape`() {
        val compact = """{"password":"pass","server":"example.com","server_port":8388,"type":"shadowsocks"}"""
        FlroneProfileActions.transport = { encoded ->
            val request = request(encoded)
            assertEquals("profileImport", request.string("method"))
            assertEquals("ss://link", (request["data"] as JsonObject).string("text"))
            okReply(importReply(nodeJson("shadowsocks", "Node A", compact, "ss://link")))
        }

        val answer = runBlocking { FlroneProfiles.parseNodeText("ss://link") }
        val nodes = answer["nodes"] as List<*>
        val node = nodes.single() as Map<*, *>
        assertEquals("Shadowsocks", node["type"])
        assertEquals("Node A", node["name"])
        assertEquals(FlroneProfileActions.prettyStored(compact), node["json"])
        assertEquals(0, answer["skipped"])
        assertEquals(emptyList<String>(), answer["messages"])
    }

    @Test
    fun `nodeParse falls back to the Kotlin importer on supported false`() {
        var calls = 0
        FlroneProfileActions.transport = {
            calls++
            okReply(objectOf("supported" to false, "reason" to "advanced fields are not ported yet"))
        }

        val link = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node%20A"
        val answer = runBlocking { FlroneProfiles.parseNodeText(link) }
        val node = (answer["nodes"] as List<*>).single() as Map<*, *>
        assertEquals(1, calls)
        assertEquals("Node A", node["name"])
        assertEquals("Shadowsocks", node["type"])
        assertEquals(
            ProfileJson.text(
                OutboundFactory.fromJson(JsonInput.parseObject("""{"method":"aes-256-gcm","password":"pass","server":"example.com","server_port":8388,"tag":"Node A","type":"shadowsocks"}"""))!!,
            ),
            node["json"],
        )
        assertEquals(0, answer["skipped"])
    }

    @Test
    fun `an unavailable action bus falls back to the Kotlin importer`() {
        FlroneProfileActions.transport = { throw UnsatisfiedLinkError("libcore is absent") }

        val link = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node%20A"
        val answer = runBlocking { FlroneProfiles.parseNodeText(link) }
        val node = (answer["nodes"] as List<*>).single() as Map<*, *>
        assertEquals("Node A", node["name"])
        assertEquals("Shadowsocks", node["type"])
    }

    @Test
    fun `a bare stored document takes the Go normalizer, not the importer`() {
        val stored = """{"type":"vless","server":"h","server_port":443,"uuid":"u","encryption":"","tls":{"enabled":true}}"""
        val canonical = """{"encryption":"none","packet_encoding":"xudp","server":"h","server_port":443,"tls":{"enabled":true},"type":"vless","uuid":"u"}"""
        val methods = ArrayList<String>()
        FlroneProfileActions.transport = { encoded ->
            val request = request(encoded)
            methods.add(request.string("method"))
            assertEquals("stored", (request["data"] as JsonObject).string("format"))
            okReply(objectOf("supported" to true, "json" to canonical))
        }

        val parsed = FlroneProfileActions.parseEditorNode(stored)
        val node = (parsed as FlroneProfileActions.EditorParse.Nodes).nodes.single()
        assertEquals(listOf("profileNormalize"), methods)
        assertEquals("vless", node.type)
        assertEquals("", node.name)
        assertEquals(canonical, node.json)
    }

    @Test
    fun `a custom document skips the normalizer and falls back through the importer refusal`() {
        val methods = ArrayList<String>()
        FlroneProfileActions.transport = { encoded ->
            methods.add(request(encoded).string("method"))
            okReply(objectOf("supported" to false, "reason" to "stored outbound type not ported yet: custom"))
        }

        // The Kotlin Custom model rewrites launcher blocks; the Go normalizer only
        // canonicalises keys, so the routing deliberately takes the import refusal
        // and lets FlroneNodeEditorLegacy own the document.
        val parsed = FlroneProfileActions.parseEditorNode(
            """{"config":"","name":"","subtype":"","type":"custom"}""",
        )
        assertTrue(parsed is FlroneProfileActions.EditorParse.Refused)
        assertEquals(listOf("profileImport"), methods)

        methods.clear()
        val selector = FlroneProfileActions.parseEditorNode(
            """{"gids":[1],"name":"","type":"autoselector"}""",
        )
        assertTrue(selector is FlroneProfileActions.EditorParse.Refused)
        assertEquals(listOf("profileImport"), methods)
    }

    @Test
    fun `a share link takes the Go importer on the editor path`() {
        val compact = """{"method":"aes-256-gcm","password":"pass","server":"h","server_port":8388,"type":"shadowsocks"}"""
        FlroneProfileActions.transport = { encoded ->
            val request = request(encoded)
            assertEquals("profileImport", request.string("method"))
            okReply(importReply(nodeJson("shadowsocks", "n", compact)))
        }
        val parsed = FlroneProfileActions.parseEditorNode("ss://YWVzLTI1Ni1nY206cGFzcw@h:8388#n")
        val node = (parsed as FlroneProfileActions.EditorParse.Nodes).nodes.single()
        assertEquals("shadowsocks", node.type)
        assertEquals(compact, node.json)
    }

    // ------------------------------------------------------------------------------------------------ validate / normalize / export

    @Test
    fun `stored validation maps issues and the Go refusal`() {
        FlroneProfileActions.transport = { encoded ->
            assertEquals("profileValidate", request(encoded).string("method"))
            okReply(objectOf(
                "ok" to false,
                "supported" to true,
                "issues" to JsonArray().also { issues ->
                    issues.add(objectOf(
                        "field" to "server",
                        "message" to "the address is required",
                        "severity" to "error",
                    ))
                },
                "normalized" to """{"type":"socks"}""",
            ))
        }
        val verdict = FlroneProfileActions.validateStored("""{"type":"socks"}""")
        assertTrue(verdict is FlroneProfileActions.StoredValidation.Supported)
        verdict as FlroneProfileActions.StoredValidation.Supported
        assertFalse(verdict.ok)
        assertEquals("server: the address is required", verdict.issues.single().describe())
        assertEquals("""{"type":"socks"}""", verdict.normalized)

        FlroneProfileActions.transport = {
            okReply(objectOf(
                "ok" to false,
                "supported" to false,
                "issues" to JsonArray().also { issues ->
                    issues.add(objectOf("field" to "", "message" to "not modelled", "severity" to "error"))
                },
            ))
        }
        val refused = FlroneProfileActions.validateStored("""{"type":"wireguard"}""")
        assertTrue(refused is FlroneProfileActions.StoredValidation.Refused)
        assertEquals("not modelled", (refused as FlroneProfileActions.StoredValidation.Refused).reason)
    }

    @Test
    fun `normalize and rename keep the stored format flag`() {
        val requests = ArrayList<JsonObject>()
        FlroneProfileActions.transport = { encoded ->
            val request = request(encoded)
            requests.add(request)
            okReply(objectOf("supported" to true, "json" to """{"tag":"New","type":"socks"}"""))
        }
        val renamed = FlroneProfileActions.renameStored("""{"type":"socks"}""", "New")
        assertTrue(renamed is FlroneProfileActions.StoredNormalize.Supported)
        assertEquals("""{"tag":"New","type":"socks"}""", (renamed as FlroneProfileActions.StoredNormalize.Supported).json)
        assertEquals("profileNormalize", requests.single().string("method"))
        assertEquals("stored", (requests.single()["data"] as JsonObject).string("format"))
        assertEquals("""{"tag":"New","type":"socks"}""", (requests.single()["data"] as JsonObject).string("json"))
    }

    @Test
    fun `export answers the node info fields and a refusal is typed`() {
        FlroneProfileActions.transport = { encoded ->
            assertEquals("profileExport", request(encoded).string("method"))
            okReply(objectOf(
                "supported" to true,
                "type" to "shadowsocks",
                "name" to "Node A",
                "displayType" to "Shadowsocks",
                "json" to """{"server":"h","server_port":8388,"type":"shadowsocks"}""",
                "link" to "ss://link",
                "jsonLink" to "throne://add/json",
            ))
        }
        val exported = FlroneProfileActions.exportStored("""{"type":"shadowsocks"}""")
        assertTrue(exported is FlroneProfileActions.StoredExport.Supported)
        val node = (exported as FlroneProfileActions.StoredExport.Supported).node
        assertEquals("ss://link", node.link)
        assertEquals("throne://add/json", node.jsonLink)

        FlroneProfileActions.transport = { okReply(objectOf("supported" to false, "reason" to "not modelled")) }
        val refused = FlroneProfileActions.exportStored("""{"type":"tuic"}""")
        assertTrue(refused is FlroneProfileActions.StoredExport.Refused)
    }

    // ------------------------------------------------------------------------------------------------ decode

    @Test
    fun `decodeIntent uses Go for a link and keeps the editor draft shape`() {
        val compact = """{"password":"pass","server":"example.com","server_port":8388,"type":"shadowsocks"}"""
        FlroneProfileActions.transport = {
            okReply(importReply(nodeJson("shadowsocks", "Node A", compact)))
        }
        val answer = runBlocking { FlroneProfiles.decodeIntent("ss://link") }
        assertEquals("Node A", answer["name"])
        assertEquals("ss://link", answer["content"])
        assertEquals(false, answer["remote"])
        assertEquals(0, answer["interval"])
        assertEquals(1, answer["nodeCount"])
        assertEquals(7, answer.keys.size)
    }

    @Test
    fun `decodeIntent falls back to the Kotlin decoder on a Go refusal`() {
        FlroneProfileActions.transport = { okReply(objectOf("supported" to false, "reason" to "not ported")) }
        val link = "ss://YWVzLTI1Ni1nY206cGFzcw@example.com:8388#Node%20A"
        val answer = runBlocking { FlroneProfiles.decodeIntent(link) }
        assertEquals("Node A", answer["name"])
        assertEquals(link, answer["content"])
        assertEquals(1, answer["nodeCount"])
    }
}