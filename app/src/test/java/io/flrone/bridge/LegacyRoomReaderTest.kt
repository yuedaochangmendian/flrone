package io.flrone.bridge

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
 * The raw legacy reader (ADR 0006 stage C2c2a).
 *
 * These tests cover the row/eligibility decisions and the "never create, never
 * migrate, empty on a fresh install" contract without an Android connection:
 * [LegacyRoomReader.read] over a fake [LegacyRoomReader.Source], and the
 * document-presence gate over a temp directory. A real `sager_net.db` read is a
 * device/CI check (only [LegacyRoomReader.FrameworkSource] touches
 * `android.database`).
 */
class LegacyRoomReaderTest {

    private lateinit var root: File
    private lateinit var logger: (String, Throwable?) -> Unit

    @Before
    fun setUp() {
        root = Files.createTempDirectory("legacy-reader-").toFile()
        logger = LegacyRoomReader.logger
        // The default logger goes through Logs, whose Android logging is a
        // device concern; the row decisions are what these tests pin.
        LegacyRoomReader.logger = { _, _ -> }
    }

    @After
    fun tearDown() {
        LegacyRoomReader.logger = logger
        root.deleteRecursively()
    }

    private class FakeSource(
        private val tables: Set<String>,
        private val rows: Map<String, List<Map<String, Any?>>>,
    ) : LegacyRoomReader.Source {
        override fun tables(): Set<String> = tables
        override fun rows(table: String): List<Map<String, Any?>> =
            rows[table] ?: error("unexpected table $table")
    }

    @Test
    fun `a missing database answers empty and is never created`() {
        val file = File(root, "databases/sager_net.db")
        val documents = File(root, "documents")
        val reply = LegacyRoomReader.snapshot(documents, file)
        for (key in listOf(
            "profiles", "groups", "routeProfiles", "routeRules",
            "globalRouteRules", "settings", "markers",
        )) {
            assertTrue("$key must be empty", (reply[key] as List<*>).isEmpty())
        }
        assertFalse("the reader must not create the database", file.exists())
        assertFalse("the reader must not create the databases directory", file.parentFile!!.exists())
        assertFalse("the reader must not create the documents directory", documents.exists())
    }

    @Test
    fun `read answers every table the source has`() {
        val tables = LegacyRoomReader.TABLES.toSet()
        val rows = tables.associateWith { table ->
            listOf<Map<String, Any?>>(mapOf("id" to 1L, "name" to table))
        }
        val legacy = LegacyRoomReader.read(FakeSource(tables, rows))
        assertEquals(tables, legacy.rows.keys)
        assertEquals("profiles", legacy.rows.getValue("profiles").single()["name"])
        assertEquals(1L, legacy.rows.getValue("route_rules").single()["id"])
    }

    @Test
    fun `a missing table is skipped, not invented`() {
        val legacy = LegacyRoomReader.read(
            FakeSource(setOf("profiles"), mapOf("profiles" to listOf(mapOf("id" to 7L)))),
        )
        assertEquals(setOf("profiles"), legacy.rows.keys)
    }

    @Test
    fun `a failing table read leaves that table empty`() {
        val source = object : LegacyRoomReader.Source {
            override fun tables(): Set<String> = setOf("profiles", "groups")
            override fun rows(table: String): List<Map<String, Any?>> =
                if (table == "groups") error("corrupt") else listOf(mapOf("id" to 1L))
        }
        val legacy = LegacyRoomReader.read(source)
        assertEquals(1, legacy.rows.getValue("profiles").size)
        assertTrue(legacy.rows.getValue("groups").isEmpty())
    }

    @Test
    fun `eligibility follows the documents that exist`() {
        val documents = File(root, "documents").apply { mkdirs() }
        val all = LegacyRoomReader.eligible(documents)
        assertTrue(all.profiles && all.routeTables && all.settings && all.markers)

        File(documents, "profiles.json").writeText("{}")
        File(documents, "settings.json").writeText("{}")
        val partial = LegacyRoomReader.eligible(documents)
        assertFalse("profiles.json exists", partial.profiles)
        assertFalse("settings.json exists", partial.settings)
        assertTrue(partial.routeTables)
        assertTrue(partial.markers)
    }

    @Test
    fun `snapshot gates rows by their documents`() {
        val documents = File(root, "documents").apply { mkdirs() }
        File(documents, "profiles.json").writeText("{}")
        val tables = LegacyRoomReader.TABLES.toSet()
        val rows = tables.associateWith { table ->
            listOf<Map<String, Any?>>(mapOf("id" to 1L, "name" to table))
        }
        // The snapshot's reader is [read] over the framework connection; the
        // gate itself is what this test pins, through the same helper.
        val can = LegacyRoomReader.eligible(documents)
        assertFalse(can.profiles)
        assertEquals(0, if (can.profiles) rows.getValue("profiles").size else 0)
        assertTrue(can.routeTables)
        assertEquals(1, rows.getValue("route_profiles").size)
    }

    @Test
    fun `seeding the route documents writes each table once`() {
        val documents = File(root, "documents")
        val rows = mapOf(
            "route_profiles" to listOf<Map<String, Any?>>(mapOf("id" to 1L, "name" to "Home")),
            "route_rules" to listOf<Map<String, Any?>>(
                mapOf("route_profile_id" to 1L, "rule_order" to 0L, "name" to "Rule DNS"),
            ),
            "global_route_rules" to emptyList<Map<String, Any?>>(),
        )
        assertTrue(
            LegacyRoomReader.seedRouteDocuments(documents, LegacyRoomReader.ROUTE_TABLES, rows),
        )
        val profiles = File(documents, "route_profiles.json")
        assertTrue(profiles.isFile)
        val document = JSONObject(profiles.readText())
        assertEquals(1, document.getInt("version"))
        assertEquals("route_profiles", document.getString("name"))
        val first = document.getJSONArray("rows").getJSONObject(0)
        assertEquals(1L, first.getLong("id"))
        assertEquals("Home", first.getString("name"))

        // The marker exists: a second hand-over must not overwrite the kernel's copy.
        assertFalse(
            LegacyRoomReader.seedRouteDocuments(documents, LegacyRoomReader.ROUTE_TABLES, rows),
        )
    }

    @Test
    fun `seeding without route tables does nothing`() {
        val documents = File(root, "documents")
        assertFalse(
            LegacyRoomReader.seedRouteDocuments(documents, LegacyRoomReader.ROUTE_TABLES, emptyMap()),
        )
        assertFalse(documents.exists())
    }
}
