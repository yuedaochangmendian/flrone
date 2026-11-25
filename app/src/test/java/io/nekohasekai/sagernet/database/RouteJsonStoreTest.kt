// The read-only view of the single global route-rule table.
//
// Go is the only writer, so this side's contract is narrow: read a document the kernel wrote,
// map every column onto [GlobalRouteRuleEntity], and answer null — never throw — when the file
// is absent or corrupt, because null means "no global rules" for the build.

import io.nekohasekai.sagernet.database.RouteJsonStore
import java.io.File
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class RouteJsonStoreTest {

    private lateinit var temp: File
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("route-json", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        RouteJsonStore.directory = temp
        originalLogger = RouteJsonStore.logger
        RouteJsonStore.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        RouteJsonStore.directory = null
        RouteJsonStore.logger = originalLogger
        temp.deleteRecursively()
    }

    /** Writes a document the way the kernel does: a versioned envelope around rows. */
    private fun write(name: String, rows: List<Map<String, Any?>>) {
        val payload = JSONObject().apply {
            put("version", 1)
            put("name", name)
            put("rows", org.json.JSONArray(rows))
        }
        File(temp, "$name.json").writeText(payload.toString())
    }

    /** A global row as the kernel writes it: `id`, no `route_profile_id`. */
    private fun globalRuleRow(id: Long, order: Int, name: String = "global") = mapOf<String, Any?>(
        "id" to id,
        "rule_order" to order,
        "name" to name,
        "type" to 0,
        "ip_version" to "4",
        "network" to "tcp",
        "protocol" to "tls",
        "domain_json" to """["b.com"]""",
        "domain_suffix_json" to """["ads.example"]""",
        "rule_set_json" to """["rs"]""",
        "sniffers_json" to """["sn"]""",
        "action" to "reject",
        "outbound_id" to -1L,
        "strategy" to "prefer_ipv4",
        "disabled" to 1,
        "invert" to 1,
        "network_is_expensive" to 1,
    )

    @Test
    fun `not ready without a directory`() {
        RouteJsonStore.directory = null
        assertFalse(RouteJsonStore.ready)
        assertNull(RouteJsonStore.allGlobalRules())
    }

    @Test
    fun `not ready before the kernel writes the table`() {
        assertFalse(RouteJsonStore.ready)
        assertNull(RouteJsonStore.allGlobalRules())
    }

    @Test
    fun `a global row written by the kernel maps every column`() {
        write("global_route_rules", listOf(globalRuleRow(7, 0, "ads")))
        assertTrue(RouteJsonStore.ready)

        val rule = RouteJsonStore.allGlobalRules()!!.single()
        assertEquals(7L, rule.ruleId)
        assertEquals(0, rule.ruleOrder)
        assertEquals("ads", rule.name)
        assertEquals("4", rule.ipVersion)
        assertEquals("tcp", rule.network)
        assertEquals("tls", rule.protocol)
        assertEquals("""["b.com"]""", rule.domainJson)
        assertEquals("""["ads.example"]""", rule.domainSuffixJson)
        assertEquals("""["rs"]""", rule.ruleSetJson)
        assertEquals("""["sn"]""", rule.sniffersJson)
        assertEquals("reject", rule.action)
        assertEquals(-1L, rule.outboundId)
        assertEquals("prefer_ipv4", rule.strategy)
        assertTrue(rule.disabled)
        assertTrue(rule.invert)
        assertTrue(rule.networkIsExpensive)
    }

    @Test
    fun `the global pool maps id onto ruleId`() {
        write("global_route_rules", listOf(globalRuleRow(11, 0), globalRuleRow(12, 1)))

        val pool = RouteJsonStore.allGlobalRules()!!
        assertEquals(listOf(11L, 12L), pool.map { it.ruleId })
        assertEquals(listOf(0, 1), pool.map { it.ruleOrder })
        assertEquals("reject", pool.first().action)
        assertEquals("""["ads.example"]""", pool.first().domainSuffixJson)
    }

    @Test
    fun `a missing global table reads as absent`() {
        assertNull(RouteJsonStore.allGlobalRules())
    }

    @Test
    fun `a corrupt global table reads as absent`() {
        File(temp, "global_route_rules.json").writeText("{ broken")
        assertNull(RouteJsonStore.allGlobalRules())
    }

    @Test
    fun `a document with no rows array reads as absent`() {
        File(temp, "global_route_rules.json").writeText("""{"version":1,"name":"global_route_rules"}""")
        assertNull(RouteJsonStore.allGlobalRules())
    }

    @Test
    fun `a newer document version still reads`() {
        // Columns are additive; refusing a newer file would strand a user who downgraded a build.
        val payload = JSONObject().apply {
            put("version", 2)
            put("name", "global_route_rules")
            put("rows", org.json.JSONArray(listOf(globalRuleRow(5, 0))))
        }
        File(temp, "global_route_rules.json").writeText(payload.toString())

        assertEquals(5L, RouteJsonStore.allGlobalRules()!!.single().ruleId)
    }

    @Test
    fun `the table is cached until the file version changes`() {
        write("global_route_rules", listOf(globalRuleRow(1, 0, "first")))
        assertEquals("first", RouteJsonStore.allGlobalRules()!!.single().name)

        // Same mtime+length snapshot: a rewrite with identical bytes keeps the cache.
        write("global_route_rules", listOf(globalRuleRow(1, 0, "first")))
        assertEquals("first", RouteJsonStore.allGlobalRules()!!.single().name)
    }
}
