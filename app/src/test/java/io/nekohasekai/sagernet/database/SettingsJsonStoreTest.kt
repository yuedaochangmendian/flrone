package io.nekohasekai.sagernet.database

import java.io.File
import java.io.RandomAccessFile
import java.nio.channels.OverlappingFileLockException
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The settings documents (ADR 0006 stages C1/C2): seed-from-legacy, the read/write round trip,
 * corrupt/empty-document re-seeding, the write lock and the markers companion. Pure JVM — the
 * legacy seams are injected, so no Room and no Android types load.
 */
class SettingsJsonStoreTest {

    private lateinit var dir: File
    private var legacyReads = 0

    @Before
    fun setUp() {
        dir = File.createTempFile("settings-json", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        legacyReads = 0
        SettingsJsonStore.logger = { _, _ -> }
        SettingsJsonStore.legacySettings = {
            legacyReads++
            mapOf("theme" to "dark", "keep" to "1")
        }
        SettingsJsonStore.legacyMarkers = { mapOf("marker-a" to 42L) }
        SettingsJsonStore.directory = dir
    }

    @After
    fun tearDown() {
        SettingsJsonStore.directory = null
        SettingsJsonStore.legacySettings = { emptyMap() }
        SettingsJsonStore.legacyMarkers = { emptyMap() }
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
    fun `first access seeds the documents from the legacy rows`() {
        assertEquals("dark", SettingsJsonStore.get("theme"))
        assertTrue(File(dir, "settings.json").isFile)
        assertTrue(File(dir, "markers.json").isFile)
        assertEquals(1, legacyReads)
        assertEquals(mapOf("marker-a" to 42L), SettingsJsonStore.markers())
    }

    @Test
    fun `writes round-trip through the document`() {
        SettingsJsonStore.put("theme", "light")
        SettingsJsonStore.putAll(mapOf("added" to "x"))
        assertEquals("light", SettingsJsonStore.get("theme"))
        assertEquals("x", SettingsJsonStore.get("added"))
        SettingsJsonStore.remove("keep")
        assertNull(SettingsJsonStore.get("keep"))
        assertEquals(mapOf("theme" to "light", "added" to "x"), SettingsJsonStore.all())
        SettingsJsonStore.reset()
        assertTrue(SettingsJsonStore.all().isEmpty())
    }

    @Test
    fun `a corrupt document re-seeds instead of losing rows`() {
        SettingsJsonStore.put("theme", "light")
        File(dir, "settings.json").writeText("{ not json")
        // The next read treats the document as missing and re-seeds from the
        // legacy rows — the property that makes the switch loss-free.
        assertEquals("dark", SettingsJsonStore.get("theme"))
    }

    @Test
    fun `a truncated document is re-seeded before the first write`() {
        // A write that died before its payload: the file exists, holds nothing.
        File(dir, "settings.json").writeText("")
        SettingsJsonStore.put("theme", "light")
        assertEquals("light", SettingsJsonStore.get("theme"))
        // The legacy row the empty file would otherwise have silently dropped.
        assertEquals("1", SettingsJsonStore.get("keep"))
    }

    @Test
    fun `an empty unmarked document is re-seeded, not taken as an empty store`() {
        // Parses, has no rows and carries no write marker: a half seed or a foreign file.
        // Treating it as authoritative would drop every legacy row on the next write.
        File(dir, "settings.json").writeText(document("settings", emptyList(), written = false))
        assertEquals("dark", SettingsJsonStore.get("theme"))
        assertEquals(mapOf("theme" to "dark", "keep" to "1"), SettingsJsonStore.all())
    }

    @Test
    fun `a deliberate reset stays empty`() {
        SettingsJsonStore.put("theme", "light")
        SettingsJsonStore.reset()
        // The reset writes a marked empty document, so the seed path (which re-seeds empty
        // unmarked files) must not resurrect the legacy rows.
        assertTrue(SettingsJsonStore.all().isEmpty())
        assertTrue(SettingsJsonStore.all().isEmpty())
        SettingsJsonStore.put("after", "reset")
        assertEquals(mapOf("after" to "reset"), SettingsJsonStore.all())
    }

    @Test
    fun `mounted writes land in the document and never consult the legacy rows`() {
        assertEquals("dark", SettingsJsonStore.get("theme"))
        assertEquals(1, legacyReads)
        SettingsJsonStore.put("theme", "light")
        SettingsJsonStore.putAll(mapOf("added" to "x"))
        SettingsJsonStore.remove("added")
        // The legacy lambda is the Room read path: a mounted write must not fall back to it.
        assertEquals(1, legacyReads)

        val document = JSONObject(File(dir, "settings.json").readText())
        assertEquals("settings", document.getString("name"))
        assertTrue(document.getBoolean("written"))
        assertEquals(mapOf("theme" to "light", "keep" to "1"), rowsOf("settings"))
    }

    @Test
    fun `an external write invalidates the cache by mtime and length`() {
        // Another process — or a restore from Dart — rewrites the whole document.
        assertEquals("dark", SettingsJsonStore.get("theme"))
        File(dir, "settings.json").writeText(
            document("settings", listOf("theme" to "light", "added" to "from-outside")),
        )
        // The reader had the pre-write rows cached; the document is what it must answer.
        assertEquals("light", SettingsJsonStore.get("theme"))
        assertEquals("from-outside", SettingsJsonStore.get("added"))
    }

    @Test
    fun `concurrent writers keep every key`() {
        SettingsJsonStore.get("theme") // seed once, so the threads only race on their own keys
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
        // The eight written keys plus the two the seed put there.
        assertEquals(10, rows.size)
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
        SettingsJsonStore.get("theme") // the seed is a mutation too; run it outside the check
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
        assertEquals(mapOf("marker-a" to 42L, "marker-b" to 7L), SettingsJsonStore.markers())
        SettingsJsonStore.resetMarkers()
        assertTrue(SettingsJsonStore.markers().isEmpty())
    }

    @Test
    fun `unmounted answers null and never touches the legacy rows`() {
        SettingsJsonStore.directory = null
        assertNull(SettingsJsonStore.get("theme"))
        assertNull(SettingsJsonStore.get("missing"))
        assertEquals(0, legacyReads)
    }
}
