package io.nekohasekai.sagernet.outbound.config

import io.nekohasekai.sagernet.database.RouteJsonStore
import io.nekohasekai.sagernet.database.RouteManager
import io.nekohasekai.sagernet.outbound.BuildContext
import io.nekohasekai.sagernet.outbound.Outbound
import io.nekohasekai.sagernet.outbound.json.JsonInput
import io.nekohasekai.sagernet.outbound.json.JsonObject
import io.nekohasekai.sagernet.outbound.types.Vless
import io.nekohasekai.sagernet.route.RuleSetCatalog
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
 * The single-table model end to end: the in-memory Default profile carries the global rule
 * table, and ConfigGenerator turns it into a sing-box `route.rules` / `route.rule_set` /
 * `route.final` without any route document other than the global table (no profile selection,
 * no Room, no kernel call).
 */
class ConfigGeneratorGlobalRulesTest {

    private lateinit var temp: File
    private var previousDir: File? = null
    private var previousLogger: (String, Throwable?) -> Unit = { _, _ -> }

    @Before
    fun setUp() {
        temp = Files.createTempDirectory("global-rules-build-").toFile()
        previousDir = RouteJsonStore.directory
        previousLogger = RouteJsonStore.logger
        RouteJsonStore.directory = temp
        RouteJsonStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        RouteJsonStore.directory = previousDir
        RouteJsonStore.logger = previousLogger
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

    private fun globalRule(order: Int, domain: String) = JSONObject().apply {
        put("id", order + 1)
        put("rule_order", order)
        put("name", "block-$domain")
        put("type", 0) // CUSTOM
        put("domain_suffix_json", JSONArray(listOf(domain)))
        put("action", "reject")
        put("outbound_id", -1L)
    }

    private val startedProfile = Vless().apply {
        name = "node"
        server = "node.example.com"
        serverPort = 443
        uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
    }

    private fun provider(vararg entries: Pair<Long, Outbound>) = object : ProfileProvider {
        private val byId = entries.toMap()
        override fun get(id: Long): Outbound? = byId[id]
    }

    private fun generate(): JsonObject {
        // RouteManager.current() = built-in Default (hijack-dns) + global rules.
        val input = RoutingInput(RouteManager.current(), RuleSetCatalog(emptyList()))
        val settings = GeneratorSettings(vpnMode = false, enableDnsRouting = false, trafficStats = false)
        val generator = ConfigGenerator(provider(1L to startedProfile), settings, BuildContext.DEFAULT, input)
        val result = generator.build(1L)
        assertTrue("build must succeed: ${result.error}", result.ok)
        return JsonInput.parseObject(result.coreConfig)
    }

    @Test
    fun `global rules become route rules with a proxy final`() {
        writeGlobalRules(globalRule(0, "ads.example"), globalRule(1, "tracker.example"))
        val core = generate()
        val route = core.obj("route")
        assertEquals("proxy", route.string("final"))

        val rules = route.array("rules")
        // sniff, hijack-dns (from the built-in Default), then the two global rules.
        assertTrue("hijack-dns rule must stay", rules.any { (it as? JsonObject)?.string("action") == "hijack-dns" })
        val suffixes = rules.mapNotNull { rule ->
            (rule as? JsonObject)?.array("domain_suffix")?.strings()?.firstOrNull()
        }
        assertEquals(listOf("ads.example", "tracker.example"), suffixes)
        assertTrue("the rule_set array is always present", route.contains("rule_set"))
    }

    @Test
    fun `a stale global rule naming a missing outbound is dropped`() {
        // outbound 42 has no profile row: the build must not reference a non-existent tag.
        writeGlobalRules(JSONObject().apply {
            put("id", 1)
            put("rule_order", 0)
            put("name", "stale")
            put("type", 0)
            put("domain_suffix_json", JSONArray(listOf("gone.example")))
            put("action", "route")
            put("outbound_id", 42L)
        })
        val rules = generate().obj("route").array("rules")
        assertFalse(rules.any { rule ->
            (rule as? JsonObject)?.array("domain_suffix")?.strings()?.contains("gone.example") == true
        })
    }

    @Test
    fun `a disabled global rule is filtered before the build`() {
        writeGlobalRules(JSONObject().apply {
            put("id", 1)
            put("rule_order", 0)
            put("name", "off")
            put("type", 0)
            put("domain_suffix_json", JSONArray(listOf("off.example")))
            put("action", "reject")
            put("outbound_id", -1L)
            put("disabled", 1)
        })
        val rules = generate().obj("route").array("rules")
        assertFalse(rules.any { rule ->
            (rule as? JsonObject)?.array("domain_suffix")?.strings()?.contains("off.example") == true
        })
    }

    @Test
    fun `every remote rule-set carries the empty initial copy even without a deferred start`() {
        // A dead mirror or CDN used to fail the whole start ("initial rule-set: <tag>"). The empty initial_path lets
        // the core come up with an empty set and download in the background, so it must be present on the ordinary
        // (non-deferred) start too, not only when the user opted into "start without rule sets".
        writeGlobalRules(JSONObject().apply {
            put("id", 1)
            put("rule_order", 0)
            put("name", "geosite-ru")
            put("type", 0)
            put("rule_set_json", JSONArray(listOf("geosite-ru")).toString())
            put("action", "reject")
            put("outbound_id", -1L)
        })
        val input = RoutingInput(
            RouteManager.current(),
            RuleSetCatalog(
                listOf(
                    "geosite-ru" to
                        "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/ru.srs",
                ),
            ),
        )
        val settings = GeneratorSettings(vpnMode = false, enableDnsRouting = false, trafficStats = false)
        val generator = ConfigGenerator(provider(1L to startedProfile), settings, BuildContext.DEFAULT, input)
        val result = generator.build(1L)
        assertTrue("build must succeed: ${result.error}", result.ok)

        val sets = JsonInput.parseObject(result.coreConfig).obj("route").array("rule_set")
        val remotes = sets.mapNotNull { it as? JsonObject }.filter { it.string("type") == "remote" }
        assertTrue("a remote rule-set must be emitted", remotes.isNotEmpty())
        for (set in remotes) {
            assertEquals(
                "remote set ${set.string("tag")} needs an initial_path so a fetch failure cannot block the start",
                ConfigGenerator.EMPTY_RULE_SET_PATH,
                set.string("initial_path"),
            )
        }
    }
}
