package io.nekohasekai.sagernet.bg.autoselector

import io.flrone.bridge.DartProfileStore
import io.flrone.bridge.DartProfileWriter
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * The model-free selector prune view (S8 residual cleanup): [AutoSelectorProfiles.load] /
 * [AutoSelectorProfiles.SelectorPruneView.pruned] / [AutoSelectorProfiles.save] must reproduce the
 * old `AutoSelector` decisions **and** write back only `pool` / `last_built`, leaving every other
 * field of the stored document — including its canonical sorted-key compact form — untouched. A
 * whole-model re-export here would silently drop anything the model did not know about.
 */
class AutoSelectorProfilesTest {

    private lateinit var temp: File
    private var originalDirectory: File? = null
    private lateinit var originalLogger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        temp = File.createTempFile("autoselector-profiles", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        originalDirectory = DartProfileStore.directory
        originalLogger = DartProfileStore.logger
        DartProfileStore.directory = temp
        DartProfileStore.logger = { _, _ -> }
        DartProfileStore.invalidate()
        DartProfileWriter.testTransport = null
    }

    @After
    fun tearDown() {
        DartProfileWriter.testTransport = null
        DartProfileStore.directory = originalDirectory
        DartProfileStore.logger = originalLogger
        DartProfileStore.invalidate()
        temp.deleteRecursively()
    }

    /** The canonical compact document `AutoSelector.exportToJson` writes (sorted keys), edited in place. */
    private val selectorJson = "{" +
        "\"active_size\":8,\"balance\":false,\"balance_interval_sec\":30,\"balance_mode\":\"rotate\"," +
        "\"bench_interval_sec\":600,\"build_limit\":300,\"connectivity_url\":\"\",\"country_filter\":\"\"," +
        "\"dial_retries\":2,\"exclude_unavailable\":true,\"expected\":3,\"gid\":2,\"gids\":[2,3]," +
        "\"history\":[{\"builds\":1,\"fails\":0,\"first\":1,\"id\":9,\"last\":2,\"name\":\"x\"}]," +
        "\"interrupt_on_switch\":true,\"interval_sec\":300,\"last_built\":[4],\"last_built_at\":0," +
        "\"max_rtt_ms\":0,\"name\":\"\",\"name_filter\":\"\",\"pinned_id\":-1,\"pool\":[1,2]," +
        "\"pool_cap\":1000,\"pool_ranked_at\":1700000000,\"result_validity_mins\":1440,\"sampling\":10," +
        "\"test_url\":\"\",\"tolerance_ms\":300,\"type\":\"autoselector\",\"watch_interval_sec\":15}"

    private fun writeDocument(outboundJson: String, type: String = AutoSelectorProfiles.TYPE) {
        val profile = JSONObject()
            .put("id", 10L)
            .put("type", type)
            .put("name", "sel")
            .put("gid", 1L)
            .put("user_order", 0L)
            .put("outbound_json", outboundJson)
        val root = JSONObject()
            .put("version", 1)
            .put("nextProfileId", 11L)
            .put("nextGroupId", 1L)
            .put("profiles", JSONArray().put(profile))
            .put("groups", JSONArray())
        File(temp, "profiles.json").writeText(root.toString())
        DartProfileStore.invalidate()
    }

    /**
     * Captures the column patches [AutoSelectorProfiles.save] sends. The rows are keyed by the string
     * id the wire carries (`applyDocument` stringifies the ids), so the assertions read "10".
     */
    private fun saveAndCapture(view: AutoSelectorProfiles.SelectorPruneView): Map<String, Map<String, Any?>> {
        var patches: Map<String, Map<String, Any?>> = emptyMap()
        DartProfileWriter.testTransport = { method, args ->
            assertEquals("applyDocument", method)
            val payload = args as Map<*, *>
            @Suppress("UNCHECKED_CAST")
            patches = payload["profilePatches"] as? Map<String, Map<String, Any?>> ?: emptyMap()
            emptyMap<String, Any?>()
        }
        try {
            AutoSelectorProfiles.save(10L, view)
        } finally {
            DartProfileWriter.testTransport = null
        }
        return patches
    }

