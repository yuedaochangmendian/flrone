package io.nekohasekai.sagernet.database

import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.OverlappingFileLockException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The settings documents (ADR 0006 stages C1/C2): fresh-install empty seeding, the
 * read/write round trip, corrupt/empty-document rewriting, the write lock and the
 * markers companion. Pure JVM — no Room and no Android types load.
 */
class SettingsJsonStoreTest {

    private lateinit var dir: File

    @Before
    fun setUp() {
        dir = File.createTempFile("settings-json", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        SettingsJsonStore.logger = { _, _ -> }
        SettingsJsonStore.directory = dir
    }

    @After
    fun tearDown() {
        SettingsJsonStore.directory = null
        dir.deleteRecursively()
    }

    /** A document as another process (or the kernel) writes one: the envelope the store reads. */
    private fun document(name: String, rows: List<Pair<String, String>>, written: Boolean = true): String {
        val array = JSONArray()
        rows.forEach { (key, value) -> array.put(JSONObject().put("key", key).put("value", value)) }
        return JSONObject().apply {
            put("version", 1)
            put("name", name)
            if (written) put("written", true)
            put("rows", array)
        }.toString()
    }

    private fun rowsOf(name: String): Map<String, String> {
        val array = JSONObject(File(dir, "$name.json").readText()).getJSONArray("rows")
        return (0 until array.length()).associate {
            val row = array.getJSONObject(it)
            row.getString("key") to row.getString("value")
        }
    }

    @Test
    fun `first access seeds two empty documents`() {
        assertNull(SettingsJsonStore.get("theme"))
        assertTrue(File(dir, "settings.json").isFile)
        assertTrue(File(dir, "markers.json").isFile)
        assertTrue(SettingsJsonStore.all().isEmpty())
        assertTrue(SettingsJsonStore.markers().isEmpty())
    }

    @Test
    fun `writes round-trip through the document`() {
        SettingsJsonStore.put("theme", "light")
        SettingsJsonStore.putAll(mapOf("added" to "x"))
        assertEquals("light", SettingsJsonStore.get("theme"))
        assertEquals("x", SettingsJsonStore.get("added"))
        SettingsJsonStore.remove("added")
        assertNull(SettingsJsonStore.get("added"))
        assertEquals(mapOf("theme" to "light"), SettingsJsonStore.all())
        SettingsJsonStore.reset()
        assertTrue(SettingsJsonStore.all().isEmpty())
    }

    @Test
    fun `a corrupt document is rewritten as empty`() {
        SettingsJsonStore.put("theme", "light")
        File(dir, "settings.json").writeText("{ not json")
        // The next read treats the document as missing and rewrites it as an
        // empty, marked document instead of failing every subsequent read.
        assertNull(SettingsJsonStore.get("theme"))
        assertTrue(SettingsJsonStore.all().isEmpty())
    }

    @Test
    fun `a truncated document is rewritten before the first write`() {
        // A write that died before its payload: the file exists, holds nothing.
        File(dir, "settings.json").writeText("")
        SettingsJsonStore.put("theme", "light")
        assertEquals("light", SettingsJsonStore.get("theme"))
        assertEquals(mapOf("theme" to "light"), SettingsJsonStore.all())
    }

    @Test
    fun `an empty unmarked document is rewritten, not taken as an empty store`() {
        // Parses, has no rows and carries no write marker: a half-written or foreign file.
        File(dir, "settings.json").writeText(document("settings", emptyList(), written = false))
        assertTrue(SettingsJsonStore.all().isEmpty())
        assertTrue(JSONObject(File(dir, "settings.json").readText()).getBoolean("written"))
    }

    @Test
    fun `a deliberate reset stays empty`() {
        SettingsJsonStore.put("theme", "light")
        SettingsJsonStore.reset()
        // The reset writes a marked empty document, so the empty-file rewriting path
        // must not turn it back into a missing document.
        assertTrue(SettingsJsonStore.all().isEmpty())
        SettingsJsonStore.put("after", "reset")
        assertEquals(mapOf("after" to "reset"), SettingsJsonStore.all())
    }

    @Test
    fun `mounted writes land in the document`() {
        SettingsJsonStore.put("theme", "light")
        SettingsJsonStore.putAll(mapOf("added" to "x"))
        SettingsJsonStore.remove("added")

        val document = JSONObject(File(dir, "settings.json").readText())
        assertEquals("settings", document.getString("name"))
        assertTrue(document.getBoolean("written"))
        assertEquals(mapOf("theme" to "light"), rowsOf("settings"))
    }

    @Test
    fun `the document stamp tracks the file and is null when absent`() {
        assertNull(SettingsJsonStore.settingsStamp())
        SettingsJsonStore.put("theme", "light")
        val first = SettingsJsonStore.settingsStamp()
        assertNotNull(first)
        assertEquals(File(dir, "settings.json").length(), first!!.length)
        SettingsJsonStore.put("theme", "a longer value")
        val second = SettingsJsonStore.settingsStamp()
        assertNotNull(second)
        assertNotEquals("the watch needs a different stamp for a changed document", first, second)
    }

    @Test
    fun `an external write invalidates the cache by mtime and length`() {
        // Another process — or a restore from Dart — rewrites the whole document.
        SettingsJsonStore.put("theme", "initial")
        File(dir, "settings.json").writeText(
            document("settings", listOf("theme" to "light", "added" to "from-outside")),
        )
        // The reader had the pre-write rows cached; the document is what it must answer.
        assertEquals("light", SettingsJsonStore.get("theme"))
        assertEquals("from-outside", SettingsJsonStore.get("added"))
    }

    @Test
    fun `concurrent writers keep every key`() {
        SettingsJsonStore.ensure() // seed once, so the threads only race on their own keys
        val keys = (0 until 8).map { "key-$it" }
        val threads = keys.map { key ->
            Thread {
                repeat(25) { round -> SettingsJsonStore.put(key, "v-$round") }
            }
        }
        threads.forEach { it.start() }
        threads.forEach { it.join(60_000) }
        threads.forEach { assertTrue("a writer did not finish", !it.isAlive) }

        val rows = SettingsJsonStore.all()
        keys.forEach { assertTrue("lost key $it", rows.containsKey(it)) }
        assertEquals(keys.size, rows.size)
    }

    @Test
    fun `the document lock is held for the whole block and released after it`() {
        val lockFile = File(dir, DocumentWriteLock.FILE)
        DocumentWriteLock.withLock(dir, { _, _ -> }) {
            RandomAccessFile(lockFile, "rw").use { handle ->
                val error = runCatching { handle.channel.tryLock() }.exceptionOrNull()
                // A second lock in the same JVM is refused: proof the OS lock is held.
                assertTrue("the document lock was not held: $error", error is OverlappingFileLockException)
            }
        }
        RandomAccessFile(lockFile, "rw").use { handle ->
            val lock = handle.channel.tryLock()
            assertNotNull("the document lock was not released", lock)
            lock!!.release()
        }
    }

    @Test
    fun `every mutation takes the document lock`() {
        SettingsJsonStore.ensure() // the seed is a mutation too; run it outside the check
        val lockFile = File(dir, DocumentWriteLock.FILE)
        RandomAccessFile(lockFile, "rw").use { handle ->
            val held = handle.channel.lock()
            try {
                // While this JVM holds the lock, a mutation cannot take it as well (FileLock is
                // process-wide, not thread-wide): the JDK refuses the overlap. A mutation that
                // skipped the lock would sail through here.
                val error = runCatching { SettingsJsonStore.put("theme", "light") }.exceptionOrNull()
                assertTrue("a mutation ran without the document lock: $error", error is OverlappingFileLockException)
            } finally {
                held.release()
            }
        }
        SettingsJsonStore.put("theme", "light")
        assertEquals("light", SettingsJsonStore.get("theme"))
    }

    @Test
    fun `markers round-trip and reset`() {
        SettingsJsonStore.putMarkers(mapOf("marker-b" to 7L))
        assertEquals(mapOf("marker-b" to 7L), SettingsJsonStore.markers())
        SettingsJsonStore.resetMarkers()
        assertTrue(SettingsJsonStore.markers().isEmpty())
    }

    @Test
    fun `unmounted answers null`() {
        SettingsJsonStore.directory = null
        assertNull(SettingsJsonStore.get("theme"))
        assertNull(SettingsJsonStore.get("missing"))
    }
}
