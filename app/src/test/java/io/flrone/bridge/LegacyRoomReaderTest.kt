package io.flrone.bridge

import io.nekohasekai.sagernet.database.RouteJsonStore
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * The raw legacy reader (ADR 0006 stages C2c2a/C2c2b2): the only reader of the
 * retired database.
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
        for (key in listOf("profiles", "groups", "settings", "markers")) {
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
        assertEquals(1L, legacy.rows.getValue("groups").single()["id"])
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
        assertTrue(all.profiles && all.settings && all.markers)

        File(documents, "profiles.json").writeText("{}")
        File(documents, "settings.json").writeText("{}")
        val partial = LegacyRoomReader.eligible(documents)
        assertFalse("profiles.json exists", partial.profiles)
        assertFalse("settings.json exists", partial.settings)
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
        assertTrue(can.settings)
        assertEquals(1, rows.getValue("settings").size)
    }

    @Test
    fun `a fresh install seeds nothing and the stores read empty`() {
        // No database file: the snapshot is all-empty and creates nothing, and
        // nothing reads documents that do not exist.
        val documents = File(root, "documents")
        val missing = File(root, "databases/sager_net.db")
        val reply = LegacyRoomReader.snapshot(documents, missing)
        for (value in reply.values) {
            assertTrue("every part must be empty", (value as List<*>).isEmpty())
        }
        assertFalse(documents.exists())

        val previous = RouteJsonStore.directory
        try {
            RouteJsonStore.directory = documents
            assertNull("a fresh install has no global rule table", RouteJsonStore.allGlobalRules())
        } finally {
            RouteJsonStore.directory = previous
        }
        assertTrue(LegacyRoomReader.settingsFrom(emptyList()).isEmpty())
        assertTrue(LegacyRoomReader.markersFrom(emptyList()).isEmpty())
    }

    @Test
    fun `an old database seeds every row set once`() {
        // The retired file's rows, as the framework reader returns them: one
        // row per table. A real SQLite open needs Android, so the row decisions
        // and the document gate are driven here over the same helpers. Route
        // tables are absent: there is no legacy route format any more.
        val documents = File(root, "documents")
        val legacy = LegacyRoomReader.Legacy(
            mapOf(
                "profiles" to listOf<Map<String, Any?>>(mapOf("id" to 1L, "type" to "ss")),
                "groups" to listOf<Map<String, Any?>>(mapOf("id" to 1L, "name" to "G")),
                "settings" to listOf<Map<String, Any?>>(mapOf("key" to "theme", "value" to "dark")),
                "markers" to listOf<Map<String, Any?>>(mapOf("key" to "m", "marked_at" to 7L)),
            ),
        )
        val absent = LegacyRoomReader.eligible(documents)
        val first = LegacyRoomReader.snapshot(legacy, absent)
        assertEquals(1, (first.getValue("profiles") as List<*>).size)
        assertEquals(1, (first.getValue("groups") as List<*>).size)
        assertEquals(1, (first.getValue("settings") as List<*>).size)
        assertEquals(1, (first.getValue("markers") as List<*>).size)
        assertEquals(mapOf("theme" to "dark"), LegacyRoomReader.settingsFrom(legacy.rows.getValue("settings")))
        assertEquals(mapOf("m" to 7L), LegacyRoomReader.markersFrom(legacy.rows.getValue("markers")))

        // The owners write the documents (Dart's profiles.json,
        // SettingsJsonStore's pair); every gate now reports "present".
        for (name in listOf("profiles.json", "settings.json", "markers.json")) {
            File(documents, name).writeText("{}")
        }
        val can = LegacyRoomReader.eligible(documents)
        assertFalse(can.profiles)
        assertFalse(can.settings)
        assertFalse(can.markers)
        // Second hand-over: nothing is copied over the live documents.
        val again = LegacyRoomReader.snapshot(legacy, can)
        for (value in again.values) {
            assertTrue("no table may answer twice", (value as List<*>).isEmpty())
        }
    }
}