    @Test
    fun `load reads the tracked groups and the two ranked lists`() {
        writeDocument(selectorJson)
        val view = AutoSelectorProfiles.load(10L)!!
        assertEquals(listOf(2L, 3L), view.gids)
        assertEquals(listOf(1L, 2L), view.pool)
        assertEquals(listOf(4L), view.lastBuilt)
    }

    @Test
    fun `load prefers gids over gid and drops negative or repeated ids`() {
        writeDocument("""{"gid":7,"gids":[3,-1,4,4],"pool":[5,-6],"last_built":[]}""")
        val view = AutoSelectorProfiles.load(10L)!!
        assertEquals(listOf(3L, 4L), view.gids)
        assertEquals(listOf(5L, -6L), view.pool)
        assertEquals(emptyList<Long>(), view.lastBuilt)
    }

    @Test
    fun `load falls back to the single gid and drops a negative one`() {
        writeDocument("""{"gid":7}""")
        assertEquals(listOf(7L), AutoSelectorProfiles.load(10L)!!.gids)
        writeDocument("""{"gid":-1}""")
        assertEquals(emptyList<Long>(), AutoSelectorProfiles.load(10L)!!.gids)
    }

    @Test
    fun `load of a blank document is the type defaults, of an unreadable one nothing`() {
        writeDocument("")
        val empty = AutoSelectorProfiles.load(10L)!!
        assertEquals(emptyList<Long>(), empty.gids)
        assertEquals(emptyList<Long>(), empty.pool)
        assertEquals(emptyList<Long>(), empty.lastBuilt)
        writeDocument("[]")
        assertNull(AutoSelectorProfiles.load(10L))
    }

    @Test
    fun `load of another type or a missing row is nothing`() {
        writeDocument(selectorJson, type = "vless")
        assertNull(AutoSelectorProfiles.load(10L))
        writeDocument(selectorJson)
        assertNull(AutoSelectorProfiles.load(99L))
    }

    @Test
    fun `pruned drops the members that no longer exist and reports no change otherwise`() {
        val view = AutoSelectorProfiles.SelectorPruneView(
            gids = listOf(1L),
            pool = listOf(1L, 2L, 3L),
            lastBuilt = listOf(9L),
        )
        val pruned = view.pruned(setOf(1L, 3L))!!
        assertEquals(listOf(1L, 3L), pruned.pool)
        assertEquals(emptyList<Long>(), pruned.lastBuilt)
        assertEquals(view.gids, pruned.gids)
        assertNull(view.pruned(setOf(1L, 2L, 3L, 9L)))
    }

    @Test
    fun `save patches only outbound_json and preserves every other field and its order`() {
        writeDocument(selectorJson)
        val patches = saveAndCapture(
            AutoSelectorProfiles.SelectorPruneView(gids = listOf(2L, 3L), pool = listOf(2L, 3L), lastBuilt = listOf(4L, 5L)),
        )
        assertEquals(setOf("10"), patches.keys)
        assertEquals(setOf("outbound_json"), patches.getValue("10").keys)
        // Only the two ranked lists changed; the canonical sorted-key compact form is byte-identical otherwise.
        val expected = selectorJson
            .replace("\"last_built\":[4]", "\"last_built\":[4,5]")
            .replace("\"pool\":[1,2]", "\"pool\":[2,3]")
        assertEquals(expected, patches.getValue("10")["outbound_json"])
    }

    @Test
    fun `save keeps a document it cannot read instead of replacing it`() {
        writeDocument("[]")
        val patches = saveAndCapture(
            AutoSelectorProfiles.SelectorPruneView(gids = emptyList(), pool = listOf(1L), lastBuilt = emptyList()),
        )
        assertTrue(patches.isEmpty())
    }
}
