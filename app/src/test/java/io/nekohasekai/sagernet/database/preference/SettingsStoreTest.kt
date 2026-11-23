package io.nekohasekai.sagernet.database.preference

import io.nekohasekai.sagernet.database.SettingsJsonStore
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * [SettingsStore]'s two stores (ADR 0006 stages C1/C2): the documents once the host mounts the
 * directory, Room's legacy table as the pre-mount fallback. The Room side is the store's own
 * [SettingsStore.Room] seam, so no Room and no Android type loads in the test process.
 */
class SettingsStoreTest {

    private lateinit var dir: File
    private lateinit var room: FakeRoom

    private class FakeRoom : SettingsStore.Room {
        val rows = LinkedHashMap<String, String>()
        var writes = 0

        override fun get(key: String): String? = rows[key]

        override fun all(): Map<String, String> = LinkedHashMap(rows)

        override fun put(key: String, value: String) {
            writes++
            rows[key] = value
        }

        override fun putAll(values: Map<String, String>) {
            writes++
            rows.putAll(values)
        }

        override fun remove(key: String) {
            writes++
            rows.remove(key)
        }

        override fun reset() {
            writes++
            rows.clear()
        }
    }

    @Before
    fun setUp() {
        dir = File.createTempFile("settings-store", "").let { probe ->
            probe.delete()
            probe.mkdirs()
            probe
        }
        room = FakeRoom()
        SettingsJsonStore.logger = { _, _ -> }
        SettingsJsonStore.legacySettings = { mapOf("legacy" to "seed") }
        SettingsJsonStore.legacyMarkers = { emptyMap() }
        SettingsJsonStore.directory = dir
    }

    @After
    fun tearDown() {
        SettingsJsonStore.directory = null
        SettingsJsonStore.legacySettings = { emptyMap() }
        SettingsJsonStore.legacyMarkers = { emptyMap() }
        dir.deleteRecursively()
    }

    private fun store() = SettingsStore(room, { null })

    @Test
    fun `mounted writes land in the document and never in the legacy table`() {
        val store = store()
        store.putBoolean("mounted", true)
        store.putInt("port", 1080)
        store.putStringList("list", listOf("a", "b"))

        assertEquals("true", SettingsJsonStore.get("mounted"))
        assertEquals("1080", SettingsJsonStore.get("port"))
        assertEquals(0, room.writes)
        assertTrue(room.rows.isEmpty())

        // The typed getters read the same document back.
        assertEquals(true, store.getBoolean("mounted"))
        assertEquals(1080, store.getInt("port"))
        assertEquals(listOf("a", "b"), store.getStringList("list"))
    }

    @Test
    fun `mounted reads come from the document, not the legacy table`() {
        room.rows["port"] = "1"
        SettingsJsonStore.put("port", "2")
        assertEquals(2, store().getInt("port"))
    }

    @Test
    fun `mounted all, putAll, remove and reset route to the document`() {
        val store = store()
        store.putAll(mapOf("a" to "1", "b" to "2"))
        assertEquals(mapOf("legacy" to "seed", "a" to "1", "b" to "2"), store.all())
        assertEquals(0, room.writes)

        store.remove("a")
        assertNull(store.getRaw("a"))
        assertEquals(0, room.writes)

        store.reset()
        assertTrue(store.all().isEmpty())
        assertEquals(0, room.writes)
        // The legacy table is untouched throughout.
        assertTrue(room.rows.isEmpty())
    }

    @Test
    fun `unmounted reads and writes the legacy table`() {
        SettingsJsonStore.directory = null
        room.rows["a"] = "1"

        val store = store()
        assertEquals("1", store.getString("a"))
        assertEquals(mapOf("a" to "1"), store.all())

        store.putString("b", "2")
        assertEquals("2", room.rows["b"])

        store.putAll(mapOf("c" to "3"))
        assertEquals(mapOf("a" to "1", "b" to "2", "c" to "3"), room.rows)

        store.remove("a")
        assertNull(room.rows["a"])

        store.reset()
        assertTrue(room.rows.isEmpty())
        assertEquals(4, room.writes)
    }

    @Test
    fun `a second store instance sees an external write`() {
        val first = store()
        first.putString("shared", "one")
        assertEquals("one", first.getString("shared"))

        // Another process rewrites the document in the same envelope (a restore does exactly
        // this); the second instance must answer the file, not a snapshot of the first read.
        val array = JSONArray().put(JSONObject().put("key", "shared").put("value", "two-two-two"))
        File(dir, "settings.json").writeText(
            JSONObject().apply {
                put("version", 1)
                put("name", "settings")
                put("written", true)
                put("rows", array)
            }.toString(),
        )
        assertEquals("two-two-two", store().getString("shared"))
    }
}
