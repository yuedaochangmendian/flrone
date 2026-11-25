package io.nekohasekai.sagernet.outbound.config

import io.flrone.bridge.DartProfileStore
import io.nekohasekai.sagernet.database.RouteJsonStore
import io.nekohasekai.sagernet.database.RouteManager
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The single-table model at the JVM level: `RouteManager.current()` is the in-memory Default profile carrying the
 * global rule table, and the table rules are ordered and filtered the way the build sees them.
 *
 * The full `ConfigGenerator.build()` path needs the Android application object, so it is not driven here; the wire
 * shape it produces (`route.rules` / `route.rule_set` / `route.final`) is covered by the Dart routing tests that run
 * the same generated config against the fake kernel.
 */
class ConfigGeneratorGlobalRulesTest {

    private lateinit var temp: File
    private var previousDir: File? = null
    private var previousLogger: (String, Throwable?) -> Unit = { _, _ -> }
    private var previousProfileDir: File? = null
    private var previousProfileLogger: (String, Throwable?) -> Unit = { _, _ -> }

    @Before
    fun setUp() {
        temp = Files.createTempDirectory("global-rules-build-").toFile()
        previousDir = RouteJsonStore.directory
        previousLogger = RouteJsonStore.logger
        RouteJsonStore.directory = temp
        RouteJsonStore.logger = { _, _ -> }
        // dropStaleOutbounds asks ProfileManager (the Dart-owned document) whether a rule's outbound exists.
        previousProfileDir = DartProfileStore.directory
        previousProfileLogger = DartProfileStore.logger
        DartProfileStore.directory = temp
        DartProfileStore.logger = { _, _ -> }
        // One real node (id 1) so a rule that names it survives the stale-outbound filter.
        File(temp, "profiles.json").writeText(
            """{"version":1,"nextProfileId":2,"nextGroupId":1,"profiles":[{"id":1,"type":"vless",""" +
                """"name":"node","gid":0,"outbound_json":"{}"}],"groups":[]}""",
        )
        DartProfileStore.invalidate()
    }

    @After
    fun tearDown() {
        RouteJsonStore.directory = previousDir
        RouteJsonStore.logger = previousLogger
        DartProfileStore.directory = previousProfileDir
        DartProfileStore.logger = previousProfileLogger
        DartProfileStore.invalidate()
        temp.deleteRecursively()
    }

    private fun writeGlobalRules(vararg rows: JSONObject) {
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", "global_route_rules")
            put("rows", JSONArray(rows.toList()))
        }
        File(temp, "global_route_rules.json").writeText(payload.toString())
    }

    private fun globalRule(
        order: Int,
        domain: String,
        outboundId: Long = -1L,
        disabled: Boolean = false,
    ) = JSONObject().apply {
        put("id", order + 1)
        put("rule_order", order)
        put("name", "rule-$domain")
        put("type", 0) // CUSTOM
        put("domain_suffix_json", JSONArray(listOf(domain)).toString())
        put("action", "route")
        put("outbound_id", outboundId)
        if (disabled) put("disabled", 1)
    }

    @Test
    fun `the current profile carries the global table in stored order`() {
        writeGlobalRules(globalRule(1, "second.example"), globalRule(0, "first.example"))
        val current = RouteManager.current()
        // The built-in Default's own hijack-dns rule comes first, then the table in `rule_order`.
        assertTrue(current.rules.any { it.action == "hijack-dns" })
        val suffixes = current.rules.mapNotNull { it.domain_suffix.firstOrNull() }
        assertEquals(listOf("first.example", "second.example"), suffixes)
    }

    @Test
    fun `a rule naming a missing outbound is dropped`() {
        writeGlobalRules(globalRule(0, "gone.example", outboundId = 42L))
        val current = RouteManager.current()
        assertFalse(current.rules.any { it.domain_suffix.contains("gone.example") })
    }

    @Test
    fun `a rule naming a real outbound survives the filter`() {
        writeGlobalRules(globalRule(0, "kept.example", outboundId = 1L))
        val current = RouteManager.current()
        assertTrue(current.rules.any { it.domain_suffix.contains("kept.example") })
    }

    @Test
    fun `dropStaleOutbounds keeps the direct and reject fixed targets`() {
        writeGlobalRules(
            globalRule(0, "direct.example", outboundId = -2L),
            globalRule(1, "reject.example", outboundId = -1L),
        )
        val current = RouteManager.current()
        assertTrue(current.rules.any { it.domain_suffix.contains("direct.example") })
        assertTrue(current.rules.any { it.domain_suffix.contains("reject.example") })
    }
}
